#!/usr/bin/env bash
# Tests: plugins/agent/plan — plan stage agent plugin (issue #340)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugin: plan (plan-stage agent plugin — issue #340)"

setup_test_env "plugin-plan"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

PLUGIN_DIR="$REPO_ROOT/plugins/agent/plan"

# ─── Fixture state dir ────────────────────────────────────────────────────────
STATE_DIR="$TEST_TEMP_DIR/state"
STATE_FILE="$STATE_DIR/pipeline-state.json"
ARTIFACTS_DIR="$STATE_DIR/artifacts"
mkdir -p "$STATE_DIR" "$ARTIFACTS_DIR"
echo '{"schema_version":1,"run_id":"test","issue":"999","stage_statuses":{}}' > "$STATE_FILE"

# Scope manifest required by redaction chokepoint
cat > "$STATE_DIR/scope-manifest.md" <<'SCOPE'
+ core/
+ plugins/
SCOPE

# Canned plan.json the mock router will write. Tests override CANNED_PLAN
# (the mock reads it at each invocation) to exercise violation cases without
# needing to redefine the mock body.
# shellcheck disable=SC2089,SC2090  # JSON literal stored verbatim; mocked
# route_to_model echoes it as-is.
CANNED_PLAN='{"schema_version":1,"issue":999,"title":"fixture","goal":"test goal","steps":[{"id":"step-1","description":"do thing","files":["core/foo.sh"],"estimated_lines":10}],"estimated_total_lines":10,"notes":""}'

# ─── Source plugin under test ─────────────────────────────────────────────────
# Source the plugin first so its sourced dependencies (scope-redaction.sh,
# route.sh) are loaded and their idempotent guards (_ZBUILD_*_LOADED) are set.
# Then redefine the mocks — they will shadow the real functions for the rest
# of this test session.
# shellcheck source=../../../../plugins/agent/plan/plugin.sh
source "$PLUGIN_DIR/plugin.sh"

# ─── Mock: apply_scope_redaction — copy input to output, succeed ─────────────
# Overrides the real function loaded by scope-redaction.sh above.
apply_scope_redaction() {
    local _input="$1"
    local _output="$2"
    # _3 = manifest, _4 = allowlist, _5 = cycle_id (ignored in mock)
    cat "$_input" > "$_output"
    return 0
}

# ─── Mock: route_to_model — emit canned plan.json to stdout, succeed ─────────
# Overrides the real function loaded by route.sh above. Captures the prompt
# (arg $2) to a file so tests can assert what the plan plugin actually asks
# the LLM for (issue #435). plan_run invokes route_to_model inside $(...),
# so variable-based capture is lost to the subshell — use a file instead.
_CAPTURED_PROMPT_FILE="$TEST_TEMP_DIR/captured-plan-prompt.txt"
_CAPTURED_ENVELOPE_FILE="$TEST_TEMP_DIR/captured-plan-envelope.txt"
_CAPTURED_ARTIFACT_FILE="$TEST_TEMP_DIR/captured-plan-artifact.txt"
: > "$_CAPTURED_PROMPT_FILE"
: > "$_CAPTURED_ENVELOPE_FILE"
: > "$_CAPTURED_ARTIFACT_FILE"
route_to_model() {
    # Args: tier prompt [flags...]
    printf '%s' "${2:-}" > "$_CAPTURED_PROMPT_FILE"
    # #476: capture envelope-mode state at call time so we can assert
    # plan opted in (ADR-018 Pattern 1 §"JSON envelope is mandatory…").
    printf '%s' "${ZBUILD_ROUTER_JSON_OUTPUT:-unset}" > "$_CAPTURED_ENVELOPE_FILE"
    # #483: capture artifact-id env at call time so we can assert plan
    # tagged the capture so its own banner renders via render_plan_md.
    printf '%s' "${ZBUILD_ROUTER_ARTIFACT_ID:-unset}" > "$_CAPTURED_ARTIFACT_FILE"
    printf '%s\n' "$CANNED_PLAN"
    return 0
}

# ─── Test 1: plan_init sets env vars ─────────────────────────────────────────
plan_init >/dev/null 2>&1

assert_eq "plan_init sets ZBUILD_PLUGIN=plan" "plan" "${ZBUILD_PLUGIN:-}"
assert_eq "plan_init sets ZBUILD_PLUGIN_KIND=agent" "agent" "${ZBUILD_PLUGIN_KIND:-}"

# ─── Test 2: plan_run produces plan.json ─────────────────────────────────────
export ZBUILD_GOAL="test goal"

set +e
plan_run "plan" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e

assert_eq "plan_run returns rc=0" "0" "$rc"
assert_file_exists "plan.json artifact created" "$ARTIFACTS_DIR/plan.json"

# ─── Test 2b (#476): plan opts into JSON envelope mode before route_to_model ──
# ADR-018 §"JSON envelope is mandatory when tools are available" + decision #8.
# Without ZBUILD_ROUTER_JSON_OUTPUT=1, claude --print streams reasoning turns
# as a prose preamble that breaks the strict-JSON parser.
captured_envelope="$(cat "$_CAPTURED_ENVELOPE_FILE" 2>/dev/null || true)"
assert_eq "plan exports ZBUILD_ROUTER_JSON_OUTPUT=1 around route_to_model (#476)" \
    "1" "$captured_envelope"

