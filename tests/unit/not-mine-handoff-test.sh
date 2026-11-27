#!/usr/bin/env bash
# tests/unit/not-mine-handoff-test.sh — a finding reaches the stage that can fix
# it (#2599, ADR-068 §6, ADR-071 §1).
#
# #2532 run 45231040380: four lens findings stayed open through both rounds.
# Three were about test files, marked fix: code, so they went to build, which
# answered "not mine — test-author must fix"; one was about an ADR, marked
# fix: test, so it went to test-author, which answered "not mine — the code
# stage must …". Both stages passed, so neither answer was handed on.
#
# N1 [change] a lens finding about a file in the test folders goes to
#             test-author, though the lens marked it fix: code
# N2 [guard]  ...one about any other file goes to build, as marked
# N3 [change] build's "not mine" naming a test file or test-author is handed to
#             test-author, in any words
# N4 [guard]  ...one naming neither is not
# N5 [change] test-author's "not mine" naming a file outside the test folders,
#             or the code, is handed to build
# N6 [change] a finding build handed to test-author that test-author answers
#             "not mine" goes to design, never back to build
# N7 [change] test-author is told the form that hands a finding to build, in
#             its composed prompt; build is told the design form
# (review on #2599)
# N8 [change] a "<stage> must" the answer names decides, before any file it
#             names; "design must" goes to design, from either stage
# N9 [change] a finding test-author handed to build that build answers "not
#             mine" goes to design, never back
# N10 [change] the words are read in any case ("Not mine — The code must…")
# N11 [change] a finding handed on keeps its id and its text, beside the answer
# N12 [guard]  a stage's own check's finding is left to the old path
# N13 [change] a backslash or a [class] in the test folders list is read as
#             bash reads it, and a list that cannot be read routes nothing
# N14 [change] a fix: design finding about a test file goes to test-author too
# N15 [change] build's design hand-off is written fresh each try: none, no file
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "a finding reaches the stage that can fix it (#2599)"
setup_test_env "not-mine-handoff"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"
R="$TEST_TEMP_DIR/repo"; mkdir -p "$R/core" "$R/tests/unit"
printf 'one line\n' > "$R/core/x.sh"; printf 'guard line\n' > "$R/tests/unit/guard-test.sh"
export ZBUILD_REPO_ROOT="$R"

print_test_section "N1-N2: a lens finding about a test file"
(
    # shellcheck source=../../core/plugin-registry/registry.sh
    source "$REPO_ROOT/core/plugin-registry/registry.sh"
    # shellcheck source=../../plugins/agent/review-lens/plugin.sh
    source "$REPO_ROOT/plugins/agent/review-lens/plugin.sh"
    zb_test_lens_jobs n1 >/dev/null 2>&1
    route_to_model() { zb_test_lens_check_answer "$2" && return 0
        printf 'SCORE: 4\nFINDING\nseverity: medium\ncategory: logic\nfix: code\nintroduced: yes\nquote: tests/unit/guard-test.sh | guard line\nmessage: TEST-FILE-FINDING\ntrigger: t\naccepted if: a\nFINDING\nseverity: medium\ncategory: logic\nfix: code\nintroduced: yes\nquote: core/x.sh | one line\nmessage: CODE-FILE-FINDING\ntrigger: t\naccepted if: a\n'; }
    A="$TEST_TEMP_DIR/art1"; mkdir -p "$A"; printf 'diff --git a/core/x.sh b/core/x.sh\n+one line\n' > "$A/diff.patch"
    ( cd "$R" && ZBUILD_CURRENT_STAGE=review_lenses ZBUILD_REVIEW_LENS_ID=n1 _TPL_STAGE_FAIL_ON_review_lenses="medium high critical" \
        _review_lens_run_inner n1 "" "$A/diff.patch" "$A/lens-n1.json" "$A" ) >/dev/null 2>&1
    echo "N1|$(cat "$A/lens-n1-test-result.json" 2>/dev/null | tr -d '\n')"
    echo "N2|$(cat "$A/lens-n1-code-result.json" 2>/dev/null | tr -d '\n')"
) > "$TEST_TEMP_DIR/n12.out" 2>/dev/null
_l() { grep "^$1|" "$TEST_TEMP_DIR/$2" | sed -n 1p | cut -d'|' -f2-; }
assert_contains "[N1] the test file's finding goes to test-author" "$(_l N1 n12.out)" "TEST-FILE-FINDING"
_n2="$(_l N2 n12.out)"
assert_contains "[N2] the code file's goes to build" "$_n2" "CODE-FILE-FINDING"
if [[ "$_n2" == *TEST-FILE-FINDING* ]]; then assert_fail "[N1] ...and not to build" "$_n2"; else assert_pass "[N1] ...and not to build"; fi

