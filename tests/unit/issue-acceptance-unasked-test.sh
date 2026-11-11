#!/usr/bin/env bash
# Tests: issue-acceptance asks the reverse question (#2508, ADR-072 §3 amendment).
#
# Build had a list of the files it may change (design's scope block), and that
# list was the only check on what build changed. On #1805 run 42556446368 the
# list allowed build to remove the `--from-stage` needs `--resume` guard and
# rewrite an old test to match, and nothing asked whether anything wanted it.
# The list is gone; the check is issue-acceptance's second question: which part
# of the change does no requirement ask for? Each such part is a finding the
# code must fix (change-findings), which build takes.
#
#   U1 [code]: the prompt asks the reverse question and says how to answer it,
#              and how to say there is none
#   U2 [code]: an UNASKED line becomes a finding for build (topic
#              change-findings), and the change does not pass
#   U3 [code]: `UNASKED: none` is no finding, and the change passes
#   U4 [code]: an UNASKED line whose quote is not in the code is not used: the
#              answer is asked again, then `unusable`
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
    printf '%s\n' 'diff --git a/runner.sh b/runner.sh' '+from_stage="$1"' '+resume_required=0' > "$_in/diff.patch"
    zb_test_test_run_output "$_in" pass 1 0 >/dev/null
    jq -n --arg i "$_in/intake-result.json" --arg d "$_in/design.md" --arg p "$_in/diff.patch" --arg t "$_in/test-results.json" \
        '{inputs: {a: $i, b: $d, c: $p, d: $t}}' > "$_S/stage-inputs.json"
    export ZBUILD_STAGE_INPUTS="$_S/stage-inputs.json" ZBUILD_ARTIFACT_DIR="$_A" ZBUILD_REPO_ROOT="$_S"
}
_res() { jq -r "$1" "$_A/issue-acceptance-result.json" 2>/dev/null || echo MISSING; }
_run() { : > "$_IA_PROMPT"; : > "$_IA_CALLS"; issue_acceptance_run "issue-acceptance" "$_S/pipeline-state.json" >/dev/null 2>&1; }

print_test_section "U1: the prompt asks the reverse question"
_p="$(tr -s '[:space:]' ' ' <<< "$(_ia_prompt "ISSUE-TEXT" "SPEC-TEXT" "DIFF-TEXT" "pass")")"
assert_contains "[U1] the composer built a real prompt" "$_p" "ISSUE-TEXT"
assert_contains "[U1] it asks for each part of the change no requirement asks for" \
    "$_p" "each part of the DIFF that no requirement asks for"
assert_contains "[U1] it says how to answer it" "$_p" 'UNASKED: <what the change does> | WHY: <why no requirement asks for it> | QUOTE: <file> | <one line of the code that does it>'
assert_contains "[U1] it says how to say there is none" "$_p" "UNASKED: none"

print_test_section "U2: an unasked part is a finding for build"
_setup u2
_IA_ANSWER=$'MET: --from-stage starts the run at that stage\nUNASKED: it drops the rule that --from-stage needs --resume | WHY: no requirement asks to drop it | QUOTE: runner.sh | resume_required=0'
_run
assert_eq "[U2] the change does not pass" "fail" "$(_res .outcome)"
assert_eq "[U2] one finding" "1" "$(_res '.data.findings | length')"
assert_eq "[U2] its topic is change-findings (build takes it)" "change-findings" "$(_res '.data.findings[0].topic')"
assert_contains "[U2] the finding names the part" "$(_res '.data.findings[0].text')" "it drops the rule that --from-stage needs --resume"
assert_contains "[U2] ...and the code that shows it" "$(_res '.data.findings[0].text')" 'runner.sh | resume_required=0'
assert_eq "[U2] it is kept apart from the unmet requirements" "0" "$(_res '.data.unmet | length')"
assert_eq "[U2] ...as an unasked part" "1" "$(_res '.data.unasked | length')"
assert_eq "[U2] the manifest lets the result name change-findings" "1" \
    "$(grep -cE '^[[:space:]]+finding_topics:.*change-findings' "$PLUGIN_DIR/manifest.yaml" || true)"

print_test_section "U3: none is no finding"
_setup u3
_IA_ANSWER=$'MET: --from-stage starts the run at that stage\nUNASKED: none'
_run
assert_eq "[U3] the change passes" "pass" "$(_res .outcome)"
assert_eq "[U3] no finding" "0" "$(_res '.data.findings | length')"

print_test_section "U4: an unasked part with a quote that is not there is not used"
_setup u4
_IA_ANSWER=$'MET: --from-stage starts the run at that stage\nUNASKED: it adds a cache | WHY: nothing asks for one | QUOTE: runner.sh | cache=1'
_run
assert_eq "[U4] asked again once" "2" "$(grep -c x "$_IA_CALLS")"
assert_eq "[U4] then unusable" "unusable" "$(_res .outcome)"
assert_contains "[U4] ...saying which quote" "$(_res .reason)" "cache=1"

print_test_results
exit $((FAIL > 0))
