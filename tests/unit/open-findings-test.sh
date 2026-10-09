#!/usr/bin/env bash
# tests/unit/open-findings-test.sh — a finding is never silent (ADR-068 §10).
#
# Why: on #1799's run a review lens said a test was weak. Nothing asked any
# stage to act on it, the PR went out ready, and `auto_unless_flagged` would
# have merged it: a low or medium concern counted for nothing. Warnings are
# findings, a finding is settled only by a `done` or by its opener's
# `satisfied`, and one still open at the end counts against a clean finish.
#
# F1 [code] a check that PASSED but listed a finding nobody answered: the
#           finding is open
# F2 [code] a `done` from any stage settles the finding it answered; the
#           others stay open
# F3 [code] an answer settles only what the check reported when it was given:
#           once the check runs again, an earlier `done` settles nothing — not
#           a new finding 1 (findings are numbered by position), and not the
#           SAME sentence reported again (the stage said done; the check says it
#           is still there). The engine counts each stage's runs where every
#           dispatch passes (plugin_hook_call).
# F4 [code] the opener's `satisfied` settles its own finding; `nothing to do`
#           from every stage leaves it open, with the answers listed
# F5 [code] review-aggregator lists every lens finding as a numbered finding,
#           low and medium included, with where it is and how severe
# F6 [code] the reports list an open finding of a check that passed — the
#           completion comment on a successful run too ("Still open")
# F7 [code] the pull request is a draft while a finding is open, and says
#           which
# F8 [code] auto_unless_flagged never merges while a finding is open
# F9 [code] a run that completed says, in its end-of-run banner, that it
#           completed with open items, and names each
# F10 [code] so does the live status comment once the run has ended complete
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "a finding is never silent: settled only by done or satisfied (ADR-068 §10)"
setup_test_env "open-findings"

LIB="$REPO_ROOT/core/pipeline/open-findings.sh"
if [[ -f "$LIB" ]]; then
    # shellcheck source=../../core/pipeline/open-findings.sh
    source "$LIB"
fi
declare -F open_findings_json >/dev/null 2>&1 \
    || assert_fail "[F0] core/pipeline/open-findings.sh defines open_findings_json" "missing"
# shellcheck source=../../core/pipeline/state_helpers.sh
source "$REPO_ROOT/core/pipeline/state_helpers.sh"
# shellcheck source=../../scripts/lib/stage-summary.sh
source "$REPO_ROOT/scripts/lib/stage-summary.sh"
# shellcheck source=../../scripts/lib/stage-answers.sh
source "$REPO_ROOT/scripts/lib/stage-answers.sh"
# shellcheck source=../../scripts/lib/run-open-items.sh
source "$REPO_ROOT/scripts/lib/run-open-items.sh"

# One check plugin, `checkx`, whose result is artifacts/checkx-result.json.
mock_plugin_factory checkx agent 0 >/dev/null
export ZBUILD_PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
SD="$TEST_TEMP_DIR/state"; mkdir -p "$SD/artifacts"
SF="$SD/pipeline-state.json"
jq -n '{schema_version:1, stage_statuses:{}, stage_verdicts:{}}' > "$SF"
_update_stage_status "$SF" checkx complete
export ZBUILD_STATE_DIR="$SD" ZBUILD_STATE_FILE="$SF"

# The check's result, its findings written by the findings writer every check
# uses; then the engine records that the check ran (what plugin_hook_call does).
_checkx_result() {   # <verdict> <finding lines…>
    local v="$1"; shift
    local f; f="$(printf '%s\n' "$@" | stage_findings_json)"
    jq -n --arg v "$v" --argjson f "$f" \
        '{result_contract:2, verdict:$v, disposition:"complete", reason:"checked", data:{findings:$f}}' \
        > "$SD/artifacts/checkx-result.json"
    open_findings_stage_ran "$SD" checkx
}
# A stage's reply, recorded by the router's own writer.
_reply() {   # <stage> <reply text>
    ZBUILD_UNIT="$1" ZBUILD_CURRENT_STAGE="$1" answers_record "$2"
}
_open_refs() { jq -r '[.[].ref] | join(",")' <<< "$(open_findings_json "$SF" 2>/dev/null || printf '[]')"; }

