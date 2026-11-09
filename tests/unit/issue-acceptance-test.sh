#!/usr/bin/env bash
# Tests: issue-acceptance — does the finished change do what the ISSUE asked?
#
# Before this stage the issue was read once, by spec-coverage, before any code
# existed; every later check judged the SPECs. #1849 (run 36238164552) went
# green while two of the issue's own requirements were unmet: the plan narrowed
# "no artifact paths in code" to "no declared-input paths", and the issue's
# interruption → `unavailable` rule was never built. Nothing compared the code
# to the issue.
#
#   SPEC-1 [change]: the prompt carries the issue, the SPECs, the change (what
#                    it is pointed at: #2507, ADR-072 §7) and the test verdict
#                    — every piece the judgement needs
#   SPEC-2 [change]: a requirement the code does not meet → verdict=fail,
#                    and each unmet requirement a numbered finding (#2271)
#   SPEC-3 [change]: no fault class is asked for or written (#2271)
#                    (the template routes that back to design)
#   SPEC-4 [change]: every requirement met → verdict=pass
#   SPEC-5 [guard] : a placeholder issue is never a pass
#   SPEC-6 [change]: an unparseable answer is `unusable` (the engine retries it),
#                    never a pass
#   SPEC-7 [change]: inputs come from the engine's index only — no path in code
#   SPEC-8 [change]: simple.yaml runs it in build_test_cycle after the tests,
#                    and the loop's exit_when names it (#2368)
#   SPEC-9 [change]: the prompt judges what the tests must catch too, and asks
#                    whether the tests would catch a broken change (#2303)
#   SPEC-10 [change]: one finding per UNMET:/UNSURE: line, never split at a
#                    semicolon — on #1944 a finding whose prose held a `;` came
#                    out as fragments ("…", "set -e` mid-file)")
#   SPEC-11 [change]: an answer with no verdict is asked again once, at once,
#                    told what was wrong and shown the answer (ADR-060 §6); a
#                    second answer with no verdict is `unusable`; a failed
#                    call is not asked again
#   SPEC-12 [change]: a failing test it cannot quickly trace to the change is
#                    UNSURE with the reason, never investigated (#2476: on #1805
#                    run 42127743259 both round-2 calls spent their 600s on one)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "issue-acceptance: the change against the issue (#1849)"
setup_test_env "issue-acceptance"
_test_cleanup_hook() { cleanup_test_env; }

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"

PLUGIN_DIR="$REPO_ROOT/plugins/agent/issue-acceptance"
# shellcheck source=../../plugins/agent/issue-acceptance/plugin.sh
source "$PLUGIN_DIR/plugin.sh" 2>/dev/null
# #2366: input results are made with the engine's writer.
# shellcheck source=../../scripts/lib/stage-result.sh
source "$REPO_ROOT/scripts/lib/stage-result.sh"
set +e

# Stubs AFTER the source (the plugin sources the real router).
_IA_PROMPT="$TEST_TEMP_DIR/prompt.txt"
_IA_ANSWER=""
_IA_RC=0
route_to_model() { printf '%s' "$2" > "$_IA_PROMPT"; printf '%s\n' "$_IA_ANSWER"; return $_IA_RC; }
resolve_tier() { printf 'T2'; }

