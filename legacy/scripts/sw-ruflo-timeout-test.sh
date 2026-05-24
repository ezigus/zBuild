#!/usr/bin/env bash
# sw-ruflo-timeout-test.sh — regression tests for ruflo_with_timeout FD hang (#426)
#
# Verifies that $( ruflo_with_timeout ... ) returns promptly even when the
# subshell spawns orphaned grandchildren that would otherwise hold the pipe
# FD open indefinitely.  Also exercises RUFLO_FORCE_DISABLE and
# RUFLO_NPX_FALLBACK=0 hardening added in the same fix.
#
# Run:  bash scripts/sw-ruflo-timeout-test.sh
set -euo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── output helpers ───────────────────────────────────────────────────────────
pass() { printf "  PASS: %s\n" "$1"; PASS=$(( PASS + 1 )); }
fail() { printf "  FAIL: %s\n" "$1"; FAIL=$(( FAIL + 1 )); }

assert_eq() {
    if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3 (expected '$2', got '$1')"; fi
}
assert_lt() {
    if [[ "$1" -lt "$2" ]]; then pass "$3"; else fail "$3 (expected < $2, got $1)"; fi
}
assert_le() {
    if [[ "$1" -le "$2" ]]; then pass "$3"; else fail "$3 (expected <= $2, got $1)"; fi
}
assert_empty() {
    if [[ -z "$1" ]]; then pass "$2"; else fail "$2 (expected empty, got '$1')"; fi
}

# ─── minimal stubs so ruflo-adapter.sh sources cleanly ───────────────────────
# Normally provided by helpers.sh; stub here to keep test self-contained.
warn()       { true; }
info()       { true; }
success()    { true; }
emit_event() { true; }

# Source the adapter under test.
# shellcheck source=scripts/lib/ruflo-adapter.sh
source "$SCRIPT_DIR/lib/ruflo-adapter.sh"

# Reset circuit-breaker (normally 0 at startup).
RUFLO_FAILURE_COUNT=0
export RUFLO_FAILURE_COUNT

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "================================================================"
echo "  ruflo_with_timeout -- FD hang regression tests  (issue #426)"
echo "================================================================"
echo ""

# ─── Test 1: $() unblocks despite orphaned grandchild ────────────────────────
# Primary regression.  Before the fix the subshell inherited the $() pipe FD;
# pkill killed the direct child but the grandchild (sleep 300) kept the FD
# open so $() never returned.  After the fix stdout goes to a temp file;
# $() returns as soon as ruflo_with_timeout returns regardless of survivors.
echo "--- Test 1: \$() unblocks despite orphaned grandchild -----------"

# _spawns_grandchild uses a two-level tree so that pkill -TERM -P $bg_pid kills
# only the intermediate shell (direct child), leaving its 'sleep 9871' child
# (grandchild) as an orphan.  Without the fix the orphan holds the $() pipe FD;
# with the fix it can only write to the temp file so $() unblocks immediately.
# The unusual sleep duration (9871) avoids colliding with unrelated processes.
_spawns_grandchild() {
    sh -c 'sleep 9871 & wait' &  # intermediate shell is direct child of bg_pid;
    wait                          # sleep 9871 is grandchild — survives pkill -P
}

RUFLO_FAILURE_COUNT=0; export RUFLO_FAILURE_COUNT
_t1_start=$(date +%s)
_t1_result=$(ruflo_with_timeout 2 _spawns_grandchild 2>/dev/null || true)
_t1_elapsed=$(( $(date +%s) - _t1_start ))

assert_lt   "$_t1_elapsed"  6   "\$() returns within 6 seconds (timeout=2 + 4s buffer)"
assert_empty "$_t1_result"      "output is empty on timeout (partial output discarded)"

# Kill only our test grandchildren by their unique duration, not all sleeps.
pkill -f "sleep 9871" 2>/dev/null || true

# ─── Test 2: Successful call passes stdout through ───────────────────────────
# The temp-file redirect must still return output to the caller on clean exit.
echo ""
echo "--- Test 2: successful call passes stdout through ---------------"

_emits_output() { echo "hello from subshell"; }

RUFLO_FAILURE_COUNT=0; export RUFLO_FAILURE_COUNT
_t2_result=$(ruflo_with_timeout 5 _emits_output 2>/dev/null || true)
assert_eq "$_t2_result" "hello from subshell" "stdout captured on success"

# ─── Test 3: Failed function returns empty output ────────────────────────────
# A function that exits non-zero should not emit partial output.
echo ""
echo "--- Test 3: failed function returns empty output ----------------"

_fails_immediately() { return 1; }

