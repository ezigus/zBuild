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
# O2 [code] the report written when no stage could act on an item is what the
#           other reports list, in the same words
# O3 [code] the end reason a reader sees is words, never the engine's code:
#           "stopped with 1 open item", "ran out of rounds with 2 open items"
# O4 [code] the issue completion comment lists each open item, not a bare
#           `failure`; with nothing recorded it still says what happened
# O5 [code] the live status comment, once the run has ended, lists each open
#           item under the end reason in words
# O6 [code] the end-of-run banner says why the run stopped and lists the items
# O7 [code] guard: none of the reports above contains an internal term, a raw
#           code or number, or "a person" / "human" wording
# O8 [code] the completion comment workflow builds its body from O4, and the
#           pipeline workflow hands it the run's open items
# O10 [code] a loop that stops on its last round with items no stage could act
#           on says so in its banner: it did not end early
# O9 [code] the runner's lines that say a loop ended the run say why in words
#           (run_end_words), not as "rc=N reason=<code>"
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
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
# shellcheck source=../../core/pipeline/unowned.sh
source "$REPO_ROOT/core/pipeline/unowned.sh"

_GUARDED=""   # every report text produced below, for O7
_guard() { _GUARDED+=$'\n'"$1"; }

# ─── a state dir that ended on failing checks ───────────────────────────────
# An existing state dir with nothing in it. It must exist: with TMPDIR unset
# (Linux CI) the status renderer makes its temp file inside the state dir.
mkdir -p "$TEST_TEMP_DIR/empty"
S1="$TEST_TEMP_DIR/s1"; mkdir -p "$S1/artifacts"
jq -n '{result_contract:2, verdict:"fail", reason:"not sure one requirement is met",
        data:{unsure:["R-1: the flag is documented"],
              findings:[{n:1, text:"Not sure this requirement is met: R-1: the flag is documented. What would settle it: a test that fails when the flag is not documented, or the page that documents it."}]}}' \
    > "$S1/artifacts/judge-result.json"
jq -n '{result_contract:2, verdict:"fail", reason:"one test failed",
        data:{findings:[{n:1, text:"tests/unit/foo-test.sh fails: expected 3, got 2"}]}}' \
    > "$S1/artifacts/tests-result.json"
jq -n '{result_contract:2, verdict:"fail", reason:"the secret scan could not read the diff", data:{}}' \
    > "$S1/artifacts/scan-result.json"
jq -n '{result_contract:2, verdict:"pass", reason:"all good", data:{findings:[{n:1, text:"PASSING CHECK TEXT"}]}}' \
    > "$S1/artifacts/ok-result.json"
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

print_test_section "O2: the report for items no stage could act on is the shared list"
S2="$TEST_TEMP_DIR/s2"; mkdir -p "$S2/artifacts"
jq -n '{result_contract:2, verdict:"fail", data:{findings:[{n:1, text:"config/x.json is not the file that calls the new code"}]}}' \
    > "$S2/artifacts/acc-result.json"
_unowned_report "$S2" '["acc finding 1"]' \
    '[{"ref":"acc finding 1","by":"build","answer":"nothing to do","why":"the code passes the tests it was given"}]' halt
_rep="$(cat "$S2/artifacts/unowned-findings.md" 2>/dev/null)"; _guard "$_rep"
assert_contains "[O2] the report names the item" "$_rep" "acc finding 1"
assert_contains "[O2] ...what is unresolved" "$_rep" "config/x.json is not the file that calls the new code"
assert_contains "[O2] ...what would settle it" "$_rep" "What would settle it:"
assert_contains "[O2] ...and each answer with its why" "$_rep" "build: nothing to do — the code passes the tests it was given"
_md2="$(open_items_markdown "$S2")"
assert_contains "[O2] the other reports list the same item" "$_md2" "config/x.json is not the file that calls the new code"
assert_eq "[O2] ...and only the items the report names" "1" "$(open_items_count "$S2")"

print_test_section "O2b: a check not sure of one item reports that item, not its others"
S3="$TEST_TEMP_DIR/s3"; mkdir -p "$S3/artifacts"
jq -n '{result_contract:2, verdict:"fail",
        data:{unsure:["R-2: the flag is documented"],
              findings:[{n:1, text:"The issue requires this and the change does not meet it: R-1: the command exits 2"},
                        {n:2, text:"Not sure this requirement is met: R-2: the flag is documented. What would settle it: a test."}]}}' \
    > "$S3/artifacts/judge-result.json"