print_test_section "F1–F4: open until done or satisfied"
_checkx_result pass "the retry test only checks the exit code" "the timeout is never exercised"
assert_eq "[F1] a passing check's unanswered findings are open" \
    "checkx finding 1,checkx finding 2" "$(_open_refs)"

_reply build "ANSWER checkx finding 1: done — the retry test now checks the output"
assert_eq "[F2] a done settles the finding it answered, and only that one" \
    "checkx finding 2" "$(_open_refs)"

_checkx_result pass "the cleanup step leaves a temp dir behind" "the timeout is never exercised"
assert_eq "[F3] a done given to an earlier finding 1 does not settle a new finding 1" \
    "checkx finding 1,checkx finding 2" "$(_open_refs)"
_reply build "ANSWER checkx finding 1: done — the temp dir is removed"
_checkx_result pass "the cleanup step leaves a temp dir behind" "the timeout is never exercised"
assert_eq "[F3] the same finding reported again after a done is open again" \
    "checkx finding 1,checkx finding 2" "$(_open_refs)"
_lc="$REPO_ROOT/core/plugin-registry/lifecycle.sh"
if grep -qE '^[^#]*open_findings_stage_ran' "$_lc"; then
    assert_pass "[F3] every dispatch records that its stage ran (plugin_hook_call)"
else
    assert_fail "[F3] every dispatch records that its stage ran (plugin_hook_call)" "no call in $_lc"
fi

_reply build "ANSWER checkx finding 2: nothing to do — out of scope"
_reply impact "ANSWER checkx finding 2: nothing to do — not mine"
assert_contains "[F4] nothing to do from every stage leaves it open" "$(_open_refs)" "checkx finding 2"
assert_contains "[F4] ...with the answers listed" \
    "$(jq -r '.[] | select(.ref=="checkx finding 2") | [.answers[].why] | join(";")' <<< "$(open_findings_json "$SF")")" \
    "out of scope"
_reply checkx "ANSWER checkx finding 2: satisfied — the timeout test was added"
_reply build "ANSWER checkx finding 1: done — the temp dir is removed"
assert_eq "[F4] the opener's satisfied settles its own finding" "" "$(_open_refs)"

print_test_section "F5: review-aggregator lists every lens finding"
_d5="$TEST_TEMP_DIR/f5"; mkdir -p "$_d5"
jq -n '{schema_version:1, name:"correctness", score:7, findings:[
    {severity:"low", file:"tests/unit/x-test.sh", line:12, message:"the test only checks the exit code"},
    {severity:"medium", file:"core/x.sh", line:40, message:"an error is swallowed"}]}' > "$_d5/lens-correctness.json"
printf '{"inputs":{"lens_result":["%s"]}}\n' "$_d5/lens-correctness.json" > "$_d5/inputs.json"
# In a fresh shell holding only the plugin: it must load the findings writer
# itself (this file sourced it above, which would hide a plugin that does not).
env -i PATH="$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" ZBUILD_STAGE_INPUTS="$_d5/inputs.json" \
    bash -c 'source "$1/plugins/agent/review-aggregator/plugin.sh" && _review_aggregator_run_inner "$2" "$2/review-report.json" "$2/review-report.md"' \
    _ "$REPO_ROOT" "$_d5" >/dev/null 2>&1 || true
_f5="$(jq -r '[(.data.findings // [])[] | "\(.n): \(.text)"] | join(" | ")' "$_d5/review-report.json" 2>/dev/null)"
assert_contains "[F5] a low lens finding is a numbered finding" "$_f5" "the test only checks the exit code"
assert_contains "[F5] ...naming where it is" "$_f5" "tests/unit/x-test.sh:12"
assert_contains "[F5] ...and how severe" "$_f5" "low"
assert_contains "[F5] a medium lens finding is one too" "$_f5" "an error is swallowed"

print_test_section "F6: the reports list an open finding of a passing check"
_checkx_result pass "the log line names no stage"
_items="$(open_items_markdown "$SD")"
assert_contains "[F6] the open items list a passing check's open finding" "$_items" "the log line names no stage"
_body="$(run_completion_body success "" "" "" "" "$_items" "")"
assert_contains "[F6] a successful run's completion comment says what is still open" "$_body" "Still open"
assert_contains "[F6] ...and names it" "$_body" "the log line names no stage"

