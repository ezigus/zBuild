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

print_test_results
