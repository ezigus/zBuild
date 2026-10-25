#!/usr/bin/env bash
# tests/unit/result-read-memo-test.sh — a stage's result is parsed once per
# change, however many readers ask (ADR-054 §5; ADR-065 §5).
#
# After every dispatch the runner asks five or six readers about the result —
# verdict, raw verdict, reason, disposition, report, build kind — each in its
# own $( ), each parsing the file again: 306 jq in one three-run pipeline test.
# The runner now reads the result once in its own shell; the readers it starts
# after that inherit the parse, and use it while a mark made before the parse is
# strictly newer than the file.
#
# R1 [change] once read in the calling shell, the six readers start one jq
#             between them (the report's own extraction)
# R2 [guard]  …and say what the result says
# R3 [guard]  rewritten straight after it was read (no pause): every reader
#             says what the new result says
# R4 [guard]  broken straight after it was read: the malformed violation, as
#             before
# R5 [change] the build kind comes from the same parse, for each shape of data
# R6 [change] each of the runner's three post-dispatch blocks reads the result
#             in its own shell before its readers
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/pipeline/verdict.sh
source "$REPO_ROOT/core/pipeline/verdict.sh"
# shellcheck source=../../scripts/lib/stage-result.sh
source "$REPO_ROOT/scripts/lib/stage-result.sh"

print_test_header "stage result: one parse per change (ADR-054 §5)"
setup_test_env "result-read-memo"

SD="$TEST_TEMP_DIR/state"; mkdir -p "$SD/artifacts" "$SD/runtime"
MF="$TEST_TEMP_DIR/manifest.yaml"
cat > "$MF" <<'EOF'
id: rr
kind: agent
outputs:
  - id: rr_result
    path: ${artifact_dir}/rr.json
    primary: true
EOF
RES="$SD/artifacts/rr.json"
CALLS="$TEST_TEMP_DIR/calls"
jq() { printf 'jq\n' >> "$CALLS"; command jq "$@"; }
jqs() { local c; c="$(grep -c '^jq$' "$CALLS" 2>/dev/null)"; printf '%s' "${c:-0}"; }
# All six, as the runner asks them, one $( ) each.
readers() {
    printf '%s|%s|%s|%s|%s|%s' \
        "$(runner_read_stage_verdict "$SD" "$MF" rr 0 2>/dev/null)" \
        "$(runner_read_stage_verdict_raw "$SD" "$MF" rr 0 2>/dev/null)" \
        "$(runner_read_stage_reason "$SD" "$MF" rr 0 2>/dev/null)" \
        "$(runner_read_stage_disposition "$SD" "$MF" rr 0 "" 0 2>/dev/null)" \
        "$(runner_read_stage_report "$SD" "$MF" rr 0 2>/dev/null | command jq -r '.reason // ""')" \
        "$(runner_read_stage_data_kind "$SD" "$MF" rr 2>/dev/null)"
}
read_here() { local _h_state _h_contract _h_verdict _h_disp _h_reason _h_viol _h_path _h_present _h_kind
    _verdict_read_result "$SD" "$MF" rr 0 _h; _HERE_VIOL="$_h_viol"; }

print_test_section "R1/R2: six readers after one read"
stage_result_write "$RES" pass "all good" '{"build_kind":"docs"}'
read_here
: > "$CALLS"
_got="$(readers)"
assert_eq "[R1] one jq between the six (the report's)" "1" "$(jqs)"
assert_eq "[R2] they say what the result says" "pass|pass|all good|complete|all good|docs" "$_got"

print_test_section "R3: rewritten at once"
read_here
stage_result_write "$RES" fail "now broken tests" '{"build_kind":"code"}'
assert_eq "[R3] every reader sees the new result" "fail|fail|now broken tests|complete|now broken tests|code" "$(readers)"

print_test_section "R4: broken at once"
read_here
printf '{"outcome":' > "$RES"
read_here
assert_eq "[R4] the malformed violation" "contract_violation:malformed_json" "$_HERE_VIOL"

print_test_section "R5: the build kind"
_kinds=""
for _d in '{"build_kind":"docs"}' '{}' '{"build_kind":3}' '{"build_kind":null}' '{"build_kind":false}'; do
    stage_result_write "$RES" pass "r" "$_d"
    _kinds+="[$(runner_read_stage_data_kind "$SD" "$MF" rr 2>/dev/null)]"
done
printf '{"result_contract":3,"outcome":"pass","reason":"r","data":"flat"}\n' > "$RES"
_kinds+="[$(runner_read_stage_data_kind "$SD" "$MF" rr 2>/dev/null)]"
assert_eq "[R5] string, none, number, null, false, data not an object" "[docs][][3][][][]" "$_kinds"
: > "$CALLS"
runner_read_stage_data_kind "$SD" "$MF" rr >/dev/null 2>&1
assert_eq "[R5] …read in the one parse" "1" "$(jqs)"
unset -f jq

print_test_section "R6: the runner reads first"
RUNNER="$REPO_ROOT/core/pipeline/runner.sh"
_sites=0; _primed=0
while IFS= read -r _ln; do
    _sites=$((_sites + 1))
    _before="$(sed -n "$(( _ln > 12 ? _ln - 12 : 1 )),$(( _ln - 1 ))p" "$RUNNER")"
    grep -q '^[[:space:]]*_verdict_read_result ' <<< "$_before" && _primed=$((_primed + 1))
done < <(grep -n '="$(runner_read_stage_verdict "' "$RUNNER" | cut -d: -f1)
assert_eq "[R6] each of the three blocks reads the result in its own shell first" "3 3" "$_sites $_primed"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
