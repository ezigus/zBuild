#!/usr/bin/env bash
# Tests: scripts/run-tests.sh --tier all runs the tiers CONCURRENTLY (#997).
# (#1129 Change C added a `lint` tier; this test stubs it via ZBUILD_LINT_CMD=true
# so the fake-tier hermeticity holds — see the _all helper.)
#
# Before #997 the `all` branch ran unit→integration→e2e→golden→mutation serially
# inside one process-substitution, so the ~8min mutation tier (2nd-longest, last)
# never overlapped the others. #997 fans the tiers out as background subshells
# while keeping the output BYTE-IDENTICAL to the serial path: each tier's stdout
# and stderr are captured SEPARATELY and replayed to their ORIGINAL fds in
# canonical order (a 2>&1 merge would move run_tier's `name: FAIL <f>` stderr
# onto stdout and break parity — the make-or-break detail).
#
# Hermetic by construction: every invocation targets FAKE tiers via
# ZBUILD_TESTS_DIR and an EMPTY mutation dir via ZBUILD_MUTATION_DIR, so no real
# tier or mutation spec ever runs. ZBUILD_TIER_CONCURRENCY=0 selects the verbatim
# serial path (the parity baseline + escape hatch). ZBUILD_TIER_BUDGET pins the
# job budget so the floor(B/2) split is deterministic regardless of host CPUs.
#
# SPEC-1  CHANGE  tiers OVERLAP: concurrent wall-clock < 0.7x the serial sum
# SPEC-2  CHANGE  byte-identical stdout (serial vs concurrent), stderr FAIL order
# SPEC-3  GUARD   a failing tier → exit 1 (both paths); all-clean → exit 0
# SPEC-4  CHANGE  budget split: unit JOBS=floor(B/2), mutation JOBS=ceil(B/2), sum<=B
# SPEC-5  CHANGE  per-tier distinct TMPDIR; coverage traces concat in canonical order
# SPEC-6  GUARD   UPDATE_GOLDEN=1 → serial path (no buf_dir), still byte-identical
# SPEC-7  GUARD   ZBUILD_TIER_CONCURRENCY=0 → serial path
# SPEC-8  GUARD   --tier unit and --files a-test.sh unchanged from baseline
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUN_TESTS="$REPO_ROOT/scripts/run-tests.sh"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "run-tests.sh cross-tier concurrency (#997)"
setup_test_env "run-tests-tier-concurrency"

EMPTY_DIR="$TEST_TEMP_DIR/empty"
EMPTY_MUT="$TEST_TEMP_DIR/empty-mut"
mkdir -p "$EMPTY_DIR" "$EMPTY_MUT"

# ─── Hermetic fixtures ───────────────────────────────────────────────────────
# "fast" fixture: every tier has one instant-pass test → cheap parity/budget runs.
FAST="$TEST_TEMP_DIR/fast"
for t in unit integration e2e golden; do
  mkdir -p "$FAST/$t"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$FAST/$t/p-test.sh"
  chmod +x "$FAST/$t/p-test.sh"
done

# "slow" fixture: each tier's single test sleeps ~1s. Serial = ~4s (4 sleeping
# tiers; mutation dir empty → instant). Concurrent should be ~1s → well under 0.7x.
SLOW="$TEST_TEMP_DIR/slow"
for t in unit integration e2e golden; do
  mkdir -p "$SLOW/$t"
  printf '#!/usr/bin/env bash\nsleep 1\nexit 0\n' > "$SLOW/$t/s-test.sh"
  chmod +x "$SLOW/$t/s-test.sh"
done

# "fail" fixture: golden tier has one failing test, everything else passes.
FAILF="$TEST_TEMP_DIR/failf"
for t in unit integration e2e; do
  mkdir -p "$FAILF/$t"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$FAILF/$t/p-test.sh"
  chmod +x "$FAILF/$t/p-test.sh"
done
mkdir -p "$FAILF/golden"
printf '#!/usr/bin/env bash\necho "boom" >&2\nexit 1\n' > "$FAILF/golden/f-test.sh"
chmod +x "$FAILF/golden/f-test.sh"

# _all <fixture_tests_dir> [extra env...] — run `--tier all` against fake tiers +
# an empty mutation dir. Force the safe-tier list to all four file-tiers so the
# job-count plumbing is observable; integration parallel-safety (#991) is out of
# scope here. Captures stdout/stderr/rc separately.
_all() {
  local td="$1"; shift
  local out_f="$TEST_TEMP_DIR/o.txt" err_f="$TEST_TEMP_DIR/e.txt" rc=0
  # #1129 Change C: lint is now a `--tier all` tier. Stub it to an instant pass
  # (ZBUILD_LINT_CMD=true) to keep this concurrency test hermetic — without this
  # the lint tier would shell out to the real `npm run lint` (shellcheck over the
  # whole tree) on every _all invocation, defeating the fake-tier design.
  env -u ZBUILD_TEST_PARALLEL_JOBS -u ZBUILD_PARALLEL_SAFE_TIERS \
      -u ZBUILD_TIER_CONCURRENCY -u ZBUILD_TIER_BUDGET -u UPDATE_GOLDEN \
      ZBUILD_TESTS_DIR="$td" \
      ZBUILD_PLUGINS_DIR="$EMPTY_DIR" \
      ZBUILD_CORE_DIR="$EMPTY_DIR" \
      ZBUILD_MUTATION_DIR="$EMPTY_MUT" \
      ZBUILD_LINT_CMD=true \
      ZBUILD_PARALLEL_SAFE_TIERS="unit integration e2e golden" \
      "$@" \
      bash "$RUN_TESTS" --tier all \
      >"$out_f" 2>"$err_f" || rc=$?
  _OUT="$(cat "$out_f")"; _ERR="$(cat "$err_f")"; _RC="$rc"
}

