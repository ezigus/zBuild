#!/usr/bin/env bash
# [#1801/SPEC-7] Guard: removing ZBUILD_ORCH_TIMEOUT from the three strategy files
# means the per-dispatch watchdog is the only stage time limit.
#
# Before this change the strategy files had `orch_collect … --timeout
# "${ZBUILD_ORCH_TIMEOUT:-300}"` as a flat ceiling; a plan dispatch running
# longer than 300 s would have been killed even when its `stage_timeout_s`
# allowed more. After the change, orch_collect is called without --timeout (or
# with no ceiling), leaving the per-dispatch watchdog in lifecycle.sh as the
# only limit.
#
# The assertions are source-level: they verify that each strategy file no
# longer carries the flat ceiling. This test FAILS on pre-change code
# (where ZBUILD_ORCH_TIMEOUT still appears) and PASSES after the change.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "[#1801/SPEC-7] ZBUILD_ORCH_TIMEOUT absent from strategy files; no flat ceiling"
setup_test_env "stage-timeout-no-flat-limit"

# ─── Each strategy file must not reference ZBUILD_ORCH_TIMEOUT ───────────────
# These are the three files the design names: fanout.sh, sequential.sh, map.sh.
# Every occurrence of ZBUILD_ORCH_TIMEOUT pins a flat ceiling that the per-dispatch
# watchdog is meant to replace.

for _sf in \
    core/pipeline/strategies/fanout.sh \
    core/pipeline/strategies/sequential.sh \
    core/pipeline/strategies/map.sh; do

    _file="$REPO_ROOT/$_sf"
    if [[ ! -f "$_file" ]]; then
        assert_fail "[#1801/SPEC-7] $_sf exists" "file not found: $_file"
        continue
    fi

    if grep -q 'ZBUILD_ORCH_TIMEOUT' "$_file"; then
        assert_fail "[#1801/SPEC-7] $_sf carries no ZBUILD_ORCH_TIMEOUT flat ceiling" \
            "ZBUILD_ORCH_TIMEOUT still present — a plan dispatch longer than the default 300 s" \
            "would be killed before its stage_timeout_s expires"
    else
        assert_pass "[#1801/SPEC-7] $_sf carries no ZBUILD_ORCH_TIMEOUT flat ceiling"
    fi

    # Also verify orch_collect/orch_wait calls carry no --timeout flag.
    # A hard-coded --timeout N in the orch call would impose a flat ceiling
    # independent of ZBUILD_ORCH_TIMEOUT and would kill long-but-valid dispatches.
    if grep -qE 'orch_collect.*--timeout|orch_wait.*--timeout' "$_file"; then
        assert_fail "[#1801/SPEC-7] $_sf orch_collect/orch_wait carry no --timeout flag" \
            "--timeout found in orch call — imposes a flat ceiling that overrides stage_timeout_s"
    else
        assert_pass "[#1801/SPEC-7] $_sf orch_collect/orch_wait carry no --timeout flag"
    fi
done

# ─── [#1801/SPEC-7] behavioral: strategy dispatch does not pass --timeout ─────
# The old fanout.sh called `orch_collect "$pool_id" --timeout "$ZBUILD_ORCH_TIMEOUT"`.
# After the change, it calls `orch_collect "$pool_id"` — no flat ceiling.
# This behavioral test sources the actual fanout.sh, runs _strategy_run_fanout
# with mock orch functions that record what orch_collect is called with, and
# asserts --timeout is absent.
#
# Fails on pre-change code: fanout.sh passes --timeout to orch_collect.
# Passes on post-change code: fanout.sh calls orch_collect without --timeout.
print_test_section "[#1801/SPEC-7] behavioral: strategy dispatch does not pass --timeout to orch_collect"

