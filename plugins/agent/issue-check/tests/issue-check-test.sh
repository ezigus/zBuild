#!/usr/bin/env bash
# Tests: issue-check — before any design work, each of the issue's requirements
# is judged against the system as it is today (#2614, ADR-074).
#
# On #1722 run 45739271221 the issue asked for events from a check #2556 had
# removed, which ADR-040 says stay removed. Intake answers from the issue alone;
# design took the conflict for an unclear word and reversed the ADR. Nothing
# checked the issue against the code or the ADRs; the run spent 2h11m.
#
#   IC1 [code]: the prompt names each requirement by its id, asks for one of the
#               four judgements in the block form, a quote for each one that is
#               not still needed, and a better set of requirements
#   IC2 [code]: every requirement still needed → pass, no finding
#   IC3 [code]: one already true, quoted → misconfigured (the run stops), the
#               reason says the issue needs rewriting and names it; its finding
#               says what is wrong, the quote, and what the issue could ask
#               instead; the report lists it and the better set
#   IC4 [code]: one that contradicts an ADR, quoting the ADR's line → the same,
#               saying it contradicts the ADR
#   IC5 [code]: one about something that no longer exists → the same
#   IC6 [code]: a quote that is not in its file is asked again once, then the
#               answer is unusable — the run never stops on a guess
#   IC7 [code]: a requirement with no line is asked again, then unusable
#   IC8 [code]: a problem with no better set of requirements is asked again
#   IC9 [guard]: a rerun judges again: an earlier stop is never kept
#   IC10 [code]: its call reads files, git and GitHub only, as the architect
#   IC11 [code]: no requirements (a goal run) → pass, nothing to check; an
#               issue run whose requirements intake did not write → broken
#   (review of #2614)
#   IC12 [code]: two problems → two findings, both named in the reason
#   IC13 [code]: a quote is checked for every judgement: none, one not in its
#               file, one in another file, under three words; a CONTRADICTS
#               quote is an ADR's line
#   IC14 [code]: an answer the model numbered, bulleted or headed is read
#   IC15 [code]: the stage changes no file of the repository
#   IC16 [code]: on a branch with this issue's earlier work, the system judged is
#               the commit the branch began from, not the branch
#   IC17 [code]: an issue that says it amends the ADR is not CONTRADICTS
#   IC18 [code]: the run's last comment (its open items) shows each problem with
#               its quote, and the better set of requirements
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
PLUGIN_DIR="$REPO_ROOT/plugins/agent/issue-check"

# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"

print_test_header "issue-check: the issue against the system as it is (#2614)"
setup_test_env "issue-check"
_test_cleanup_hook() { cleanup_test_env; }

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"

# shellcheck source=../plugin.sh
source "$PLUGIN_DIR/plugin.sh" 2>/dev/null
# shellcheck source=../../../../scripts/lib/stage-result.sh
source "$REPO_ROOT/scripts/lib/stage-result.sh"
set +e

# The model call is mocked; everything else is the plugin's own code. Each call
# leaves a line, and the answer for call N is _IC_ANSWER_N (else _IC_ANSWER).
_IC_PROMPT="$TEST_TEMP_DIR/prompt.txt"; _IC_CALLS="$TEST_TEMP_DIR/calls"
_IC_ANSWER="" _IC_ANSWER_2=""
route_to_model() {
    printf 'x\n' >> "$_IC_CALLS"; printf '%s' "$2" > "$_IC_PROMPT"
    local n; n="$(grep -c x "$_IC_CALLS")"
    if [[ "$n" -ge 2 && -n "$_IC_ANSWER_2" ]]; then printf '%s\n' "$_IC_ANSWER_2"; else printf '%s\n' "$_IC_ANSWER"; fi
    return 0
}
resolve_tier() { printf 'T2'; }

ISSUE_TEXT="Shape-floor events carry the result's reason. R1: every shape_floor event has a reason. R2: a skip says it was a skip."

