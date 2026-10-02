#!/usr/bin/env bash
# tests/integration/cycle-member-unfinished-no-convergence-test.sh
#
# Issue #2032 — a stage that did not finish cannot end its cycle.
#
# When a cycle's exit_when predicate matches (converged==0) but any iteration
# member carries an unfinished disposition (timed_out, out_of_turns, interrupted),
# the cycle must NOT converge — a gate that matched on stale output from a
# timed-out stage is a FALSE convergence (§4/A).
#
# SPEC-1 [change]: when converged==0 and any member is unfinished, suppress:
#                  emit cycle.member_unfinished.suppressed_convergence, iterate.
# SPEC-2 [guard]:  when ALL members are disposition:complete and exit_when matches,
#                  converge normally; the new suppression block must not fire.
# SPEC-6 [change]: at max_iterations, suppression fires first (preventing the
#                  false-complete branch), then the #1261 exhaustion path fires —
#                  cycle.timeout_exhausted with reason=design_timeout_exhausted,
#                  term_rc=8, not rc=0 complete.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "cycle: unfinished member blocks exit_when convergence (#2032)"
setup_test_env "cycle-member-unfinished-no-convergence"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ZBUILD_STATE_DIR"

# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/template.sh"
# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"
# verdict_classify is used by the mock dispatch and must be sourced so the
# mock exercises the real classifier (mirrors runner.sh).
# shellcheck source=../../core/pipeline/verdict.sh
source "$REPO_ROOT/core/pipeline/verdict.sh"

# ─── design-verify cycle fixture (design → design-gate; NO test member) ──────
# max_iterations=3 for SPEC-1 (needs room to iterate after suppression) and SPEC-2.
DESIGN_TPL="$TEST_TEMP_DIR/design-verify-cycle.yaml"
cat > "$DESIGN_TPL" <<'YAML'
id: design-verify-unfinished
name: design-verify cycle for unfinished member suppression test
defaults:
  strategy: fanout
stages:
  - id: design-verify
    type: cycle
    stages: [design, design-gate]
    until:
      stage: design-gate
      field: verdict
      op: eq
      value: pass
    max_iterations: 3
    on_max: continue
stage_definitions:
  design:
    roles: [designer]
  design-gate:
    roles: [design_gate]
YAML

# max_iterations=2 so SPEC-6 can show suppression on iter-1, then exhaustion on iter-2.
DESIGN_TPL_2="$TEST_TEMP_DIR/design-verify-cycle-max2.yaml"
cat > "$DESIGN_TPL_2" <<'YAML'
id: design-verify-max2
name: design-verify cycle (max_iterations=2) for SPEC-6 boundary
defaults:
  strategy: fanout
stages:
  - id: design-verify
    type: cycle
    stages: [design, design-gate]
    until:
      stage: design-gate
      field: verdict
      op: eq
      value: pass
    max_iterations: 2
    on_max: continue
stage_definitions:
  design:
    roles: [designer]
  design-gate:
    roles: [design_gate]
YAML