# Mock orch backend contract functions; capture orch_collect args.
_spec7_orch_collect_called=0
_spec7_orch_collect_args=""
orch_spawn()    { return 0; }
orch_dispatch() { return 0; }
orch_shutdown() { return 0; }
orch_collect() {
    _spec7_orch_collect_called=1
    _spec7_orch_collect_args="$*"
    _ORCH_COLLECT_OUTCOME="passed"
    return 0
}

# Create a minimal mock plugin directory (manifest.yaml required by _strategy_make_work_unit).
_spec7_plugin="$TEST_TEMP_DIR/spec7-plugin"
mkdir -p "$_spec7_plugin"
cat > "$_spec7_plugin/manifest.yaml" <<'MANIFEST'
id: spec7-plan
name: Spec7 Plan
kind: agent
version: 0.0.1
roles:
  - plan
MANIFEST
cat > "$_spec7_plugin/plugin.sh" <<'PLUGIN'
zbuild_run() { :; }
PLUGIN

# Mock resolve_plugin_for_role to return our plugin dir for any role.
resolve_plugin_for_role() { echo "$_spec7_plugin"; return 0; }

# Set ZBUILD_ORCH_TIMEOUT — if the strategy still passes it to orch_collect,
# the test will catch it.
export ZBUILD_ORCH_TIMEOUT=1
_DETECTED_PLATFORMS=("linux")
export ZBUILD_ORCH_SCRATCH="$TEST_TEMP_DIR/spec7-scratch"
export ZBUILD_RUN_ID="spec7-test"
mkdir -p "$ZBUILD_ORCH_SCRATCH"
_spec7_state="$TEST_TEMP_DIR/spec7-state.json"
printf '{"pipeline_status":"running"}' > "$_spec7_state"

# Source fanout.sh under test (reset the guard to force re-source).
unset _ZBUILD_STRATEGY_FANOUT_LOADED 2>/dev/null || true
unset _ZBUILD_STRATEGY_COMMON_LOADED 2>/dev/null || true
# shellcheck source=../../core/pipeline/strategies/fanout.sh
source "$REPO_ROOT/core/pipeline/strategies/fanout.sh" 2>/dev/null || true

# Run _strategy_run_fanout; ignore its exit code (pool is empty / mock plugin not real).
set +e
_strategy_run_fanout "pool-spec7" "plan" "plan" "$_spec7_state" "$TEST_TEMP_DIR/plugins"
set -e

unset ZBUILD_ORCH_TIMEOUT

if [[ "$_spec7_orch_collect_called" -eq 0 ]]; then
    assert_fail "[#1801/SPEC-7] behavioral: orch_collect was invoked by _strategy_run_fanout" \
        "orch_collect not called — check mock resolve_plugin_for_role setup"
elif grep -q '\-\-timeout' <<< "$_spec7_orch_collect_args"; then
    assert_fail "[#1801/SPEC-7] behavioral: _strategy_run_fanout calls orch_collect without --timeout" \
        "orch_collect received '--timeout': args='$_spec7_orch_collect_args' — ZBUILD_ORCH_TIMEOUT flat ceiling still in fanout.sh"
else
    assert_pass "[#1801/SPEC-7] behavioral: _strategy_run_fanout calls orch_collect without --timeout (no flat ceiling)"
fi

# ─── [#1801/SPEC-7] behavioral: a dispatch running past ZBUILD_ORCH_TIMEOUT exits 0 ──
# The requirement: "a plan dispatch whose hook sleeps 310 s (inside its stage_timeout_s)
# completes with exit 0, proving no earlier ceiling fires".
# Scaled to 2 s to keep the test fast. ZBUILD_ORCH_TIMEOUT=1 is the old flat ceiling
# (pre-change: strategy passed --timeout 1 to orch_collect, killing a 2s dispatch).
# Post-change: no --timeout, orch_collect sleeps 2s, returns 0 → exit 0.
#
# This FAILS on pre-change code (fanout passes --timeout 1 → ceiling fires → exit 1)
# and PASSES on post-change code (no --timeout → dispatch completes → exit 0).
print_test_section "[#1801/SPEC-7] behavioral: dispatch running 2s with ZBUILD_ORCH_TIMEOUT=1 exits 0"

