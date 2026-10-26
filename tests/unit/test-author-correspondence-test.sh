#!/usr/bin/env bash
# tests/unit/test-author-correspondence-test.sh — test-author's check that each
# assertion tests what its SPEC SAYS (#2034; #2370 moved it from the
# spec-correspondence stage into test-author).
#
# A passing test proves the implementation satisfies the ASSERTION, never that
# the assertion satisfies the SENTENCE. Measured before it was built: a
# three-word vocabulary called 6/15 merged pairs `mismatch` because it had
# nowhere to put "the right property, narrower than promised"; `partial` took
# false mismatches to 0/15. The vocabulary was the defect.
#
#   SPEC-1 the prompt carries the requirement TEXT and the assertion source
#   SPEC-2 and NO implementation (no diff, no build summary)
#   SPEC-3 `partial` is in the vocabulary, and a partial assertion is a finding
#   SPEC-7/8 junk replies are never a pass: the outcome is unusable (#2062)
#   #2108 a model that drains stdin still leaves every SPEC judged
#   #2143 every SPEC is judged in ONE call when the reply answers each
#   #2032 a failed call is classified; a later success never hides it
#   A SPEC with no tagged assertion is not judged (the acceptance check reports it)
#   W1 the judge sees the whole test the assertion is in — its setup too, even
#      when a blank line separates them — with the tagged lines marked (#1944
#      run 40329284881: the check saw only the assertion's stanza and called it
#      partial for what its setup established)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "test-author: the assertion vs the sentence (#2034, #2370)"
setup_test_env "test-author-correspondence"

# shellcheck source=../../plugins/agent/test-author/plugin.sh
source "$REPO_ROOT/plugins/agent/test-author/plugin.sh"

# Stubbed AFTER the plugin loads: it sources core/router/route.sh itself.
_P_FILE="$TEST_TEMP_DIR/prompt.txt"; _CALLS="$TEST_TEMP_DIR/calls"
_REPLY='VERDICT: corresponds
REASON: the assertion checks exactly the property the requirement names'
route_to_model() { cat >/dev/null; printf 'x\n' >> "$_CALLS"; printf '%s' "$2" >> "$_P_FILE"; printf '%s' "$_REPLY"; return 0; }

R="$TEST_TEMP_DIR/repo"; mkdir -p "$R/tests"; D="$TEST_TEMP_DIR/design.md"
_contract() {   # _contract <n> — SPEC-1..n, each with a tagged assertion
    local i; : > "$R/tests/acc-test.sh"
    { printf '# Design\n```acceptance\n'
      for (( i = 1; i <= $1; i++ )); do printf 'SPEC-%s[code]: thing %s holds\n' "$i" "$i"; done
      printf 'WIRING: none\nTESTFILES:\n'
      for (( i = 1; i <= $1; i++ )); do printf 'SPEC-%s: tests/acc-test.sh\n' "$i"; done
      printf '```\n'; } > "$D"
    for (( i = 1; i <= $1; i++ )); do
        printf 'assert_eq "[SPEC-%s] thing %s holds" "1" "$got"\n' "$i" "$i" >> "$R/tests/acc-test.sh"
    done
}
_judge() { : > "$_CALLS"; : > "$_P_FILE"; _ta_correspondence "$D" "$R" T2 >/dev/null 2>&1; }

# ── W1 ───────────────────────────────────────────────────────────────────────
_contract 1
cat > "$R/tests/acc-test.sh" <<'SH'
got="$(thing_under_test --empty; echo $?)"
wait_past_limit 5

assert_eq "[SPEC-1] thing 1 holds" "1" "$got"
SH
_judge
_P="$(cat "$_P_FILE")"
assert_contains "[W1] the judge sees the test's setup" "$_P" 'thing_under_test --empty'
assert_contains "[W1] ...all of it" "$_P" 'wait_past_limit 5'
assert_contains "[W1] ...and the tagged assertion, marked" "$_P" '>> assert_eq "[SPEC-1] thing 1 holds"'
assert_contains "[W1] the prompt says what the marks are" "$(tr -s '[:space:]' ' ' <<< "$_P")" \
    "the lines marked >> are the ones tagged for the requirement; the lines above them set up the test"

