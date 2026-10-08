#!/usr/bin/env bash
# Tests (#1799, ADR-019 fall-through): a run whose work did not settle opens —
# or turns — its PR into a draft, and says why at the top of the description.
#
# The state file here is written by the ENGINE's own loop writers
# (_cycle_state_init / _cycle_state_write_iter_atomic, core/pipeline/
# cycle-orchestrator.sh), never by hand: a hand-written state file can contain
# any field name, which is how the first attempt read an `iterations_used` the
# engine never writes and would have printed "null/5".
#
# "Did not settle" is read from what reaches the pr stage:
#   * a loop (any template's — keyed by its own id) whose last recorded status
#     is not `complete`: it ran out of rounds, stopped with findings no stage
#     could act on, or ended without passing;
#   * the final gate roll-up (gate_aggregator_result) that did not pass.
#
# U1 [change] an unsettled loop opens the PR as a draft; the result records why
# U2 [change] the description names each unsettled loop with its real round
#             counts, and the warning comes before the footer and the plan
# U3 [guard]  loops that settled are not named; all settled + gates passing →
#             not a draft
# U4 [change] a failed final gate roll-up → draft, and the failing gates and
#             reason are listed, escaped
# U5 [change] a re-run onto an open ready PR turns it into a draft
# U6 [change] a settled re-run turns back to ready only a PR zBuild itself made
#             a draft — never one a person made a draft
# U7 [change] the plugin.result event says the PR is a draft and why
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "pr-open: an unsettled run's PR is a draft, and says why (#1799)"

# assert_not_contains <desc> <haystack> <needle> — the refuting twin of
# assert_contains, which test-helpers.sh does not provide.
assert_not_contains() {
    if grep -qF -- "$3" <<< "$2"; then assert_fail "$1" "found: $3"; else assert_pass "$1"; fi
}
setup_test_env "pr-open-unsettled"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

STATE_DIR="$TEST_TEMP_DIR/state"
ART="$STATE_DIR/artifacts"
STATE_FILE="$STATE_DIR/pipeline-state.json"
RESULT="$ART/pr-result.json"
GATES="$ART/gate-aggregator-result.json"
mkdir -p "$ART"
printf '{"schema_version":1,"verdict":"pass","findings":[]}\n' > "$ART/review-report.json"
jq -n --arg a "$ART" '{inputs: {review_report: ($a + "/review-report.json"),
    gate_aggregator_result: ($a + "/gate-aggregator-result.json")}}' > "$STATE_DIR/stage-inputs.json"
export ZBUILD_STAGE_INPUTS="$STATE_DIR/stage-inputs.json"

# The engine's own loop writers, via the shared helper (scripts/lib/test-helpers.sh).
_loop() { zb_engine_loop_state "$STATE_FILE" "$@" || assert_fail "[setup] the engine's loop writers ran for $1" "they failed"; }
_fresh_state() {
    printf '{"schema_version":1,"run_id":"t","issue":"999","status":"running","stage_statuses":{}}\n' > "$STATE_FILE"
    rm -f "$RESULT" "$GATES" "$ZBUILD_EVENTS_JSONL"
}
_gates() {  # <verdict> <failed json array> <reason>
    jq -n --arg v "$1" --argjson f "$2" --arg r "$3" \
        '{result_contract:2, verdict:$v, disposition:"complete", reason:$r, gates:[], failed:$f}' > "$GATES"
}

# gh/git mocks. EXISTING_PR="" → no open PR; else its number. EXISTING_DRAFT /
# EXISTING_BODY describe it.
GH_LOG="$TEST_TEMP_DIR/gh.log"
git() {
    case "${1:-} ${2:-}" in
        "rev-parse --abbrev-ref") echo "zbuild/issue-999" ;;
        *) return 0 ;;
    esac
}
gh() {
    printf '%s\n' "$*" >> "$GH_LOG"
    case "${1:-} ${2:-}" in
        "pr list")   [[ -n "${EXISTING_PR:-}" ]] && echo "$EXISTING_PR"; return 0 ;;
        "pr view")
            if [[ "$*" == *isDraft* ]]; then
                jq -nc --argjson d "${EXISTING_DRAFT:-false}" --arg b "${EXISTING_BODY:-}" '{isDraft:$d, body:$b}'
            else
                echo "https://github.com/ezigus/zBuild/pull/${EXISTING_PR:-7}"
            fi ;;
        "pr create") printf '%s\n' "$*" > "$TEST_TEMP_DIR/create.args"; echo "https://github.com/ezigus/zBuild/pull/7" ;;
        "pr edit")   printf '%s\n' "$*" > "$TEST_TEMP_DIR/edit.args" ;;
        "pr ready")  return 0 ;;
    esac
    return 0
}
export -f git gh

