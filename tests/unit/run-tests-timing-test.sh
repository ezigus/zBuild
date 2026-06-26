#!/usr/bin/env bash
# Tests: scripts/run-tests.sh per-tier + per-file timing instrumentation (#1058 A).
#
# #1058 Phase A makes per-tier AND per-test-file wall-clock measurable WITHOUT
# changing any default behavior. ALL new behavior is gated on ZBUILD_TEST_TIMING_FILE
# being set+non-empty: when unset, run-tests.sh output/behavior is byte-identical
# to pre-#1058 (the parallel path's byte-identical-output guarantee).
#
# Hermetic by construction: FAKE tiers via ZBUILD_TESTS_DIR + an empty plugins/core
# dir, so no real test ever runs. Each scenario writes the timing log to a fresh
# path under TEST_TEMP_DIR.
#
# SPEC-1  CHANGE  with ZBUILD_TEST_TIMING_FILE set, a tier run writes `file <ms> <path>`
# SPEC-2  CHANGE  ... and a `tier <ms> <name>` line for the finished tier
# SPEC-3  GUARD   with the var UNSET, stdout/stderr are byte-identical to a baseline
#                 run and NO timing lines leak onto either stream
# SPEC-4  CHANGE  ms values are non-negative integers (a `sleep`-ing file reads > 0)
# SPEC-5  GUARD   timing failure (unwritable path) never changes rc or output
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUN_TESTS="$REPO_ROOT/scripts/run-tests.sh"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "run-tests.sh timing instrumentation (#1058 Phase A)"
setup_test_env "run-tests-timing"

EMPTY_DIR="$TEST_TEMP_DIR/empty"
mkdir -p "$EMPTY_DIR"

# Fixture: a unit tier with one instant-pass and one ~50ms-sleeping test.
FIX="$TEST_TEMP_DIR/fix"
mkdir -p "$FIX/unit"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FIX/unit/p-test.sh"
printf '#!/usr/bin/env bash\nsleep 0.05\nexit 0\n' > "$FIX/unit/s-test.sh"
chmod +x "$FIX/unit/p-test.sh" "$FIX/unit/s-test.sh"

# _unit <timing_file|""> [extra env...] — run `--tier unit` against the fake tier.
# Captures stdout/stderr/rc separately into _OUT/_ERR/_RC. Force serial within the
# tier (JOBS=0) so the run is deterministic; the timing path is the same _rt_run
# choke point on both serial and parallel paths.
_unit() {
  local tf="$1"; shift
  local out_f="$TEST_TEMP_DIR/o.txt" err_f="$TEST_TEMP_DIR/e.txt" rc=0
  local -a _tf_env=()
  [[ -n "$tf" ]] && _tf_env=(ZBUILD_TEST_TIMING_FILE="$tf")
  env -u ZBUILD_TEST_TIMING_FILE \
      ZBUILD_TESTS_DIR="$FIX" \
      ZBUILD_PLUGINS_DIR="$EMPTY_DIR" \
      ZBUILD_CORE_DIR="$EMPTY_DIR" \
      ZBUILD_TEST_PARALLEL_JOBS=0 \
      "${_tf_env[@]}" \
      "$@" \
      bash "$RUN_TESTS" --tier unit \
      >"$out_f" 2>"$err_f" || rc=$?
  _OUT="$(cat "$out_f")"; _ERR="$(cat "$err_f")"; _RC="$rc"
}

# ─── [SPEC-1/2/4] CHANGE: timing file gets file + tier lines ──────────────────
TF="$TEST_TEMP_DIR/timing.log"
rm -f "$TF"
_unit "$TF"
assert_eq "[SPEC-1pre] timed run still exits 0" "0" "$_RC"
assert_eq "[SPEC-1pre2] timed run summary unchanged" "unit: 2/2 passed" "$_OUT"

if [[ -s "$TF" ]]; then
  assert_pass "[SPEC-1] timing file written"
else
  assert_fail "[SPEC-1] timing file must be written" "missing/empty: $TF"
fi

# `file <ms> <path>` for each test file.
if grep -Eq '^file [0-9]+ .*p-test\.sh$' "$TF"; then
  assert_pass "[SPEC-1b] file line for p-test.sh present"
else
  assert_fail "[SPEC-1b] missing 'file <ms> <path>' for p-test.sh" "$(cat "$TF")"
fi
if grep -Eq '^file [0-9]+ .*s-test\.sh$' "$TF"; then
  assert_pass "[SPEC-1c] file line for s-test.sh present"
else
  assert_fail "[SPEC-1c] missing 'file <ms> <path>' for s-test.sh" "$(cat "$TF")"
fi

# `tier <ms> <name>` for the finished tier.
if grep -Eq '^tier [0-9]+ unit$' "$TF"; then
  assert_pass "[SPEC-2] tier line for 'unit' present"
else
  assert_fail "[SPEC-2] missing 'tier <ms> unit'" "$(cat "$TF")"
fi

# ms for the sleeping file should be > 0 (≥ ~50ms). Tolerant lower bound (>0).
_s_ms="$(grep -E '^file [0-9]+ .*s-test\.sh$' "$TF" | awk '{print $2}' | head -1)"
if [[ "$_s_ms" =~ ^[0-9]+$ && "$_s_ms" -gt 0 ]]; then
  assert_pass "[SPEC-4] sleeping file recorded > 0 ms ($_s_ms)"
else
  assert_fail "[SPEC-4] sleeping file ms must be a positive integer" "got: $_s_ms"
fi

# ─── [SPEC-3] GUARD: UNSET → byte-identical output, no timing lines ───────────
_unit ""              # var unset
_base_out="$_OUT"; _base_err="$_ERR"; _base_rc="$_RC"
assert_eq "[SPEC-3] unset-path exit 0" "0" "$_base_rc"
assert_eq "[SPEC-3b] unset-path summary unchanged" "unit: 2/2 passed" "$_base_out"

# stdout/stderr from the TIMED run (above) vs the UNSET run must be byte-identical:
# timing goes ONLY to the file, never to stdout/stderr.
_unit "$TEST_TEMP_DIR/timing2.log"
assert_eq "[SPEC-3c] stdout byte-identical (timed vs unset)" "$_base_out" "$_OUT"
assert_eq "[SPEC-3d] stderr byte-identical (timed vs unset)" "$_base_err" "$_ERR"

# No `file `/`tier ` instrumentation tokens leak onto either stream.
case "$_base_out$_base_err" in
  *"file "*|*"tier "*)
    assert_fail "[SPEC-3e] no timing token may leak to stdout/stderr" "out=$_base_out err=$_base_err" ;;
  *) assert_pass "[SPEC-3e] no timing token leaked to stdout/stderr" ;;
esac

# ─── [SPEC-5] GUARD: unwritable timing path never changes rc/output ───────────
# Point the timing file at a path whose parent does not exist → the `>>` redirect
# fails, but `|| true` swallows it. rc + output must be unaffected.
_unit "$TEST_TEMP_DIR/nonexistent-dir/timing.log"
assert_eq "[SPEC-5] unwritable timing path → still exit 0" "0" "$_RC"
assert_eq "[SPEC-5b] unwritable timing path → summary unchanged" "unit: 2/2 passed" "$_OUT"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