# ─── Test 2c (#483): plan tags capture with metadata.artifact=plan ───────────
# ADR-018 producer-side renderer dispatch — the plugin's own banner must
# render via render_plan_md, not raw JSON.
captured_artifact="$(cat "$_CAPTURED_ARTIFACT_FILE" 2>/dev/null || true)"
assert_eq "plan exports ZBUILD_ROUTER_ARTIFACT_ID=plan around route_to_model (#483)" \
    "plan" "$captured_artifact"

# ─── Test 3: plan.json has required fields ────────────────────────────────────
plan_json_content="$(cat "$ARTIFACTS_DIR/plan.json" 2>/dev/null || echo '{}')"

schema_version="$(printf '%s' "$plan_json_content" | jq -r '.schema_version // empty' 2>/dev/null || true)"
assert_eq "plan.json schema_version == 1" "1" "$schema_version"

step_count="$(printf '%s' "$plan_json_content" | jq '.steps | length' 2>/dev/null || echo 0)"
assert_gt "plan.json .steps | length > 0" "$step_count" "0"

# ─── Test 3b: prompt declares the plan.json schema (issue #435) ───────────────
# The LLM must be told what shape to produce, or it returns prose and the
# `jq -e` validator in _plan_run_inner rejects it. Assert the prompt names the required
# fields and demands JSON-only output (no markdown wrappers, no commentary).
captured_prompt="$(cat "$_CAPTURED_PROMPT_FILE" 2>/dev/null || true)"
assert_contains "plan prompt names schema_version field" \
    "$captured_prompt" "schema_version"
assert_contains "plan prompt names steps array" \
    "$captured_prompt" "steps"
assert_contains "plan prompt describes a step's id field" \
    "$captured_prompt" '"id"'
assert_contains "plan prompt describes a step's description field" \
    "$captured_prompt" '"description"'
assert_contains "plan prompt describes a step's files field" \
    "$captured_prompt" '"files"'
# ADR-028 PR 2/5: framework renders canonical OUTPUT CONTRACT phrasing.
assert_contains "plan prompt demands exactly one JSON object response" \
    "$captured_prompt" "EXACTLY ONE JSON object"
assert_contains "plan prompt forbids markdown code fences" \
    "$captured_prompt" "NO markdown code fences"
assert_contains "plan prompt still includes the goal text" \
    "$captured_prompt" "test goal"

# ─── Test 3c: ADR-018 (#468) — prompt invites Read; forbids mutating tools ──
# Lifted the "no tool calls" prohibition once #466 made tools available via
# --dangerously-skip-permissions. Plan now invites Read for context-gathering
# while still forbidding Edit/Write/Bash and inlining the scope-manifest.
if grep -q "no tool calls" <<< "$captured_prompt"; then
    assert_fail "plan prompt no longer forbids tool calls"
else
    assert_pass "plan prompt no longer forbids tool calls"
fi
if grep -q "no tool-use" <<< "$captured_prompt"; then
    assert_fail "plan prompt no longer says no tool-use"
else
    assert_pass "plan prompt no longer says no tool-use"
fi
if grep -qi "READ-ONLY tools" <<< "$captured_prompt"; then
    assert_pass "plan prompt invites read-only exploration (Read/Grep/Glob)"
else
    assert_fail "plan prompt invites read-only exploration" "captured: $(head -c 200 <<<"$captured_prompt")"
fi
assert_contains "plan prompt forbids mutating tools (Edit/Write)" \
    "$captured_prompt" "Do NOT call Edit"

# ─── Test 3d: #1442 — turn-budget guardrail (inject budget + bias to converge) ─
# The captured prompt should carry the budget block (the plugin resolves the
# router's max_turns; the in-test fallback is a finite default, so the block
# is present).
assert_contains "plan prompt states its turn budget" \
    "$captured_prompt" "TURN BUDGET"
# _plan_budget_guidance unit behavior: finite budget -> guidance; 0/empty -> none.
assert_contains "[budget] guidance names the budget number" \
    "$(_plan_budget_guidance 45)" "45"
assert_contains "[budget] guidance biases toward a best-effort plan" \
    "$(_plan_budget_guidance 45)" "best-effort plan"
assert_eq "[budget] empty for the 0 (unlimited) sentinel" "" "$(_plan_budget_guidance 0)"
assert_eq "[budget] empty for a non-numeric budget"       "" "$(_plan_budget_guidance abc)"

# ─── Test 3e: #1550 — wall-clock budget block in captured prompt ─────────────
# [SPEC-7] (CHANGE): plan prompt must carry the WALL CLOCK BUDGET block so the
# planner can self-arrest before the OS SIGTERM fires. Fails at baseline because
# the block is only emitted after _plan_wallclock_guidance is wired into
# _plan_run_inner (plugins/agent/plan/plugin.sh is the acceptance-gate WIRING file).
assert_contains "[SPEC-7] plan prompt states its wall-clock budget" \
    "$captured_prompt" "WALL CLOCK BUDGET"
