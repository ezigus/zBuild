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
case "$_ERR" in
  *"unit: ABORTED"*) assert_pass "[SPEC-1] killed unit tier → 'unit: ABORTED' on stderr" ;;
  *) assert_fail "[SPEC-1] killed unit tier must produce ABORTED on stderr" "stderr: $_ERR" ;;
esac
case "$_OUT" in
  *"total: ABORTED"*) assert_pass "[SPEC-1b] killed unit tier → 'total: ABORTED' on stdout" ;;
  *) assert_fail "[SPEC-1b] killed unit tier must produce 'total: ABORTED' on stdout" "stdout: $_OUT" ;;
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
case "$_ERR" in
  *"mutation: ABORTED"*) assert_pass "[SPEC-2] killed mutation tier → 'mutation: ABORTED' on stderr" ;;
  *) assert_fail "[SPEC-2] killed mutation tier must produce ABORTED on stderr" "stderr: $_ERR" ;;
esac
assert_eq "[SPEC-2b] killed mutation tier → non-zero exit" "1" "$_RC"
case "$_OUT" in
  *"total: "[0-9]*" passed"*) assert_fail "[SPEC-2c] must not print 'total: N/N passed' when mutation aborted" "stdout: $_OUT" ;;
  *) assert_pass "[SPEC-2c] no 'total: N/N passed' line when mutation tier aborted" ;;
esac

cleanup_test_env
print_test_results
exit $((FAIL > 0))
