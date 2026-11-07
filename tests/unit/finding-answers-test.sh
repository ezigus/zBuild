#!/usr/bin/env bash
# tests/unit/finding-answers-test.sh — every finding a stage is given gets an
# answer the engine can read, a "not mine" is not a dispute, and a finding that
# does not block still reaches the stages that fix it (ADR-068 §6, ADR-071 §5,
# ADR-072 §5).
#
# Why: on #1805 run 42374066107
# - test-author answered the lenses' code findings "nothing to do — fix: code,
#   not in test scope", and each lens was told a stage that had to act on them
#   said they were wrong;
# - build answered all 13 in prose, so none was kept, and its two disputes never
#   reached red-team;
# - the performance lens graded a finding low and passed, so no stage was given
#   it, and the next round graded the same finding medium and failed.
#
# A1 an answer is done, wrong or not mine; anything else is no answer
# A2 only a `wrong` answer goes back to the stage that raised the finding
# A3 a working call is told the three forms; a judging call is not
# B1 a finding a stage was shown and did not answer is asked for once, alone,
#    with the stage's reply shown and tools for reading only
# B2 a stage shown no finding is asked nothing; one that answered all is not
#    asked again
# B3 the summary lines: what each finding was answered, what was not, or that
#    no finding was open
# B4 build: an unanswered finding is asked for, and every answer is kept
# B5 issue-acceptance is told the forms, and keeps its answers
# C1 a lens sends on every finding the change introduced, each marked whether
#    it blocks; one below its fail rule does not fail it
# C2 Previous work marks a finding that does not block
# C3 a lens is shown its findings from last time, with their answers, and told
#    a finding keeps its grade unless it quotes what changed
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "every finding a stage is given gets an answer (ADR-068 §6)"
setup_test_env "finding-answers"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
source "$REPO_ROOT/scripts/lib/stage-result.sh"
source "$REPO_ROOT/scripts/lib/judge.sh"
source "$REPO_ROOT/scripts/lib/stage-prompt.sh"

print_test_section "A1: the three answers"
_k() { local v; zb_answer_kind_v v "$1"; printf '%s' "$v"; }
assert_eq "[A1] done" "done" "$(_k 'lens-sre-code finding 1: done — the write now emits an event')"
assert_eq "[A1] wrong" "wrong" "$(_k 'lens-red-team-code finding 1: wrong — the two reads are of different links')"
assert_eq "[A1] not mine" "not mine" "$(_k 'lens-sre-code finding 2: not mine — a code fix, and test-author writes tests')"
assert_eq "[A1] ...markdown around the word is read" "not mine" "$(_k 'lens-sre-code finding 2: **not mine** — tests only')"
assert_eq "[A1] the old 'nothing to do' is no answer" "" "$(_k 'lens-sre-code finding 1: nothing to do — fix: code')"

print_test_section "A2: only a wrong answer goes back"
A2="$TEST_TEMP_DIR/a2"; mkdir -p "$A2"
stage_result_write "$A2/test-author-result.json" pass "tests written" \
    '{"answers":["lens-sre-code finding 1: not mine — a code fix"]}' >/dev/null
stage_result_write "$A2/build-summary.json" pass "built" \
    '{"answers":["lens-sre-code finding 1: done — emits an event","lens-sre-code finding 2: wrong — the write cannot fail there"]}' >/dev/null
_a2=""; judge_answers_to_v _a2 "$A2" lens-sre-code
assert_eq "[A2] the judge is given only the wrong answer" "lens-sre-code finding 2: wrong — the write cannot fail there" "$_a2"

print_test_section "A3: a working call is told the forms; a judging call is not"
_own=$'## What you own\nWrite x.'
_work="$(stage_prompt_compose_text "$_own" "THE THING" "- do not y" 2>/dev/null)"
_judge="$(stage_prompt_compose_text --fresh "$_own" "THE THING" "- do not y" 2>/dev/null)"
assert_contains "[A3] a working call is told every finding gets an answer" "$_work" "ANSWER <stage> finding <n>: not mine — <why your job cannot fix it>"
assert_contains "[A3] ...and the other two forms" "$_work" "ANSWER <stage> finding <n>: wrong — <why it does not hold>"
_a3_j=1; [[ "$_judge" == *"ANSWER <stage> finding <n>"* ]] && _a3_j=0
assert_eq "[A3] a judging call is not told to answer findings" "1" "$_a3_j"