# [SPEC-8] (CHANGE): _plan_wallclock_guidance function behavior — fails at baseline
# because the function does not exist until plugin.sh is updated.
assert_contains "[SPEC-8] wallclock guidance names the budget seconds" \
    "$(_plan_wallclock_guidance 300 0)" "300"
assert_contains "[SPEC-8] wallclock guidance mentions best-effort plan" \
    "$(_plan_wallclock_guidance 300 0)" "best-effort plan"
assert_eq "[SPEC-8] empty for zero budget" "" "$(_plan_wallclock_guidance 0 0)"
assert_eq "[SPEC-8] empty for non-numeric budget" "" "$(_plan_wallclock_guidance abc 0)"
assert_eq "[SPEC-8] empty when elapsed >= budget (degenerate)" "" "$(_plan_wallclock_guidance 100 100)"

if grep -qi "Scope manifest" <<< "$captured_prompt"; then
    assert_pass "plan prompt inlines the scope manifest"
else
    assert_fail "plan prompt inlines the scope manifest"
fi
assert_contains "plan prompt includes manifest prefix" \
    "$captured_prompt" "+ core/"

# ─── Test 6: scope post-validation — in-scope plan emits zero violations ────
EVENTS_FILE="$ZBUILD_EVENTS_JSONL"
: > "$EVENTS_FILE" 2>/dev/null || true
CANNED_PLAN='{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"step-1","description":"d","files":["core/foo.sh","plugins/agent/plan/plugin.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}'
set +e
plan_run "plan" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "in-scope plan returns rc=0" "0" "$rc"
assert_file_exists "in-scope plan.json written" "$ARTIFACTS_DIR/plan.json"
violation_count="$(jq -r 'select(.type=="plan.scope.violation") | .type' "$EVENTS_FILE" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "in-scope plan emits no violation events" "0" "$violation_count"
sv="$(jq -r 'select(.type=="plugin.run.complete" and .data.stage=="plan") | .data.scope_violations' "$EVENTS_FILE" 2>/dev/null | tail -1)"
assert_eq "in-scope plugin.run.complete payload.scope_violations=0" "0" "${sv:-MISSING}"

# ─── Test 7: out-of-scope single path — one violation, plan.json still written ─
: > "$EVENTS_FILE"
CANNED_PLAN='{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"step-1","description":"d","files":["legacy/foo.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}'
set +e
plan_run "plan" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "out-of-scope plan returns rc=0 (fail-soft)" "0" "$rc"
assert_file_exists "out-of-scope plan.json still written" "$ARTIFACTS_DIR/plan.json"
violation_count="$(jq -r 'select(.type=="plan.scope.violation") | .type' "$EVENTS_FILE" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "out-of-scope plan emits exactly one violation event" "1" "$violation_count"
reason="$(jq -r 'select(.type=="plan.scope.violation") | .data.reason' "$EVENTS_FILE" 2>/dev/null | head -1)"
assert_eq "violation reason=out_of_scope" "out_of_scope" "$reason"
voff="$(jq -r 'select(.type=="plan.scope.violation") | .data.path' "$EVENTS_FILE" 2>/dev/null | head -1)"
assert_eq "violation path reports offender" "legacy/foo.sh" "$voff"
sv="$(jq -r 'select(.type=="plugin.run.complete" and .data.stage=="plan") | .data.scope_violations' "$EVENTS_FILE" 2>/dev/null | tail -1)"
assert_eq "scope_violations=1 in run.complete" "1" "$sv"

# ─── Test 8: multiple out-of-scope — one event per offender ─────────────────
: > "$EVENTS_FILE"
CANNED_PLAN='{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"step-1","description":"d","files":["legacy/a.sh","docs/b.md"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}'
set +e
plan_run "plan" "$STATE_FILE" >/dev/null 2>&1
set -e
violation_count="$(jq -r 'select(.type=="plan.scope.violation") | .type' "$EVENTS_FILE" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "two offenders emit two violation events" "2" "$violation_count"

# ─── Test 9: mixed — only out-of-scope path is reported ─────────────────────
: > "$EVENTS_FILE"
CANNED_PLAN='{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"step-1","description":"d","files":["core/ok.sh","legacy/bad.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}'
set +e
plan_run "plan" "$STATE_FILE" >/dev/null 2>&1
set -e
violation_count="$(jq -r 'select(.type=="plan.scope.violation") | .type' "$EVENTS_FILE" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "mixed plan reports only out-of-scope path" "1" "$violation_count"
voff="$(jq -r 'select(.type=="plan.scope.violation") | .data.path' "$EVENTS_FILE" 2>/dev/null | head -1)"
assert_eq "mixed violation path is the offender" "legacy/bad.sh" "$voff"

# ─── Test 10: absolute path — reason=absolute_path ──────────────────────────
: > "$EVENTS_FILE"
CANNED_PLAN='{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"step-1","description":"d","files":["/etc/passwd"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}'
set +e
plan_run "plan" "$STATE_FILE" >/dev/null 2>&1
set -e
reason="$(jq -r 'select(.type=="plan.scope.violation") | .data.reason' "$EVENTS_FILE" 2>/dev/null | head -1)"
assert_eq "absolute path violation reason=absolute_path" "absolute_path" "$reason"

