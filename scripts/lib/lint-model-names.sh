#!/usr/bin/env bash
# lint-model-names.sh — ADR-003: no hardcoded model names in core/plugins/scripts.
#
# ONE definition, called by BOTH `npm run lint` and the CI Lint job. It used to be
# an inline snippet duplicated at both sites, which is the exact divergence class
# #1682 exists to remove — and duplicating it also re-introduced a subtler bug:
# the CI copy runs under Actions' bash `run:`, so its `[[ ]]` was correct there,
# but npm runs scripts with /bin/sh (dash on Linux), where `[[` does not exist.
# A bash script with a shebang is immune to the caller's shell either way.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${ZBUILD_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
cd "$REPO_ROOT" || exit 2

# Tier ordinals are stable, model names are not (ADR-003) — selection must flow
# through core/router reading config/models.json, never a literal.
_MODEL_RE='claude-haiku|claude-sonnet|claude-opus|gpt-[0-9]|llama-[0-9]|mistral-'
_ROOTS=(core/ plugins/ scripts/)

# Exclude THIS file: it necessarily contains the pattern it searches for, and the
# previous inline copies escaped that only by living under .github/ (outside the
# searched roots). A linter that fails on its own definition is not a linter.
_SELF="$(basename "${BASH_SOURCE[0]}")"

_hits="$(grep -rEn "$_MODEL_RE" "${_ROOTS[@]}" \
    --include='*.sh' --include='*.yaml' --include='*.json' \
    --exclude-dir='.git' --exclude="$_SELF" 2>/dev/null || true)"

if [[ -n "$_hits" ]]; then
    _count="$(printf '%s\n' "$_hits" | wc -l | tr -d ' ')"
    echo "ERROR: $_count hardcoded model name(s) found (ADR-003 violation)" >&2
    printf '%s\n' "$_hits" >&2
    exit 1
fi
echo "lint-model-names: OK — no hardcoded model names in ${_ROOTS[*]}"