# _setup <name> [no-reqs] — a run whose inputs are made by their writers: the
# issue, and intake's requirements written by intake's own writer. The
# repository holds the lines a quote may name.
_setup() {
    _S="$TEST_TEMP_DIR/$1"; _A="$_S/artifacts"; local _in="$_S/inputs"
    mkdir -p "$_A" "$_in" "$_S/docs/adr" "$_S/lib"
    printf '{}' > "$_S/pipeline-state.json"
    zb_test_issue_output "$_in" "$ISSUE_TEXT" >/dev/null
    if [[ "${2:-}" != no-reqs ]]; then
        (
            # shellcheck source=../../intake/plugin.sh
            source "$REPO_ROOT/plugins/agent/intake/plugin.sh" >/dev/null 2>&1
            route_to_model() {
                if [[ "$2" == *"check a list of requirements"* ]]; then printf 'MISSING: none\n'
                else printf 'REQUIREMENT: RQEVNT-1 every shape_floor event has a reason.\nREQUIREMENT: RQSKIP-1 a skip says it was a skip.\n'; fi
            }
            _intake_write_requirements "$_in" "$(jq -nc --arg b "$ISSUE_TEXT" '{title: "Shape-floor events", body: $b}')"
        ) >/dev/null 2>&1
    fi
    printf '%s\n' '# ADR-040' '- **The shape floor is removed**, with its check and its `shape_floor.*` events.' > "$_S/docs/adr/ADR-040.md"
    printf '%s\n' 'skip_reason="precondition_unmet" written with the skip' > "$_S/lib/check.sh"
    local -a _ins=(--arg i "$_in/intake-result.json")
    local _q='{inputs: {a: $i}}'
    [[ -f "$_in/requirements.json" ]] && { _ins+=(--arg r "$_in/requirements.json"); _q='{inputs: {a: $i, r: $r}}'; }
    jq -n "${_ins[@]}" "$_q" > "$_S/stage-inputs.json"
    export ZBUILD_STAGE_INPUTS="$_S/stage-inputs.json" ZBUILD_ARTIFACT_DIR="$_A" ZBUILD_REPO_ROOT="$_S"
    : > "$_IC_PROMPT"; : > "$_IC_CALLS"; _IC_ANSWER=""; _IC_ANSWER_2=""
}
_res() { jq -r "$1" "$_A/issue-check-result.json" 2>/dev/null || echo MISSING; }
_sum() { cat "$_A/issue-check-summary.md" 2>/dev/null; }
_run() { _RC=0; issue_check_run "issue-check" "$_S/pipeline-state.json" >/dev/null 2>&1 || _RC=$?; }

GOOD_SUGGEST=$'SUGGEST: the acceptance check\'s closing event carries the result\'s reason\nSUGGEST: a skip says it was a skip'

print_test_section "IC1: the prompt"
_setup ic1
_IC_ANSWER=$'NEEDED: RQEVNT-1\nNEEDED: RQSKIP-1'
_run
_p="$(tr -s '[:space:]' ' ' < "$_IC_PROMPT")"
assert_contains "[IC1] it names each requirement by its id" "$_p" "RQEVNT-1: every shape_floor event has a reason."
assert_contains "[IC1] ...the second too" "$_p" "RQSKIP-1: a skip says it was a skip."
assert_contains "[IC1] it holds the issue" "$_p" "R2: a skip says it was a skip."
assert_contains_lines "[IC1] it asks for the four judgements in the block form" "$(cat "$_IC_PROMPT")" \
    $'NEEDED: <id>\nDONE: <id>\nwhy: <what the system already does>\naccepted if: <what the issue could ask instead, or: the requirement is dropped>\nquote: <file> | <the line that shows it>'
assert_contains "[IC1] ...contradicts an ADR" "$_p" "CONTRADICTS: <id>"
assert_contains "[IC1] ...about something that no longer exists" "$_p" "GONE: <id>"
assert_contains "[IC1] it asks for a better set of requirements" "$_p" "SUGGEST: <a requirement>"
assert_contains "[IC1] it is told to read the ADRs" "$_p" "docs/adr"

print_test_section "IC2: every requirement still needed"
_setup ic2
_IC_ANSWER=$'NEEDED: RQEVNT-1\nNEEDED: RQSKIP-1'
_run
assert_eq "[IC2] pass" "pass" "$(_res .outcome)"
assert_eq "[IC2] no finding" "0" "$(_res '.data.findings | length')"
assert_eq "[IC2] one call" "1" "$(grep -c x "$_IC_CALLS")"

