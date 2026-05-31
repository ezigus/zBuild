#!/usr/bin/env bash
# Unit test (#547): stage dispatch loop eb_emit_event calls must be guarded with
# || true so that a non-zero return from the event bus never aborts the pipeline
# via bash set -e.
#
# Regression: after cycle.complete reason=max_iterations the review stage was
# skipped because eb_emit_event "stage.start" returned non-zero (lock contention
# from the deferred-tracker still writing to events.jsonl), and set -e was
# re-enabled before the call, causing bash to exit without setting
# _runner_ended=true, which triggered the EXIT trap → pipeline.abort.
#
# This test stubs eb_emit_event to always return 1 for stage.start events and
# verifies that:
#   (a) the review stage still runs (stage_statuses.review == complete), and
#   (b) the runner exits 0 on a converged cycle (no pipeline.abort).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "runner stage dispatch: eb_emit_event || true guard (#547)"
setup_test_env "runner-stage-dispatch-eb-emit-guard-547"

# _drive_with_failing_eb cycles_enabled=1 so the standard template's cycle:build-test
# path runs, then falls through to stage:review. eb_emit_event is overridden to
# return 1 for "stage.start" events to simulate lock-contention failure.
_drive_with_failing_eb() {
    local _cycle_rc="$1" _reason="${2:-converged}"
    local _tmp; _tmp="$(mktemp -d "$TEST_TEMP_DIR/m-XXXXXX")"
    (
        set +e
        export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
        export ZBUILD_EVENTS_DIR="$_tmp/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
        export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
        export ZBUILD_STATE_DIR="$_tmp/state"; mkdir -p "$ZBUILD_STATE_DIR"
        export ZBUILD_STATE_FILE="$ZBUILD_STATE_DIR/pipeline-state.json"
        export ZBUILD_CYCLES_ENABLED=1
        export ZBUILD_CONTRACT_VALIDATOR=warn
        export ZBUILD_PLUGINS_ROOT="$REPO_ROOT/plugins"
        # shellcheck disable=SC1091
        source "$REPO_ROOT/core/pipeline/runner.sh" 2>/dev/null

        # Simulate a cycle that exits with the given rc (e.g. 0=converged, 1=max_iter).
        eval "cycle_orchestrator_run() { _CYCLE_LAST_TERMINATED_REASON=\"$_reason\"; _CYCLE_LAST_ITERATIONS=1; return $_cycle_rc; }"

        # Stub eb_emit_event to return 1 for stage.start — mimics lock contention
        # from the deferred-tracker still writing cycle.complete to events.jsonl.
        # All other events succeed so the state file is written correctly.
        eb_emit_event() {
            local _evt="$1"
            # Write a minimal JSON line so downstream assertions still work.
            local _ts; _ts="$(date -u +%s 2>/dev/null || echo 0)"
            printf '{"ts":%s,"type":"%s"}\n' "$_ts" "$_evt" \
                >> "${ZBUILD_EVENTS_JSONL:-/dev/null}" 2>/dev/null || true
            # Return non-zero for stage.start to trigger the bug under test.
            [[ "$_evt" == "stage.start" ]] && return 1
            return 0
        }

        _find_plugin_for_stage() { echo "$REPO_ROOT/plugins/agent/review"; }
        runner_read_stage_verdict() { echo "request_changes"; }
        plugin_hook_call() {
            local state="$4"
            local artdir; artdir="$(dirname "$state")/artifacts"
            mkdir -p "$artdir"
            printf '{"verdict":"request_changes"}' > "$artdir/review.json"
            return 0
        }
        main --issue 999 --template standard >/dev/null 2>&1
    )
    printf '%s' "$_tmp"
}

# ─── Test S1: converged cycle (rc=0) — review dispatched despite eb_emit_event
#              returning 1 for stage.start ───────────────────────────────────────
_dir="$(_drive_with_failing_eb 0 "converged")"
_state="$_dir/state/pipeline-state.json"

_got_review="$(jq -r '.stage_statuses.review // "absent"' "$_state" 2>/dev/null)"
assert_eq "S1 #547: converged cycle — review dispatched when eb_emit_event stage.start fails" \
    "complete" "$_got_review"

_got_status="$(jq -r '.status' "$_state" 2>/dev/null)"
assert_eq "S1 #547: converged cycle — pipeline_status=complete when eb_emit_event fails" \
    "complete" "$_got_status"

# ─── Test S2: max_iterations cycle (rc=1, the exact bug scenario) — review
#              must still run even when eb_emit_event stage.start returns non-zero ─
_dir="$(_drive_with_failing_eb 1 "max_iterations")"
_state="$_dir/state/pipeline-state.json"

_got_review="$(jq -r '.stage_statuses.review // "absent"' "$_state" 2>/dev/null)"
assert_eq "S2 #547: max_iterations cycle — review dispatched when eb_emit_event stage.start fails" \
    "complete" "$_got_review"

# Pipeline should be failed (unconverged) but NOT interrupted/aborted.
_got_status="$(jq -r '.status' "$_state" 2>/dev/null)"
assert_eq "S2 #547: max_iterations cycle — pipeline_status=failed (not interrupted) when eb_emit_event fails" \
    "failed" "$_got_status"

# Verify no pipeline.abort was emitted (the original bug symptom).
_ev="$_dir/events/events.jsonl"
_abort_count="$(grep -c '"type":"pipeline.abort"' "$_ev" 2>/dev/null || true)"
[[ -z "$_abort_count" ]] && _abort_count=0
assert_eq "S2 #547: no pipeline.abort emitted when eb_emit_event stage.start fails" \
    "0" "$_abort_count"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
