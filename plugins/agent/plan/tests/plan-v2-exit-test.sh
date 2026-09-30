#!/usr/bin/env bash
# plugins/agent/plan/tests/plan-v2-exit-test.sh — #1835 acceptance items the
# run's SPECs did not cover.
#
# P1 [change] an outside signal writes a v2 result — `interrupted` /
#             `signal_interrupt` — and the caller's own TERM handler comes back
#             ("every exit path — success, failure, and interruption")
# P2 [change] plan's real success plan.json goes through the engine's reader
#             (runner_read_stage_verdict) as `pass`, with no contract violation
# P3 [change] the manifest records that plan holds no live resources and
#             declares no cleanup hook (ADR-054 §7: recorded, not implied)
# P4 [change] inputs come ONLY from the engine's index (ZBUILD_STAGE_INPUTS):
#             no ZBUILD_GOAL, no ZBUILD_SCOPE_MANIFEST, no <state>/scope-manifest.md
# P5 [change] the result goes to the engine's artifact dir (ZBUILD_ARTIFACT_DIR),
#             never a path derived from the state file
# P6 [change] plugin.sh constructs no input or artifact path — brace forms
#             included (the run's SPEC-12 grep missed `${state_dir}/…`)
# P7 [change] a router failure the shared mapping cannot name is said out loud,
#             not silently replaced by the plugin's own word (review #2237)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugin: plan — v2 exits, inputs and the engine's reader (#1835)"
setup_test_env "plugin-plan-v2-exit"
_ZB_ID="$(zb_test_issue)"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"
unset ZBUILD_GOAL ZBUILD_SCOPE_MANIFEST ZBUILD_STAGE_INPUTS ZBUILD_ARTIFACT_DIR 2>/dev/null || true

PLUGIN_DIR="$REPO_ROOT/plugins/agent/plan"
CANNED_PLAN='{"schema_version":1,"issue":'"$_ZB_ID"',"title":"fixture","goal":"g","steps":[{"id":"step-1","description":"do thing","files":["core/foo.sh"],"estimated_lines":10}],"estimated_total_lines":10,"notes":""}'

# _stage <name> — a state dir the way the engine lays one out: intake's goal
# and scope manifest, an input index naming them, and an artifact dir. Prints
# the state file; exports nothing.
_stage() {
    local d="$TEST_TEMP_DIR/$1"
    mkdir -p "$d/state" "$d/art"
    printf '{"schema_version":1,"run_id":"t","issue":"%s","stage_statuses":{}}\n' "$_ZB_ID" > "$d/state/pipeline-state.json"
    printf 'goal from intake\n' > "$d/state/intake.md"
    printf '+ core/\n' > "$d/state/scope-manifest.md"
    jq -n --arg g "$d/state/intake.md" --arg s "$d/state/scope-manifest.md" \
        '{inputs:{intake_goal:$g, scope_manifest:$s}}' > "$d/state/stage-inputs.json"
    printf '%s' "$d/state/pipeline-state.json"
}

# shellcheck source=../plugin.sh
source "$PLUGIN_DIR/plugin.sh"
apply_scope_redaction() { cat "$1" > "$2"; return 0; }
MODEL_CALLS="$TEST_TEMP_DIR/model-calls"; : > "$MODEL_CALLS"
route_to_model() { echo call >> "$MODEL_CALLS"; printf '%s\n' "$CANNED_PLAN"; return 0; }

print_test_section "P2/P5: success, read by the engine, in the engine's artifact dir"
SF="$(_stage ok)"; D="$(dirname "$SF")"
OTHER_ART="$TEST_TEMP_DIR/ok/art"
( export ZBUILD_STAGE_INPUTS="$D/stage-inputs.json" ZBUILD_ARTIFACT_DIR="$OTHER_ART"
  plan_run plan "$SF" ) >/dev/null 2>&1
assert_file_exists "[P5] plan.json is written to ZBUILD_ARTIFACT_DIR" "$OTHER_ART/plan.json"
assert_file_not_exists "[P5] ...not to a path derived from the state file" "$D/artifacts/plan.json"
# shellcheck source=../../../../core/pipeline/verdict.sh
source "$REPO_ROOT/core/pipeline/verdict.sh"
mkdir -p "$D/artifacts"; cp "$OTHER_ART/plan.json" "$D/artifacts/plan.json" 2>/dev/null || true
: > "$ZBUILD_EVENTS_JSONL"
_v="$(runner_read_stage_verdict "$D" "$PLUGIN_DIR/manifest.yaml" plan 0 2>/dev/null)"
assert_eq "[P2] the engine's reader says pass" "pass" "$_v"
if grep -q 'contract_violation' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_fail "[P2] ...with no contract violation" "$(grep contract_violation "$ZBUILD_EVENTS_JSONL")"
else
    assert_pass "[P2] ...with no contract violation"
fi

print_test_section "P4: inputs only from the engine's index"
SF4="$(_stage noindex)"; D4="$(dirname "$SF4")"
: > "$MODEL_CALLS"
( export ZBUILD_GOAL="a goal from the environment" ZBUILD_SCOPE_MANIFEST="$D4/scope-manifest.md"
  export ZBUILD_ARTIFACT_DIR="$TEST_TEMP_DIR/noindex/art"
  plan_run plan "$SF4" ) >/dev/null 2>&1
assert_eq "[P4] with no index, plan does not run the model on ZBUILD_GOAL / fallback paths" "0" "$(wc -l < "$MODEL_CALLS" | tr -d ' ')"
assert_eq "[P4] ...and says the engine gave it no input (broken)" "broken" \
    "$(jq -r '.disposition // empty' "$TEST_TEMP_DIR/noindex/art/plan.json" 2>/dev/null)"
