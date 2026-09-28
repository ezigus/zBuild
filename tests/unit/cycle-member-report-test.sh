#!/usr/bin/env bash
# Tests (#2189): the cycle reads what a member REPORTED in this iteration — never
# a specific stage's artifact by path (ADR-055 §1, ADR-050 §1: the engine never
# learns what an artifact means).
#
# #1849 run 35949629759: design_verify_cycle (no build member) opened
# artifacts/build-summary.json, found build's leftover scope request, denied it
# and ended the run blocked_on_scope with 2h15m left.
#
# SPEC-1 [change]: runner_read_stage_report reads a member's primary result into
#   one report: changes {files, added, removed}, scope_request, not_reproduced.
# SPEC-2 [change]: a scope request is resolved only when a member of THIS
#   iteration reported one — a stale build-summary.json on disk is not read.
# SPEC-3 [guard] : a member's reported request is still resolved (deny when the
#   cycle is not expandable).
# SPEC-4 [change]: progress is the sum of the changes members reported this
#   iteration; a stale file on disk counts for nothing.
# SPEC-5 [change]: the changed-files list handed to the next test run comes from
#   the reports too.
# SPEC-6 [change]: the report also carries a test count, a list of failed items
#   and the member's reason, whichever member it is.
# SPEC-7 [change]: "the member that commits" is the one whose manifest declares
#   capabilities.produces_commits — found by declaration, never by the name build.
# SPEC-8 [change]: "tests failing" at exhaustion is decided from the members'
#   reported test counts — no member named `test`, no test-results.json by path.
# SPEC-9 [change]: the failed-gates banner names what the cycle's own exit_when
#   stage reported — not gate-aggregator-result.json by path.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "the cycle reads what members reported, not a stage's file (#2189)"
setup_test_env "cycle-member-report"
_test_cleanup_hook() { cleanup_test_env; }

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/ev"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="/dev/null"

# shellcheck source=../../core/pipeline/verdict.sh
source "$REPO_ROOT/core/pipeline/verdict.sh"
# shellcheck source=../../core/pipeline/cycle-orchestrator.sh
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"
set +e

STATE="$TEST_TEMP_DIR/state"; ART="$STATE/artifacts"; mkdir -p "$ART"
PD="$TEST_TEMP_DIR/plugins/agent/rp"; mkdir -p "$PD"
cat > "$PD/manifest.yaml" <<'EOF'
id: rp
name: rp
kind: agent
version: 0.0.1
hooks:
  run: rp_run
outputs:
  - id: rp_result
    path: ${artifact_dir}/rp-result.json
    type: json
    required: true
    primary: true
EOF

# ─── SPEC-1 ──────────────────────────────────────────────────────────────────
print_test_section "SPEC-1: one report per member, from its primary result"
jq -n '{result_contract:2, verdict:"scope_violation", disposition:"complete", reason:"r",
        files_changed:["a.sh","b.sh"], lines_added:7, lines_removed:2,
        scope_expansion_request:{files:[{path:"docs/x.md",category:"collateral_docs"}]},
        data:{not_reproduced:["test"]}}' > "$ART/rp-result.json"
_rep="$(runner_read_stage_report "$STATE" "$PD/manifest.yaml" rp 0 2>/dev/null)"
assert_eq "[SPEC-1] changes.files" '["a.sh","b.sh"]' "$(jq -c '.changes.files' <<< "$_rep" 2>/dev/null)"
assert_eq "[SPEC-1] changes.added" "7" "$(jq -r '.changes.added' <<< "$_rep" 2>/dev/null)"
assert_eq "[SPEC-1] changes.removed" "2" "$(jq -r '.changes.removed' <<< "$_rep" 2>/dev/null)"
assert_eq "[SPEC-1] scope_request" "docs/x.md" "$(jq -r '.scope_request.files[0].path' <<< "$_rep" 2>/dev/null)"
assert_eq "[SPEC-1] not_reproduced" '["test"]' "$(jq -c '.not_reproduced' <<< "$_rep" 2>/dev/null)"
# The v2 shape — fields under data.* — takes precedence over the legacy names.
jq -n '{result_contract:2, verdict:"pass", disposition:"complete", reason:"r",
        files_changed:["legacy.sh"],
        data:{changes:{files:["new.sh"],added:4,removed:0},
              scope_request:{files:[{path:"docs/y.md",category:"collateral_docs"}]}}}' > "$ART/rp-result.json"
