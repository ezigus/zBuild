#!/usr/bin/env bash
# scripts/lib/lint-test-real-tree.sh — a test never runs a lint over the real
# checkout (#2615, ADR-012).
#
# `npm run lint` runs every lint over the tree, once. A lint test that also ran
# its lint over the checkout the suite runs from paid for that again on every
# suite run — lint-test-engine-state's took 9 of its 9.5 seconds — and grew with
# every file added. A lint test runs its lint on its own fixtures; that the lint
# step runs it is checked against package.json.
#
# Refused, in a lint's test (lint-*-test.sh) under the test folders: `bash
# "$LINT"` with no root or with "$REPO_ROOT", and `bash
# "$REPO_ROOT/scripts/lib/lint-….sh"` the same way — unless a variable set on
# the same command points the lint at a root that is not the checkout.
#
# Usage: bash scripts/lib/lint-test-real-tree.sh [root]   (default: the repo)
# Exit:  0 = clean; 1 = at least one such line.
set -euo pipefail

_LRT_ROOT="${1:-$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; cd "../.." && pwd)}"
# The lint, then no argument or the checkout, then the end of the command.
_LRT_RE='bash[[:space:]]+"(\$LINT|\$REPO_ROOT/scripts/lib/lint-[a-z0-9-]+\.sh)"([[:space:]]+"\$REPO_ROOT")?[[:space:]]*($|[;|)&<>]|[0-9]>)'
_bad=0
while IFS= read -r -d '' f; do
    n=0
    while IFS= read -r l || [[ -n "$l" ]]; do
        n=$((n + 1))
        [[ "$l" =~ ^[[:space:]]*# ]] && continue
        if [[ "$l" =~ $_LRT_RE ]]; then
            # A root set on the command itself (VAR="$FIX" bash …) is the test's own.
            _pre="${l%%"${BASH_REMATCH[0]}"*}"
            [[ "$_pre" =~ [A-Z_]+=\"([^\"]*)\"[[:space:]]*$ && "${BASH_REMATCH[1]}" != *'$REPO_ROOT'* ]] && continue
            echo "lint-test-real-tree: ${f#"$_LRT_ROOT"/}:$n runs a lint over the real checkout — run it on the test's own fixtures; npm run lint runs it over the tree" >&2
            _bad=$((_bad + 1))
        fi
    done < "$f"
done < <(find "$_LRT_ROOT/tests" "$_LRT_ROOT/plugins" -name 'lint-*-test.sh' -not -path '*/legacy-DoNotUse/*' -print0 2>/dev/null)

if (( _bad > 0 )); then
    echo "lint-test-real-tree: $_bad line(s) run a lint over the real checkout" >&2
    exit 1
fi
echo "lint-test-real-tree: clean"
