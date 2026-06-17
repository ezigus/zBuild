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

print_test_header "run-tests.sh --files guard: non-test/hanging files can't wedge it (#929)"
setup_test_env "run-tests-files-guard"

# Portable outer bound so this test can never hang, even against unfixed code.
_OUTER=()
if   command -v gtimeout >/dev/null 2>&1; then _OUTER=(gtimeout 30)
elif command -v timeout  >/dev/null 2>&1; then _OUTER=(timeout 30)
fi

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
# Short per-file timeout so the loop is bounded; outer gtimeout is the backstop.
out="$(ZBUILD_TEST_FILE_TIMEOUT=3 "${_OUTER[@]}" bash "$RUN_TESTS" --files "$FX/infinite-loop-test.sh" 2>&1)"
rc=$?
# run-tests.sh exits 1 when a file fails; the OUTER bound (30s) must NOT be what
# stopped it — the per-file timeout (3s) should. rc=124 here would mean the
# outer bound fired = the per-file timeout did NOT work = still wedged.
assert_eq "G3: infinite-loop test failed via per-file timeout, not outer bound" "1" "$rc"
case "$out" in
    *"unit: FAIL $FX/infinite-loop-test.sh"*) assert_pass "G3: hung test surfaced as FAIL (not a hang)" ;;
    *) assert_fail "G3: infinite-loop test must surface as FAIL" "out: $out" ;;
esac

cleanup_test_env
print_test_results
exit $((FAIL > 0))