SF4b="$(_stage nogoal)"; D4b="$(dirname "$SF4b")"
jq '.inputs |= del(.intake_goal)' "$D4b/stage-inputs.json" > "$D4b/si.tmp" && mv "$D4b/si.tmp" "$D4b/stage-inputs.json"
: > "$MODEL_CALLS"
( export ZBUILD_GOAL="a goal from the environment" ZBUILD_STAGE_INPUTS="$D4b/stage-inputs.json"
  export ZBUILD_ARTIFACT_DIR="$TEST_TEMP_DIR/nogoal/art"
  plan_run plan "$SF4b" ) >/dev/null 2>&1
assert_eq "[P4] an index without intake_goal is not rescued by ZBUILD_GOAL" "0" "$(wc -l < "$MODEL_CALLS" | tr -d ' ')"
assert_eq "[P4] ...and says the engine gave it no intake_goal (broken)" "broken" \
    "$(jq -r '.disposition // empty' "$TEST_TEMP_DIR/nogoal/art/plan.json" 2>/dev/null)"

print_test_section "P7: a router failure the shared mapping cannot name"
# Cannot happen today (the classifier has a catch-all the mapping covers), but
# the plugin's own "unusable" must not stand in silently for the shared word.
SF7="$(_stage unmapped)"; D7="$(dirname "$SF7")"
_err7="$(
    route_to_model() { printf '%s' '{"error":"x"}'; return 1; }
    router_reason_disposition() { printf ''; }
    export ZBUILD_STAGE_INPUTS="$D7/stage-inputs.json" ZBUILD_ARTIFACT_DIR="$TEST_TEMP_DIR/unmapped/art"
    plan_run plan "$SF7" 2>&1 >/dev/null
)" || true
assert_contains "[P7] the plugin says the shared mapping returned nothing" "$_err7" "router_reason_disposition returned nothing"

print_test_section "P1: an outside signal"
SF1="$(_stage sig)"; D1="$(dirname "$SF1")"
READY="$TEST_TEMP_DIR/sig-ready"
bash -c "
    set -uo pipefail
    source '$REPO_ROOT/scripts/lib/helpers.sh'
    source '$PLUGIN_DIR/plugin.sh'
    apply_scope_redaction() { cat \"\$1\" > \"\$2\"; }
    route_to_model() { sleep 30 >/dev/null 2>&1 & printf '%s' \$! > '$READY'; wait \$!; }
    export ZBUILD_STAGE_INPUTS='$D1/stage-inputs.json' ZBUILD_ARTIFACT_DIR='$TEST_TEMP_DIR/sig/art'
    export ZBUILD_EVENTS_DIR='$ZBUILD_EVENTS_DIR' ZBUILD_EVENTS_JSONL='$ZBUILD_EVENTS_JSONL'
    export ZBUILD_EVENT_SCHEMA='$ZBUILD_EVENT_SCHEMA'
    plan_run plan '$SF1' &
    _p=\$!
    for _i in \$(seq 1 200); do [[ -s '$READY' ]] && break; sleep 0.05; done
    kill -TERM \"\$_p\" 2>/dev/null || true
    wait \"\$_p\" 2>/dev/null || true
    kill \"\$(cat '$READY' 2>/dev/null)\" 2>/dev/null || true
" >/dev/null 2>&1
assert_file_exists "[P1] fixture: the model call was reached before the signal" "$READY"
_r1="$TEST_TEMP_DIR/sig/art/plan.json"
assert_eq "[P1] a signal writes disposition=interrupted" "interrupted" "$(jq -r '.disposition // empty' "$_r1" 2>/dev/null)"
assert_eq "[P1] ...reason=signal_interrupt" "signal_interrupt" "$(jq -r '.reason // empty' "$_r1" 2>/dev/null)"
assert_eq "[P1] ...result_contract=2" "2" "$(jq -r '.result_contract // empty' "$_r1" 2>/dev/null)"
SF1b="$(_stage sig2)"; D1b="$(dirname "$SF1b")"
_trap1="$(
    trap 'printf "CALLER\n"' TERM
    export ZBUILD_STAGE_INPUTS="$D1b/stage-inputs.json" ZBUILD_ARTIFACT_DIR="$TEST_TEMP_DIR/sig2/art"
    plan_run plan "$SF1b" >/dev/null 2>&1 || true
    trap -p TERM
)"
assert_contains "[P1] the caller's own TERM handler is back after plan returns" "$_trap1" "CALLER"

print_test_section "P3/P6: what the files say"
_hooks="$(awk '/^hooks:/{f=1;print;next} f&&/^[a-zA-Z_]/{exit} f{print}' "$PLUGIN_DIR/manifest.yaml")"
if grep -qiE 'no live resources' <<< "$_hooks" && grep -qiE 'no cleanup hook' <<< "$_hooks"; then
    assert_pass "[P3] the manifest records: no live resources, no cleanup hook"
else
    assert_fail "[P3] the manifest records: no live resources, no cleanup hook" "$_hooks"
fi
# Outputs named inside the engine's artifact dir are fine; a path derived from
# the state file, or an input read from the environment, is not.
_paths="$(grep -nE 'state_dir|dirname "\$state_file"|ZBUILD_GOAL|ZBUILD_SCOPE_MANIFEST' "$PLUGIN_DIR/plugin.sh" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
assert_eq "[P6] plugin.sh derives no path from the state file and reads no ZBUILD_GOAL / ZBUILD_SCOPE_MANIFEST" "" "$_paths"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