print_test_section "IC3: one already true today"
_setup ic3
_IC_ANSWER=$'NEEDED: RQEVNT-1\n\nDONE: RQSKIP-1\nwhy: the skip already says it was a skip, with its reason\naccepted if: the requirement is dropped\nquote: lib/check.sh | skip_reason="precondition_unmet" written with the skip\n\n'"$GOOD_SUGGEST"
_run
assert_eq "[IC3] the run stops: misconfigured (the operator fixes the issue)" "misconfigured" "$(_res .outcome)"
assert_contains "[IC3] the reason says the issue needs rewriting" "$(_res .reason)" "the issue needs rewriting"
assert_contains "[IC3] ...and names the requirement" "$(_res .reason)" "RQSKIP-1"
assert_eq "[IC3] the stage ends non-zero: it stops the run, and the runner names it with its reason" "1" "$_RC"
assert_eq "[IC3] two findings: the problem, and the better set" "2" "$(_res '.data.findings | length')"
_f="$(_res '.data.findings[0].text')"
assert_contains "[IC3] the finding says it is already true" "$_f" "already true today"
assert_contains "[IC3] ...why" "$_f" "the skip already says it was a skip"
assert_contains "[IC3] ...the quote" "$_f" 'lib/check.sh | skip_reason="precondition_unmet" written with the skip'
assert_contains "[IC3] ...and what would settle it" "$_f" "ACCEPTED IF: the requirement is dropped"
assert_contains "[IC3] the report names the requirement" "$(_sum)" "RQSKIP-1"
assert_contains "[IC3] ...and the better set of requirements" "$(_sum)" "the acceptance check's closing event carries the result's reason"
assert_eq "[IC3] the better set is kept in the result" "2" "$(_res '.data.suggested | length')"
for _t in design test code; do
    assert_file_not_exists "[IC3] no stage is sent it ($_t): it is the operator's" "$_A/issue-check-$_t-result.json"
done

print_test_section "IC4: one that contradicts an ADR"
_setup ic4
_IC_ANSWER=$'CONTRADICTS: RQEVNT-1\nwhy: ADR-040 removed the shape floor and its events\naccepted if: the acceptance check\'s own events carry the reason\nquote: docs/adr/ADR-040.md | - **The shape floor is removed**, with its check and its `shape_floor.*` events.\n\nNEEDED: RQSKIP-1\n\n'"$GOOD_SUGGEST"
_run
assert_eq "[IC4] misconfigured" "misconfigured" "$(_res .outcome)"
assert_contains "[IC4] the finding says it contradicts an ADR" "$(_res '.data.findings[0].text')" "contradicts an ADR"
assert_contains "[IC4] ...quoting the ADR" "$(_res '.data.findings[0].text')" "docs/adr/ADR-040.md | - **The shape floor is removed**"

print_test_section "IC5: one about something that no longer exists"
_setup ic5
_IC_ANSWER=$'GONE: RQEVNT-1\nwhy: the shape-floor check was removed; the acceptance check replaced it\naccepted if: the acceptance check\'s own events carry the reason\nquote: docs/adr/ADR-040.md | - **The shape floor is removed**, with its check and its `shape_floor.*` events.\n\nNEEDED: RQSKIP-1\n\n'"$GOOD_SUGGEST"
_run
assert_eq "[IC5] misconfigured" "misconfigured" "$(_res .outcome)"
assert_contains "[IC5] the finding says it no longer exists" "$(_res '.data.findings[0].text')" "no longer exists"

print_test_section "IC6: a quote that is not there"
_setup ic6
_IC_ANSWER=$'DONE: RQEVNT-1\nwhy: it is done\naccepted if: the requirement is dropped\nquote: lib/check.sh | skip_reason="other" written elsewhere\n\nNEEDED: RQSKIP-1\n\n'"$GOOD_SUGGEST"
_run
assert_eq "[IC6] asked again once" "2" "$(grep -c x "$_IC_CALLS")"
assert_eq "[IC6] then unusable — never a stop on a guess" "unusable" "$(_res .outcome)"
assert_contains "[IC6] ...saying which quote" "$(_res .reason)" 'written elsewhere'
_setup ic6b
_IC_ANSWER=$'DONE: RQEVNT-1\nwhy: it is done\naccepted if: the requirement is dropped\nquote: lib/check.sh | skip_reason="other" written elsewhere\n\nNEEDED: RQSKIP-1\n\n'"$GOOD_SUGGEST"
_IC_ANSWER_2=$'NEEDED: RQEVNT-1\nNEEDED: RQSKIP-1'
_run
assert_eq "[IC6] a re-ask answered well is used" "pass" "$(_res .outcome)"

print_test_section "IC7: a requirement with no line"
_setup ic7
_IC_ANSWER=$'NEEDED: RQEVNT-1'
_run
assert_eq "[IC7] asked again once" "2" "$(grep -c x "$_IC_CALLS")"
assert_eq "[IC7] then unusable" "unusable" "$(_res .outcome)"
assert_contains "[IC7] ...naming it" "$(_res .reason)" "RQSKIP-1"