print_test_section "F7: the pull request is a draft while a finding is open"
# shellcheck source=../../plugins/tool/pr-open/lib/unsettled.sh
source "$REPO_ROOT/plugins/tool/pr-open/lib/unsettled.sh"
_u="$(_pr_open_unsettled "$SF" "" 2>/dev/null)"
assert_contains "[F7] an open finding makes the run unsettled" "$_u" "open finding"
assert_contains "[F7] ...and the warning names it" "$_u" "the log line names no stage"
_reply build "ANSWER checkx finding 1: done — the stage is named"
assert_eq "[F7] with every finding settled the run is settled" "" "$(_pr_open_unsettled "$SF" "" 2>/dev/null)"

print_test_section "F8: auto_unless_flagged never merges while a finding is open"
_checkx_result pass "the log line names no stage"
_pd="$REPO_ROOT/plugins/agent/pr-delivery/plugin.sh"
_guard_line="$(grep -n 'open_findings_count' "$_pd" | head -1 | cut -d: -f1)"
_merge_line="$(grep -n 'merge_run "pr"' "$_pd" | tail -1 | cut -d: -f1)"
if [[ -n "$_guard_line" && -n "$_merge_line" && "$_guard_line" -lt "$_merge_line" ]]; then
    assert_pass "[F8] pr-delivery checks the open findings before its auto-merge"
else
    assert_fail "[F8] pr-delivery checks the open findings before its auto-merge" \
        "open_findings_count at ${_guard_line:-absent}, merge_run at ${_merge_line:-absent}"
fi
assert_eq "[F8] the count pr-delivery reads sees the open finding" "1" "$(open_findings_count "$SF" 2>/dev/null)"

print_test_section "F9/F10: a run that completed says what is still open"
_e9="$(bash -c "
    export NO_COLOR=1 ZBUILD_TERM_WIDTH_OVERRIDE=80 ZBUILD_STAGE_IO_NOW_MS_OVERRIDE=12345000
    export ZBUILD_STATE_DIR='$TEST_TEMP_DIR/rs9' ZBUILD_EVENTS_DIR='$TEST_TEMP_DIR/ev9'
    export ZBUILD_EVENTS_JSONL='$TEST_TEMP_DIR/ev9/events.jsonl' ZBUILD_PLUGINS_ROOT='$ZBUILD_PLUGINS_ROOT'
    mkdir -p \"\$ZBUILD_STATE_DIR\" \"\$ZBUILD_EVENTS_DIR\"
    source '$REPO_ROOT/core/pipeline/runner.sh'
    _runner_run_id=r1; _runner_issue=1; _RUNNER_PIPELINE_START_MS=12344600
    _runner_state_file='$SF'
    _render_pipeline_end complete
" 2>&1)"
assert_contains "[F9] the banner of a completed run says it completed with an open item" "$_e9" "completed with 1 open item"
assert_contains "[F9] ...and names it" "$_e9" "the log line names no stage"
# shellcheck source=../../scripts/lib/run-status-comment.sh
source "$REPO_ROOT/scripts/lib/run-status-comment.sh"
EV="$SD/events.jsonl"
jq -cn '{ts:"2026-10-08T10:00:00.000Z", run_id:"r-of", issue:1, type:"pipeline.start", data:{run_id:"r-of", issue:"1"}, schema_version:1}' > "$EV"
jq -cn '{ts:"2026-10-08T11:00:00.000Z", run_id:"r-of", issue:1, type:"pipeline.end", data:{status:"success"}, schema_version:1}' >> "$EV"
_b10="$(ZBUILD_STATUS_NOW=2026-10-08T11:00:00Z rsc_render_body "$EV" "$SD")"
assert_contains "[F10] the status comment of a completed run lists the open item" "$_b10" "the log line names no stage"
assert_contains "[F10] ...under words saying it completed with it" "$_b10" "ompleted with 1 open item"

cleanup_test_env
print_test_results