# ── SPEC-1 / SPEC-2 / SPEC-3 ────────────────────────────────────────────────
_contract 1
_judge
_P="$(cat "$_P_FILE")"
assert_contains "[SPEC-1] the prompt carries the requirement TEXT" "$_P" "thing 1 holds"
assert_contains "[SPEC-1] and the assertion source" "$_P" '"[SPEC-1] thing 1 holds"'
assert_eq "[SPEC-2] the prompt carries NO diff" "0" "$(grep -c 'diff --git' <<< "$_P" || true)"
assert_contains "[SPEC-3] partial is offered as a verdict" "$_P" "partial"
assert_eq "[SPEC-2] a corresponding assertion: no finding" "0" "${#_TA_CORR_FINDINGS[@]}"
assert_eq "[SPEC-2] ...and the check was judged" "" "$_TA_CORR_OUTCOME"

# ── #2143 / SPEC-3 ──────────────────────────────────────────────────────────
_contract 3
_REPLY='SPEC-1: VERDICT: corresponds | REASON: exactly the property
SPEC-2: VERDICT: partial | REASON: one case of several
SPEC-3: VERDICT: corresponds | REASON: exactly the property'
_judge
assert_eq "[#2143] all 3 SPECs are judged in ONE model call" "1" "$(wc -l < "$_CALLS" | tr -d ' ')"
for _id in SPEC-1 SPEC-2 SPEC-3; do
    assert_contains "[#2143] the batch prompt carries $_id as a heading" "$(cat "$_P_FILE")" "### $_id"
done
assert_eq "[SPEC-3] a partial assertion is one finding" "1" "${#_TA_CORR_FINDINGS[@]}"
assert_contains "[SPEC-3] ...naming the SPEC and why" "${_TA_CORR_FINDINGS[0]:-}" "SPEC-2's assertion establishes only part of the requirement: one case of several"

# ── #2108: a stdin-draining model still leaves every SPEC judged ────────────
_REPLY='VERDICT: corresponds
REASON: the property'
_judge
assert_eq "[#2108] 1 batch + 3 fallback calls, every SPEC judged" "4" "$(wc -l < "$_CALLS" | tr -d ' ')"
assert_eq "[#2108] ...and judged clean" "0|" "${#_TA_CORR_FINDINGS[@]}|$_TA_CORR_OUTCOME"

# ── SPEC-7/8: junk replies are never a pass ─────────────────────────────────
route_to_model() { cat >/dev/null; printf 'I am afraid I cannot help with that.'; return 0; }
_judge
assert_eq "[SPEC-8] zero judgments is not a pass: unusable" "unusable" "$_TA_CORR_OUTCOME"
assert_eq "[SPEC-8] ...and the word is on the engine's outcome list" "0" \
    "$( source "$REPO_ROOT/core/pipeline/verdict.sh" >/dev/null 2>&1; outcome_is_valid "$_TA_CORR_OUTCOME"; echo $?)"

# ── #2032: a failed call is classified ──────────────────────────────────────
_contract 1
route_to_model() { cat >/dev/null; return 1; }
_judge
assert_eq "[#2032] rc=1 → unavailable" "unavailable" "$_TA_CORR_OUTCOME"
route_to_model() { cat >/dev/null; return 124; }
_judge
assert_eq "[#2032] rc=124 → timed_out" "timed_out" "$_TA_CORR_OUTCOME"
route_to_model() {
    cat >/dev/null; printf 'x\n' >> "$_CALLS"
    [[ "$(wc -l < "$_CALLS" | tr -d ' ')" -eq 1 ]] && return 124
    printf 'VERDICT: corresponds\nREASON: the assertion checks the SPEC'; return 0
}
_judge
assert_eq "[#2032] the batch timed out and the fallback succeeded: still timed_out" "timed_out" "$_TA_CORR_OUTCOME"

# ── a SPEC with no tagged assertion is not judged (as before #2370) ─────────
_contract 1; : > "$R/tests/acc-test.sh"
route_to_model() { cat >/dev/null; printf 'x\n' >> "$_CALLS"; printf '%s' "$_REPLY"; return 0; }
_judge
assert_eq "a SPEC with no tagged assertion is not judged: no call, no finding" "0|0" \
    "$(wc -l < "$_CALLS" | tr -d ' ')|${#_TA_CORR_FINDINGS[@]}"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