print_test_section "IC8: a problem with no better set"
_setup ic8
_IC_ANSWER=$'DONE: RQSKIP-1\nwhy: the skip already says it was a skip, with its reason\naccepted if: the requirement is dropped\nquote: lib/check.sh | skip_reason="precondition_unmet" written with the skip\n\nNEEDED: RQEVNT-1'
_run
assert_eq "[IC8] asked again once" "2" "$(grep -c x "$_IC_CALLS")"
assert_contains "[IC8] ...saying there is no better set" "$(cat "$_IC_PROMPT")" "there is no better set of requirements"
assert_eq "[IC8] then unusable" "unusable" "$(_res .outcome)"

print_test_section "IC9: a rerun judges again"
_setup ic9
_IC_ANSWER=$'DONE: RQSKIP-1\nwhy: the skip already says it was a skip, with its reason\naccepted if: the requirement is dropped\nquote: lib/check.sh | skip_reason="precondition_unmet" written with the skip\n\nNEEDED: RQEVNT-1\n\n'"$GOOD_SUGGEST"
_run
: > "$_IC_CALLS"; _IC_ANSWER=$'NEEDED: RQEVNT-1\nNEEDED: RQSKIP-1'
_run
assert_eq "[IC9] the rerun calls the model" "1" "$(grep -c x "$_IC_CALLS")"
assert_eq "[IC9] ...and its verdict is this run's" "pass" "$(_res .outcome)"

print_test_section "IC10: its call reads only, as the architect"
_mf="$PLUGIN_DIR/manifest.yaml"
assert_eq "[IC10] its role" "issue_check" "$(awk '/^provides:/{p=1} p && /role:/ {print $2; exit}' "$_mf")"
assert_eq "[IC10] its one call reads files, git and GitHub" "[read-files, read-git, read-github]" \
    "$(awk '/^calls:/{c=1; next} c && /main:/ {sub(/^[[:space:]]*main:[[:space:]]*/, ""); print; exit}' "$_mf")"
assert_eq "[IC10] ...as the architect" "architect" \
    "$(awk '/^personas:/{c=1; next} c && /main:/ {print $2; exit}' "$_mf")"

print_test_section "IC11: no requirements to check"
_setup ic11 no-reqs
jq -n '{inputs: {}}' > "$_S/stage-inputs.json"
_IC_ANSWER=$'NEEDED: RQEVNT-1'
_run
assert_eq "[IC11] a goal run passes" "pass" "$(_res .outcome)"
assert_eq "[IC11] no call" "0" "$(grep -c x "$_IC_CALLS")"
_setup ic11b no-reqs
printf '{"requirements_missing":true}\n' > /dev/null
jq -n --arg i "$_S/inputs/intake-result.json" '{inputs: {a: $i}}' > "$_S/stage-inputs.json"
_run
assert_eq "[IC11] an issue whose requirements were not written → broken" "broken" "$(_res .outcome)"

print_test_section "IC12: two problems"
_setup ic12
_IC_ANSWER=$'DONE: RQSKIP-1\nwhy: the skip already says it\naccepted if: the requirement is dropped\nquote: lib/check.sh | skip_reason="precondition_unmet" written with the skip\n\nCONTRADICTS: RQEVNT-1\nwhy: ADR-040 removed them\naccepted if: the acceptance check\'s own events carry the reason\nquote: docs/adr/ADR-040.md | - **The shape floor is removed**, with its check and its `shape_floor.*` events.\n\n'"$GOOD_SUGGEST"
_run
assert_eq "[IC12] three findings: two problems and the better set" "3" "$(_res '.data.findings | length')"
assert_contains "[IC12] the reason names one" "$(_res .reason)" "RQSKIP-1 is already true today"
assert_contains "[IC12] ...and the other" "$(_res .reason)" "RQEVNT-1 contradicts an ADR"

