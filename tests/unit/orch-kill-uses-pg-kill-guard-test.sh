#!/usr/bin/env bash
# Guard: _orch_local_kill_slot and the always-run watchdog in runner.sh kill
# through zbuild_pg_kill, not through direct `kill` (#1801, SPEC-6).
#
# Direct `kill -TERM/-KILL $pid` only reaches the named process. A hook that
# forks a child which ignores TERM (as in SPEC-6b) keeps that child alive when
# the watchdog fires on just the leader. zbuild_pg_kill sends to the whole
# process group (TERM then KILL), so the child is caught.
#
# This is a static guard: it searches the source files for the patterns
# that must NOT be there (direct kill in _orch_local_kill_slot) and the
# patterns that MUST be there (zbuild_pg_kill call in both sites).
#
# The test must FAIL on current code (which uses direct kill in both places)
# and PASS after the implementation switches to zbuild_pg_kill.
#
# [#1801/SPEC-6]
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "orch kill sites use zbuild_pg_kill (not direct kill) (#1801 SPEC-6)"
setup_test_env "orch-kill-uses-pg-kill-guard"

LOCAL_ENGINE="$REPO_ROOT/core/orch/local_engine.sh"
RUNNER="$REPO_ROOT/core/pipeline/runner.sh"

assert_file_exists "SPEC-0a: local_engine.sh exists" "$LOCAL_ENGINE"
assert_file_exists "SPEC-0b: runner.sh exists" "$RUNNER"

# ── SPEC-6a: _orch_local_kill_slot calls zbuild_pg_kill ─────────────────────
# Extract the body of _orch_local_kill_slot (from its header to the closing }).
# After the fix it should call zbuild_pg_kill; on old code it calls direct kill.
_kill_slot_body="$(sed -n '/_orch_local_kill_slot\(\)/,/^}/p' "$LOCAL_ENGINE" 2>/dev/null || true)"
if grep -q 'zbuild_pg_kill' <<< "$_kill_slot_body"; then
    assert_pass "[#1801/SPEC-6] _orch_local_kill_slot calls zbuild_pg_kill"
else
    assert_fail "[#1801/SPEC-6] _orch_local_kill_slot calls zbuild_pg_kill" \
        "body uses direct kill; after #1801 it must call zbuild_pg_kill for process-group coverage"
fi

# Old pattern: `kill -TERM/-KILL "$wrapper_pid"` individually (not zbuild_pg_kill).
# This must NOT appear in _orch_local_kill_slot after the fix.
if grep -qE 'kill\s+-TERM\s+"?\$wrapper_pid"?' <<< "$_kill_slot_body" || \
   grep -qE 'kill\s+-KILL\s+"?\$wrapper_pid"?' <<< "$_kill_slot_body"; then
    assert_fail "[#1801/SPEC-6] _orch_local_kill_slot does not use bare kill on wrapper_pid" \
        "still uses direct \`kill -TERM/-KILL \$wrapper_pid\`; must use zbuild_pg_kill"
else
    assert_pass "[#1801/SPEC-6] _orch_local_kill_slot does not use bare kill on wrapper_pid"
fi

# ── SPEC-6b: always-run watchdog in runner.sh calls zbuild_pg_kill ──────────
# The always-run watchdog is inside _runner_dispatch_always_run. Extract its
# subshell block (from `_runner_dispatch_always_run` to the closing `done`).
_ar_body="$(sed -n '/_runner_dispatch_always_run()/,/^    }$/p' "$RUNNER" 2>/dev/null || true)"
if [[ -z "$_ar_body" ]]; then
    # fallback: grab from the function definition keyword to its end
    _ar_body="$(sed -n '/^    _runner_dispatch_always_run() {/,/^    }$/p' "$RUNNER" 2>/dev/null || true)"
fi
if grep -q 'zbuild_pg_kill' <<< "$_ar_body"; then
    assert_pass "[#1801/SPEC-6] always-run watchdog in runner.sh calls zbuild_pg_kill"
else
    assert_fail "[#1801/SPEC-6] always-run watchdog in runner.sh calls zbuild_pg_kill" \
        "_runner_dispatch_always_run uses direct kill; after #1801 the watchdog must call zbuild_pg_kill"
fi

# ── SPEC-6c: zbuild_pg_kill is defined and sourced by both files ─────────────
PG_KILL_LIB="$REPO_ROOT/scripts/lib/proc-group.sh"
assert_file_exists "SPEC-6c: proc-group.sh defines zbuild_pg_kill" "$PG_KILL_LIB"
if grep -q 'zbuild_pg_kill()' "$PG_KILL_LIB" 2>/dev/null; then
    assert_pass "[#1801/SPEC-6] zbuild_pg_kill is defined in proc-group.sh"
