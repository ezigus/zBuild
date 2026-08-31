#!/usr/bin/env bash
# scripts/lib/lint-llm-envelope.sh — #1993, ADR-060 §1
#
# A parsed envelope carries structured data only. A field holding a markdown
# DOCUMENT is the shape that produced #767, #774, #783, #908 and finally #1972,
# where a single markdown-escaped underscore (`done\_sentinel` — not a legal
# JSON escape) made jq refuse the whole object and killed a 24-minute run.
#
# _llm_output_contract refuses the shape for stages that build their prompt
# through the framework — impact, monitor, plan. This lint covers the ones that
# do not: review-lens and security-lens declare their expected shape through
# lib/charters.sh and never touch the framework, so a check that lived only in
# _llm_output_contract would not see them.
#
# Signals, both taken from the field that actually caused #1972:
#   1. a schema field whose NAME ends in `_md`
#   2. a placeholder whose TEXT says "markdown"
#
# Scope excludes */tests/*: fixtures legitimately contain retired envelopes in
# order to assert they are ignored (impact-prompt-contract-test.sh carries four).
# This lint is about what a stage DECLARES to a model, not what a test feeds it.
#
# Short plain-text fields — reason, message, summary, description, evidence —
# are data and are NOT flagged. ADR-060 §5 is the line; do not read it wider.
#
# Usage: bash scripts/lib/lint-llm-envelope.sh [plugins_root]
set -uo pipefail

_LLE_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
_LLE_ROOT="${1:-${ZBUILD_PLUGINS_ROOT:-$_LLE_REPO/plugins}}"

_lle_violations=0
_lle_complain() {
    printf 'lint-llm-envelope: %s\n' "$1" >&2
    _lle_violations=$(( _lle_violations + 1 ))
}

while IFS= read -r _hit; do
    [[ -z "$_hit" ]] && continue
    case "$_hit" in */tests/*) continue ;; esac
    _lle_complain "$_hit"
    printf '  ADR-060 §1: an envelope carries structured data only. Put the detail in\n' >&2
    printf '  short plain-text fields and render any narrative from them (§3).\n' >&2
done < <(
    grep -rnE '"[A-Za-z0-9_]*_md"[[:space:]]*:|"[A-Za-z0-9_]+"[[:space:]]*:[[:space:]]*"<[^"]*[Mm]arkdown[^"]*>"' \
        "$_LLE_ROOT" --include='*.sh' 2>/dev/null || true
)

if [[ "$_lle_violations" -gt 0 ]]; then
    printf 'lint-llm-envelope: %s markdown-document field declaration(s) found\n' "$_lle_violations" >&2
    exit 1
fi

_lle_count="$(find "$_LLE_ROOT" -name '*.sh' -not -path '*/tests/*' 2>/dev/null | wc -l | tr -d ' ')"
printf 'lint-llm-envelope: OK — %s plugin source(s) checked, no markdown-document envelope fields\n' "$_lle_count"
