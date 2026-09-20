#!/usr/bin/env bash
# Tests (#2163): no plugin knows about another plugin — the engine derives
# obligations and permissions from declared data.
#
# SPEC-1 [change]: the STAGE SUMMARIES heading stamps RESOLVE by FAULT CLASS —
#   a failing summary whose result declares fault=specification (or scope) is
#   "context only — the engine routes this"; a failure with no fault keeps RESOLVE.
# SPEC-2 [change]: the build prompt's acceptance section names no other stage;
#   it states the paths that are read-only for THIS stage.
# SPEC-3 [change]: the spawn deny rule is rendered with an absolute path in
#   Claude Code's syntax — `Edit(//…)` — a single leading `/` is project-relative
#   and matches nothing (why the builder could edit the testfile every run).
# SPEC-4 [change]: the gate's tautology finding states the fact, not a remedy
#   addressed to someone ("passes at the baseline, so it asserts no change").
# SPEC-5 [change]: an integrity violation is restorable — test-author's record
#   keeps a copy of each authored testfile, and the build stage restores a
#   modified one from that copy before it starts (the build owns repo writes);
#   assertion-integrity's finding says so.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "stage boundaries — obligations and permissions come from data, not from naming stages (#2163)"
setup_test_env "stage-boundaries"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/ev"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"

