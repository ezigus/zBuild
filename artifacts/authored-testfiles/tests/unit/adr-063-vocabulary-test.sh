#!/usr/bin/env bash
# tests/unit/adr-063-vocabulary-test.sh — ADR-063 vocabulary and structure (#2032).
#
# ADR-063 was written with `exhausted`/`escalate` vocabulary that #2187 retired
# in favour of timed_out/out_of_turns. §1 referenced a single shared budget-
# guidance helper that per-stage helpers replaced. These tests assert the document
# has been updated and that no stale language survives.
#
#   SPEC-7[change] (#2032): ADR-063 status is "Accepted" and the document contains
#                           no prescriptive use of `exhausted` as the §3 disposition
#                           word or `escalate` as the §4 engine action.
#                           Fails before: status is "Proposed" and both stale words appear.
#   SPEC-8[change] (#2032): §1 uses per-stage budget-guidance helper language —
#                           each stage has its own _<stage>_budget_guidance helper;
#                           the baseline single-helper "One helper renders the budget
#                           block" language is absent.
#                           Fails before: the old single-helper sentence is present.
#   SPEC-9[change] (#2032): document contains an amendment back-pointer that
#                           explicitly names #2187 (the issue that retired the
#                           exhausted/escalate vocabulary).
#                           Fails before: no #2187 mention.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "ADR-063 vocabulary and structure (#2032)"
setup_test_env "adr-063-vocabulary"

ADR="$REPO_ROOT/docs/adr/ADR-063-budget-disclosure-and-partial-output.md"

if [[ ! -f "$ADR" ]]; then
    assert_fail "[#2032/SPEC-7] ADR-063 file exists" "not found at $ADR"
    print_test_results
    exit 1
fi

_adr_text="$(cat "$ADR")"

# ── SPEC-7[change]: status=Accepted, no prescriptive exhausted/escalate vocab ──
# The status header line must read "Accepted".
_status_line="$(grep -m1 '^\*\*Status:\*\*' "$ADR" 2>/dev/null || true)"
assert_contains "[#2032/SPEC-7] ADR-063 status header reads Accepted" \
    "$_status_line" "Accepted"

# §3 disposition word: the document must NOT prescribe `exhausted` as the
# machine-readable disposition to emit. "exhausted" may appear in historical
# context, but must not appear in a prescriptive "disposition: exhausted" form.
_exhausted_prescriptive="$(grep -c 'disposition: \`exhausted\`\|disposition: exhausted\b\|as \`disposition: exhausted\`' "$ADR" 2>/dev/null || true)"
assert_eq "[#2032/SPEC-7] §3 does not prescribe disposition:exhausted (vocabulary retired by #2187)" \
    "0" "$_exhausted_prescriptive"

# §4 engine action: the document must NOT prescribe `escalate` as the engine action
# for the timed-out disposition. "escalate" may appear in historical context but
# must not appear in the "exhausted → escalate" action prescription form.
_escalate_prescriptive="$(grep -c 'exhausted.*escalate\|escalate.*already routes\|→ escalate\b' "$ADR" 2>/dev/null || true)"
assert_eq "[#2032/SPEC-7] §4 does not prescribe exhausted→escalate action (vocabulary retired by #2187)" \
    "0" "$_escalate_prescriptive"

# ── SPEC-8[change]: §1 uses per-stage helpers, not the single-helper baseline ──
# The old §1 text "One helper renders the budget block" must be absent.
_old_single_helper="$(grep -c 'One helper renders the budget block' "$ADR" 2>/dev/null || true)"
assert_eq "[#2032/SPEC-8] §1 baseline single-helper sentence is absent (replaced by per-stage helpers)" \
    "0" "$_old_single_helper"

# Per-stage helper language must be present: each stage gets its own
# _<stage>_budget_guidance helper. Check for the characteristic pattern.
_per_stage_helper="$(grep -c '_budget_guidance\b' "$ADR" 2>/dev/null || true)"
assert_gt "[#2032/SPEC-8] §1 contains per-stage _<stage>_budget_guidance helper language" \
    "$_per_stage_helper" "0"

# ── SPEC-9[change]: amendment back-pointer names #2187 ─────────────────────────
# The document must contain an explicit reference to #2187 as the issue that
# retired the exhausted/escalate vocabulary.
_2187_ref="$(grep -c '#2187' "$ADR" 2>/dev/null || true)"
assert_gt "[#2032/SPEC-9] ADR-063 contains amendment back-pointer naming #2187" \
    "$_2187_ref" "0"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
