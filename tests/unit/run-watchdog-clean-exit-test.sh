#!/usr/bin/env bash
# tests/unit/run-watchdog-clean-exit-test.sh — clean-exit watchdog lifecycle (#1944)
#
# SPEC-3 [code]:
#   A run that finishes within max_run_s exits with its own pipeline status
#   unchanged; the watchdog process does not exist after the runner process exits.
#
# A test that only checks "runner exits 0" passes BEFORE implementation too.
# We discriminate by also asserting:
#   1. _runner_resolve_run_limit_s is defined (fails before implementation)
#   2. With ZBUILD_MAX_RUN_S set, the completed run's status is the stage-reported
#      status — not timed_out (impl must not fire the watchdog on a clean run)
#   3. No pipeline.end status=timed_out in the events log (watchdog was reaped)
#   4. Watchdog process is dead after runner exits: abort sentinel is NOT written
#      after the runner exits — an un-reaped watchdog would write it when it fires.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "run-watchdog-clean-exit: watchdog reaped, status unchanged (#1944 SPEC-3)"
setup_test_env "run-watchdog-clean-exit"

RUNNER="$REPO_ROOT/core/pipeline/runner.sh"
STAGE_LIMITS="$REPO_ROOT/scripts/lib/stage-limits.sh"

# ─── S3-1: _runner_resolve_run_limit_s is defined ───────────────────────────
print_test_section "[#1944/SPEC-3] _runner_resolve_run_limit_s defined in stage-limits.sh"

# shellcheck source=../../scripts/lib/stage-limits.sh
source "$STAGE_LIMITS" 2>/dev/null || true

if declare -F _runner_resolve_run_limit_s >/dev/null 2>&1; then
    assert_pass "[#1944/SPEC-3] _runner_resolve_run_limit_s is defined"
else
    assert_fail "[#1944/SPEC-3] _runner_resolve_run_limit_s is defined" \
        "function not found; watchdog arms only when this function exists"
fi

# ─── S3-2: clean run with max_run_s set → status unchanged, not timed_out ──
print_test_section "[#1944/SPEC-3] clean run with max_run_s=30 exits with complete status"

export ZBUILD_PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_CONTRACT_VALIDATOR=warn
export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_CYCLES_ENABLED=0
export ZBUILD_SCOPE_OVERRIDE=1
mkdir -p "$ZBUILD_STATE_DIR" "$ZBUILD_EVENTS_DIR" "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"

# Minimal 1-stage pipeline that completes quickly (no sleep)
mock_plugin_factory "intake" "agent" 0 >/dev/null

CLEAN_OVERLAY="$(setup_git_temp_repo watchdog-clean-exit)"
mkdir -p "$CLEAN_OVERLAY/.zbuild/templates"
cat > "$CLEAN_OVERLAY/.zbuild/templates/watchdog-single.yaml" <<'EOF'
id: watchdog-single
extends: simple
stages:
  - id: intake
    gate: auto
    io:
      destinations: [file]
      tail_lines: 50
EOF
(cd "$CLEAN_OVERLAY" && git add .zbuild && git commit -q -m "add watchdog-single template") \
    >/dev/null 2>&1

# max_run_s=30 is generous: the pipeline completes in < 5s, well before the limit
_clean_rc=0
( cd "$CLEAN_OVERLAY" && ZBUILD_MAX_RUN_S=30 bash "$RUNNER" \
    --template watchdog-single --goal "clean run watchdog test" ) \
    >"$TEST_TEMP_DIR/clean.stdout" 2>"$TEST_TEMP_DIR/clean.stderr" \
    || _clean_rc=$?

_clean_sf="$ZBUILD_STATE_DIR/pipeline-state.json"

assert_eq "[#1944/SPEC-3] clean run exits 0" "0" "$_clean_rc"