# ─── plan-driven mock dispatch ─────────────────────────────────────────────────
# MOCK_PLAN format: "stage:token1,token2,...;stage2:...". Tokens per stage:
#   timed_out   → disposition=timed_out, verdict=incomplete  (unfinished)
#   out_of_turns → disposition=out_of_turns, verdict=incomplete (unfinished)
#   interrupted → disposition=interrupted, verdict=incomplete (unfinished)
#   pass        → disposition=complete, verdict=pass          (finished, gate-matching)
#   fail        → disposition=complete, verdict=fail          (finished, gate-failing)
# The last listed token repeats for any iter past the end of the list.
# No commit-producing member is in scope: neither stage has a manifest that
# declares capabilities.produces_commits=true, so the build-member suppression
# (cycle.build_unfinished.suppressed_convergence) never fires here.
cycle_dispatch_stage() {
    local stage="$1" iter="$2"
    local IFS_save="$IFS"
    local p sname vlist v="pass"
    IFS=';'
    # shellcheck disable=SC2206
    local -a parts=($MOCK_PLAN)
    IFS="$IFS_save"
    for p in "${parts[@]}"; do
        sname="${p%%:*}"; vlist="${p#*:}"
        if [[ "$sname" == "$stage" ]]; then
            IFS=','
            # shellcheck disable=SC2206
            local -a vs=($vlist)
            IFS="$IFS_save"
            local idx=$(( iter - 1 ))
            [[ $idx -ge ${#vs[@]} ]] && idx=$(( ${#vs[@]} - 1 ))
            v="${vs[$idx]}"
            break
        fi
    done
    _CYCLE_DISPATCH_STATUS="complete"
    _CYCLE_DISPATCH_REASON=""
    _CYCLE_DISPATCH_DISPOSITION="complete"
    _CYCLE_DISPATCH_DATA_KIND=""
    case "$v" in
        timed_out|out_of_turns|interrupted)
            _CYCLE_DISPATCH_VERDICT="$(verdict_classify incomplete 2>/dev/null || echo warn)"
            _CYCLE_DISPATCH_VERDICT_RAW="incomplete"
            _CYCLE_DISPATCH_DISPOSITION="$v"
            ;;
        pass)
            _CYCLE_DISPATCH_VERDICT="pass"
            _CYCLE_DISPATCH_VERDICT_RAW="pass"
            _CYCLE_DISPATCH_DISPOSITION="complete"
            ;;
        fail)
            _CYCLE_DISPATCH_VERDICT="fail"
            _CYCLE_DISPATCH_VERDICT_RAW="fail"
            _CYCLE_DISPATCH_DISPOSITION="complete"
            _CYCLE_DISPATCH_STATUS="failed"
            ;;
    esac
    return 0
}

_seed() {
    STATE_FILE="$ZBUILD_STATE_DIR/pipeline-state.json"
    : > "$ZBUILD_EVENTS_JSONL"
    rm -f "$STATE_FILE" "${STATE_FILE}.bak" "${STATE_FILE}.lock"
    rm -rf "$ZBUILD_STATE_DIR/artifacts"
    mkdir -p "$ZBUILD_STATE_DIR/artifacts"
    printf '{"schema_version":1,"status":"in_progress","stage_statuses":{}}' > "$STATE_FILE"
}

_run() {
    # $1 = template, $2 = cycle id, $3 = MOCK_PLAN
    _seed
    load_template "$1"
    MOCK_PLAN="$3"
    set +e
    cycle_orchestrator_run "$2" "$ZBUILD_STATE_DIR" "$STATE_FILE"
    RUN_RC=$?
    set -e
}

# ─── SPEC-2 [guard]: all complete dispositions + exit_when matches → convergence
print_test_section "[#2032/SPEC-2] guard: all complete dispositions — cycle converges normally"
_run "$DESIGN_TPL" "design-verify" "design:pass;design-gate:pass"
assert_eq "[#2032/SPEC-2] all complete dispositions + exit_when match → rc=0 (converged)" "0" "$RUN_RC"
assert_eq "[#2032/SPEC-2] converged on iter 1 (no suppression delay)" "1" "${_CYCLE_LAST_ITERATIONS:-}"
assert_eq "[#2032/SPEC-2] terminal reason is converged" "converged" "${_CYCLE_LAST_TERMINATED_REASON:-}"
if grep -q '"cycle.member_unfinished.suppressed_convergence"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_fail "[#2032/SPEC-2] suppression block must NOT fire when all members are complete" \
        "event was emitted"
else
    assert_pass "[#2032/SPEC-2] new suppression block did not fire (all members complete)"
fi

# ─── SPEC-1 [change]: unfinished member + exit_when matches → suppression, iterate
# Plan: iter 1 — design times out (timed_out), design-gate passes (exit_when would
# match). New suppression fires, cycle iterates. Iter 2 — design completes (pass),
# design-gate passes → convergence (rc=0). This verifies the suppression prevented
# the false convergence on iter 1 and the cycle ran to a real resting point.
print_test_section "[#2032/SPEC-1] unfinished member + exit_when match → suppression, not convergence"
_run "$DESIGN_TPL" "design-verify" "design:timed_out,pass;design-gate:pass,pass"
assert_contains "[#2032/SPEC-1] cycle.member_unfinished.suppressed_convergence emitted" \
    "$(cat "$ZBUILD_EVENTS_JSONL")" '"cycle.member_unfinished.suppressed_convergence"'
