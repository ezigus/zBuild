#!/usr/bin/env bash
# tests/unit/gwt-judges-test.sh — design's check and test-author's check judge
# every part of a SPEC, and say which part falls short and why (#2467,
# ADR-073 §5 §6, ADR-072 §3).
#
# Why: on #1805 run 41757933766 test-author's check said BNDY-1's and DLGT-1's
# tests were "partial" three tries running, and design's check had passed both.
# A verdict on the whole SPEC does not say which part is missing, and a SPEC no
# test can prove used up every try before anything said so.
#
# J1 design's check is shown each SPEC's parts as written, and answers a line
#    for each SPEC that is fine and one for each part that is not (#2470)
# J2 every part ok: nothing found, in one call
# J3 a SPEC with no line is asked again, naming it
# J4 a Then a test cannot observe is a finding naming the SPEC, the part and why
# J5 ...untestable only for a Then, duplicate only for a When: asked again
# J6 a part that says how, not what, is a finding
# J7 a SPEC whose Given leaves something behind with no Cleanup is a finding
# J8 a quote that is not in that part's words is asked again, then unusable
# T1 test-author's check is shown the parts as written, and answers a line for
#    a SPEC whose test is right, one for each part it is not, and one for
#    missing sections (#2470)
# T2 every part ok and the sections there: the SPEC corresponds
# T3 a Then not asserted is a finding naming the SPEC, the part and why
# T4 a test without its sections is a finding
# T5 a part the test does something else for is a finding
# T6 a SPEC with no line is asked again on its own, and the answer counts
# T7 ...still none: not judged
# T8 a SPEC no test can prove ends the run at once, naming it as design's to fix
# T9 a SPEC written on one line is judged as one Then, its words
# T10 test-author is told to write the sections, and to rewrite an old test it
#     touches into them
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "every part of a SPEC is judged (#2467)"
setup_test_env "gwt-judges"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export _RUNNER_ENGINE_SHA="engine-a"

_N="$TEST_TEMP_DIR/n"; _P="$TEST_TEMP_DIR/p"
_l() { grep "^$2|" "$1" | head -1 | cut -d'|' -f2-; }

