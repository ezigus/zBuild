#!/usr/bin/env bash
# Integration: governed scope expansion in the cycle orchestrator (#840 / ADR-030).
# Drives cycle_orchestrator_run with a mock dispatch that emits a
# scope_expansion_request (via build-summary.json), and verifies:
#   - non-expandable / floor / unenabled-class request → blocked_on_scope (rc=7)
#     in ONE iter (the dogfood-loop fix: never grind to max_iterations).
#   - grantable collateral request → grant (ZBUILD_SCOPE_EXPANSION_GRANT set),
#     cycle CONTINUES and can then converge.
#   - no request → unchanged behavior.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "integration: governed scope expansion (#840)"
setup_test_env "cycle-scope-expansion-840"

export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
mkdir -p "$ZBUILD_STATE_DIR/artifacts" "$ZBUILD_EVENTS_DIR"
STATE_FILE="$ZBUILD_STATE_DIR/pipeline-state.json"
FIXT="$REPO_ROOT/tests/fixtures/templates"

# shellcheck source=../../core/pipeline/cycle-orchestrator.sh
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"

_seed_state() {
    : > "$ZBUILD_EVENTS_JSONL"
    rm -f "$STATE_FILE" "${STATE_FILE}.bak" "${STATE_FILE}.lock"
    rm -f "$ZBUILD_STATE_DIR/artifacts/build-summary.json" "$ZBUILD_STATE_DIR/scope-expansion-grant.txt"
    unset ZBUILD_SCOPE_EXPANSION_GRANT
    jq -n '{schema_version:1, stage_statuses:{}, updated_at:"seed"}' > "$STATE_FILE"
}

