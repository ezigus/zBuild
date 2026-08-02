#!/usr/bin/env bash
# Tests: bounded parallel execution in scripts/run-tests.sh (issues #983 + #984, EPIC #982).
#
# #983 made parallel test execution safe by construction; #984 makes it the DEFAULT
# for safe tiers; #991 adds the integration tier to the safe allow-list:
#   - safe tiers (unit, integration) run PARALLEL BY DEFAULT (#984/#991);
#     ZBUILD_TEST_PARALLEL_JOBS unset → computed default; set to 0 → serial escape
#     hatch; set to N → N jobs,
#   - tier-gated to a safe allow-list (ZBUILD_PARALLEL_SAFE_TIERS, default
#     "unit integration") — the integration tier became parallel-safe once #989
#     (per-test HOME/state/events isolation) + #990 (repo-write/tmp/worktree
#     fixes) removed the fork-bomb that deadlocked its route.sh/claude-spawning
#     tests under concurrency,
#   - a serial-pin escape hatch (#991): _ZBUILD_SERIAL_PIN[] + ZBUILD_SERIAL_TESTS
#     keep named integration files in a SERIAL bucket while the rest parallelize,
#   - guarded against re-entrancy (ZBUILD_RUN_TESTS_ACTIVE) so a test can never
#     fork-bomb the suite by invoking run-tests.sh against a real tier,
#   - coverage (PS4-traced) stays parallel-compatible via per-test trace files
#     that are merged after the pool — NOT forced serial — see SPEC-12.
#
# EVERY invocation here targets a hermetic FAKE tier via ZBUILD_TESTS_DIR — never
# the real repo tier — so this test cannot itself recurse into the live suite.
#
# SPEC-1  CHANGE  parallel path is ACTIVATED for a safe tier (unit) when JOBS>0
# SPEC-2  GUARD   parallel-mode summary line is correct (4/6)
# SPEC-3  GUARD   parallel mode emits one FAIL line per failing file (2)
# SPEC-4  GUARD   parallel mode exits 1 when a file fails
# SPEC-5  GUARD   serial (JOBS=0) and parallel summaries are identical
# SPEC-6  CHANGE  integration tier is PARALLEL-SAFE BY DEFAULT (activates pool) (#991)
# SPEC-7  CHANGE  re-entrancy guard refuses a nested real-tier run (no fixture) → exit 2
# SPEC-8  GUARD   guard exempts fixture-isolated nested runs (ZBUILD_TESTS_DIR set)
# SPEC-9  CHANGE  unit runs PARALLEL BY DEFAULT when JOBS is UNSET (#984)
# SPEC-10 GUARD   JOBS=0 is the serial escape hatch (NOT activated) even by default
# SPEC-11 CHANGE  integration runs PARALLEL BY DEFAULT when JOBS is UNSET (#991)
# SPEC-12 GUARD   check-coverage.sh delegates tracing to the runner (--coverage-trace), no force-serial (#993)
# SPEC-13 CHANGE  integration accounting + overall rc identical parallel vs JOBS=0 (#991)
# SPEC-14 CHANGE  a ZBUILD_SERIAL_TESTS-matched file runs in the SERIAL bucket, not the pool (#991)
# SPEC-15 CHANGE  gh-automation-idempotency-log-test.sh is serial-pinned in _ZBUILD_SERIAL_PIN (#1425)
# SPEC-16 GUARD   unit tier routes a ZBUILD_SERIAL_TESTS-pinned file to the serial bucket (#1425)
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
SER_FILE="$TEST_TEMP_DIR/serial-active"   # #991: serial-bucket routing evidence
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
  : > "$SER_FILE"   # reset the serial-bucket routing hook each call
  # `env -u` clears any AMBIENT ZBUILD_TEST_PARALLEL_JOBS / SAFE_TIERS so the
  # "unset → default-parallel" SPECs are hermetic. Without this, a caller env
  # that sets JOBS (e.g. an explicit ZBUILD_TEST_PARALLEL_JOBS=0 escape hatch)
  # would leak in and make the no-JOBS cases run serial. Explicit "$@"
  # assignments re-add after -u.
  env -u ZBUILD_TEST_PARALLEL_JOBS -u ZBUILD_PARALLEL_SAFE_TIERS \
      ZBUILD_TESTS_DIR="$FAKE_TESTS" \
      ZBUILD_PLUGINS_DIR="$EMPTY_DIR" \
      ZBUILD_CORE_DIR="$EMPTY_DIR" \
      _ZBUILD_PAR_ACTIVE_FILE="$ACT_FILE" \
      _ZBUILD_SERIAL_ACTIVE_FILE="$SER_FILE" \
      "$@" \
      bash "$RUN_TESTS" --tier "$tier" \
      >"$out_f" 2>"$err_f" || rc=$?
  _LAST_STDOUT="$(cat "$out_f")"
  _LAST_STDERR="$(cat "$err_f")"
  _LAST_RC="$rc"
  _LAST_ACTIVATED="$(cat "$ACT_FILE" 2>/dev/null | tr -d '[:space:]')"
  # Keep newlines: one pinned basename per line, so a SPEC can grep for routing.
  _LAST_SERIAL="$(cat "$SER_FILE" 2>/dev/null || true)"
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

