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
# SPEC-4 CHANGE  npm's shellcheck runs in parallel batches (ADR-065: alone it
#                took 102s on one core, 466s under the full suite's load), and a
#                defect in any one batch still fails it
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
# eval is needed to honour the quoting in the extracted arguments ('*.sh' must
# reach find unexpanded). Guard it: require the string to consist ONLY of the
# characters a find argument list legitimately uses, so a future refactor
# introducing command substitution or a subshell fails loudly here rather than
# being evaluated. Hyphen is last in the class so it is literal, not a range.
_FIND_ARG_CHARS="^[A-Za-z0-9_/.*'\" -]+\$"
_resolve() {
    if ! [[ "$1" =~ $_FIND_ARG_CHARS ]]; then
        printf 'unsafe characters in extracted find args: %s\n' "$1" >&2
        return 1
    fi
    ( cd "$REPO_ROOT" && eval "find $1" 2>/dev/null | sort -u )
}

_npm_files="$(_resolve "$_npm_args")"
_ci_files="$(_resolve "$_ci_args")"

# A resolution that yields nothing would make the superset check trivially true.
if [[ -n "$_ci_files" && -n "$_npm_files" ]]; then
    assert_pass "[SPEC-1] both invocations resolve to a non-empty file list ($(wc -l <<< "$_ci_files" | tr -d ' ') CI / $(wc -l <<< "$_npm_files" | tr -d ' ') npm)"
else
    assert_fail "[SPEC-1] a find invocation resolved to nothing — superset check would be vacuous" \
        "ci=$(wc -l <<< "$_ci_files" | tr -d ' ') npm=$(wc -l <<< "$_npm_files" | tr -d ' ')"
fi

# ─── the actual parity assertion: sets must match ────────────────────────────
# Only meaningful when both sets actually resolved. Without this guard the
# failure path asserts PASS: `printf '%s\n' ""` emits a newline, so comm sees two
# identical one-line streams, finds no difference, and reports a clean superset
# over nothing — the vacuous pass this whole guard exists to prevent.
if [[ -z "$_ci_files" || -z "$_npm_files" ]]; then
    assert_fail "[SPEC-1] parity comparison skipped — a prior extraction or resolution step failed" \
        "refusing to compare empty sets; see the failures above"
else
    # comm -13 = only in CI: files CI lints that local does not. The dangerous
    # direction, and the exact shape of the original bug.
    _only_in_ci="$(comm -13 <(printf '%s\n' "$_npm_files") <(printf '%s\n' "$_ci_files"))"
    if [[ -z "$_only_in_ci" ]]; then
        assert_pass "[SPEC-1] npm lint file set is a superset of the CI lint file set"
    else
        assert_fail "[SPEC-1] CI lints files that npm run lint does not — local must be the superset" \
            "only in CI: $(printf '%s' "$_only_in_ci" | tr '\n' ' ')"
    fi

    # The reverse: still drift, and #1682 asks the guard to fail when the two
    # resolve to different sets. Today they are exactly equal. If CI is ever
    # deliberately narrower or broader, update this and record why at BOTH sites.
    _only_in_npm="$(comm -23 <(printf '%s\n' "$_npm_files") <(printf '%s\n' "$_ci_files"))"
    if [[ -z "$_only_in_npm" ]]; then
        assert_pass "[SPEC-1] the two file sets are exactly equal (no drift in either direction)"
    else
        assert_fail "[SPEC-1] npm and CI resolve to different file sets — reconcile, or record the deliberate difference at both sites" \
            "only in npm: $(printf '%s' "$_only_in_npm" | tr '\n' ' ')"
    fi
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
grep -qE "xargs -0( -[Pn] [0-9]+)* shellcheck[^&|]*-x" "$PKG"      && _npm_x=1
grep -qE "xargs -0( -[Pn] [0-9]+)* shellcheck[^&|]*-x" "$WORKFLOW" && _ci_x=1
if [[ "$_npm_x" -eq 1 && "$_ci_x" -eq 1 ]]; then
    assert_pass "[SPEC-3] both npm and CI shellcheck with -x (follow source directives)"
else
    assert_fail "[SPEC-3] npm and CI must agree on -x — a sourced-only defect would pass one and fail the other" \
        "npm_x=$_npm_x ci_x=$_ci_x"
fi

# ─── SPEC-4: parallel batches, and a failing batch fails the step ───────────
_npm_xargs="$(grep -oE "xargs -0 [^&]*shellcheck [^&]*" "$PKG" | head -1 | sed 's/[[:space:]]*$//')"
assert_contains "[SPEC-4] npm's shellcheck runs in parallel (xargs -P)" "$_npm_xargs" " -P "
# The batches themselves need shellcheck; a runner without it (macOS CI) is an
# honest SKIP here — rc 127 would pass the defect check for the wrong reason.
skip_unless_capable "shellcheck unavailable" command -v shellcheck
_sc_dir="$(mktemp -d "${TMPDIR:-/tmp}/sc-parity.XXXXXX")"
for _i in 1 2 3 4 5 6; do printf '#!/usr/bin/env bash\necho ok\n' > "$_sc_dir/good$_i.sh"; done
printf '#!/usr/bin/env bash\nx=$(( 1 + ))\nif [ "$x" = 1 ] then\n' > "$_sc_dir/zz-bad.sh"
if [[ "$_npm_xargs" =~ ^xargs\ -0(\ -[Pn]\ [0-9]+)*\ shellcheck\ -x\ --severity=warning$ ]]; then
    ( cd "$_sc_dir" && find . -name '*.sh' -print0 | sort -z | eval "$_npm_xargs" ) >/dev/null 2>&1; _sc_rc=$?
    # GNU xargs reports a failed batch as 123, BSD xargs as 1; 127 (no
    # shellcheck) is neither.
    case "$_sc_rc" in 1|123) _sc_failed=yes ;; *) _sc_failed="no (rc $_sc_rc)" ;; esac
    assert_eq "[SPEC-4] a defect in one batch fails the step (xargs: a batch failed)" "yes" "$_sc_failed"
    ( cd "$_sc_dir" && rm -f zz-bad.sh && find . -name '*.sh' -print0 | eval "$_npm_xargs" ) >/dev/null 2>&1; _sc_rc=$?
    assert_eq "[SPEC-4] …and clean files pass it" "0" "$_sc_rc"
else
    assert_fail "[SPEC-4] the shellcheck step has the expected shape" "$_npm_xargs"
fi

rm -rf "${_sc_dir:-/nonexistent}"
print_test_results
exit $((FAIL > 0))
