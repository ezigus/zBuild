#!/usr/bin/env bash
# tests/unit/judge-reply-format-test.sh — a judge's reply is read with all its
# formatting and spacing ignored, by every judge's reader (#2474, ADR-072 §3).
#
# Why: #1805 run 42090130741's judge wrote `**RHYD-1** sections: missing`, and
# test-author's reader, which allowed bold in some places only, read 12 of its
# 13 lines as no line at all. The run before broke the same way on italics.
#
# F1 [code]  one shared step reads the same line written plain, in bold or
#            italics, in a list, a quote, a heading, a table row, with code
#            marks, with its labels in bold, or with extra spaces
# F2 [guard] underscores inside a word stay: done_wrong, resume_mode; a WHY's
#            code marks stay
# F3 [code]  test-author's check reads a line whose id alone is in bold
# F4 [code]  design's check reads a line whose id alone is in bold
# F5 [code]  issue-acceptance reads a line whose label is in bold
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "a judge's reply is read with its formatting ignored (#2474)"
setup_test_env "judge-reply-format"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export _RUNNER_ENGINE_SHA="engine-a"
# shellcheck source=../../scripts/lib/judge.sh
source "$REPO_ROOT/scripts/lib/judge.sh"

_l() { grep "^$2|" "$1" | head -1 | cut -d'|' -f2-; }

print_test_section "F1-F2: one shared step"
WANT='LOOP-1 And: missing | WHY: nothing asserts the round | QUOTE: "the outer loop is at round 2"'
_read() { local out=""; judge_reply_line_v out "$1"; printf '%s' "$out"; }
if ! declare -F judge_reply_line_v >/dev/null; then
    assert_fail "[F1] judge.sh has the shared step judge_reply_line_v" "it is not defined"
else
    while IFS= read -r _v; do
        [[ -n "$_v" ]] || continue
        # Given the same answer written with formatting
        # When the shared step reads it
        # Then it reads as the plain line
        assert_eq "[F1] read as the plain line: $_v" "$WANT" "$(_read "$_v")"
    done <<'V'
LOOP-1 And: missing | WHY: nothing asserts the round | QUOTE: "the outer loop is at round 2"
**LOOP-1** And: missing | WHY: nothing asserts the round | QUOTE: "the outer loop is at round 2"
**LOOP-1 And: missing** | WHY: nothing asserts the round | QUOTE: "the outer loop is at round 2"
_LOOP-1_ And: missing | WHY: nothing asserts the round | QUOTE: "the outer loop is at round 2"
*LOOP-1 And*: missing | WHY: nothing asserts the round | QUOTE: "the outer loop is at round 2"
`LOOP-1` And: `missing` | WHY: nothing asserts the round | QUOTE: "the outer loop is at round 2"
- LOOP-1 And: missing | WHY: nothing asserts the round | QUOTE: "the outer loop is at round 2"
  * LOOP-1 And: missing | WHY: nothing asserts the round | QUOTE: "the outer loop is at round 2"
> LOOP-1 And: missing | WHY: nothing asserts the round | QUOTE: "the outer loop is at round 2"
3. LOOP-1 And: missing | WHY: nothing asserts the round | QUOTE: "the outer loop is at round 2"
### LOOP-1 And: missing | WHY: nothing asserts the round | QUOTE: "the outer loop is at round 2"
| LOOP-1 And: missing | WHY: nothing asserts the round | QUOTE: "the outer loop is at round 2" |
| LOOP-1 And | missing | WHY: nothing asserts the round | QUOTE: "the outer loop is at round 2" |
LOOP-1   And:    missing   |   WHY:   nothing asserts the round   |   QUOTE:   "the outer loop is at round 2"
LOOP-1 And: missing **WHY:** nothing asserts the round **QUOTE:** "the outer loop is at round 2"
LOOP-1 And: missing WHY: nothing asserts the round QUOTE: "the outer loop is at round 2"
V
    assert_eq "[F2] an underscore inside a word stays" \
        'FRSH-1: done_wrong | WHY: resume_mode is never read | QUOTE: x.sh:"resume_mode=1"' \
        "$(_read '**FRSH-1**: done_wrong | WHY: resume_mode is never read | QUOTE: x.sh:"resume_mode=1"')"
    assert_eq "[F2] a line with no WHY keeps its words" "LOOP-1: ok" "$(_read '**LOOP-1:** ok')"
    assert_eq "[F2] code marks in the WHY are kept as written" \
        'UNMET: R-10 | WHY: eight files use `set +e` | QUOTE: "no artifact paths"' \
        "$(_read '**UNMET:** R-10 | WHY: eight files use `set +e` | QUOTE: "no artifact paths"')"
fi