assert_eq "[#2032/SPEC-1] cycle iterated past the suppressed iter (ran >= 2 iters)" \
    "2" "${_CYCLE_LAST_ITERATIONS:-0}"
assert_eq "[#2032/SPEC-1] final rc=0 (converged after suppression, not stuck)" "0" "$RUN_RC"
# The build-member suppression (cycle.build_unfinished.suppressed_convergence) must
# NOT fire — there is no commit-producing member in this cycle; only the new block fires.
if grep -q '"cycle.build_unfinished.suppressed_convergence"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_fail "[#2032/SPEC-1] build-member suppression must not fire (no commit-producing member)" \
        "event was emitted"
else
    assert_pass "[#2032/SPEC-1] build-member suppression did not fire (correct — no build member)"
fi

# SPEC-1 also requires the unfinished dispositions to be recognised individually —
# timed_out was tested above; verify out_of_turns and interrupted also trigger.
print_test_section "[#2032/SPEC-1] out_of_turns and interrupted also trigger suppression"
_run "$DESIGN_TPL" "design-verify" "design:out_of_turns,pass;design-gate:pass,pass"
assert_contains "[#2032/SPEC-1] out_of_turns disposition triggers suppression" \
    "$(cat "$ZBUILD_EVENTS_JSONL")" '"cycle.member_unfinished.suppressed_convergence"'
assert_eq "[#2032/SPEC-1] out_of_turns case: cycle iterated (>= 2 iters)" \
    "2" "${_CYCLE_LAST_ITERATIONS:-0}"

_run "$DESIGN_TPL" "design-verify" "design:interrupted,pass;design-gate:pass,pass"
assert_contains "[#2032/SPEC-1] interrupted disposition triggers suppression" \
    "$(cat "$ZBUILD_EVENTS_JSONL")" '"cycle.member_unfinished.suppressed_convergence"'
assert_eq "[#2032/SPEC-1] interrupted case: cycle iterated (>= 2 iters)" \
    "2" "${_CYCLE_LAST_ITERATIONS:-0}"

# ─── SPEC-6 [change]: suppression at max_iterations → exhaustion, not false complete
# Iter 1 (max_iterations=2): design=timed_out, design-gate=pass → suppression fires.
# Iter 2 (last): design=timed_out, design-gate=pass → suppression fires again.
# Since iter==max_iterations: _cycle_check_max_iterations fires;
# _iter_did_not_finish==1 and _exh_tests_reported==0 → design_timeout_exhausted (rc=8).
# Without §4/A the false-complete branch at line 2728 would fire (rc=0) on iter 2.
print_test_section "[#2032/SPEC-6] suppression at max_iterations → exhaustion (rc=8), not false complete"
_run "$DESIGN_TPL_2" "design-verify" "design:timed_out;design-gate:pass"
assert_eq "[#2032/SPEC-6] rc=8 (exhaustion, not rc=0 false complete)" "8" "$RUN_RC"
assert_contains "[#2032/SPEC-6] suppression block fired (cycle.member_unfinished.suppressed_convergence)" \
    "$(cat "$ZBUILD_EVENTS_JSONL")" '"cycle.member_unfinished.suppressed_convergence"'
assert_contains "[#2032/SPEC-6] cycle.timeout_exhausted emitted (existing #1261 exhaustion path)" \
    "$(cat "$ZBUILD_EVENTS_JSONL")" '"cycle.timeout_exhausted"'
assert_eq "[#2032/SPEC-6] terminal reason is design_timeout_exhausted" \
    "design_timeout_exhausted" "${_CYCLE_LAST_TERMINATED_REASON:-}"
# Pin the reason carried in the event, not just that it was emitted.
assert_contains "[#2032/SPEC-6] cycle.timeout_exhausted carries reason=design_timeout_exhausted" \
    "$(cat "$ZBUILD_EVENTS_JSONL")" '"reason":"design_timeout_exhausted"'
if grep -q '"reason":"converged"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_fail "[#2032/SPEC-6] false complete (reason=converged) must NOT be emitted" \
        "converged event found"
else
    assert_pass "[#2032/SPEC-6] no false complete — converged event was not emitted"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
