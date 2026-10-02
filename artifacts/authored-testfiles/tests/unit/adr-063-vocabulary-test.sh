#!/usr/bin/env bash
# tests/unit/adr-063-vocabulary-test.sh
#
# Issue #2032 — ADR-063 status and vocabulary amendment.
#
# ADR-063 was "Proposed" and prescribed `exhausted` as the §3 disposition word
# and `escalate` as the §4 engine action. Both are retired vocabulary: #2187
# replaced them with timed_out/out_of_turns (router_reason_disposition words).
# The ADR is amended to "Accepted" and the prescriptive uses are removed.
#
#   SPEC-7 [change]: status header reads "Accepted" and the document contains
#                    no prescriptive use of `exhausted` as the §3 disposition
#                    word or `escalate` as the §4 engine action — vocabulary
#                    updated to timed_out/out_of_turns per #2187.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "ADR-063 vocabulary amendment: Accepted, retired exhausted/escalate (#2032)"
setup_test_env "adr-063-vocabulary"

ADR="$REPO_ROOT/docs/adr/ADR-063-budget-disclosure-and-partial-output.md"

# ── SPEC-7: file exists ────────────────────────────────────────────────────────
assert_file_exists "[#2032/SPEC-7] ADR-063 exists" "$ADR"

# ── SPEC-7: status line is Accepted ───────────────────────────────────────────
_status_line="$(grep -m1 -E '^\*\*Status:\*\*' "$ADR" 2>/dev/null || true)"
if grep -qE '\bAccepted\b' <<< "$_status_line"; then
    assert_pass "[#2032/SPEC-7] ADR-063 status header reads Accepted"
else
    assert_fail "[#2032/SPEC-7] ADR-063 status header must read Accepted" \
        "got: ${_status_line:-missing}"
fi

# ── SPEC-7: no prescriptive `exhausted` as the §3 disposition word ────────────
# The old §3 section prescribed: "Partial is signalled as `disposition: exhausted`"
# This exact form — `disposition: exhausted` — is the §3 prescription. After
# amendment the word is timed_out or out_of_turns (router_reason_disposition).
if grep -qF 'disposition: exhausted' "$ADR" 2>/dev/null; then
    assert_fail "[#2032/SPEC-7] §3 must not prescribe 'disposition: exhausted' (retired — timed_out/out_of_turns per #2187)" \
        "found prescriptive 'disposition: exhausted'"
else
    assert_pass "[#2032/SPEC-7] §3 does not prescribe 'disposition: exhausted' (retired word removed)"
fi

# ── SPEC-7: no `escalate` as the §4 engine action ────────────────────────────
# The old §4 prescribed: "`exhausted → escalate` already routes to …"
# After amendment this escalation branch is stricken; the retry table in ADR-029
# replaces it. Assert the exact `exhausted → escalate` prescription is gone.
if grep -qF 'exhausted → escalate' "$ADR" 2>/dev/null; then
    assert_fail "[#2032/SPEC-7] §4 must not prescribe 'exhausted → escalate' (retired action — ADR-029 retry table)" \
        "found 'exhausted → escalate'"
else
    assert_pass "[#2032/SPEC-7] §4 does not prescribe 'exhausted → escalate' (action stricken)"
fi

# ── SPEC-7: updated vocabulary timed_out/out_of_turns is present ─────────────
# The amendment adds a back-pointer to #2187 and uses the new words; at least
# one of them must appear to confirm the replacement text was written.
if grep -qE '\btimed_out\b|\bout_of_turns\b' "$ADR" 2>/dev/null; then
    assert_pass "[#2032/SPEC-7] ADR-063 contains updated vocabulary (timed_out or out_of_turns per #2187)"
else
    assert_fail "[#2032/SPEC-7] ADR-063 must contain updated vocabulary (timed_out/out_of_turns)" \
        "neither timed_out nor out_of_turns found"
fi

# ── SPEC-8: §1 uses per-stage budget-guidance helpers language ────────────────
# The old §1 baseline said "One helper renders the budget block." After the
# amendment each stage has its own _<stage>_budget_guidance helper that reads
# the enforcing values. Assert the per-stage language is present and the old
# single-helper baseline is absent.
if grep -qF 'One helper renders the budget block' "$ADR" 2>/dev/null; then
    assert_fail "[#2032/SPEC-8] §1 must not contain 'One helper renders the budget block' (replaced by per-stage helpers)" \
        "found old single-helper language"
else
    assert_pass "[#2032/SPEC-8] §1 does not contain the old single-helper language"
fi

if grep -qE '_[a-z_]+_budget_guidance' "$ADR" 2>/dev/null; then
    assert_pass "[#2032/SPEC-8] ADR-063 §1 contains per-stage _<stage>_budget_guidance helper language"
else
    assert_fail "[#2032/SPEC-8] ADR-063 §1 must contain per-stage _<stage>_budget_guidance helper language" \
        "no _<stage>_budget_guidance pattern found"
fi

# ── SPEC-9: amendment back-pointer explicitly names #2187 ─────────────────────
if grep -qF '#2187' "$ADR" 2>/dev/null; then
    assert_pass "[#2032/SPEC-9] ADR-063 contains amendment back-pointer to #2187"
else
    assert_fail "[#2032/SPEC-9] ADR-063 must contain an amendment back-pointer that explicitly names #2187 (the issue that retired exhausted/escalate vocabulary)" \
        "#2187 not found in the document"
fi

print_test_results
exit $((FAIL > 0))