# _setup <name> [issue text] — a run with every input at a NON-standard path, named only by the index.
_setup() {
    _S="$TEST_TEMP_DIR/$1"; _A="$_S/artifacts"; local _in="$_S/inputs"
    mkdir -p "$_A" "$_in"
    printf '{}' > "$_S/pipeline-state.json"
    # #2364: each input as its writer makes it, found by what it is.
    zb_test_issue_output "$_in" "${2:-Migrate the plugin. Acceptance: - [ ] no artifact paths in code - [ ] an interrupted push reports unavailable}" >/dev/null
    printf '%s\n' '# Design' '```acceptance' 'SPEC-1[change]: the plugin reads its inputs from the index' 'TESTFILES:' 'SPEC-1: tests/t.sh' 'WIRING: none' '```' > "$_in/design.md"
    printf '%s\n' 'diff --git a/p.sh b/p.sh' '+gate="$(jq -r .inputs.gate "$ZBUILD_STAGE_INPUTS")"' > "$_in/diff.patch"
    zb_test_test_run_output "$_in" pass 1 0 >/dev/null
    jq -n --arg i "$_in/intake-result.json" --arg d "$_in/design.md" --arg p "$_in/diff.patch" --arg t "$_in/test-results.json" \
        '{inputs: {a: $i, b: $d, c: $p, d: $t}}' > "$_S/stage-inputs.json"
    # #2482: no git repository, so no branch diff — the index's diff.patch is the change.
    export ZBUILD_STAGE_INPUTS="$_S/stage-inputs.json" ZBUILD_ARTIFACT_DIR="$_A" ZBUILD_REPO_ROOT="$_S"
}
_res() { jq -r "$1" "$_A/issue-acceptance-result.json" 2>/dev/null || echo MISSING; }
_run() { : > "$_IA_PROMPT"; issue_acceptance_run "issue-acceptance" "$_S/pipeline-state.json" >/dev/null 2>&1; }

print_test_section "SPEC-1: the prompt carries everything the judgement needs"
_setup s1
_IA_ANSWER=$'MET: no artifact paths in code\nMET: an interrupted push reports unavailable'
_run
_p="$(cat "$_IA_PROMPT")"
assert_contains "[SPEC-1] the issue text" "$_p" "an interrupted push reports unavailable"
assert_contains "[SPEC-1] the SPEC text" "$_p" "the plugin reads its inputs from the index"
assert_contains "[SPEC-1] the change: with no starting commit, the patch it is pointed at" "$_p" "$_S/inputs/diff.patch"
assert_contains "[SPEC-1] ...and the file in it" "$_p" "p.sh"
assert_contains "[SPEC-1] the test verdict" "$_p" "TEST VERDICT: pass"

print_test_section "SPEC-2: unmet by the code → fail, a numbered finding"
_setup s2
_IA_ANSWER=$'MET: no artifact paths in code\nUNMET: an interrupted push | WHY: the push failure is reported as broken | QUOTE: "an interrupted push reports unavailable"'
_run; _rc=$?
assert_eq "[SPEC-2] rc=0 (the verdict is in the artifact)" "0" "$_rc"
assert_eq "[SPEC-2] outcome=fail" "fail" "$(_res .outcome)"
assert_eq "[SPEC-2] contract 3 (#2366)" "3" "$(_res .result_contract)"
assert_eq "[SPEC-2] no verdict or disposition field" "false" "$(_res 'has("verdict") or has("disposition")')"
assert_contains "[SPEC-2] the unmet requirement is a numbered finding" "$(_res '.data.findings[0].text')" "an interrupted push reports unavailable"
assert_contains "[SPEC-2] the unmet requirement is named, with why" "$(_res '.data.unmet[0]')" "an interrupted push: the push failure is reported as broken"

print_test_section "SPEC-3: no fault class — the stage does not decide who fixes it"
_setup s3
_IA_ANSWER=$'FAULT: specification\nUNMET: no artifact paths | WHY: no SPEC asks for it | QUOTE: "no artifact paths in code"\nMET: an interrupted push reports unavailable'
_run
assert_eq "[SPEC-3] a fault line in the reply is not written" "null" "$(_res .fault)"
if grep -q 'FAULT' "$REPO_ROOT/plugins/agent/issue-acceptance/plugin.sh"; then
    assert_fail "[SPEC-3] the prompt no longer asks for a fault" "FAULT still in plugin.sh"
else
    assert_pass "[SPEC-3] the prompt no longer asks for a fault"
fi

print_test_section "SPEC-4: every requirement met → pass"
_setup s4
_IA_ANSWER=$'MET: no artifact paths in code\nMET: an interrupted push reports unavailable'
_run
assert_eq "[SPEC-4] outcome=pass" "pass" "$(_res .outcome)"
assert_eq "[SPEC-4] no fault on a pass" "null" "$(_res .fault)"

