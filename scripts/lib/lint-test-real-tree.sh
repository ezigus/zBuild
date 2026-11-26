#!/usr/bin/env bash
# scripts/lib/lint-test-real-tree.sh — a test never runs a lint over the real
# checkout (#2615, ADR-012).
#
# `npm run lint` runs every lint over the tree, once. A test that also ran a
# lint over the checkout the suite runs from paid for that again on every suite
# run — lint-test-engine-state's took 9 of its 9.5 seconds — and grew with every
# file added. A test runs a lint on its own fixtures; that the lint step runs it
# is checked against package.json.
#
# A lint is named by its path (…scripts/lib/lint-….sh) or by a variable the file
# sets to one. Refused, in any *-test.sh under the test folders: a lint run
# (bash <lint>, or <lint> itself) whose root is none, "$REPO_ROOT" or a path
# under it, unless a *_ROOT variable set on the same command points it at a root
# that is not the checkout. A line ending in \ is read with the next.
#
# Usage: bash scripts/lib/lint-test-real-tree.sh [root]   (default: the repo)
# Exit:  0 = clean; 1 = at least one such line.
set -euo pipefail

_LRT_ROOT="${1:-$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; cd "../.." && pwd)}"
_bad=0
# The regexes, kept in variables: [[ =~ ]] cannot hold a bare ; | ) & < >.
_LRT_SET='^[[:space:]]*(local[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)="?[^ ]*scripts/lib/lint-[a-z0-9-]+\.sh"?[[:space:]]*$'
_LRT_PATH='(bash[[:space:]]+|(^|[;&|({]|\$\(|then|do)[[:space:]]*)"?\$\{?REPO_ROOT\}?/scripts/lib/lint-[a-z0-9-]+\.sh"?'
_LRT_END='([[:space:]]|$|[;|)&>])'
_LRT_ROOTW='^[[:space:]]*("[^"]*"|[^][:space:];|)&<>[]+)'
_LRT_ENV='[A-Z_]*ROOT="([^"]*)"([[:space:]]+[A-Za-z_]+=[^[:space:]]*)*[[:space:]]*$'
_lrt_file() {
    local f="$1" l n=0 start=0 cur="" v vars=" " lint pre post root re
    # The variables this file sets to a lint's path.
    while IFS= read -r l; do
        [[ "$l" =~ $_LRT_SET ]] && vars+="${BASH_REMATCH[2]} "
    done < "$f"
    while IFS= read -r l || [[ -n "$l" ]]; do
        n=$((n + 1))
        if [[ -n "$cur" ]]; then cur+=" ${l#"${l%%[![:space:]]*}"}"; else cur="$l"; start=$n; fi
        [[ "$l" == *\\ ]] && { cur="${cur%\\}"; continue; }
        l="$cur"; cur=""
        [[ "$l" =~ ^[[:space:]]*# ]] && continue
        [[ "$l" =~ $_LRT_SET ]] && continue   # it names the lint, and runs nothing
        lint=""
        for v in $vars; do
            # Run: after `bash`, or as the command itself (line start, ; & | ( { $( then do).
            re="(bash[[:space:]]+|(^|[;&|({]|\\\$\\(|then|do)[[:space:]]*([A-Z_]+=[^[:space:]]*[[:space:]]+)*)\"?\\\$\\{?$v\\}?\"?$_LRT_END"
            [[ "$l" =~ $re ]] && { lint="$v"; break; }
        done
        if [[ -z "$lint" && "$l" =~ $_LRT_PATH ]]; then lint="${BASH_REMATCH[0]}"; fi
        [[ -n "$lint" ]] || continue
        pre="${l%%"${BASH_REMATCH[0]}"*}"; post="${l#*"${BASH_REMATCH[0]}"}"
        # The lint's root: the first word after it, unless it is a redirect.
        root=""; [[ "$post" =~ ^[[:space:]]*[0-9]*[\<\>] ]] || { [[ "$post" =~ $_LRT_ROOTW ]] && root="${BASH_REMATCH[1]}"; }
        root="${root//\"/}"
        if [[ -n "$root" && "$root" != '$REPO_ROOT'* && "$root" != '${REPO_ROOT}'* ]]; then continue; fi
        # A root set on the command itself (X_ROOT="$FIX" bash …) is the test's own.
        if [[ "$pre" =~ $_LRT_ENV ]] \
           && [[ "${BASH_REMATCH[1]}" != *'REPO_ROOT'* ]]; then continue; fi
        echo "lint-test-real-tree: ${f#"$_LRT_ROOT"/}:$start runs a lint over the real checkout — run it on the test's own fixtures; npm run lint runs it over the tree" >&2
        _bad=$((_bad + 1))
    done < "$f"
}
while IFS= read -r -d '' f; do _lrt_file "$f"; done \
    < <(find "$_LRT_ROOT/tests" "$_LRT_ROOT/plugins" -name '*-test.sh' -not -path '*/legacy-DoNotUse/*' -print0 2>/dev/null)

if (( _bad > 0 )); then
    echo "lint-test-real-tree: $_bad line(s) run a lint over the real checkout" >&2
    exit 1
fi
echo "lint-test-real-tree: clean"