# Redefine orch_collect: if it receives --timeout ≤ 1 (the old flat ceiling value),
# simulate the ceiling firing (return 1 immediately). If called without --timeout
# (post-change), sleep 2s to represent a 310s stage running within stage_timeout_s,
# then return 0.
_spec7c_ceiling_fired=0
orch_collect() {
    local _to=0 _prev="" _arg
    for _arg in "$@"; do
        [[ "$_prev" == "--timeout" ]] && _to="$_arg"
        _prev="$_arg"
    done
    if [[ "$_to" -gt 0 ]] && [[ "$_to" -le 1 ]]; then
        # Old flat ceiling: --timeout 1 would kill a 2s dispatch
        _spec7c_ceiling_fired=1
        _ORCH_COLLECT_OUTCOME="failed"
        return 1
    fi
    # No flat ceiling: simulate a 2s dispatch that finishes within stage_timeout_s
    sleep 2
    _ORCH_COLLECT_OUTCOME="passed"
    return 0
}

export ZBUILD_ORCH_TIMEOUT=1
_spec7c_state="$TEST_TEMP_DIR/spec7c-state.json"
printf '{"pipeline_status":"running"}' > "$_spec7c_state"
export ZBUILD_ORCH_SCRATCH="$TEST_TEMP_DIR/spec7c-scratch"
export ZBUILD_RUN_ID="spec7c-test"
mkdir -p "$TEST_TEMP_DIR/spec7c-scratch"

# Re-source fanout.sh (reset guard — common.sh is re-sourced and redefines
# _strategy_make_work_unit; we override it below, after the source).
unset _ZBUILD_STRATEGY_FANOUT_LOADED 2>/dev/null || true
unset _ZBUILD_STRATEGY_COMMON_LOADED 2>/dev/null || true
# shellcheck source=../../core/pipeline/strategies/fanout.sh
source "$REPO_ROOT/core/pipeline/strategies/fanout.sh" 2>/dev/null || true

# Override _strategy_make_work_unit AFTER sourcing so common.sh cannot clobber it.
# This ensures dispatch_count > 0 and orch_collect is reached (with our sleeping mock).
_strategy_make_work_unit() {
    local _wu; _wu="$(mktemp "$TEST_TEMP_DIR/wu-XXXXXX.json")"
    printf '{"plugin_dir":"%s","stage":"%s","platform":"%s"}' \
        "${1:-}" "${2:-}" "${4:-linux}" > "$_wu"
    echo "$_wu"
    return 0
}

set +e
_strategy_run_fanout "pool-spec7c" "plan" "plan" "$_spec7c_state" "$TEST_TEMP_DIR/plugins"
_spec7c_rc=$?
set -e
unset ZBUILD_ORCH_TIMEOUT

if [[ "$_spec7c_rc" -eq 0 ]]; then
    assert_pass "[#1801/SPEC-7] behavioral: dispatch running 2s with ZBUILD_ORCH_TIMEOUT=1 completes exit 0 (no flat ceiling)"
else
    if [[ "$_spec7c_ceiling_fired" -eq 1 ]]; then
        assert_fail "[#1801/SPEC-7] behavioral: dispatch running 2s with ZBUILD_ORCH_TIMEOUT=1 completes exit 0 (no flat ceiling)" \
            "exit $_spec7c_rc — flat ceiling fired (fanout still passes --timeout 1 to orch_collect)"
    else
        assert_fail "[#1801/SPEC-7] behavioral: dispatch running 2s with ZBUILD_ORCH_TIMEOUT=1 completes exit 0 (no flat ceiling)" \
            "exit $_spec7c_rc — dispatch failed for an unrelated reason (check mock setup)"
    fi
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
