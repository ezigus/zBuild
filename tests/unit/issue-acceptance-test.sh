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
#   SPEC-1 [change]: the prompt carries the issue, the SPECs, the diff and the
#                    test verdict — every piece the judgement needs
#   SPEC-2 [change]: a requirement the code does not meet → verdict=fail,
#                    fault=implementation (build fixes it, in the cycle)
#   SPEC-3 [change]: a requirement no SPEC captures → fault=specification
#                    (the template routes that back to design)
#   SPEC-4 [change]: every requirement met → verdict=pass
#   SPEC-5 [guard] : a placeholder issue is never a pass
#   SPEC-6 [change]: an unparseable answer is `unusable` (the engine retries it),
#                    never a pass
#   SPEC-7 [change]: inputs come from the engine's index only — no path in code
#   SPEC-8 [change]: simple.yaml runs it in build_test_cycle before the
#                    gate-aggregator, and the aggregator's roster includes it
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
export ZBUILD_EVENTS_DB="/dev/null"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"

PLUGIN_DIR="$REPO_ROOT/plugins/agent/issue-acceptance"
# shellcheck source=../../plugins/agent/issue-acceptance/plugin.sh
source "$PLUGIN_DIR/plugin.sh" 2>/dev/null
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
    printf '%s\n' "${2:-Migrate the plugin. Acceptance: - [ ] no artifact paths in code - [ ] an interrupted push reports unavailable}" > "$_in/issue.md"
    printf '%s\n' '# Design' '```acceptance' 'SPEC-1[change]: the plugin reads its inputs from the index' 'TESTFILES:' 'SPEC-1: tests/t.sh' 'WIRING: none' '```' > "$_in/design.md"
    printf '%s\n' 'diff --git a/p.sh b/p.sh' '+gate="$(jq -r .inputs.gate "$ZBUILD_STAGE_INPUTS")"' > "$_in/diff.patch"
    printf '{"result_contract":2,"verdict":"pass","disposition":"complete","reason":"ok"}\n' > "$_in/test-results.json"
    jq -n --arg i "$_in/issue.md" --arg d "$_in/design.md" --arg p "$_in/diff.patch" --arg t "$_in/test-results.json" \
        '{inputs: {intake_goal: $i, design: $d, diff_patch: $p, test_results: $t}}' > "$_S/stage-inputs.json"
    export ZBUILD_STAGE_INPUTS="$_S/stage-inputs.json" ZBUILD_ARTIFACT_DIR="$_A"
}
_res() { jq -r "$1" "$_A/issue-acceptance-result.json" 2>/dev/null || echo MISSING; }
_run() { : > "$_IA_PROMPT"; issue_acceptance_run "issue-acceptance" "$_S/pipeline-state.json" >/dev/null 2>&1; }

print_test_section "SPEC-1: the prompt carries everything the judgement needs"
_setup s1
_IA_ANSWER=$'VERDICT: pass\nREASON: all met'
_run
_p="$(cat "$_IA_PROMPT")"
assert_contains "[SPEC-1] the issue text" "$_p" "an interrupted push reports unavailable"
assert_contains "[SPEC-1] the SPEC text" "$_p" "the plugin reads its inputs from the index"
assert_contains "[SPEC-1] the diff" "$_p" '+gate="$(jq -r .inputs.gate'
assert_contains "[SPEC-1] the test verdict" "$_p" "TEST VERDICT: pass"

print_test_section "SPEC-2: unmet by the code → fail, fault=implementation"
_setup s2
_IA_ANSWER=$'VERDICT: fail\nFAULT: implementation\nREASON: the push failure is reported as broken\nUNMET: an interrupted push reports unavailable'
_run; _rc=$?
assert_eq "[SPEC-2] rc=0 (the verdict is in the artifact)" "0" "$_rc"
assert_eq "[SPEC-2] verdict=fail" "fail" "$(_res .verdict)"
assert_eq "[SPEC-2] fault=implementation" "implementation" "$(_res .fault)"
assert_eq "[SPEC-2] the unmet requirement is named" "an interrupted push reports unavailable" "$(_res '.data.unmet[0]')"
assert_eq "[SPEC-2] the stage completed" "complete" "$(_res .disposition)"

