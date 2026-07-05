#!/usr/bin/env bash
# Tests: scripts/run-tests.sh --files cannot be wedged by a non-test or hanging
# file (#929). A markdown mutation spec run as bash blocked on stdin for 3.5h
# in a #911 dogfood because the --files loop ran EVERY passed path as `bash`
# with no *-test.sh filter, no stdin guard, and no timeout.
#
# Each case bounds its OWN call to run-tests.sh with an outer gtimeout so an
# unfixed (hanging) run-tests.sh makes the test FAIL fast, never hang the suite.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUN_TESTS="$REPO_ROOT/scripts/run-tests.sh"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

# Resolve a REAL timeout command BEFORE setup_test_env prepends its mock bin to
# PATH (the harness can install a stub `timeout` that ignores the duration —
# test-helpers.sh). Capture the absolute path so the outer bound and the G3
# per-file-timeout assertion both use a real, enforcing timeout — never a stub.
_REAL_TIMEOUT=""
if   command -v gtimeout >/dev/null 2>&1; then _REAL_TIMEOUT="$(command -v gtimeout)"
elif command -v timeout  >/dev/null 2>&1; then _REAL_TIMEOUT="$(command -v timeout)"; fi

print_test_header "run-tests.sh --files guard: non-test/hanging files can't wedge it (#929)"
setup_test_env "run-tests-files-guard"

# Outer safety bound (real timeout only) so this test can never hang, even
# against unfixed code. When no real timeout exists on the host, the bound is
# empty and G3 (which needs an enforcing timeout) is skipped — G1/G2 are
# inherently hang-free with the fix present (skip / EOF), so they always run.
_OUTER=()
[[ -n "$_REAL_TIMEOUT" ]] && _OUTER=("$_REAL_TIMEOUT" 30)

FX="$TEST_TEMP_DIR/fx"
mkdir -p "$FX"
# A real passing test.
printf '#!/usr/bin/env bash\nexit 0\n' > "$FX/good-test.sh"
# A markdown "mutation spec" with an unbalanced backtick — run as bash it blocks
# on stdin waiting to close the command-substitution (the original 3.5h wedge).
printf '## File\n`some/path.sh`\n## Mutation\nremove the `mv` call\n' > "$FX/cache.md"
# A *-test.sh that reads stdin — passes the name filter, must NOT block (</dev/null).
printf '#!/usr/bin/env bash\nread -r _x\nexit 0\n' > "$FX/reads-stdin-test.sh"
# A *-test.sh that infinite-loops — only the per-file timeout can stop it.
printf '#!/usr/bin/env bash\nwhile true; do :; done\n' > "$FX/infinite-loop-test.sh"
chmod +x "$FX"/*.sh

# ─── G1: a non-test (.md) file is SKIPPED, not executed → no hang, run returns ─
out="$("${_OUTER[@]}" bash "$RUN_TESTS" --files "$FX/good-test.sh" "$FX/cache.md" 2>&1)"
rc=$?
assert_eq "G1: run returns (outer bound not hit) — non-test .md did not wedge it" "0" "$rc"
case "$out" in
    *"skip non-test: $FX/cache.md"*) assert_pass "G1: cache.md skipped, not executed" ;;
    *) assert_fail "G1: cache.md should be skipped" "out: $out" ;;
esac
case "$out" in
    *"unit: 1/1 passed"*) assert_pass "G1: denominator counts only the real test (1/1)" ;;
    *) assert_fail "G1: summary must count only *-test.sh (expected 1/1)" "out: $out" ;;
esac

# ─── G2: a *-test.sh that reads stdin returns immediately (</dev/null guard) ───
out="$("${_OUTER[@]}" bash "$RUN_TESTS" --files "$FX/reads-stdin-test.sh" 2>&1)"
rc=$?
assert_eq "G2: stdin-reading test returns (EOF from </dev/null, no block)" "0" "$rc"
case "$out" in
    *"unit: 1/1 passed"*) assert_pass "G2: stdin-reading test passed without hanging" ;;
    *) assert_fail "G2: stdin-reading test should pass" "out: $out" ;;
esac

# ─── G3: an infinite-loop *-test.sh is killed by the per-file timeout → FAIL ──
# Requires a REAL enforcing timeout — run-tests.sh degrades to no-timeout when
# none exists, so there is nothing to assert on such a host. Gate accordingly.
if [[ -n "$_REAL_TIMEOUT" ]]; then
    # Short per-file timeout so the loop is bounded; outer bound is the backstop.
    out="$(ZBUILD_TEST_FILE_TIMEOUT=3 "${_OUTER[@]}" bash "$RUN_TESTS" --files "$FX/infinite-loop-test.sh" 2>&1)"
    rc=$?
    # run-tests.sh exits 1 when a file fails; the OUTER bound (30s) must NOT be
    # what stopped it — the per-file timeout (3s) should. rc=124 here would mean
    # the outer bound fired = the per-file timeout did NOT work = still wedged.
    assert_eq "G3: infinite-loop test failed via per-file timeout, not outer bound" "1" "$rc"
    case "$out" in
        *"unit: FAIL $FX/infinite-loop-test.sh"*) assert_pass "G3: hung test surfaced as FAIL (not a hang)" ;;
        *) assert_fail "G3: infinite-loop test must surface as FAIL" "out: $out" ;;
    esac
else
    assert_pass "G3: skipped — no real gtimeout/timeout on host (run-tests.sh degrades to no-timeout)"
fi

# ─── G4: a MISSING *-test.sh path is SKIPPED, never a phantom failure (#1239) ─
# The targeted re-run list is an advisory hint. A path that does not resolve
# (e.g. a stale absolute path into a destroyed per-iter temp dir) must be
# skipped — running `bash <missing>` would surface a bogus "No such file" FAIL
# and inflate the failure count (the #945 dogfood 5->10 phantom-failure bug).
out="$("${_OUTER[@]}" bash "$RUN_TESTS" --files "$FX/good-test.sh" "$FX/gone-test.sh" 2>&1)"
rc=$?
assert_eq "G4: run returns 0 — a missing test path is not a failure" "0" "$rc"
case "$out" in
    *"skip missing: $FX/gone-test.sh"*) assert_pass "G4: missing test path skipped, not executed" ;;
    *) assert_fail "G4: missing test path should be skipped" "out: $out" ;;
esac
case "$out" in
    *"unit: 1/1 passed"*) assert_pass "G4: denominator counts only the resolvable test (1/1)" ;;
    *) assert_fail "G4: summary must exclude the missing path (expected 1/1)" "out: $out" ;;
esac
case "$out" in
    *"FAIL $FX/gone-test.sh"*) assert_fail "G4: missing path must NOT surface as FAIL" "out: $out" ;;
    *) assert_pass "G4: missing path produced no phantom FAIL line" ;;
esac

cleanup_test_env
print_test_results
exit $((FAIL > 0))