RUFLO_FAILURE_COUNT=0; export RUFLO_FAILURE_COUNT
_t3_result=$(ruflo_with_timeout 5 _fails_immediately 2>/dev/null || true)
assert_empty "$_t3_result" "output is empty when function exits non-zero"

# ─── Test 4: RUFLO_FORCE_DISABLE=true overrides RUFLO_AVAILABLE=true ─────────
# ruflo_detect() can set RUFLO_AVAILABLE=true; the old RUFLO_AVAILABLE=false
# approach would be overwritten.  RUFLO_FORCE_DISABLE bypasses detection.
echo ""
echo "--- Test 4: RUFLO_FORCE_DISABLE=true overrides detection --------"

RUFLO_AVAILABLE=true; export RUFLO_AVAILABLE
RUFLO_FORCE_DISABLE=true; export RUFLO_FORCE_DISABLE

if ruflo_available 2>/dev/null; then
    fail "ruflo_available returned true despite RUFLO_FORCE_DISABLE=true"
else
    pass "RUFLO_FORCE_DISABLE=true blocks ruflo_available"
fi

RUFLO_FORCE_DISABLE=false; export RUFLO_FORCE_DISABLE
if ruflo_available 2>/dev/null; then
    pass "ruflo_available returns true when RUFLO_FORCE_DISABLE=false"
else
    fail "ruflo_available returned false unexpectedly"
fi

unset RUFLO_FORCE_DISABLE RUFLO_AVAILABLE

# ─── Test 5: RUFLO_NPX_FALLBACK=0 prevents npx invocation ───────────────────
# When no local ruflo binary exists and RUFLO_NPX_FALLBACK=0, ruflo_detect
# must not invoke npx.  We inject a fake npx that creates a sentinel file
# to detect any invocation.
echo ""
echo "--- Test 5: RUFLO_NPX_FALLBACK=0 skips npx fallback ------------"

RUFLO_NPX_FALLBACK=0;    export RUFLO_NPX_FALLBACK
RUFLO_USE_NPX=false;     export RUFLO_USE_NPX
RUFLO_AVAILABLE=false;   export RUFLO_AVAILABLE

_fake_dir="$(mktemp -d "${TMPDIR:-/tmp}/sw-ruflo-timeout.XXXXXX")"
_sentinel="${TMPDIR:-/tmp}/_sw426_npx_called"
rm -f "$_sentinel"

# Stub npx: records invocation via sentinel file.
cat >"$_fake_dir/npx" <<'STUBEOF'
#!/usr/bin/env bash
touch "${TMPDIR:-/tmp}/_sw426_npx_called"
exit 1
STUBEOF
chmod +x "$_fake_dir/npx"

# Prepend fake dir so 'npx' is found but 'ruflo' is not.
_saved_PATH="$PATH"
export PATH="$_fake_dir:$PATH"

ruflo_detect 2>/dev/null || true

export PATH="$_saved_PATH"
rm -rf "$_fake_dir"

if [[ -f "$_sentinel" ]]; then
    fail "npx was invoked despite RUFLO_NPX_FALLBACK=0"
    rm -f "$_sentinel"
else
    pass "npx was NOT invoked when RUFLO_NPX_FALLBACK=0"
fi

if [[ "${RUFLO_USE_NPX:-false}" == "true" ]]; then
    fail "RUFLO_USE_NPX set to true despite RUFLO_NPX_FALLBACK=0"
else
    pass "RUFLO_USE_NPX remained false when RUFLO_NPX_FALLBACK=0"
fi

unset RUFLO_NPX_FALLBACK RUFLO_USE_NPX RUFLO_AVAILABLE

# ─── Test 6: Temp file cleaned up after timeout ───────────────────────────────
# Calls ruflo_with_timeout directly (not inside $()) — we're only testing that
# the temp file is removed; the FD-inheritance fix is exercised by test 1.
echo ""
echo "--- Test 6: temp file cleaned up after timeout ------------------"

_slow_function() { sleep 30; }

RUFLO_FAILURE_COUNT=0; export RUFLO_FAILURE_COUNT
# Use { find ... || true; } so find's non-zero exit (e.g. TMPDIR permission
# sub-dirs on macOS) does not make the pipe fail and trigger || echo "0",
# which would concatenate two outputs into "3\n0" — an unparseable integer.
_t6_before=$( { find "${TMPDIR:-/tmp}" -name 'ruflo_timeout.*' 2>/dev/null || true; } | wc -l | tr -d ' ')
ruflo_with_timeout 1 _slow_function >/dev/null 2>&1 || true
_t6_after=$( { find "${TMPDIR:-/tmp}" -name 'ruflo_timeout.*' 2>/dev/null || true; } | wc -l | tr -d ' ')

