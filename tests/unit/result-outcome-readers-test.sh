#!/usr/bin/env bash
# tests/unit/result-outcome-readers-test.sh — every reader of a result sees a
# contract-3 outcome (#2366, ADR-054 §6).
#
# Until #2364 and #2368 remove them, a few stages read other results' verdicts.
# A stage that moves to contract 3 writes `outcome`, not `verdict`, so each of
# those readers must read the outcome first or it misreads the moved stage.
#
#   R1 [change] gate-aggregator reads a member's contract-3 pass and fail
#   R2 [change] gate-aggregator counts a member that did not finish as failed
#   R3 [guard]  no stage reads `.verdict` from a result without `.outcome`
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "every reader of a result sees a contract-3 outcome (#2366)"
setup_test_env "result-outcome-readers"
# shellcheck source=../../scripts/lib/stage-result.sh
source "$REPO_ROOT/scripts/lib/stage-result.sh"
# shellcheck source=../../plugins/tool/gate-aggregator/plugin.sh
source "$REPO_ROOT/plugins/tool/gate-aggregator/plugin.sh" >/dev/null 2>&1

R="$TEST_TEMP_DIR/member-result.json"

print_test_section "R1/R2: gate-aggregator"
stage_result_write "$R" pass "ok" >/dev/null 2>&1
assert_eq "[R1] a contract-3 pass satisfies the gate" "pass" "$(_ga_read_gate_verdict "$R" 2>/dev/null)"
stage_result_write "$R" fail "2 tests fail" >/dev/null 2>&1
assert_eq "[R1] a contract-3 fail blocks" "fail" "$(_ga_read_gate_verdict "$R" 2>/dev/null)"
stage_result_write "$R" timed_out "the call timed out" >/dev/null 2>&1
_r2="$(_ga_read_gate_verdict "$R" 2>/dev/null)"
if [[ "$_r2" == pass || "$_r2" == skip || "$_r2" == advisory ]]; then
    assert_fail "[R2] a member that did not finish does not satisfy the gate" "got $_r2"
else
    assert_pass "[R2] a member that did not finish does not satisfy the gate"
fi

print_test_section "R3: no reader of .verdict without .outcome"
# A stage model's own reply may carry a `verdict` key (monitor's report); that
# is the model's answer, not a result, and is exempt by its line.
_bad="$(cd "$REPO_ROOT" && /usr/bin/grep -rnE "jq[^|]*'[^']*\.verdict\b" plugins --include='*.sh' \
        | /usr/bin/grep -v '/tests/' | /usr/bin/grep -v '\.outcome' \
        | /usr/bin/grep -v 'schema_version == 1 and (.verdict|type=="string")' \
        | /usr/bin/grep -v 'report_json' || true)"
assert_eq "[R3] every .verdict read also reads .outcome" "" "$_bad"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
