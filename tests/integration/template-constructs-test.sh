#!/usr/bin/env bash
# Integration (#978): template CONSTRUCT-TYPE coverage.
#
# The pipeline engine orchestrates three template construct types — a LEAF
# stage, a PARALLEL group, and a CYCLE — plus any COMBINATION of them in one
# template. These tests prove the ENGINE handles each construct correctly,
# WITHOUT coupling to any shipped roster (simple.yaml / standard.yaml). That
# decoupling is the point: flipping the default template or retiring standard
# must not shatter these tests, because they assert on construct behavior via
# inline / standalone fixtures, never on a roster's stage list.
#
# Harness mirrors cycle-exit-when-success-test.sh: source template.sh +
# the orchestrators, load a fixture by direct file path, stub the dispatch
# hook, and assert on parsed structure + orchestrator events/state.
#
# Coverage boundary (reported to the team lead):
#   - LEAF     → PARSE level. There is no standalone leaf orchestrator; leaf
#                dispatch is reachable only via the full runner (needs an
#                installed/overlay template). We assert the parse structures a
#                leaf correctly (type=leaf, stage:<id> dispatch unit, no
#                cycle/parallel typing).
#   - CYCLE    → DISPATCH level via cycle_orchestrator_run + stub.
#   - PARALLEL → DISPATCH level via parallel_group_run + stub.
#   - COMBINED → PARSE (all three structured in one template) + DISPATCH (the
#                cycle AND the parallel group run within the combined template).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "template constructs — leaf / parallel / cycle / combined (#978)"
setup_test_env "template-constructs"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ZBUILD_STATE_DIR"

# shellcheck source=../../core/pipeline/cycle-orchestrator.sh
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"
# shellcheck source=../../core/pipeline/parallel-orchestrator.sh
source "$REPO_ROOT/core/pipeline/parallel-orchestrator.sh"
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"

FIXT="$REPO_ROOT/tests/fixtures/templates"
STATE_FILE="$ZBUILD_STATE_DIR/pipeline-state.json"

_seed() {
    : > "$ZBUILD_EVENTS_JSONL"
    rm -f "$STATE_FILE" "${STATE_FILE}.bak" "${STATE_FILE}.lock"
    jq -n '{schema_version:1, stage_statuses:{}, updated_at:"seed"}' > "$STATE_FILE"
}

# Reset the template module arrays before each load so a prior fixture's
# structure never leaks into the next assertion.
_reset_tpl() {
    _TPL_STAGES=()
    _TPL_CYCLES=()
    _TPL_PARALLEL_GROUPS=()
}

# Stubs mirror the runner-registered dispatch hooks. The cycle stub sets
# _CYCLE_DISPATCH_*; the parallel stub sets _PARALLEL_DISPATCH_*. Both return 0
# with a converging/passing verdict so the orchestrators run their happy path.
cycle_dispatch_stage() {
    local stage="$1"
    case "$stage" in
        test) _CYCLE_DISPATCH_VERDICT="pass" ;;
        *)    _CYCLE_DISPATCH_VERDICT="pass" ;;
    esac
    _CYCLE_DISPATCH_STATUS="complete"
    return 0
}
parallel_dispatch_stage() {
    _PARALLEL_DISPATCH_VERDICT="ok"
    _PARALLEL_DISPATCH_STATUS="complete"
    return 0
}

# ─── T1 [leaf] — PARSE level ─────────────────────────────────────────────────
# Reuse the existing leaf-only fixture (runner-state-dir-minimal.yaml: two leaf
# stages, no cycle, no parallel). Assert the parser structures leaves as leaves.
_seed
_reset_tpl
set +e; load_template "$FIXT/runner-state-dir-minimal.yaml"; rc=$?; set -e
assert_eq "T1a [leaf] template loads rc=0" "0" "$rc"
assert_eq "T1b [leaf] no cycles parsed" "0" "${#_TPL_CYCLES[@]}"
assert_eq "T1c [leaf] no parallel groups parsed" "0" "${#_TPL_PARALLEL_GROUPS[@]}"
assert_eq "T1d [leaf] intake stage type is leaf" "leaf" "${_TPL_STAGE_TYPE_intake:-MISSING}"
assert_eq "T1e [leaf] build stage type is leaf" "leaf" "${_TPL_STAGE_TYPE_build:-MISSING}"
# Dispatch units are plain stage:<id> — no cycle:/parallel: unit.
assert_eq "T1f [leaf] dispatch units are all stage:<id>" "stage:intake stage:build" "${_TPL_DISPATCH_UNITS[*]}"

# ─── T2 [cycle] — DISPATCH level ─────────────────────────────────────────────
# Load the cycle-only fixture and run it through cycle_orchestrator_run. Assert
# it iterates and CONVERGES via its until/exit predicate.
_seed
_reset_tpl
set +e; load_template "$FIXT/cycle-converges-iter2.yaml"; rc=$?; set -e
assert_eq "T2a [cycle] template loads rc=0" "0" "$rc"
assert_eq "T2b [cycle] one cycle parsed (build-test)" "build-test" "${_TPL_CYCLES[*]}"
assert_eq "T2c [cycle] build-test stage type is cycle" "cycle" "${_TPL_STAGE_TYPE_build_test:-MISSING}"

set +e; cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc=$?; set -e
assert_eq "T2d [cycle] cycle_orchestrator_run converged rc=0" "0" "$rc"
assert_eq "T2e [cycle] terminated_reason=converged" "converged" "${_CYCLE_LAST_TERMINATED_REASON:-MISSING}"
iter_complete=$(jq -c 'select(.type=="cycle.iteration.complete" and .data.cycle_id=="build-test")' "$ZBUILD_EVENTS_JSONL" | wc -l | tr -d ' ')
assert_gt "T2f [cycle] cycle.iteration.complete fired for build-test" "$iter_complete" "0"
cyc_complete=$(jq -c 'select(.type=="cycle.complete" and .data.cycle_id=="build-test")' "$ZBUILD_EVENTS_JSONL" | wc -l | tr -d ' ')
assert_eq "T2g [cycle] cycle.complete fired once for build-test" "1" "$cyc_complete"

