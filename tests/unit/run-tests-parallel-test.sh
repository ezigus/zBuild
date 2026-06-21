#!/usr/bin/env bash
# Tests: bounded parallel execution in scripts/run-tests.sh (issues #983 + #984, EPIC #982).
#
# #983 made parallel test execution safe by construction; #984 makes it the DEFAULT
# for safe tiers:
#   - safe tiers (unit) run PARALLEL BY DEFAULT (#984); ZBUILD_TEST_PARALLEL_JOBS
#     unset → computed default; set to 0 → serial escape hatch; set to N → N jobs,
#   - tier-gated to a safe allow-list (ZBUILD_PARALLEL_SAFE_TIERS, default "unit")
#     so non-safe tiers (e.g. integration, until #991) stay serial even by default
#     — this is the fix for the fork-bomb that deadlocked the integration tier's
#     route.sh/claude-spawning tests when run concurrently,
#   - guarded against re-entrancy (ZBUILD_RUN_TESTS_ACTIVE) so a test can never
#     fork-bomb the suite by invoking run-tests.sh against a real tier,
#   - coverage (PS4-traced) is forced serial — see SPEC-12.
#
# EVERY invocation here targets a hermetic FAKE tier via ZBUILD_TESTS_DIR — never
# the real repo tier — so this test cannot itself recurse into the live suite.
#
# SPEC-1  CHANGE  parallel path is ACTIVATED for a safe tier (unit) when JOBS>0
# SPEC-2  GUARD   parallel-mode summary line is correct (4/6)
# SPEC-3  GUARD   parallel mode emits one FAIL line per failing file (2)
# SPEC-4  GUARD   parallel mode exits 1 when a file fails
# SPEC-5  GUARD   serial (JOBS=0) and parallel summaries are identical
# SPEC-6  GUARD   non-safe tier (integration) stays SERIAL even with JOBS>0
# SPEC-7  CHANGE  re-entrancy guard refuses a nested real-tier run (no fixture) → exit 2
# SPEC-8  GUARD   guard exempts fixture-isolated nested runs (ZBUILD_TESTS_DIR set)
# SPEC-9  CHANGE  unit runs PARALLEL BY DEFAULT when JOBS is UNSET (#984)
# SPEC-10 GUARD   JOBS=0 is the serial escape hatch (NOT activated) even by default
# SPEC-11 GUARD   non-safe tier (integration) stays serial BY DEFAULT (JOBS unset)
# SPEC-12 GUARD   check-coverage.sh forces JOBS=0 (PS4 trace needs serial, #984)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUN_TESTS="$REPO_ROOT/scripts/run-tests.sh"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "run-tests.sh bounded parallel execution (#983)"
setup_test_env "run-tests-parallel"

# ─── Hermetic fixture: a fake unit tier (4 pass, 2 fail) + a fake integration
#     tier (2 pass, 1 fail). ZBUILD_TESTS_DIR/PLUGINS_DIR/CORE_DIR isolate them so
#     no real repo tests mix into the counts and no real tier is ever executed.
FAKE_TESTS="$TEST_TEMP_DIR/fake-tests"
EMPTY_DIR="$TEST_TEMP_DIR/empty"
ACT_FILE="$TEST_TEMP_DIR/par-active"
mkdir -p "$FAKE_TESTS/unit" "$FAKE_TESTS/integration" "$EMPTY_DIR"

for i in 1 2 3 4; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_TESTS/unit/pass-${i}-test.sh"
  chmod +x "$FAKE_TESTS/unit/pass-${i}-test.sh"
done
for i in 1 2; do
  printf '#!/usr/bin/env bash\necho "fixture fail %s" >&2\nexit 1\n' "$i" \
    > "$FAKE_TESTS/unit/fail-${i}-test.sh"
  chmod +x "$FAKE_TESTS/unit/fail-${i}-test.sh"
done
for i in 1 2; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_TESTS/integration/ipass-${i}-test.sh"
  chmod +x "$FAKE_TESTS/integration/ipass-${i}-test.sh"
done
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKE_TESTS/integration/ifail-1-test.sh"
chmod +x "$FAKE_TESTS/integration/ifail-1-test.sh"