PLUGIN_DIR="$REPO_ROOT/plugins/tool/pr-open"
# shellcheck source=../../../../plugins/tool/pr-open/plugin.sh
source "$PLUGIN_DIR/plugin.sh"
_run() {
    : > "$GH_LOG"; rm -f "$TEST_TEMP_DIR/create.args" "$TEST_TEMP_DIR/edit.args"
    _pr_open_run_inner "$ART/review.json" "$STATE_FILE" "$RESULT" "999" >/dev/null 2>&1 || true
}
_body() {  # the --body value of the last create/edit
    local f="$TEST_TEMP_DIR/create.args"; [[ -f "$f" ]] || f="$TEST_TEMP_DIR/edit.args"
    [[ -f "$f" ]] && sed -n '/--body/,$p' "$f"
}

# ─── U1/U2 ──────────────────────────────────────────────────────────────────
print_test_section "U1/U2: a loop that used all its rounds"
_fresh_state; EXISTING_PR=""
_loop design_verify_cycle 1 2 complete
_loop build_test_cycle 3 3 max_iterations
assert_eq "[setup] the engine recorded the loop's real fields" "max_iterations 3 3" \
    "$(jq -r '.cycle_iterations.build_test_cycle | "\(.status) \(.current_iter) \(.max_iterations)"' "$STATE_FILE")"
_run
assert_contains "[U1] the PR is created as a draft" "$(cat "$TEST_TEMP_DIR/create.args" 2>/dev/null)" "--draft"
assert_eq "[U1] the result records a draft" "true" "$(jq -r '.data.draft' "$RESULT" 2>/dev/null)"
assert_contains "[U1] ...and why" "$(jq -r '.data.draft_reason // empty' "$RESULT" 2>/dev/null)" "build_test_cycle"
_b="$(_body)"
assert_contains "[U2] the description names the loop and its real counts" "$_b" \
    "\`build_test_cycle\` stopped after round 3 of 3 without passing"
_warn_line="$(grep -n "did not settle" <<< "$_b" | head -n 1 | cut -d: -f1)"
_foot_line="$(grep -n "Generated by zBuild automation" <<< "$_b" | cut -d: -f1)"
_plan_line="$(grep -n "Plan goal" <<< "$_b" | cut -d: -f1)"
if [[ -n "$_warn_line" && -n "$_foot_line" && -n "$_plan_line" \
        && "$_warn_line" -lt "$_plan_line" && "$_warn_line" -lt "$_foot_line" ]]; then
    assert_pass "[U2] the warning comes before the plan and the footer"
else
    assert_fail "[U2] the warning comes before the plan and the footer" \
        "warning=${_warn_line:-none} plan=${_plan_line:-none} footer=${_foot_line:-none}"
fi
assert_not_contains "[U3] a loop that settled is not named" "$_b" "design_verify_cycle"

# ─── U3 guard ───────────────────────────────────────────────────────────────
print_test_section "U3: everything settled"
_fresh_state; EXISTING_PR=""
_loop build_test_cycle 2 3 complete
_gates pass '[]' "all 6 gate(s) passed"
_run
assert_not_contains "[U3] all settled → not a draft" "$(cat "$TEST_TEMP_DIR/create.args" 2>/dev/null)" "--draft"
assert_eq "[U3] the result records no draft" "false" "$(jq -r '.data.draft' "$RESULT" 2>/dev/null)"
assert_not_contains "[U3] ...and no warning" "$(_body)" "did not settle"

