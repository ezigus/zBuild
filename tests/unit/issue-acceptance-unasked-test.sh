#!/usr/bin/env bash
# Tests: issue-acceptance asks the reverse question (#2508, ADR-072 §3 amendment).
#
# Build had a list of the files it may change (design's scope block), and that
# list was the only check on what build changed. On #1805 run 42556446368 the
# list allowed build to remove the `--from-stage` needs `--resume` guard and
# rewrite an old test to match, and nothing asked whether anything wanted it.
# The list is gone; the check is issue-acceptance's second question: which part
# of the change does no requirement ask for? Each such part is a finding the
# code must fix (code-findings since #2569; was change-findings), which build takes.
#
#   U1 [code]: the prompt asks the reverse question and says how to answer it,
#              and how to say there is none
#   U2 [code]: an UNASKED line becomes a finding for build (topic
#              code-findings, #2569), and the change does not pass
#   U3 [code]: `UNASKED: none` is no finding, and the change passes
#   U4 [code]: an UNASKED line whose quote is not in the code is not used: the
#              answer is asked again, then `unusable`
#
# #2523 (ADR-071 §1): build may not change a test. On #1805 run 43093018140 five
# unasked test-file edits went to build only, which answered "not mine" to each,
# and test-author was never shown them.
#   U5 [code]: an UNASKED line whose quote is in a test folder is test-findings
#              (test-author takes it); one in any other file stays code-findings (#2569)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"

print_test_header "issue-acceptance: each part of the change nothing asked for (#2508)"
setup_test_env "issue-acceptance-unasked"
_test_cleanup_hook() { cleanup_test_env; }

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"

PLUGIN_DIR="$REPO_ROOT/plugins/agent/issue-acceptance"
# shellcheck source=../../plugins/agent/issue-acceptance/plugin.sh
source "$PLUGIN_DIR/plugin.sh" 2>/dev/null
# shellcheck source=../../scripts/lib/stage-result.sh
source "$REPO_ROOT/scripts/lib/stage-result.sh"
set +e

# The model call is mocked; everything else is the plugin's own code.
_IA_PROMPT="$TEST_TEMP_DIR/prompt.txt"
_IA_ANSWER=""
_IA_CALLS="$TEST_TEMP_DIR/calls"
# The call runs in a subshell: each one leaves a line in a file.
route_to_model() { printf 'x\n' >> "$_IA_CALLS"; printf '%s' "$2" > "$_IA_PROMPT"; printf '%s\n' "$_IA_ANSWER"; return 0; }
resolve_tier() { printf 'T2'; }

# _setup <name> — a run whose inputs are made by their writers and named by the
# index; the change's file is on disk, so a quote of it can be checked.
_setup() {
    _S="$TEST_TEMP_DIR/$1"; _A="$_S/artifacts"; local _in="$_S/inputs"
    mkdir -p "$_A" "$_in"
    printf '{}' > "$_S/pipeline-state.json"
    zb_test_issue_output "$_in" "Add --from-stage. Acceptance: - [ ] --from-stage starts the run at that stage" >/dev/null
    printf '%s\n' '# Design' '```acceptance' 'DSFSTG-1[code]: --from-stage starts the run at that stage' 'WIRING: none' '```' > "$_in/design.md"
    printf '%s\n' 'from_stage="$1"' 'resume_required=0' > "$_S/runner.sh"
    mkdir -p "$_S/tests/unit"; printf '%s\n' 'assert_eq "[R8] shown as code" x y' > "$_S/tests/unit/r-test.sh"
    printf '%s\n' 'diff --git a/runner.sh b/runner.sh' '+from_stage="$1"' '+resume_required=0' > "$_in/diff.patch"
    zb_test_test_run_output "$_in" pass 1 0 >/dev/null
    jq -n --arg i "$_in/intake-result.json" --arg d "$_in/design.md" --arg p "$_in/diff.patch" --arg t "$_in/test-results.json" \
        '{inputs: {a: $i, b: $d, c: $p, d: $t}}' > "$_S/stage-inputs.json"
    export ZBUILD_STAGE_INPUTS="$_S/stage-inputs.json" ZBUILD_ARTIFACT_DIR="$_A" ZBUILD_REPO_ROOT="$_S"
}
_res() { jq -r "$1" "$_A/issue-acceptance-result.json" 2>/dev/null || echo MISSING; }
# _out <word> — the texts of issue-acceptance's output for one topic (#2556).
_out() { jq -r '[.data.findings[]?.text] | join(" || ")' "$_A/issue-acceptance-$1-result.json" 2>/dev/null; }
# _mf_topic <output id> — the topic issue-acceptance's manifest gives that output.
_mf_topic() { awk -v id="$1" '$0 ~ "- id: " id "$" {f=1; next} f && /^  - id:/ {f=0} f && /topic:/ {print $2; exit}' "$PLUGIN_DIR/manifest.yaml"; }
_run() { : > "$_IA_PROMPT"; : > "$_IA_CALLS"; issue_acceptance_run "issue-acceptance" "$_S/pipeline-state.json" >/dev/null 2>&1; }

