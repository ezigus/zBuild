#!/usr/bin/env bash
# plugins/agent/plan/tests/plan-work-items-test.sh — plan splits the issue into
# work items and writes only plan.json and its notes (#2363).
#
# Why: #1801 failed at plan four runs in a row. Each call spent its whole time
# reading code and debugging build's failing tests, and wrote nothing; the one
# plan it ever produced was 8 KB of function names and line counts. Plan's own
# text sent it into the code, told it not to call Write while the engine told
# it to save its notes, and a timed-out call left nothing behind.
#
#   W1 [change] What you own opens with the work-items job; the stage text has
#               no code-level asks (estimated lines, every file, explore the
#               code, uncapped notes) and no Write ban
#   W2 [change] the model writes plan.json itself; a valid file it wrote is the
#               plan, with the result fields added
#   W3 [change] a valid plan.json written before a failed call still counts
#   W4 [change] a failed call that wrote nothing is an error, even when an
#               earlier valid plan.json is on disk
#   W5 [change] a call that ends normally without rewriting a valid plan.json
#               keeps it: the earlier plan still stands
#   W6 [change] a plan.json that is not a plan is a schema_violation
#   W7 [change] plan no longer reports scope_files; plan-context is retired;
#               the DoD-phrase check is gone
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "plan splits the issue into work items (#2363)"
setup_test_env "plan-work-items"
# shellcheck source=plan-test-lib.sh
source "$SCRIPT_DIR/plan-test-lib.sh"

# shellcheck disable=SC2034  # read by _run_plan (plan-test-lib.sh)
PLAN_GOAL="Make stage timeouts apply on every dispatch."
_PJ="$ARTIFACTS_DIR/plan.json"
_GOOD='{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"step-1","description":"Stop a hung hook at its stage limit.","areas":["core/plugin-registry/"]}],"open_questions":[]}'
_OLD='{"schema_version":1,"title":"old","goal":"g","steps":[{"id":"step-1","description":"earlier item","areas":["core/"]}],"open_questions":[],"result_contract":2,"verdict":"pass","disposition":"complete","reason":"plan has 1 work item(s)"}'

# The model writes plan.json at the path its prompt names; MOCK_WRITE is what
# it writes (empty: nothing), MOCK_RC how the call ends.
MOCK_WRITE=""; MOCK_RC=0
route_to_model() {
    printf '%s' "${2:-}" > "$_CAPTURED_PROMPT_FILE"
    [[ -n "$MOCK_WRITE" ]] && printf '%s\n' "$MOCK_WRITE" > "$ZBUILD_ARTIFACT_DIR/plan.json"
    printf 'done\n'
    return "$MOCK_RC"
}
_reset() { rm -f "$_PJ" "$ARTIFACTS_DIR/plan-summary.md" "$ARTIFACTS_DIR/plan-context.json"; MOCK_WRITE=""; MOCK_RC=0; }

print_test_section "W1: the job, and nothing that sends plan into the code"
_reset; MOCK_WRITE="$_GOOD"
_run_plan "$STATE_FILE" >/dev/null 2>&1
_P="$(cat "$_CAPTURED_PROMPT_FILE")"
_own="$(awk '/^## What you own/{f=1;next} f&&/^## /{exit} f' <<< "$_P" | sed '/^[[:space:]]*$/d' | head -n1)"
assert_eq "[W1] What you own opens with the work-items job" \
    "Your job: split the issue into an ordered list of work items, the plan.json described below. Each item says what changes and why, in one or two sentences, and names the areas it touches. Do not say how: no function names, no code, no line counts. If your earlier plan is under Previous work, keep the items that still stand, and change or add an item for each open finding, in one sentence that names it. Do not read code to diagnose a finding." \
    "$_own"
assert_contains "[W1] the prompt names the file plan writes" "$_P" "$_PJ"
assert_contains "[W1] work items name their areas" "$_P" '"areas"'
assert_contains "[W1] open questions replace notes" "$_P" '"open_questions"'
# Wrapped text is matched with its line breaks joined.
_flat="$(tr '\n' ' ' <<< "$_P" | tr -s ' ')"
for _gone in "estimated_lines" "estimated_total_lines" "not length-capped" \
        "check it against the code yourself" "Explore with READ-ONLY tools" \
        "TURN BUDGET" "WALL CLOCK BUDGET" "Do NOT call Edit or Write" \
        "lists every file the step expects" "FORBIDDEN"; do
    if grep -qF -- "$_gone" <<< "$_flat"; then
        assert_fail "[W1] the prompt no longer says: $_gone" "found"
    else
        assert_pass "[W1] the prompt no longer says: $_gone"
    fi
done

print_test_section "W2: the model writes plan.json; a valid one is the plan"
_reset; MOCK_WRITE="$_GOOD"
_run_plan "$STATE_FILE" >/dev/null 2>&1; _rc=$?
assert_eq "[W2] plan_run returns 0" "0" "$_rc"
assert_eq "[W2] verdict pass" "pass" "$(jq -r .verdict "$_PJ" 2>/dev/null)"
assert_eq "[W2] the model's work item is kept" "Stop a hung hook at its stage limit." \
    "$(jq -r '.steps[0].description' "$_PJ" 2>/dev/null)"
