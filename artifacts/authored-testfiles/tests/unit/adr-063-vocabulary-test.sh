#!/usr/bin/env bash
# tests/unit/adr-063-vocabulary-test.sh — ADR-063 status is Accepted and the
# document carries no prescriptive use of the retired vocabulary (#2032, #2187).
#
# [#2032/SPEC-7]: docs/adr/ADR-063-budget-disclosure-and-partial-output.md
# status header reads "Accepted" and contains no prescriptive use of `exhausted`
# as the §3 disposition word or `escalate` as the §4 engine action — vocabulary
# is updated to timed_out/out_of_turns per #2187.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "ADR-063 vocabulary updated to timed_out/out_of_turns (#2032)"
setup_test_env "adr-063-vocabulary"

ADR="$REPO_ROOT/docs/adr/ADR-063-budget-disclosure-and-partial-output.md"
assert_file_exists "[#2032/SPEC-7] ADR-063 exists" "$ADR"

# ── status is Accepted ────────────────────────────────────────────────────────
if grep -q '\*\*Status:\*\* Accepted' "$ADR" 2>/dev/null; then
    assert_pass "[#2032/SPEC-7] ADR-063 status is Accepted"
else
    assert_fail "[#2032/SPEC-7] ADR-063 status is Accepted" \
        "status header does not read Accepted — still Proposed or another word"
fi

# ── no prescriptive `exhausted` as §3 disposition word ───────────────────────
# §3's prescription must not name `exhausted` — the retired word (#2187).
# The amendment updates it to timed_out/out_of_turns. The pattern matches the
# prescriptive phrase `disposition: exhausted` that appears in both the §0 table
# and the §3 heading — both must be updated.
if grep -qE 'disposition: *exhausted' "$ADR" 2>/dev/null; then
    assert_fail "[#2032/SPEC-7] ADR-063 §3 contains no prescriptive 'disposition: exhausted'" \
        "phrase 'disposition: exhausted' still present — §3 heading and §0 table need updating"
else
    assert_pass "[#2032/SPEC-7] ADR-063 §3 contains no prescriptive 'disposition: exhausted'"
fi

# ── no `exhausted → escalate` as §4 engine action ────────────────────────────
# The §4 `exhausted → escalate` prescription is stricken by the amendment; the
# retry table in ADR-029 replaces it. The compound phrase must be absent.
if grep -qE 'exhausted[[:space:]]*→[[:space:]]*escalate' "$ADR" 2>/dev/null; then
    assert_fail "[#2032/SPEC-7] ADR-063 §4 contains no 'exhausted → escalate' engine action" \
        "phrase 'exhausted → escalate' still present — §4 bullet must be stricken"
else
    assert_pass "[#2032/SPEC-7] ADR-063 §4 contains no 'exhausted → escalate' engine action"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
