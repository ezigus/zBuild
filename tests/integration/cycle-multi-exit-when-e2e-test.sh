#!/usr/bin/env bash
# Integration: multi-condition exit_when (all/any) driven END-TO-END through the
# real cycle orchestrator (#1297, follow-on to #1284 / ADR-047).
#
# #1284 shipped the all/any combinator + unit coverage that pokes
# _cycle_check_until with hand-built verdict blobs (cycle-multi-exit-when-test.sh).
# What was MISSING is a live caller: proof that a cycle whose `exit_when` is a
# multi-condition `all:`/`any:` actually converges (or keeps iterating) when
# DISPATCHED through cycle_orchestrator_run — the same path the runner uses.
#
# This exercises the mechanism on a fixture cycle (tests/fixtures/templates/
# cycle-multi-exit-when-e2e.yaml, shaped like a build_test_cycle gate set) so the
# production simple.yaml default cycle is untouched. A mock cycle_dispatch_stage
# publishes per-stage verdicts (optionally iteration-dependent); the orchestrator
# accumulates them into its predicate-evaluation blob and evaluates the
# multi-condition exit_when for real.
#
# SPEC-1: all: converges ONLY when every condition passes (all gates pass → rc=0).
# SPEC-2: all: a single failing condition keeps the cycle iterating, then
#         converges once the offending gate is fixed on a later iteration.
# SPEC-3: all: a persistently-failing condition NEVER converges (exhausts to
#         max_iterations; on_max=continue → by-severity rc=2, never a false pass).
# SPEC-4: any: converges when at least one condition passes.
# SPEC-5: any: converges only via a passing condition — all failing exhausts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "cycle — multi-condition exit_when end-to-end dispatch (#1297)"
setup_test_env "cycle-multi-exit-when-e2e"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ZBUILD_STATE_DIR"

# shellcheck source=../../core/pipeline/cycle-orchestrator.sh
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"

FIXT="$REPO_ROOT/tests/fixtures/templates"
STATE_FILE="$ZBUILD_STATE_DIR/pipeline-state.json"

# Fresh event log + seed state for one orchestrator run. Returns the fixture cycle
# id (both e2e fixtures name their cycle `build-test-cycle`).
_reset_run() {
    : > "$ZBUILD_EVENTS_JSONL"
    rm -f "$STATE_FILE" "${STATE_FILE}.bak" "${STATE_FILE}.lock"
    jq -n '{schema_version:1, stage_statuses:{}, updated_at:"seed"}' > "$STATE_FILE"
    _TPL_STAGES=()
    _TPL_CYCLES=()
}

