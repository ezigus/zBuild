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

# Canned plan.json the mock model writes. Tests override CANNED_PLAN (the mock
# reads it at each invocation); an empty CANNED_PLAN writes nothing.
CANNED_PLAN='{"schema_version":1,"title":"fixture","goal":"test goal","steps":[{"id":"step-1","description":"do thing","areas":["core/"]}],"open_questions":[]}'

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
# handed on (its result's issue_text, #2364); an index the test set itself is used as-is.
_run_plan() {
    local sf="${1:-}" sd si
    if [[ -z "$sf" ]]; then plan_run "plan"; return; fi
    sd="$(dirname "$sf")"
    if [[ -n "${ZBUILD_STAGE_INPUTS:-}" ]]; then
        ZBUILD_ARTIFACT_DIR="${ZBUILD_ARTIFACT_DIR:-$sd/artifacts}" plan_run "plan" "$sf"; return
    fi
    # #2364: the issue as intake hands it on — a result carrying the text.
    local _ir; _ir="$(zb_test_issue_output "$sd/artifacts" "${PLAN_GOAL-}")"
    si="$sd/stage-inputs.json"
    jq -n --arg g "$_ir" --arg s "$sd/scope-manifest.md" \
        '{inputs:{intake_result:$g, scope_manifest:$s}}' > "$si"
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

# ─── Mock: route_to_model — the model writes plan.json, as plan asks ─────────
# #2363: plan's model writes plan.json at the path its prompt names and answers
# with one line. The mock writes CANNED_PLAN to that path and returns MOCK_RC
# (default 0). It captures the prompt (arg $2) to a file: plan_run invokes
# route_to_model in a subshell, so a variable would be lost.
_CAPTURED_PROMPT_FILE="$TEST_TEMP_DIR/captured-plan-prompt.txt"
: > "$_CAPTURED_PROMPT_FILE"
MOCK_RC=0
route_to_model() {
    local _p="${2:-}" _out
    printf '%s' "$_p" > "$_CAPTURED_PROMPT_FILE"
    _out="$(awk '/^Write the plan to this file/{f=1; next} f && /^  \//{sub(/^  /, ""); print; exit}' <<< "$_p")"
    [[ -n "$_out" && -n "$CANNED_PLAN" ]] && printf '%s\n' "$CANNED_PLAN" > "$_out"
    printf 'done\n'
    return "${MOCK_RC:-0}"
}


# Every event assertion reads the one sink.
EVENTS_FILE="$ZBUILD_EVENTS_JSONL"
