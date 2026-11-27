#!/usr/bin/env bash
# tests/unit/unclear-questions-shown-test.sh — a requirement design did not
# understand is asked, not guessed in silence (#2508, ADR-064 §4, ADR-040).
#
# Why: #1805 run 42556446368 — whether `--from-stage` needs `--resume` was not
# in the issue. Design never said it had to decide, and issue-acceptance read
# it one way in one run and the other way in the next. Design now writes
# `UNCLEAR: <id> | <the question> | <what it assumed>` and carries on with the
# assumption; the question must reach the people who can answer it.
#
# Q1 [code] the reader lists each well-formed UNCLEAR line of design.md as
#           id, question and assumption; a line inside a fenced block, and one
#           missing a part, is not a question
# Q2 [code] the live run-status comment shows each question while the run is
#           still running
# Q3 [code] (ADR-068 §8) the report of a failed run shows each question: the end-of-run
#           banner and the issue's completion comment
# Q4 [code] the PR description shows each question (ADR-040)
# Q5 [code] with no question, none of them has a questions section
# Q7 [change] (review on #2567) an UNCLEAR whose assumption is only the word
#            Assumed: is not a question; a leading Assumed: is set aside
# Q6 [change] (#2567) a question design wrapped over lines is read whole: its
#            assumption on the next line is kept, the prose after a blank line
#            is not, and a wrapped line inside a block is still no question
# Q8 [change] (#2571, ADR-069 §12) every stage's open questions are shown, not
#            only design's: a question in the one form in a stage's result
#            (data.unclear, written with the shared writer) reaches the
#            run-status comment, the failed run's report and the PR description,
#            under the stage's name, with its quote and assumption
# Q9 [change] (#2571) a result an earlier run left (older than this run's start)
#            is not this run's; the status comment reads the questions with no
#            program run (it renders on every tick)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"

print_test_header "questions design could not settle are shown (#2508)"
setup_test_env "unclear-questions"
assert_not_contains() {
    if grep -qF -- "$3" <<< "$2"; then assert_fail "$1" "found: $3"; else assert_pass "$1"; fi
}

# design.md is written by the model; the UNCLEAR line is the shape its prompt
# asks for.
S="$TEST_TEMP_DIR/s"; mkdir -p "$S/artifacts"
cat > "$S/artifacts/design.md" <<'EOF'
# Design

UNCLEAR: R-2 | Does --from-stage need --resume? | it works on its own
  UNCLEAR:  R-4  |  Is the flag <b>documented</b>?  |  no page is needed
UNCLEAR: R-9 | only a question, no assumption

```acceptance
UNCLEAR: R-7 | inside a block | not a question
DSFLAG-1[code]: the flag works
```
EOF
EMPTY="$TEST_TEMP_DIR/e"; mkdir -p "$EMPTY/artifacts"
printf '# Design\n\nNothing unclear.\n' > "$EMPTY/artifacts/design.md"

print_test_section "Q1: the reader"
if [[ -f "$REPO_ROOT/scripts/lib/unclear.sh" ]]; then
    # shellcheck source=../../scripts/lib/unclear.sh
    source "$REPO_ROOT/scripts/lib/unclear.sh"
fi
_q=()
if declare -F zb_unclear_list_v >/dev/null 2>&1; then zb_unclear_list_v _q "$S/artifacts/design.md"; fi
assert_eq "[Q1] two well-formed questions" "2" "${#_q[@]}"
# #2571: id, quote, readings, assumption and form — an old line's question is its readings.
assert_eq "[Q1] id, question, assumption" $'R-2\t\tDoes --from-stage need --resume?\tit works on its own\told' "${_q[0]:-}"
assert_eq "[Q1] trimmed" $'R-4\t\tIs the flag <b>documented</b>?\tno page is needed\told' "${_q[1]:-}"

print_test_section "Q6: a wrapped question is read whole"
# #1764 run 44417314654: design wrapped its assumption onto the next line.
W="$TEST_TEMP_DIR/w"; mkdir -p "$W/artifacts"
cat > "$W/artifacts/design.md" <<'EOF'
# Design

UNCLEAR: RQADR-2 | "the holder is in the run-status comment" — which comment is this? | Assumed:
the ADR-064 run-status comment (`scripts/lib/run-status-comment.sh`), not a new one.

The claim lives in the coordinator plugin.