# ─── [SPEC-1] CHANGE: tiers overlap (wall-clock) ─────────────────────────────
_t0=$(date +%s)
_all "$SLOW" ZBUILD_TIER_CONCURRENCY=0
_serial_secs=$(( $(date +%s) - _t0 ))
_t0=$(date +%s)
_all "$SLOW"   # concurrency default-on
_conc_secs=$(( $(date +%s) - _t0 ))
# Threshold: concurrent must beat 0.7x serial. Use integer math (x10) to avoid
# bc; require serial>=3s so the fixture actually exercised overlap.
if [[ "$_serial_secs" -ge 3 && $(( _conc_secs * 10 )) -lt $(( _serial_secs * 7 )) ]]; then
  assert_pass "[SPEC-1] concurrent ($_conc_secs s) < 0.7x serial ($_serial_secs s)"
else
  assert_fail "[SPEC-1] tiers must overlap" "serial=${_serial_secs}s concurrent=${_conc_secs}s"
fi

# ─── [SPEC-2] CHANGE: byte-identical stdout (serial vs concurrent) ───────────
_all "$FAST" ZBUILD_TIER_CONCURRENCY=0
_ser_out="$_OUT"
_all "$FAST"
_conc_out="$_OUT"
if [[ "$_ser_out" == "$_conc_out" ]]; then
  assert_pass "[SPEC-2] serial and concurrent stdout byte-identical"
else
  assert_fail "[SPEC-2] stdout must be byte-identical" "$(diff <(printf '%s' "$_ser_out") <(printf '%s' "$_conc_out") | head)"
fi
# Canonical order + total line: summaries unit→integration→e2e→golden→mutation→
# lint (#1129 Change C added lint as the last tier), blank line, then
# `total: N/N passed` LAST. The stubbed lint (ZBUILD_LINT_CMD=true) passes 1/1.
_expected_stdout="$(printf 'unit: 1/1 passed\nintegration: 1/1 passed\ne2e: 1/1 passed\ngolden: 1/1 passed\nmutation: 0/0 passed\nlint: 1/1 passed\n\ntotal: 5/5 passed')"
assert_eq "[SPEC-2b] concurrent stdout matches canonical order + total" "$_expected_stdout" "$_conc_out"

# FAIL lines land on STDERR (not stdout), in canonical tier order.
_all "$FAILF"
case "$_ERR" in
  *"golden: FAIL "*) assert_pass "[SPEC-2c] FAIL line lands on stderr" ;;
  *) assert_fail "[SPEC-2c] FAIL line must be on stderr" "stderr: $_ERR" ;;
esac
case "$_OUT" in
  *"FAIL "*) assert_fail "[SPEC-2d] FAIL line must NOT appear on stdout" "stdout: $_OUT" ;;
  *) assert_pass "[SPEC-2d] no FAIL line on stdout (no 2>&1 merge)" ;;
esac

# ─── [SPEC-3] GUARD: failing tier → exit 1; clean → exit 0 ───────────────────
_all "$FAILF"
assert_eq "[SPEC-3] failing tier → exit 1 (concurrent)" "1" "$_RC"
_all "$FAILF" ZBUILD_TIER_CONCURRENCY=0
assert_eq "[SPEC-3b] failing tier → exit 1 (serial)" "1" "$_RC"
_all "$FAST"
assert_eq "[SPEC-3c] all-clean → exit 0 (concurrent)" "0" "$_RC"

# ─── [SPEC-4] CHANGE: budget split unit=floor(B/2), mutation=ceil(B/2) ───────
# Hook: unit's fake test records the JOBS it received; a wrapper mutation script
# is NOT reachable (we run the real run-mutation.sh against an empty dir), so we
# assert the unit half via a parallel-active probe + a JOBS-echo fixture.
HOOK="$TEST_TEMP_DIR/jobs-hook"
JOBS_FIX="$TEST_TEMP_DIR/jobsfix"
for t in unit integration e2e golden; do
  mkdir -p "$JOBS_FIX/$t"
  # Each tier's test writes the parallel-jobs value it sees to a per-tier hook.
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "${ZBUILD_TEST_PARALLEL_JOBS:-UNSET}" > "%s.%s"\nexit 0\n' \
    "$HOOK" "$t" > "$JOBS_FIX/$t/j-test.sh"
  chmod +x "$JOBS_FIX/$t/j-test.sh"