print_test_section "J1-J8: design's check"
(
    # shellcheck source=../../plugins/agent/design/plugin.sh
    source "$REPO_ROOT/plugins/agent/design/plugin.sh"
    route_to_model() {
        local n; n=$(( $(cat "$_N") + 1 )); printf '%s' "$n" > "$_N"; printf '%s' "$2" > "$_P.$n"
        if [[ $n -eq 1 ]]; then printf '%s' "$_R1"; else printf '%s' "${_R2:-$_R1}"; fi
    }
    D="$TEST_TEMP_DIR/j.md"
    cat > "$D" <<'MD'
# Design
```acceptance
FRSH-1[code]: a new run starts from the first stage covers: RQST-1
  Given: a run whose stages all completed
  When: it is started again
  Then: every stage is dispatched
  And: the test file contains both cases
TESTFILES:
FRSH-1: tests/a-test.sh
WIRING: none
```
MD
    REQS='- RQST-1: start from the first stage'
    _cov() { printf 0 > "$_N"; _design_coverage "$D" "$REQS" T2 >/dev/null 2>&1; }
    OK=$'RQST-1: covered\nFRSH-1: ok\n'
    R=$'RQST-1: covered\n'
    _R1="$OK"; _R2=""; _cov
    echo "J1|$(tr -s '[:space:]' ' ' < "$_P.1")"
    echo "J2|$(_design_coverage_findings | grep -c .)|$_DESIGN_COV_OUTCOME|$(cat "$_N")"
    _R1="$R"; _R2="$OK"; _cov
    echo "J3|$(cat "$_N")|$_DESIGN_COV_OUTCOME|$(tr -s '[:space:]' ' ' < "$_P.2" 2>/dev/null)"
    # #2470: a part is named by its word; the quote picks the line.
    _R1="$R"$'FRSH-1 And: untestable | WHY: a test cannot observe what a file contains | QUOTE: "the test file contains both cases"\n'; _R2=""; _cov
    echo "J4|$(_design_coverage_findings | tr '\n\036' '~~')|$_DESIGN_COV_OUTCOME"
    _R1="$R"$'FRSH-1 When: untestable | WHY: x | QUOTE: "it is started again"\n'; _R2="$_R1"; _cov
    echo "J5|$_DESIGN_COV_OUTCOME|$(tr -s '[:space:]' ' ' < "$_P.2" 2>/dev/null)"
    _R1="$R"$'FRSH-1 Then: duplicate | WHY: x | QUOTE: "every stage is dispatched"\n'; _R2="$_R1"; _cov
    echo "J5b|$_DESIGN_COV_OUTCOME"
    _R1="$R"$'FRSH-1 When: how | WHY: it names the call, not what happens | QUOTE: "it is started again"\n'; _R2=""; _cov
    echo "J6|$(_design_coverage_findings | tr '\n\036' '~~')"
    _R1="$R"$'FRSH-1: needs_cleanup | WHY: the run it sets up stays in the state folder | QUOTE: "a run whose stages all completed"\n'; _R2=""; _cov
    echo "J7|$(_design_coverage_findings | tr '\n\036' '~~')"
    _R1="$R"$'FRSH-1 Then: untestable | WHY: x | QUOTE: "it is started again"\n'; _R2="$_R1"; _cov
    echo "J8|$(cat "$_N")|$_DESIGN_COV_OUTCOME|$(tr -s '[:space:]' ' ' < "$_P.2" 2>/dev/null)"
    # Review on #2469: the tests' stand-in for a judge that finds nothing answers
    # every part of a SPEC with parts, as the real judge is asked to.
    route_to_model() { zb_test_coverage_ok "$2"; }
    _cov
    echo "J9|$_DESIGN_COV_OUTCOME|$(_design_coverage_findings | grep -c .)"
) > "$TEST_TEMP_DIR/j.out" 2>/dev/null
J="$TEST_TEMP_DIR/j.out"
assert_contains "[J1] the check is shown each part, as written" "$(_l "$J" J1)" "And: the test file contains both cases"
assert_contains "[J1] ...and asked for one line for a SPEC that is fine" "$(_l "$J" J1)" "<SPEC id>: ok"
assert_contains "[J1] ...and one for each part that is not" "$(_l "$J" J1)" "<SPEC id> <part>: untestable"
assert_eq "[J9] the tests' all-ok judge answers every part (review on #2469)" "|0" "$(_l "$J" J9)"
assert_eq "[J2] every part ok: nothing found, one call" "0||1" "$(_l "$J" J2)"
assert_contains "[J3] a SPEC with no line is asked again" "$(_l "$J" J3)" "2||"
assert_contains "[J3] ...naming it" "$(_l "$J" J3)" "no line for FRSH-1"
assert_contains "[J4] an unobservable Then is a finding naming the SPEC" "$(_l "$J" J4)" "FRSH-1: 1 part to fix"
assert_contains "[J4] ...and marking the part" "$(_l "$J" J4)" "~  And: the test file contains both cases [FIX IN DESIGN:"
assert_contains "[J4] ...and why" "$(_l "$J" J4)" "a test cannot observe what a file contains"
assert_eq "[J5] untestable on a When cannot be used" "unusable" "$(_l "$J" J5 | cut -d'|' -f1)"
assert_contains "[J5] ...and is asked again saying so" "$(_l "$J" J5)" "untestable is only for a Then"
assert_eq "[J5] duplicate on a Then cannot be used" "unusable" "$(_l "$J" J5b)"
assert_contains "[J6] a part that says how is a finding" "$(_l "$J" J6)" "  When: it is started again [FIX IN DESIGN: it names the call, not what happens — say what someone could see happen"
assert_contains "[J7] something left behind with no Cleanup is a finding" "$(_l "$J" J7)" "covers: RQST-1 [FIX IN DESIGN: the run it sets up stays in the state folder"
assert_contains "[J7] ...that asks for a Cleanup line" "$(_l "$J" J7)" "Cleanup:"
assert_contains "[J8] a quote from another part: asked again, then unusable" "$(_l "$J" J8)" "2|unusable|"
assert_contains "[J8] ...saying which" "$(_l "$J" J8)" "FRSH-1 Then's quote is not in"

