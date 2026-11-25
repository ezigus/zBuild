#!/usr/bin/env bash
# tests/unit/run-open-items-test.sh — every report a run writes names each open
# item in plain words: what is unresolved and what would settle it (#2330,
# ADR-068 §8).
#
# Why: #2035 run 37450960900 ended with one requirement the judge was not sure
# of, which no stage could act on. The issue comment said only "finished with
# result: `failure`", the end banner said max_iterations, and nothing named the
# item. A reader — a person, an agent or a later run — could not tell what was
# open or what would close it.
#
# O1 [code] a run that ends with failing checks lists each of their findings:
#           the finding's words and what would settle it (a finding's own
#           "What would settle it:" when it gives one); a passing check and a
#           file with no verdict are not listed; a failing check with no
#           findings is listed by its reason
# O3 [code] the end reason a reader sees is words, never the engine's code:
#           "ran out of rounds with 2 open items"
# O4 [code] the issue completion comment lists each open item, not a bare
#           `failure`; with nothing recorded it still says what happened
# O5 [code] the live status comment, once the run has ended, lists each open
#           item under the end reason in words
# O6 [code] the end-of-run banner says why the run stopped and lists the items
# O7 [code] guard: none of the reports above contains an internal term, a raw
#           code or number, or "a person" / "human" wording
# O8 [code] the completion comment workflow builds its body from O4, and the
#           pipeline workflow hands it the run's open items
# O9 [code] the runner's lines that say a loop ended the run say why in words
#           (run_end_words), not as "rc=N reason=<code>"
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
# shellcheck source=../lib/plain-report-terms.sh
source "$REPO_ROOT/tests/lib/plain-report-terms.sh"

print_test_header "every report names each open item and what would settle it (#2330)"
setup_test_env "run-open-items"

LIB="$REPO_ROOT/scripts/lib/run-open-items.sh"
# shellcheck source=../../scripts/lib/run-open-items.sh
if ! { [[ -f "$LIB" ]] && source "$LIB" 2>/dev/null && declare -F open_items_markdown >/dev/null 2>&1; }; then
    assert_fail "[O0] scripts/lib/run-open-items.sh defines open_items_markdown" "missing"
fi
# shellcheck source=../../scripts/lib/run-status-comment.sh
source "$REPO_ROOT/scripts/lib/run-status-comment.sh"

_GUARDED=""   # every report text produced below, for O7
_guard() { _GUARDED+=$'\n'"$1"; }

# ─── a state dir that ended on failing checks ───────────────────────────────
# An existing state dir with nothing in it. It must exist: with TMPDIR unset
# (Linux CI) the status renderer makes its temp file inside the state dir.
mkdir -p "$TEST_TEMP_DIR/empty"
S1="$TEST_TEMP_DIR/s1"; mkdir -p "$S1/artifacts"
# #2366: results are made with the engine's writer.
# shellcheck source=../../scripts/lib/stage-result.sh
source "$REPO_ROOT/scripts/lib/stage-result.sh"
stage_result_write "$S1/artifacts/judge-result.json" fail "not sure one requirement is met" \
    '{"unsure":["R-1: the flag is documented"],"findings":[{"n":1,"text":"Not sure this requirement is met: R-1: the flag is documented. What would settle it: a test that fails when the flag is not documented, or the page that documents it."}]}'
stage_result_write "$S1/artifacts/tests-result.json" fail "one test failed" \
    '{"findings":[{"n":1,"text":"tests/unit/foo-test.sh fails: expected 3, got 2"}]}'
stage_result_write "$S1/artifacts/scan-result.json" fail "the secret scan could not read the diff"
stage_result_write "$S1/artifacts/ok-result.json" pass "all good" \
    '{"findings":[{"n":1,"text":"PASSING CHECK TEXT"}]}'
jq -n '{pushed:true}' > "$S1/artifacts/persist-result.json"

print_test_section "O1: failing checks are listed, each with what would settle it"
_md="$(open_items_markdown "$S1")"; _guard "$_md"
assert_contains "[O1] the unsure finding is named" "$_md" "judge finding 1"
assert_contains "[O1] ...with what is unresolved" "$_md" "R-1: the flag is documented"
assert_contains "[O1] ...and the finding's own settle sentence" "$_md" \
    "What would settle it: a test that fails when the flag is not documented"