assert_file_exists "[W2] plan writes its summary" "$ARTIFACTS_DIR/plan-summary.md"

print_test_section "W3: a valid plan written before a failed call still counts"
_reset; MOCK_WRITE="$_GOOD"; MOCK_RC=124
_run_plan "$STATE_FILE" >/dev/null 2>&1; _rc=$?
assert_eq "[W3] plan_run returns 0" "0" "$_rc"
assert_eq "[W3] verdict pass" "pass" "$(jq -r .verdict "$_PJ" 2>/dev/null)"

print_test_section "W4: a failed call that wrote nothing is an error"
_reset; printf '%s\n' "$_OLD" > "$_PJ"; MOCK_RC=124
_run_plan "$STATE_FILE" >/dev/null 2>&1; _rc=$?
assert_eq "[W4] plan_run returns 1" "1" "$_rc"
assert_eq "[W4] verdict error, not the earlier plan's pass" "error" "$(jq -r .verdict "$_PJ" 2>/dev/null)"

print_test_section "W5: a call that ends normally keeps a valid plan it did not rewrite"
_reset; printf '%s\n' "$_OLD" > "$_PJ"; MOCK_RC=0
_run_plan "$STATE_FILE" >/dev/null 2>&1; _rc=$?
assert_eq "[W5] plan_run returns 0" "0" "$_rc"
assert_eq "[W5] the earlier plan stands" "earlier item" "$(jq -r '.steps[0].description' "$_PJ" 2>/dev/null)"

print_test_section "W6: a plan.json that is not a plan"
_reset; MOCK_WRITE='{"schema_version":1,"steps":[]}'
_run_plan "$STATE_FILE" >/dev/null 2>&1; _rc=$?
assert_eq "[W6] plan_run returns 1" "1" "$_rc"
assert_eq "[W6] reason schema_violation" "schema_violation" "$(jq -r .reason "$_PJ" 2>/dev/null)"

print_test_section "W7: retired"
_reset; MOCK_WRITE="$_GOOD"
_run_plan "$STATE_FILE" >/dev/null 2>&1
assert_eq "[W7] plan reports no scope_files" "false" "$(jq 'has("scope_files")' "$_PJ" 2>/dev/null)"
assert_file_not_exists "[W7] no plan-context.json" "$ARTIFACTS_DIR/plan-context.json"
assert_file_not_exists "[W7] scripts/lib/plan-context.sh is gone" "$REPO_ROOT/scripts/lib/plan-context.sh"
if grep -q 'plan-context\|plan\.context\.' "$PLUGIN_DIR/manifest.yaml"; then
    assert_fail "[W7] the manifest declares no plan-context output or event" "found"
else
    assert_pass "[W7] the manifest declares no plan-context output or event"
fi
if declare -F _plan_validate_dod_discipline >/dev/null; then
    assert_fail "[W7] the DoD-phrase check is gone" "still defined"
else
    assert_pass "[W7] the DoD-phrase check is gone"
fi

print_test_section "W9: a plan whose result cannot be added still ends with a result"
# rules.md: every stage writes a v2 result on every exit path. Adding the result
# fields to a valid plan can fail; the stage then records that, not a plan
# with no verdict.
_reset; MOCK_WRITE="$_GOOD"
_w9="$( atomic_write() { local _in; _in="$(cat)"; [[ "$_in" == *'"verdict":"pass"'* ]] && return 1; printf '%s\n' "$_in" > "$1"; }
        _run_plan "$STATE_FILE" >/dev/null 2>&1; printf '%s' "$?" )"
assert_eq "[W9] plan_run returns 1" "1" "$_w9"
assert_eq "[W9] the result says error" "error" "$(jq -r '.verdict // "none"' "$_PJ" 2>/dev/null)"

print_test_section "W8: a flow without a design scope works from the areas"
# Until build stops reading plan.json (#2364), the areas a work item names are
# what build may touch when no design scope exists — as a step's files were.
_w8="$( source "$REPO_ROOT/plugins/agent/build/plugin.sh" >/dev/null 2>&1
        declare -F _build_load_context >/dev/null || { echo "build plugin.sh did not load"; exit; }
        artifact_dir="$TEST_TEMP_DIR/w8"; mkdir -p "$artifact_dir"
        plan_json="$_GOOD"; plan_files_csv=""
        unset ZBUILD_STAGE_INPUTS ZBUILD_SCOPE_ALLOWLIST ZBUILD_SCOPE_EXPANSION_GRANT
        _build_load_context >/dev/null 2>&1
        printf '%s' "$plan_files_csv" )"
assert_eq "[W8] build's scope holds the work item's areas" "core/plugin-registry/" "$_w8"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
