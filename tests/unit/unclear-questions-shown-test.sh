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
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

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
assert_eq "[Q1] id, question, assumption" $'R-2\tDoes --from-stage need --resume?\tit works on its own' "${_q[0]:-}"
assert_eq "[Q1] trimmed" $'R-4\tIs the flag <b>documented</b>?\tno page is needed' "${_q[1]:-}"

print_test_section "Q2: the live run-status comment"
# shellcheck source=../../scripts/lib/run-status-comment.sh
source "$REPO_ROOT/scripts/lib/run-status-comment.sh"
EV="$S/events.jsonl"
jq -cn '{ts:"2026-11-09T10:00:00.000Z", run_id:"r-2508", issue:2508, type:"pipeline.start", data:{run_id:"r-2508", issue:"2508"}, schema_version:1}' > "$EV"
_b="$(ZBUILD_STATUS_NOW=2026-11-09T10:30:00Z rsc_render_body "$EV" "$S")"
assert_contains "[Q2] a questions section while running" "$_b" "Questions design could not settle"
assert_contains "[Q2] each question with what it assumed" "$_b" "- R-2: Does --from-stage need --resume? — assumed: it works on its own"
assert_not_contains "[Q2] text from the model is escaped" "$_b" "<b>"

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
_o="$(open_items_outbound "$S")"
_c="$(run_completion_body failure blocking_member_failure "" "https://x/run/1" "" "$_o" "")"
assert_contains "[Q3] the completion comment shows each question" "$_c" "- R-4: Is the flag"

print_test_section "Q4: the PR description"
# shellcheck source=../../plugins/tool/pr-open/plugin.sh
source "$REPO_ROOT/plugins/tool/pr-open/plugin.sh" >/dev/null 2>&1
_qmd=""
declare -F zb_unclear_markdown >/dev/null 2>&1 && _qmd="$(zb_unclear_markdown "$S/artifacts/design.md")"
_pb="$(_pr_open_compose_body 2508 "" pass "src/x.sh" "" false "" "$_qmd")"
assert_contains "[Q4] the PR description shows each question" "$_pb" "- R-2: Does --from-stage need --resume? — assumed: it works on its own"
# The design is found among the earlier outputs by what it contains (#2364).
jq -n --arg d "$S/artifacts/design.md" '{inputs:{design:$d}}' > "$TEST_TEMP_DIR/inputs.json"
_pq=""
declare -F _pr_open_questions >/dev/null 2>&1 && _pq="$(ZBUILD_STAGE_INPUTS="$TEST_TEMP_DIR/inputs.json" _pr_open_questions)"
assert_contains "[Q4] pr-open finds the design's questions" "$_pq" "- R-4: Is the flag"

print_test_section "Q5: no question, no section"
_b0="$(ZBUILD_STATUS_NOW=2026-11-09T10:30:00Z rsc_render_body "$EV" "$EMPTY")"
assert_not_contains "[Q5] status comment" "$_b0" "Questions design could not settle"
assert_eq "[Q5] no markdown" "" "$(declare -F zb_unclear_markdown >/dev/null 2>&1 && zb_unclear_markdown "$EMPTY/artifacts/design.md")"
assert_not_contains "[Q5] PR description" "$(_pr_open_compose_body 2508 "" pass "src/x.sh" "" false "" "")" "Questions design"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
