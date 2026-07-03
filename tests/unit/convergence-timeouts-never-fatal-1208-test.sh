#!/usr/bin/env bash
# Tests: issue #1208 — "Timeouts never fatal; the only fatal is the cycle running
# out of tries without a clean, passing convergence."
#
# Engine-level, REPO-AGNOSTIC (SPEC-8): the whole chain keys ONLY on repo-neutral
# signals — the build member's LOOP_COMPLETE-vs-timeout resting-point verdict
# (`did_not_finish` for router_timeout/error, `empty_diff` for a clean stall),
# the generic gate/test verdict, and `failure_count`. No plugin id / language /
# path / test-format appears in the exercised path (the cycle uses generic
# `build`/`test` member ids and drives verdicts through the dispatch contract,
# exactly as any target repo — iOS/Swift, Go, Python — would).
#
# SPECs:
#   1 timeout-never-fatal          — build times out every iter (tests green) →
#                                     cycle NEVER halts (no rc=4/5/8), runs all
#                                     iters, ends unconverged→review (rc=2). No
#                                     cycle.member.timeout_abandoned.
#   2 no-false-converge-on-unfinished — build did_not_finish + gate/test=pass →
#                                     iteration does NOT converge; suppression
#                                     event cycle.build_unfinished.suppressed_convergence.
#   3 re-run-nothing-to-do-passes  — clean empty_diff (LOOP_COMPLETE) + tests
#                                     green → converge on iter 1 (rc=0), NOT a stall.
#   4 only-fatal-at-exhaustion     — needs iters 1..3 red then iter 4 green →
#                                     converges at iter 4 (NOT abandoned early).
#   5 by-severity-at-exhaustion    — exhausted + tests failing → rc=8 (failed halt);
#                                     exhausted + tests passing-but-unclean → rc=2.
#   6 retry>2                      — a 4-iteration convergence is not abandoned
#                                     by the old G2 2x rule (== SPEC-4 evidence).
#   9 build-never-short-circuits   — clean stall (empty_diff, LOOP_COMPLETE) +
#                                     tests green → converge; timeout + tests
#                                     green → do NOT converge (mid-flight) → iterate.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "convergence: timeouts never fatal; only fatal = exhaustion (#1208)"
setup_test_env "convergence-timeouts-never-fatal-1208"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ZBUILD_STATE_DIR"

# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/template.sh"
# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"

FIXT="$REPO_ROOT/tests/fixtures/templates"

# Plan-driven mock dispatch. Format: "stage:v1,v2,...;stage2:...". A stage
# missing from the plan defaults to pass. Verdicts:
#   pass       — clean pass (build: LOOP_COMPLETE with changes)
#   fail       — verdict=fail
#   dnf        — build did_not_finish (router_timeout/error surfaced by Change 2)
#   empty_diff — build clean empty diff via LOOP_COMPLETE (nothing-to-do)
# The mock writes the real member artifacts so the orchestrator's failure_count
# override (test-results.json .failed) and the mid-flight suppression
# (build-summary.json .verdict) read honest data.
cycle_dispatch_stage() {
    local stage="$1" iter="$2" state_file="$3"
    local sd; sd="$(dirname "$state_file")"
    local art="$sd/artifacts"; mkdir -p "$art"
    local IFS_save="$IFS"; IFS=';'
    # shellcheck disable=SC2206
    local -a parts=($MOCK_PLAN); IFS="$IFS_save"
    local p sname vlist v="pass"
    for p in "${parts[@]}"; do
        sname="${p%%:*}"; vlist="${p#*:}"
        if [[ "$sname" == "$stage" ]]; then
            IFS=','; # shellcheck disable=SC2206
            local -a vs=($vlist); IFS="$IFS_save"
            local idx=$(( iter - 1 ))
            [[ $idx -ge ${#vs[@]} ]] && idx=$(( ${#vs[@]} - 1 ))
            v="${vs[$idx]}"
            break
        fi
    done
    _CYCLE_DISPATCH_STATUS="complete"
    _CYCLE_DISPATCH_REASON=""
    case "$stage" in
        build)
            local bv="pass" tr="done_sentinel" fc="[{\"path\":\"a\"}]"
            case "$v" in
                dnf)        bv="did_not_finish"; tr="router_timeout"; fc="[]" ;;
                empty_diff) bv="empty_diff"; tr="done_sentinel"; fc="[]" ;;
                fail)       bv="fail"; tr="done_sentinel" ;;
                *)          bv="pass" ;;
            esac
            printf '{"schema_version":4,"verdict":"%s","terminated_reason":"%s","files_changed":%s}' \
                "$bv" "$tr" "$fc" > "$art/build-summary.json"
            _CYCLE_DISPATCH_VERDICT="$(verdict_classify "$bv" 2>/dev/null || echo warn)"
            _CYCLE_DISPATCH_VERDICT_RAW="$bv"
            ;;
        test)
            local tv="pass" nf=0
            [[ "$v" == "fail" ]] && { tv="fail"; nf=3; }
            printf '{"schema_version":2,"verdict":"%s","exit_code":0,"passed":5,"failed":%d,"run_mode":"full"}' \
                "$tv" "$nf" > "$art/test-results.json"
            _CYCLE_DISPATCH_VERDICT="$(verdict_classify "$tv" 2>/dev/null || echo fail)"
            _CYCLE_DISPATCH_VERDICT_RAW="$tv"
            ;;
        *)
            _CYCLE_DISPATCH_VERDICT="pass"; _CYCLE_DISPATCH_VERDICT_RAW="pass" ;;
    esac
    return 0
}