# ─── SPEC-1: RESOLVE by fault class ──────────────────────────────────────────
print_test_section "SPEC-1: the summaries heading stamps RESOLVE by fault class"
# shellcheck disable=SC1091
source "$REPO_ROOT/core/pipeline/input-resolve.sh"
PROOT="$TEST_TEMP_DIR/plugins"; STATE="$TEST_TEMP_DIR/state"; ART="$STATE/artifacts"
mkdir -p "$PROOT/tool/sb-gate" "$PROOT/tool/sb-test" "$ART"
for g in sb-gate sb-test; do
cat > "$PROOT/tool/$g/manifest.yaml" <<EOF
id: $g
name: $g
kind: tool
version: 0.0.1
convergence: gate
hooks:
  run: ${g//-/_}_run
inputs: []
outputs:
  - id: ${g//-/_}_result
    path: \${artifact_dir}/$g-result.json
    type: json
    required: true
    primary: true
  - id: ${g//-/_}_detail
    path: \${artifact_dir}/$g-detail.txt
    type: text
    required: false
    summary: true
EOF
done
_TPL_STAGES=(sb-gate sb-test)
printf '{"schema_version":1,"run_id":"sb","stage_statuses":{"sb-gate":"failed","sb-test":"failed"},"stage_verdicts":{"sb-gate":"fail","sb-test":"fail"}}\n' > "$STATE/pipeline-state.json"
printf 'SPEC-21 passes at the baseline\n' > "$ART/sb-gate-detail.txt"
printf 'integration: TIMEOUT tests/x-test.sh\n' > "$ART/sb-test-detail.txt"
printf '{"result_contract":2,"verdict":"fail","disposition":"complete","reason":"x","fault":"specification"}\n' > "$ART/sb-gate-result.json"
printf '{"result_contract":2,"verdict":"fail","disposition":"complete","reason":"1 of 2 tests failed"}\n' > "$ART/sb-test-result.json"
_blk="$(stage_summaries_prompt_block "$STATE/pipeline-state.json" "$PROOT" 2>/dev/null || true)"
_gate_head="$(grep -E '^### sb-gate' <<< "$_blk" || true)"
_test_head="$(grep -E '^### sb-test' <<< "$_blk" || true)"
if [[ "$_gate_head" == *"RESOLVE"* ]]; then assert_fail "[SPEC-1] a failure with fault=specification is NOT a RESOLVE obligation for the reader" "$_gate_head"; else assert_pass "[SPEC-1] a failure with fault=specification is NOT a RESOLVE obligation for the reader"; fi
assert_contains "[SPEC-1] …it is framed as context the engine routes" "$_gate_head" "context only"
assert_contains "[SPEC-1] …and its body is still visible (stages see everything)" "$_blk" "SPEC-21 passes at the baseline"
assert_contains "[SPEC-1] a failure with no fault keeps RESOLVE" "$_test_head" "RESOLVE these findings"

# ─── SPEC-2: the build prompt names no other stage ───────────────────────────
print_test_section "SPEC-2: the build prompt states read-only paths, names no stage"
# shellcheck disable=SC1091
source "$REPO_ROOT/plugins/agent/build/lib/prompt.sh" 2>/dev/null || true
if declare -F _build_compose_prompt_body >/dev/null 2>&1; then
    P="$TEST_TEMP_DIR/prompt.txt"
    _build_compose_prompt_body "$P" "# task" "plan" "instructions" "" $'tests/unit/a-test.sh\ntests/unit/b-test.sh' $'SPEC-1\nSPEC-2' 1 >/dev/null 2>&1 || true
    _pt="$(cat "$P" 2>/dev/null)"
    assert_contains "[SPEC-2] the prompt states the paths are read-only for this stage" "$_pt" "read-only for this stage"
    if grep -qi 'author stage' <<< "$_pt"; then assert_fail "[SPEC-2] the prompt names no other stage" "mentions the author stage"; else assert_pass "[SPEC-2] the prompt names no other stage"; fi
    assert_contains "[SPEC-2] the listed paths are there" "$_pt" "tests/unit/b-test.sh"
    assert_contains "[SPEC-2] a failing assertion still means the code is wrong" "$_pt" "YOUR CODE is wrong"
else
    assert_fail "[SPEC-2] _build_compose_prompt_body is defined" "missing"
fi

# ─── SPEC-3: the deny rule is absolute in Claude Code's syntax ───────────────
print_test_section "SPEC-3: Edit(//abs) — a single leading slash is project-relative"
# shellcheck disable=SC1091
source "$REPO_ROOT/core/router/permissions.sh" 2>/dev/null || true
if declare -F _zbuild_build_permissions_settings >/dev/null 2>&1; then
    export ZBUILD_REPO_ROOT="$TEST_TEMP_DIR/repo"; mkdir -p "$ZBUILD_REPO_ROOT"
    export ZBUILD_PERMISSION_DENY_EDIT="$ZBUILD_REPO_ROOT/tests/a-test.sh"$'\n'
    export _ZBUILD_PERMISSIONS_SETTINGS_FILE="$TEST_TEMP_DIR/settings.json"
    _zbuild_build_permissions_settings >/dev/null 2>&1 || true
    _deny="$(jq -r '.permissions.deny[]?' "$_ZBUILD_PERMISSIONS_SETTINGS_FILE" 2>/dev/null || true)"
    assert_contains "[SPEC-3] the rule is rendered Edit(//<abs>)" "$_deny" "Edit(/$ZBUILD_REPO_ROOT/tests/a-test.sh)"
    if grep -qE "^Edit\(/[^/]" <<< "$_deny"; then assert_fail "[SPEC-3] no single-slash (project-relative) rule remains" "$_deny"; else assert_pass "[SPEC-3] no single-slash (project-relative) rule remains"; fi
    unset ZBUILD_PERMISSION_DENY_EDIT _ZBUILD_PERMISSIONS_SETTINGS_FILE
else
    assert_fail "[SPEC-3] _zbuild_build_permissions_settings is defined" "missing"
fi

# ─── SPEC-4: the gate states the finding, not the remedy ─────────────────────
print_test_section "SPEC-4: the tautology finding is a fact, not an instruction to someone"
# shellcheck disable=SC1091
source "$REPO_ROOT/plugins/agent/spec-acceptance/plugin.sh" >/dev/null 2>&1 || true
if declare -F _ag_build_reason >/dev/null 2>&1; then
    _r="$(_ag_build_reason "tautology:SPEC-21")"
    assert_contains "[SPEC-4] states the fact" "$_r" "passes at the baseline"
    if grep -q 're-author' <<< "$_r"; then assert_fail "[SPEC-4] no remedy addressed to another stage" "$_r"; else assert_pass "[SPEC-4] no remedy addressed to another stage"; fi
else
    assert_fail "[SPEC-4] _ag_build_reason is defined" "missing"
fi

# ─── SPEC-5: an integrity violation is restored, not just reported ───────────
print_test_section "SPEC-5: the authored copy is kept, and the build restores a modified testfile from it"
# shellcheck disable=SC1091
source "$REPO_ROOT/plugins/tool/assertion-integrity/plugin.sh" >/dev/null 2>&1 || true
REPO5="$TEST_TEMP_DIR/repo5"; ART5="$TEST_TEMP_DIR/art5"; mkdir -p "$REPO5/tests" "$ART5"
printf '```acceptance\nSPEC-1[change]: x\nTESTFILES:\nSPEC-1: tests/a-test.sh\n```\n' > "$ART5/design.md"
printf '#!/usr/bin/env bash\n# authored\nexit 0\n' > "$REPO5/tests/a-test.sh"
assertion_integrity_record "$ART5" "$REPO5" 2>/dev/null || true
assert_file_exists "[SPEC-5] the record keeps a copy of the authored testfile" "$ART5/authored-testfiles/tests/a-test.sh"
printf '#!/usr/bin/env bash\n# MODIFIED BY BUILD\nexit 0\n' > "$REPO5/tests/a-test.sh"
export ZBUILD_REPO_ROOT="$REPO5"
mkdir -p "$TEST_TEMP_DIR/st5"; printf '{}' > "$TEST_TEMP_DIR/st5/state.json"; ln -sfn "$ART5" "$TEST_TEMP_DIR/st5/artifacts"
assertion_integrity_run "assertion-integrity" "$TEST_TEMP_DIR/st5/state.json" >/dev/null 2>&1 || true
_ai="$(jq -r '.verdict+"|"+.reason' "$ART5/assertion-integrity-result.json" 2>/dev/null)"
assert_contains "[SPEC-5] the finding says the file will be restored and is read-only for the build stage" "$_ai" "restored"
# the build stage's pre-step restores from the copy
# shellcheck disable=SC1091
source "$REPO_ROOT/plugins/agent/build/lib/summary.sh" >/dev/null 2>&1 || true
if declare -F _build_restore_authored_testfiles >/dev/null 2>&1; then
    _n="$(_build_restore_authored_testfiles "$ART5" "$REPO5" 2>/dev/null)"
    assert_eq "[SPEC-5] the build restores the modified testfile to the authored bytes" "# authored" "$(sed -n 2p "$REPO5/tests/a-test.sh")"
    assert_eq "[SPEC-5] …and reports how many it restored" "1" "$_n"
    assert_eq "[SPEC-5] …an unmodified tree restores nothing" "0" "$(_build_restore_authored_testfiles "$ART5" "$REPO5" 2>/dev/null)"
else
    assert_fail "[SPEC-5] _build_restore_authored_testfiles is defined" "missing"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