# ─── U4 ─────────────────────────────────────────────────────────────────────
print_test_section "U4: the final gate roll-up did not pass"
_fresh_state; EXISTING_PR=""
_loop build_test_cycle 2 3 complete
_gates fail '["acceptance-gate","test"]' "acceptance-gate: SPEC-3 <b>still fails</b> at the merge-base"
_run
assert_contains "[U4] a failed gate roll-up → draft" "$(cat "$TEST_TEMP_DIR/create.args" 2>/dev/null)" "--draft"
_b="$(_body)"
assert_contains "[U4] the failing gates are listed" "$_b" "acceptance-gate, test"
assert_contains "[U4] the reason is shown when it adds something" "$_b" "still fails"
assert_not_contains "[U4] ...escaped, not raw HTML" "$_b" "<b>"

# ─── U5 ─────────────────────────────────────────────────────────────────────
print_test_section "U5: a re-run onto an open ready PR"
_fresh_state; EXISTING_PR=42; EXISTING_DRAFT=false; EXISTING_BODY="old body"
_loop build_test_cycle 3 3 max_iterations
_run
assert_contains "[U5] the existing PR is turned into a draft" "$(cat "$GH_LOG")" "pr ready 42 --undo"
assert_contains "[U5] ...and its description is updated with the warning" "$(_body)" "did not settle"

# ─── U6 ─────────────────────────────────────────────────────────────────────
print_test_section "U6: a settled re-run onto a draft PR"
_marker="$(_pr_open_forced_draft_marker 2>/dev/null || true)"
assert_contains "[U6 setup] zBuild marks a draft it forced" "$_marker" "zbuild"
_fresh_state; EXISTING_PR=43; EXISTING_DRAFT=true; EXISTING_BODY="earlier body
$_marker"
_loop build_test_cycle 1 3 complete
_run
if grep -qE '^pr ready 43$' "$GH_LOG"; then
    assert_pass "[U6] a draft zBuild forced is turned back to ready"
else
    assert_fail "[U6] a draft zBuild forced is turned back to ready" "gh calls: $(tr '\n' '|' < "$GH_LOG")"
fi
_fresh_state; EXISTING_PR=44; EXISTING_DRAFT=true; EXISTING_BODY="a person made this a draft"
_loop build_test_cycle 1 3 complete
_run
assert_not_contains "[U6] a draft a person made is left alone" "$(cat "$GH_LOG")" "pr ready 44"

# ─── U7 ─────────────────────────────────────────────────────────────────────
print_test_section "U7: the event says so"
_fresh_state; EXISTING_PR=""
_loop build_test_cycle 3 3 max_iterations
_run
_ev="$(jq -c 'select(.type=="plugin.result")' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | tail -n 1)"
assert_contains "[U7] plugin.result carries draft=true" "$_ev" '"draft":"true"'
assert_contains "[U7] ...and the whole reason, as one field" "$_ev" '"draft_reason":"build_test_cycle stopped after round 3 of 3"'

# ─── U8 ─────────────────────────────────────────────────────────────────────
print_test_section "U8: lib/unsettled.sh works on its own"
# It escapes with the definitions advisory-section.sh holds; sourced alone it
# must load them itself, not silently render without escaping (review #2343).
_u8_gates="$TEST_TEMP_DIR/u8-gates.json"
jq -n '{result_contract:2, verdict:"fail", disposition:"complete", reason:"a <b>bold</b> claim", failed:["x"]}' > "$_u8_gates"
_fresh_state; zb_engine_loop_state "$STATE_FILE" build_test_cycle 1 3 complete
_u8="$(bash -c 'source "$1/scripts/lib/helpers.sh" 2>/dev/null; source "$1/plugins/tool/pr-open/lib/unsettled.sh"; _pr_open_unsettled "$2" "$3"' _ "$REPO_ROOT" "$STATE_FILE" "$_u8_gates" 2>&1)"
assert_contains "[U8] sourced alone, it still renders the gate check" "$_u8" "The final gate check did not pass"
assert_not_contains "[U8] ...and still escapes" "$_u8" "<b>"

unset -f git gh
cleanup_test_env
print_test_results