_seed() {
    STATE_FILE="$ZBUILD_STATE_DIR/pipeline-state.json"
    : > "$ZBUILD_EVENTS_JSONL"
    rm -f "$STATE_FILE" "${STATE_FILE}.bak" "${STATE_FILE}.lock"
    rm -rf "$ZBUILD_STATE_DIR/artifacts" "$ZBUILD_STATE_DIR/cycle-build-test"
    mkdir -p "$ZBUILD_STATE_DIR/artifacts"
    printf '{"schema_version":1,"status":"in_progress","stage_statuses":{}}' > "$STATE_FILE"
}

_run() {
    # $1 = template fixture, $2 = MOCK_PLAN
    _seed
    load_template "$1"
    MOCK_PLAN="$2"
    set +e
    cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"
    RUN_RC=$?
    set -e
}

# ─── SPEC-1: timeout never fatal ─────────────────────────────────────────────
print_test_section "SPEC-1: build times out every iter (tests green) → never a halt; runs all iters"
_run "$FIXT/cycle-converges-iter2.yaml" "build:dnf,dnf,dnf,dnf,dnf;test:pass,pass,pass,pass,pass"
assert_eq "[SPEC-1] cycle does not halt on timeout — rc=2 (unconverged→review)" "2" "$RUN_RC"
[[ "${_CYCLE_LAST_ITERATIONS:-0}" -eq 5 ]] \
    && assert_pass "[SPEC-1] ran all 5 iterations (no early abandon), got ${_CYCLE_LAST_ITERATIONS:-?}" \
    || assert_fail "[SPEC-1] ran all 5 iterations" "got ${_CYCLE_LAST_ITERATIONS:-?}"
if grep -q 'cycle.member.timeout_abandoned' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_fail "[SPEC-1] no timeout_abandoned (G2 removed)" "abandoned emitted"
else
    assert_pass "[SPEC-1] no cycle.member.timeout_abandoned (G2 abandon removed)"
fi

# ─── SPEC-2 + SPEC-9(timeout): no false converge on unfinished build ─────────
print_test_section "SPEC-2: build did_not_finish + tests pass → NOT converged; suppression event"
_run "$FIXT/cycle-max-iter.yaml" "build:dnf,dnf,dnf;test:pass,pass,pass"
assert_eq "[SPEC-2] not converged (mid-flight build) — rc=2" "2" "$RUN_RC"
assert_contains "[SPEC-2] suppression event emitted" \
    "$(cat "$ZBUILD_EVENTS_JSONL")" "cycle.build_unfinished.suppressed_convergence"
if grep -q '"reason":"converged"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_fail "[SPEC-2] never a false converge on unfinished build" "converged emitted"
else
    assert_pass "[SPEC-2] never a false converge on unfinished build"
fi

# ─── SPEC-3 / SPEC-9(stall): re-run nothing-to-do converges on iter 1 ────────
print_test_section "SPEC-3: clean empty_diff (LOOP_COMPLETE) + tests green → converge iter 1"
_run "$FIXT/cycle-converges-iter2.yaml" "build:empty_diff;test:pass"
assert_eq "[SPEC-3] converged (rc=0)" "0" "$RUN_RC"
assert_eq "[SPEC-3] converged at iter 1 (nothing-to-do, not a stall)" "1" "${_CYCLE_LAST_ITERATIONS:-}"
if grep -qE 'cycle.stalled|suppressed_convergence' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_fail "[SPEC-3] clean stall is NOT suppressed / stalled" "unexpected event"
else
    assert_pass "[SPEC-3] clean stall converges (not suppressed, not stalled)"
fi

# ─── SPEC-4 + SPEC-6: only fatal at exhaustion; retry>2 not abandoned ────────
print_test_section "SPEC-4/6: red for iters 1-3 then green at iter 4 → converges (not abandoned early)"
_run "$FIXT/cycle-converges-iter2.yaml" \
    "build:pass,pass,pass,pass;test:fail,fail,fail,pass"
assert_eq "[SPEC-4/6] converges at iter 4 (rc=0) — no early terminator" "0" "$RUN_RC"
assert_eq "[SPEC-4/6] iteration count is 4 (>2, G2 does not bite)" "4" "${_CYCLE_LAST_ITERATIONS:-}"

