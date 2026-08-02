#!/usr/bin/env bash
# Tests: scripts/run-tests.sh --tier all detects a tier killed before writing its
# rc_file entry and reports ABORTED instead of silently passing (#1662).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUN_TESTS="$REPO_ROOT/scripts/run-tests.sh"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "run-tests.sh killed-tier abort detection (#1662)"
setup_test_env "run-tests-killed-tier"

EMPTY_DIR="$TEST_TEMP_DIR/empty"
EMPTY_MUT="$TEST_TEMP_DIR/empty-mut"
mkdir -p "$EMPTY_DIR" "$EMPTY_MUT"

# Minimal passing fixture: all file-tiers have one instant-pass test.
FAST="$TEST_TEMP_DIR/fast"
for t in unit integration e2e golden; do
  mkdir -p "$FAST/$t"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$FAST/$t/p-test.sh"
  chmod +x "$FAST/$t/p-test.sh"
done

# _all_abort <tier_to_kill> — run `--tier all` with one tier simulated as killed
# before it writes its rc_file entry (_ZBUILD_TEST_ABORT_TIER hook, #1662).
_all_abort() {
  local abort_tier="$1"
  local out_f="$TEST_TEMP_DIR/o.txt" err_f="$TEST_TEMP_DIR/e.txt" rc=0
  env -u ZBUILD_TEST_PARALLEL_JOBS -u ZBUILD_PARALLEL_SAFE_TIERS \
      -u ZBUILD_TIER_CONCURRENCY -u ZBUILD_TIER_BUDGET -u UPDATE_GOLDEN \
      ZBUILD_TESTS_DIR="$FAST" \
      ZBUILD_PLUGINS_DIR="$EMPTY_DIR" \
      ZBUILD_CORE_DIR="$EMPTY_DIR" \
      ZBUILD_MUTATION_DIR="$EMPTY_MUT" \
      ZBUILD_LINT_CMD=true \
      ZBUILD_PARALLEL_SAFE_TIERS="unit integration e2e golden" \
      _ZBUILD_TEST_ABORT_TIER="$abort_tier" \
      bash "$RUN_TESTS" --tier all \
      >"$out_f" 2>"$err_f" || rc=$?
  _OUT="$(cat "$out_f")"; _ERR="$(cat "$err_f")"; _RC="$rc"
}

# ─── [SPEC-1] CHANGE: file-tier killed before rc_file write → ABORTED ────────
# Unit tier exits 137 via the _ZBUILD_TEST_ABORT_TIER hook before writing its
# rc_file entry. The presence check must catch the missing entry and report ABORTED.
_all_abort "unit"
# #1662 specifies this wording exactly, because the tier name has to be IN the
# `total:` line — that line is what people grep for and what CI surfaces.
case "$_OUT" in
  *"total: ABORTED — tier unit produced no result"*)
    assert_pass "[SPEC-1] killed unit tier → 'total: ABORTED — tier unit produced no result'" ;;
  *) assert_fail "[SPEC-1] killed unit tier must produce the issue's exact abort wording" "stdout: $_OUT" ;;
esac
# The surviving tiers must still report — an abort you cannot diagnose is barely
# better than a silent pass, and buf_dir is deleted on exit.
case "$_OUT" in
  *"integration: "*passed*) assert_pass "[SPEC-1b] surviving tiers still report their summaries on abort" ;;
  *) assert_fail "[SPEC-1b] an abort must not discard the summaries of tiers that finished" "stdout: $_OUT" ;;
esac
assert_eq "[SPEC-1c] killed unit tier → non-zero exit" "1" "$_RC"
# The normal 'total: N/N passed' line must NOT appear when a tier was aborted.
case "$_OUT" in
  *"total: "[0-9]*" passed"*) assert_fail "[SPEC-1d] must not print 'total: N/N passed' on abort" "stdout: $_OUT" ;;
  *) assert_pass "[SPEC-1d] no 'total: N/N passed' line on abort" ;;
esac