# ─── Test 11: traversal — reason=out_of_repo ────────────────────────────────
: > "$EVENTS_FILE"
CANNED_PLAN='{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"step-1","description":"d","files":["../escape.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}'
set +e
plan_run "plan" "$STATE_FILE" >/dev/null 2>&1
set -e
reason="$(jq -r 'select(.type=="plan.scope.violation") | .data.reason' "$EVENTS_FILE" 2>/dev/null | head -1)"
assert_eq "traversal violation reason=out_of_repo" "out_of_repo" "$reason"

# ─── Test 12: malformed plan (non-string files) — rc=1, schema_violation ────
# #476: plan now distinguishes schema_violation (response present but fails
# jq -e predicate) from empty_result_envelope (router rc=0, .result empty)
# and invalid_plan_response (legacy fallback for other rc paths).
: > "$EVENTS_FILE"
CANNED_PLAN='{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"step-1","description":"d","files":[123],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}'
set +e
plan_run "plan" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "malformed files[] non-string returns rc=1" "1" "$rc"
err_reason="$(jq -r 'select(.type=="plugin.run.error") | .data.reason' "$EVENTS_FILE" 2>/dev/null | tail -1)"
assert_eq "malformed plan error reason=schema_violation (#476)" "schema_violation" "$err_reason"

# ─── Test 13: empty files[] — allowed, no violation ─────────────────────────
: > "$EVENTS_FILE"
CANNED_PLAN='{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"step-1","description":"refactor only","files":[],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}'
set +e
plan_run "plan" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "empty files[] returns rc=0" "0" "$rc"
violation_count="$(jq -r 'select(.type=="plan.scope.violation") | .type' "$EVENTS_FILE" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "empty files[] emits no violations" "0" "$violation_count"

# ─── Test 13b (#476): router returns empty .result → empty_result_envelope ──
# Negative case the #476 fix was written to handle: model emits only tool
# turns and the final assistant message is empty. Router succeeds (rc=0)
# but raw_response is empty. Plugin must distinguish this from a schema
# failure and emit reason=empty_result_envelope.
: > "$EVENTS_FILE"
CANNED_PLAN=''
set +e
plan_run "plan" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "empty .result returns rc=1 (#476)" "1" "$rc"
empty_reason="$(jq -r 'select(.type=="plugin.run.error") | .data.reason' "$EVENTS_FILE" 2>/dev/null | tail -1)"
assert_eq "empty .result emits reason=empty_result_envelope (#476)" "empty_result_envelope" "$empty_reason"

# ─── Test 13c (#478): prose-prefixed JSON survives via parser-side helper ───
# Envelope mode (#476) separates reasoning *turns* from the final turn but the
# model can still emit prose INSIDE the final assistant message before its
# JSON. _llm_envelope_parse (--schema-gate, #944) slices the LAST top-level
# balanced object out of the prose preface. Without the helper this exact shape
# was the triggering dogfood failure on #294.
: > "$EVENTS_FILE"
CANNED_PLAN='Now I have a complete picture.