print_test_section "N3-N4: build's not mine"
(
    # shellcheck source=../../plugins/agent/build/plugin.sh
    source "$REPO_ROOT/plugins/agent/build/plugin.sh" >/dev/null 2>&1
    echo "N3|$(_build_test_wrong $'ANSWER RLRT-5: not mine — the scan logic lives in tests/unit/guard-test.sh, a test file this stage cannot modify; the test-author stage must fix it\n' | tr '\n' '~')"
    echo "N3b|$(_build_test_wrong $'ANSWER RLSC-1: not mine — the assert strings are in a test; test-author must update them\n' | tr '\n' '~')"
    echo "N4|$(_build_test_wrong $'ANSWER RLRT-9: not mine — design must decide which platforms are valid\n' | tr '\n' '~')"
) > "$TEST_TEMP_DIR/n34.out" 2>/dev/null
assert_contains "[N3] a not mine naming a test file is handed to test-author" "$(_l N3 n34.out)" "RLRT-5: tests/unit/guard-test.sh:"
assert_contains "[N3] ...as is one naming test-author" "$(_l N3b n34.out)" "RLSC-1:"
assert_eq "[N4] one naming no test and no test-author is not handed to test-author" "" "$(_l N4 n34.out)"

print_test_section "N5-N7: test-author's not mine"
(
    # shellcheck source=../../plugins/agent/test-author/plugin.sh
    source "$REPO_ROOT/plugins/agent/test-author/plugin.sh" >/dev/null 2>&1
    A="$TEST_TEMP_DIR/art5"; mkdir -p "$A"
    _ta_write_code_findings "$A" $'ANSWER RLRT-7: not mine — the fix is in docs/adr/ADR-009.md: the code stage must reference map-strategy-test.sh\nANSWER RLRT-8: done — added the test\nANSWER BUFND-3: not mine — the code must change: core/x.sh: the guard reads it\n'
    echo "N5|$(cat "$A/test-author-code-result.json" 2>/dev/null | tr -d '\n')"
    echo "N6|$(cat "$A/test-author-design-result.json" 2>/dev/null | tr -d '\n')"
    echo "N7|$(declare -f test_author_run | tr -s '[:space:]' ' ')"
) > "$TEST_TEMP_DIR/n57.out" 2>/dev/null
_n5="$(_l N5 n57.out)"
assert_contains "[N5] test-author's not mine naming another file is handed to build" "$_n5" "RLRT-7"
if [[ "$_n5" == *RLRT-8* ]]; then assert_fail "[N5] ...a done is not" "$_n5"; else assert_pass "[N5] ...a done is not"; fi
if [[ "$_n5" == *BUFND-3* ]]; then assert_fail "[N6] a finding build handed on is not handed back" "$_n5"; else assert_pass "[N6] a finding build handed on is not handed back"; fi
assert_contains "[N6] ...it goes to design" "$(_l N6 n57.out)" "BUFND-3"
assert_contains "[N7] test-author is told the form, in its prompt" "$(_l N7 n57.out)" "not mine — the code must change: <file>: <why>"