assert_contains "[O1] an ordinary failing check's finding is named" "$_md" "expected 3, got 2"
assert_contains "[O1] a failing check with no findings is listed by its reason" "$_md" \
    "the secret scan could not read the diff"
assert_eq "[O1] every item says what would settle it" "3" \
    "$(grep -c 'What would settle it:' <<< "$_md" || true)"
assert_eq "[O1] a passing check is not listed" "0" "$(grep -c 'PASSING CHECK TEXT' <<< "$_md" || true)"
assert_eq "[O1] the count is the items listed" "3" "$(open_items_count "$S1")"
assert_eq "[O1] no open items → nothing listed" "" "$(open_items_markdown "$TEST_TEMP_DIR/empty")"

print_test_section "O3: the end reason is words"
_w1="$(run_end_words blocking_member_failure 1)"; _guard "$_w1"
assert_contains "[O3] one item, in words" "$_w1" "with 1 open item"
_w2="$(run_end_words max_iterations 2)"; _guard "$_w2"
assert_contains "[O3] out of rounds, with the count" "$_w2" "ran out of rounds with 2 open items"
_w3="$(run_end_words max_iterations 0)"; _guard "$_w3"
assert_contains "[O3] out of rounds, nothing recorded" "$_w3" "ran out of rounds"
# A signal stop keeps which signal it was, in words (review of #2330).
assert_contains "[O3] a TERM stop names the signal" "$(run_end_words sigterm 0)" "told to stop (TERM signal)"
assert_contains "[O3] an interrupt names the signal" "$(run_end_words sigint 0)" "interrupted (INT signal, Ctrl-C)"
# A leaf stage that reported a failure (#1798) says so, and names the word.
assert_contains "[O3] a stage that reported a failure says so in words" \
    "$(run_end_words stage_failed:block 0)" "stopped: a stage reported that it failed (block)"
# R2 (#2582, ADR-054 §6, ADR-064): a stage that stopped the run is named, with
# its own reason; never "the model could not be reached".
_w4="$(run_end_words 'stage_stopped:pr:PR opened https://github.com/o/r/pull/7; merge refused: gh pr merge: Auto merge is not allowed' 0)"
_guard "$_w4"
assert_contains "[R2] the stop names the stage" "$_w4" "stopped: pr stopped the run"
assert_contains "[R2] ...and the stage's own reason" "$_w4" "merge refused: gh pr merge: Auto merge is not allowed"
if [[ "$_w4" == *"model"* ]]; then assert_fail "[R2] a stage's stop is not the model's" "$_w4"
else assert_pass "[R2] a stage's stop is not the model's"; fi
_c4="$(run_completion_body failure 'stage_stopped:pr:gh pr merge: refused' "" "" "" "" "")"
assert_contains "[R2] the completion comment names the stage and its reason" "$_c4" "pr stopped the run — gh pr merge: refused"
# R3 (#2607, ADR-064 §4): a reason the stop line has no words for is shown as
# the engine wrote it. On #2533 run 45403848593 the engine stopped the run for a
# stage that changed files it may not change, and both comments said only
# "stopped before finishing".
_r3='broken: test changed files in the repository that it may not change: /w/core/claim/claim.sh'
_w5="$(run_end_words "$_r3" 13)"; _guard "$_w5"
assert_eq "[R3] a reason with no words is shown as written" \
    "stopped: broken: test changed files in the repository that it may not change: /w/core/claim/claim.sh with 13 open items" "$_w5"