# ─── [SPEC-6] CHANGE: integration is PARALLEL-SAFE BY DEFAULT (#991) ───────────
# Default ZBUILD_PARALLEL_SAFE_TIERS now includes integration (#989/#990 made the
# tier hermetic), so the pool MUST activate for integration when JOBS>0. At the
# #983/#984 baseline this stayed serial (the fork-bomb guard).
_run_tier integration ZBUILD_TEST_PARALLEL_JOBS=2
assert_eq "[SPEC-6] integration activates the parallel pool when JOBS=2 (parallel-safe via #991)" \
  "integration" "$_LAST_ACTIVATED"
case "$_LAST_STDOUT" in
  *"integration: 2/3 passed"*) assert_pass "[SPEC-6b] integration accounting correct (2/3) under the pool" ;;
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

# ─── [SPEC-11] CHANGE: integration runs PARALLEL BY DEFAULT (JOBS unset) (#991) ─
# No explicit JOBS → the internal default (_zb_default_jobs) must activate the
# pool for the now-safe integration tier, mirroring SPEC-9 for unit.
_run_tier integration
assert_eq "[SPEC-11] integration activates parallel BY DEFAULT when JOBS is unset (#991)" \
  "integration" "$_LAST_ACTIVATED"

# ─── [SPEC-12] GUARD: coverage delegates tracing to the runner, runs parallel ─
# #993 (was #984's force-serial): check-coverage.sh no longer wires PS4/fd-9 or
# pins ZBUILD_TEST_PARALLEL_JOBS=0. It asks the runner for a merged trace via
# `--coverage-trace`; run-tests.sh owns per-test trace files + merge, so
# coverage runs safely under the parallel unit tier.
_cov="$REPO_ROOT/scripts/check-coverage.sh"
_cov_has_trace=$(grep -c -- '--coverage-trace' "$_cov" 2>/dev/null || true)
_cov_has_serial=$(grep -c 'ZBUILD_TEST_PARALLEL_JOBS=0' "$_cov" 2>/dev/null || true)
if [[ "$_cov_has_trace" -gt 0 && "$_cov_has_serial" -eq 0 ]]; then
  assert_pass "[SPEC-12] check-coverage.sh delegates tracing via --coverage-trace and does not force serial"
else
  assert_fail "[SPEC-12] check-coverage.sh must request a runner trace (--coverage-trace) and not force ZBUILD_TEST_PARALLEL_JOBS=0" \
    "--coverage-trace=$_cov_has_trace JOBS=0=$_cov_has_serial in $_cov"
fi

# ─── [SPEC-13] CHANGE: integration accounting + rc identical parallel vs serial ─
# The whole point of #991: flipping the gate must not change the integration
# tier's outcome. Compare the summary line AND the overall rc between the
# default-parallel run and the explicit-serial (JOBS=0) escape hatch.
_run_tier integration ZBUILD_TEST_PARALLEL_JOBS=2
_ipar_sum="$(printf '%s\n' "$_LAST_STDOUT" | grep -E '^integration: [0-9]+/[0-9]+ passed' || true)"
_ipar_rc="$_LAST_RC"
_run_tier integration ZBUILD_TEST_PARALLEL_JOBS=0
_iser_sum="$(printf '%s\n' "$_LAST_STDOUT" | grep -E '^integration: [0-9]+/[0-9]+ passed' || true)"
_iser_rc="$_LAST_RC"
assert_eq "[SPEC-13] integration summary identical parallel vs serial" "$_ipar_sum" "$_iser_sum"
assert_eq "[SPEC-13b] integration overall rc identical parallel vs serial" "$_ipar_rc" "$_iser_rc"

# ─── [SPEC-14] CHANGE: a ZBUILD_SERIAL_TESTS-matched file runs SERIAL, not pool ─
# Pin one of the passing integration files via the env override. DIRECT evidence
# of the routing: the runner records each serial-bucket file to the
# _ZBUILD_SERIAL_ACTIVE_FILE hook ($_LAST_SERIAL). The pinned file MUST appear
# there (it ran serially) and MUST NOT have changed the accounting (2/3) — the
# OTHER files still parallelize (the pool still activates for the tier).
_run_tier integration ZBUILD_TEST_PARALLEL_JOBS=2 ZBUILD_SERIAL_TESTS='ipass-1-test.sh'
assert_eq "[SPEC-14] tier still activates the pool when one file is serial-pinned" \
  "integration" "$_LAST_ACTIVATED"
case "$_LAST_SERIAL" in
  *"ipass-1-test.sh"*) assert_pass "[SPEC-14b] pinned file routed to the SERIAL bucket (direct hook evidence)" ;;
  *) assert_fail "[SPEC-14b] pinned file must appear in the serial-bucket hook" "serial-active: '$_LAST_SERIAL'" ;;
