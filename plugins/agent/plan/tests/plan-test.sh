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
: > "$_CAPTURED_PROMPT_FILE"
route_to_model() {
    # Args: tier prompt [flags...]
    printf '%s' "${2:-}" > "$_CAPTURED_PROMPT_FILE"
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
assert_contains "plan prompt demands a SINGLE JSON object response" \
    "$captured_prompt" "SINGLE JSON object"
assert_contains "plan prompt forbids markdown code fences" \
    "$captured_prompt" "no markdown code fences"
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

# ─── Test 12: malformed plan (non-string files) — rc=1, invalid_plan_response ─
: > "$EVENTS_FILE"
CANNED_PLAN='{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"step-1","description":"d","files":[123],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}'
set +e
plan_run "plan" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "malformed files[] non-string returns rc=1" "1" "$rc"
err_reason="$(jq -r 'select(.type=="plugin.run.error") | .data.reason' "$EVENTS_FILE" 2>/dev/null | tail -1)"
assert_eq "malformed plan error reason=invalid_plan_response" "invalid_plan_response" "$err_reason"

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