_rep="$(runner_read_stage_report "$STATE" "$PD/manifest.yaml" rp 0 2>/dev/null)"
assert_eq "[SPEC-1] data.changes wins over the legacy fields" '["new.sh"]' "$(jq -c '.changes.files' <<< "$_rep" 2>/dev/null)"
assert_eq "[SPEC-1] data.scope_request is read" "docs/y.md" "$(jq -r '.scope_request.files[0].path' <<< "$_rep" 2>/dev/null)"

# ─── SPEC-2/3 ────────────────────────────────────────────────────────────────
print_test_section "SPEC-2/3: only a request reported this iteration is resolved"
jq -n '{scope_expansion_request:{files:[{path:"docs/adr/x.md",category:"collateral_docs",evidence:"",reason:"r"}]}}' \
    > "$ART/build-summary.json"
_blob_none='{"design":{"verdict":"pass","report":{}},"design-gate":{"verdict":"fail","report":{}}}'
assert_eq "[SPEC-2] a stale build-summary.json request is not read (the #1849 halt)" "none" \
    "$(_cycle_resolve_scope_expansion design_verify_cycle "$STATE" "$_blob_none" 2>/dev/null)"
_blob_req='{"build":{"verdict":"scope_violation","report":{"scope_request":{"files":[{"path":"docs/adr/x.md","category":"collateral_docs","evidence":"","reason":"r"}]}}}}'
assert_eq "[SPEC-3] a request a member reported is resolved (not expandable → deny)" "deny" \
    "$(_cycle_resolve_scope_expansion build_test_cycle "$STATE" "$_blob_req" 2>/dev/null)"

# ─── SPEC-4 ──────────────────────────────────────────────────────────────────
print_test_section "SPEC-4: progress is what members reported"
jq -n '{files_changed:["stale.sh"], lines_added:99, lines_removed:99}' > "$ART/build-summary.json"
assert_eq "[SPEC-4] no member reported changes → no progress, whatever is on disk" "0 0 0" \
    "$(_cycle_read_progress "$_blob_none" 2>/dev/null)"
_blob_chg='{"build":{"report":{"changes":{"files":["a.sh"],"added":3,"removed":1}}},"test":{"report":{}}}'
assert_eq "[SPEC-4] a member's reported changes are the progress" "1 3 1" \
    "$(_cycle_read_progress "$_blob_chg" 2>/dev/null)"

# ─── SPEC-5 ──────────────────────────────────────────────────────────────────
print_test_section "SPEC-5: the changed-files list comes from the reports"
assert_eq "[SPEC-5] changed files from the reports" "a.sh" \
    "$(_cycle_reported_changed_files "$_blob_chg" 2>/dev/null)"
assert_eq "[SPEC-5] none reported → empty" "" \
    "$(_cycle_reported_changed_files "$_blob_none" 2>/dev/null)"


# ─── SPEC-6 ──────────────────────────────────────────────────────────────────
print_test_section "SPEC-6: test counts, failed items and the reason travel in the report"
jq -n '{result_contract:2, verdict:"fail", disposition:"complete", reason:"3 failing", data:{failed:3, passed:9}}' > "$ART/rp-result.json"
_rep="$(runner_read_stage_report "$STATE" "$PD/manifest.yaml" rp 0 2>/dev/null)"
assert_eq "[SPEC-6] tests.failed" "3" "$(jq -r '.tests.failed' <<< "$_rep" 2>/dev/null)"
assert_eq "[SPEC-6] reason" "3 failing" "$(jq -r '.reason' <<< "$_rep" 2>/dev/null)"
jq -n '{result_contract:2, verdict:"fail", disposition:"complete", reason:"gates failed: lint", failed:["lint","secret-scan"]}' > "$ART/rp-result.json"
_rep="$(runner_read_stage_report "$STATE" "$PD/manifest.yaml" rp 0 2>/dev/null)"
assert_eq "[SPEC-6] failed_items" '["lint","secret-scan"]' "$(jq -c '.failed_items' <<< "$_rep" 2>/dev/null)"
assert_eq "[SPEC-6] a list is not a test count" "null" "$(jq -c '.tests' <<< "$_rep" 2>/dev/null)"

