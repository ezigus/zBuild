#!/usr/bin/env bash
# tests/unit/dependabot-excludes-legacy-test.sh — Dependabot leaves
# legacy-DoNotUse/ alone (ADR-008, amended 2026-11-28).
#
# legacy-DoNotUse/ is a frozen reference copy nothing runs. Its package files
# still drew Dependabot's security updates (PRs #2623, #2625, #2636, #2637,
# #2645), which scan every manifest in the repository, not only the
# directories dependabot.yml names. `exclude-paths` on each update entry is
# what keeps a directory out of both kinds of update.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"

print_test_header "Dependabot excludes legacy-DoNotUse/ (ADR-008)"

# _db_scan <dependabot.yml> — sets _entries (each update entry's ecosystem, one
# a line) and _missing (each one whose exclude-paths does not list
# "legacy-DoNotUse/**").
_db_scan() {
    local _l _eco="" _excl=0 _in=0
    _entries="" _missing=""
    _db_end() { [[ -n "$_eco" ]] || return 0; _entries+="$_eco"$'\n'; (( _excl )) || _missing+="$_eco"$'\n'; }
    while IFS= read -r _l; do
        if [[ "$_l" =~ ^[[:space:]]*-[[:space:]]+package-ecosystem:[[:space:]]*([A-Za-z0-9_-]+) ]]; then
            _db_end; _eco="${BASH_REMATCH[1]}"; _excl=0; _in=0; continue
        fi
        if [[ "$_l" =~ ^[[:space:]]*exclude-paths: ]]; then _in=1; continue; fi
        if (( _in )); then
            if [[ "$_l" =~ ^[[:space:]]*-[[:space:]]+[\"\']?legacy-DoNotUse/\*\*[\"\']?[[:space:]]*$ ]]; then _excl=1
            elif [[ ! "$_l" =~ ^[[:space:]]*-[[:space:]] ]]; then _in=0; fi
        fi
    done < "$1"
    _db_end
}

print_test_section "the scan"
_T="$(mktemp -d "${TMPDIR:-/tmp}/depbot.XXXXXX")" || exit 1
printf 'updates:\n  - package-ecosystem: npm\n    directory: "/"\n    exclude-paths:\n      - "legacy-DoNotUse/**"\n  - package-ecosystem: pip\n    directory: "/"\n' > "${_T:?}/d.yml"
_db_scan "$_T/d.yml"
assert_eq "an entry that excludes the directory is not missing it; one that does not is" "pip" "${_missing%$'\n'}"
rm -rf "${_T:?}"

print_test_section "the repository's dependabot.yml"
_db_scan "$REPO_ROOT/.github/dependabot.yml"
assert_contains "it has update entries" "$_entries" "npm"
assert_eq "every update entry excludes legacy-DoNotUse/**" "" "$_missing"

print_test_results
exit $((FAIL > 0))
