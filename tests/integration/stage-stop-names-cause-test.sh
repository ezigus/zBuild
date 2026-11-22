#!/usr/bin/env bash
# Integration: a stage that stops the run is named, with its own reason
# (#2582; ADR-054 §6, ADR-064 §4, ADR-025, amended 2026-11-21).
#
# #1764 run 44910536811: the merge code inside `pr` ended `unavailable` with no
# model call, and the run said "the model could not be reached".
#
# S1 [R2] a stage with no model call that ends unavailable: pipeline.aborted,
#         the stop line and the end words name it and its reason; aborted,
#         resumable; the model is not blamed
# S2 [R2] a stage that ends misconfigured: pipeline.end and the state's reason
#         (what the status comment reads) are stage_stopped:pr:…
# S3 [review 2] a model call that failed (here an empty reply, marked by the
#         router itself) with the stage's reason in its own words: "the model
#         could not be reached"
# S4 [review 4] the stop reason is cleaned before it leaves the runner: a
#         credential and a private path in gh's error are not in the event,
#         the state or the words
# S5 [review 5] a stage that ends broken on an engine code (router_oom_kill),
#         or interrupted: no stage_stopped word, and no engine code in the words
# Real runner (core/pipeline/runner.sh --template simple) over stub plugins
# (tests/lib/simple-run-stubs.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"

print_test_header "a stage that stops the run is named, with its own reason (#2582)"
setup_test_env "stage-stop-names-cause"

_ZB_REPO="$(zb_test_repo stage-stop-names-cause)"
_ZB_GOAL="$(zb_test_goal stage-stop-names-cause)"
PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
STATE_DIR="$TEST_TEMP_DIR/state"
EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" ZBUILD_STATE_DIR="$STATE_DIR"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events" ZBUILD_EVENTS_JSONL="$EVENTS_JSONL"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_CYCLES_ENABLED=1 ZBUILD_CONTRACT_VALIDATOR=warn
export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZB_STUB_ROOT="$REPO_ROOT"
mkdir -p "$STATE_DIR" "$TEST_TEMP_DIR/events"

# shellcheck source=../lib/simple-run-stubs.sh
source "$REPO_ROOT/tests/lib/simple-run-stubs.sh"
simple_stubs_roster

# The model, when a stage calls one: it answers nothing (an empty reply).
printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_TEMP_DIR/bin/claude"; chmod +x "$TEST_TEMP_DIR/bin/claude"

# _make_stopping_pr_plugin <outcome> <reason> [call] — the pr stage, ending
# <outcome> with <reason>. With [call], it first calls the model through the
# real router (the redaction precondition waived by the operator's token for
# this run).
_make_stopping_pr_plugin() {
    local dir="$PLUGINS_ROOT/agent/pr" call=":" load=""
    # The router is loaded with the plugin: requires-core checks it is there.
    [[ -n "${3:-}" ]] && { load='source "$ZB_STUB_ROOT/core/router/route.sh"'; call='printf %s "$ZBUILD_RUN_ID" > "$HOME/.zbuild/scope-override-token"; route_to_model T2 ping --skip-precondition >/dev/null 2>&1 || true'; }
    # The manifest is mock_plugin_factory's: its model call is listed (ADR-017 §12).
    rm -rf "$dir"; mock_plugin_factory pr agent 0 "" pr >/dev/null
    # A stage that reaches the model declares the router (requires-core.sh).
    [[ -z "${3:-}" ]] || { awk '{ print } /^    - redaction$/ { print "    - router" }' "$dir/manifest.yaml" > "$dir/m" && mv "$dir/m" "$dir/manifest.yaml"; }
    cat > "$dir/plugin.sh" <<PLUG
$load
pr_run() {
    local state_dir; state_dir="\$(dirname "\$2")"
    mkdir -p "\$state_dir/artifacts"
    $call
    source "\$STAGE_RESULT_LIB"
    stage_result_write "\$state_dir/artifacts/pr-result.json" $1 "$2"
    return 1
}
PLUG
}
_aborted() { jq -r 'select(.type=="pipeline.aborted") | .data.reason' "$EVENTS_JSONL" 2>/dev/null | head -1; }
_ended() { jq -r 'select(.type=="pipeline.end") | .data.reason // empty' "$EVENTS_JSONL" 2>/dev/null | tail -1; }
_state_reason() { jq -r '.reason // empty' "$STATE_DIR/pipeline-state.json" 2>/dev/null || true; }
_lacks() { if [[ "$2" == *"$3"* ]]; then assert_fail "$1" "it has: $3"; else assert_pass "$1"; fi; }

