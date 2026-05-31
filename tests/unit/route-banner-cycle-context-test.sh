#!/usr/bin/env bash
# Unit test (#566): route.sh's per-iteration [llm] banner guard MUST resolve
# the stage id when invoked inside a cycle context. Today _cycle_iter_dispatch
# fails to export ZBUILD_CURRENT_STAGE, so route.sh:679 resolves stage_id to ""
# and route.sh:680's guard silently skips stage_io_begin --kind llm.
#
# This test exercises _cycle_iter_dispatch directly with a stubbed
# cycle_dispatch_stage that records what ZBUILD_CURRENT_STAGE looks like at
# dispatch time, then asserts (a) the var is exported per stage during the
# loop, (b) the route.sh guard would resolve the stage id non-empty, and
# (c) after the loop ZBUILD_CURRENT_STAGE is restored to its prior state.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "route banner cycle context — ZBUILD_CURRENT_STAGE export (#566)"
setup_test_env "route-banner-cycle-context"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ZBUILD_STATE_DIR"

# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"

STATE_FILE="$ZBUILD_STATE_DIR/pipeline-state.json"
jq -n '{schema_version:1, stage_statuses:{}, updated_at:"seed"}' > "$STATE_FILE"

# ─── Stub cycle_dispatch_stage: record stage var seen at dispatch time ───────
SEEN_LOG="$TEST_TEMP_DIR/seen-stages.log"
: > "$SEEN_LOG"
cycle_dispatch_stage() {
    local _stage="$1"
    # The bug: ZBUILD_CURRENT_STAGE is empty here without the fix.
    # The route.sh guard fallback also checks ZBUILD_PLUGIN — we deliberately
    # leave it unset to mimic the build_stage_run subshell where the
    # build_stage_init's export does not propagate.
    printf 'stage_arg=%s ZBUILD_CURRENT_STAGE=%s ZBUILD_PLUGIN=%s\n' \
        "$_stage" "${ZBUILD_CURRENT_STAGE:-UNSET}" "${ZBUILD_PLUGIN:-UNSET}" \
        >> "$SEEN_LOG"
    _CYCLE_DISPATCH_VERDICT="pass"
    _CYCLE_DISPATCH_STATUS="complete"
    return 0
}

# ─── Set up orchestrator state for one cycle, two stages ─────────────────────
_CYCLE_STAGES=(build test)
_CYCLE_TRAP_CYCLE_ID="cyc1"
# Avoid the trap installer noise — we only care about per-iter dispatch.
_cycle_install_traps() { :; }
_cycle_pre_iter_cleanup() { :; }

# Ensure caller environment has ZBUILD_CURRENT_STAGE unset BEFORE the call,
# so restore-after-loop semantics can be asserted.
unset ZBUILD_CURRENT_STAGE
unset ZBUILD_PLUGIN

# Dispatch one iter.
set +e; _cycle_iter_dispatch 1 "$STATE_FILE"; rc=$?; set -e
assert_eq "_cycle_iter_dispatch rc=0" "0" "$rc"

# (1) Both stages dispatched with ZBUILD_CURRENT_STAGE matching the stage arg.
build_line="$(grep '^stage_arg=build ' "$SEEN_LOG" || true)"
test_line="$(grep '^stage_arg=test '  "$SEEN_LOG" || true)"
assert_contains "build dispatch: ZBUILD_CURRENT_STAGE=build (RED today)" \
    "$build_line" "ZBUILD_CURRENT_STAGE=build"
assert_contains "test dispatch: ZBUILD_CURRENT_STAGE=test (RED today)" \
    "$test_line" "ZBUILD_CURRENT_STAGE=test"

# (2) route.sh's guard mirror: the resolved stage id MUST be non-empty
# at dispatch time. Without the fix this assertion fails (stage_id="").
build_stage_id="${build_line#*ZBUILD_CURRENT_STAGE=}"
build_stage_id="${build_stage_id%% *}"
if [[ -n "$build_stage_id" && "$build_stage_id" != "UNSET" ]]; then
    assert_pass "route.sh guard would resolve _iter_stage_id non-empty for build"
else
    assert_fail "route.sh guard would resolve _iter_stage_id non-empty for build" \
        "got: '$build_stage_id' — banner is silently skipped"
fi

# (3) After the dispatch loop returns, ZBUILD_CURRENT_STAGE MUST NOT pollute
# the caller's env (it was unset before — must remain unset after).
post_state="${ZBUILD_CURRENT_STAGE:-UNSET}"
assert_eq "ZBUILD_CURRENT_STAGE restored to unset after loop" "UNSET" "$post_state"

# (4) Prior-value restore: if caller had a value, it must be preserved.
export ZBUILD_CURRENT_STAGE="caller-stage"
: > "$SEEN_LOG"
set +e; _cycle_iter_dispatch 2 "$STATE_FILE"; rc=$?; set -e
assert_eq "_cycle_iter_dispatch rc=0 with prior value" "0" "$rc"
assert_eq "prior ZBUILD_CURRENT_STAGE restored after loop" \
    "caller-stage" "${ZBUILD_CURRENT_STAGE:-UNSET}"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