# ─── SPEC-7 ──────────────────────────────────────────────────────────────────
print_test_section "SPEC-7: the committing member is found by declaration"
PR7="$TEST_TEMP_DIR/p7"; mkdir -p "$PR7/agent/maker" "$PR7/tool/checker"
printf 'id: maker\nname: m\nkind: agent\nversion: 0.0.1\nhooks:\n  run: m\ncapabilities:\n  produces_commits: true\n' > "$PR7/agent/maker/manifest.yaml"
printf 'id: checker\nname: c\nkind: tool\nversion: 0.0.1\nhooks:\n  run: c\n' > "$PR7/tool/checker/manifest.yaml"
_CYCLE_STAGES=(checker maker)
assert_eq "[SPEC-7] the member declaring produces_commits" "maker" \
    "$(ZBUILD_PLUGINS_ROOT="$PR7" _cycle_commit_member 2>/dev/null)"
_CYCLE_STAGES=(checker)
assert_eq "[SPEC-7] none declares it → none" "" \
    "$(ZBUILD_PLUGINS_ROOT="$PR7" _cycle_commit_member 2>/dev/null)"

# ─── SPEC-8 ──────────────────────────────────────────────────────────────────
print_test_section "SPEC-8: tests failing is decided from reported counts"
printf '{"result_contract":2,"verdict":"pass","data":{"failed":0}}' > "$ART/test-results.json"
_b8='{"verify":{"verdict":"pass","report":{"tests":{"failed":3}}}}'
if _cycle_tests_failing "$_b8"; then assert_pass "[SPEC-8] a member reporting 3 failures → failing (whatever its name, whatever is on disk)"
else assert_fail "[SPEC-8] a member reporting 3 failures → failing"; fi
_b8b='{"verify":{"verdict":"fail","report":{"tests":{"failed":0}}}}'
if _cycle_tests_failing "$_b8b"; then assert_pass "[SPEC-8] a test-reporting member whose verdict is fail → failing"
else assert_fail "[SPEC-8] a test-reporting member whose verdict is fail → failing"; fi
if _cycle_tests_failing '{"x":{"verdict":"fail","report":{}}}'; then assert_fail "[SPEC-8] a member that reports no tests says nothing about tests"
else assert_pass "[SPEC-8] a member that reports no tests says nothing about tests"; fi
if _cycle_tests_reported '{"x":{"report":{}}}'; then assert_fail "[SPEC-8] no test report → none reported"
else assert_pass "[SPEC-8] no test report → none reported"; fi

# ─── SPEC-9 ──────────────────────────────────────────────────────────────────
print_test_section "SPEC-9: the banner names what the exit_when stage reported"
printf '{"failed":["stale-gate"],"reason":"stale"}' > "$ART/gate-aggregator-result.json"
_CYCLE_UNTIL_STAGE="roll-up"
_CYCLE_LAST_VERDICTS_BLOB='{"roll-up":{"verdict":"fail","report":{"failed_items":["lint"],"reason":"gates failed: lint"}}}'
_CYCLE_LAST_FAILURE_COUNT=1
_b9="$(_cycle_render_predicate_result 1 "$STATE" 2>/dev/null)"
assert_contains "[SPEC-9] names the reported failed gate" "$_b9" "failed gates: lint"
assert_eq "[SPEC-9] the stale file on disk is not read" "0" "$(grep -c stale-gate <<< "$_b9" || true)"

print_test_results
exit $((FAIL > 0))