done
rm -f "$HOOK".*
_all "$JOBS_FIX" ZBUILD_TIER_BUDGET=6
_u_jobs="$(cat "$HOOK.unit" 2>/dev/null || echo MISSING)"
_e_jobs="$(cat "$HOOK.e2e" 2>/dev/null || echo MISSING)"
assert_eq "[SPEC-4] unit tier sees JOBS=floor(6/2)=3" "3" "$_u_jobs"
assert_eq "[SPEC-4b] non-unit file-tier (e2e) sees JOBS=0 (serial within tier)" "0" "$_e_jobs"

# ─── [SPEC-5] CHANGE: per-tier distinct TMPDIR + coverage concat ─────────────
TMP_HOOK="$TEST_TEMP_DIR/tmp-hook"
TMP_FIX="$TEST_TEMP_DIR/tmpfix"
for t in unit integration e2e golden; do
  mkdir -p "$TMP_FIX/$t"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "${TMPDIR:-NONE}" > "%s.%s"\nexit 0\n' \
    "$TMP_HOOK" "$t" > "$TMP_FIX/$t/tt-test.sh"
  chmod +x "$TMP_FIX/$t/tt-test.sh"
done
rm -f "$TMP_HOOK".*
_all "$TMP_FIX"
_tmp_unit="$(cat "$TMP_HOOK.unit" 2>/dev/null || echo A)"
_tmp_e2e="$(cat "$TMP_HOOK.e2e" 2>/dev/null || echo B)"
if [[ -n "$_tmp_unit" && "$_tmp_unit" != "$_tmp_e2e" ]]; then
  assert_pass "[SPEC-5] unit and e2e see distinct TMPDIR"
else
  assert_fail "[SPEC-5] tiers must get distinct TMPDIR" "unit=$_tmp_unit e2e=$_tmp_e2e"
fi

# coverage: per-tier traces concat in canonical order → final trace non-empty.
COV="$TEST_TEMP_DIR/cov.trace"
env -u ZBUILD_TEST_PARALLEL_JOBS -u ZBUILD_PARALLEL_SAFE_TIERS \
    -u ZBUILD_TIER_CONCURRENCY -u ZBUILD_TIER_BUDGET -u UPDATE_GOLDEN \
    ZBUILD_TESTS_DIR="$FAST" \
    ZBUILD_PLUGINS_DIR="$EMPTY_DIR" \
    ZBUILD_CORE_DIR="$EMPTY_DIR" \
    ZBUILD_MUTATION_DIR="$EMPTY_MUT" \
    ZBUILD_LINT_CMD=true \
    ZBUILD_PARALLEL_SAFE_TIERS="unit integration e2e golden" \
    bash "$RUN_TESTS" --tier all --coverage-trace "$COV" >/dev/null 2>&1 || true
if [[ -s "$COV" ]]; then
  assert_pass "[SPEC-5b] coverage trace concatenated (non-empty) under concurrent --tier all"
else
  assert_fail "[SPEC-5b] coverage trace must be non-empty" "trace: $COV"
fi

# ─── [SPEC-6] GUARD: UPDATE_GOLDEN=1 → serial path, byte-identical ───────────
_all "$FAST" ZBUILD_TIER_CONCURRENCY=0
_ser_out="$_OUT"
_all "$FAST" UPDATE_GOLDEN=1
assert_eq "[SPEC-6] UPDATE_GOLDEN=1 stdout identical to serial" "$_ser_out" "$_OUT"

# ─── [SPEC-7] GUARD: ZBUILD_TIER_CONCURRENCY=0 → serial, identical ───────────
_all "$FAST"
_conc_out="$_OUT"
_all "$FAST" ZBUILD_TIER_CONCURRENCY=0
assert_eq "[SPEC-7] CONCURRENCY=0 stdout identical to concurrent" "$_conc_out" "$_OUT"

# ─── [SPEC-8] GUARD: single-tier + --files unaffected ────────────────────────
_st_out="$(env -u ZBUILD_TEST_PARALLEL_JOBS ZBUILD_TESTS_DIR="$FAST" \
  ZBUILD_PLUGINS_DIR="$EMPTY_DIR" ZBUILD_CORE_DIR="$EMPTY_DIR" \
  bash "$RUN_TESTS" --tier unit 2>/dev/null)"; _st_rc=$?
assert_eq "[SPEC-8] --tier unit summary unchanged" "unit: 1/1 passed" "$_st_out"
assert_eq "[SPEC-8b] --tier unit exit 0" "0" "$_st_rc"

_files_tf="$TEST_TEMP_DIR/x-test.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$_files_tf"; chmod +x "$_files_tf"
_files_out="$(bash "$RUN_TESTS" --files "$_files_tf" 2>/dev/null)"; _files_rc=$?
assert_eq "[SPEC-8c] --files summary unchanged" "unit: 1/1 passed" "$_files_out"
assert_eq "[SPEC-8d] --files exit 0" "0" "$_files_rc"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