{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"step-1","description":"d","files":["core/foo.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}'
set +e
plan_run "plan" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "#478: prose-prefixed JSON returns rc=0" "0" "$rc"
assert_file_exists "#478: plan.json written despite prose preface" "$ARTIFACTS_DIR/plan.json"
schema_v="$(jq -r '.schema_version // empty' "$ARTIFACTS_DIR/plan.json" 2>/dev/null || true)"
assert_eq "#478: plan.json parsed from prose-prefixed payload" "1" "$schema_v"

# ─── Test 13d (#478): prompt hardening — explicit "MUST begin with {" rule ──
captured_prompt_478="$(cat "$_CAPTURED_PROMPT_FILE" 2>/dev/null || true)"
assert_contains "#478: plan prompt demands first character must be {" \
    "$captured_prompt_478" 'first output character MUST be `{`'
assert_contains "#478 / ADR-028: prompt forbids prose before/after JSON" \
    "$captured_prompt_478" "NO prose before, after, or around the JSON envelope"

# Restore the original canned plan for any tests below
CANNED_PLAN='{"schema_version":1,"issue":999,"title":"fixture","goal":"test goal","steps":[{"id":"step-1","description":"do thing","files":["core/foo.sh"],"estimated_lines":10}],"estimated_total_lines":10,"notes":""}'

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
plan_run "plan" "$NO_SCOPE_STATE_FILE" >/dev/null 2>&1
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
    : > "$_CAPTURED_ENVELOPE_FILE"
    : > "$_CAPTURED_ARTIFACT_FILE"
    rm -rf "$TEST_TEMP_DIR/cycle-feedback-842"
    mkdir -p "$TEST_TEMP_DIR/cycle-feedback-842"
    unset ZBUILD_CYCLE_ITER ZBUILD_CYCLE_FEEDBACK_DIR 2>/dev/null || true
}

# ─── #842-A: no cycle env → clean prompt (baseline) ─────────────────────────
_842_clean
set +e; plan_run "plan" "$STATE_FILE" >/dev/null 2>&1; rc=$?; set -e
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
# from a prior design_impact_cycle iter), plan must ignore it completely.
_842_clean
export ZBUILD_CYCLE_ITER=2
export ZBUILD_CYCLE_FEEDBACK_DIR="$TEST_TEMP_DIR/cycle-feedback-842"
printf '%s' "STALE_SENTINEL_BODY" > "$ZBUILD_CYCLE_FEEDBACK_DIR/prior_plan.txt"
printf '%s' "STALE_IMPACT_SENTINEL" > "$ZBUILD_CYCLE_FEEDBACK_DIR/prior_impact_feedback.txt"
set +e; plan_run "plan" "$STATE_FILE" >/dev/null 2>&1; rc=$?; set -e
assert_eq "#842-B: plan_run rc=0 with stale feedback env" "0" "$rc"
captured_prompt="$(cat "$_CAPTURED_PROMPT_FILE" 2>/dev/null || true)"
assert_contains "#842-B: prompt is non-empty (guard)" "$captured_prompt" "test goal"
if grep -q "STALE_SENTINEL_BODY\|STALE_IMPACT_SENTINEL\|## PRIOR PLAN\|## PRIOR IMPACT" \
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

CANNED_PLAN='{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"step-1","description":"d","files":["core/foo.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}'
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

# ═══════════════════════════════════════════════════════════════════════════
#  Issue #1052 — Plan-stage resilience SPEC tests (RED until Wave B plugin.sh)
#  These drive through plan_run / _plan_run_inner (which exist) and the
#  envelope-recovery helpers from scripts/lib/plan-context.sh. They assert on
#  OBSERVABLE behavior (events, files, prompt content, rc) so they fail on the
#  unimplemented behavior, not on harness/sourcing errors.
# ═══════════════════════════════════════════════════════════════════════════
print_test_header "Issue #1052 — plan-stage resilience (resumable context + recovery)"

# Restore a clean passthrough redaction + canned-plan mock for these tests.
apply_scope_redaction() {
    local _input="$1" _output="$2"
    cat "$_input" > "$_output"
    return 0
}
CANNED_PLAN='{"schema_version":1,"title":"fixture","goal":"test goal","steps":[{"id":"step-1","description":"do thing","files":["core/foo.sh"],"estimated_lines":10}],"estimated_total_lines":10,"notes":""}'

# Isolate the cross-run plan-context cache under the test temp dir so no real
# $HOME/.zbuild/plan-context is touched and goal-hash collisions across tests
# are impossible.
export ZBUILD_PLAN_CONTEXT_DIR="$TEST_TEMP_DIR/plan-context-cache"
mkdir -p "$ZBUILD_PLAN_CONTEXT_DIR"

# goal_hash formula (plan §Pillar A): normalized pre-redaction goal text.
_spec_goal_hash() {
    printf '%s' "$1" | tr -d '[:space:]' | shasum -a 256 | cut -d' ' -f1
}

# ─── [SPEC-1][change] plan persists plan-context.json on success ─────────────
# On a successful plan run, the plugin must persist a durable plan-context
# artifact (status=complete, goal_hash set) and emit plan.context.persisted;
# the human-readable plan-context.md must be readable.
print_test_section "[SPEC-1][change] persist plan-context on success"
: > "$EVENTS_FILE"
export ZBUILD_GOAL="test goal"
CANNED_PLAN='{"schema_version":1,"title":"fixture","goal":"test goal","steps":[{"id":"step-1","description":"do thing","files":["core/foo.sh"],"estimated_lines":10}],"estimated_total_lines":10,"notes":""}'
set +e
plan_run "plan" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "[SPEC-1] plan_run rc=0 on success" "0" "$rc"
assert_event_emitted "[SPEC-1] plan.context.persisted emitted on success" \
    "$EVENTS_FILE" "plan.context.persisted"
# plan-context.json lives in the per-run artifacts dir (a copy) on every outcome.
assert_file_exists "[SPEC-1] plan-context.json written to artifacts" \
    "$ARTIFACTS_DIR/plan-context.json"
_ctx_status="$(jq -r '.status // empty' "$ARTIFACTS_DIR/plan-context.json" 2>/dev/null || true)"
assert_eq "[SPEC-1] plan-context status=complete on success" "complete" "$_ctx_status"
_ctx_gh="$(jq -r '.goal_hash // empty' "$ARTIFACTS_DIR/plan-context.json" 2>/dev/null || true)"
assert_eq "[SPEC-1] plan-context goal_hash matches normalized goal" \
    "$(_spec_goal_hash "test goal")" "$_ctx_gh"
assert_file_exists "[SPEC-1] plan-context.md readable" \
    "$ARTIFACTS_DIR/plan-context.md"

# ─── [SPEC-2][change] resume splices PRIOR EXPLORATION CONTEXT from cache ─────
# A pre-seeded namespaced cache entry (status != complete, matching goal_hash +
# scope_manifest_ref) must be spliced into the captured prompt under a
# `PRIOR EXPLORATION CONTEXT` heading and plan.context.resumed must fire.
print_test_section "[SPEC-2][change] resume splices prior exploration context"
: > "$EVENTS_FILE"
: > "$_CAPTURED_PROMPT_FILE"
export ZBUILD_GOAL="resume me please"
export ZBUILD_PLAN_RESUME=1
_RESUME_TOKEN="PRIOR_EXPLORATION_SENTINEL_42"
_gh="$(_spec_goal_hash "resume me please")"
_scope_ref="$(shasum -a 256 "$STATE_DIR/scope-manifest.md" | cut -d' ' -f1)"
# Pre-seed the cache in the namespaced layout (Pillar E). repo_id/scope_key are
# derived by the plugin; we seed all candidate leaves so resume resolves
# regardless of how repo_id/scope_key hash out for this fixture.
# Seed a cache leaf the lib's read contract will accept. plan_context_read_for_resume
# refuses on ANY key mismatch (Pillar E), including repo_id — so the seed MUST
# embed the repo_id the plugin computes (derived below) and the scope_key, exactly
# as Wave A's plan_context_write does.
_seed_plan_context() {
    local dir="$1" repo_id="$2" scope_key="$3"
    mkdir -p "$dir"
    jq -n \
        --arg gh "$_gh" \
        --arg sr "$_scope_ref" \
        --arg repo "$repo_id" \
        --arg sk "$scope_key" \
        --arg pr "$_RESUME_TOKEN exploration from a prior exhausted run" \
        '{schema_version:1,goal_hash:$gh,scope_manifest_ref:$sr,
          status:"scope_too_large",num_turns:25,partial_reasoning:$pr,
          candidate_split:true,run_id:"prior-run",repo_id:$repo,scope_key:$sk,
          branch:"test",created_at:"2026-06-26T00:00:00Z"}' \
        > "$dir/$_gh.json"
    printf '# plan-context\n## Accumulated exploration\n%s\n' "$_RESUME_TOKEN" \
        > "$dir/$_gh.md"
}
# Seed the EXACT namespaced leaf the plugin reads: <repo_id>/<scope_key>/
# <goal_hash>.json. repo_id is derived the same way the plugin derives it (via
# plan_context_repo_id, sourced transitively through plugin.sh); scope_key is
# ZBUILD_ISSUE_NUMBER when present (Pillar E). The behavior under test is
# "resume happened", not the namespace math (that is SPEC-5, owned elsewhere).
export ZBUILD_ISSUE_NUMBER=999
_seed_repo_id="$(plan_context_repo_id)"
_seed_plan_context "$ZBUILD_PLAN_CONTEXT_DIR/$_seed_repo_id/999" "$_seed_repo_id" "999"
set +e
plan_run "plan" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "[SPEC-2] plan_run rc=0 with resume enabled" "0" "$rc"
_resume_prompt="$(cat "$_CAPTURED_PROMPT_FILE" 2>/dev/null || true)"
assert_contains "[SPEC-2] prompt carries PRIOR EXPLORATION CONTEXT heading" \
    "$_resume_prompt" "PRIOR EXPLORATION CONTEXT"
