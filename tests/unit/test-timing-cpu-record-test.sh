#!/usr/bin/env bash
# The timing record must carry CPU time, not only wall-clock.
#
# The unit tier's total work doubled between two runs at constant 4.0x
# parallelism — sum of file times 1,631s -> 3,242s, job wall 404s -> 816s, and
# the slowest file 196s -> 445s. Every file moved together. Wall-clock alone
# cannot say whether that is more work being done or more time spent waiting,
# and those have opposite fixes.
#
# The one local measurement that hints at an answer is not in any record:
#
#   real 150.12   user 52.32   sys 81.24
#
# System time is 1.55x user time for a bash test — 89% CPU-bound, and most of it
# in the KERNEL. That is fork/exec cost, not computation. If sys doubles across
# runs the suite is spawning more (or more expensive) processes; if wall doubles
# while CPU stays flat it is blocking on something. Nothing recorded today can
# tell those apart, which is why six explanations of the Coverage timeout were
# all guesses.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "the timing record carries CPU time"
setup_test_env "test-timing-cpu-record"

_TDIR="$TEST_TEMP_DIR/tests"; mkdir -p "$_TDIR/unit"
# Deliberately fork-heavy: CPU time must be measurably non-zero, or the
# assertion below passes on a rounding artifact.
cat > "$_TDIR/unit/probe-test.sh" <<'PROBE'
#!/usr/bin/env bash
for i in $(seq 1 120); do echo x | tr a-z A-Z >/dev/null; done
exit 0
PROBE
_timing="$TEST_TEMP_DIR/timing.txt"
( cd "$REPO_ROOT" && ZBUILD_TESTS_DIR="$_TDIR" ZBUILD_TEST_TIMING_FILE="$_timing" \
    bash scripts/run-tests.sh --tier unit >/dev/null 2>&1 ) || true

# ─── SPEC-1: a cpu record exists alongside the wall record ─────────────────
assert_gt "[SPEC-1] the timing file records a cpu line" \
    "$(grep -cE '^cpu ' "$_timing" 2>/dev/null || true)" "0"
assert_gt "[SPEC-1] GUARD: it still records the wall-clock line" \
    "$(grep -cE '^file ' "$_timing" 2>/dev/null || true)" "0"

# ─── SPEC-2: the figures are real, and user and sys are separable ──────────
# Separable because they answer different questions: user is computation, sys is
# fork/exec and syscalls. Collapsing them to one number would hide the thing the
# local measurement above actually shows.
_cpu_fields="$(awk '/^cpu /{print NF; exit}' "$_timing" 2>/dev/null || true)"
assert_eq "[SPEC-2] the cpu record carries user AND sys, plus the file" \
    "4" "${_cpu_fields:-0}"
_cpu_total="$(awk '/^cpu /{print $2+$3; exit}' "$_timing" 2>/dev/null || true)"
assert_gt "[SPEC-2] the recorded CPU time is non-zero for a fork-heavy file" \
    "${_cpu_total:-0}" "0"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
