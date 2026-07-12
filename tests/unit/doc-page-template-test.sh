#!/usr/bin/env bash
# tests/unit/doc-page-template-test.sh — verifies docs/templates/doc-page.md
# encodes the issue's four required sections (DOC-B, #1415):
#   NEWCOMER_OPENING (summary) -> HOW_TO_USE (usage) -> REFERENCE (manifest/
#   registry fields) -> ADVANCED, in progressive-disclosure order, per DOC-STYLE.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "docs/templates/doc-page.md — shared doc output contract (DOC-B #1415)"

TEMPLATE="$REPO_ROOT/docs/templates/doc-page.md"

# ── SPEC-1: template file exists ─────────────────────────────────────────────
fe=0; [[ -f "$TEMPLATE" ]] && fe=1
assert_eq "[SPEC-1] template exists at docs/templates/doc-page.md" "1" "$fe"
if [[ "$fe" -ne 1 ]]; then print_test_results; exit $((FAIL > 0)); fi

TMPL="$(cat "$TEMPLATE")"

# ── SPEC-2..5: the four required slots, matching the issue's sections ─────────
assert_contains "[SPEC-2] NEWCOMER_OPENING slot present (from summary)"      "$TMPL" "SLOT: NEWCOMER_OPENING"
assert_contains "[SPEC-3] HOW_TO_USE slot present (from usage)"              "$TMPL" "SLOT: HOW_TO_USE"
assert_contains "[SPEC-4] REFERENCE slot present (manifest/registry fields)" "$TMPL" "SLOT: REFERENCE"
assert_contains "[SPEC-5] ADVANCED slot present"                            "$TMPL" "SLOT: ADVANCED"

# ── SPEC-6: slots in progressive-disclosure order ────────────────────────────
_slot_line() { grep -n "SLOT: $1" "$TEMPLATE" | head -1 | cut -d: -f1; }
n_new="$(_slot_line NEWCOMER_OPENING)"; n_use="$(_slot_line HOW_TO_USE)"
n_ref="$(_slot_line REFERENCE)";        n_adv="$(_slot_line ADVANCED)"
order=0
if [[ -n "$n_new" && -n "$n_use" && -n "$n_ref" && -n "$n_adv" ]] \
   && (( n_new < n_use && n_use < n_ref && n_ref < n_adv )); then
    order=1
fi
assert_eq "[SPEC-6] slots ordered NEWCOMER_OPENING<HOW_TO_USE<REFERENCE<ADVANCED" "1" "$order"

# ── SPEC-7: the '## Advanced' heading (DOC-STYLE rule 4) ─────────────────────
adv_h=0; grep -qE '^## Advanced' "$TEMPLATE" && adv_h=1
assert_eq "[SPEC-7] '## Advanced' heading present" "1" "$adv_h"

# ── Issue sections: the How-to-use + Reference headings are actually emitted ──
howto_h=0; grep -qE '^## How to use' "$TEMPLATE" && howto_h=1
assert_eq "'## How to use' heading present (from manifest usage)" "1" "$howto_h"
ref_h=0; grep -qE '^## Reference' "$TEMPLATE" && ref_h=1
assert_eq "'## Reference' heading present (manifest/registry fields)" "1" "$ref_h"

# ── VARIANT marker + DOC-STYLE reference ─────────────────────────────────────
assert_contains "VARIANT: plugin | mechanic marker present" "$TMPL" "VARIANT: plugin | mechanic"
assert_contains "template references docs/DOC-STYLE.md" "$TMPL" "DOC-STYLE.md"

# ── Guard: lint-doc-style.sh still passes on the real repo docs ──────────────
lint_rc=0; bash "$REPO_ROOT/scripts/lib/lint-doc-style.sh" >/dev/null 2>&1 || lint_rc=$?
assert_eq "lint-doc-style.sh still passes (no newcomer-opening regression)" "0" "$lint_rc"

print_test_results
exit $((FAIL > 0))