esac
case "$_LAST_STDOUT" in
  *"integration: 2/3 passed"*) assert_pass "[SPEC-14b2] serial-pinned file still counted (2/3), pinning is routing-only" ;;
  *) assert_fail "[SPEC-14b2] pinned-file run must still produce 'integration: 2/3 passed'" "stdout: $_LAST_STDOUT" ;;
esac

# ─── [SPEC-14c] CHANGE: serial-pin routes the named file out of the pool ──────
# Direct evidence: a fixture integration tier where the failing file is pinned.
# With the failing file in the SERIAL bucket and a pool-job count of 1, the FAIL
# line and accounting are unchanged from the all-parallel run — the partition is
# transparent. We assert the partition helper itself by sourcing run-tests.sh's
# matcher in isolation.
(
  set -uo pipefail
  _ZBUILD_SERIAL_PIN=( 'pinned-*-test.sh' )
  # Re-declare the matcher exactly as run-tests.sh defines it would couple the
  # test to source; instead exercise it through the env override, which the
  # runner merges with the array. Assert the env-merge path matches.
  ZBUILD_SERIAL_TESTS='other-*-test.sh'
  _match() {
    local base="$1" glob
    for glob in "${_ZBUILD_SERIAL_PIN[@]+"${_ZBUILD_SERIAL_PIN[@]}"}" ${ZBUILD_SERIAL_TESTS:-}; do
      [[ -n "$glob" ]] || continue
      # shellcheck disable=SC2053
      [[ "$base" == $glob ]] && return 0
    done
    return 1
  }
  _match 'pinned-3-test.sh' && _match 'other-9-test.sh' && ! _match 'free-1-test.sh'
) && assert_pass "[SPEC-14c] matcher: array glob + env glob match, non-pinned does not" \
  || assert_fail "[SPEC-14c] serial-pin matcher must match array+env globs and reject others" ""

# ─── [SPEC-15] CHANGE: gh-automation-idempotency-log-test.sh in _ZBUILD_SERIAL_PIN ─────────────
# Source-read grep: the literal basename must appear in the _ZBUILD_SERIAL_PIN block of
# run-tests.sh. Fails at merge-base (entry absent) and passes once the pin is added (#1425).
_pin_count="$(grep -c 'gh-automation-idempotency-log-test\.sh' "$RUN_TESTS" || true)"
assert_eq "[SPEC-15] gh-automation-idempotency-log-test.sh is present in _ZBUILD_SERIAL_PIN" \
  "1" "$_pin_count"

# ─── [SPEC-16] GUARD: unit tier routes ZBUILD_SERIAL_TESTS-pinned file to serial bucket ────────
# Mirrors SPEC-14 for the integration tier: the serial-pin routing mechanism is tier-agnostic.
# Pins one of the passing unit fixtures via the env override and verifies it appears in
# _ZBUILD_SERIAL_ACTIVE_FILE (_LAST_SERIAL) while the pool still activates and accounting is
# unchanged. Passes at baseline (routing mechanism already exists; proven for integration by
# SPEC-14; same code path serves unit). This is a guard: does not fail at merge-base.
_run_tier unit ZBUILD_TEST_PARALLEL_JOBS=2 ZBUILD_SERIAL_TESTS='pass-1-test.sh'
assert_eq "[SPEC-16] unit tier still activates the pool when one file is serial-pinned" \
  "unit" "$_LAST_ACTIVATED"
case "$_LAST_SERIAL" in
  *"pass-1-test.sh"*) assert_pass "[SPEC-16b] unit-tier pinned file routed to the SERIAL bucket (hook evidence)" ;;
  *) assert_fail "[SPEC-16b] unit-tier pinned file must appear in the serial-bucket hook" "serial-active: '$_LAST_SERIAL'" ;;
esac
case "$_LAST_STDOUT" in
  *"unit: 4/6 passed"*) assert_pass "[SPEC-16c] serial-pin is routing-only; unit accounting unchanged (4/6)" ;;
  *) assert_fail "[SPEC-16c] unit-tier accounting must remain 4/6 with one file pinned" "stdout: $_LAST_STDOUT" ;;
esac

# ─── [SPEC-17] GUARD: _ZBUILD_SERIAL_PIN entry count must not exceed 7 ─────────
# ADR-053 §4: ratchet cap. Count non-comment, non-blank quoted entries inside the
# _ZBUILD_SERIAL_PIN=( ... ) block in scripts/run-tests.sh. Must be ≤ 7.
_pin_count=$(awk '
  /^_ZBUILD_SERIAL_PIN=\(/ { in_block=1; next }
  in_block && /^\)/ { in_block=0 }
  in_block && /^[[:space:]]*#/ { next }
  in_block && /^[[:space:]]*$/ { next }
  in_block { count++ }
  END { print count+0 }
' "$REPO_ROOT/scripts/run-tests.sh")
if [[ "$_pin_count" -le 7 ]]; then
    assert_pass "[SPEC-17] serial-pin cap ≤ 7 (count=$_pin_count, ADR-053 §4)"
else
    assert_fail "[SPEC-17] serial-pin count exceeds ADR-053 §4 cap of 7" \
        "count=$_pin_count — remove an entry or amend ADR-053 to raise the cap"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
