#!/usr/bin/env bash
# tests/unit/test-failure-detail-test.sh — a failing check's whole message is
# kept, however many lines it spans (#2460).
#
# Why: the test stage kept only the one line after a ✗. On #1805 a check printed
# "expected: 1, got: 1" with "3" on the next line — the value really was "1⏎3"
# — and the stage's findings and summary both read "expected: 1, got: 1", a
# pass. build spent long stretches of run 41489923219 on it.
#
# D1 [change] the finding for a failing file keeps the whole message of its
#             first failing check, every continued line
# D2 [change] ...any message, not only one that says expected or got
# D3 [change] ...and says how many more checks in the file failed
# D4 [change] the summary keeps each failure's whole message, its lines together
# D5 [change] assert_fail prints a message or a label that spans lines on one
#             line, its line breaks shown as ⏎
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../plugins/tool/test/plugin.sh
source "$REPO_ROOT/plugins/tool/test/plugin.sh" 2>/dev/null || true
print_test_header "a failing check's whole message is kept (#2460)"
setup_test_env "test-failure-detail"

T="$TEST_TEMP_DIR/stage"; mkdir -p "$T/tests"
RAW="$(printf '%s\n' \
    "unit: FAIL $T/tests/a-test.sh" \
    "" \
    "  section one" \
    "  ✓ T1: fine" \
    "  ✗ T4: both start at iter=1" \
    "    expected: 1, got: 1" \
    "3" \
    "  ✗ T5: output names the file" \
    "    output missing: tests/x.sh" \
    "  2 of 3 tests failed" \
    "unit: FAIL $T/tests/b-test.sh" \
    "  ✗ B1: prints the path" \
    "    output missing: /tmp/out" \
    "  1 of 1 tests failed" \
    "unit: 0/2 passed")"

_fj="$(_test_failure_findings "$RAW" "$T")"
_ra="$(jq -r '.[] | select(.file == "tests/a-test.sh") | .reason' <<< "$_fj")"
_rb="$(jq -r '.[] | select(.file == "tests/b-test.sh") | .reason' <<< "$_fj")"
assert_contains "[D1] the finding keeps the message's first line" "$_ra" "expected: 1, got: 1"
assert_contains "[D1] ...and its continued line" "$_ra" "expected: 1, got: 1 ⏎ 3"
assert_contains "[D2] any message is kept, not only expected/got" "$_rb" "output missing: /tmp/out"
assert_contains "[D3] it says how many more checks in the file failed" "$_ra" "1 more failing check"

_sum="$TEST_TEMP_DIR/summary.md"
_test_emit_failures_summary "$_sum" fail 2 1 "$RAW" 1 >/dev/null 2>&1
_s="$(cat "$_sum" 2>/dev/null)"
assert_contains "[D4] the summary keeps a failure's lines together" "$_s" "✗ T4: both start at iter=1 ⏎ expected: 1, got: 1 ⏎ 3"
assert_contains "[D4] ...for each failure" "$_s" "✗ T5: output names the file ⏎ output missing: tests/x.sh"

_out="$( (FAIL=0; TOTAL=0; FAILURES=(); assert_fail $'label one\nlabel two' $'expected: 1\ngot: 1\n3') )"
assert_contains "[D5] a label that spans lines is printed on one line" "$_out" "label one ⏎ label two"
assert_contains "[D5] ...and so is its message" "$_out" "expected: 1 ⏎ got: 1 ⏎ 3"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