# Use <= not == : the OS may clean stale files during the 1-second grace-period
# sleep inside ruflo_with_timeout, so pre-existing files can disappear. What we
# care about is that we didn't ADD any new leaked files (count didn't increase).
assert_le "${_t6_after:-0}" "${_t6_before:-0}" "no ruflo_timeout.* temp files leaked after timeout"

# ─── Test 7: Temp file cleaned up after success ───────────────────────────────
echo ""
echo "--- Test 7: temp file cleaned up after success ------------------"

RUFLO_FAILURE_COUNT=0; export RUFLO_FAILURE_COUNT
_t7_before=$( { find "${TMPDIR:-/tmp}" -name 'ruflo_timeout.*' 2>/dev/null || true; } | wc -l | tr -d ' ')
ruflo_with_timeout 5 _emits_output >/dev/null 2>&1 || true
_t7_after=$( { find "${TMPDIR:-/tmp}" -name 'ruflo_timeout.*' 2>/dev/null || true; } | wc -l | tr -d ' ')

assert_le "${_t7_after:-0}" "${_t7_before:-0}" "no ruflo_timeout.* temp files leaked after success"

# ─── Test 8: All descendants killed after timeout (issue #441) ───────────────
# Verifies that _kill_process_tree reaps the full process subtree — not just
# direct children — so ruflo grandchildren (e.g. Node agentdb workers) do not
# accumulate as orphaned processes across loop iterations.
echo ""
echo "--- Test 8: all descendants killed after timeout (issue #441) ---"

# Use unique sleep duration based on shell PID to avoid cross-run collision
_T8_SLEEP_ID="98$(printf '%05d' $$)"

_spawns_deep_tree() {
    sh -c "sleep $_T8_SLEEP_ID & wait" &
    wait
}

# Pre-clean orphaned sleep processes left by any previous test run so
# historical leaks don't cause a false failure in the current-run assertion.
pkill -f "sleep $_T8_SLEEP_ID" 2>/dev/null || true
sleep 0.3

RUFLO_FAILURE_COUNT=0; export RUFLO_FAILURE_COUNT
ruflo_with_timeout 2 _spawns_deep_tree >/dev/null 2>&1 || true
sleep 2  # allow SIGKILL grace period + reaping

_t8_survivors=$(pgrep -f "sleep $_T8_SLEEP_ID" 2>/dev/null || true)
if [[ -z "$_t8_survivors" ]]; then
    pass "grandchild process fully reaped after timeout (no leak)"
else
    pkill -f "sleep $_T8_SLEEP_ID" 2>/dev/null || true
    fail "grandchild survived timeout — process leak detected (pids: $_t8_survivors)"
fi

# ─── Test 9: External binary path also reaps full tree (issue #441) ─────────
# Before the unified fix, external binaries (cmd_type != "function") went through
# timeout(1) which kills only the direct child — leaving Node grandchildren alive.
# After the fix, all commands use background subshell + BFS kill, so even a binary
# that spawns a grandchild gets its full subtree reaped on timeout.
echo ""
echo "--- Test 9: external binary also reaps full tree (issue #441) ---"

_rft_sleep_bin=$(mktemp "${TMPDIR:-/tmp}/rft_sleeper_bin.XXXXXX" 2>/dev/null)
# Use a PID-derived unique marker so concurrent test runs don't collide.
_t9_marker="9873sw$$"
cat > "$_rft_sleep_bin" <<BINEOF
#!/usr/bin/env sh
# Simulates a binary that spawns a grandchild (e.g. Node worker).
sh -c 'sleep ${_t9_marker} & wait' &
wait
BINEOF
chmod +x "$_rft_sleep_bin"

pkill -f "sleep ${_t9_marker}" 2>/dev/null || true
sleep 0.3

RUFLO_FAILURE_COUNT=0; export RUFLO_FAILURE_COUNT
ruflo_with_timeout 2 "$_rft_sleep_bin" >/dev/null 2>&1 || true
sleep 2  # allow SIGKILL grace period + reaping

_t9_survivors=$(pgrep -f "sleep ${_t9_marker}" 2>/dev/null || true)
if [[ -z "$_t9_survivors" ]]; then
    pass "external binary grandchild fully reaped after timeout (no leak)"
else
    pkill -f "sleep ${_t9_marker}" 2>/dev/null || true
    fail "external binary grandchild survived timeout — process leak (pids: $_t9_survivors)"
fi
rm -f "$_rft_sleep_bin" 2>/dev/null || true

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "----------------------------------------------------------------"
printf "  Results: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "----------------------------------------------------------------"
echo ""

[[ "$FAIL" -eq 0 ]]