# _run_tier <tier> [extra env assignments...] — run run-tests.sh against the fake
# tier with a FRESH activation-hook file. Captures stdout/stderr/rc separately.
_run_tier() {
  local tier="$1"; shift
  local out_f="$TEST_TEMP_DIR/stdout.txt" err_f="$TEST_TEMP_DIR/stderr.txt" rc=0
  : > "$ACT_FILE"   # reset the activation hook each call
  # `env -u` clears any AMBIENT ZBUILD_TEST_PARALLEL_JOBS / SAFE_TIERS so the
  # "unset → default-parallel" SPECs are hermetic. Without this, a caller env
  # that sets JOBS (e.g. check-coverage.sh forces JOBS=0) would leak in and make
  # the no-JOBS cases run serial. Explicit "$@" assignments re-add after -u.
  env -u ZBUILD_TEST_PARALLEL_JOBS -u ZBUILD_PARALLEL_SAFE_TIERS \
      ZBUILD_TESTS_DIR="$FAKE_TESTS" \
      ZBUILD_PLUGINS_DIR="$EMPTY_DIR" \
      ZBUILD_CORE_DIR="$EMPTY_DIR" \
      _ZBUILD_PAR_ACTIVE_FILE="$ACT_FILE" \
      "$@" \
      bash "$RUN_TESTS" --tier "$tier" \
      >"$out_f" 2>"$err_f" || rc=$?
  _LAST_STDOUT="$(cat "$out_f")"
  _LAST_STDERR="$(cat "$err_f")"
  _LAST_RC="$rc"
  _LAST_ACTIVATED="$(cat "$ACT_FILE" 2>/dev/null | tr -d '[:space:]')"
}

# ─── [SPEC-1] CHANGE: parallel path activated for the unit tier when JOBS>0 ────
_run_tier unit ZBUILD_TEST_PARALLEL_JOBS=2
assert_eq "[SPEC-1] parallel path activated for safe tier 'unit' when JOBS=2" \
  "unit" "$_LAST_ACTIVATED"

# ─── [SPEC-2] GUARD: parallel summary line correct ───────────────────────────
case "$_LAST_STDOUT" in
  *"unit: 4/6 passed"*) assert_pass "[SPEC-2] parallel-mode summary is 'unit: 4/6 passed'" ;;
  *) assert_fail "[SPEC-2] parallel-mode summary must be 'unit: 4/6 passed'" "stdout: $_LAST_STDOUT" ;;
esac

# ─── [SPEC-3] GUARD: one FAIL line per failing file ──────────────────────────
_fail_count="$(printf '%s\n' "$_LAST_STDERR" | grep -c '^unit: FAIL ' || true)"
assert_eq "[SPEC-3] parallel mode emits exactly 2 FAIL lines" "2" "$_fail_count"

# ─── [SPEC-4] GUARD: exit 1 on failures ──────────────────────────────────────
assert_eq "[SPEC-4] parallel mode exits 1 when a file fails" "1" "$_LAST_RC"

# ─── [SPEC-5] GUARD: serial (JOBS=0) summary identical to parallel ───────────
_par_sum="$(printf '%s\n' "$_LAST_STDOUT" | grep -E '^unit: [0-9]+/[0-9]+ passed' || true)"
_run_tier unit ZBUILD_TEST_PARALLEL_JOBS=0
_ser_sum="$(printf '%s\n' "$_LAST_STDOUT" | grep -E '^unit: [0-9]+/[0-9]+ passed' || true)"
assert_eq "[SPEC-5] serial and parallel summary lines identical" "$_par_sum" "$_ser_sum"

# ─── [SPEC-6] GUARD: non-safe tier (integration) stays serial even with JOBS>0 ─
# Default ZBUILD_PARALLEL_SAFE_TIERS is "unit", so integration must NOT activate
# the parallel path — the structural fix for the fork-bomb.
_run_tier integration ZBUILD_TEST_PARALLEL_JOBS=2
assert_eq "[SPEC-6] non-safe tier 'integration' stays serial (parallel NOT activated)" \
  "" "$_LAST_ACTIVATED"
case "$_LAST_STDOUT" in
  *"integration: 2/3 passed"*) assert_pass "[SPEC-6b] integration accounting correct (2/3) when serial-forced" ;;
  *) assert_fail "[SPEC-6b] integration summary must be 'integration: 2/3 passed'" "stdout: $_LAST_STDOUT" ;;
