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

# Canned plan.json the mock router will write
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
# validator at plugin.sh:128 rejects it. Assert the prompt names the required
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