print_test_section "T1-T9: test-author's check"
(
    # shellcheck source=../../plugins/agent/test-author/plugin.sh
    source "$REPO_ROOT/plugins/agent/test-author/plugin.sh"
    route_to_model() {
        local n; n=$(( $(cat "$_N") + 1 )); printf '%s' "$n" > "$_N"; printf '%s' "$2" > "$_P.$n"
        if [[ $n -eq 1 ]]; then printf '%s' "$_R1"; elif [[ $n -eq 2 ]]; then printf '%s' "${_R2:-$_R1}"; else printf '%s' "${_R3:-${_R2:-$_R1}}"; fi
    }
    R="$TEST_TEMP_DIR/t-repo"; mkdir -p "$R/tests"; D="$TEST_TEMP_DIR/t.md"
    cat > "$D" <<'MD'
# Design
```acceptance
LOOP-1[code]: a nested loop starts at round 1
  Given: an outer loop in round 2
  When: the inner loop is entered again
  Then: the inner loop is at round 1
  And: the outer loop is still at round 2
  Cleanup: ZB_ROUND is unset
DOCS-1[no-code]: the README says how to resume
WIRING: none
TESTFILES:
LOOP-1: tests/loop-test.sh
DOCS-1: tests/loop-test.sh
```
MD
    printf '# Given\nexport ZB_ROUND=2\n# When\nenter_inner\n# Then\nassert_eq "[LOOP-1] inner at 1" "1" "$inner"\nassert_eq "[DOCS-1] readme" "1" "$r"\n# Cleanup\nunset ZB_ROUND\n' > "$R/tests/loop-test.sh"
    _j() { printf 0 > "$_N"; rm -f "$TEST_TEMP_DIR/t-art/test-author-judged.json"; mkdir -p "$TEST_TEMP_DIR/t-art"
           _ta_correspondence "$D" "$R" T2 "$TEST_TEMP_DIR/t-art" >/dev/null 2>&1; }
    OK=$'LOOP-1: ok\nDOCS-1: ok\n'
    _R1="$OK"; _R2=""; _R3=""; _j
    echo "T1|$(tr -s '[:space:]' ' ' < "$_P.1")"
    echo "T2|${#_TA_CORR_FINDINGS[@]}|$_TA_CORR_OUTCOME|$(cat "$_N")"
    _R1=$'DOCS-1: ok\nLOOP-1 And: missing | WHY: nothing asserts the outer round | QUOTE: "the outer loop is still at round 2"\n'; _j
    echo "T3|${#_TA_CORR_FINDINGS[@]}|$(tr '\036' '~' <<< "${_TA_CORR_FINDINGS[0]:-}")|$_TA_CORR_OUTCOME"
    _R1=$'DOCS-1: ok\nLOOP-1 sections: missing | WHY: there is no Cleanup section\n'; _j
    echo "T4|${#_TA_CORR_FINDINGS[@]}|${_TA_CORR_FINDINGS[0]:-}"
    _R1=$'DOCS-1: ok\nLOOP-1 When: wrong | WHY: it enters the outer loop | QUOTE: "the inner loop is entered again"\n'; _j
    echo "T5|${#_TA_CORR_FINDINGS[@]}|$(tr '\036' '~' <<< "${_TA_CORR_FINDINGS[0]:-}")"
    _R1=$'DOCS-1: ok\n'; _R2=$'LOOP-1: ok\n'; _j
    echo "T6|$(cat "$_N")|${#_TA_CORR_FINDINGS[@]}|$_TA_CORR_OUTCOME|$(tr -s '[:space:]' ' ' < "$_P.2" 2>/dev/null)"
    _R1=$'DOCS-1: ok\n'; _R2="$_R1"; _R3="$_R1"; _j
    echo "T7|$(cat "$_N")|$_TA_CORR_OUTCOME|$(tr -s '[:space:]' ' ' < "$_P.3" 2>/dev/null)"
    _R1=$'DOCS-1: ok\nLOOP-1: untestable | WHY: no test can see the outer loop from outside | QUOTE: "the outer loop is still at round 2"\n'; _R2=""; _R3=""; _j
    echo "T8|${_TA_CORR_UNTESTABLE:-}"
    _R1="$OK"; _j
    echo "T9|$([[ "$(cat "$_P.1")" == *"  Then: the README says how to resume"* ]] && echo one-then)"
) > "$TEST_TEMP_DIR/t.out" 2>/dev/null
T="$TEST_TEMP_DIR/t.out"
assert_contains "[T1] the check is shown each part, as written" "$(_l "$T" T1)" "And: the outer loop is still at round 2"
assert_contains "[T1] ...and asked for one line for a SPEC whose test is right" "$(_l "$T" T1)" "<identifier>: ok"
assert_contains "[T1] ...and one for each part it is not" "$(_l "$T" T1)" "<identifier> <part>: missing"
assert_contains "[T1] ...and one for the sections" "$(_l "$T" T1)" "<identifier> sections:"
assert_eq "[T2] every part ok: corresponds, nothing found, one call" "0||1" "$(_l "$T" T2)"
assert_contains "[T3] a Then not asserted is a finding" "$(_l "$T" T3)" "1|LOOP-1: 1 part to fix"
assert_contains "[T3] ...marking the line" "$(_l "$T" T3)" "~  And: the outer loop is still at round 2 [FIX IN TEST: nothing asserts the outer round"
assert_contains "[T3] ...saying why" "$(_l "$T" T3)" "nothing asserts the outer round"
assert_contains "[T4] a test without its sections is a finding" "$(_l "$T" T4)" "1|LOOP-1"
assert_contains "[T4] ...saying what is missing" "$(_l "$T" T4)" "there is no Cleanup section"
assert_contains "[T5] a part the test does something else for is a finding" "$(_l "$T" T5)" "~  When: the inner loop is entered again [FIX IN TEST:"
assert_contains "[T5] ...saying what it does instead" "$(_l "$T" T5)" "it enters the outer loop"
assert_contains "[T6] a missing part line is asked again on its own, and the answer counts" "$(_l "$T" T6)" "2|0||"
assert_contains "[T6] ...naming the SPEC" "$(_l "$T" T6)" "no line for LOOP-1"
assert_contains "[T7] still none: not judged" "$(_l "$T" T7)" "3|unusable|"
assert_contains "[T8] a SPEC no test can prove is named" "$(_l "$T" T8)" "LOOP-1"
assert_contains "[T8] ...with why, marked as design's to fix" "$(_l "$T" T8)" "[FIX IN DESIGN: no test can see the outer loop from outside"
assert_eq "[T9] a one-line SPEC is judged as one Then" "one-then" "$(_l "$T" T9)"