print_test_section "SPEC-5: a placeholder issue is never a pass"
_setup s5 "GitHub issue #1849"
_IA_ANSWER=$'MET: no artifact paths in code\nMET: an interrupted push reports unavailable'
_run
assert_eq "[SPEC-5] outcome=fail" "fail" "$(_res .outcome)"
assert_eq "[SPEC-5] ...because the issue was unreadable" "unreadable" "$(_res .data.judgement)"

print_test_section "SPEC-6: an unparseable answer is unusable, never a pass"
_setup s6
_IA_ANSWER="I think it mostly looks fine?"
_run
assert_eq "[SPEC-6] outcome=unusable (the engine retries it)" "unusable" "$(_res .outcome)"

print_test_section "SPEC-7: inputs from the index only"
_setup s7
printf '{"inputs":{}}\n' > "$_S/stage-inputs.json"
# Real-looking outputs on disk, but not in the index: they are not read.
zb_test_issue_output "$_S" "on-disk issue" >/dev/null
printf '%s\n' '```acceptance' 'SPEC-1[change]: on disk' '```' > "$_A/design.md"
_IA_ANSWER=$'MET: no artifact paths in code\nMET: an interrupted push reports unavailable'
_run
assert_eq "[SPEC-7] no index entry → nothing to judge against (unreadable), whatever is on disk" "unreadable" "$(_res .data.judgement)"
_code="$(grep -v '^[[:space:]]*#' "$PLUGIN_DIR/plugin.sh")"
for _f in intake.md design.md diff.patch test-results.json; do
    assert_eq "[SPEC-7] plugin.sh constructs no $_f path" "0" "$(grep -cF "$_f" <<< "$_code" || true)"
done

print_test_section "SPEC-8: wired into build_test_cycle as a gate"
_tpl="$REPO_ROOT/config/templates/simple.yaml"
_flow="$(awk '/^build_test_cycle:/{f=1} f&&/^  flow:/{g=1;next} g&&/^  [a-z_]+:/{exit} g&&/^    - /{print $2}' "$_tpl" | paste -sd, -)"
_ia_pos="$(tr ',' '\n' <<< "$_flow" | grep -n '^issue-acceptance$' | cut -d: -f1)"
_t_pos="$(tr ',' '\n' <<< "$_flow" | grep -n '^test$' | cut -d: -f1)"
if [[ -n "$_ia_pos" && "$_ia_pos" -gt "$_t_pos" ]]; then
    assert_pass "[SPEC-8] issue-acceptance runs after test"
else
    assert_fail "[SPEC-8] issue-acceptance runs after test" "flow: $_flow"
fi
# #2368: the loop's exit_when names it, so it must pass.
assert_contains "[SPEC-8] build_test_cycle must pass it" \
    "$(awk '/^build_test_cycle:/{f=1} f&&/exit_when:/{e=1} e&&/max_iterations:/{exit} e' "$_tpl")" "stage: issue-acceptance,"

# #2303: on #2035 this stage passed PR #2298 while the issue's "the tests must
# catch X" requirements were unmet, because its prompt said a requirement about
# how the change is verified is "proven by the pipeline itself; never judge it
# here". The pipeline never proved them. The prompt is built by the plugin's own
# composer, so a copy of the text cannot stand in for it.
print_test_section "SPEC-9: the whole issue is judged, including what the tests must catch (#2303)"
_p9="$(_ia_prompt "ISSUE-TEXT" "SPEC-TEXT" "DIFF-TEXT" "pass")"
# One line, single spaces: a phrase the prompt wraps across lines is still found.
_p9="$(tr -s '[:space:]' ' ' <<< "$_p9")"
assert_contains "[SPEC-9] the composer built a real prompt (the issue text is in it)" "$_p9" "ISSUE-TEXT"
assert_eq "[SPEC-9] the prompt does not exempt requirements about how the change is verified" \
    "0" "$(grep -cF "proven by the pipeline itself" <<< "$_p9" || true)"
assert_eq "[SPEC-9] the prompt does not tell the model to skip any requirement" \
    "0" "$(grep -cF "never judge it here" <<< "$_p9" || true)"
assert_contains "[SPEC-9] the prompt says what the tests must catch is a requirement to judge" \
    "$_p9" "including what its tests must catch"
