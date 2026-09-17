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

# ─── G3: an infinite-loop *-test.sh is killed by the per-file timeout ─────────
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
    # #1613: this file is killed at its bound, so the marker is TIMEOUT, not FAIL.
    # G3's subject is unchanged — the hung file must SURFACE rather than wedge the
    # run — but asserting `FAIL` here would now be asserting the exact conflation
    # #1613 exists to remove, since a reader could not tell this from an assertion
    # failure. The bound is named so the line is self-explaining.
    case "$out" in
        *"unit: TIMEOUT $FX/infinite-loop-test.sh (exceeded 3s,"*)
            assert_pass "G3: hung test surfaced as TIMEOUT naming the bound (not a hang)" ;;
        *) assert_fail "G3: infinite-loop test must surface as TIMEOUT" "out: $out" ;;
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

# ─── #2123: --files runs through the same bounded pool as a tier ─────────────
# A targeted rerun of 286 files ran them one after another (39 minutes on
# #1841's iteration 2). Three 1-second files at JOBS=3 must finish in ~1s, and
# the output grammar the verdict parser reads must be byte-identical to serial.
print_test_section "#2123: --files is parallel"
PFX="$TEST_TEMP_DIR/pfx"; mkdir -p "$PFX"
for n in 1 2 3; do
    printf '#!/usr/bin/env bash\nsleep 1\nexit 0\n' > "$PFX/p$n-test.sh"; chmod +x "$PFX/p$n-test.sh"
done
printf '#!/usr/bin/env bash\nexit 1\n' > "$PFX/p4-fail-test.sh"; chmod +x "$PFX/p4-fail-test.sh"
_t0=$(date +%s)
_par_out="$(cd "$REPO_ROOT" && ZBUILD_TEST_PARALLEL_JOBS=4 "${_OUTER[@]}" bash "$RUN_TESTS" --files "$PFX/p1-test.sh" "$PFX/p2-test.sh" "$PFX/p3-test.sh" "$PFX/p4-fail-test.sh" 2>"$TEST_TEMP_DIR/par.err")"; _par_rc=$?
_par_secs=$(( $(date +%s) - _t0 ))
_t1=$(date +%s)
_ser_out="$(cd "$REPO_ROOT" && ZBUILD_TEST_PARALLEL_JOBS=0 "${_OUTER[@]}" bash "$RUN_TESTS" --files "$PFX/p1-test.sh" "$PFX/p2-test.sh" "$PFX/p3-test.sh" "$PFX/p4-fail-test.sh" 2>"$TEST_TEMP_DIR/ser.err")"; _ser_rc=$?
_ser_secs=$(( $(date +%s) - _t1 ))
# Relative, not absolute: `date +%s` truncates and a loaded runner adds
# startup overhead, so "parallel is faster than serial" is the claim.
if [[ "$_par_secs" -lt "$_ser_secs" ]]; then
    assert_pass "[#2123] three 1s files at JOBS=4 finish faster than serial (${_par_secs}s < ${_ser_secs}s)"
else
    assert_fail "[#2123] --files must run files concurrently" "parallel ${_par_secs}s, serial ${_ser_secs}s"
fi
# Serial-pinned files run first, alone, whatever their argument position.
printf '#!/usr/bin/env bash\ndate +%%s > "%s/pin-start"\nsleep 1\nexit 0\n' "$PFX" > "$PFX/pin-test.sh"; chmod +x "$PFX/pin-test.sh"
printf '#!/usr/bin/env bash\ndate +%%s > "%s/p1-start"\nsleep 1\nexit 0\n' "$PFX" > "$PFX/p1-test.sh"
_pin_out="$(cd "$REPO_ROOT" && ZBUILD_TEST_PARALLEL_JOBS=4 ZBUILD_SERIAL_TESTS='pin-test.sh' "${_OUTER[@]}" bash "$RUN_TESTS" --files "$PFX/p1-test.sh" "$PFX/pin-test.sh" 2>/dev/null)"
if [[ "$(cat "$PFX/pin-start")" -lt "$(cat "$PFX/p1-start")" ]]; then
    assert_pass "[#2123] a serial-pinned file listed second still runs before the pool starts"
else
    assert_fail "[#2123] a serial-pinned file must run first, alone" "pin=$(cat "$PFX/pin-start") p1=$(cat "$PFX/p1-start")"
fi
assert_contains "[#2123] …and the summary still counts both" "$_pin_out" "unit: 2/2 passed"
assert_eq "[#2123] parallel stdout is byte-identical to serial" "$_ser_out" "$_par_out"
assert_eq "[#2123] parallel rc equals serial rc (a failing file still fails the run)" "$_ser_rc" "$_par_rc"
assert_contains "[#2123] the FAIL line still names the file on stderr" "$(cat "$TEST_TEMP_DIR/par.err")" "unit: FAIL $PFX/p4-fail-test.sh"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
