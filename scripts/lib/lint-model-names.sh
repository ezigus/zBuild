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

# Verify the roots BEFORE scanning. The obvious check — trust grep's exit code,
# 1 for "no matches" and 2 for a real failure — is not portable: BSD grep on
# macOS returns 1 for a MISSING DIRECTORY too, conflating it with a clean scan,
# while GNU grep (Linux/CI) returns 2. Measured on both. So a vanished root would
# be invisible here and reported on CI, which is precisely the local/CI split
# #1682 exists to remove. An explicit existence check behaves the same everywhere
# and names the missing root instead of inferring it from an exit code.
for _root in "${_ROOTS[@]}"; do
    [[ -d "$_root" ]] || {
        echo "ERROR: model-name scan root does not exist: $_root" >&2
        echo "  (renamed or removed? the scan would otherwise report a false OK)" >&2
        exit 2
    }
done

# Secondary net: honour rc>=2 where the local grep reports it (GNU, ugrep).
# Harmless on BSD grep, which never sets it for this case.
_rc=0
_hits="$(grep -rEn "$_MODEL_RE" "${_ROOTS[@]}" \
    --include='*.sh' --include='*.yaml' --include='*.json' \
    --exclude-dir='.git' --exclude="$_SELF")" || _rc=$?
if (( _rc >= 2 )); then
    echo "ERROR: model-name scan failed (grep rc=$_rc) — roots: ${_ROOTS[*]}" >&2
    exit 2
fi

if [[ -n "$_hits" ]]; then
    _count="$(printf '%s\n' "$_hits" | wc -l | tr -d ' ')"
    echo "ERROR: $_count hardcoded model name(s) found (ADR-003 violation)" >&2
    printf '%s\n' "$_hits" >&2
    exit 1
fi
echo "lint-model-names: OK — no hardcoded model names in ${_ROOTS[*]}"