assert_contains "[SPEC-2] prompt carries the prior exploration sentinel" \
    "$_resume_prompt" "$_RESUME_TOKEN"
assert_event_emitted "[SPEC-2] plan.context.resumed emitted" \
    "$EVENTS_FILE" "plan.context.resumed"

# ─── [SPEC-2][guard] resume refused on mismatch / disable ────────────────────
# Resume must NOT happen on: goal_hash mismatch, scope-manifest change, or
# ZBUILD_PLAN_RESUME=0. In each case no PRIOR EXPLORATION CONTEXT splice and no
# plan.context.resumed event.
print_test_section "[SPEC-2][guard] resume refused on mismatch / disable"

# (a) ZBUILD_PLAN_RESUME=0 disables resume even with a matching cache entry.
: > "$EVENTS_FILE"; : > "$_CAPTURED_PROMPT_FILE"
export ZBUILD_PLAN_RESUME=0
set +e; plan_run "plan" "$STATE_FILE" >/dev/null 2>&1; set -e
_guard_prompt="$(cat "$_CAPTURED_PROMPT_FILE" 2>/dev/null || true)"
if grep -qF "$_RESUME_TOKEN" <<<"$_guard_prompt"; then
    assert_fail "[SPEC-2][guard] ZBUILD_PLAN_RESUME=0 must not splice prior context"
else
    assert_pass "[SPEC-2][guard] ZBUILD_PLAN_RESUME=0 must not splice prior context"
fi
_resumed_count="$(jq -r 'select(.type=="plan.context.resumed") | .type' "$EVENTS_FILE" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "[SPEC-2][guard] no plan.context.resumed when disabled" "0" "$_resumed_count"

# (b) goal_hash mismatch — different goal text, same cache → no resume.
: > "$EVENTS_FILE"; : > "$_CAPTURED_PROMPT_FILE"
export ZBUILD_PLAN_RESUME=1
export ZBUILD_GOAL="a completely different goal that does not match the cache"
set +e; plan_run "plan" "$STATE_FILE" >/dev/null 2>&1; set -e
_guard_prompt="$(cat "$_CAPTURED_PROMPT_FILE" 2>/dev/null || true)"
if grep -qF "$_RESUME_TOKEN" <<<"$_guard_prompt"; then
    assert_fail "[SPEC-2][guard] goal_hash mismatch must not splice prior context"