_lacks() { if [[ "$2" == *"$3"* ]]; then assert_fail "$1" "it has: $3"; else assert_pass "$1"; fi; }
print_test_section "U1: the prompt asks the reverse question"
_p="$(tr -s '[:space:]' ' ' <<< "$(_ia_prompt "ISSUE-TEXT" "SPEC-TEXT" "DIFF-TEXT" "pass")")"
assert_contains "[U1] the composer built a real prompt" "$_p" "ISSUE-TEXT"
assert_contains "[U1] it asks for each part of the change no requirement asks for" \
    "$_p" "each part of the DIFF that no requirement asks for"
assert_contains_lines "[U1] it says how to answer it: no condition to write, the part is taken out" "$_p" $'UNASKED: <what the change does>\nwhy: <why no requirement asks for it>\nquote: <file> | <one line of the code that does it>'
_lacks "[U1] ...the form asks no accepted if" "$_p" "accepted if: <the change without it"
# No sentence anywhere in the prompt asks an UNASKED for an ACCEPTED IF (audit on #2634).
_u1s="$(tr '.' '\n' <<< "$_p" | grep -iF unasked | grep -iF 'accepted if' || true)"
if [[ -n "$_u1s" ]]; then assert_fail "[U1] ...no sentence asks an UNASKED for an ACCEPTED IF" "$_u1s"
else assert_pass "[U1] ...no sentence asks an UNASKED for an ACCEPTED IF"; fi
# ...nor any sentence of the reverse question, whether or not it says UNASKED.
_rv="${_p#*Then answer the reverse question}"; _rv="${_rv%%UNASKED: none*}"
assert_contains "[U1] (the reverse question is found)" "$_rv" "Each part you name here"
_lacks "[U1] the reverse question asks no accepted if" "${_rv,,}" "accepted if"
assert_contains "[U1] it says each part it names is taken out of the change" "$_p" "Each part you name here is taken out of the change."
assert_contains "[U1] ...and that words of the issue that could ask for it make it a question, not this" "$_p" \
    "When words of the ISSUE could be read as asking for it, it is not one of these: write an UNCLEAR line that quotes them."
assert_contains "[U1] it says how to say there is none" "$_p" "UNASKED: none"