esac

# ─── [SPEC-7] CHANGE: re-entrancy guard refuses a nested real-tier run ────────
# ZBUILD_RUN_TESTS_ACTIVE set + NO fixture override → must refuse before globbing.
# (No ZBUILD_TESTS_DIR here, so the guard fires immediately and no real tier runs.)
_g_out="$(env ZBUILD_RUN_TESTS_ACTIVE=1 bash "$RUN_TESTS" --tier unit 2>&1)"; _g_rc=$?
assert_eq "[SPEC-7] re-entrancy guard refuses nested real-tier run with exit 2" "2" "$_g_rc"
case "$_g_out" in
  *"refusing nested real-tier invocation"*) assert_pass "[SPEC-7b] guard prints the refusal reason" ;;
  *) assert_fail "[SPEC-7b] guard must print 'refusing nested real-tier invocation'" "got: $_g_out" ;;
esac

# ─── [SPEC-8] GUARD: guard EXEMPTS fixture-isolated nested runs ───────────────
# Same ZBUILD_RUN_TESTS_ACTIVE, but with a fixture override → allowed to run.
_run_tier unit ZBUILD_RUN_TESTS_ACTIVE=1
assert_eq "[SPEC-8] guard exempts fixture-isolated nested run (ZBUILD_TESTS_DIR set) — runs, exits 1" \
  "1" "$_LAST_RC"
case "$_LAST_STDOUT" in
  *"unit: 4/6 passed"*) assert_pass "[SPEC-8b] exempted nested run produces correct accounting" ;;
  *) assert_fail "[SPEC-8b] exempted nested run must produce 'unit: 4/6 passed'" "stdout: $_LAST_STDOUT" ;;
esac

# ─── [SPEC-9] CHANGE: unit runs PARALLEL BY DEFAULT when JOBS is UNSET (#984) ──
# _run_tier sets no JOBS → the internal default (_zb_default_jobs) must activate
# the parallel path for the safe 'unit' tier. At #983 baseline this stayed serial.
_run_tier unit
assert_eq "[SPEC-9] unit activates parallel BY DEFAULT when ZBUILD_TEST_PARALLEL_JOBS is unset" \
  "unit" "$_LAST_ACTIVATED"
case "$_LAST_STDOUT" in
  *"unit: 4/6 passed"*) assert_pass "[SPEC-9b] default-parallel accounting correct (4/6)" ;;
  *) assert_fail "[SPEC-9b] default-parallel summary must be 'unit: 4/6 passed'" "stdout: $_LAST_STDOUT" ;;
esac

# ─── [SPEC-10] GUARD: JOBS=0 is the serial escape hatch even when default-parallel
_run_tier unit ZBUILD_TEST_PARALLEL_JOBS=0
assert_eq "[SPEC-10] explicit JOBS=0 forces serial (parallel NOT activated)" \
  "" "$_LAST_ACTIVATED"

# ─── [SPEC-11] GUARD: non-safe tier stays serial BY DEFAULT (JOBS unset) ──────
_run_tier integration
assert_eq "[SPEC-11] non-safe tier 'integration' stays serial by default (JOBS unset)" \
  "" "$_LAST_ACTIVATED"

# ─── [SPEC-12] GUARD: coverage forces serial (PS4 trace can't run parallel) ───
# check-coverage.sh must pin ZBUILD_TEST_PARALLEL_JOBS=0 on its traced unit run,
# else concurrent workers interleave the fd-9 trace and skew coverage (#984).
_cov="$REPO_ROOT/scripts/check-coverage.sh"
if grep -Eq 'ZBUILD_TEST_PARALLEL_JOBS=0' "$_cov" 2>/dev/null; then
  assert_pass "[SPEC-12] check-coverage.sh forces ZBUILD_TEST_PARALLEL_JOBS=0 for the traced run"
else
  assert_fail "[SPEC-12] check-coverage.sh must force ZBUILD_TEST_PARALLEL_JOBS=0 (PS4 trace needs serial)" \
    "no ZBUILD_TEST_PARALLEL_JOBS=0 found in $_cov"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