assert_contains "[SPEC-9] the prompt asks whether the tests would catch a broken change" \
    "$_p9" "if the change were broken, would its tests catch it?"
assert_contains "[SPEC-9] the narrowed-SPEC rule is kept" "$_p9" "a SPEC that narrowed a"
assert_contains "[SPEC-12] a failing test it cannot trace to the change is UNSURE, not investigated" \
    "$_p9" "A failing test you cannot trace to the change within a few reads: mark the requirement it bears on UNSURE"
assert_contains "[SPEC-12] ...and it does not work out why the test fails" "$_p9" "Do not work out why a test fails"

print_test_section "SPEC-10: one finding per line, whole"
_setup s10
_IA_ANSWER=$'UNMET: R-4 | WHY: persist is not tested; only release is | QUOTE: "no artifact paths in code"\nUNMET: R-10 | WHY: lint fails (eight files use `set +e`; one sets `set -e` mid-file) | QUOTE: "no artifact paths in code"\nUNSURE: R-9 | WHY: §9 or §11; the issue is unclear | QUOTE: "an interrupted push reports unavailable"'
_run
assert_eq "[SPEC-10] two UNMET lines → two unmet items" "2" "$(_res '.data.unmet | length')"
assert_eq "[SPEC-10] a semicolon inside a finding does not split it" \
    'R-4: persist is not tested; only release is — "no artifact paths in code"' "$(_res '.data.unmet[0]')"
assert_eq "[SPEC-10] ...nor a backticked one" \
    'R-10: lint fails (eight files use `set +e`; one sets `set -e` mid-file) — "no artifact paths in code"' "$(_res '.data.unmet[1]')"
assert_eq "[SPEC-10] an UNSURE line is one item too" 'R-9: §9 or §11; the issue is unclear — "an interrupted push reports unavailable"' "$(_res '.data.unsure[0]')"
assert_eq "[SPEC-10] three findings in all" "3" "$(_res '.data.findings | length')"
_p10="$(_ia_prompt "I" "S" "D" "pass")"
assert_eq "[SPEC-10] the prompt no longer asks for a semicolon-separated list" \
    "0" "$(grep -c "semicolon" <<< "$_p10" || true)"

print_test_section "SPEC-11: an answer with no line is asked again, with what was wrong (#2464: no VERDICT line any more)"
_IA_N="$TEST_TEMP_DIR/n11"
_ia_two() {   # _ia_two <rc1> <answer1> <answer2>
    printf '0' > "$_IA_N"; _IA_A1="$2"; _IA_A2="$3"; _IA_RC1="$1"
    route_to_model() {
        local n; n=$(( $(cat "$_IA_N") + 1 )); printf '%s' "$n" > "$_IA_N"
        printf '%s' "$2" > "$_IA_PROMPT.$n"
        if [[ $n -eq 1 ]]; then printf '%s\n' "$_IA_A1"; return "$_IA_RC1"; fi
        printf '%s\n' "$_IA_A2"
    }
}
_setup s11a
_ia_two 0 "I think it mostly looks fine?" $'MET: no artifact paths in code\nMET: an interrupted push reports unavailable'
_run
assert_eq "[SPEC-11] asked twice" "2" "$(cat "$_IA_N")"
_p11="$(cat "$_IA_PROMPT.2" 2>/dev/null)"
assert_contains "[SPEC-11] the second ask says what was wrong" "$_p11" "it has no MET:, UNMET: or UNSURE: line"
assert_contains "[SPEC-11] the second ask carries the first answer" "$_p11" "I think it mostly looks fine?"
assert_eq "[SPEC-11] the second answer is the judgement" "pass" "$(_res .outcome)"
_setup s11b
_ia_two 0 "maybe?" "still maybe?"
_run
assert_eq "[SPEC-11] asked twice, no more" "2" "$(cat "$_IA_N")"
assert_eq "[SPEC-11] still no verdict: unusable" "unusable" "$(_res .outcome)"
assert_contains "[SPEC-11] ...saying what was wrong" "$(_res .reason)" "it has no MET:, UNMET: or UNSURE: line"
_setup s11c
_ia_two 1 "" $'MET: no artifact paths in code\nMET: an interrupted push reports unavailable'
_run
assert_eq "[SPEC-11] a failed call is not asked again" "1" "$(cat "$_IA_N")"
route_to_model() { printf '%s' "$2" > "$_IA_PROMPT"; printf '%s\n' "$_IA_ANSWER"; return $_IA_RC; }