print_test_section "T8: a SPEC no test can prove ends the run"
(
    # shellcheck source=../../plugins/agent/test-author/plugin.sh
    source "$REPO_ROOT/plugins/agent/test-author/plugin.sh"
    d="$TEST_TEMP_DIR/run8"; R="$d/repo"; A="$d/state/artifacts"; mkdir -p "$A" "$R/tests"
    ( cd "$R" && git init -q -b main . && git config user.email t@e.st && git config user.name t \
        && : > tests/acc-test.sh && git add -A && git commit -q -m seed ) >/dev/null 2>&1
    printf '{"schema_version":1}' > "$d/state/pipeline-state.json"
    printf '# Design\n```acceptance\nLOOP-1[code]: a nested loop starts at round 1\n  When: the inner loop is entered again\n  Then: the inner loop is at round 1\nWIRING: none\nTESTFILES:\nLOOP-1: tests/acc-test.sh\n```\n' > "$A/design.md"
    route_to_model_loop() {
        {
            printf '#!/usr/bin/env bash\n'
            printf 'assert_eq() { if [[ "$2" == "$3" ]]; then printf "  ✓ %%s\\n" "$1"; else printf "  ✗ %%s\\n" "$1"; return 1; fi; }\n'
            printf '# Given\n# When\nrc=0\n# Then\n'
            printf 'assert_eq "%s the inner loop is at round 1" "1" "$rc" || exit 1\n' "$(acceptance_spec_tag LOOP-1)"
        } > "$R/tests/acc-test.sh"
        _ROUTE_LOOP_TERMINATED_REASON=done_sentinel; _ROUTE_LOOP_LAST_RESPONSE=LOOP_COMPLETE; return 0
    }
    route_to_model() { printf 'LOOP-1: untestable | WHY: round 1 cannot be seen from outside | QUOTE: "the inner loop is at round 1"\n'; }
    export ZBUILD_REPO_ROOT="$R" ZBUILD_EVENTS_JSONL="$d/events.jsonl"
    test_author_run test-author "$d/state/pipeline-state.json" >/dev/null 2>&1
    echo "T8b|$(jq -r '.outcome' "$A/test-author-result.json" 2>/dev/null)|$(jq -r '.reason' "$A/test-author-result.json" 2>/dev/null)"
) > "$TEST_TEMP_DIR/t8.out" 2>/dev/null
assert_contains "[T8] ...the try ends misconfigured, which stops the run" "$(_l "$TEST_TEMP_DIR/t8.out" T8b)" "misconfigured|"
assert_contains "[T8] ...naming the SPEC as design's to rewrite" "$(_l "$TEST_TEMP_DIR/t8.out" T8b)" "LOOP-1 cannot be proven by any test"

print_test_section "T10: test-author's prompt"
_tp="$(tr -s '[:space:]' ' ' < "$REPO_ROOT/plugins/agent/test-author/plugin.sh")"
assert_contains "[T10] it writes a test in sections" "$_tp" "# Given"
assert_contains "[T10] ...with Cleanup" "$_tp" "Cleanup"
assert_contains "[T10] ...and rewrites an old test it touches into them" "$_tp" "rewrite it into these sections"

cleanup_test_env
print_test_results
