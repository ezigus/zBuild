#!/usr/bin/env bash
# Unit test (#547): stage dispatch loop eb_emit_event calls must be guarded so
# that a non-zero return from the event bus never aborts the pipeline via bash
# set -e, AND failures must be surfaced as warnings on stderr (not silently
# swallowed) — review followup to PR #554.
#
# Regression: after cycle.complete reason=max_iterations the review stage was
# skipped because eb_emit_event "stage.start" returned non-zero (lock contention
# from the deferred-tracker still writing to events.jsonl), and set -e was
# re-enabled before the call, causing bash to exit without setting
# _runner_ended=true, which triggered the EXIT trap → pipeline.abort.
#
# The fix in #554 was a bare `|| true` which silenced legitimate disk/perm
# failures (including the consumer-contract pipeline.end status=failed terminal
# event). This followup replaces those guards with a warn-wrapper. This test
# verifies, across all 4 sites (stage.start, stage.fail, pipeline.end
# status=failed, stage.complete):
#   (S1/S2) behavior: when eb_emit_event stage.start fails, the review stage
#           still runs and no pipeline.abort is emitted, and a warn line is
#           written to stderr — both converged and max_iterations paths.
#   (S3)    behavior: when eb_emit_event stage.complete fails, the dispatched
#           stage still completes cleanly and a warn line is emitted.
#   (S4)    shape: runner.sh contains a `warn` wrapper (not a bare `|| true`)
#           on each of the 4 guarded eb_emit_event sites in the stage:* arm of
#           the dispatch loop. This guards the stage.fail and
#           pipeline.end status=failed sites, which cannot easily be driven via
#           real dispatch because bash's `set -e` propagation through a nested
#           function that explicitly re-enables `set -e` exits the subshell
#           even when the caller wrapped the call in `set +e` — testing the
#           full failed-dispatch path requires extraction work tracked
#           separately. The source-shape assertion below ensures the bare
#           `|| true` guards do not silently regress.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "runner stage dispatch: eb_emit_event warn-wrapper guard (#547 review followup)"
setup_test_env "runner-stage-dispatch-eb-emit-guard-547"

# _drive_with_failing_eb runs the pipeline with eb_emit_event stubbed to return
# non-zero for the given event type. Captures stderr to verify warn output.
# Args: _cycle_rc _reason _fail_event
_drive_with_failing_eb() {
    local _cycle_rc="$1" _reason="${2:-converged}" _fail_event="${3:-stage.start}"
    local _tmp; _tmp="$(mktemp -d "$TEST_TEMP_DIR/m-XXXXXX")"
    local _stderr="$_tmp/stderr.log"
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

        eval "cycle_orchestrator_run() { _CYCLE_LAST_TERMINATED_REASON=\"$_reason\"; _CYCLE_LAST_ITERATIONS=1; return $_cycle_rc; }"
        eval "_TARGET_FAIL_EVENT='$_fail_event'"

        eb_emit_event() {
            local _evt="$1"
            local _ts; _ts="$(date -u +%s 2>/dev/null || echo 0)"
            printf '{"ts":%s,"type":"%s"}\n' "$_ts" "$_evt" \
                >> "${ZBUILD_EVENTS_JSONL:-/dev/null}" 2>/dev/null || true
            if [[ "$_evt" == "$_TARGET_FAIL_EVENT" ]]; then
                return 1
            fi
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
        main --issue 999 --template standard >/dev/null 2>"$_stderr"
    )
    printf '%s' "$_tmp"
}

_assert_warn_and_no_abort() {
    local _label="$1" _dir="$2" _fail_event="$3"
    local _ev="$_dir/events/events.jsonl"
    local _stderr="$_dir/stderr.log"

    local _abort_count; _abort_count="$(grep -c '"type":"pipeline.abort"' "$_ev" 2>/dev/null || true)"
    [[ -z "$_abort_count" ]] && _abort_count=0
    assert_eq "$_label: no pipeline.abort emitted when eb_emit_event $_fail_event fails" \
        "0" "$_abort_count"

    local _warn_hits; _warn_hits="$(grep -c "eb_emit_event $_fail_event failed" "$_stderr" 2>/dev/null || true)"
    [[ -z "$_warn_hits" ]] && _warn_hits=0
    local _hit_flag; _hit_flag=$([[ "$_warn_hits" -ge 1 ]] && echo 1 || echo 0)
    assert_eq "$_label: warn fired on stderr for eb_emit_event $_fail_event failure" \
        "1" "$_hit_flag"
}

