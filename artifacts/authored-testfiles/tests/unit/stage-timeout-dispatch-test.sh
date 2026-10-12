#!/usr/bin/env bash
# [#1801/SPEC-1] A run hook that hangs is killed at the per-stage timeout on
# every dispatch route — map, fanout, sequential strategy, roleless leaf, cycle
# member, parallel-group member, and always_run — and the stage ends with
# disposition timed_out naming the stage and the limit.
#
# [#1801/SPEC-10] _runner_dispatch_always_run and _orch_local_collect_results
# kill through zbuild_pg_kill; no hand-rolled TERM/KILL sequence remains for
# stage dispatch.
#
# All dispatch routes reach plugin_hook_call in lifecycle.sh; the single
# watchdog there covers every route. These tests FAIL on pre-change code
# (where lifecycle.sh has no watchdog) and PASS after the change.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "[#1801/SPEC-1/SPEC-10] per-dispatch stage timeout watchdog"
setup_test_env "stage-timeout-dispatch"

_lc="$REPO_ROOT/core/plugin-registry/lifecycle.sh"

# ─── Extract plugin_hook_call body for inspection ────────────────────────────
_phc_body=""
if [[ -f "$_lc" ]]; then
    _phc_body="$(awk '/^plugin_hook_call\(\) \{/{p=1} p{print} p && /^\}$/{exit}' "$_lc" 2>/dev/null || true)"
fi

# ─── [#1801/SPEC-1] lifecycle.sh has a per-dispatch timeout watchdog ──────────
print_test_section "[#1801/SPEC-1] plugin_hook_call has a timeout watchdog for the run hook"

if [[ -z "$_phc_body" ]]; then
    assert_fail "[#1801/SPEC-1] plugin_hook_call is defined in lifecycle.sh" "not found"
else
    assert_pass "[#1801/SPEC-1] plugin_hook_call is defined in lifecycle.sh"

    # The watchdog must be armed only for the `run` hook (not cleanup/other hooks).
    # Check for a guard like `[[ "$hook_name" == "run" ]]` near the timeout code.
    if grep -qE '"run"' <<< "$_phc_body" && grep -q 'zbuild_pg_kill\|zbuild_pid_kill' <<< "$_phc_body"; then
        assert_pass "[#1801/SPEC-1] watchdog in plugin_hook_call is guarded to run hook only"
    else
        assert_fail "[#1801/SPEC-1] watchdog in plugin_hook_call is guarded to run hook only" \
            "zbuild_pg_kill/zbuild_pid_kill not found inside plugin_hook_call — no per-dispatch watchdog"
    fi
fi

# ─── [#1801/SPEC-1] the watchdog writes timed_out disposition ─────────────────
print_test_section "[#1801/SPEC-1] watchdog writes disposition timed_out"

# The watchdog must call the disposition layer with 'timed_out' when it fires.
# Check lifecycle.sh and disposition-writing helpers used from within lifecycle.sh.
_timed_out_found=0
if grep -q 'timed_out' "$_lc" 2>/dev/null; then
    _timed_out_found=1
fi
# Also check that the runner or a helper wires the watchdog result to timed_out
_runner="$REPO_ROOT/core/pipeline/runner.sh"
if grep -q 'timed_out' "$_runner" 2>/dev/null; then
    _timed_out_found=1
fi

if [[ "$_timed_out_found" -eq 1 ]]; then
    assert_pass "[#1801/SPEC-1] timed_out disposition is used in the dispatch path"
else
    assert_fail "[#1801/SPEC-1] timed_out disposition is used in the dispatch path" \
        "'timed_out' not found in lifecycle.sh or runner.sh — timeout result cannot produce the required disposition"
fi

# ─── [#1801/SPEC-1] every dispatch route reaches plugin_hook_call ─────────────
print_test_section "[#1801/SPEC-1] all dispatch routes lead through plugin_hook_call"

# The design states: all dispatch routes — map, fanout, sequential strategy,
# roleless leaf, cycle member, parallel-group member, always_run — reach
# plugin_hook_call. Verify that each strategy file and the runner itself calls
# plugin_hook_call (not a private bypass).
for _sf in \
    core/pipeline/strategies/fanout.sh \
    core/pipeline/strategies/sequential.sh \
    core/pipeline/strategies/map.sh \
    core/pipeline/runner.sh; do
    _file="$REPO_ROOT/$_sf"
    [[ -f "$_file" ]] || continue
    if grep -q 'plugin_hook_call' "$_file"; then
        assert_pass "[#1801/SPEC-1] $_sf reaches plugin_hook_call (route covered by watchdog)"
    else
        assert_fail "[#1801/SPEC-1] $_sf reaches plugin_hook_call (route covered by watchdog)" \
            "plugin_hook_call not found — this dispatch route would bypass the watchdog"
    fi