if [[ -f "$_clean_sf" ]]; then
    _clean_status="$(jq -r '.status // empty' "$_clean_sf" 2>/dev/null || true)"
    # Status must be the stage-driven completion, not timed_out
    if [[ "$_clean_status" == "complete" || "$_clean_status" == "success" ]]; then
        assert_pass "[#1944/SPEC-3] pipeline status is complete (not timed_out)"
    else
        assert_fail "[#1944/SPEC-3] pipeline status is complete (not timed_out)" \
            "actual status: ${_clean_status:-<empty>}"
    fi
    assert_eq "[#1944/SPEC-3] pipeline status is NOT timed_out" "" \
        "$([[ "$_clean_status" == "timed_out" ]] && echo "timed_out" || echo "")"
else
    assert_fail "[#1944/SPEC-3] pipeline-state.json written" \
        "state file not found: $_clean_sf"
fi

# ─── S3-3: no timed_out event after clean run ───────────────────────────────
print_test_section "[#1944/SPEC-3] no pipeline.end status=timed_out in events log after clean run"

if [[ -f "$ZBUILD_EVENTS_JSONL" ]]; then
    _timed_out_events="$(jq -r 'select(.type=="pipeline.end" and .data.status=="timed_out") | .type' \
        "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
    assert_eq "[#1944/SPEC-3] no pipeline.end/timed_out event after clean run" "0" "$_timed_out_events"
else
    # Events file absent means no events fired — acceptable for a clean run
    assert_pass "[#1944/SPEC-3] no timed_out event (events file absent)"
fi

# ─── S3-4: watchdog process is dead — abort sentinel NOT written after exit ──
# The watchdog does `sleep $_wdg_lim` and writes to the abort sentinel when it
# fires. The runner's EXIT trap kills the watchdog (kill -KILL) and disarms the
# sentinel. If the watchdog is NOT reaped, it fires at max_run_s seconds after
# the runner exits and writes to the sentinel file. We verify:
#   - Runner exits cleanly within max_run_s=4s (fast stage, << 4s)
#   - We wait past max_run_s=4 (sleep 5s)
#   - The abort sentinel must not be present: neither created by the watchdog
#     firing after the runner exited, nor left over from the run.
print_test_section "[#1944/SPEC-3] watchdog killed: abort sentinel not written after runner exits"

rm -f "$ZBUILD_EVENTS_JSONL"
# Use a fresh state dir to keep sentinel check clean
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state-sentinel"
mkdir -p "$ZBUILD_STATE_DIR"
_ABORT_SENTINEL="$ZBUILD_STATE_DIR/.abort.signal"
rm -f "$_ABORT_SENTINEL"

# max_run_s=4: watchdog would fire 4s after runner exits if not reaped.
# The fast stage completes in < 2s, so the runner exits well before max_run_s.
_reaped_rc=0
( cd "$CLEAN_OVERLAY" && ZBUILD_MAX_RUN_S=4 bash "$RUNNER" \
    --template watchdog-single --goal "watchdog reaped sentinel test" ) \
    >"$TEST_TEMP_DIR/reaped.stdout" 2>"$TEST_TEMP_DIR/reaped.stderr" \
    || _reaped_rc=$?

assert_eq "[#1944/SPEC-3] clean run with max_run_s=4 exits 0" "0" "$_reaped_rc"

# Wait past max_run_s=4: if watchdog not reaped, it would write the sentinel here
sleep 5

# The abort sentinel must NOT be present: the EXIT trap disarmed it (clean exit)
# and a reaped watchdog cannot write it again after the runner exits.
if [[ -f "$_ABORT_SENTINEL" ]]; then
    _sentinel_content="$(cat "$_ABORT_SENTINEL" 2>/dev/null || true)"
    assert_fail "[#1944/SPEC-3] watchdog killed before it fired: abort sentinel absent after runner exit" \
        "sentinel exists with content '${_sentinel_content:-<empty>}' — watchdog fired AFTER runner exited"
else
    assert_pass "[#1944/SPEC-3] watchdog killed: abort sentinel absent after runner exits (watchdog was reaped)"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
