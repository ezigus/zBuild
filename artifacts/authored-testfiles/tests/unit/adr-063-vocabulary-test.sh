#!/usr/bin/env bash
# tests/unit/adr-063-vocabulary-test.sh
# ADR-063 vocabulary update checks (#2032):
#   SPEC-7 [#2032/SPEC-7]: status=Accepted; no prescriptive exhausted/escalate vocabulary
#   SPEC-8 [#2032/SPEC-8]: §1 per-stage helpers language; baseline "One helper" absent
#   SPEC-9 [#2032/SPEC-9]: amendment back-pointer explicitly names #2187
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "ADR-063 vocabulary update — accepted with #2187 vocabulary (#2032)"

ADR_FILE="$REPO_ROOT/docs/adr/ADR-063-budget-disclosure-and-partial-output.md"

assert_file_exists "[#2032/SPEC-7] ADR-063 file exists" "$ADR_FILE"

# ── SPEC-7 [#2032/SPEC-7]: status=Accepted; retired exhausted/escalate vocabulary ─
print_test_section "SPEC-7: Accepted status and retired exhausted/escalate vocabulary"

_status="$(grep -m 1 '^\*\*Status:' "$ADR_FILE" 2>/dev/null || true)"
assert_contains "[#2032/SPEC-7] status header reads Accepted" "$_status" "Accepted"

# The prescriptive §3 disposition word `exhausted` must be absent: the header
# `disposition: exhausted` and the dependency-table row both used this pattern.
_disp_exhausted="$(grep -c 'disposition.*exhausted\|exhausted.*disposition' "$ADR_FILE" 2>/dev/null || true)"
assert_eq "[#2032/SPEC-7] prescriptive 'disposition: exhausted' is removed from §3" \
    "0" "$_disp_exhausted"

# The prescriptive §4 engine action `exhausted → escalate` must be absent.
_chain="$(grep -c 'exhausted.*escalate\|escalate.*already routes' "$ADR_FILE" 2>/dev/null || true)"
assert_eq "[#2032/SPEC-7] prescriptive exhausted→escalate §4 chain is stricken" \
    "0" "$_chain"

# ── SPEC-8 [#2032/SPEC-8]: §1 per-stage helpers; "One helper" baseline absent ─
print_test_section "SPEC-8: per-stage _<stage>_budget_guidance helpers replace One-helper baseline"

_one_helper="$(grep -c 'One helper renders the budget block' "$ADR_FILE" 2>/dev/null || true)"
assert_eq "[#2032/SPEC-8] 'One helper renders the budget block' baseline language is absent" \
    "0" "$_one_helper"

# After the amendment, §1 describes per-stage helpers (_<stage>_budget_guidance).
_adr_content="$(cat "$ADR_FILE" 2>/dev/null || true)"
assert_contains "[#2032/SPEC-8] §1 uses per-stage _<stage>_budget_guidance helpers language" \
    "$_adr_content" "_budget_guidance"

# ── SPEC-9 [#2032/SPEC-9]: amendment back-pointer names #2187 ─────────────────
print_test_section "SPEC-9: amendment back-pointer explicitly names #2187"

assert_contains "[#2032/SPEC-9] document contains an amendment back-pointer naming #2187" \
    "$_adr_content" "#2187"

print_test_results
exit $((FAIL > 0))