# Mock dispatch: test verdict from MOCK_TEST_VERDICTS (comma list per iter).
# When MOCK_REQUEST_ITER == current iter, build writes a scope_expansion_request
# into build-summary.json (the channel the orchestrator reads).
cycle_dispatch_stage() {
    local stage="$1" iter="$2"
    _CYCLE_DISPATCH_VERDICT="pass"; _CYCLE_DISPATCH_STATUS="complete"
    if [[ "$stage" == "build" ]]; then
        if [[ "${MOCK_REQUEST_ITER:-0}" == "$iter" && -n "${MOCK_REQUEST_JSON:-}" ]]; then
            jq -n --argjson r "$MOCK_REQUEST_JSON" \
                '{schema_version:4, verdict:"empty_diff", scope_expansion_request:$r}' \
                > "$ZBUILD_STATE_DIR/artifacts/build-summary.json"
        else
            jq -n '{schema_version:4, verdict:"pass"}' > "$ZBUILD_STATE_DIR/artifacts/build-summary.json"
        fi
        return 0
    fi
    if [[ "$stage" == "test" ]]; then
        local IFS_save="$IFS"; IFS=','
        # shellcheck disable=SC2206
        local -a vs=(${MOCK_TEST_VERDICTS:-fail})
        IFS="$IFS_save"
        local idx=$(( iter - 1 )); [[ $idx -ge ${#vs[@]} ]] && idx=$(( ${#vs[@]} - 1 ))
        _CYCLE_DISPATCH_VERDICT="${vs[$idx]}"
        [[ "${vs[$idx]}" == "fail" ]] && { _CYCLE_DISPATCH_STATUS="failed"; return 1; }
        return 0
    fi
    return 0
}

# ─── T1: non-expandable cycle + request → blocked_on_scope in 1 iter ──────
_seed_state
load_template "$FIXT/cycle-converges-iter2.yaml"   # NO scope_policy → default off
MOCK_TEST_VERDICTS="fail,fail,fail,fail,fail"
MOCK_REQUEST_ITER=1
MOCK_REQUEST_JSON='{"files":[{"path":"tests/unit/foo-test.sh","category":"collateral_tests","evidence":"x","reason":"pins old"}]}'
set +e; cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc=$?; set -e
assert_eq "T1: rc=7 (blocked_on_scope)" "7" "$rc"
assert_eq "T1: reason=blocked_on_scope" "blocked_on_scope" "$_CYCLE_LAST_TERMINATED_REASON"
assert_eq "T1: abandoned in iter 1 (no loop)" "1" "$_CYCLE_LAST_ITERATIONS"
assert_event_emitted "T1: cycle.scope.denied emitted" "$ZBUILD_EVENTS_JSONL" "cycle.scope.denied"

# ─── T2: floor path → blocked_on_scope even when expandable ───────────────
_seed_state
load_template "$FIXT/cycle-scope-expandable.yaml"
MOCK_TEST_VERDICTS="fail,fail,fail,fail,fail"
MOCK_REQUEST_ITER=1
MOCK_REQUEST_JSON='{"files":[{"path":"legacy/x.sh","category":"collateral_tests","evidence":"x","reason":"need legacy"}]}'
set +e; cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc=$?; set -e
assert_eq "T2: floor path → rc=7 (blocked_on_scope)" "7" "$rc"
assert_eq "T2: abandoned iter 1" "1" "$_CYCLE_LAST_ITERATIONS"

# ─── T3: grantable collateral request → grant + cycle continues/converges ─
_seed_state
load_template "$FIXT/cycle-scope-expandable.yaml"
# Create the evidence file relative to CWD so scope_evidence_present finds it.
PINNED_REL="tests/unit/scope-gov-grant-fixture-test.sh"
mkdir -p "$TEST_TEMP_DIR/repo/tests/unit"
printf 'assert "still has 8 stages"\n' > "$TEST_TEMP_DIR/repo/$PINNED_REL"
MOCK_TEST_VERDICTS="fail,pass"   # iter 1 fails (build requests), iter 2 converges
MOCK_REQUEST_ITER=1
MOCK_REQUEST_JSON="$(jq -nc --arg p "$PINNED_REL" '{files:[{path:$p, category:"collateral_tests", evidence:"8 stages", reason:"pins old count"}]}')"
pushd "$TEST_TEMP_DIR/repo" >/dev/null || exit 1
set +e; cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc=$?; set -e
popd >/dev/null || exit 1
assert_eq "T3: grant → cycle converges (rc=0, not blocked)" "0" "$rc"
assert_event_emitted "T3: cycle.scope.granted emitted" "$ZBUILD_EVENTS_JSONL" "cycle.scope.granted"
if [[ -f "$ZBUILD_STATE_DIR/scope-expansion-grant.txt" ]] && grep -qF "$PINNED_REL" "$ZBUILD_STATE_DIR/scope-expansion-grant.txt"; then
    assert_pass "T3: granted path recorded in grant file"
else
    assert_fail "T3: grant file missing the granted path"
fi

# ─── T4: no request → normal behavior (converges) ────────────────────────
_seed_state
load_template "$FIXT/cycle-scope-expandable.yaml"
MOCK_TEST_VERDICTS="pass"
MOCK_REQUEST_ITER=0   # never emit a request
set +e; cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc=$?; set -e
assert_eq "T4: no request → converges normally rc=0" "0" "$rc"

# ─── T5 (#870): created-collateral request (empty evidence) → grant → converge ─
# The exact dogfood case (#862): build CREATED a new golden not in scope. The
# old evidence-required path DENIED it (no token in a brand-new file) → loop.
# created:true now grants on class+floor → converge in one extra iter, no loop.
_seed_state
load_template "$FIXT/cycle-scope-expandable.yaml"
CREATED_REL="tests/golden/created-by-build.golden"
mkdir -p "$TEST_TEMP_DIR/repo/tests/golden"
printf 'snapshot-line\n' > "$TEST_TEMP_DIR/repo/$CREATED_REL"
MOCK_TEST_VERDICTS="fail,pass"
MOCK_REQUEST_ITER=1
MOCK_REQUEST_JSON="$(jq -nc --arg p "$CREATED_REL" '{files:[{path:$p, category:"collateral_tests", created:true, evidence:"", reason:"build created new golden"}]}')"
pushd "$TEST_TEMP_DIR/repo" >/dev/null || exit 1
set +e; cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc=$?; set -e
popd >/dev/null || exit 1
assert_eq "T5: created collateral (empty evidence) → converges rc=0 (no loop)" "0" "$rc"
assert_event_emitted "T5: cycle.scope.granted emitted" "$ZBUILD_EVENTS_JSONL" "cycle.scope.granted"
if grep -q 'cycle.scope.denied' "$ZBUILD_EVENTS_JSONL"; then
    assert_fail "T5: created collateral must NOT be denied"
else
    assert_pass "T5: created collateral not denied (no blocked_on_scope loop)"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
