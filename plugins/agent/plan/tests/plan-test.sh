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
if grep -qi "Read tool" <<< "$captured_prompt"; then
    assert_pass "plan prompt invites the Read tool"
else
    assert_fail "plan prompt invites the Read tool" "captured: $(head -c 200 <<<"$captured_prompt")"
fi
assert_contains "plan prompt forbids Edit/Write/Bash" \
    "$captured_prompt" "Do NOT call Edit"
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
# JSON. extract_first_json_object slices the LAST top-level balanced object
# out of the prose preface. Without the helper this exact shape was the
# triggering dogfood failure on #294.
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

# ─── Test 4: plan_run fails with missing scope_manifest (rc=1 — redaction fail-closed) ─
# Temporarily replace apply_scope_redaction with a scope-aware mock that
# matches the real ADR-004 fail-closed behavior (returns 1 when manifest absent).
apply_scope_redaction() {
    local _input="$1" _output="$2" _manifest="$3"
    if [[ -z "$_manifest" || ! -f "$_manifest" ]]; then
        return 1
    fi
    cat "$_input" > "$_output"
    return 0
}

NO_SCOPE_STATE_DIR="$TEST_TEMP_DIR/state-noscope"
NO_SCOPE_STATE_FILE="$NO_SCOPE_STATE_DIR/pipeline-state.json"
mkdir -p "$NO_SCOPE_STATE_DIR/artifacts"
echo '{"schema_version":1,"run_id":"test","issue":"0","stage_statuses":{}}' > "$NO_SCOPE_STATE_FILE"
printf 'test goal\n' > "$NO_SCOPE_STATE_DIR/intake.md"
# No scope-manifest.md written here — redaction chokepoint will refuse

set +e
plan_run "plan" "$NO_SCOPE_STATE_FILE" >/dev/null 2>&1
rc=$?
set -e

assert_eq "plan_run with missing scope_manifest returns rc=1 (redaction fail-closed)" "1" "$rc"

# Restore passthrough mock for remaining tests
apply_scope_redaction() {
    local _input="$1" _output="$2"
    cat "$_input" > "$_output"
    return 0
}

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