print_test_section "F3: test-author's check"
(
    # shellcheck source=../../plugins/agent/test-author/plugin.sh
    source "$REPO_ROOT/plugins/agent/test-author/plugin.sh"
    _N="$TEST_TEMP_DIR/n"; _P="$TEST_TEMP_DIR/p"
    route_to_model() {
        local n; n=$(( $(cat "$_N") + 1 )); printf '%s' "$n" > "$_N"; printf '%s' "$2" > "$_P.$n"
        printf '%s' "$_R1"
    }
    R="$TEST_TEMP_DIR/repo"; mkdir -p "$R/tests"
    ( cd "$R" && git init -q -b main . && git config user.email t@e.st && git config user.name t ) >/dev/null 2>&1
    D="$TEST_TEMP_DIR/t.md"
    cat > "$D" <<'MD'
# Design
```acceptance
LOOP-1[code]: a nested loop starts at round 1
  Given: the outer loop is at round 2
  When: the inner loop is entered again
  Then: the inner loop is at round 1
WIRING: none
TESTFILES:
LOOP-1: tests/loop-test.sh
```
MD
    printf '# Given\nexport ZB_ROUND=2\n# When\nenter_inner\n# Then\nassert_eq "[LOOP-1] inner at 1" "1" "$inner"\n' > "$R/tests/loop-test.sh"
    ( cd "$R" && git add -A && git commit -q -m seed ) >/dev/null 2>&1
    printf 0 > "$_N"; mkdir -p "$TEST_TEMP_DIR/t-art"
    _R1=$'**LOOP-1** When: wrong | WHY: it enters the outer loop | QUOTE: "the inner loop is entered again"\n'
    _ta_correspondence "$D" "$R" T2 "$TEST_TEMP_DIR/t-art" >/dev/null 2>&1
    echo "F3|$(cat "$_N")|${#_TA_CORR_FINDINGS[@]}|$(tr '\036' '~' <<< "${_TA_CORR_FINDINGS[0]:-}")"
) > "$TEST_TEMP_DIR/f3.out" 2>/dev/null
# Then the line counts: one call, one finding saying what the judge said
assert_contains "[F3] a bold id is read: one call, one finding" "$(_l "$TEST_TEMP_DIR/f3.out" F3)" "1|1|LOOP-1"
assert_contains "[F3] ...with the judge's words" "$(_l "$TEST_TEMP_DIR/f3.out" F3)" "it enters the outer loop"

print_test_section "F4: design's check"
(
    # shellcheck source=../../plugins/agent/design/plugin.sh
    source "$REPO_ROOT/plugins/agent/design/plugin.sh"
    _N="$TEST_TEMP_DIR/dn"
    route_to_model() { local n; n=$(( $(cat "$_N") + 1 )); printf '%s' "$n" > "$_N"; printf '%s' "$_R1"; }
    D="$TEST_TEMP_DIR/d.md"
    cat > "$D" <<'MD'
# Design
```acceptance
FRSH-1[code]: a new run starts from the first stage covers: RQST-1
  Given: a run whose stages all completed
  When: it is started again
  Then: every stage is dispatched
TESTFILES:
FRSH-1: tests/a-test.sh
WIRING: none
```
MD
    printf 0 > "$_N"
    _R1=$'**RQST-1**: covered\n**FRSH-1** When: how | WHY: it names the call, not what happens | QUOTE: "it is started again"\n'
    _design_coverage "$D" '- RQST-1: start from the first stage' T2 >/dev/null 2>&1
    echo "F4|$(cat "$_N")|$_DESIGN_COV_OUTCOME|$(_design_coverage_findings | tr '\n\036' '~~')"
) > "$TEST_TEMP_DIR/f4.out" 2>/dev/null
assert_contains "[F4] bold ids are read: one call" "$(_l "$TEST_TEMP_DIR/f4.out" F4)" "1|"
assert_contains "[F4] ...and the part's finding is made" "$(_l "$TEST_TEMP_DIR/f4.out" F4)" "it names the call, not what happens"

print_test_section "F5: issue-acceptance"
(
    # shellcheck source=../../plugins/agent/issue-acceptance/plugin.sh
    source "$REPO_ROOT/plugins/agent/issue-acceptance/plugin.sh"
    _ia_parse $'**UNMET:** [fix-code] RQST-1 | WHY: the run starts at stage 2 | QUOTE: "start from the first stage"\n' \
        '- RQST-1: start from the first stage' 'start from the first stage' "$TEST_TEMP_DIR"
    echo "F5|${_IA_PROBLEM:-none}|${#_IA_UNMET[@]}|${_IA_UNMET[0]:-}"
) > "$TEST_TEMP_DIR/f5.out" 2>/dev/null
assert_contains "[F5] a bold label is read: no problem, one unmet requirement" "$(_l "$TEST_TEMP_DIR/f5.out" F5)" "none|1|"
assert_contains "[F5] ...with the judge's words" "$(_l "$TEST_TEMP_DIR/f5.out" F5)" "the run starts at stage 2"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
