#!/usr/bin/env bash
# tests/unit/doc-page-template-test.sh — verifies docs/templates/doc-page.md
# structure and DOC-STYLE compliance (issue #1415, DOC-B).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "docs/templates/doc-page.md — template structure + DOC-STYLE compliance"

TEMPLATE="$REPO_ROOT/docs/templates/doc-page.md"

# ── SPEC-1: template file exists ──────────────────────────────────────────────
fe=0
[[ -f "$TEMPLATE" ]] || fe=1
assert_eq "[SPEC-1] template file exists at docs/templates/doc-page.md" "0" "$fe"

if [[ ! -f "$TEMPLATE" ]]; then
    print_test_results
    exit $((FAIL > 0))
fi

TMPL="$(cat "$TEMPLATE")"

# ── SPEC-2: NEWCOMER_OPENING slot present ─────────────────────────────────────
assert_contains "[SPEC-2] NEWCOMER_OPENING slot marker present" \
    "$TMPL" "SLOT: NEWCOMER_OPENING"

# ── SPEC-3: WHAT_IT_DOES slot present ────────────────────────────────────────
assert_contains "[SPEC-3] WHAT_IT_DOES slot marker present" \
    "$TMPL" "SLOT: WHAT_IT_DOES"

# ── SPEC-4: EXAMPLE slot present ──────────────────────────────────────────────
assert_contains "[SPEC-4] EXAMPLE slot marker present" \
    "$TMPL" "SLOT: EXAMPLE"

# ── SPEC-5: ADVANCED slot present ─────────────────────────────────────────────
assert_contains "[SPEC-5] ADVANCED slot marker present" \
    "$TMPL" "SLOT: ADVANCED"

# ── SPEC-6: slots in progressive-disclosure order ─────────────────────────────
ln_newcomer=$(/usr/bin/grep -n "SLOT: NEWCOMER_OPENING" "$TEMPLATE" | cut -d: -f1 | head -1)
ln_whatitdoes=$(/usr/bin/grep -n "SLOT: WHAT_IT_DOES" "$TEMPLATE" | cut -d: -f1 | head -1)
ln_example=$(/usr/bin/grep -n "SLOT: EXAMPLE" "$TEMPLATE" | cut -d: -f1 | head -1)
ln_advanced=$(/usr/bin/grep -n "SLOT: ADVANCED" "$TEMPLATE" | cut -d: -f1 | head -1)
slot_order=1
[[ "${ln_newcomer:-0}" -lt "${ln_whatitdoes:-0}" ]] || slot_order=0
[[ "${ln_whatitdoes:-0}" -lt "${ln_example:-0}" ]] || slot_order=0
[[ "${ln_example:-0}" -lt "${ln_advanced:-0}" ]] || slot_order=0
assert_eq "[SPEC-6] slots appear in progressive-disclosure order (NEWCOMER_OPENING->WHAT_IT_DOES->EXAMPLE->ADVANCED)" \
    "1" "$slot_order"

# ── SPEC-7: ## Advanced heading is present ────────────────────────────────────
assert_contains "[SPEC-7] ## Advanced heading present (DOC-STYLE rule 4)" \
    "$TMPL" "## Advanced"

# ── Extra: VARIANT marker present ─────────────────────────────────────────────
assert_contains "VARIANT marker present (plugin | mechanic)" \
    "$TMPL" "VARIANT:"

# ── Extra: DOC-STYLE.md referenced ───────────────────────────────────────────
assert_contains "template references docs/DOC-STYLE.md" \
    "$TMPL" "DOC-STYLE.md"

# ── Extra: template's newcomer-opening prose passes lint structural rule ───────
# Reads the first non-blank, non-HTML-comment line after the H1 and applies the
# same structural checks as lint-doc-style.sh _is_prose_opening:
#   >= 5 words, ends in sentence punctuation, no structural prefix.
h1_seen=0
opening_line=""
while IFS= read -r _l; do
    if [[ "$h1_seen" -eq 0 ]]; then
        [[ "$_l" =~ ^#[[:space:]] ]] && h1_seen=1
        continue
    fi
    [[ -z "${_l//[[:space:]]/}" ]] && continue
    [[ "$_l" == '<!--'* ]] && continue
    opening_line="$_l"
    break
done < "$TEMPLATE"

lint_pass=1
if [[ -n "$opening_line" ]]; then
    wc=$(printf '%s\n' "$opening_line" | wc -w | tr -d '[:space:]')
    [[ "$wc" -ge 5 ]] || lint_pass=0
    trimmed="${opening_line%%[[:space:]]}"
    trimmed="${trimmed%[*_\`]}"
    trimmed="${trimmed%[*_\`]}"
    trimmed="${trimmed%)}"
    case "$trimmed" in
        *'.'|*'!'|*'?') : ;;
        *) lint_pass=0 ;;
    esac
    case "$opening_line" in
        '#'*|'```'*|'|'*|'!['*|'<'*|'- '*|'* '*|'+ '*) lint_pass=0 ;;
    esac
else
    lint_pass=0
fi
assert_eq "template newcomer-opening prose passes lint-doc-style structural rule" \
    "1" "$lint_pass"

print_test_results
exit $((FAIL > 0))