else
    assert_pass "[SPEC-2][guard] goal_hash mismatch must not splice prior context"
fi
_resumed_count="$(jq -r 'select(.type=="plan.context.resumed") | .type' "$EVENTS_FILE" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "[SPEC-2][guard] no plan.context.resumed on goal_hash mismatch" "0" "$_resumed_count"

# (c) scope-manifest change — matching goal_hash but the manifest hash differs
# from the seeded scope_manifest_ref → refuse resume (Pillar B condition).
: > "$EVENTS_FILE"; : > "$_CAPTURED_PROMPT_FILE"
export ZBUILD_GOAL="resume me please"
# Mutate the live manifest so its hash no longer matches the seeded ref.
cat > "$STATE_DIR/scope-manifest.md" <<'SCOPE2'
+ core/
+ plugins/
+ scripts/
SCOPE2
set +e; plan_run "plan" "$STATE_FILE" >/dev/null 2>&1; set -e
_guard_prompt="$(cat "$_CAPTURED_PROMPT_FILE" 2>/dev/null || true)"
if grep -qF "$_RESUME_TOKEN" <<<"$_guard_prompt"; then
    assert_fail "[SPEC-2][guard] scope-manifest change must not splice prior context"
else
    assert_pass "[SPEC-2][guard] scope-manifest change must not splice prior context"
fi
_resumed_count="$(jq -r 'select(.type=="plan.context.resumed") | .type' "$EVENTS_FILE" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "[SPEC-2][guard] no plan.context.resumed on scope-manifest change" "0" "$_resumed_count"
# A cache leaf EXISTS for the goal_hash but the scope_manifest_ref guard
# rejected it — this must surface as plan.context.resume_skipped, not a silent
# degrade (#1052 review observability fix).
assert_event_emitted "[SPEC-2][guard] plan.context.resume_skipped fires on guard mismatch" \
    "$EVENTS_FILE" "plan.context.resume_skipped"
# Restore the canonical manifest for downstream tests.
cat > "$STATE_DIR/scope-manifest.md" <<'SCOPE'
+ core/
+ plugins/
SCOPE
unset ZBUILD_ISSUE_NUMBER ZBUILD_PLAN_RESUME 2>/dev/null || true
export ZBUILD_GOAL="test goal"

# ─── [SPEC-4][change] envelope recovery from prose-wrapped/last-turn result ───
# _plan_recover_envelope_json must salvage exactly one schema-valid plan object
# out of a prose-wrapped / multi-turn response and the plugin must emit
# plan.envelope.recovered when it does. Since #944 this helper delegates to the
# shared framework _llm_recover_envelope_json (_plan_envelope_schema_ok gate);
# the assertions below hold identically across the delegation.
print_test_section "[SPEC-4][change] envelope recovery of a single schema-bearer"
_VALID_PLAN='{"schema_version":1,"title":"recovered","goal":"g","steps":[{"id":"step-1","description":"d","files":["core/foo.sh"],"estimated_lines":3}],"estimated_total_lines":3,"notes":""}'
_PROSE_WRAPPED="I explored the repo across several turns. Here is the final plan:

$_VALID_PLAN

That completes my planning."
set +e
_recovered="$(_plan_recover_envelope_json "$_PROSE_WRAPPED" 2>/dev/null)"
_rec_rc=$?
set -e
assert_eq "[SPEC-4] _plan_recover_envelope_json returns rc=0 on single bearer" "0" "$_rec_rc"
_rec_sv="$(printf '%s' "$_recovered" | jq -r '.schema_version // empty' 2>/dev/null || true)"
assert_eq "[SPEC-4] recovered object has schema_version=1" "1" "$_rec_sv"
_rec_steps="$(printf '%s' "$_recovered" | jq -r '.steps | length' 2>/dev/null || echo 0)"
assert_gt "[SPEC-4] recovered object has non-empty steps[]" "$_rec_steps" "0"

# ─── [SPEC-4][guard] recovery fails closed on two schema-bearers ─────────────
# Ambiguity must fail closed (#908): two schema-valid objects → no recovery.
print_test_section "[SPEC-4][guard] recovery fails closed on ambiguity"
_TWO_BEARERS="First candidate:
$_VALID_PLAN
Second candidate:
$_VALID_PLAN"
set +e
_plan_recover_envelope_json "$_TWO_BEARERS" >/dev/null 2>&1
_amb_rc=$?
set -e
assert_eq "[SPEC-4][guard] two schema-bearers → recovery rc!=0 (fail closed)" \
    "1" "$_amb_rc"
# A bearer missing steps[] must also be rejected by the shared predicate.
set +e
_plan_envelope_schema_ok '{"schema_version":1,"title":"t","steps":[]}' >/dev/null 2>&1
_nosteps_rc=$?
set -e
assert_eq "[SPEC-4][guard] object missing non-empty steps[] rejected" "1" "$_nosteps_rc"