print_test_section "N8-N12: the stage named, bounces, case, ids"
(
    # shellcheck source=../../scripts/lib/stage-answers.sh
    source "$REPO_ROOT/scripts/lib/stage-answers.sh"; source "$REPO_ROOT/scripts/lib/test-paths.sh"
    _t() { local v; zb_not_mine_target_v v "$1"; printf '%s' "$v"; }
    echo "N8a|$(_t 'not mine — design must change SPEC-3, which core/x.sh cannot meet')"
    echo "N8b|$(_t 'not mine — design must change SPEC-2; tests/unit/guard-test.sh only shows the symptom')"
    echo "N8c|$(_t 'not mine — the fix is in docs/adr/ADR-009.md')"
    echo "N8d|$(_t 'not mine — tests/unit/guard-test.sh holds it')"
    echo "N10|$(_t 'Not mine — The code must change: core/x.sh: why')"
) > "$TEST_TEMP_DIR/n8.out" 2>/dev/null
assert_eq "[N8] design must, with a code file: design" "design" "$(_l N8a n8.out)"
assert_eq "[N8] design must, with a test file: design" "design" "$(_l N8b n8.out)"
assert_eq "[N8] only a code file: code" "code" "$(_l N8c n8.out)"
assert_eq "[N8] only a test file: test" "test" "$(_l N8d n8.out)"
assert_eq "[N10] any case" "code" "$(_l N10 n8.out)"
(
    source "$REPO_ROOT/plugins/agent/build/plugin.sh" >/dev/null 2>&1
    A="$TEST_TEMP_DIR/art9"; mkdir -p "$A"
    declare -gA _ZB_ANS_FINDING=([TAFND-4]="lens red-team: the guard misses a form" [RLRT-2]="lens: SPEC-2 cannot be met")
    _build_write_handoffs "$A" $'ANSWER TAFND-4: not mine — tests/unit/guard-test.sh holds it; test-author must fix it\nANSWER RLRT-2: not mine — design must change SPEC-2\nANSWER BUFND-1: not mine — the test must change: tests/unit/guard-test.sh: it pins the old\n'
    echo "N9|$(cat "$A/build-tests-result.json" 2>/dev/null | tr -d '\n')"
    echo "N9d|$(cat "$A/build-design-result.json" 2>/dev/null | tr -d '\n')"
    _build_write_handoffs "$A" $'ANSWER RLRT-3: done — changed it\n'
    echo "N15|$([[ -e "$A/build-design-result.json" ]] && echo stale || echo gone)"
    echo "N7b|$(declare -f _build_compose_instructions | tr -s '[:space:]' ' ')"
) > "$TEST_TEMP_DIR/n9.out" 2>/dev/null
_n9="$(_l N9 n9.out)"
if [[ "$_n9" == *TAFND-4* ]]; then assert_fail "[N9] build does not hand test-author's finding back" "$_n9"; else assert_pass "[N9] build does not hand test-author's finding back"; fi
assert_contains "[N9] ...it goes to design" "$(_l N9d n9.out)" "TAFND-4"
assert_contains "[N8] build's design must goes to design" "$(_l N9d n9.out)" "RLRT-2"
assert_contains "[N11] ...keeping its id and its text" "$(_l N9d n9.out)" "SPEC-2 cannot be met"
assert_contains "[N12] build's own step finding still goes the old way (to test-author's findings)" "$_n9" "BUFND-1"
assert_eq "[N15] a later try with no design hand-off leaves no file (review on PR #2601)" "gone" "$(_l N15 n9.out)"
assert_contains "[N7] build is told the design form" "$(_l N7b n9.out)" "not mine — design must"
(
    source "$REPO_ROOT/plugins/agent/test-author/plugin.sh" >/dev/null 2>&1
    A="$TEST_TEMP_DIR/art11"; mkdir -p "$A"
    declare -gA _ZB_ANS_FINDING=([RLRT-7]="lens red-team: §C2 names no test")
    _ta_write_code_findings "$A" $'ANSWER RLRT-7: not mine — the code must change: docs/adr/ADR-009.md: cite it\nANSWER TAFND-2: not mine — the code must change: core/x.sh: own finding\n'
    echo "N11|$(cat "$A/test-author-code-result.json" 2>/dev/null | tr -d '\n')"
) > "$TEST_TEMP_DIR/n11.out" 2>/dev/null
assert_contains "[N11] test-author's hand-off keeps the finding's id" "$(_l N11 n11.out)" "RLRT-7"
assert_contains "[N11] ...and its text" "$(_l N11 n11.out)" "§C2 names no test"
if [[ "$(_l N11 n11.out)" == *TAFND-2* ]]; then assert_fail "[N12] test-author's own finding is left to the old path" "handed"; else assert_pass "[N12] test-author's own finding is left to the old path"; fi

print_test_section "N13-N14: the test folders list, and fix: design"
(
    source "$REPO_ROOT/scripts/lib/test-paths.sh"
    X="$TEST_TEMP_DIR/r13"; mkdir -p "$X/.zbuild"; printf 't[ab]/*\nspec\\x/*\n' > "$X/.zbuild/test-paths.txt"
    zb_test_path_regexes_json_v rx "$X"
    echo "N13|$(jq -c '[.[] as $r | "ta/x.sh", "tc/x.sh", "specx/y" | test($r)] ' <<< "$rx" 2>&1)"
) > "$TEST_TEMP_DIR/n13.out" 2>/dev/null
assert_eq "[N13] read as bash reads them: ta yes, tc no, spec\\x matches specx" "[true,false,false,false,false,true]" "$(_l N13 n13.out)"
(
    source "$REPO_ROOT/core/plugin-registry/registry.sh"; source "$REPO_ROOT/plugins/agent/review-lens/plugin.sh"
    zb_test_lens_jobs n14 >/dev/null 2>&1
    route_to_model() { zb_test_lens_check_answer "$2" && return 0
        printf 'SCORE: 4\nFINDING\nseverity: medium\ncategory: logic\nfix: design\nintroduced: yes\nquote: tests/unit/guard-test.sh | guard line\nmessage: DESIGN-WORD-TEST-FILE\ntrigger: t\naccepted if: a\n'; }
    A="$TEST_TEMP_DIR/art14"; mkdir -p "$A"; printf 'diff --git a/core/x.sh b/core/x.sh\n+one line\n' > "$A/diff.patch"
    ( cd "$R" && ZBUILD_CURRENT_STAGE=review_lenses ZBUILD_REVIEW_LENS_ID=n14 _TPL_STAGE_FAIL_ON_review_lenses="medium high critical" \
        _review_lens_run_inner n14 "" "$A/diff.patch" "$A/lens-n14.json" "$A" ) >/dev/null 2>&1
    echo "N14|$(cat "$A/lens-n14-test-result.json" 2>/dev/null | tr -d '\n')"
) > "$TEST_TEMP_DIR/n14.out" 2>/dev/null
assert_contains "[N14] a fix: design finding about a test file goes to test-author" "$(_l N14 n14.out)" "DESIGN-WORD-TEST-FILE"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