```acceptance
UNCLEAR: R-7 | inside a block |
not a question
DSFLAG-1[code]: the flag works
```
EOF
_w=()
declare -F zb_unclear_list_v >/dev/null 2>&1 && zb_unclear_list_v _w "$W/artifacts/design.md"
assert_eq "[Q6] one question, outside the block" "1" "${#_w[@]}"
assert_eq "[Q6] its assumption whole, the next line included, the word Assumed: set aside" \
    $'RQADR-2\t\t"the holder is in the run-status comment" — which comment is this?\tthe ADR-064 run-status comment (`scripts/lib/run-status-comment.sh`), not a new one.\told' "${_w[0]:-}"
assert_not_contains "[Q6] the prose after the blank line is not part of it" "${_w[0]:-}" "coordinator plugin"

print_test_section "Q7: a question with no assumption is not one"
B="$TEST_TEMP_DIR/b"; mkdir -p "$B/artifacts"
cat > "$B/artifacts/design.md" <<'EOF'
# Design

UNCLEAR: R-3 | is it bare? | Assumed:

UNCLEAR: R-4 | is it led by a hash? | Assumed:
#2460's reader joins it

UNCLEAR: R-5 | is it led by a dash? | Assumed:
- the existing one

UNCLEAR: R-6 | is it whole? | Assumed: it is
EOF
_q7=()
zb_unclear_list_v _q7 "$B/artifacts/design.md"
assert_eq "[Q7] only the question with an assumption is listed" "1" "${#_q7[@]}"
assert_eq "[Q7] ...its assumption without the word Assumed:" $'R-6\t\tis it whole?\tit is\told' "${_q7[0]:-}"

# _shown <markdown> — what GitHub shows: CommonMark's backslash escapes read
# as the character, the zero-width spaces that stop a mention or a link gone.
_shown() { local s="${1//$'\xe2\x80\x8b'/}"; perl -pe 's/\\([!-\/:-@\[-`{-~])/$1/g' <<< "$s"; }

print_test_section "Q2: the live run-status comment"
# shellcheck source=../../scripts/lib/run-status-comment.sh
source "$REPO_ROOT/scripts/lib/run-status-comment.sh"
EV="$S/events.jsonl"
jq -cn '{ts:"2026-11-09T10:00:00.000Z", run_id:"r-2508", issue:2508, type:"pipeline.start", data:{run_id:"r-2508", issue:"2508"}, schema_version:1}' > "$EV"
_b="$(ZBUILD_STATUS_NOW=2026-11-09T10:30:00Z rsc_render_body "$EV" "$S")"
assert_contains "[Q2] a questions section while running" "$_b" "Questions design could not settle"
assert_contains "[Q2] each question with what it assumed" "$(_shown "$_b")" "- R-2: Does --from-stage need --resume? — assumed: it works on its own"
assert_not_contains "[Q2] text from the model is escaped" "$_b" "<b>"
assert_contains "[Q2] ...shown as written: escaped for markdown" "$_b" "R\\-2"

print_test_section "Q3: the report of a failed run"
_e="$(bash -c "
    export NO_COLOR=1 ZBUILD_TERM_WIDTH_OVERRIDE=80 ZBUILD_STAGE_IO_NOW_MS_OVERRIDE=12345000
    export ZBUILD_STATE_DIR='$TEST_TEMP_DIR/rs' ZBUILD_EVENTS_DIR='$TEST_TEMP_DIR/ev'
    export ZBUILD_EVENTS_JSONL='$TEST_TEMP_DIR/ev/events.jsonl'
    mkdir -p \"\$ZBUILD_STATE_DIR\" \"\$ZBUILD_EVENTS_DIR\"
    source '$REPO_ROOT/core/pipeline/runner.sh'
    _runner_run_id=r1; _runner_issue=2508; _RUNNER_PIPELINE_START_MS=12344600
    _runner_state_file='$S/pipeline-state.json'
    _CYCLE_LAST_TERMINATED_REASON=blocking_member_failure
    _render_pipeline_end failed
" 2>&1)"
assert_contains "[Q3] the end-of-run banner shows each question" "$_e" "- R-2: Does --from-stage need --resume? — assumed: it works on its own"
assert_contains "[Q3] ...as written, not escaped for markdown (a terminal shows no markdown)" "$_e" "- R-4: Is the flag <b>documented</b>? — assumed: no page is needed"
_o="$(open_items_outbound "$S")"
_c="$(run_completion_body failure blocking_member_failure "" "https://x/run/1" "" "$_o" "")"
assert_contains "[Q3] the completion comment shows each question" "$(_shown "$_c")" "- R-4: Is the flag"
assert_contains "[Q3] ...escaped for GitHub" "$_c" "R\\-4"