_c5="$(run_completion_body failure "$_r3" "" "" "" "" "")"
assert_contains "[R3] ...in the completion comment" "$_c5" "stopped: broken: test changed files in the repository that it may not change"
_w6="$(run_end_words $'first line of the reason\nsecond line' 0)"
assert_eq "[R3] ...on one line" "stopped: first line of the reason second line" "$_w6"
_long="$(printf 'x%.0s' {1..400})"; _w7="$(run_end_words "$_long" 0)"
assert_eq "[R3] ...capped at 300 characters" "stopped: $(printf 'x%.0s' {1..300})…" "$_w7"
assert_eq "[R3] no reason at all: stopped before finishing" "stopped before finishing" "$(run_end_words "" 0)"
# R4 (review of #2607): a code the engine writes gets words — never shown raw;
# a reason it has no words for is one line, masked, and blank is no reason.
for _k in max_iterations max_iterations_tests_failing design_timeout_exhausted blocking_member_failure \
          member_terminal_failure blocked no_committed_changes cycle_abort timed_out sigterm sigint \
          github_login_rejected aborted llm_rate_limited llm_unavailable scope_too_large out_of_tries:design \
          stage_stopped:pr:merge-refused stage_failed:fail converged complete success config_invalid \
          contract_violation:missing_result contract_violation:malformed_json; do
    _wk="$(run_end_words "$_k" 0)"; _guard "$_wk"
    if [[ "$_wk" == *"${_k%%:*}"* ]]; then assert_fail "[R4] $_k is said in words, not shown" "$_wk"; else assert_pass "[R4] $_k is said in words, not shown"; fi
done
_wk="$(run_end_words error 0)"
if [[ "$_wk" == "stopped: error" ]]; then assert_fail "[R4] error is said in words, not shown" "$_wk"; else assert_pass "[R4] error is said in words, not shown"; fi
assert_contains "[R4] a stage's result with no result says so" "$(run_end_words contract_violation:missing_result 0)" "left no result"
assert_eq "[R4] a reason with no words is shown as written" "stopped: some_new_code" "$(run_end_words some_new_code 0)"
assert_eq "[R4] ...carriage returns and tabs are spaces" "stopped: a b c" "$(run_end_words $'a\rb\tc' 0)"
assert_eq "[R4] ...a blank reason is no reason" "stopped before finishing" "$(run_end_words $' \t ' 0)"
_tok="ghp_$(printf 'A%.0s' {1..36})"
_wk="$(run_end_words "broken: gh auth failed with $_tok" 0)"
if [[ "$_wk" == *"$_tok"* ]]; then assert_fail "[R4] ...a credential in it is masked" "$_wk"; else assert_pass "[R4] ...a credential in it is masked"; fi
# The completion comment reads the reason as the workflow does: run_end_reason
# on the state dir (the run's last pipeline.end), into run_completion_body.
_S4="$TEST_TEMP_DIR/s4"; mkdir -p "$_S4"
( source "$REPO_ROOT/core/event-bus/event-bus.sh"
  export ZBUILD_EVENTS_JSONL="$_S4/events.jsonl"
  eb_emit_event "pipeline.end" "status=failed" $'reason=broken: test said:\nline two of the reason' >/dev/null 2>&1 )
_e4="$(run_end_reason "$_S4")"
assert_eq "[R4] the run's end reason is read whole, on one line" "broken: test said: line two of the reason" "$_e4"
assert_contains "[R4] ...and the completion comment says it" \
    "$(run_completion_body failure "" "" "" "" "" "$(run_end_words "$_e4" 0)")" "stopped: broken: test said: line two of the reason"
# Every reason the engine writes (blocked_on_scope is no longer one: ADR-021,
# #2508); a reason with no words is shown as written (R3).
for _r in stage_failed:fail max_iterations_tests_failing blocking_member_failure member_terminal_failure \
          blocked cycle_abort sigint sigterm llm_rate_limited llm_unavailable \
          scope_too_large design_timeout_exhausted no_committed_changes ""; do
    _guard "$(run_end_words "$_r" 1)"
    _guard "$(run_end_words "$_r" 0)"
done

print_test_section "O4: the completion comment lists each open item"
_c1="$(run_completion_body failure "" "" "https://x/run/1" "" "$(open_items_markdown "$S1")" \
    "$(run_end_words max_iterations 3)")"; _guard "$_c1"
