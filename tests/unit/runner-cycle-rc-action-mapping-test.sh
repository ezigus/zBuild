#!/usr/bin/env bash
# Unit test (#527): runner's cycle rc → (action, final pipeline_status) mapping.
#
# Table-driven coverage of the rc dispatch table at runner.sh dispatch loop:
#   rc=0   → continue, status=complete  (converged)
#   rc=1   → continue, status=failed    (max_iterations, _RUNNER_CYCLE_UNCONVERGED=1)
#   rc=2   → continue, status=failed    (plateau)
#   rc=3   → continue, status=failed    (divergence)
#   rc=4   → halt,     status=interrupted (config_invalid)
#   rc=5   → halt,     status=interrupted (blocked, #528)
#   rc=130 → halt,     status=interrupted (aborted)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "runner cycle rc → (action, status) mapping (#527)"
setup_test_env "runner-cycle-rc-mapping-527"

# #1921 follow-up: the runner resolves repo_root from CWD, so an in-process
# `main` snapshots into whatever repository the test stands in. These files used
# REAL issue numbers from the working checkout, adding commits to real issues'
# state branches (measured: 3 per run onto issue-698). Reserved id + throwaway
# repo; the cd below is what actually contains it.
_ZB_ISSUE="$(zb_test_issue)"
_ZB_REPO="$(zb_test_repo rc-action-mapping)"

_drive() {
    local _rc="$1" _reason="$2"
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
        cd "$_ZB_REPO" || exit 1
        source "$REPO_ROOT/core/pipeline/runner.sh" 2>/dev/null
        # #979: resolve the owned route-back-cycles fixture (retired standard.yaml).
        resolve_template_file() { echo "$REPO_ROOT/tests/fixtures/templates/route-back-cycles.yaml"; }
        # Make the stub cycle-aware: design_impact_cycle always converges (rc=0)
        # so this test focuses on build_review_cycle's rc → status mapping.
        eval "cycle_orchestrator_run() {
            if [[ \"\$1\" == \"design_impact_cycle\" ]]; then
                _CYCLE_LAST_TERMINATED_REASON=\"converged\"
                _CYCLE_LAST_ITERATIONS=1
                return 0
            fi
            _CYCLE_LAST_TERMINATED_REASON=\"$_reason\"
            _CYCLE_LAST_ITERATIONS=1
            return $_rc
        }"
        _find_plugin_for_stage() { echo "$REPO_ROOT/plugins/agent/build"; }
        runner_read_stage_verdict() { echo "request_changes"; }
        plugin_hook_call() {
            local state="$4"; local artdir; artdir="$(dirname "$state")/artifacts"; mkdir -p "$artdir"
            printf '{"verdict":"request_changes"}' > "$artdir/review.json"
            return 0
        }
        main --issue "$_ZB_ISSUE" --template route-back-cycles >/dev/null 2>&1
    )
    printf '%s' "$_tmp"
}

# Expected (rc, reason, expected_status, expected_review_ran[1/0])
_cases=(
    "0|converged|complete|1"
    "1|max_iterations|failed|1"
    "2|plateau|failed|1"
    "3|divergence|failed|1"
    "4|config_invalid|interrupted|0"
    "5|blocked|interrupted|0"
    "8|blocking_member_failure|failed|0"
    "130|aborted|interrupted|0"
)

# ONE drive per case (#1946). Each _drive runs the WHOLE runner and writes both
# pipeline-state.json and events.jsonl into the same dir; the loops below want
# one file each, so re-driving to read the second was 9 redundant full-pipeline
# runs — 53% of this file's wall clock, and what pushed the macOS unit tier past
# its 480s bound. Drive once, index the results.
declare -a _dirs=()
for _row in "${_cases[@]}"; do
    IFS='|' read -r _rc _reason _ _ <<< "$_row"
    _dirs+=("$(_drive "$_rc" "$_reason")")
done