print_test_section "IC13: a quote is checked for every judgement"
_ic13() {   # _ic13 <label> <block for RQEVNT-1>
    _setup "ic13-$RANDOM"
    _IC_ANSWER="$2"$'\n\nNEEDED: RQSKIP-1\n\n'"$GOOD_SUGGEST"
    _run
    assert_eq "[IC13] $1 → asked again, then unusable" "2 unusable" "$(grep -c x "$_IC_CALLS") $(_res .outcome)"
}
_ic13 "CONTRADICTS with no quote" $'CONTRADICTS: RQEVNT-1\nwhy: ADR-040 removed them\naccepted if: x'
_ic13 "GONE with a quote not in its file" $'GONE: RQEVNT-1\nwhy: removed\naccepted if: x\nquote: docs/adr/ADR-040.md | the shape floor stays forever'
_ic13 "DONE quoting a line from another file" $'DONE: RQEVNT-1\nwhy: done\naccepted if: x\nquote: lib/check.sh | - **The shape floor is removed**, with its check and its `shape_floor.*` events.'
_ic13 "a quote under three words" $'DONE: RQEVNT-1\nwhy: done\naccepted if: x\nquote: lib/check.sh | written'
_ic13 "CONTRADICTS quoting a file that is not an ADR" $'CONTRADICTS: RQEVNT-1\nwhy: no\naccepted if: x\nquote: lib/check.sh | skip_reason="precondition_unmet" written with the skip'

print_test_section "IC14: an answer as a list"
_setup ic14
_IC_ANSWER=$'1. **NEEDED:** RQEVNT-1\n\n2. DONE: RQSKIP-1\nwhy: the skip already says it\naccepted if: the requirement is dropped\nquote: lib/check.sh | skip_reason="precondition_unmet" written with the skip\n\n### Better requirements\n- SUGGEST: the acceptance check\'s closing event carries the result\'s reason'
_run
assert_eq "[IC14] read: one call" "1" "$(grep -c x "$_IC_CALLS")"
assert_eq "[IC14] ...and judged" "misconfigured" "$(_res .outcome)"
assert_eq "[IC14] the bulleted SUGGEST is kept" "1" "$(_res '.data.suggested | length')"

print_test_section "IC15: the stage changes no file"
_setup ic15
( cd "$_S" && git init -q -b main && git config user.email t@t && git config user.name t && printf 'artifacts/\ninputs/\npipeline-state.json\nstage-inputs.json\n' > .gitignore && git add -A && git commit -qm base ) >/dev/null 2>&1
_IC_ANSWER=$'NEEDED: RQEVNT-1\n\nDONE: RQSKIP-1\nwhy: the skip already says it\naccepted if: the requirement is dropped\nquote: lib/check.sh | skip_reason="precondition_unmet" written with the skip\n\n'"$GOOD_SUGGEST"
_run
assert_eq "[IC15] the repository is as it was" "" "$(git -C "$_S" status --porcelain 2>/dev/null)"

print_test_section "IC16: the system is where the branch began"
_setup ic16
( cd "$_S" && git init -q -b main && git config user.email t@t && git config user.name t && printf 'artifacts/\ninputs/\npipeline-state.json\nstage-inputs.json\n' > .gitignore && git add -A && git commit -qm base \
  && git checkout -q -b zbuild/issue-1722 && printf 'earlier work\n' > lib/new.sh && git add -A && git commit -qm "earlier work on the issue" ) >/dev/null 2>&1
_base="$(git -C "$_S" rev-parse main)"
_IC_ANSWER=$'NEEDED: RQEVNT-1\nNEEDED: RQSKIP-1'
_run
assert_contains "[IC16] the prompt names the commit the branch began from" "$(tr -s '[:space:]' ' ' < "$_IC_PROMPT")" "the repository at commit $_base, where this run's branch began on the default branch"

print_test_section "IC17: an issue that amends the ADR"
assert_contains "[IC17] the prompt says such an issue is NEEDED" "$(tr -s '[:space:]' ' ' < "$_IC_PROMPT")" "An issue that names the ADR and says it amends or supersedes that statement is NEEDED"

print_test_section "IC18: the run's last comment"
# shellcheck source=../../../../scripts/lib/run-open-items.sh
source "$REPO_ROOT/scripts/lib/run-open-items.sh"
_setup ic18
_IC_ANSWER=$'NEEDED: RQEVNT-1\n\nDONE: RQSKIP-1\nwhy: the skip already says it\naccepted if: the requirement is dropped\nquote: lib/check.sh | skip_reason="precondition_unmet" written with the skip\n\n'"$GOOD_SUGGEST"
_run
_oi="$(open_items_json "$_S" 2>/dev/null | jq -r '.[].text' 2>/dev/null)"
assert_contains "[IC18] the open items name the problem" "$_oi" "RQSKIP-1"
assert_contains "[IC18] ...with its quote" "$_oi" 'lib/check.sh | skip_reason="precondition_unmet" written with the skip'
assert_contains "[IC18] ...and the better set of requirements" "$_oi" "the acceptance check's closing event carries the result's reason"

print_test_results
exit $((FAIL > 0))