assert_contains "[O4] the end reason in words" "$_c1" "ran out of rounds with 3 open items"
assert_contains "[O4] each item is listed" "$_c1" "judge finding 1"
assert_contains "[O4] ...with what would settle it" "$_c1" "What would settle it:"
assert_contains "[O4] the run link stays" "$_c1" "https://x/run/1"
assert_eq "[O4] no bare result word" "0" "$(grep -c '`failure`' <<< "$_c1" || true)"
_c2="$(run_completion_body failure "" "" "https://x/run/2" "" "" "")"; _guard "$_c2"
assert_eq "[O4] nothing recorded: still no bare result word" "0" "$(grep -c '`failure`' <<< "$_c2" || true)"
assert_contains "[O4] ...and it says where to look" "$_c2" "https://x/run/2"
_c3="$(run_completion_body success "" "" "https://x/run/3" "" "" "")"; _guard "$_c3"
assert_contains "[O4] a passing run says so" "$_c3" "completed successfully"
_c4="$(run_completion_body failure llm_rate_limited "resets 12pm (UTC)" "https://x/run/4" "" "" "")"; _guard "$_c4"
assert_contains "[O4] a rate-limited run says when to resume" "$_c4" "resets 12pm (UTC)"
_c5="$(run_completion_body failure cycle_abort "" "https://x/run/5" "" "" "")"; _guard "$_c5"
_c6="$(run_completion_body failure cycle_abort "" "https://x/run/6" "" "$(open_items_markdown "$S1")" "")"; _guard "$_c6"
assert_contains "[O4] a stop with a reason still counts its open items in the headline" \
    "$(head -n 1 <<< "$_c6")" "with 3 open items"
assert_contains "[O4] an aborted run names the reason in words" "$_c5" "$(run_end_words cycle_abort 0)"

print_test_section "O5: the status comment lists each open item once the run ended"
EV="$S1/events.jsonl"
jq -cn '{ts:"2026-10-06T10:00:00.000Z", run_id:"r-2330", issue:2330, type:"pipeline.start", data:{run_id:"r-2330", issue:"2330"}, schema_version:1}' > "$EV"
jq -cn '{ts:"2026-10-06T11:00:00.000Z", run_id:"r-2330", issue:2330, type:"pipeline.end", data:{status:"failed", reason:"blocking_member_failure"}, schema_version:1}' >> "$EV"
_b="$(ZBUILD_STATUS_NOW=2026-10-06T11:00:00Z rsc_render_body "$EV" "$S1")"; _guard "$_b"
assert_contains "[O5] the end reason in words" "$_b" "a check that must pass failed with 3 open items"
assert_contains "[O5] each item is listed" "$_b" "judge finding 1"
assert_contains "[O5] ...with what would settle it" "$_b" "What would settle it:"
jq -cn '{ts:"2026-10-06T10:00:00.000Z", run_id:"r-2330", issue:2330, type:"pipeline.start", data:{run_id:"r-2330", issue:"2330"}, schema_version:1}' > "$EV"
_b2="$(ZBUILD_STATUS_NOW=2026-10-06T10:30:00Z rsc_render_body "$EV" "$S1")"
assert_eq "[O5] a running run lists no open items yet" "0" "$(grep -c 'What would settle it:' <<< "$_b2" || true)"

jq -cn '{ts:"2026-10-06T10:40:00.000Z", run_id:"r-2330", issue:2330, type:"pipeline.aborted", data:{reason:"cycle_abort", status:"interrupted"}, schema_version:1}' >> "$EV"
_b3="$(ZBUILD_STATUS_NOW=2026-10-06T10:41:00Z rsc_render_body "$EV" "$TEST_TEMP_DIR/empty")"; _guard "$_b3"
assert_contains "[O5] an aborted run's header says why in words" "$_b3" "$(run_end_words cycle_abort 0)"

print_test_section "O6: the end-of-run banner says why it stopped and lists the items"
_e="$(bash -c "
    export NO_COLOR=1 ZBUILD_TERM_WIDTH_OVERRIDE=80 ZBUILD_STAGE_IO_NOW_MS_OVERRIDE=12345000
    export ZBUILD_STATE_DIR='$TEST_TEMP_DIR/rs' ZBUILD_EVENTS_DIR='$TEST_TEMP_DIR/ev'
    export ZBUILD_EVENTS_JSONL='$TEST_TEMP_DIR/ev/events.jsonl'
    mkdir -p \"\$ZBUILD_STATE_DIR\" \"\$ZBUILD_EVENTS_DIR\"
    source '$REPO_ROOT/core/pipeline/runner.sh'
    _runner_run_id=r1; _runner_issue=2330; _RUNNER_PIPELINE_START_MS=12344600
    _runner_state_file='$S1/pipeline-state.json'
    _CYCLE_LAST_TERMINATED_REASON=blocking_member_failure
    _render_pipeline_end failed
