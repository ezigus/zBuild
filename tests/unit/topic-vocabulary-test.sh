#!/usr/bin/env bash
# tests/unit/topic-vocabulary-test.sh — findings go by one set of topics, named
# by what must change: the design, a test, or the code (#2569 R5, ADR-071 §1
# amended 2026-11-20, ADR-038 amended 2026-11-20).
#
# Why: on #1764 run 44530053809 the topic names mixed two ideas.
# `requirement-findings` named what a finding is about; `change-findings` was
# "findings only the code can fix"; `code-findings` was mostly what a test must
# fix. The lenses had their own words (`fix: code / test / design / issue`) and
# the lens code translated them: `fix: code` went to change-findings.
# `test-findings` was test-author's private channel to design.
#
#   V1 [change]: the topics are ask, tests, change, design-findings,
#                test-findings, code-findings
#   V2 [change]: every shipped manifest's topics and takes come from them, and
#                an output routed by topic is named by its topic's word
#                (<name>-<word>-result.json for <word>-findings)
#   V3 [change]: a lens finding's fix: word is its topic: it lands in
#                lens-<id>-<fix>-result.json, whose topic is <fix>-findings
#   V4 [change]: each lens finding reaches the stage that can fix it, and no
#                other: code → build, test → test-author, design → design
#   V5 [change]: issue-acceptance — [fix-code] → its code output; [fix-design]
#                → design; an unasked part in a test file → test; any other
#                unasked part → code; an unmarked UNMET or UNSURE line says
#                nothing of what must change, so it goes to design, test and
#                code; an UNSURE line with a mark goes by its mark (review on
#                #2569)
#   V6 [change]: the acceptance check, each finding to every stage that can fix
#                it — a test failing on the new code → code and test; a test
#                passing on the old code → design (the code may already do it:
#                mark it [done]) and test; a requirement no assertion is tagged
#                with → test; a test that never reached its assertion on the new
#                code → test and code; a WIRING file that is not what runs the
#                change → design; code no requirement covers → design and code;
#                a test file past its time limit → code and test (review on
#                #2569)
#   V8 [change]: the acceptance check's pipeline problems ("not in your change")
#                and its own code failing to load go to no stage: they are in its
#                own result, for the report; a load failure stops the run
#                (broken, terminal) (review on #2569)
#   V7 [change]: an output under an old topic's file name, restored from an
#                earlier run (hydrate), reaches no stage, and every stage's
#                Previous work is still written
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "findings go by one set of topics: what must change (#2569 R5)"
setup_test_env "topic-vocabulary"
unset ZBUILD_STAGE_INPUTS ZBUILD_INPUTS_FLOW ZBUILD_MAP_ELEMENT 2>/dev/null || true
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"

# shellcheck source=../../core/state/resume.sh
source "$REPO_ROOT/core/state/resume.sh"
# shellcheck source=../../core/pipeline/state_helpers.sh
source "$REPO_ROOT/core/pipeline/state_helpers.sh"
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
# shellcheck source=../../core/pipeline/input-resolve.sh
source "$REPO_ROOT/core/pipeline/input-resolve.sh"
# shellcheck source=../../scripts/lib/stage-prompt.sh
source "$REPO_ROOT/scripts/lib/stage-prompt.sh"
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
# shellcheck source=../../plugins/agent/review-lens/plugin.sh
source "$REPO_ROOT/plugins/agent/review-lens/plugin.sh"

assert_not_contains() {
    if grep -qF -- "$3" <<< "$2" 2>/dev/null; then assert_fail "$1" "output unexpectedly has: $3"; else assert_pass "$1"; fi
}
_texts() { jq -r '[.data.findings[].text] | join(" ")' "$1" 2>/dev/null; }

# ── V1 ───────────────────────────────────────────────────────────────────────
print_test_section "V1: the topics"
_VOCAB="ask tests change design-findings test-findings code-findings"
assert_eq "[V1] ask, tests, change, and one findings topic for each thing that can change" \
    "$_VOCAB" "${ZBUILD_STAGE_TOPICS[*]}"

# ── V2 ───────────────────────────────────────────────────────────────────────
print_test_section "V2: every manifest uses them"
# Every topic: and take word of every shipped manifest, "<manifest> <word>" a line.
_words="$(awk '/^[ ]*(- )?topic:[ ]*/{ w=$0; sub(/.*topic:[ ]*/, "", w); gsub(/["'"'"' ]/, "", w); print FILENAME " " w }' \
    "$REPO_ROOT"/plugins/*/*/manifest.yaml)"
assert_gt "[V2] the manifests name topics" "$(grep -c . <<< "$_words")" "20"
_bad=""
while read -r _m _w; do
    [[ " $_VOCAB " == *" $_w "* ]] || _bad+="${_m#"$REPO_ROOT"/} $_w; "