else
    assert_fail "[#1801/SPEC-6] zbuild_pg_kill is defined in proc-group.sh" \
        "function not found in $PG_KILL_LIB"
fi
if grep -q 'proc-group' "$LOCAL_ENGINE" 2>/dev/null; then
    assert_pass "[#1801/SPEC-6] local_engine.sh sources proc-group.sh (or its parent does)"
else
    assert_fail "[#1801/SPEC-6] local_engine.sh sources proc-group.sh" \
        "no reference to proc-group.sh found in local_engine.sh"
fi

# ── SPEC-6 runtime: TERM-ignoring child leaves no running process ─────────────
# Behavioral guarantee: after the watchdog kills a slot whose wrapper spawned a
# child that ignores TERM, that child must also be gone.
#
# Old _orch_local_kill_slot: `kill "-${sig}" "$wrapper_pid"` only. Killing the
# wrapper with SIGKILL does not kill its children — they are orphaned and continue
# running. So a TERM-ignoring child outlives the watchdog on old code.
# New _orch_local_kill_slot: calls zbuild_pg_kill, which sends TERM then KILL to
# the WHOLE process group. The TERM-ignoring child receives KILL and exits.
#
# Fails on old code (child alive after collect kills wrapper).
# Passes on new code (process-group KILL reaches child).
print_test_section "[#1801/SPEC-6] TERM-ignoring child leaves no process after watchdog fires (runtime)"
# Source the implementations so the runtime paths execute (not just pattern-match).
# shellcheck source=../../core/orch/local_engine.sh
source "$REPO_ROOT/core/orch/local_engine.sh"
# shellcheck source=../../scripts/lib/proc-group.sh
source "$REPO_ROOT/scripts/lib/proc-group.sh"

_s6rt_pool="$TEST_TEMP_DIR/spec6-rt-pool"
mkdir -p "$_s6rt_pool/pids" "$_s6rt_pool/results"
_s6rt_child_file="$TEST_TEMP_DIR/spec6-rt-child.pid"

# Start the wrapper as a NEW process group (set -m → background job is group leader).
# The wrapper forks a child that ignores TERM and records its PID. The wrapper
# itself waits and never writes a .exit file, so _orch_local_collect_results will
# time out and call _orch_local_kill_slot to kill the slot.
set -m
(
    ( trap '' TERM; printf '%s\n' "$BASHPID" > "$_s6rt_child_file"; sleep 120 ) &
    _s6rt_inner=$!
    trap ':' TERM
    wait "$_s6rt_inner" 2>/dev/null || true
) &
_s6rt_wrapper_pid=$!
set +m

printf '%s\n' "$_s6rt_wrapper_pid" > "$_s6rt_pool/pids/spec6rt.pid"
# No .inner_pid file: _orch_local_kill_slot only receives wrapper_pid, so the
# child can be reached only via process-group kill (the new code path).

# Wait for the child pid to be recorded (up to 5 s).
for _ in $(seq 1 50); do [[ -s "$_s6rt_child_file" ]] && break; sleep 0.1; done
_s6rt_child_pid="$(head -n 1 "$_s6rt_child_file" 2>/dev/null || true)"

# Collect with 2 s timeout. The wrapper never writes .exit, so collect fires the
# kill path. After collect returns, the child should be dead (new code) or alive (old).
set +e
_orch_local_collect_results "$_s6rt_pool" "pids" 2
set -e

# Poll briefly: the KILL signal needs a moment to be processed.
_s6rt_alive=1
if [[ -n "$_s6rt_child_pid" ]]; then
    for _ in $(seq 1 30); do
        kill -0 "$_s6rt_child_pid" 2>/dev/null || { _s6rt_alive=0; break; }
        sleep 0.1
    done
fi

if [[ -z "$_s6rt_child_pid" ]]; then
    assert_fail "[#1801/SPEC-6] fixture: TERM-ignoring child recorded its pid" \
        "no pid written to $_s6rt_child_file (wrapper may not have started)"
elif [[ "$_s6rt_alive" -eq 1 ]]; then
    assert_fail "[#1801/SPEC-6] TERM-ignoring child must not outlive the watchdog" \
        "pid $_s6rt_child_pid still alive; old code: direct kill misses TERM-ignoring children; new code: zbuild_pg_kill kills the group"
    kill -KILL "$_s6rt_child_pid" 2>/dev/null || true
    wait "$_s6rt_child_pid" 2>/dev/null || true
else
    assert_pass "[#1801/SPEC-6] TERM-ignoring child does not outlive the watchdog (group kill via zbuild_pg_kill)"
fi

print_test_results
