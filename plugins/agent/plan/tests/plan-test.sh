#!/usr/bin/env bash
# Tests: plugins/agent/plan — plan stage agent plugin (issue #340)
# shellcheck disable=SC2034  # PLAN_GOAL / CANNED_PLAN are read by plan-test-lib.sh's _run_plan and model mock
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugin: plan (plan-stage agent plugin — issue #340)"

setup_test_env "plugin-plan"

# shellcheck source=plan-test-lib.sh
source "$SCRIPT_DIR/plan-test-lib.sh"

# ─── Test 2: plan_run produces plan.json ─────────────────────────────────────
PLAN_GOAL="test goal"

set +e
_run_plan "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e

assert_eq "plan_run returns rc=0" "0" "$rc"
assert_file_exists "plan.json artifact created" "$ARTIFACTS_DIR/plan.json"

# ─── Test 3: plan.json has required fields ────────────────────────────────────
plan_json_content="$(cat "$ARTIFACTS_DIR/plan.json" 2>/dev/null || echo '{}')"

schema_version="$(printf '%s' "$plan_json_content" | jq -r '.schema_version // empty' 2>/dev/null || true)"
assert_eq "plan.json schema_version == 1" "1" "$schema_version"

step_count="$(printf '%s' "$plan_json_content" | jq '.steps | length' 2>/dev/null || echo 0)"
assert_gt "plan.json .steps | length > 0" "$step_count" "0"

# ─── Test 3b: the prompt names the file and its shape (#435, #2363) ──────────
captured_prompt="$(cat "$_CAPTURED_PROMPT_FILE" 2>/dev/null || true)"
assert_contains "plan prompt names the file plan writes" \
    "$captured_prompt" "$ARTIFACTS_DIR/plan.json"
assert_contains "plan prompt names schema_version field" \
    "$captured_prompt" '"schema_version": 1'
assert_contains "plan prompt names steps array" \
    "$captured_prompt" '"steps"'
assert_contains "plan prompt describes a step's id field" \
    "$captured_prompt" '"id": "step-1"'
assert_contains "plan prompt describes a step's description field" \
    "$captured_prompt" '"description"'
assert_contains "plan prompt describes a step's areas field" \
    "$captured_prompt" '"areas"'
assert_contains "plan prompt still includes the goal text" \
    "$captured_prompt" "test goal"

# ─── Test 3c2: ADR-067 §9 — a solution in the issue is a starting point ──────
# #1668's issue said which tests the change left alone, and it was wrong; the
# plan trusted it. A recorded decision binds; anything else is a starting point.
_flat_prompt="$(tr '\n' ' ' <<< "$captured_prompt" | tr -s ' ')"
assert_contains "[ADR-067 §9] plan is told a recorded decision binds" \
    "$_flat_prompt" "A section of the issue that records a decision (for example \"Decision:\") is binding"
assert_contains "[ADR-067 §9] plan is told any other proposal is a starting point" \
    "$_flat_prompt" "is a starting point: follow it unless it contradicts a decision"

# ─── Test 12: a plan.json that is not a plan — rc=1, schema_violation ───────
: > "$EVENTS_FILE"
CANNED_PLAN='{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"step-1","description":"d","areas":[123]}],"open_questions":[]}'
set +e
_run_plan "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "non-string areas[] returns rc=1" "1" "$rc"
err_reason="$(jq -r 'select(.type=="plugin.result" and .data.verdict=="error") | .data.reason' "$EVENTS_FILE" 2>/dev/null | tail -1)"
assert_eq "malformed plan error reason=schema_violation (#476)" "schema_violation" "$err_reason"

# ─── Test 13b: the model writes nothing — no_plan_written ───────────────────
: > "$EVENTS_FILE"; rm -f "$ARTIFACTS_DIR/plan.json"
CANNED_PLAN=''
set +e
_run_plan "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "no plan written returns rc=1" "1" "$rc"
assert_eq "no plan written: reason=no_plan_written" "no_plan_written" \
    "$(jq -r 'select(.type=="plugin.result" and .data.verdict=="error") | .data.reason' "$EVENTS_FILE" 2>/dev/null | tail -1)"

CANNED_PLAN='{"schema_version":1,"title":"fixture","goal":"test goal","steps":[{"id":"step-1","description":"do thing","areas":["core/"]}],"open_questions":[]}'

# ─── Test 4: redaction fail-closed moved to the router (ADR-043) ─────────────
# Redaction is now owned by route_to_model, so plan_run no longer fail-closes on
# a missing scope-manifest at the plugin level — that guarantee is enforced by
# the router (fail-closed on a configured-but-missing manifest → redaction.refused
# → call blocked) and covered by tests/integration/router-precondition-test.sh +
# the security-lens router fail-closed test + plan-integration-test's real-router
# [SPEC-2] guard. With route_to_model mocked here, plan_run completes normally.
NO_SCOPE_STATE_DIR="$TEST_TEMP_DIR/state-noscope"
NO_SCOPE_STATE_FILE="$NO_SCOPE_STATE_DIR/pipeline-state.json"
mkdir -p "$NO_SCOPE_STATE_DIR/artifacts"
echo '{"schema_version":1,"run_id":"test","issue":"0","stage_statuses":{}}' > "$NO_SCOPE_STATE_FILE"
printf 'test goal\n' > "$NO_SCOPE_STATE_DIR/intake.md"
# No scope-manifest.md written — the router (not the plugin) owns fail-closed.

set +e
_run_plan "$NO_SCOPE_STATE_FILE" >/dev/null 2>&1
rc=$?
set -e

assert_eq "plan_run no longer fail-closes on missing manifest (router-owned, ADR-043)" "0" "$rc"

# ─── #842: plan is a leaf — no cycle feedback inputs ─────────────────────────
# plan was moved out of plan_impact_cycle (#842): it is now a top-level leaf
# dispatched before design_impact_cycle. It has NO prior_plan or
# prior_impact_feedback cycle feedback inputs. Regression guard: even when
# ZBUILD_CYCLE_FEEDBACK_DIR is set (e.g. stale env from a prior cycle run),
# plan must produce a clean prompt with no PRIOR PLAN / PRIOR IMPACT headings.

_842_clean() {
    : > "$_CAPTURED_PROMPT_FILE"
    rm -rf "$TEST_TEMP_DIR/cycle-feedback-842"
    mkdir -p "$TEST_TEMP_DIR/cycle-feedback-842"
    unset ZBUILD_CYCLE_ITER ZBUILD_CYCLE_FEEDBACK_DIR 2>/dev/null || true
}

# ─── #842-A: no cycle env → clean prompt (baseline) ─────────────────────────
_842_clean
set +e; _run_plan "$STATE_FILE" >/dev/null 2>&1; rc=$?; set -e
assert_eq "#842-A: plan_run rc=0 (no cycle env — plan is a leaf)" "0" "$rc"
captured_prompt="$(cat "$_CAPTURED_PROMPT_FILE" 2>/dev/null || true)"
assert_contains "#842-A: prompt is non-empty (guard)" "$captured_prompt" "test goal"
if grep -q "## PRIOR PLAN\|## PRIOR IMPACT" <<<"$captured_prompt"; then
    assert_fail "#842-A: plan prompt must NOT contain PRIOR headings (plan is a leaf)"
else
    assert_pass "#842-A: plan prompt has no PRIOR PLAN / PRIOR IMPACT headings"
fi

# ─── #842-B: stale ZBUILD_CYCLE_FEEDBACK_DIR set → still no headings ────────
# Regression guard: even if the environment leaks a cycle feedback dir (e.g.
# from a prior cycle iter), plan must ignore it completely.
_842_clean
export ZBUILD_CYCLE_ITER=2
export ZBUILD_CYCLE_FEEDBACK_DIR="$TEST_TEMP_DIR/cycle-feedback-842"
printf '%s' "STALE_SENTINEL_BODY" > "$ZBUILD_CYCLE_FEEDBACK_DIR/prior_plan.txt"
set +e; _run_plan "$STATE_FILE" >/dev/null 2>&1; rc=$?; set -e
assert_eq "#842-B: plan_run rc=0 with stale feedback env" "0" "$rc"
captured_prompt="$(cat "$_CAPTURED_PROMPT_FILE" 2>/dev/null || true)"
assert_contains "#842-B: prompt is non-empty (guard)" "$captured_prompt" "test goal"
if grep -q "STALE_SENTINEL_BODY\|## PRIOR PLAN" \
        <<<"$captured_prompt"; then
    assert_fail "#842-B: plan prompt must NOT splice stale cycle feedback (plan is a leaf)"
else
    assert_pass "#842-B: stale cycle feedback not spliced — plan is a leaf"
fi

# Cleanup env for downstream tests.
unset ZBUILD_CYCLE_ITER ZBUILD_CYCLE_FEEDBACK_DIR 2>/dev/null || true

# ─── T_SANITIZE (#721): sanitizer strips noise from plan redacted_content ─────
# SPEC-3 (CHANGE): OOS-marker tags stripped — fails at baseline because
# without the sanitizer source+pipe the tags reach the LLM prompt verbatim.
# SPEC-4 (GUARD): genuine goal text always survives (tagged but not contorted).
print_test_header "T_SANITIZE (#721): _zbuild_sanitize_for_llm applied to plan redacted_content"

_PLAN_SAN_ARTIFACTS="$TEST_TEMP_DIR/artifacts-plan-san"
mkdir -p "$_PLAN_SAN_ARTIFACTS"

_PLAN_ANSI_ESC=$'\x1b'
# Noisy goal text: OOS wrapper tags + ANSI + genuine content.
# apply_scope_redaction mock copies verbatim → tags reach redacted_content.
_NOISY_PLAN_GOAL="<out-of-scope-context>OOS-WRAPPED-CONTENT</out-of-scope-context>
${_PLAN_ANSI_ESC}[31mANSI-PLAN-NOISE${_PLAN_ANSI_ESC}[0m
Genuine goal: implement the feature"

CANNED_PLAN='{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"step-1","description":"d","areas":["core/"]}],"open_questions":[]}'
: > "$_CAPTURED_PROMPT_FILE"

set +e
_plan_run_inner \
    "$STATE_DIR/scope-manifest.md" \
    "$_NOISY_PLAN_GOAL" \
    "$_PLAN_SAN_ARTIFACTS/plan.json" \
    "$_PLAN_SAN_ARTIFACTS" >/dev/null 2>&1
rc_plan_san=$?
set -e
assert_eq "T_SANITIZE: _plan_run_inner rc=0" "0" "$rc_plan_san"

# SPEC-3 (CHANGE): OOS-marker tags stripped from plan's redacted_content
if grep -qF "<out-of-scope-context>" "$_CAPTURED_PROMPT_FILE" 2>/dev/null; then
    assert_fail "[SPEC-3] plan redacted_content OOS-marker tags stripped before LLM prompt"
else
    assert_pass "[SPEC-3] plan redacted_content OOS-marker tags stripped before LLM prompt"
fi

# SPEC-4 (GUARD): genuine goal text outside OOS tags survives sanitize
_plan_san_prompt="$(cat "$_CAPTURED_PROMPT_FILE")"
assert_contains "[SPEC-4] plan redacted_content genuine text survives sanitize" \
    "$_plan_san_prompt" "Genuine goal: implement the feature"


# ─── Teardown ─────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
exit $((FAIL > 0))