# ── SPEC-1: all: converges only when EVERY condition passes ───────────────────
# Every gate (shape-floor, acceptance-gate, secret-scan, test) reports pass →
# the all: combinator is satisfied on iteration 1.
cycle_dispatch_stage() {
    _CYCLE_DISPATCH_VERDICT="pass"
    _CYCLE_DISPATCH_VERDICT_RAW="pass"
    _CYCLE_DISPATCH_STATUS="complete"
    return 0
}
_reset_run
load_template "$FIXT/cycle-multi-exit-when-e2e.yaml"
set +e
cycle_orchestrator_run "build-test-cycle" "$ZBUILD_STATE_DIR" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "SPEC-1: all — every gate pass → rc=0 (converged)" "0" "$rc"
assert_eq "SPEC-1: all — terminated reason=converged" "converged" "${_CYCLE_LAST_TERMINATED_REASON:-MISSING}"
assert_eq "SPEC-1: all — converged on first iteration" "1" "${_CYCLE_LAST_ITERATIONS:-0}"
complete_ev=$(jq -c 'select(.type=="cycle.complete" and .data.cycle_id=="build-test-cycle" and .data.reason=="converged")' \
    "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "SPEC-1: all — cycle.complete reason=converged emitted end-to-end" "1" "$complete_ev"

# ── SPEC-2: all: one failing condition keeps iterating, then converges ────────
# secret-scan fails on iteration 1 (a real gate on the exit_when path) then
# passes from iteration 2 on. all: must NOT converge on iter 1 (one condition
# unmet) but converge on iter 2 once the gate is fixed.
cycle_dispatch_stage() {
    local stage="$1" iter="$2"
    if [[ "$stage" == "secret-scan" && "$iter" -lt 2 ]]; then
        _CYCLE_DISPATCH_VERDICT="fail"
    else
        _CYCLE_DISPATCH_VERDICT="pass"
    fi
    _CYCLE_DISPATCH_VERDICT_RAW="$_CYCLE_DISPATCH_VERDICT"
    _CYCLE_DISPATCH_STATUS="complete"
    return 0
}
_reset_run
load_template "$FIXT/cycle-multi-exit-when-e2e.yaml"
set +e
cycle_orchestrator_run "build-test-cycle" "$ZBUILD_STATE_DIR" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "SPEC-2: all — fixed-on-iter-2 → rc=0 (converged)" "0" "$rc"
assert_eq "SPEC-2: all — terminated reason=converged" "converged" "${_CYCLE_LAST_TERMINATED_REASON:-MISSING}"
assert_eq "SPEC-2: all — iterated once before converging (converged on iter 2)" "2" "${_CYCLE_LAST_ITERATIONS:-0}"

# ── SPEC-3: all: a persistently-failing condition NEVER converges ─────────────
# acceptance-gate always fails; every other gate passes. all: can never be
# satisfied → the cycle exhausts max_iterations (5). on_max=continue → the
# by-severity cascade returns rc=2 (passing-but-unconverged → route to review),
# never a false convergence.
cycle_dispatch_stage() {
    local stage="$1"
    if [[ "$stage" == "acceptance-gate" ]]; then
        _CYCLE_DISPATCH_VERDICT="fail"
    else
        _CYCLE_DISPATCH_VERDICT="pass"
    fi
    _CYCLE_DISPATCH_VERDICT_RAW="$_CYCLE_DISPATCH_VERDICT"
    _CYCLE_DISPATCH_STATUS="complete"
    return 0
}
_reset_run
load_template "$FIXT/cycle-multi-exit-when-e2e.yaml"
set +e
cycle_orchestrator_run "build-test-cycle" "$ZBUILD_STATE_DIR" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "SPEC-3: all — one gate always fails → rc=2 (unconverged, by-severity)" "2" "$rc"
assert_eq "SPEC-3: all — terminated reason=max_iterations (no false convergence)" "max_iterations" "${_CYCLE_LAST_TERMINATED_REASON:-MISSING}"
assert_eq "SPEC-3: all — ran all 5 iterations" "5" "${_CYCLE_LAST_ITERATIONS:-0}"
converged_ev=$(jq -c 'select(.type=="cycle.complete" and .data.cycle_id=="build-test-cycle" and .data.reason=="converged")' \
    "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "SPEC-3: all — NO cycle.complete reason=converged emitted" "0" "$converged_ev"

# ── SPEC-4: any: converges when at least one condition passes ─────────────────
# gate-a always fails, gate-b always passes. any: is satisfied by gate-b on
# iteration 1. Reuses the #1284 fixture (already dispatch-shaped) for the any
# combinator.
cycle_dispatch_stage() {
    local stage="$1"
    if [[ "$stage" == "gate-a" ]]; then
        _CYCLE_DISPATCH_VERDICT="fail"
    else
        _CYCLE_DISPATCH_VERDICT="pass"
    fi
    _CYCLE_DISPATCH_VERDICT_RAW="$_CYCLE_DISPATCH_VERDICT"
    _CYCLE_DISPATCH_STATUS="complete"
    return 0
}
_reset_run
load_template "$FIXT/cycle-multi-exit-when-any.yaml"
set +e
cycle_orchestrator_run "build-test-cycle" "$ZBUILD_STATE_DIR" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "SPEC-4: any — one gate passes → rc=0 (converged)" "0" "$rc"
assert_eq "SPEC-4: any — terminated reason=converged" "converged" "${_CYCLE_LAST_TERMINATED_REASON:-MISSING}"
assert_eq "SPEC-4: any — converged on first iteration" "1" "${_CYCLE_LAST_ITERATIONS:-0}"

# ── SPEC-5: any: all conditions failing → never converges (exhausts) ──────────
cycle_dispatch_stage() {
    _CYCLE_DISPATCH_VERDICT="fail"
    _CYCLE_DISPATCH_VERDICT_RAW="fail"
    _CYCLE_DISPATCH_STATUS="complete"
    return 0
}
_reset_run
load_template "$FIXT/cycle-multi-exit-when-any.yaml"
set +e
cycle_orchestrator_run "build-test-cycle" "$ZBUILD_STATE_DIR" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "SPEC-5: any — no gate passes → rc=2 (unconverged, by-severity)" "2" "$rc"
assert_eq "SPEC-5: any — terminated reason=max_iterations (no false convergence)" "max_iterations" "${_CYCLE_LAST_TERMINATED_REASON:-MISSING}"
assert_eq "SPEC-5: any — ran all 5 iterations" "5" "${_CYCLE_LAST_ITERATIONS:-0}"

print_test_results