# ─── T3 [parallel] — DISPATCH level ──────────────────────────────────────────
# Load the parallel-only fixture, assert the parser structures the group + its
# members + aggregate mode, then dispatch it via parallel_group_run.
_seed
_reset_tpl
set +e; load_template "$FIXT/parallel-only.yaml"; rc=$?; set -e
assert_eq "T3a [parallel] template loads rc=0" "0" "$rc"
assert_eq "T3b [parallel] one parallel group parsed (lens_group)" "lens_group" "${_TPL_PARALLEL_GROUPS[*]}"
assert_eq "T3c [parallel] lens_group stage type is parallel" "parallel" "${_TPL_STAGE_TYPE_lens_group:-MISSING}"
assert_eq "T3d [parallel] group members parsed in declaration order" \
    "lens-security,lens-performance,lens-red-team" "${_TPL_PARALLEL_FLOW_lens_group:-MISSING}"
assert_eq "T3e [parallel] aggregate mode is advisory" "advisory" "${_TPL_PARALLEL_AGGREGATE_lens_group:-MISSING}"
assert_eq "T3f [parallel] on_member_error is continue" "continue" "${_TPL_PARALLEL_ON_ERR_lens_group:-MISSING}"
assert_eq "T3g [parallel] dispatch unit is parallel:lens_group" "parallel:lens_group" "${_TPL_DISPATCH_UNITS[*]}"

set +e; parallel_group_run "lens_group" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc=$?; set -e
assert_eq "T3h [parallel] parallel_group_run rc=0 (advisory group never blocks)" "0" "$rc"
assert_eq "T3i [parallel] zero member failures" "0" "${_PARALLEL_LAST_FAILURE_COUNT}"
# All THREE members ran — one dispatch.complete per member.
members_ran=$(jq -c 'select(.type=="parallel.member.dispatch.complete" and .data.group_id=="lens_group")' "$ZBUILD_EVENTS_JSONL" | wc -l | tr -d ' ')
assert_eq "T3j [parallel] all 3 members dispatched" "3" "$members_ran"
# Aggregate blob carries every member's verdict.
blob_members=$(jq -r '[.["lens-security","lens-performance","lens-red-team"] | .verdict] | length' <<< "$_PARALLEL_LAST_VERDICTS_BLOB")
assert_eq "T3k [parallel] aggregate blob has all 3 member verdicts" "3" "$blob_members"
grp_complete=$(jq -c 'select(.type=="parallel.group.complete" and .data.group_id=="lens_group" and .data.status=="complete")' "$ZBUILD_EVENTS_JSONL" | wc -l | tr -d ' ')
assert_eq "T3l [parallel] parallel.group.complete status=complete" "1" "$grp_complete"

# ─── T4 [combined] — PARSE (all three) + DISPATCH (cycle + parallel) ─────────
# ONE template with a leaf, a cycle, AND a parallel group. Prove the parser
# structures all three in a single load, then dispatch the cycle AND the
# parallel group to show both run within the combined template.
_seed
_reset_tpl
set +e; load_template "$FIXT/all-constructs.yaml"; rc=$?; set -e
assert_eq "T4a [combined] template loads rc=0" "0" "$rc"
# All three dispatch units present, in flow order: leaf, cycle, parallel.
assert_eq "T4b [combined] dispatch units = leaf + cycle + parallel in flow order" \
    "stage:intake cycle:refine_cycle parallel:lens_group" "${_TPL_DISPATCH_UNITS[*]}"
assert_eq "T4c [combined] leaf typed leaf" "leaf" "${_TPL_STAGE_TYPE_intake:-MISSING}"
assert_eq "T4d [combined] cycle typed cycle" "cycle" "${_TPL_STAGE_TYPE_refine_cycle:-MISSING}"
assert_eq "T4e [combined] parallel typed parallel" "parallel" "${_TPL_STAGE_TYPE_lens_group:-MISSING}"
assert_eq "T4f [combined] cycle members structured" "build,test" "${_TPL_CYCLE_FLOW_refine_cycle:-MISSING}"
assert_eq "T4g [combined] parallel members structured" \
    "lens-security,lens-performance" "${_TPL_PARALLEL_FLOW_lens_group:-MISSING}"
# The flat stage view expands cycle + parallel members alongside the leaf.
assert_eq "T4h [combined] flat stage view expands all members" \
    "intake build test lens-security lens-performance" "${_TPL_STAGES[*]}"

# Dispatch the CYCLE within the combined template → converges.
set +e; cycle_orchestrator_run "refine_cycle" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc=$?; set -e
assert_eq "T4i [combined] cycle member dispatches + converges rc=0" "0" "$rc"
assert_eq "T4j [combined] cycle terminated_reason=converged" "converged" "${_CYCLE_LAST_TERMINATED_REASON:-MISSING}"

# Dispatch the PARALLEL group within the same combined template → all members run.
set +e; parallel_group_run "lens_group" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc=$?; set -e
assert_eq "T4k [combined] parallel group dispatches rc=0" "0" "$rc"
combined_members_ran=$(jq -c 'select(.type=="parallel.member.dispatch.complete" and .data.group_id=="lens_group")' "$ZBUILD_EVENTS_JSONL" | wc -l | tr -d ' ')
assert_eq "T4l [combined] both parallel members dispatched" "2" "$combined_members_ran"

print_test_results
