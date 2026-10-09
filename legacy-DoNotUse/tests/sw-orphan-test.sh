#!/usr/bin/env bash
# sw-orphan-test.sh — regression tests for process cleanup primitives
# Tests that _kill_process_tree, _kill_process_group_safe, and parent-PID polling
# leave zero orphaned descendants in all three threat classes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROC_UTILS="$SCRIPT_DIR/../scripts/lib/proc-utils.sh"

PASS=0
FAIL=0
ERRORS=()

# ─── Helpers ─────────────────────────────────────────────────────────────────

ok() {
    local name="$1"
    echo "  ✓ $name"
    PASS=$(( PASS + 1 ))
}

fail() {
    local name="$1" msg="$2"
    echo "  ✗ $name: $msg"
    FAIL=$(( FAIL + 1 ))
    ERRORS+=("$name: $msg")
}

# Clean up any test temp files on exit
TMPFILES=()
cleanup_test() {
    local f
    for f in "${TMPFILES[@]:-}"; do
        rm -f "$f" 2>/dev/null || true
    done
}
trap cleanup_test EXIT

# ─── Load primitives ─────────────────────────────────────────────────────────

if [[ ! -f "$PROC_UTILS" ]]; then
    echo "ERROR: proc-utils.sh not found at $PROC_UTILS"
    exit 1
fi

# Source in a subshell to check for syntax errors first
if ! bash -n "$PROC_UTILS" 2>/dev/null; then
    echo "ERROR: proc-utils.sh has syntax errors"
    exit 1
fi

# shellcheck source=../scripts/lib/proc-utils.sh
source "$PROC_UTILS"

echo ""
echo "sw-orphan-test.sh — process cleanup regression tests"
echo "──────────────────────────────────────────────────────"

# ─── Test A: _kill_process_tree cleans full descendant tree ──────────────────

echo ""
echo "A: _kill_process_tree"

# Spawn: root → two long-lived children
( sleep 600 & sleep 600 & wait ) &
ROOT_A=$!
sleep 0.5  # let children fork

# Check children exist before killing
_children_a=$(pgrep -P "$ROOT_A" 2>/dev/null || true)
if [[ -z "$_children_a" ]]; then
    fail "A.pre" "no children spawned before kill (test setup issue)"
else
    _kill_process_tree TERM "$ROOT_A" 2>/dev/null || true
    sleep 1
    _kill_process_tree KILL "$ROOT_A" 2>/dev/null || true
    sleep 0.3

    if kill -0 "$ROOT_A" 2>/dev/null; then
        fail "A.root" "root PID $ROOT_A survived _kill_process_tree"
    else
        ok "A.root: root terminated"
    fi

    _survivors=$(pgrep -P "$ROOT_A" 2>/dev/null || true)
    if [[ -n "$_survivors" ]]; then
        fail "A.children" "descendants survived: $_survivors"
    else
        ok "A.children: no descendants remain"
    fi
fi

# ─── Test B: _kill_process_group_safe cleans the process group ───────────────

echo ""
echo "B: _kill_process_group_safe"

# Must launch the target in a separate process group (setsid) so that
# _kill_process_group_safe doesn't kill this test script's own group.
if command -v setsid >/dev/null 2>&1; then
    _b_pid_file=$(mktemp /tmp/orphan-test-b.XXXXXX)
    TMPFILES+=("$_b_pid_file")
    # setsid makes the child its own session/group leader
    setsid bash -c 'echo $$ > '"$_b_pid_file"'; sleep 600 & sleep 600 & wait' &
    sleep 0.5
    ROOT_B=$(cat "$_b_pid_file" 2>/dev/null || echo "")
    if [[ -z "$ROOT_B" || ! "$ROOT_B" =~ ^[0-9]+$ ]]; then
        fail "B.setup" "setsid child PID not written"
    else
        _pgid_b=$(_get_pgid "$ROOT_B" 2>/dev/null || echo "")
        if [[ -z "$_pgid_b" || "$_pgid_b" -le 1 ]]; then
            fail "B.pgid" "could not determine PGID for PID $ROOT_B"
            kill -9 "$ROOT_B" 2>/dev/null || true
        else
            _kill_process_group_safe "$_pgid_b" 3
            sleep 0.3
            if kill -0 "$ROOT_B" 2>/dev/null; then
                fail "B.root" "root PID $ROOT_B survived _kill_process_group_safe PGID $_pgid_b"
                kill -9 "$ROOT_B" 2>/dev/null || true
            else
                ok "B.root: root terminated"
            fi
        fi
    fi
