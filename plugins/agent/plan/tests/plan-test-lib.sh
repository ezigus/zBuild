#!/usr/bin/env bash
# plugins/agent/plan/tests/plan-test-lib.sh — the setup every plan test file
# shares: identity, event sinks, a fixture state dir, the plugin loaded, the
# engine-style dispatch (_run_plan) and the model/redaction mocks. Sourced
# AFTER helpers, test-helpers and setup_test_env (it writes under $TEST_TEMP_DIR).
# shellcheck disable=SC2034  # the variables are read by the sourcing test file

# #1921 follow-up: reserved test identity (zb_test_issue). These were real
# issue numbers; a run keyed to one writes fabricated prior work onto that
# issue's state branch. Only identity positions and the strings DERIVED from
# them are swept — a bare number elsewhere is not an identity.
_ZB_ID="$(zb_test_issue)"

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
echo '{"schema_version":1,"run_id":"test","issue":"'"$_ZB_ID"'","stage_statuses":{}}' > "$STATE_FILE"

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
CANNED_PLAN='{"schema_version":1,"issue":'"$_ZB_ID"',"title":"fixture","goal":"test goal","steps":[{"id":"step-1","description":"do thing","files":["core/foo.sh"],"estimated_lines":10}],"estimated_total_lines":10,"notes":""}'

# ─── Source plugin under test ─────────────────────────────────────────────────
# Source the plugin first so its sourced dependencies (scope-redaction.sh,
# route.sh) are loaded and their idempotent guards (_ZBUILD_*_LOADED) are set.
# Then redefine the mocks — they will shadow the real functions for the rest
# of this test session.
# shellcheck source=../../../../plugins/agent/plan/plugin.sh
source "$PLUGIN_DIR/plugin.sh"

# #1835: plan reads its inputs ONLY from the engine's index and writes to the
# engine's artifact dir. _run_plan dispatches it the way the engine does
# (core/plugin-registry/lifecycle.sh): PLAN_GOAL is the goal intake would have
# written to intake.md; an index the test set itself is used as-is.
_run_plan() {
    local sf="${1:-}" sd si
    if [[ -z "$sf" ]]; then plan_run "plan"; return; fi
    sd="$(dirname "$sf")"
    if [[ -n "${ZBUILD_STAGE_INPUTS:-}" ]]; then
        ZBUILD_ARTIFACT_DIR="${ZBUILD_ARTIFACT_DIR:-$sd/artifacts}" plan_run "plan" "$sf"; return
    fi
    printf '%s\n' "${PLAN_GOAL-}" > "$sd/intake.md"
    si="$sd/stage-inputs.json"
    jq -n --arg g "$sd/intake.md" --arg s "$sd/scope-manifest.md" \
        '{inputs:{intake_goal:$g, scope_manifest:$s}}' > "$si"
    ZBUILD_STAGE_INPUTS="$si" ZBUILD_ARTIFACT_DIR="${ZBUILD_ARTIFACT_DIR:-$sd/artifacts}" plan_run "plan" "$sf"
}

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


# Every event assertion reads the one sink.
EVENTS_FILE="$ZBUILD_EVENTS_JSONL"
