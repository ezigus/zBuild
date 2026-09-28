#!/usr/bin/env bash
# Tests: issue #1208 Change 7 — repo-declarable test-count contract (parse.sh).
#
# SPEC-7: a repo declares its granular pass/fail counts via a first-priority
# source so the progress/failure signal is repo-agnostic (iOS/Swift, not just the
# built-in JS/Py/Go/Rust recognizer bank):
#   (a) ZBUILD_TEST_RESULTS_JSON — a {passed,failed,total,skipped?} file the test
#       command wrote; parsed FIRST, before the recognizer bank.
#   (b) ZBUILD_TEST_COUNT_CMD — a command that emits that JSON on stdout.
#   (c) neither set + unrecognized runner → summary_unavailable (fail-safe;
#       NEVER fabricate counts).
#   (d) recognized runners (jest/pytest/…) still parse via the bank when no
#       contract is declared (bank stays the out-of-box default).
# SPEC-8 (repo-agnostic): a faux-xcodebuild raw output the bank cannot recognize
#       yields honest declared counts through the contract — no zbuild/JS/Py
#       token needed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "test count contract — repo-declarable pass/fail source (#1208)"
setup_test_env "test-declared-count-contract-1208"

# shellcheck disable=SC1090
source "$REPO_ROOT/plugins/tool/test/lib/parse.sh"

# Faux-xcodebuild output the built-in recognizer bank cannot parse (no jest/
# pytest/go/cargo/mocha/runall anchor).
FAUX_XCODE=$'Test Suite '\''AppTests.xctest'\'' started\nTest Case '\''-[AppTests testFoo]'\'' passed (0.01 seconds).\nTest Case '\''-[AppTests testBar]'\'' failed (0.02 seconds).\n** TEST FAILED **'

_field() { printf '%s' "$1" | cut -d'|' -f"$2"; }

# ─── SPEC-7(c): unrecognized runner, no contract → summary_unavailable ───────
print_test_section "SPEC-7c: unrecognized runner + no contract → fail-safe (recognized=0)"
unset ZBUILD_TEST_RESULTS_JSON ZBUILD_TEST_COUNT_CMD 2>/dev/null || true
out="$(_test_parse_summary "$FAUX_XCODE" 1)"
assert_eq "[SPEC-7c] verdict=error (fail-safe)" "error" "$(_field "$out" 1)"
assert_eq "[SPEC-7c] recognized=0 (bank did not recognize)" "0" "$(_field "$out" 5)"

# ─── SPEC-7(a) + SPEC-8: ZBUILD_TEST_RESULTS_JSON declared → parsed FIRST ────
print_test_section "SPEC-7a/8: ZBUILD_TEST_RESULTS_JSON → honest declared counts (faux-iOS)"
RJSON="$TEST_TEMP_DIR/results.json"
printf '{"passed":41,"failed":2,"total":43,"skipped":0}' > "$RJSON"
export ZBUILD_TEST_RESULTS_JSON="$RJSON"
out="$(_test_parse_summary "$FAUX_XCODE" 1)"
assert_eq "[SPEC-7a] verdict=fail (declared failed=2)" "fail" "$(_field "$out" 1)"
assert_eq "[SPEC-7a] passed=41 from declared source" "41" "$(_field "$out" 2)"
assert_eq "[SPEC-7a] failed=2 from declared source" "2" "$(_field "$out" 3)"
assert_eq "[SPEC-7a] recognized=1 (contract honored)" "1" "$(_field "$out" 5)"

# All-green declared → verdict=pass even with rc=0.
printf '{"passed":43,"failed":0,"total":43}' > "$RJSON"
out="$(_test_parse_summary "$FAUX_XCODE" 0)"
assert_eq "[SPEC-7a] all-green declared → verdict=pass" "pass" "$(_field "$out" 1)"
assert_eq "[SPEC-7a] failed=0" "0" "$(_field "$out" 3)"
unset ZBUILD_TEST_RESULTS_JSON

# ─── SPEC-7(b): ZBUILD_TEST_COUNT_CMD emits the JSON ─────────────────────────
print_test_section "SPEC-7b: ZBUILD_TEST_COUNT_CMD → command emits {passed,failed,total}"
export ZBUILD_TEST_COUNT_CMD='printf "{\"passed\":10,\"failed\":1,\"total\":11}"'
out="$(_test_parse_summary "$FAUX_XCODE" 1)"
assert_eq "[SPEC-7b] verdict=fail (declared failed=1)" "fail" "$(_field "$out" 1)"
assert_eq "[SPEC-7b] passed=10 from command" "10" "$(_field "$out" 2)"
assert_eq "[SPEC-7b] failed=1 from command" "1" "$(_field "$out" 3)"
assert_eq "[SPEC-7b] recognized=1" "1" "$(_field "$out" 5)"
unset ZBUILD_TEST_COUNT_CMD

# ─── SPEC-7(d): recognized runner still parses via the bank (no contract) ────
print_test_section "SPEC-7d: bank still parses recognized runner when no contract set"
unset ZBUILD_TEST_RESULTS_JSON ZBUILD_TEST_COUNT_CMD 2>/dev/null || true
JEST=$'Tests:       2 failed, 18 passed, 20 total'
out="$(_test_parse_summary "$JEST" 1)"
assert_eq "[SPEC-7d] jest verdict=fail via bank" "fail" "$(_field "$out" 1)"
assert_eq "[SPEC-7d] jest passed=18 via bank" "18" "$(_field "$out" 2)"
assert_eq "[SPEC-7d] jest failed=2 via bank" "2" "$(_field "$out" 3)"
assert_eq "[SPEC-7d] recognized=1 via bank" "1" "$(_field "$out" 5)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