# ── S1 ───────────────────────────────────────────────────────────────────────
print_test_section "S1: a stage with no model call that ends unavailable names itself and its reason"
_make_stopping_pr_plugin unavailable "gh pr create: error connecting to api.github.com"
_run_pipeline
_err="$(cat "$TEST_TEMP_DIR/runner.stderr")"
assert_eq "[S1] pipeline.aborted names the stage and its reason" \
    "stage_stopped:pr:gh pr create: error connecting to api.github.com" "$(_aborted)"
assert_eq "[S1] the run is aborted, resumable (unavailable)" "aborted" \
    "$(jq -r '.status // empty' "$STATE_DIR/pipeline-state.json" 2>/dev/null || true)"
assert_contains "[S1] the stop line names pr and its reason" "$_err" \
    "pr stopped the run — gh pr create: error connecting to api.github.com"
_lacks "[S1] no model was called, so the stop does not blame it" "$_err" "the model could not be reached"

# ── S2 ───────────────────────────────────────────────────────────────────────
print_test_section "S2: a stage that ends misconfigured names itself and its reason"
_S2_WHY="PR opened https://github.com/o/r/pull/7; merge refused: gh pr merge: Auto merge is not allowed"
_make_stopping_pr_plugin misconfigured "$_S2_WHY"
_run_pipeline
assert_eq "[S2] pipeline.end names the stage and its reason" "stage_stopped:pr:$_S2_WHY" "$(_ended)"
assert_eq "[S2] ...and so does the state's reason (what the status comment reads)" "stage_stopped:pr:$_S2_WHY" "$(_state_reason)"
assert_contains "[S2] the end-of-run words name pr and its reason" "$(cat "$TEST_TEMP_DIR/runner.stderr")" \
    "The run stopped: pr stopped the run — PR opened https://github.com/o/r/pull/7; merge refused"
assert_eq "[S2] the runner exits 1" "1" "${_RUNNER_RC:-}"

# ── S3 ───────────────────────────────────────────────────────────────────────
print_test_section "S3: a model call that failed, the reason in the stage's own words: the model is named"
_make_stopping_pr_plugin unavailable "the PR description could not be written" call
_run_pipeline
assert_eq "[S3] pipeline.aborted says llm_unavailable" "llm_unavailable" "$(_aborted)"
assert_contains "[S3] the stop line says the model could not be reached" \
    "$(cat "$TEST_TEMP_DIR/runner.stderr")" "the model could not be reached"

# ── S4 ───────────────────────────────────────────────────────────────────────
print_test_section "S4: the stop reason is cleaned before it leaves the runner"
_make_stopping_pr_plugin misconfigured "gh pr merge: HTTP 401: token=ghs_A1b2C3d4E5f6G7h8I9j0 read from .env failed"
_run_pipeline
# The stop texts: the event, the state, and the stop and end-words lines. (The
# open-items list below them shows the check's own result, as before.)
_s4="$(_ended)"$'\n'"$(_state_reason)"$'\n'"$(/usr/bin/grep -E 'The run stopped|Stage pr:' "$TEST_TEMP_DIR/runner.stderr" || true)"
assert_contains "[S4] the stop still names the stage" "$(_ended)" "stage_stopped:pr:gh pr merge: HTTP 401"
_lacks "[S4] the credential is in no stop text" "$_s4" "ghs_A1b2C3d4E5f6G7h8I9j0"
_lacks "[S4] the private path is in no stop text" "$_s4" ".env failed"

# ── S5 ───────────────────────────────────────────────────────────────────────
print_test_section "S5: a broken or interrupted stage on an engine code keeps its words"
for _s5 in broken interrupted; do
    _make_stopping_pr_plugin "$_s5" "router_oom_kill"
    _run_pipeline
    _lacks "[S5 $_s5] pipeline.end carries no stage_stopped word" "$(_ended)" "stage_stopped"
    _lacks "[S5 $_s5] the end words hold no engine code" \
        "$(/usr/bin/grep 'The run' "$TEST_TEMP_DIR/runner.stderr" || true)" "router_oom_kill"
done

cleanup_test_env
print_test_results
exit $((FAIL > 0))
