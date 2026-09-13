#!/usr/bin/env bash
# A coverage run must report how much trace each file produced.
#
# Coverage broke on main at exactly one commit — 563aab3b (#2065), which added
# requires-core.sh and 57 lines to manifest-validation.sh. Measured on the
# boundary, running the same file under tracing from bash:
#
#   df277e9e (last green)  wall=195s  trace=224,730,454 bytes
#   563aab3b (first red)   wall=213s  trace=314,276,976 bytes
#
# +89.5MB of trace (+40%) from one commit, and on CI that is what pushes
# template-resolvability-preflight-test.sh past the 480s per-file bound.
#
# None of that was visible. The job reported only "TIMEOUT … exceeded 480s" with
# every assertion in the file passing, so the obvious readings were "the test
# hangs" or "the bound is too tight" — both wrong, and both cost a round of
# investigation. Trace VOLUME is the quantity that actually moved, and nothing
# recorded it.
#
# Recording it per file turns the next such regression into a number in the log
# instead of a mystery kill.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "a coverage run reports per-file trace volume"
setup_test_env "coverage-trace-volume-report"

# A private one-file tests dir, driven through the TIER path.
#
# Not `--files`: that path exits before --coverage-trace is parsed (it treats
# the flag as a filename, "skip non-test: --coverage-trace") and calls _rt_run
# with no trace argument at all, so tracing is silently off there. Only the
# tier loops pass a trace file. check-coverage.sh uses `--tier unit`, so the
# tier path is also the one production actually exercises.
_TDIR="$TEST_TEMP_DIR/tests"
mkdir -p "$_TDIR/unit"
_probe="$_TDIR/unit/probe-test.sh"
printf '#!/usr/bin/env bash\nfor i in $(seq 1 200); do :; done\nexit 0\n' > "$_probe"
_timing="$TEST_TEMP_DIR/timing.txt"
_trace="$TEST_TEMP_DIR/trace.out"

( cd "$REPO_ROOT" && ZBUILD_TESTS_DIR="$_TDIR" ZBUILD_TEST_TIMING_FILE="$_timing" \
    bash scripts/run-tests.sh --tier unit --coverage-trace "$_trace" \
    >/dev/null 2>&1 ) || true

# ─── SPEC-1: the timing record carries trace bytes for a traced run ─────────
_vol_line="$(grep -E '^trace ' "$_timing" 2>/dev/null || true)"
if [[ -n "$_vol_line" ]]; then
    assert_pass "[SPEC-1] a traced run records per-file trace volume"
else
    assert_fail "[SPEC-1] a traced run records per-file trace volume" \
        "timing file: $(tr '\n' '|' < "$_timing" 2>/dev/null || echo '<empty>')"
fi

# The recorded figure must be a real byte count, not a placeholder — a zero for
# a file that demonstrably produced trace would make the record worse than none.
_vol_bytes="$(awk '/^trace /{print $2; exit}' "$_timing" 2>/dev/null || true)"
assert_gt "[SPEC-1] the recorded volume is a real byte count" "${_vol_bytes:-0}" "0"

# ─── SPEC-2: GUARD — an untraced run records no volume line ────────────────
# Instrumentation must not change the untraced path: the parallel tier's
# byte-identical-output guarantee depends on it (#1058).
_timing2="$TEST_TEMP_DIR/timing-plain.txt"
( cd "$REPO_ROOT" && ZBUILD_TESTS_DIR="$_TDIR" ZBUILD_TEST_TIMING_FILE="$_timing2" \
    bash scripts/run-tests.sh --tier unit >/dev/null 2>&1 ) || true
assert_eq "[SPEC-2] GUARD: an untraced run records no trace-volume line" \
    "0" "$(grep -cE '^trace ' "$_timing2" 2>/dev/null || true)"
assert_gt "[SPEC-2] GUARD: an untraced run still records its duration" \
    "$(grep -cE '^file ' "$_timing2" 2>/dev/null || true)" "0"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