done <<< "$_words"
assert_eq "[V2] no manifest names a topic outside them" "" "$_bad"
# Every output whose path ends -<word>-result.json for a findings word, with its topic.
_routed="$(awk 'function out() { if (p != "") print m " " p " " t; p = ""; t = "" }
    FNR==1{ out(); f=0; m=FILENAME }
    /^outputs:/{f=1;next} f&&/^[a-zA-Z_]/{ out(); f=0 }
    f&&/^  - id:/{ out() }
    f&&/^    path:/{ p=$2; gsub(/"/, "", p) }
    f&&/^    topic:/{ t=$2 }
    END{ out() }' "$REPO_ROOT"/plugins/*/*/manifest.yaml)"
_bad=""; _n=0
while read -r _m _p _t; do
    [[ "$_p" =~ -(design|test|code|requirement|change)-result\.json$ ]] || continue
    _n=$((_n + 1))
    [[ "$_t" == "${BASH_REMATCH[1]}-findings" && " $_VOCAB " == *" $_t "* ]] || _bad+="${_m#"$REPO_ROOT"/} ${_p##*/}=$_t; "
done <<< "$_routed"
assert_gt "[V2] outputs are routed by topic" "$_n" "8"
assert_eq "[V2] each routed output's file is named by its topic's word" "" "$_bad"

# ── V3 / V4 ──────────────────────────────────────────────────────────────────
load_template "$REPO_ROOT/config/templates/simple.yaml" >/dev/null 2>&1 \
    || assert_fail "simple.yaml loads" "load_template failed"
PROOT="$REPO_ROOT/plugins"
STATE="$TEST_TEMP_DIR/state"; ART="$STATE/artifacts"; mkdir -p "$ART"
export ZBUILD_STATE_DIR="$STATE" ZBUILD_ARTIFACT_DIR="$ART"
init_state "$STATE/pipeline-state.json" run-1 7 >/dev/null 2>&1
printf 'diff --git a/a.sh b/a.sh\n+x=1\n' > "$ART/diff.patch"
printf 'scope: all\n' > "$TEST_TEMP_DIR/scope-manifest.md"
_f() { printf '{"accepted_if":"the change no longer does this","trigger":"a caller passes this on a normal run","quote":"x=1","file":"a.sh","category":"x","severity":"high","line":1,"message":"%s","introduced":true,"fix":"%s"}' "$1" "$2"; }
_FINDINGS="[$(_f "FIX-CODE the read is unchecked" code),$(_f "FIX-TEST the test sets a value nothing writes" test),$(_f "FIX-DESIGN the design never says when" design)]"
route_to_model() { zb_test_lens_check_answer "$2" && return 0; zb_test_lens_lines "{\"score\":3,\"findings\":$_FINDINGS}"; return 0; }
_TPL_STAGE_FAIL_ON_review_lenses="medium high critical" ZBUILD_CURRENT_STAGE=review_lenses ZBUILD_REVIEW_LENS_ID=correctness \
    _review_lens_run_inner correctness "$TEST_TEMP_DIR/scope-manifest.md" "$ART/diff.patch" "$ART/lens-correctness.json" "$ART" >/dev/null 2>&1 || true
_update_stage_status "$STATE/pipeline-state.json" review_lenses complete

print_test_section "V3: a lens finding's fix: word is its topic"
_lens_topic() {   # <word> — the topic the lens manifest gives lens-<id>-<word>-result.json
    awk -v w="-$1-result.json" 'function out() { if (index(p, w)) print t; p = ""; t = "" }
        /^  - id:/{ out() } /^    path:/{ p=$2 } /^    topic:/{ t=$2 } END{ out() }' \
        "$REPO_ROOT/plugins/agent/review-lens/manifest.yaml"
}
for _w in code test design; do
    _W="$(tr '[:lower:]' '[:upper:]' <<< "$_w")"
    assert_contains "[V3] fix: $_w lands in lens-correctness-$_w-result.json" \
        "$(_texts "$ART/lens-correctness-$_w-result.json")" "FIX-$_W"
    assert_eq "[V3] ...whose topic is $_w-findings" "$_w-findings" "$(_lens_topic "$_w")"
done
assert_file_not_exists "[V3] no lens output under the old word change" "$ART/lens-correctness-change-result.json"

print_test_section "V4: each reaches the stage that can fix it, and no other"
_pw() {   # <stage> — its Previous work, from the index the engine writes for it
    local idx; idx="$(_inputs_resolve_stage "$1" "$PROOT" "$STATE")"
    _stage_block_previous_work "$1" "$STATE" "$PROOT" "$idx" ""
}
B="$(_pw build)"; TA="$(_pw test-author)"; D="$(_pw design)"
assert_contains "[V4] build is shown fix: code" "$B" "FIX-CODE"
assert_not_contains "[V4] ...and not fix: test" "$B" "FIX-TEST"
assert_not_contains "[V4] ...nor fix: design" "$B" "FIX-DESIGN"
assert_contains "[V4] test-author is shown fix: test" "$TA" "FIX-TEST"
assert_not_contains "[V4] ...and not fix: code" "$TA" "FIX-CODE"
assert_not_contains "[V4] ...nor fix: design" "$TA" "FIX-DESIGN"
assert_contains "[V4] design is shown fix: design" "$D" "FIX-DESIGN"
assert_not_contains "[V4] ...and not fix: code" "$D" "FIX-CODE"
assert_not_contains "[V4] ...nor fix: test" "$D" "FIX-TEST"

# ── V5 ───────────────────────────────────────────────────────────────────────
print_test_section "V5: issue-acceptance's outputs by what must change"
# shellcheck source=../../plugins/agent/issue-acceptance/plugin.sh
source "$REPO_ROOT/plugins/agent/issue-acceptance/plugin.sh" 2>/dev/null
D5="$TEST_TEMP_DIR/ia"; mkdir -p "$D5"
_IA_ANSWERS=()
_ia_write "$D5" fail "x" '["[fix-code] R1 CODE-UNMET","[fix-design] R2 DESIGN-UNMET","R3 PLAIN-UNMET"]' \
    '["R4 PLAIN-UNSURE","[fix-design] R5 DESIGN-UNSURE"]' '' \
    '["[fix-test] TEST-UNASKED","CODE-UNASKED"]'
_c5="$(_texts "$D5/issue-acceptance-code-result.json")"
_d5="$(_texts "$D5/issue-acceptance-design-result.json")"
_t5="$(_texts "$D5/issue-acceptance-test-result.json")"
assert_contains "[V5] code output: [fix-code]" "$_c5" "R1 CODE-UNMET"
assert_contains "[V5] ...and an unasked part outside the tests" "$_c5" "CODE-UNASKED"
assert_not_contains "[V5] ...and not [fix-design]" "$_c5" "DESIGN-UNMET"
assert_contains "[V5] design output: [fix-design]" "$_d5" "R2 DESIGN-UNMET"
assert_not_contains "[V5] ...and not [fix-code]" "$_d5" "CODE-UNMET"
assert_contains "[V5] test output: an unasked part in a test file" "$_t5" "TEST-UNASKED"
assert_contains "[V5] [fix-code] reaches the test output too: the code or its tests must change" "$_t5" "R1 CODE-UNMET"
for _o in code design test; do
    _ot="$(_texts "$D5/issue-acceptance-$_o-result.json")"
    assert_contains "[V5] an unmarked UNMET line reaches the $_o output" "$_ot" "R3 PLAIN-UNMET"
    assert_contains "[V5] an unmarked UNSURE line reaches the $_o output" "$_ot" "R4 PLAIN-UNSURE"
done
assert_contains "[V5] an UNSURE line marked [fix-design] reaches design" "$_d5" "R5 DESIGN-UNSURE"
assert_not_contains "[V5] ...and not code" "$_c5" "R5 DESIGN-UNSURE"
assert_not_contains "[V5] ...nor test" "$_t5" "R5 DESIGN-UNSURE"
assert_not_contains "[V5] ...and its text keeps no mark" "$_d5" "[fix-design] R5"
_own5="$(_texts "$D5/issue-acceptance-result.json")"
assert_eq "[V5] its own result holds each finding once" "1" "$(grep -o 'R3 PLAIN-UNMET' <<< "$_own5" | grep -c .)"

# ── V6 ───────────────────────────────────────────────────────────────────────
print_test_section "V6: the acceptance check's outputs by what must change"
# shellcheck source=../../plugins/tool/test/lib/acceptance-reason.sh
source "$REPO_ROOT/plugins/tool/test/lib/acceptance-reason.sh"
D6="$TEST_TEMP_DIR/ag"; mkdir -p "$D6"
_ag_route_findings "$D6/acceptance-gate-result.json" not_passing_at_head:SPEC-1 tautology:SPEC-2 \
    untagged_spec:SPEC-3 unreached_at_head:SPEC-4 inert_wiring:lib/w.sh unclaimed_code:lib/u.sh \
    negctl_error:timeout:SPEC-7 > "$TEST_TEMP_DIR/ag6.own"
_c6="$(_texts "$D6/acceptance-gate-code-result.json")"
_t6="$(_texts "$D6/acceptance-gate-test-result.json")"
_d6="$(_texts "$D6/acceptance-gate-design-result.json")"
assert_contains "[V6] a test failing on the new code → code" "$_c6" "SPEC-1: its test does not pass on the new code"
assert_contains "[V6] ...and test: the test may be wrong" "$_t6" "SPEC-1: its test does not pass on the new code"
assert_contains "[V6] a test passing on the old code → test" "$_t6" "SPEC-2: its test already passes"
assert_contains "[V6] ...and design, which marks it [done] when the code already does it" "$_d6" "SPEC-2: its test already passes"
assert_contains "[V6] no assertion carries a requirement's tag → test" "$_t6" "SPEC-3: no assertion"
assert_not_contains "[V6] ...and not design" "$_d6" "SPEC-3"
assert_contains "[V6] a test that never reached its assertion on the new code → test" "$_t6" "SPEC-4"
assert_contains "[V6] ...and code" "$_c6" "SPEC-4"
assert_contains "[V6] a WIRING file that is not what runs the change → design" "$_d6" "lib/w.sh was put back"
assert_not_contains "[V6] ...and not code" "$_c6" "lib/w.sh"
assert_contains "[V6] code no requirement covers → design" "$_d6" "lib/u.sh"
assert_contains "[V6] ...and code" "$_c6" "lib/u.sh"
assert_not_contains "[V6] ...and not test" "$_t6" "lib/u.sh"
assert_contains "[V6] a test file past its time limit → code" "$_c6" "SPEC-7: its test file ran past its time limit"
assert_contains "[V6] ...and test" "$_t6" "SPEC-7: its test file ran past its time limit"
assert_not_contains "[V6] ...and not design" "$_d6" "SPEC-7"
assert_eq "[V6] the check's own result holds each finding once" "1" \
    "$(jq -r '[.[].text | select(contains("SPEC-2: its test already passes"))] | length' "$TEST_TEMP_DIR/ag6.own" 2>/dev/null)"

# ── V8 ───────────────────────────────────────────────────────────────────────
print_test_section "V8: the check's pipeline problems go to no stage"
D8="$TEST_TEMP_DIR/ag8"; mkdir -p "$D8"
_ag_route_findings "$D8/acceptance-gate-result.json" untagged_spec:SPEC-1 negctl_error:worktree:SPEC-8 \
    reachability_error:worktree:lib/r.sh > "$TEST_TEMP_DIR/ag8.own"
for _o in design test code; do
    assert_not_contains "[V8] a problem in the pipeline is not in the $_o output" \
        "$(_texts "$D8/acceptance-gate-$_o-result.json")" "not in your change"
done
assert_contains "[V8] ...it is in the check's own result, for the report" \
    "$(jq -r '[.[].text] | join(" ")' "$TEST_TEMP_DIR/ag8.own" 2>/dev/null)" "SPEC-8's test on the code from before this change could not be done"
D8b="$TEST_TEMP_DIR/ag8b"; mkdir -p "$D8b"
( _ag_fail_load "$D8b/acceptance-gate-result.json" "acceptance_spec_tag" ) >/dev/null 2>&1
for _o in design test code; do
    assert_file_not_exists "[V8] the check's code failing to load reaches no $_o output" "$D8b/acceptance-gate-$_o-result.json"
done
assert_eq "[V8] ...it stops the run: broken, terminal" "broken terminal" \
    "$(jq -r '"\(.outcome) \(.severity)"' "$D8b/acceptance-gate-result.json" 2>/dev/null)"
assert_contains "[V8] ...and its result says so" "$(_texts "$D8b/acceptance-gate-result.json")" "its own code did not load"

# ── V7 ───────────────────────────────────────────────────────────────────────
print_test_section "V7: an old topic's file restored from an earlier run reaches no stage"
for _old in issue-acceptance-requirement issue-acceptance-change test-change acceptance-gate-requirement \
            lens-correctness-change test-author-requirement; do
    printf '{"data":{"findings":[{"n":1,"text":"OLD-NAME %s"}]}}\n' "$_old" > "$ART/$_old-result.json"
done
_update_stage_status "$STATE/pipeline-state.json" issue-acceptance complete
_update_stage_status "$STATE/pipeline-state.json" test complete
_update_stage_status "$STATE/pipeline-state.json" test-author complete
for _s in design test-author build issue-acceptance; do
    _out="$(_pw "$_s")"; _rc=$?
    assert_eq "[V7] $_s's Previous work is written" "0" "$_rc"
    assert_not_contains "[V7] ...and holds no finding from an old topic's file" "$_out" "OLD-NAME"
done

cleanup_test_env
print_test_results
exit $((FAIL > 0))
