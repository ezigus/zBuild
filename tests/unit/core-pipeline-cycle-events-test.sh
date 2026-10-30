#!/usr/bin/env bash
# Tests: cycle-* event registrations in config/event-schema.json (ADR-021, #512)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "cycle events — schema registrations (ADR-021)"
setup_test_env "cycle-events"

SCHEMA="$REPO_ROOT/config/event-schema.json"

# All cycle events that MUST be registered per ADR-021 §Event-schema additions
required_events=(
    "cycle.start"
    "cycle.complete"
    "cycle.plateau"
    "cycle.divergence"
    "cycle.iteration.complete"
    "cycle.aborted"
    "cycle.config.invalid"
    "cycle.iteration.verdict_missing"
    "cycle.history.lost"
    "cycle.metric.invalid"
    "cycle.plateau.skipped"
    "cycle.iter.stale_artifact"
)

for ev in "${required_events[@]}"; do
    if jq -e --arg t "$ev" '.known_types | index($t)' "$SCHEMA" >/dev/null 2>&1; then
        assert_pass "event registered: $ev"
    else
        assert_fail "event registered: $ev" "missing from known_types"
    fi
done

# SPEC-3: the cycle.feedback.* events are retired with template feedback wires
# (ADR-055 §4, amended 2026-10-12) and are no longer registered.
for ev in cycle.feedback.missing cycle.feedback.absent; do
    if jq -e --arg t "$ev" '.known_types | index($t)' "$SCHEMA" >/dev/null 2>&1; then
        assert_fail "[SPEC-3] retired $ev is not registered" "still in known_types"
    else
        assert_pass "[SPEC-3] retired $ev is not registered"
    fi
done

print_test_section "SPEC-7 / SPEC-8 — evaluator op guards"
# Source cycle-orchestrator to get the evaluator functions.
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ZBUILD_STATE_DIR"
# shellcheck source=../../core/pipeline/cycle-orchestrator.sh
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"

# ── [#1760/SPEC-7] gt/gte/lt/lte with non-numeric operand emits error ──────────
# Must NOT silently evaluate to false; must emit a diagnostic and return 1.
# Tests FAIL before #1760 (numeric ops not yet present in evaluators).

# Helper: call each evaluator with a non-numeric value for a numeric op,
# capture stderr, verify rc=1 AND an error message appears.

# --- _cycle_check_until (single-condition) ---
_CYCLE_EXIT_COMBINATOR=""
_CYCLE_UNTIL_STAGE="s1"; _CYCLE_UNTIL_FIELD="verdict"

for _spec7_op in gt gte lt lte; do
    _CYCLE_UNTIL_OP="$_spec7_op"; _CYCLE_UNTIL_VALUE="5"
    blob='{"s1":{"verdict":"notanumber","status":"complete"}}'
    set +e
    _spec7_err=$(2>&1 _cycle_check_until "$blob"); _spec7_rc=$?
    set -e
    assert_eq "[#1760/SPEC-7] _cycle_check_until: ${_spec7_op} non-numeric → rc=1 (error, not silent false)" \
        "1" "$_spec7_rc"
    if [[ -n "$_spec7_err" ]]; then
        assert_pass "[#1760/SPEC-7] _cycle_check_until: ${_spec7_op} non-numeric emits error message"
    else
        assert_fail "[#1760/SPEC-7] _cycle_check_until: ${_spec7_op} non-numeric emits error message" \
            "no output on stderr/stdout for op=${_spec7_op} value=notanumber"
    fi
done

# --- _cycle_eval_one_condition (multi-condition) ---
# Set template vars for a single multi-condition entry using each numeric op,
# then call _cycle_load_template and _cycle_check_until (which calls _cycle_eval_one_condition).
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"