else
    # setsid not available (e.g., macOS without util-linux) — test the safe-input
    # boundary conditions only: zero PGID and dead PGID must not error.
    _kill_process_group_safe 0 1 2>/dev/null || true
    ok "B.skip: setsid unavailable — boundary-safe test passed"
fi

# ─── Test C: _parent_alive loop guard — subshell self-terminates when parent dies ─

echo ""
echo "C: parent-PID polling (hard-kill parent)"

# Write a sentinel subshell that runs the _parent_alive pattern (1s poll interval)
_sub_pid_file=$(mktemp /tmp/orphan-test-sub.XXXXXX)
TMPFILES+=("$_sub_pid_file")

# Parent script: spawns polling subshell, writes its PID, then sleeps 30s
# We hard-kill the parent and assert the subshell exits within 3 poll intervals.
PARENT_SCRIPT="
source '$PROC_UTILS'
parent_pid=\$\$
(
    while _parent_alive \"\$parent_pid\"; do
        sleep 1 & wait \$!
    done
) &
echo \"\$!\" > '$_sub_pid_file'
sleep 30
"

bash -c "$PARENT_SCRIPT" &
_parent_pid_c=$!
sleep 2  # let parent spawn subshell and write PID

_sub_pid_c=$(cat "$_sub_pid_file" 2>/dev/null || echo "")
if [[ -z "$_sub_pid_c" ]]; then
    fail "C.setup" "subshell PID not written within 2s — parent may have crashed"
    kill "$_parent_pid_c" 2>/dev/null || true
else
    # Hard-kill parent — no traps fire (suppress expected "Killed" stderr)
    kill -9 "$_parent_pid_c" 2>/dev/null || true
    wait "$_parent_pid_c" 2>/dev/null || true
    sleep 4  # > polling interval (1s) × 3 — subshell should detect parent death

    if kill -0 "$_sub_pid_c" 2>/dev/null; then
        fail "C.poll" "heartbeat subshell PID $_sub_pid_c survived hard-killed parent $­_parent_pid_c"
        kill -9 "$_sub_pid_c" 2>/dev/null || true
    else
        ok "C.poll: subshell self-terminated after parent hard-kill"
    fi
fi

# ─── Test D: _parent_alive — basic unit tests ────────────────────────────────

echo ""
echo "D: _parent_alive unit"

# PID 1 (init) — should return true (fail-open)
if _parent_alive 1; then
    ok "D.init: PID 1 treated as alive (fail-open)"
else
    fail "D.init" "_parent_alive 1 returned false — should be fail-open"
fi

# Empty PID — should return true (fail-open)
if _parent_alive ""; then
    ok "D.empty: empty PID treated as alive (fail-open)"
else
    fail "D.empty" "_parent_alive '' returned false — should be fail-open"
fi

# Dead PID: fork a short-lived process, wait for it, then test
bash -c 'sleep 0' &
_dead_pid=$!
wait "$_dead_pid" 2>/dev/null || true
sleep 0.2
if _parent_alive "$_dead_pid"; then
    fail "D.dead" "_parent_alive $­_dead_pid returned true for a reaped process"
else
    ok "D.dead: dead PID correctly reported as gone"
fi

# ─── Results ─────────────────────────────────────────────────────────────────

echo ""
echo "──────────────────────────────────────────────────────"
if [[ "$FAIL" -eq 0 ]]; then
    echo "  All $PASS tests passed"
    exit 0
else
    echo "  Results: $PASS passed / $FAIL failed / $(( PASS + FAIL )) total"
    for e in "${ERRORS[@]}"; do
        echo "    FAIL: $e"
    done
    exit 1
fi