print_test_section "SPEC-3: no SPEC captures it → fault=specification"
_setup s3
_IA_ANSWER=$'VERDICT: fail\nFAULT: specification\nREASON: no SPEC asks for it\nUNMET: no artifact paths in code'
_run
assert_eq "[SPEC-3] fault=specification" "specification" "$(_res .fault)"

print_test_section "SPEC-4: every requirement met → pass"
_setup s4
_IA_ANSWER=$'VERDICT: pass\nREASON: every requirement is met by the diff'
_run
assert_eq "[SPEC-4] verdict=pass" "pass" "$(_res .verdict)"
assert_eq "[SPEC-4] no fault on a pass" "null" "$(_res .fault)"

print_test_section "SPEC-5: a placeholder issue is never a pass"
_setup s5 "GitHub issue #1849"
_IA_ANSWER=$'VERDICT: pass\nREASON: fine'
_run
assert_eq "[SPEC-5] verdict=unreadable" "unreadable" "$(_res .verdict)"

print_test_section "SPEC-6: an unparseable answer is unusable, never a pass"
_setup s6
_IA_ANSWER="I think it mostly looks fine?"
_run
assert_eq "[SPEC-6] verdict is not pass" "unreadable" "$(_res .verdict)"
assert_eq "[SPEC-6] disposition=unusable (the engine retries it)" "unusable" "$(_res .disposition)"

print_test_section "SPEC-7: inputs from the index only"
_setup s7
printf '{"inputs":{}}\n' > "$_S/stage-inputs.json"
printf 'on-disk issue\n' > "$_S/intake.md"; printf 'x\n' > "$_A/design.md"
_IA_ANSWER=$'VERDICT: pass\nREASON: ok'
_run
assert_eq "[SPEC-7] no index entry → nothing to judge against (unreadable), whatever is on disk" "unreadable" "$(_res .verdict)"
_code="$(grep -v '^[[:space:]]*#' "$PLUGIN_DIR/plugin.sh")"
for _f in intake.md design.md diff.patch test-results.json; do
    assert_eq "[SPEC-7] plugin.sh constructs no $_f path" "0" "$(grep -cF "$_f" <<< "$_code" || true)"
done

print_test_section "SPEC-8: wired into build_test_cycle as a gate"
_tpl="$REPO_ROOT/config/templates/simple.yaml"
_flow="$(awk '/^build_test_cycle:/{f=1} f&&/^  flow:/{g=1;next} g&&/^  [a-z_]+:/{exit} g&&/^    - /{print $2}' "$_tpl" | paste -sd, -)"
_ia_pos="$(tr ',' '\n' <<< "$_flow" | grep -n '^issue-acceptance$' | cut -d: -f1)"
_ga_pos="$(tr ',' '\n' <<< "$_flow" | grep -n '^gate-aggregator$' | cut -d: -f1)"
_t_pos="$(tr ',' '\n' <<< "$_flow" | grep -n '^test$' | cut -d: -f1)"
if [[ -n "$_ia_pos" && -n "$_ga_pos" && "$_ia_pos" -lt "$_ga_pos" && "$_ia_pos" -gt "$_t_pos" ]]; then
    assert_pass "[SPEC-8] issue-acceptance runs after test and before gate-aggregator"
else
    assert_fail "[SPEC-8] issue-acceptance runs after test and before gate-aggregator" "flow: $_flow"
fi
assert_eq "[SPEC-8] the manifest marks it a convergence gate" "gate" \
    "$(awk '/^convergence:/{print $2; exit}' "$PLUGIN_DIR/manifest.yaml")"
# The aggregator's roster is built from the cycle's members — prove it picks this one up.
(
    # shellcheck source=../../plugins/tool/gate-aggregator/plugin.sh
    source "$REPO_ROOT/plugins/tool/gate-aggregator/plugin.sh" 2>/dev/null
    export ZBUILD_CYCLE_ID="build_test_cycle" _TPL_CYCLE_STAGES_build_test_cycle="$_flow"
    _ga_build_roster "$REPO_ROOT/plugins"
    printf '%s\n' "${_GA_ROSTER[@]}"
) > "$TEST_TEMP_DIR/roster.txt" 2>/dev/null
assert_contains "[SPEC-8] gate-aggregator's must-pass roster includes it" \
    "$(cat "$TEST_TEMP_DIR/roster.txt")" "issue-acceptance:issue-acceptance-result.json"

print_test_results
exit $((FAIL > 0))
