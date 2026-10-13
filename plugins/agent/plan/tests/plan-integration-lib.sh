#!/usr/bin/env bash
# plugins/agent/plan/tests/plan-integration-lib.sh — setup shared by the plan
# integration tests: the real router with a stubbed `claude` on PATH. Sourced
# AFTER helpers, test-helpers and setup_test_env.
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

STATE_DIR="$TEST_TEMP_DIR/state"
STATE_FILE="$STATE_DIR/pipeline-state.json"
ARTIFACTS_DIR="$STATE_DIR/artifacts"
mkdir -p "$STATE_DIR" "$ARTIFACTS_DIR"
echo '{"schema_version":1,"run_id":"test","issue":"'"$_ZB_ID"'","stage_statuses":{}}' > "$STATE_FILE"

cat > "$STATE_DIR/scope-manifest.md" <<'SCOPE'
+ core/
+ plugins/
SCOPE
# ADR-043: redaction is owned by route_to_model, which reads the manifest from
# ZBUILD_SCOPE_MANIFEST (the runner exports it per-stage). Export it so the
# router performs REAL redaction.
export ZBUILD_SCOPE_MANIFEST="$STATE_DIR/scope-manifest.md"

PLAN_GOAL="integration test goal"
export ZBUILD_RUN_ID="integ-test"
export ZBUILD_ISSUE="$_ZB_ID"

# Stub a real `claude` binary on PATH. route_to_model -> _route_call_claude
# resolves it via `command -v claude` and then execs it.
#
# The default stub answers with CANNED_RESPONSE_FILE's text; tests that need the
# model to write plan.json install _install_plan_writer_claude below.
CANNED_RESPONSE_FILE="$TEST_TEMP_DIR/claude-canned.json"
: > "$CANNED_RESPONSE_FILE"
install_envelope_mock_claude --file "$CANNED_RESPONSE_FILE"

# Source plugin
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

# ADR-043: route_to_model fail-closes if the events log does not yet exist (in
# production the runner emits stage events before any LLM stage). Create it so
# variant 1's router redaction can emit, mirroring the runner.
: > "$ZBUILD_EVENTS_JSONL"


# _plan_error_boundary_env — route the router's diagnostic sidecar into the
# test artifacts dir.
_plan_error_boundary_env() {
    export ZBUILD_STATE_DIR="$STATE_DIR"
    export ZBUILD_ARTIFACT_DIR="$ARTIFACTS_DIR"
    export ZBUILD_CURRENT_STAGE=plan
}

# ── A model that writes plan.json (#2363) ────────────────────────────────────
# _install_plan_writer_claude --plan-file <path> [--rc <n>] — a stub `claude`
# that does what plan asks of the model: it writes the content of <path> to the
# plan file its prompt names (nothing when <path> is empty), answers with one
# line, and exits <n>. Paths are baked in at install time: route.sh scrubs
# ZBUILD_* from the model's environment.
_install_plan_writer_claude() {
    local plan_file="" rc=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --plan-file) plan_file="$2"; shift 2 ;;
            --rc)        rc="$2"; shift 2 ;;
            *)           shift ;;
        esac
    done
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/claude" <<MOCK
#!/usr/bin/env bash
prompt_text=""
while [[ \$# -gt 0 ]]; do
    case "\$1" in
        -p) prompt_text="\${2:-}"; shift 2 ;;
        *)  shift ;;
    esac
done
[[ -n "\$prompt_text" ]] || prompt_text="\$(cat)"
# The router's redaction may wrap the path in an out-of-scope marker; the path
# inside it is the one a model would write to.
out="\$(awk '/^Write the plan to this file/{f=1; next} f && /^  [^ ]/{sub(/^  /, ""); gsub(/<\\/?out-of-scope-context>/, ""); print; exit}' <<< "\$prompt_text")"
if [[ -n "\$out" && -s "$plan_file" ]]; then cat "$plan_file" > "\$out"; fi
jq -n '{type:"result",subtype:"success",result:"1 work item",usage:{input_tokens:0,output_tokens:0},tool_uses:[]}'
exit $rc
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/claude"
}

# ── File-channel error mock (scrub-safe) ─────────────────────────────────────
# WHY: route.sh runs claude under _zbuild_make_fresh_shell, which scrubs ALL
# ZBUILD_* env vars before exec — so the shared install_envelope_mock_claude_error
# tuning vars (ZBUILD_MOCK_SUBTYPE/RESULT/RC) never reach the mock subprocess and
# it always emits its defaults. To exercise the NON-default error envelopes
# (specific subtype / a valid-plan .result / a sentinel partial-reasoning) across
# the real subprocess boundary, this mock reads its envelope fields from FILES
# whose paths are baked into the mock at INSTALL time (mirrors
# install_envelope_mock_claude --file, which survives the scrub for the same
# reason). Same shape route.sh persists to its diagnostic sidecar; then exit rc.
# Args: --subtype <s> --result-file <path> --rc <n> [--num-turns <n>]
#       [--record-prompt <path>]
_install_plan_error_mock_file() {
    local subtype="error_max_turns" result_file="" rc="1" num_turns="25" prompt_record=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --subtype)       subtype="$2"; shift 2 ;;
            --result-file)   result_file="$2"; shift 2 ;;
            --rc)            rc="$2"; shift 2 ;;
            --num-turns)     num_turns="$2"; shift 2 ;;
            --record-prompt) prompt_record="$2"; shift 2 ;;
            *)               shift ;;
        esac
    done
    mkdir -p "$TEST_TEMP_DIR/bin"
    local mock_bin="$TEST_TEMP_DIR/bin/claude"
    cat > "$mock_bin" <<MOCK
#!/usr/bin/env bash
# Test-local scrub-safe error mock (#1052 plan integration). Reads envelope
# fields from baked-in file paths, not env vars (which route.sh scrubs).
prompt_text=""
while [[ \$# -gt 0 ]]; do
    case "\$1" in
        -p) prompt_text="\${2:-}"; shift 2 ;;
        *)  shift ;;
    esac
done
if [[ -n "${prompt_record:-}" ]]; then
    printf '%s' "\$prompt_text" > "$prompt_record"
fi
_result="\$(cat "$result_file" 2>/dev/null || true)"
jq -n \\
    --arg st "$subtype" \\
    --argjson nt "$num_turns" \\
    --arg r "\$_result" \\
    '{type:"result",subtype:\$st,is_error:true,num_turns:\$nt,result:\$r,usage:{input_tokens:0,output_tokens:0},tool_uses:[]}'
exit $rc
MOCK
    chmod +x "$mock_bin"
}