print_test_section "Q4: the PR description"
# shellcheck source=../../plugins/tool/pr-open/plugin.sh
source "$REPO_ROOT/plugins/tool/pr-open/plugin.sh" >/dev/null 2>&1
_qmd=""
declare -F zb_unclear_markdown >/dev/null 2>&1 && _qmd="$(zb_unclear_markdown "$S/artifacts/design.md")"
_pb="$(_pr_open_compose_body 2508 "" pass "src/x.sh" "" false "" "$_qmd")"
assert_contains "[Q4] the PR description shows each question" "$(_shown "$_pb")" "- R-2: Does --from-stage need --resume? — assumed: it works on its own"
assert_contains "[Q4] ...escaped for GitHub" "$_pb" "R\\-2"
# The design is found among the earlier outputs by what it contains (#2364).
jq -n --arg d "$S/artifacts/design.md" '{inputs:{design:$d}}' > "$TEST_TEMP_DIR/inputs.json"
_pq=""
declare -F _pr_open_questions >/dev/null 2>&1 && _pq="$(ZBUILD_STAGE_INPUTS="$TEST_TEMP_DIR/inputs.json" _pr_open_questions)"
assert_contains "[Q4] pr-open finds the design's questions" "$(_shown "$_pq")" "- R-4: Is the flag"

print_test_section "Q8: every stage's questions"
# shellcheck source=../../scripts/lib/stage-result.sh
source "$REPO_ROOT/scripts/lib/stage-result.sh"
Q8L='UNCLEAR RQCL-3 | "the label is set early" | before the first stage, or before design | ASSUMED: before the first stage'
declare -a _q8=("$Q8L"); _q8j="[]"
declare -F zb_unclear_result_json_v >/dev/null 2>&1 && zb_unclear_result_json_v _q8j _q8
stage_result_write "$S/artifacts/intake-result.json" pass "took in the issue" "$(jq -nc --argjson u "$_q8j" '{goal_len: 1, unclear: $u}')"
Q8MD='- RQCL-3: "the label is set early" — before the first stage, or before design — assumed: before the first stage'
_b8="$(ZBUILD_STATUS_NOW=2026-11-09T10:30:00Z rsc_render_body "$EV" "$S")"
assert_contains "[Q8] status comment: intake's questions, under its name" "$_b8" "**Questions intake could not settle**"
assert_contains "[Q8] ...each with its quote, readings and assumption" "$(_shown "$_b8")" "$Q8MD"
assert_contains "[Q8] ...design's still shown" "$(_shown "$_b8")" "- R-2: Does --from-stage need --resume? — assumed: it works on its own"
_o8="$(open_items_outbound "$S")"
assert_contains "[Q8] the failed run's report" "$(_shown "$_o8")" "$Q8MD"
jq -n --arg d "$S/artifacts/design.md" --arg r "$S/artifacts/intake-result.json" '{inputs:{design:$d, intake_result:$r}}' > "$TEST_TEMP_DIR/inputs8.json"
_pq8=""
declare -F _pr_open_questions >/dev/null 2>&1 && _pq8="$(ZBUILD_STAGE_INPUTS="$TEST_TEMP_DIR/inputs8.json" _pr_open_questions)"
assert_contains "[Q8] the PR description" "$(_shown "$_pq8")" "$Q8MD"
assert_contains "[Q8] ...and design's" "$(_shown "$_pq8")" "- R-4: Is the flag"

print_test_section "Q9: this run's, with no program run"
mkdir -p "$S/runtime"; touch "$S/runtime/run-start"
touch -t 202001010000 "$S/artifacts/intake-result.json"
_q9=""; open_items_questions_v _q9 "$S"
assert_not_contains "[Q9] a result from before this run is not shown" "$(_shown "$_q9")" "RQCL-3"
touch "$S/artifacts/intake-result.json"
_q9=""; PATH=/nonexistent open_items_questions_v _q9 "$S"
assert_contains "[Q9] read with no program run" "$(_shown "$_q9")" "$Q8MD"
rm -f "$S/runtime/run-start" "$S/artifacts/intake-result.json"

print_test_section "Q5: no question, no section"
_b0="$(ZBUILD_STATUS_NOW=2026-11-09T10:30:00Z rsc_render_body "$EV" "$EMPTY")"
assert_not_contains "[Q5] status comment" "$_b0" "Questions design could not settle"
assert_eq "[Q5] no markdown" "" "$(declare -F zb_unclear_markdown >/dev/null 2>&1 && zb_unclear_markdown "$EMPTY/artifacts/design.md")"
assert_not_contains "[Q5] PR description" "$(_pr_open_compose_body 2508 "" pass "src/x.sh" "" false "" "")" "Questions design"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
