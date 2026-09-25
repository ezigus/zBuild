#!/usr/bin/env bash
# Tests (#2189 part C): engine setup reads what stages REPORTED, never plan.json
# or design.md by path, and never a role name (ADR-055 §1, ADR-050 §1).
#
# SPEC-1 [change]: the member report carries scope_files, owned_files and
#   wiring_files when the result declares them.
# SPEC-2 [change]: each dispatch's report is merged into the run's record
#   (artifacts/stage-reports.json): scope/wiring files unioned, owned files kept
#   per reporting stage.
# SPEC-3 [change]: the redaction allowlist is the reported scope files — a stale
#   plan.json on disk is not read.
# SPEC-4 [change]: "this run changes its own grader" is decided from the reported
#   wiring files — design.md is not read.
# SPEC-5 [change]: a stage is denied edits to files ANOTHER stage reported owning,
#   and never its own — no role name is consulted.
# SPEC-6 [change]: the stages report them — plan its scope files (in plan.json),
#   design its WIRING files, test-author the testfiles it owns.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "engine setup reads stage reports, not plan.json / design.md (#2189)"
setup_test_env "engine-stage-reports"
_test_cleanup_hook() { cleanup_test_env; }

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/ev"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="/dev/null"
# shellcheck source=../../core/pipeline/runner.sh
source "$REPO_ROOT/core/pipeline/runner.sh"
# shellcheck source=../../core/plugin-registry/lifecycle.sh
source "$REPO_ROOT/core/plugin-registry/lifecycle.sh" 2>/dev/null
set +e

STATE="$TEST_TEMP_DIR/state"; ART="$STATE/artifacts"; mkdir -p "$ART"

print_test_section "SPEC-1: the report carries the setup fields"
printf '%s' '{"result_contract":2,"verdict":"pass","disposition":"complete","reason":"r","data":{"scope_files":["a.sh"],"owned_files":["tests/t.sh"],"wiring_files":["scripts/lib/x.sh"]}}' > "$ART/r.json"
_r="$(_verdict_report_from_file "$ART/r.json")"
assert_eq "[SPEC-1] scope_files" '["a.sh"]' "$(jq -c '.scope_files' <<< "$_r")"
assert_eq "[SPEC-1] owned_files" '["tests/t.sh"]' "$(jq -c '.owned_files' <<< "$_r")"
assert_eq "[SPEC-1] wiring_files" '["scripts/lib/x.sh"]' "$(jq -c '.wiring_files' <<< "$_r")"

print_test_section "SPEC-2: reports merge into the run's record"
_runner_record_report "$STATE" plan '{"scope_files":["a.sh","b.sh"]}'
_runner_record_report "$STATE" design '{"scope_files":["b.sh","c.sh"],"wiring_files":["scripts/lib/x.sh"]}'
_runner_record_report "$STATE" author '{"owned_files":["tests/t.sh"]}'
_rec="$ART/stage-reports.json"
assert_eq "[SPEC-2] scope files unioned" '["a.sh","b.sh","c.sh"]' "$(jq -c '.scope_files' "$_rec" 2>/dev/null)"
assert_eq "[SPEC-2] owned files kept per stage" '["tests/t.sh"]' "$(jq -c '.owned_files.author' "$_rec" 2>/dev/null)"
assert_eq "[SPEC-2] wiring files unioned" '["scripts/lib/x.sh"]' "$(jq -c '.wiring_files' "$_rec" 2>/dev/null)"

print_test_section "SPEC-3: the redaction allowlist is the reported scope"
printf '%s' '{"files":["stale.sh"],"steps":[]}' > "$ART/plan.json"
unset ZBUILD_SCOPE_ALLOWLIST
_runner_export_scope_allowlist "$STATE"
assert_eq "[SPEC-3] allowlist = reported scope files, plan.json not read" "a.sh,b.sh,c.sh" "${ZBUILD_SCOPE_ALLOWLIST:-}"

print_test_section "SPEC-4: self-grade detection from reported wiring"
LIB="$TEST_TEMP_DIR/lib"; mkdir -p "$LIB"; : > "$LIB/x.sh"
_runner_contract_lib_closure() { printf 'x.sh\n'; }
printf '%s\n' '```acceptance' 'WIRING: scripts/lib/unrelated.sh' '```' > "$ART/design.md"
assert_eq "[SPEC-4] a reported wiring file in the grader set is a hit" "scripts/lib/x.sh" \
    "$(_runner_design_targets_contract_lib "$STATE" "$LIB" 2>/dev/null)"

print_test_section "SPEC-5: ownership denies others, never the owner"
export ZBUILD_REPO_ROOT="/repo"
assert_eq "[SPEC-5] another stage is denied the owned file" "/repo/tests/t.sh" \
    "$(_lc_owned_by_others_deny "$STATE" build 2>/dev/null)"
assert_eq "[SPEC-5] the owner is not denied its own file" "" \
    "$(_lc_owned_by_others_deny "$STATE" author 2>/dev/null)"


print_test_section "SPEC-6: the stages report the fields"
S6="$TEST_TEMP_DIR/s6"; mkdir -p "$S6"
printf '%s\n' '# D' '```acceptance' 'SPEC-1[change]: x' 'TESTFILES:' 'SPEC-1: tests/acc-test.sh' 'WIRING: scripts/lib/wired.sh' '```' > "$S6/design.md"
_d6="$( source "$REPO_ROOT/plugins/agent/design/plugin.sh" >/dev/null 2>&1
        _design_write_result "$S6" pass complete "ok" >/dev/null 2>&1
        jq -c '.data.wiring_files' "$S6/design-verdict.json" 2>/dev/null )"
assert_eq "[SPEC-6] design reports its WIRING files" '["scripts/lib/wired.sh"]' "$_d6"
_t6="$( source "$REPO_ROOT/plugins/agent/test-author/plugin.sh" >/dev/null 2>&1
        _ta_write_result "$S6" complete complete "ok" 1 >/dev/null 2>&1
        jq -c '.data.owned_files' "$S6/test-author-result.json" 2>/dev/null )"
assert_eq "[SPEC-6] test-author reports the testfiles it owns" '["tests/acc-test.sh"]' "$_t6"
_p6="$( source "$REPO_ROOT/plugins/agent/plan/plugin.sh" >/dev/null 2>&1
        _plan_with_scope_files '{"files":["a.sh"],"steps":[{"files":["b.sh","a.sh"]}]}' 2>/dev/null | jq -c '.scope_files' )"
assert_eq "[SPEC-6] plan.json carries its scope files" '["a.sh","b.sh"]' "$_p6"

print_test_results
exit $((FAIL > 0))