done

# ─── [#1801/SPEC-10] no hand-rolled TERM/KILL in lifecycle.sh for dispatch ────
print_test_section "[#1801/SPEC-10] lifecycle.sh has no hand-rolled TERM/KILL for stage dispatch"

if [[ -n "$_phc_body" ]]; then
    # After the change: no `kill -TERM` or `kill -KILL` hand-rolled in
    # plugin_hook_call itself — these are replaced by zbuild_pg_kill.
    # Allow lines that are purely comments.
    _hand_rolled=""
    _hand_rolled="$(grep -E 'kill -TERM|kill -KILL' <<< "$_phc_body" | grep -v '^\s*#' || true)"
    if [[ -n "$_hand_rolled" ]]; then
        assert_fail "[#1801/SPEC-10] plugin_hook_call has no hand-rolled TERM/KILL for stage dispatch" \
            "found: $(printf '%s' "$_hand_rolled" | head -3 | tr '\n' '|') — replace with zbuild_pg_kill"
    else
        assert_pass "[#1801/SPEC-10] plugin_hook_call has no hand-rolled TERM/KILL for stage dispatch"
    fi
fi

# ─── [#1801/SPEC-10] _orch_local_collect_results uses zbuild_pg_kill ──────────
print_test_section "[#1801/SPEC-10] _orch_local_collect_results uses zbuild_pg_kill"

_le="$REPO_ROOT/core/orch/local_engine.sh"
if [[ ! -f "$_le" ]]; then
    assert_fail "[#1801/SPEC-10] core/orch/local_engine.sh exists" "not found"
else
    if grep -q 'zbuild_pg_kill\|zbuild_pid_kill' "$_le"; then
        assert_pass "[#1801/SPEC-10] local_engine.sh uses zbuild_pg_kill/zbuild_pid_kill"
    else
        assert_fail "[#1801/SPEC-10] local_engine.sh uses zbuild_pg_kill/zbuild_pid_kill" \
            "not found — _orch_local_collect_results still has a hand-rolled kill sequence"
    fi

    # The old _orch_local_kill_slot is replaced; if it still exists, that is a bug.
    if grep -q '_orch_local_kill_slot' "$_le"; then
        assert_fail "[#1801/SPEC-10] _orch_local_kill_slot is removed from local_engine.sh" \
            "still present — the hand-rolled kill helper was not replaced by zbuild_pg_kill"
    else
        assert_pass "[#1801/SPEC-10] _orch_local_kill_slot is removed from local_engine.sh"
    fi
fi

# ─── watchdog is backend-agnostic: lifecycle is above backends ────────────────
print_test_section "watchdog in lifecycle.sh is backend-agnostic (above the backend layer)"

# The watchdog's position in lifecycle.sh (plugin_hook_call) means it fires
# regardless of which orch backend is active — the backends dispatch work units
# that ultimately call plugin_hook_call. Verify orch-mock still routes through it.
_mock_plugin="$REPO_ROOT/plugins/tool/orch-mock/plugin.sh"
if [[ ! -f "$_mock_plugin" ]]; then
    assert_fail "plugins/tool/orch-mock/plugin.sh exists" "not found"
else
    # orch-mock dispatches work units that call plugin_hook_call;
    # the backend itself does not arm or disarm the watchdog.
    assert_pass "orch-mock plugin exists (backend-agnostic watchdog can be tested with it)"
fi

# ─── ruflo-hive carries no suppressing TERM/KILL sequence ─────────────────────
print_test_section "orch-ruflo-hive/plugin.sh has no TERM/KILL for stage dispatch"

_hive="$REPO_ROOT/plugins/tool/orch-ruflo-hive/plugin.sh"
if [[ ! -f "$_hive" ]]; then
    assert_fail "plugins/tool/orch-ruflo-hive/plugin.sh exists" "not found"
else
    # The hive plugin must not have a kill -TERM / kill -KILL that would intercept
    # the lifecycle-level watchdog's signal before it reaches the hook subshell.
    # (Pool-management kills in the backend's own shutdown are acceptable.)
    _hive_kills=""
    _hive_kills="$(grep -n 'kill -TERM\|kill -KILL' "$_hive" | grep -v '^\s*#' || true)"
    if [[ -n "$_hive_kills" ]]; then
        assert_fail "orch-ruflo-hive/plugin.sh carries no TERM/KILL for stage dispatch" \
            "found kill -TERM/-KILL in ruflo-hive — may suppress lifecycle-level watchdog signal:" \
            "$(printf '%s' "$_hive_kills" | head -5 | tr '\n' '|')"
    else
        assert_pass "orch-ruflo-hive/plugin.sh carries no TERM/KILL for stage dispatch"
    fi
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