for _i in "${!_cases[@]}"; do
    IFS='|' read -r _rc _reason _exp_status _exp_review <<< "${_cases[$_i]}"
    _dir="${_dirs[$_i]}"
    _state="$_dir/state/pipeline-state.json"
    _got_status="$(jq -r '.status' "$_state" 2>/dev/null)"
    assert_eq "rc=$_rc → pipeline_status=$_exp_status" "$_exp_status" "$_got_status"
    # #979: route-back-cycles.yaml (owned fixture) wraps plan as a leaf + design_impact_cycle (design+impact)
    # and review inside the outer build_review_cycle (ADR-026). The only top-level
    # stage:* unit is intake. Use `intake` as a smoke that stage:* dispatch
    # ran when rc∈{0,1,2,3} (continue path).
    _got_intake="$(jq -r '.stage_statuses.intake // "absent"' "$_state" 2>/dev/null)"
    if [[ "$_exp_review" == "1" ]]; then
        assert_eq "rc=$_rc → intake dispatched (stage_statuses.intake=complete) [#842]" \
            "complete" "$_got_intake"
    fi
    # Halt-class cases (rc∈{4,5,130}) abort before reaching pipeline finalize;
    # plan may or may not be recorded depending on when the halt fires. Don't
    # over-assert. The pipeline_status above is the authoritative check.
done

# _RUNNER_CYCLE_UNCONVERGED flag — verified indirectly through pipeline_status,
# but also assert the cycle.unconverged event ONLY fires for rc∈{1,2,3}.
for _i in "${!_cases[@]}"; do
    IFS='|' read -r _rc _reason _exp_status _exp_review <<< "${_cases[$_i]}"
    _ev="${_dirs[$_i]}/events/events.jsonl"
    _count="$(grep -c '"type":"cycle.unconverged"' "$_ev" 2>/dev/null)"
    [[ -z "$_count" ]] && _count=0
    case "$_rc" in
        1|2|3) assert_eq "rc=$_rc → cycle.unconverged emitted once" "1" "$_count" ;;
        *)     assert_eq "rc=$_rc → cycle.unconverged NOT emitted" "0" "$_count" ;;
    esac
done

# [SPEC-3]: rc=8 (blocking_member_failure) → state-file status=failed, not interrupted.
# ADR-013 specifies blocking_member_failure → HALT; status=failed. This assertion
# fails at baseline where the rc=8 catch-all writes status=interrupted.
# Reuse the rc=8 drive rather than running the pipeline a THIRD time for the
# same scenario (#1946). Looked up by rc, NOT by a literal index: a hardcoded
# _dirs[6] would keep passing while silently asserting on a different scenario
# the moment a case is added or reordered above.
_dir8=""
for _i in "${!_cases[@]}"; do
    [[ "${_cases[$_i]%%|*}" == "8" ]] && { _dir8="${_dirs[$_i]}"; break; }
done
# ONE failure per cause. If the rc=8 case is gone the assertion below cannot
# run at all, and letting it run anyway against an empty path reported a SECOND,
# misleading failure ("status was not failed") for the same single defect —
# sending the reader after a state-file bug that does not exist.
if [[ -z "$_dir8" ]]; then
    echo "  DIAGNOSTIC: no rc=8 case in _cases — [SPEC-3] cannot run" >&2
    FAIL=$((FAIL + 1))
else
    _state8="$_dir8/state/pipeline-state.json"
    # A missing state file would make the status check silently compare an
    # empty/'null' value against 'failed'. Surface the real cause instead.
    if [[ ! -f "$_state8" ]]; then
        echo "  DIAGNOSTIC: expected state file not found: $_state8" >&2
        echo "  DIAGNOSTIC: _drive 8 dir contents:" >&2
        ls -R "$_dir8" >&2 2>/dev/null || true
    fi
    _got8="$(jq -r '.status' "$_state8" 2>/dev/null)"
    assert_eq "[SPEC-3] rc=8 (blocking_member_failure) → state-file status=failed" "failed" "$_got8"
fi

print_test_results