" 2>&1)"; _guard "$_e"
assert_contains "[O6] the banner says why the run stopped" "$_e" "a check that must pass failed with 3 open items"
assert_contains "[O6] ...and names each item" "$_e" "judge finding 1"
assert_contains "[O6] ...with what would settle it" "$_e" "What would settle it:"

print_test_section "O7: guard — no internal term, raw code or 'who must check' wording"
_bad="$(plain_report_violations "$_GUARDED")"
if [[ -z "$_bad" ]]; then
    assert_pass "[O7] every report above is in plain words"
else
    assert_fail "[O7] every report above is in plain words" "$_bad"
fi
# The guard is not vacuous: it catches each kind of word it is for.
for _probe in "ended max_iterations" "the loop yielded" "halt" "rc=8" "a person must check it" \
              "a human reads" "reason=unowned_finding" "disposition broken"; do
    assert_eq "[O7] the guard catches: $_probe" "1" \
        "$( [[ -n "$(plain_report_violations "$_probe")" ]] && echo 1 || echo 0 )"
done

print_test_section "O8: the workflows build the completion comment from these words"
_dw="$(cat "$REPO_ROOT/.github/workflows/zbuild-daemon.yml")"
_pw="$(cat "$REPO_ROOT/.github/workflows/zbuild-pipeline.yml")"
assert_contains "[O8] the completion comment is built by run_completion_body" "$_dw" "run_completion_body"
assert_eq "[O8] no bare 'finished with result' comment is left" "0" \
    "$(grep -c 'finished with result' <<< "$_dw" || true)"
assert_contains "[O8] the pipeline workflow hands over the open items" "$_pw" "open_items_outbound"
assert_contains "[O8] ...as a workflow output" "$_pw" 'open_items: ${{ steps.abort.outputs.open_items }}'

print_test_section "O9: the runner says in words why a loop ended the run"
# #1850: the two abort endings are one shared function, _runner_end_on_abort,
# whose lines name the unit ("cycle <id>: the run …").
_rn="$(grep -E '^[[:space:]]*error "(Cycle|Pipeline failed|\$\{_ea_unit)' "$REPO_ROOT/core/pipeline/runner.sh" || true)"
# Not vacuous: the six lines that say a loop ended the run are all found
# (#1944 adds a timed_out arm to _runner_end_on_abort, which is a sixth matching line).
assert_eq "[O9] the runner's six loop-ending lines are found" "6" "$(grep -c . <<< "$_rn" || true)"
assert_eq "[O9] no such line prints rc=N or the reason code" "" \
    "$(grep -E 'rc=\$_rc|reason=\$_(CYCLE_LAST_TERMINATED|RUNNER_CYCLE_UNCONVERGED)_REASON|: scope_too_large' <<< "$_rn" || true)"
assert_eq "[O9] each says why through run_end_words" "$(grep -c . <<< "$_rn")" \
    "$(grep -c 'run_end_words' <<< "$_rn" || true)"

print_test_section "O10 (#2378): only results this run wrote are open items"
# On a rerun hydrate restores the earlier run's results, keeping each file's
# saved time (git archive, then cp -p). A stage that did not run this time
# leaves its old result on disk; it is not this run's open item.
S10="$TEST_TEMP_DIR/s10"; mkdir -p "$S10/artifacts" "$S10/runtime"
stage_result_write "$S10/artifacts/oldgate-result.json" fail "an earlier run's gate failed" >/dev/null 2>&1
touch -t 202601010000 "$S10/artifacts/oldgate-result.json"
: > "$S10/runtime/run-start"
stage_result_write "$S10/artifacts/newgate-result.json" fail "this run's gate failed" >/dev/null 2>&1
_md10="$(open_items_markdown "$S10")"
assert_contains "[O10] a failing result this run wrote is listed" "$_md10" "this run's gate failed"
assert_eq "[O10] an earlier run's restored result is not listed" "0" \
    "$(grep -c "an earlier run's gate failed" <<< "$_md10" || true)"
assert_eq "[O10] the count is this run's items" "1" "$(open_items_count "$S10")"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