print_test_section "B1-B3: the engine asks for what was not answered"
_P_SHOWN=$'Previous work\n- lens-sre-code finding 1 (opened by review_lenses): the write is silent\n- lens-sre-code finding 2 (opened by review_lenses): the jq error is hidden\n- issue-acceptance finding 1 (opened by issue-acceptance): R2 is not met\nmore'
# The call runs in a command substitution: it counts in a file.
_calls() { cat "$TEST_TEMP_DIR/calls" 2>/dev/null || echo 0; }
route_to_model() {
    local n; n=$(( $(_calls) + 1 )); printf '%s' "$n" > "$TEST_TEMP_DIR/calls"
    printf '%s' "$2" > "$TEST_TEMP_DIR/ask-$n"
    printf '%s' "${ZBUILD_ROUTE_TOOLS:-}" > "$TEST_TEMP_DIR/ask-tools-$n"
    printf '%s\n' "$_ASK_REPLY"; return 0
}
_ASK_REPLY='ANSWER lens-sre-code finding 2: not mine — a code fix'
declare -a _ANS=()
zb_answers_finish _ANS "$_P_SHOWN" $'Fixed it.\nANSWER lens-sre-code finding 1: done — the write emits an event'
assert_eq "[B1] one call asks for the unanswered findings" "1" "$(_calls)"
assert_contains "[B1] ...it shows the finding not answered" "$(cat "$TEST_TEMP_DIR/ask-1")" "lens-sre-code finding 2 (opened by review_lenses): the jq error is hidden"
_b1_ans=1; [[ "$(cat "$TEST_TEMP_DIR/ask-1")" == *"finding 1 (opened by review_lenses)"* ]] && _b1_ans=0
assert_eq "[B1] ...and not the one answered" "1" "$_b1_ans"
assert_contains "[B1] ...with the stage's own reply" "$(cat "$TEST_TEMP_DIR/ask-1")" "the write emits an event"
assert_eq "[B1] ...and tools for reading only" "read" "$(cat "$TEST_TEMP_DIR/ask-tools-1")"
assert_eq "[B1] every answer is kept" $'lens-sre-code finding 1: done — the write emits an event\nlens-sre-code finding 2: not mine — a code fix' "$(printf '%s\n' "${_ANS[@]}")"
assert_eq "[B1] the one still not answered is named" "issue-acceptance finding 1" "$_ZB_ANS_MISSING"
assert_eq "[B1] three findings were shown" "3" "$_ZB_ANS_SHOWN"
rm -f "$TEST_TEMP_DIR/calls"; _ANS=()
zb_answers_finish _ANS "no findings here" "done"
assert_eq "[B2] a stage shown no finding is asked nothing" "0" "$(_calls)"
assert_eq "[B2] ...and none was shown" "0" "$_ZB_ANS_SHOWN"
_ANS=()
zb_answers_finish _ANS "$_P_SHOWN" $'ANSWER lens-sre-code finding 1: done — x\nANSWER lens-sre-code finding 2: wrong — y\nANSWER issue-acceptance finding 1: not mine — z'
assert_eq "[B2] a stage that answered every finding is not asked again" "0" "$(_calls)"
_ANS=('lens-sre-code finding 1: done — x'); _ZB_ANS_SHOWN=2; _ZB_ANS_MISSING="lens-sre-code finding 2"
_b3=""; zb_answers_summary_v _b3 _ANS
assert_eq "[B3] the summary says what each was answered, and what was not" \
    $'- answered: lens-sre-code finding 1: done — x\n- not answered: lens-sre-code finding 2' "$_b3"
_ANS=(); _ZB_ANS_SHOWN=0; _ZB_ANS_MISSING=""
_b3=""; zb_answers_summary_v _b3 _ANS
assert_eq "[B3] ...or that no finding was open" "- no finding was open for it" "$_b3"
unset -f route_to_model

print_test_section "B4: build"
(
    source "$REPO_ROOT/plugins/agent/build/plugin.sh" >/dev/null 2>&1
    route_to_model() { printf '%s\n' 'ANSWER lens-red-team-code finding 2: wrong — the plugin dir is always found'; return 0; }
    B4="$TEST_TEMP_DIR/b4"; mkdir -p "$B4"; artifact_dir="$B4"
    printf '%s\n' "$_P_SHOWN" | sed 's/lens-sre-code finding 1/lens-red-team-code finding 1/; s/lens-sre-code finding 2/lens-red-team-code finding 2/; /issue-acceptance/d' > "$B4/build-prompt.txt"
    output_summary_json="$B4/build-summary.json"; terminated_reason=done_sentinel files_changed_count=1 files_changed_json='["a.sh"]' iterations=1 repo_root="$TEST_TEMP_DIR"
    scope_violations=(); scope_violations_created=()
    _ROUTE_LOOP_LAST_RESPONSE=$'Security-1: sanitized.\nANSWER lens-red-team-code finding 1: done — the link is read once\nLOOP_COMPLETE'
    _build_write_build_summary >/dev/null 2>&1
    echo "B4|$(jq -r '[.data.answers[]?] | join(" ;; ")' "$output_summary_json" 2>/dev/null)|$(jq -r '.data.findings_shown // "none"' "$output_summary_json" 2>/dev/null)"
) > "$TEST_TEMP_DIR/b4.out" 2>/dev/null
assert_eq "[B4] build's answers, the one asked for included, are in its result" \
    "lens-red-team-code finding 1: done — the link is read once ;; lens-red-team-code finding 2: wrong — the plugin dir is always found" \
    "$(grep '^B4|' "$TEST_TEMP_DIR/b4.out" | cut -d'|' -f2)"
