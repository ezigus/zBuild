#!/usr/bin/env bash
# tests/unit/ci-npm-script-parity-test.sh — guard: `npm run lint` and the CI Lint
# job must shellcheck the same files, with local ⊇ CI (#1682).
#
# The point is to DERIVE both file sets from the two real sources — package.json
# and .github/workflows/test.yml — and compare them. An earlier draft computed
# both sides from one hardcoded `find`, so it could not fail: injecting a genuine
# divergence into the workflow left it green. A parity test that does not read
# both definitions tests nothing.
#
# SPEC-1 CHANGE  the guard derives both file sets from their real sources and
#                fails when the npm set is not a superset of the CI set
# SPEC-2 GUARD   scripts/run-tests.sh (top-level scripts/, the file the original
#                bug hid) is in the npm lint set
# SPEC-3 GUARD   both sides pass shellcheck -x, so a sourced-only defect cannot
#                pass one and fail the other
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "CI / npm lint shellcheck parity (#1682)"

WORKFLOW="$REPO_ROOT/.github/workflows/test.yml"
PKG="$REPO_ROOT/package.json"

# ─── extract the `find … -name '*.sh' …` invocation from a source file ────────
# Returns the argument list between `find` and `-print0`/`|`. Empty output means
# extraction FAILED — the caller must treat that as a hard error, never as "no
# files", or the comparison below passes vacuously at the moment it stops working.
_extract_find_args() {
    grep -oE "find [^|]*-name '\*\.sh'[^|]*" "$1" 2>/dev/null \
        | head -1 | sed -e 's/^find //' -e 's/-print0.*$//' -e 's/[[:space:]]*$//'
}

_npm_args="$(_extract_find_args "$PKG")"
_ci_args="$(_extract_find_args "$WORKFLOW")"

if [[ -n "$_npm_args" && -n "$_ci_args" ]]; then
    assert_pass "[SPEC-1] both find invocations were extracted from their real sources"
else
    assert_fail "[SPEC-1] could not extract a find invocation from both sources — the guard cannot compare anything" \
        "npm='$_npm_args' ci='$_ci_args'"
fi

# Resolve each argument list against the repo, from the repo root (both sources
# use repo-relative roots).
_resolve() { ( cd "$REPO_ROOT" && eval "find $1" 2>/dev/null | sort -u ); }
_npm_files="$(_resolve "$_npm_args")"
_ci_files="$(_resolve "$_ci_args")"

# A resolution that yields nothing would make the superset check trivially true.
if [[ -n "$_ci_files" && -n "$_npm_files" ]]; then
    assert_pass "[SPEC-1] both invocations resolve to a non-empty file list ($(wc -l <<< "$_ci_files" | tr -d ' ') CI / $(wc -l <<< "$_npm_files" | tr -d ' ') npm)"
else
    assert_fail "[SPEC-1] a find invocation resolved to nothing — superset check would be vacuous" \
        "ci=$(wc -l <<< "$_ci_files" | tr -d ' ') npm=$(wc -l <<< "$_npm_files" | tr -d ' ')"
fi

# ─── the actual parity assertion: local ⊇ CI ─────────────────────────────────
# comm -13 = lines only in CI. Anything here is a file CI lints and local does
# not — the exact shape of the original bug.
_only_in_ci="$(comm -13 <(printf '%s\n' "$_npm_files") <(printf '%s\n' "$_ci_files"))"
if [[ -z "$_only_in_ci" ]]; then
    assert_pass "[SPEC-1] npm lint file set is a superset of the CI lint file set"
else
    assert_fail "[SPEC-1] CI lints files that npm run lint does not — local must be the superset" \
        "only in CI: $(printf '%s' "$_only_in_ci" | tr '\n' ' ')"
fi

# The reverse direction: files local lints that CI does not. `local ⊇ CI` still
# holds here, so this is not the dangerous direction — but it is still DRIFT, and
# #1682 asks the guard to fail when the two resolve to different sets. Today they
# are exactly equal. If CI is ever deliberately narrower or broader (a matrix leg,
# say), update this assertion and record why at BOTH sites, as the issue requires
# — do not silently let the sets part.
_only_in_npm="$(comm -23 <(printf '%s\n' "$_npm_files") <(printf '%s\n' "$_ci_files"))"
if [[ -z "$_only_in_npm" ]]; then
    assert_pass "[SPEC-1] the two file sets are exactly equal (no drift in either direction)"
else
    assert_fail "[SPEC-1] npm and CI resolve to different file sets — reconcile, or record the deliberate difference at both sites" \
        "only in npm: $(printf '%s' "$_only_in_npm" | tr '\n' ' ')"
fi

# ─── SPEC-2: the file the original bug hid behind ────────────────────────────
if grep -qxF "scripts/run-tests.sh" <<< "$_npm_files"; then
    assert_pass "[SPEC-2] scripts/run-tests.sh is in the npm lint set"
else
    assert_fail "[SPEC-2] scripts/run-tests.sh must be linted locally (the #1682 bug: 'find scripts/lib' skipped it)" \
        "npm set has $(wc -l <<< "$_npm_files" | tr -d ' ') files"
fi

# ─── SPEC-3: the -x flag, resolved deliberately rather than left divergent ────
_npm_x=0; _ci_x=0
grep -qE "xargs -0 shellcheck[^&|]*-x" "$PKG"      && _npm_x=1
grep -qE "xargs -0 shellcheck[^&|]*-x" "$WORKFLOW" && _ci_x=1
if [[ "$_npm_x" -eq 1 && "$_ci_x" -eq 1 ]]; then
    assert_pass "[SPEC-3] both npm and CI shellcheck with -x (follow source directives)"
else
    assert_fail "[SPEC-3] npm and CI must agree on -x — a sourced-only defect would pass one and fail the other" \
        "npm_x=$_npm_x ci_x=$_ci_x"
fi

print_test_results
exit $((FAIL > 0))
