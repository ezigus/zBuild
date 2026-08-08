#!/usr/bin/env bash
# scripts/lib/lint-grep-c.sh — reject the `$(grep -c … || echo …)` antipattern (#1751).
#
# `grep -c` PRINTS its count (including "0") and EXITS 1 when there are no
# matches. So `count="$(grep -c PAT f || echo 0)"` produces the two-line string
# "0\n0" on the no-match path — and the next `(( count … ))` dies with
# "syntax error in expression", aborting the whole script under `set -e`.
# The bug only fires on the no-match branch, which is why it survives review
# and normal runs and then kills a scheduled job nobody is watching.
#
# The safe forms, all of which this linter accepts:
#   count="$(grep -c PAT f || true)"        # grep already printed the count
#   count=$(grep -c PAT f) || count=0       # assignment outside the substitution
#
# Scans scripts/ core/ plugins/ for *.sh. Excludes legacy/ (frozen upstream
# import, never run) and test files — a test asserting on the string result is
# not at risk of the arithmetic abort, and sweeping the ~30 existing test-side
# instances is tracked separately rather than bundled into this fix.
#
# Exit codes:
#   0 — no occurrences of the antipattern
#   1 — at least one occurrence (each is named with file:line)
#
# Usage:
#   bash scripts/lib/lint-grep-c.sh

set -euo pipefail

_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO_ROOT="$(cd "$_SELF_DIR/../.." && pwd)"

# Roots may be overridden for testing against a fixture tree.
_SCAN_ROOTS=("${@:-}")
_SCAN_REPO_ROOT_TOPLEVEL=0
if [[ -z "${_SCAN_ROOTS[0]:-}" ]]; then
    _SCAN_ROOTS=("$_REPO_ROOT/scripts" "$_REPO_ROOT/core" "$_REPO_ROOT/plugins")
    # Also the repo-root *.sh entrypoints (install.sh and friends). Scanned at
    # depth 1 only — recursing from the repo root would drag in node_modules,
    # .git and the frozen legacy/ import for no benefit.
    _SCAN_REPO_ROOT_TOPLEVEL=1
fi

# A `grep -c` inside a command substitution, followed by `|| echo`.
# The `-c` may be in any flag cluster, not just the first: `grep -cE PAT` and
# `grep -E -c PAT` are both the bug. The `[^)]*` guards keep a match from
# spanning two sibling substitutions on one line.
# Deliberately narrow: `|| true` and assignment-outside-substitution must both
# keep passing.
_PATTERN='\$\([^)]*grep[^)]*[[:space:]]-[a-zA-Z]*c[a-zA-Z]*[[:space:]][^)]*\|\|[[:space:]]*echo'

_failures=0

_collect_files() {
    local _r
    for _r in "${_SCAN_ROOTS[@]}"; do
        [[ -d "$_r" ]] || continue
        find "$_r" -name '*.sh' -type f -print0 2>/dev/null
    done
    if [[ "$_SCAN_REPO_ROOT_TOPLEVEL" -eq 1 ]]; then
        find "$_REPO_ROOT" -maxdepth 1 -name '*.sh' -type f -print0 2>/dev/null
    fi
}

while IFS= read -r -d '' _file; do
    case "$_file" in
        */legacy/*) continue ;;
        *-test.sh)  continue ;;
        */tests/*)  continue ;;
    esac
    while IFS=: read -r _lineno _text; do
        [[ -z "$_lineno" ]] && continue
        # Trim leading whitespace for a readable report.
        _text="${_text#"${_text%%[![:space:]]*}"}"
        # A comment describing the antipattern is not an instance of it —
        # this very file documents the bad form in its header.
        [[ "$_text" == '#'* ]] && continue
        printf 'lint-grep-c: %s:%s — `grep -c … || echo` yields "0\\n0" on no-match; use `|| true`\n' \
            "${_file#"$_REPO_ROOT"/}" "$_lineno" >&2
        printf '    %s\n' "$_text" >&2
        _failures=$((_failures + 1))
    done < <(/usr/bin/grep -nE "$_PATTERN" "$_file" 2>/dev/null || true)
done < <(_collect_files)

if [[ "$_failures" -gt 0 ]]; then
    printf '\nlint-grep-c: %d occurrence(s). `grep -c` already prints the count — replace `|| echo 0` with `|| true`.\n' \
        "$_failures" >&2
    exit 1
fi

printf 'lint-grep-c: OK — no grep -c || echo occurrences in scripts/ core/ plugins/\n'
exit 0