# ─── [SPEC-2] CHANGE: non-file-tier (mutation) killed → manifest covers all 6 ─
# Mutation is tier #5 in _TIER_ALL_MANIFEST; killing it verifies the presence
# check iterates the full manifest, not just the first four file-tiers.
_all_abort "mutation"
case "$_OUT" in
  *"total: ABORTED — tier mutation produced no result"*)
    assert_pass "[SPEC-2] killed mutation tier → abort names 'mutation' (manifest covers all 6)" ;;
  *) assert_fail "[SPEC-2] killed mutation tier must be named in the abort line" "stdout: $_OUT" ;;
esac
assert_eq "[SPEC-2b] killed mutation tier → non-zero exit" "1" "$_RC"
case "$_OUT" in
  *"total: "[0-9]*" passed"*) assert_fail "[SPEC-2c] must not print 'total: N/N passed' when mutation aborted" "stdout: $_OUT" ;;
  *) assert_pass "[SPEC-2c] no 'total: N/N passed' line when mutation tier aborted" ;;
esac

# ─── [SPEC-3] CHANGE: SIGTERM mid-flight → 'ABORTED — interrupted', rc 143 ───
# #1662's third fix component (the INT/TERM trap) shipped with no coverage at all
# in the first pass. It is the subtlest code in the change — handler, PID tracking,
# re-raise, idempotency — so it gets a real signal, not a cooperative hook.
SLOW="$TEST_TEMP_DIR/slow"
mkdir -p "$SLOW/unit" "$SLOW/integration" "$SLOW/e2e" "$SLOW/golden"
export _ZB_SIG_MARKER="$TEST_TEMP_DIR/started.marker"
# Marker-then-sleep: the test waits for proof the tier is actually running before
# signalling, so this cannot flake on a slow machine the way a fixed sleep would.
printf '#!/usr/bin/env bash\ntouch "$_ZB_SIG_MARKER"\nsleep 30\nexit 0\n' > "$SLOW/unit/slow-test.sh"
for t in integration e2e golden; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$SLOW/$t/p-test.sh"
done
chmod +x "$SLOW"/*/*.sh
rm -f "$_ZB_SIG_MARKER"

env -u ZBUILD_TEST_PARALLEL_JOBS -u ZBUILD_TIER_CONCURRENCY -u ZBUILD_TIER_BUDGET \
    -u UPDATE_GOLDEN \
    ZBUILD_TESTS_DIR="$SLOW" ZBUILD_PLUGINS_DIR="$EMPTY_DIR" ZBUILD_CORE_DIR="$EMPTY_DIR" \
    ZBUILD_MUTATION_DIR="$EMPTY_MUT" ZBUILD_LINT_CMD=true \
    ZBUILD_PARALLEL_SAFE_TIERS="unit integration e2e golden" \
    bash "$RUN_TESTS" --tier all >"$TEST_TEMP_DIR/sig.out" 2>"$TEST_TEMP_DIR/sig.err" &
_sig_pid=$!
_waited=0
while [[ ! -e "$_ZB_SIG_MARKER" && "$_waited" -lt 200 ]]; do sleep 0.1; _waited=$((_waited + 1)); done
kill -TERM "$_sig_pid" 2>/dev/null
_sig_rc=0; wait "$_sig_pid" 2>/dev/null || _sig_rc=$?
_SIG_ERR="$(cat "$TEST_TEMP_DIR/sig.err" 2>/dev/null)"

assert_eq "[SPEC-3] SIGTERM mid-flight → rc 143 (128+SIGTERM)" "143" "$_sig_rc"
case "$_SIG_ERR" in
  *"total: ABORTED — interrupted"*)
    assert_pass "[SPEC-3b] SIGTERM mid-flight → 'total: ABORTED — interrupted'" ;;
  *) assert_fail "[SPEC-3b] SIGTERM must report 'total: ABORTED — interrupted'" "stderr: $_SIG_ERR" ;;
esac

cleanup_test_env
print_test_results
exit $((FAIL > 0))