_unowned_last_round_report "$S3"; _rc3=$?
_rep3="$(cat "$S3/artifacts/unowned-findings.md" 2>/dev/null)"
assert_eq "[O2b] the report is written" "0" "$_rc3"
assert_contains "[O2b] it names the item the check is not sure of" "$_rep3" "judge finding 2"
assert_eq "[O2b] ...and not the check's other finding" "0" "$(grep -c 'judge finding 1' <<< "$_rep3" || true)"
assert_eq "[O2b] ...so one item is open" "1" "$(open_items_count "$S3")"
S4="$TEST_TEMP_DIR/s4"; mkdir -p "$S4/artifacts"
jq -n '{result_contract:2, verdict:"Passed", data:{unsure:["R-1: x"], findings:[{n:1, text:"Not sure this requirement is met: R-1: x"}]}}' \
    > "$S4/artifacts/judge-result.json"
_unowned_last_round_report "$S4"; _rc4=$?
assert_eq "[O2b] a passing check is never open, whatever case its verdict is in (same rule as the list)" "1" "$_rc4"

print_test_section "O3: the end reason is words"
_w1="$(run_end_words unowned_finding 1)"; _guard "$_w1"
assert_contains "[O3] items no stage could act on" "$_w1" "stopped with 1 open item"
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
for _r in stage_failed:fail max_iterations_tests_failing unowned_finding blocking_member_failure member_terminal_failure \
          blocked blocked_on_scope cycle_abort sigint sigterm llm_rate_limited llm_unavailable \
          scope_too_large design_timeout_exhausted no_committed_changes some_new_code ""; do
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
jq -cn '{ts:"2026-10-06T11:00:00.000Z", run_id:"r-2330", issue:2330, type:"pipeline.end", data:{status:"failed", reason:"unowned_finding"}, schema_version:1}' >> "$EV"
_b="$(ZBUILD_STATUS_NOW=2026-10-06T11:00:00Z rsc_render_body "$EV" "$S1")"; _guard "$_b"
assert_contains "[O5] the end reason in words" "$_b" "Stopped with 3 open items"
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
    _CYCLE_LAST_TERMINATED_REASON=unowned_finding
    _render_pipeline_end failed
" 2>&1)"; _guard "$_e"
assert_contains "[O6] the banner says why the run stopped" "$_e" "stopped with 3 open items"
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
_rn="$(grep -E '^[[:space:]]*error "(Cycle|Pipeline failed)' "$REPO_ROOT/core/pipeline/runner.sh" || true)"
# Not vacuous: the five lines that say a loop ended the run are all found.
assert_eq "[O9] the runner's five loop-ending lines are found" "5" "$(grep -c . <<< "$_rn" || true)"
assert_eq "[O9] no such line prints rc=N or the reason code" "" \
    "$(grep -E 'rc=\$_rc|reason=\$_(CYCLE_LAST_TERMINATED|RUNNER_CYCLE_UNCONVERGED)_REASON|: scope_too_large' <<< "$_rn" || true)"
assert_eq "[O9] each says why through run_end_words" "$(grep -c . <<< "$_rn")" \
    "$(grep -c 'run_end_words' <<< "$_rn" || true)"

print_test_section "O10: the last-round stop is not called early"
_cb="$(bash -c "
    export NO_COLOR=1 ZBUILD_TERM_WIDTH_OVERRIDE=80
    export ZBUILD_STATE_DIR='$TEST_TEMP_DIR/rs' ZBUILD_EVENTS_DIR='$TEST_TEMP_DIR/ev'
    export ZBUILD_EVENTS_JSONL='$TEST_TEMP_DIR/ev/events.jsonl'
    source '$REPO_ROOT/core/pipeline/runner.sh'
    _render_cycle_exit delivery_loop unowned_finding 2 2
" 2>&1)"; _guard "$_cb"
assert_eq "[O10] the banner does not say it ended early" "0" "$(grep -c 'ended early' <<< "$_cb" || true)"
assert_contains "[O10] ...it says it stopped with items no stage could act on" "$_cb" "no stage could act on"
_guard_bad="$(plain_report_violations "$_cb")"
assert_eq "[O10] ...in plain words" "" "$_guard_bad"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