assert_eq "[B4] ...with how many findings it was shown" "2" "$(grep '^B4|' "$TEST_TEMP_DIR/b4.out" | cut -d'|' -f3)"

print_test_section "B5: issue-acceptance"
(
    source "$REPO_ROOT/plugins/agent/issue-acceptance/plugin.sh" >/dev/null 2>&1
    _b5="$(_ia_prompt "the issue" "<none>" "<no diff>" pass "" "")"
    echo "B5|$([[ "$_b5" == *"ANSWER <stage> finding <n>: not mine —"* ]] && echo told)"
) > "$TEST_TEMP_DIR/b5.out" 2>/dev/null
assert_eq "[B5] issue-acceptance is told how to answer the findings it is given" "told" "$(grep '^B5|' "$TEST_TEMP_DIR/b5.out" | cut -d'|' -f2)"

print_test_section "C1-C3: a finding that does not block still travels"
source "$REPO_ROOT/core/plugin-registry/registry.sh"
source "$REPO_ROOT/plugins/agent/review-lens/plugin.sh"
ART="$TEST_TEMP_DIR/artifacts"; mkdir -p "$ART"
printf 'diff --git a/a.sh b/a.sh\n+x=1\n' > "$ART/diff.patch"; printf 'scope: all\n' > "$TEST_TEMP_DIR/scope-manifest.md"
_lens() {  # <fail_on> <findings json>
    route_to_model() { printf '%s' "$2" > "$TEST_TEMP_DIR/lens-prompt"; printf '%s' "{\"score\":7,\"findings\":$_FINDINGS}"; return 0; }
    rm -f "$ART/lens-performance.json" "$ART/lens-performance-judged.json"
    _FINDINGS="$2" _TPL_STAGE_FAIL_ON_review_lenses="$1" ZBUILD_CURRENT_STAGE=review_lenses \
        ZBUILD_REVIEW_LENS_ID=performance \
        _review_lens_run_inner performance "$TEST_TEMP_DIR/scope-manifest.md" "$ART/diff.patch" "$ART/lens-performance.json" "$ART" >/dev/null 2>&1 || true
}
_low='[{"quote":"x=1","file":"a.sh","category":"x","severity":"low","line":1,"message":"an extra state write a round","introduced":true,"fix":"code"}]'
_lens "medium high critical" "$_low"
assert_eq "[C1] a low finding does not fail the lens" "pass" "$(jq -r '.outcome' "$ART/lens-performance.json" 2>/dev/null)"
assert_contains "[C1] ...but is sent on to the stages that fix code" "$(jq -r '.data.findings[0].text // ""' "$ART/lens-performance-code-result.json" 2>/dev/null)" "an extra state write a round"
assert_eq "[C1] ...marked as not blocking" "false" "$(jq -r '.data.findings[0].blocking' "$ART/lens-performance-code-result.json" 2>/dev/null)"
assert_eq "[C1] ...and the output it is in does not fail" "pass" "$(jq -r '.outcome' "$ART/lens-performance-code-result.json" 2>/dev/null)"
_med='[{"quote":"x=1","file":"a.sh","category":"x","severity":"medium","line":1,"message":"two writes a round","introduced":true,"fix":"code"}]'
_lens "medium high critical" "$_med"
assert_eq "[C1] a medium finding fails it, and blocks" "fail true" \
    "$(jq -r '.outcome' "$ART/lens-performance.json") $(jq -r '.data.findings[0].blocking' "$ART/lens-performance-code-result.json" 2>/dev/null)"
source "$REPO_ROOT/scripts/lib/stage-previous-work.sh"
_c2="$(_sp_findings_for "$ART/lens-performance-code-result.json" review_lenses lens-performance-code code-findings "" "")"
assert_contains "[C2] a blocking finding is shown as it was" "$_c2" "lens-performance-code finding 1 (opened by review_lenses): "
stage_result_write "$ART/c2.json" pass "x" '{"findings":[{"n":1,"text":"an extra write","blocking":false}]}' >/dev/null
assert_contains "[C2] one that does not block is marked" \
    "$(_sp_findings_for "$ART/c2.json" review_lenses lens-performance-code code-findings "" "")" \
    "lens-performance-code finding 1 (opened by review_lenses, does not block): an extra write"
# C3: last time's findings, with what was answered, come back to the lens.
stage_result_write "$ART/build-summary.json" pass "built" \
    '{"answers":["lens-performance-code finding 1: done — one write a round now"]}' >/dev/null
_lens "medium high critical" "$_low"
_c3="$(cat "$TEST_TEMP_DIR/lens-prompt" 2>/dev/null)"
assert_contains "[C3] the lens is shown its findings from last time" "$_c3" "lens-performance-code finding 1"
assert_contains "[C3] ...with what was answered" "$_c3" "done — one write a round now"
assert_contains "[C3] ...and told a finding keeps its grade unless it quotes what changed" "$_c3" \
    "A finding you report again keeps the grade you gave it, unless you quote what changed"
rm -f "$ART/build-summary.json"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
