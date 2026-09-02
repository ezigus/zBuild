#!/usr/bin/env bash
# tests/unit/assertion-sources-test.sh — the whole assertion, not a fragment (#2034).
#
# acceptance_find_assertion_label exists for the OPERATOR readout: first match,
# trimmed to 100 chars. Judging correspondence from that is garbage-in, and it
# was measured: fed a bare `assert_pass "[SPEC-n] label"` with its `if grep -q`
# predicate stripped away, an isolated judge correctly reported "no evaluated
# condition" — describing the mutilation, not the test. The repo's dominant
# assertion shape puts ALL the meaning in that predicate.
#
#   SPEC-1 [change]: the enclosing stanza travels with the tagged line, so an
#                    `if <predicate>; then assert_pass` keeps its predicate
#   SPEC-2 [change]: every tagged assertion is returned, not only the first
#   SPEC-3 [change]: comments are stripped — pasting the SPEC sentence beside a
#                    weak assertion is the one real gaming vector
#   SPEC-4 [guard] : a '#' inside a quoted string is NOT a comment; severing
#                    there corrupts the very input being judged
#   SPEC-5 [guard] : acceptance_find_assertion_label is UNCHANGED — the operator
#                    readout and the goldens that pin it are not in scope
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/acceptance-coverage.sh
source "$REPO_ROOT/scripts/lib/acceptance-coverage.sh"

print_test_header "assertion sources: the stanza, not the fragment (#2034)"
setup_test_env "assertion-sources"
_test_cleanup_hook() { cleanup_test_env; }

R="$TEST_TEMP_DIR/repo"; mkdir -p "$R/tests"
cat > "$R/tests/sample-test.sh" <<'FIX'
#!/usr/bin/env bash
# SPEC-1 the boundary holds under load
if grep -q '"design.timeout.stub_written"' "$EVENTS" 2>/dev/null; then
    assert_pass "[SPEC-1] the event was emitted"
else
    assert_fail "[SPEC-1] the event is missing" "events: $(cat "$EVENTS")"
fi

assert_eq "[SPEC-1] the pre-#141 flat path is gone" "0" "$flat"   # SPEC-1 says the boundary holds

assert_contains "[SPEC-2] something else entirely" "$out" "other"
FIX

OUT="$(acceptance_find_assertion_sources "$R" "SPEC-1" "tests/sample-test.sh" 2>/dev/null || true)"

assert_contains "[SPEC-1][change] the enclosing predicate travels with the assertion" \
    "$OUT" 'grep -q '"'"'"design.timeout.stub_written"'"'"''
assert_contains "[SPEC-1][change] and its assert_pass arm" "$OUT" "the event was emitted"
assert_contains "[SPEC-2][change] a second tagged assertion is returned too" \
    "$OUT" "the pre-#141 flat path is gone"
assert_eq "[SPEC-2][guard] another SPEC's assertion is NOT swept in" \
    "0" "$(grep -c 'something else entirely' <<< "$OUT" || true)"
assert_eq "[SPEC-3][change] the trailing comment is stripped" \
    "0" "$(grep -c 'SPEC-1 says the boundary holds' <<< "$OUT" || true)"
assert_contains "[SPEC-4][guard] a '#' inside quotes is not treated as a comment" \
    "$OUT" "pre-#141 flat path"

# The operator readout is a different job and stays exactly as it was.
LBL="$(acceptance_find_assertion_label "$R" "SPEC-1" "tests/sample-test.sh" 2>/dev/null || true)"
assert_contains "[SPEC-5][guard] the label helper still returns its single line" \
    "$LBL" "the event was emitted"
# One line, no embedded newline. `wc -l` counts terminators, not lines, so a
# single unterminated line is 0 — asserting "1" here tested the harness.
assert_eq "[SPEC-5][guard] and still only ONE line, unlike the sources helper" \
    "0" "$(printf '%s' "$LBL" | grep -c '^' | tr -d ' ' | awk '{print $1-1}')"

print_test_results
exit $((FAIL > 0))