# ─── [SPEC-5][change] happy-path recovery via the shared framework (#944) ─────
# ADR-028 v1.2: plan's rc=0 parse now routes through _llm_envelope_parse
# --schema-gate _plan_envelope_schema_ok. When the model emits the real plan
# followed by a brace-bearing postamble, LAST-wins selects the postamble; the
# schema-gate must trigger _llm_recover_envelope_json and restore the real plan.
# CHANGE: RED before #944 — extract_first_json_object (LAST-wins) picks the
# junk object → schema_violation → rc=1.
: > "$EVENTS_FILE"
_SAVED_CANNED_PLAN="$CANNED_PLAN"
CANNED_PLAN='{"schema_version":1,"title":"recovered-via-framework","goal":"g","steps":[{"id":"step-1","description":"d","files":["core/foo.sh"],"estimated_lines":3}],"estimated_total_lines":3,"notes":""}

Trailing prose describing the plan. {"note":"brace-bearing postamble junk"}'
set +e
plan_run "plan" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "[SPEC-5] postamble-wrapped plan → framework recovery → rc=0" "0" "$rc"
_recovered_title="$(jq -r '.title // empty' "$ARTIFACTS_DIR/plan.json" 2>/dev/null || true)"
assert_eq "[SPEC-5] plan.json holds the real envelope, not the postamble" \
    "recovered-via-framework" "$_recovered_title"
CANNED_PLAN="$_SAVED_CANNED_PLAN"

# ─── [SPEC-1/SPEC-2] Persona framing fallback — prefix dropped (#1572) ───────
# SPEC-1 [change]: with product-owner manifest absent the prompt must NOT carry
#   the profession-role prefix 'You are a software planning agent.'  Fails at
#   merge-base baseline because the old fallback led with that sentence.
# SPEC-2 [guard]: with manifest present the canned behavior string must appear
#   in the prompt (persona-present path already worked; tagged, not contorted).

print_test_section "[SPEC-1/SPEC-2] persona fallback is behavior-only (no role prefix)"

# Save real persona_stage_framing so we can restore it after the section.
_ORIG_PSF="$(declare -f persona_stage_framing || true)"

# Simulate absent manifest: return rc=1 so the fallback path runs.
persona_stage_framing() { return 1; }

: > "$_CAPTURED_PROMPT_FILE"
CANNED_PLAN='{"schema_version":1,"issue":999,"title":"fixture","goal":"test goal","steps":[{"id":"step-1","description":"do thing","files":["core/foo.sh"],"estimated_lines":10}],"estimated_total_lines":10,"notes":""}'
set +e; plan_run "plan" "$STATE_FILE" >/dev/null 2>&1; _spf_rc=$?; set -e
assert_eq "[SPEC-1] plan_run rc=0 with persona absent" "0" "$_spf_rc"
_spf_prompt="$(cat "$_CAPTURED_PROMPT_FILE" 2>/dev/null || true)"
if grep -q "You are a software planning agent" <<<"$_spf_prompt"; then
    assert_fail "[SPEC-1] persona fallback must NOT contain profession-prefix role declaration"
else
    assert_pass "[SPEC-1] persona fallback does not contain profession-prefix role declaration"
fi
assert_contains "[SPEC-1] persona fallback DOES contain behavior sentence" \
    "$_spf_prompt" "Decompose the goal into concrete implementation steps."

# Simulate present manifest: emit a canned sentinel string and return rc=0.
_PERSONA_FRAMING_SENTINEL="PERSONA_BEHAVIOR_SENTINEL_XYZ_1572"
persona_stage_framing() {
    printf '%s' "$_PERSONA_FRAMING_SENTINEL"
    return 0
}

: > "$_CAPTURED_PROMPT_FILE"
set +e; plan_run "plan" "$STATE_FILE" >/dev/null 2>&1; _spf_rc2=$?; set -e
assert_eq "[SPEC-2] plan_run rc=0 with persona present" "0" "$_spf_rc2"
_spf_prompt2="$(cat "$_CAPTURED_PROMPT_FILE" 2>/dev/null || true)"
assert_contains "[SPEC-2] persona-present framing sentinel appears in prompt" \
    "$_spf_prompt2" "$_PERSONA_FRAMING_SENTINEL"

# Restore persona_stage_framing to its original definition.
unset -f persona_stage_framing
if [[ -n "$_ORIG_PSF" ]]; then eval "$_ORIG_PSF"; fi
# Restore CANNED_PLAN so the following sections run against the canonical fixture
# (this block overwrote it, mirroring the SPEC-5 restore above).
CANNED_PLAN="$_SAVED_CANNED_PLAN"

# ─── Test 5: plan_finalize runs cleanly ──────────────────────────────────────
set +e
plan_finalize >/dev/null 2>&1
rc=$?
set -e

assert_eq "plan_finalize returns rc=0" "0" "$rc"

# ─── Bonus: plan_cleanup runs cleanly ────────────────────────────────────────
set +e
plan_cleanup >/dev/null 2>&1
rc=$?
set -e

assert_eq "plan_cleanup returns rc=0" "0" "$rc"

# ─── Teardown ─────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
exit $((FAIL > 0))