for _spec7_op in gt gte lt lte; do
    _TPL_CYCLE_EXIT_COMBINATOR_spec7_cycle="all"
    _TPL_CYCLE_EXIT_COUNT_spec7_cycle="1"
    _TPL_CYCLE_EXIT_1_STAGE_spec7_cycle="s1"
    _TPL_CYCLE_EXIT_1_FIELD_spec7_cycle="verdict"
    _TPL_CYCLE_EXIT_1_OP_spec7_cycle="$_spec7_op"
    _TPL_CYCLE_EXIT_1_VALUE_spec7_cycle="5"
    _TPL_CYCLE_STAGES_spec7_cycle="s1"; _TPL_CYCLE_MAX_spec7_cycle=2
    _CYCLE_TRAP_CYCLE_ID="spec7_cycle"
    _CYCLE_TRAP_ITER=1
    # Protected so a missing _cycle_load_template (pre-#1760) does not stop the file.
    set +e; _cycle_load_template "spec7_cycle"; _s7_mc_rc=$?; set -e
    blob='{"s1":{"verdict":"notanumber","status":"complete"}}'
    set +e
    _spec7_err=$(2>&1 _cycle_check_until "$blob"); _spec7_rc=$?
    set -e
    if [[ "$_s7_mc_rc" -ne 0 ]]; then
        assert_fail "[#1760/SPEC-7] _cycle_eval_one_condition: ${_spec7_op} non-numeric → rc=1" \
            "_cycle_load_template failed (pre-#1760: function may not exist, rc=$_s7_mc_rc)"
        assert_fail "[#1760/SPEC-7] _cycle_eval_one_condition: ${_spec7_op} non-numeric emits error" \
            "_cycle_load_template failed (pre-#1760: function may not exist, rc=$_s7_mc_rc)"
    else
        assert_eq "[#1760/SPEC-7] _cycle_eval_one_condition: ${_spec7_op} non-numeric → rc=1" \
            "1" "$_spec7_rc"
        if [[ -n "$_spec7_err" ]]; then
            assert_pass "[#1760/SPEC-7] _cycle_eval_one_condition: ${_spec7_op} non-numeric emits error"
        else
            assert_fail "[#1760/SPEC-7] _cycle_eval_one_condition: ${_spec7_op} non-numeric emits error" \
                "no output for op=${_spec7_op} value=notanumber"
        fi
    fi
done

# --- _cycle_check_abort_when ---
for _spec7_op in gt gte lt lte; do
    _TPL_CYCLE_ABORT_WHEN_STAGE_spec7_aw="s1"
    _TPL_CYCLE_ABORT_WHEN_FIELD_spec7_aw="verdict"
    _TPL_CYCLE_ABORT_WHEN_OP_spec7_aw="$_spec7_op"
    _TPL_CYCLE_ABORT_WHEN_VALUE_spec7_aw="5"
    _TPL_CYCLE_UNTIL_STAGE_spec7_aw="s1"
    _TPL_CYCLE_UNTIL_FIELD_spec7_aw="verdict"
    _TPL_CYCLE_UNTIL_OP_spec7_aw="eq"
    _TPL_CYCLE_UNTIL_VALUE_spec7_aw="pass"
    _TPL_CYCLE_STAGES_spec7_aw="s1"
    _TPL_CYCLE_STAGES_spec7_aw="s1"; _TPL_CYCLE_MAX_spec7_aw=2
    _CYCLE_TRAP_CYCLE_ID="spec7_aw"
    _CYCLE_TRAP_ITER=1
    # Protected so a missing _cycle_load_template (pre-#1760) does not stop the file.
    set +e; _cycle_load_template "spec7_aw"; _s7_aw_rc=$?; set -e
    blob='{"s1":{"verdict":"notanumber","status":"complete"}}'
    set +e
    _spec7_err=$(2>&1 _cycle_check_abort_when "$blob"); _spec7_rc=$?
    set -e
    if [[ "$_s7_aw_rc" -ne 0 ]]; then
        assert_fail "[#1760/SPEC-7] _cycle_check_abort_when: ${_spec7_op} non-numeric → rc=1" \
            "_cycle_load_template failed (pre-#1760: function may not exist, rc=$_s7_aw_rc)"
        assert_fail "[#1760/SPEC-7] _cycle_check_abort_when: ${_spec7_op} non-numeric emits error" \
            "_cycle_load_template failed (pre-#1760: function may not exist, rc=$_s7_aw_rc)"
    else
        assert_eq "[#1760/SPEC-7] _cycle_check_abort_when: ${_spec7_op} non-numeric → rc=0 (the safety switch fails closed)" \
            "0" "$_spec7_rc"
        if [[ -n "$_spec7_err" ]]; then
            assert_pass "[#1760/SPEC-7] _cycle_check_abort_when: ${_spec7_op} non-numeric emits error"
        else
            assert_fail "[#1760/SPEC-7] _cycle_check_abort_when: ${_spec7_op} non-numeric emits error" \
                "no output for op=${_spec7_op} value=notanumber"
        fi
    fi
done