# ─── S1: converged cycle, eb_emit_event stage.start fails ────────────────────
_dir="$(_drive_with_failing_eb 0 "converged" "stage.start")"
_state="$_dir/state/pipeline-state.json"
_got_review="$(jq -r '.stage_statuses.review // "absent"' "$_state" 2>/dev/null)"
assert_eq "S1 #547: stage.start fail — review dispatched (converged)" \
    "complete" "$_got_review"
_got_status="$(jq -r '.status' "$_state" 2>/dev/null)"
assert_eq "S1 #547: stage.start fail — pipeline_status=complete" \
    "complete" "$_got_status"
_assert_warn_and_no_abort "S1 #547" "$_dir" "stage.start"

# ─── S2: max_iterations cycle, eb_emit_event stage.start fails (bug repro) ───
_dir="$(_drive_with_failing_eb 1 "max_iterations" "stage.start")"
_state="$_dir/state/pipeline-state.json"
_got_review="$(jq -r '.stage_statuses.review // "absent"' "$_state" 2>/dev/null)"
assert_eq "S2 #547: stage.start fail — review dispatched (max_iterations)" \
    "complete" "$_got_review"
_got_status="$(jq -r '.status' "$_state" 2>/dev/null)"
assert_eq "S2 #547: stage.start fail — pipeline_status=failed" \
    "failed" "$_got_status"
_assert_warn_and_no_abort "S2 #547" "$_dir" "stage.start"

# ─── S3: eb_emit_event stage.complete fails — must warn, pipeline completes ──
_dir="$(_drive_with_failing_eb 0 "converged" "stage.complete")"
_state="$_dir/state/pipeline-state.json"
_got_review="$(jq -r '.stage_statuses.review // "absent"' "$_state" 2>/dev/null)"
assert_eq "S3 #547: stage.complete fail — stage still marked complete" \
    "complete" "$_got_review"
_assert_warn_and_no_abort "S3 #547" "$_dir" "stage.complete"

# ─── S4: source-shape assertion — all 4 guarded eb_emit_event sites in the
#        stage:* dispatch arm must use the warn-wrapper, not a bare `|| true`.
#        This is the safety net for the stage.fail and pipeline.end
#        status=failed sites, which cannot easily be exercised via real
#        dispatch due to bash set -e propagation through cycle_dispatch_stage.
_runner="$REPO_ROOT/core/pipeline/runner.sh"

# Each of the 4 event types must appear in a warn-wrapper line. We assert
# presence of `warn "eb_emit_event <event> ... failed` for each.
for _evt in "stage.start" "stage.fail" "pipeline.end status=failed" "stage.complete"; do
    _hits="$(grep -c "warn \"eb_emit_event $_evt failed" "$_runner" 2>/dev/null || true)"
    [[ -z "$_hits" ]] && _hits=0
    _flag=$([[ "$_hits" -ge 1 ]] && echo 1 || echo 0)
    assert_eq "S4 #547: source has warn-wrapper for eb_emit_event $_evt" \
        "1" "$_flag"
done

# Assert no bare `|| true` remains on any eb_emit_event line in the stage:*
# dispatch arm of runner.sh (lines 1044–1078, but the test reads dynamically:
# any line containing `eb_emit_event` AND `|| true` is forbidden in the
# stage-dispatch region). We use a sentinel-bracket grep approach: extract
# lines from the `stage:\*)` arm and confirm none ends with bare `|| true`.
_arm_block="$(awk '/^                stage:\*\)/{flag=1} flag; /^                    ;;/{if(flag){flag=0; exit}}' "$_runner")"
_bare_true_in_arm="$(echo "$_arm_block" | grep -c 'eb_emit_event.*|| true$' || true)"
[[ -z "$_bare_true_in_arm" ]] && _bare_true_in_arm=0
assert_eq "S4 #547: no bare '|| true' on eb_emit_event in stage:* dispatch arm" \
    "0" "$_bare_true_in_arm"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
