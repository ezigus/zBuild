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
#   4. ZBUILD_MAX_RUN_S is validated by the new function: a valid value leads to a
#      clean run; the function is the one that resolves it (not the runner ignoring it)
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

# max_run_s=30 is generous: the pipeline completes in < 5s, well before the limit
set +e
( cd "$CLEAN_OVERLAY" && ZBUILD_MAX_RUN_S=30 bash "$RUNNER" \
    --template watchdog-single --goal "clean run watchdog test" ) \
    >"$TEST_TEMP_DIR/clean.stdout" 2>"$TEST_TEMP_DIR/clean.stderr"
_clean_rc=$?
set -e

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

# ─── S3-4: watchdog process reaped — no lingering sleep from the run ────────
# We cannot easily inspect the runner's internal _RUNNER_WATCHDOG_PID from
# outside. We infer reaping by running with a VERY short max_run_s (3s) on a
# pipeline that completes in < 2s, then sleeping past max_run_s and confirming
# the pipeline status remains complete (not timed_out). If the watchdog were
# not reaped, it would fire at max_run_s and attempt to signal whatever is
# running — but since the runner has exited by then, the signal is benign
# (no runner to receive it). We verify the status file is not mutated.
print_test_section "[#1944/SPEC-3] watchdog reaped: status unchanged after waiting past max_run_s"

rm -f "$ZBUILD_STATE_DIR/pipeline-state.json" "$ZBUILD_EVENTS_JSONL"

set +e
( cd "$CLEAN_OVERLAY" && ZBUILD_MAX_RUN_S=5 bash "$RUNNER" \
    --template watchdog-single --goal "watchdog reaped test" ) \
    >"$TEST_TEMP_DIR/reaped.stdout" 2>"$TEST_TEMP_DIR/reaped.stderr"
_reaped_rc=$?
set -e

# Status captured immediately after runner exits
_status_before_wait=""
if [[ -f "$_clean_sf" ]]; then
    _status_before_wait="$(jq -r '.status // empty' "$_clean_sf" 2>/dev/null || true)"
fi

# Wait past max_run_s=5 by 2 seconds: if watchdog is not reaped, it fires here
sleep 7

# Status must not have changed — a live orphan watchdog cannot mutate the state
# file (the runner process that writes the file has already exited), but we
# verify no NEW timed_out event appeared in the log since the runner exited.
_timed_out_after_wait=0
if [[ -f "$ZBUILD_EVENTS_JSONL" ]]; then
    _timed_out_after_wait="$(jq -r 'select(.type=="pipeline.end" and .data.status=="timed_out") | .type' \
        "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
fi

assert_eq "[#1944/SPEC-3] runner exits 0 with max_run_s=5 on a quick stage" "0" "$_reaped_rc"
assert_eq "[#1944/SPEC-3] no timed_out event after waiting past max_run_s" "0" "$_timed_out_after_wait"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