print_test_section "SPEC-13: the judge sees the whole branch's change, not this round's alone (#2482)"
# #1805 run 42293991602: build's diff.patch held round 3's change only, and the
# judge wrote of code an earlier round had added "it is not in this
# incremental DIFF" — design then took that code for the code from before.
_setup s13
_R13="$TEST_TEMP_DIR/r13"; mkdir -p "$_R13"
(
    cd "$_R13" || exit 1
    git init -q -b main . && git config user.email t@t && git config user.name t
    printf 'base\n' > p.sh && git add p.sh && git commit -q -m base
    git checkout -q -b zbuild/issue-1
    printf 'base\nemit_from_round_one\n' > p.sh && git commit -q -am round1
    printf 'base\nemit_from_round_one\nround_three_line\n' > p.sh && git commit -q -am round3
) >/dev/null 2>&1
printf '%s\n' 'diff --git a/p.sh b/p.sh' '+round_three_line' > "$_S/inputs/diff.patch"
_IA_ANSWER=$'MET: no artifact paths in code\nMET: an interrupted push reports unavailable'
ZBUILD_REPO_ROOT="$_R13" _run
_p13="$(cat "$_IA_PROMPT")"
# #2507 (ADR-072 §7): the judge is pointed at the change from where the branch
# started — not this round's — and reads it with git.
assert_contains "[SPEC-13] the judged change starts where the branch did, before round one" "$_p13" \
    "started at commit $(git -C "$_R13" rev-parse main)"
assert_contains "[SPEC-13] ...and names the file the rounds changed" "$_p13" "p.sh"

print_test_section "SPEC-14: the findings it is given are answered (ADR-068 §6)"
# The engine's answer check (zb_answers_finish, finding-answers-test.sh B1-B3)
# is handed the judge's prompt and reply; what it returns is kept.
eval "_s14_real_$(declare -f zb_answers_finish)"
zb_answers_finish() {
    local -n _s14a="$1"; printf '%s' "$3" > "$TEST_TEMP_DIR/s14-reply"
    _s14a+=("lens-sre-code finding 1: not mine — a code fix, not the issue's"); _ZB_ANS_SHOWN=1; _ZB_ANS_MISSING=""
}
_setup s14
_IA_ANSWER=$'MET: no artifact paths in code\nMET: an interrupted push reports unavailable\nANSWER lens-sre-code finding 1: not mine — a code fix, not the issue\'s'
_run
assert_eq "[SPEC-14] an ANSWER line does not spoil the verdict" "pass" "$(_res .outcome)"
assert_contains "[SPEC-14] the check is handed the judge's reply" "$(cat "$TEST_TEMP_DIR/s14-reply" 2>/dev/null)" "MET: no artifact paths in code"
assert_eq "[SPEC-14] what it returns is kept in the result" "lens-sre-code finding 1: not mine — a code fix, not the issue's" "$(_res '.data.answers[0]')"
assert_eq "[SPEC-14] ...with how many findings it was shown" "1" "$(_res '.data.findings_shown')"
assert_contains "[SPEC-14] ...and its summary says so" "$(cat "$_A/issue-acceptance-summary.md" 2>/dev/null)" "answered: lens-sre-code finding 1: not mine"
eval "$(declare -f _s14_real_zb_answers_finish | sed '1s/_s14_real_//')"

print_test_section "#2366: contract 3 and no verdict words"
_M="$REPO_ROOT/plugins/agent/issue-acceptance/manifest.yaml"
assert_eq "[#2366] provides.result_contract: 3" "1" "$(grep -cE '^[[:space:]]+result_contract:[[:space:]]*3' "$_M" || true)"
assert_eq "[#2366] no valid_verdicts" "0" "$(grep -c 'valid_verdicts' "$_M" || true)"

print_test_results
exit $((FAIL > 0))