# ─── SPEC-5(a): exhaustion + tests failing → rc=8 (failed halt) ──────────────
print_test_section "SPEC-5a: exhausted with tests failing → rc=8 (status=failed halt)"
_run "$FIXT/cycle-converges-iter2.yaml" "build:pass;test:fail"
assert_eq "[SPEC-5a] exhausted + failing tests → rc=8" "8" "$RUN_RC"

# ─── SPEC-5(b)+SPEC-9: exhaustion + tests passing but unclean build → rc=2 ───
print_test_section "SPEC-5b/9: exhausted, tests pass but build mid-flight every iter → rc=2 (review)"
_run "$FIXT/cycle-converges-iter2.yaml" "build:dnf;test:pass"
assert_eq "[SPEC-5b] exhausted + passing tests (unclean) → rc=2 (unconverged→review)" "2" "$RUN_RC"

# ─── SPEC-5(c): non-test gate fails + tests pass + test-results absent → rc=2 ─
# Residual false-fatal guard: at exhaustion the hard-fail (rc=8) must key ONLY on
# the authoritative test signal (test.verdict==fail OR test-results .failed>0),
# NEVER on the GENERIC failure_count. A failing NON-test gate (which inflates the
# generic failure_count) with PASSING tests and NO test-results artifact (the
# #511 Pin-10 override did not apply) must resolve to rc=2 (unconverged→review),
# NOT rc=8. Red-first: on the pre-hardening code (has_test && failure_count>0)
# this returned rc=8.
print_test_section "SPEC-5c: failing non-test gate + passing tests + no test-results → rc=2 (not rc=8)"
_5C_TPL="$TEST_TEMP_DIR/spec5c-gate-cycle.yaml"
cat > "$_5C_TPL" <<'YAML'
id: spec5c
name: SPEC-5c non-test gate exhaustion
defaults:
  strategy: fanout
stages:
  - id: build-test
    type: cycle
    stages: [build, test, shape-floor]
    until:
      stage: shape-floor
      field: verdict
      op: eq
      value: pass
    max_iterations: 2
    on_max: continue
stage_definitions:
  build:
    roles: [builder]
  test:
    roles: [tester]
  shape-floor:
    roles: [shape_floor]
YAML
_5C_SD="$TEST_TEMP_DIR/spec5c-state"
rm -rf "$_5C_SD"; mkdir -p "$_5C_SD/artifacts"
printf '{"schema_version":1,"status":"in_progress","stage_statuses":{}}' > "$_5C_SD/pipeline-state.json"
: > "$ZBUILD_EVENTS_JSONL"
# Dedicated mock: build passes; test PASSES but writes NO test-results.json (so the
# Pin-10 override does NOT apply); a non-test gate member (shape-floor) FAILS
# (verdict=fail, rc!=0) so exit_when(shape-floor==pass) never converges AND the
# generic failure_count is inflated. NB: verdict=fail (not error/corrupt/block) so
# _cycle_detect_blocked does not fire.
cycle_dispatch_stage() {
    local stage="$1"
    case "$stage" in
        shape-floor)
            _CYCLE_DISPATCH_VERDICT="fail"; _CYCLE_DISPATCH_VERDICT_RAW="fail"
            _CYCLE_DISPATCH_STATUS="failed"; _CYCLE_DISPATCH_REASON=""
            return 1 ;;
        *)
            _CYCLE_DISPATCH_VERDICT="pass"; _CYCLE_DISPATCH_VERDICT_RAW="pass"
            _CYCLE_DISPATCH_STATUS="complete"; _CYCLE_DISPATCH_REASON=""
            return 0 ;;
    esac
}
load_template "$_5C_TPL"
set +e
cycle_orchestrator_run "build-test" "$_5C_SD" "$_5C_SD/pipeline-state.json"
_5C_RC=$?
set -e
assert_eq "[SPEC-5c] non-test gate fail + tests pass + no test-results → rc=2 (not rc=8)" "2" "$_5C_RC"

# ─── SPEC-8: repo-agnostic — no zbuild plugin id / path / test-format in path ─
print_test_section "SPEC-8: exercised convergence path is repo-neutral (generic member ids only)"
_grep_leak() { grep -nE "$1" "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh" 2>/dev/null; }
if _grep_leak 'xcodebuild|npm test|run-tests\.sh|\.swift|cargo |pytest' >/dev/null 2>&1; then
    assert_fail "[SPEC-8] orchestrator has NO hardcoded runner/language token" \
        "$(_grep_leak 'xcodebuild|npm test|run-tests\.sh|\.swift|cargo |pytest' | head -1)"
else
    assert_pass "[SPEC-8] orchestrator convergence path is repo-neutral (no runner/language hardcode)"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