# ── [#1760/SPEC-8] *) branch returns 1 on unrecognized op ──────────────────────
# Each evaluator's *) / default branch must return 1 (not silently skip).
# Tests FAIL before #1760 (no *) branch in any evaluator).

# _cycle_check_until: unrecognized op
_CYCLE_EXIT_COMBINATOR=""
_CYCLE_UNTIL_STAGE="s1"; _CYCLE_UNTIL_FIELD="verdict"
_CYCLE_UNTIL_OP="bogus_op"; _CYCLE_UNTIL_VALUE="pass"
blob='{"s1":{"verdict":"pass","status":"complete"}}'
set +e; _cycle_check_until "$blob"; rc=$?; set -e
assert_eq "[#1760/SPEC-8] _cycle_check_until: bogus_op → rc=1 (not silent skip)" "1" "$rc"

# _cycle_eval_one_condition: unrecognized op (via multi-condition mode)
_TPL_CYCLE_EXIT_COMBINATOR_spec8_cycle="all"
_TPL_CYCLE_EXIT_COUNT_spec8_cycle="1"
_TPL_CYCLE_EXIT_1_STAGE_spec8_cycle="s1"
_TPL_CYCLE_EXIT_1_FIELD_spec8_cycle="verdict"
_TPL_CYCLE_EXIT_1_OP_spec8_cycle="eq"
_TPL_CYCLE_EXIT_1_VALUE_spec8_cycle="pass"
_TPL_CYCLE_STAGES_spec8_cycle="s1"; _TPL_CYCLE_MAX_spec8_cycle=2
_CYCLE_TRAP_CYCLE_ID="spec8_cycle"
_CYCLE_TRAP_ITER=1
# Protected so a missing _cycle_load_template (pre-#1760) does not stop the file.
set +e; _cycle_load_template "spec8_cycle"; _s8_mc_rc=$?; set -e
# #1760 review: the loader refuses bogus_op itself; here one reaches evaluation anyway.
_CYCLE_EXIT_CONDITIONS=("s1|verdict|bogus_op|pass")
blob='{"s1":{"verdict":"pass","status":"complete"}}'
set +e; _cycle_check_until "$blob"; rc=$?; set -e
if [[ "$_s8_mc_rc" -ne 0 ]]; then
    assert_fail "[#1760/SPEC-8] _cycle_eval_one_condition: bogus_op → rc=1 (not silent skip)" \
        "_cycle_load_template failed (pre-#1760: function may not exist, rc=$_s8_mc_rc)"
else
    assert_eq "[#1760/SPEC-8] _cycle_eval_one_condition: bogus_op → rc=1 (not silent skip)" "1" "$rc"
fi

# _cycle_check_abort_when: unrecognized op
_TPL_CYCLE_ABORT_WHEN_STAGE_spec8_aw="s1"
_TPL_CYCLE_ABORT_WHEN_FIELD_spec8_aw="verdict"
_TPL_CYCLE_ABORT_WHEN_OP_spec8_aw="bogus_op"
_TPL_CYCLE_ABORT_WHEN_VALUE_spec8_aw="pass"
_TPL_CYCLE_UNTIL_STAGE_spec8_aw="s1"
_TPL_CYCLE_UNTIL_FIELD_spec8_aw="verdict"
_TPL_CYCLE_UNTIL_OP_spec8_aw="eq"
_TPL_CYCLE_UNTIL_VALUE_spec8_aw="pass"
_TPL_CYCLE_STAGES_spec8_aw="s1"
_TPL_CYCLE_STAGES_spec8_aw="s1"; _TPL_CYCLE_MAX_spec8_aw=2
_CYCLE_TRAP_CYCLE_ID="spec8_aw"
_CYCLE_TRAP_ITER=1
# Protected so a missing _cycle_load_template (pre-#1760) does not stop the file.
set +e; _cycle_load_template "spec8_aw"; _s8_aw_rc=$?; set -e
blob='{"s1":{"verdict":"pass","status":"complete"}}'
set +e; _cycle_check_abort_when "$blob"; rc=$?; set -e
if [[ "$_s8_aw_rc" -ne 0 ]]; then
    assert_fail "[#1760/SPEC-8] _cycle_check_abort_when: bogus_op → rc=1 (not silent skip)" \
        "_cycle_load_template failed (pre-#1760: function may not exist, rc=$_s8_aw_rc)"
else
    assert_eq "[#1760/SPEC-8] _cycle_check_abort_when: bogus_op → rc=0 (the safety switch fails closed)" "0" "$rc"
fi

print_test_results