print_test_section "U2: an unasked part is a finding for build"
_setup u2
_IA_ANSWER=$'MET: --from-stage starts the run at that stage\nUNASKED: it drops the rule that --from-stage needs --resume | WHY: no requirement asks to drop it | ACCEPTED IF: the change without dropping it | QUOTE: runner.sh | resume_required=0'
_run
assert_eq "[U2] the change does not pass" "fail" "$(_res .outcome)"
assert_eq "[U2] one finding" "1" "$(_res '.data.findings | length')"
assert_contains "[U2] it is in the code output (build takes it)" "$(_out code)" "it drops the rule that --from-stage needs --resume"
assert_contains "[U2] the finding names the part" "$(_res '.data.findings[0].text')" "it drops the rule that --from-stage needs --resume"
assert_contains "[U2] ...and the code that shows it" "$(_res '.data.findings[0].text')" 'runner.sh | resume_required=0'
assert_eq "[U2] it is kept apart from the unmet requirements" "0" "$(_res '.data.unmet | length')"
assert_eq "[U2] ...as an unasked part" "1" "$(_res '.data.unasked | length')"
assert_eq "[U2] the manifest gives that output the topic code-findings" "code-findings" "$(_mf_topic issue_acceptance_code)"

print_test_section "U3: none is no finding"
_setup u3
_IA_ANSWER=$'MET: --from-stage starts the run at that stage\nUNASKED: none'
_run
assert_eq "[U3] the change passes" "pass" "$(_res .outcome)"
assert_eq "[U3] no finding" "0" "$(_res '.data.findings | length')"

print_test_section "U4: an unasked part with a quote that is not there is not used"
_setup u4
_IA_ANSWER=$'MET: --from-stage starts the run at that stage\nUNASKED: it adds a cache | WHY: nothing asks for one | ACCEPTED IF: the change without the cache | QUOTE: runner.sh | cache=1'
_run
assert_eq "[U4] asked again once" "2" "$(grep -c x "$_IA_CALLS")"
assert_eq "[U4] then unusable" "unusable" "$(_res .outcome)"
assert_contains "[U4] ...saying which quote" "$(_res .reason)" "cache=1"

print_test_section "U5: an unasked part in a test file is the tests' to fix (#2523)"
_setup u5
_IA_ANSWER=$'MET: --from-stage starts the run at that stage\nUNASKED: it changes an old test | WHY: no requirement asks for it | ACCEPTED IF: the change without the test edit | QUOTE: tests/unit/r-test.sh | assert_eq "[R8] shown as code" x y\nUNASKED: it drops the rule | WHY: no requirement asks to drop it | ACCEPTED IF: the change without dropping it | QUOTE: runner.sh | resume_required=0'
_run
assert_eq "[U5] two findings" "2" "$(_res '.data.findings | length')"
assert_contains "[U5] the one in a test file is in the test output (test-author takes it)" "$(_out test)" "it changes an old test"
assert_contains "[U5] the one in another file stays in the code output" "$(_out code)" "it drops the rule"
assert_eq "[U5] ...and only it" "1" "$(jq -r '.data.findings | length' "$_A/issue-acceptance-code-result.json" 2>/dev/null)"
assert_eq "[U5] the unasked list holds both, without any mark" "0" \
    "$(_res '[.data.unasked[] | select(startswith("["))] | length')"
assert_eq "[U5] the manifest gives the code output the topic code-findings" "code-findings" "$(_mf_topic issue_acceptance_code)"

print_test_section "U6: the answer written as blocks, as the prompt asks (#2609)"
_setup u6
_IA_ANSWER=$'MET: --from-stage starts the run at that stage\n\nUNASKED: it changes an old test\nwhy: no requirement asks for it\naccepted if: the change without the test edit\nquote: tests/unit/r-test.sh | assert_eq "[R8] shown as code" x y\nnote: an old test\n\nUNASKED: it drops the rule that --from-stage needs --resume\nwhy: no requirement asks to drop it\naccepted if: the change without dropping it\nquote: runner.sh | resume_required=0'
_run
assert_eq "[U6] both block answers are read: two findings" "2" "$(_res '.data.findings | length')"
assert_contains "[U6] ...each with its own words, not the note's" "$(_out code)" "it drops the rule"

print_test_results
exit $((FAIL > 0))
