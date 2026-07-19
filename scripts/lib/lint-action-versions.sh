#!/usr/bin/env bash
# scripts/lib/lint-action-versions.sh — detect action version drift across
# .github/workflows/*.yml (#1459).
#
# Scans every `uses: <owner>/<repo>@<ref>` line. If the same action name
# appears at two or more distinct major versions, exits 1 naming each offender.
# Accumulates all offenders before exiting so one run surfaces everything.
#
# "Major version" = leading @vN token. SHA-pinned refs compare as-is (two
# different SHAs of the same action count as drift). Relative-path reusable
# workflow calls (uses: ./.github/...) are skipped — not action references.
#
# Exit codes:
#   0 — no version drift detected
#   1 — at least one action pinned at two or more distinct major versions
#
# Usage:
#   bash scripts/lib/lint-action-versions.sh

set -euo pipefail

_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO_ROOT="$(cd "$_SELF_DIR/../.." && pwd)"
_WORKFLOWS_DIR="$_REPO_ROOT/.github/workflows"

if [[ ! -d "$_WORKFLOWS_DIR" ]]; then
    printf 'lint-action-versions: .github/workflows/ not found at %s\n' "$_WORKFLOWS_DIR" >&2
    exit 1
fi

# Collect all `uses:` values from workflow YAML files.
# -h suppresses filenames; -r recurses. We do NOT pass -o (--only-matching)
# because we need the full line, not just the matched text, so strip it below.
declare -A _versions  # action_name -> space-separated distinct major versions

while IFS= read -r _line; do
    # Skip comment lines (first non-whitespace char is #).
    _trimmed="${_line#"${_line%%[![:space:]]*}"}"
    [[ "$_trimmed" == '#'* ]] && continue

    # Strip leading whitespace and the `uses:` prefix to isolate the value.
    _uses="${_line#*uses:}"
    _uses="${_uses#"${_uses%%[![:space:]]*}"}"  # ltrim whitespace
    _uses="${_uses%%[[:space:]]*}"              # rtrim at first whitespace/comment

    # Skip reusable workflow calls (relative paths like ./.github/workflows/...).
    [[ "$_uses" == ./* ]] && continue

    # Skip entries without a pin — emit a warning.
    if [[ "$_uses" != *@* ]]; then
        printf 'lint-action-versions: warning: unpinned action (no @ref): %s\n' "$_uses" >&2
        continue
    fi

    _action="${_uses%%@*}"  # owner/repo portion
    _ref="${_uses##*@}"     # ref portion

    # Skip reusable workflows embedded as actions (owner/repo/.github/workflows/...)
    # — more than one slash in the action name signals a sub-path ref.
    _slash_count="${_action//[^\/]/}"
    [[ "${#_slash_count}" -gt 1 ]] && continue

    # Normalise to major version: @vN.x.y → vN; SHAs kept verbatim.
    if [[ "$_ref" =~ ^v([0-9]+) ]]; then
        _major="v${BASH_REMATCH[1]}"
    else
        _major="$_ref"
    fi

    # Record the major version for this action (deduplicate).
    if [[ -v "_versions[$_action]" ]]; then
        [[ " ${_versions[$_action]} " != *" $_major "* ]] && \
            _versions[$_action]+=" $_major"
    else
        _versions[$_action]="$_major"
    fi
done < <(/usr/bin/grep -rh 'uses:' "$_WORKFLOWS_DIR" --include='*.yml' --include='*.yaml' 2>/dev/null || true)

_failures=0

for _action in "${!_versions[@]}"; do
    # shellcheck disable=SC2206
    read -ra _vers_arr <<< "${_versions[$_action]}"
    _count="${#_vers_arr[@]}"
    if [[ "$_count" -gt 1 ]]; then
        printf 'lint-action-versions: DRIFT — %s pinned at %d distinct major versions: %s\n' \
            "$_action" "$_count" "${_versions[$_action]}" >&2
        _failures=$((_failures + 1))
    fi
done

if [[ "$_failures" -gt 0 ]]; then
    printf '\nlint-action-versions: %d action(s) with version drift. Pin all uses of each action to the same major version.\n' \
        "$_failures" >&2
    exit 1
fi

printf 'lint-action-versions: OK — no action version drift detected.\n'
exit 0
