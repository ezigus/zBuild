#!/usr/bin/env bash
# tests/unit/trace-rule-test.sh — everything a stage produces traces to the work
# it was handed: one rule, in one set of words, for every stage that makes a
# model call (#2629, ADR-075).
#
# Why: on #1722 run 45872552515 build changed scripts/lib/acceptance-block.sh —
# in no design step's areas — so a test would pass. issue-acceptance said "no
# requirement asks for it" and accepted it if the file stayed under 500 lines;
# the scope lens judged it needed "for the test". Nothing asked for it.
#
# T1 [change] §1 the shared pieces: a path lies in an area (a file, a folder);
#             the rule names what was handed and who adds to it, says a change
#             only a test needs is asked for by nothing, and that nothing is
#             kept on a condition about how it is done; the finding says take
#             it out or answer not mine, naming who adds
# T2 [change] §2 build: a file its round changed that no step's areas hold and
#             no done answer names is a finding; one in a step's areas, one a
#             done answer names, a test file, or a plan with no steps is none;
#             a wrong answer naming it does not count
# T3 [change] §2 build's prompt: a done answer to a finding names each file it
#             changed; every change traces to a step or a finding, in the rule
# T4 [change] §2 design: a SPEC that covers nothing, or an id intake did not
#             list, is refused; one covering a listed requirement or limit is
#             not; with no list, nothing is asked
# T5 [change] §3 intake's check names a listed item the issue does not state
# T6 [change] §3 test-author's unasked check: the rule, and the shared finding
# T7 [change] §3 issue-acceptance's reverse question: the rule — a file a test
#             needs is no longer asked for by that — and its accepted if is the
#             change without it, or a requirement that asks for it
# T8 [change] §3 the scope lens judges by the rule
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "everything a stage produces traces to the work it was handed (#2629)"
setup_test_env "trace-rule"
_lacks() { if [[ "$2" == *"$3"* ]]; then assert_fail "$1" "it has: $3"; else assert_pass "$1"; fi; }
_flat() { tr -s '[:space:]' ' ' <<< "$1"; }

# ── T1 ───────────────────────────────────────────────────────────────────────
print_test_section "T1: the shared rule and finding"
# shellcheck source=../../scripts/lib/trace.sh
source "$REPO_ROOT/scripts/lib/trace.sh" 2>/dev/null
_cov() { if zb_trace_covered "$1" "$2" 2>/dev/null; then echo yes; else echo no; fi; }
assert_eq "[T1] a file that is an area lies in it" "yes" "$(_cov scripts/lib/a.sh "scripts/lib/a.sh docs/x.md")"
assert_eq "[T1] a file under a folder area lies in it" "yes" "$(_cov plugins/p/lib/b.sh "plugins/p/")"
assert_eq "[T1] a file elsewhere does not" "no" "$(_cov scripts/lib/acceptance-block.sh "plugins/tool/test/lib/acceptance-check.sh")"
assert_eq "[T1] a path that climbs out lies in no area" "no" "$(_cov plugins/p/../../etc/x "plugins/p/")"
_rule=""; zb_trace_rule_v _rule "a requirement" "intake" 2>/dev/null
assert_contains "[T1] the rule names what was handed" "$_rule" "Everything here must trace to a requirement."
assert_contains "[T1] ...a change only a test needs is asked for by nothing" "$_rule" "when only the test needs it, the test asks for more than it was given, and neither is asked for"
assert_contains "[T1] ...what nothing asks for is taken out, or who adds to it adds it" "$_rule" "What nothing asks for is taken out, or intake adds what asks for it"
assert_contains "[T1] ...never kept on a condition about how it is done" "$_rule" "never kept on a condition about how it is done"
_f=""; zb_trace_finding_v _f "your change to x.sh" "design step" "design" 2>/dev/null
assert_eq "[T1] the finding: take it out, or not mine naming who adds" \
    "your change to x.sh traces to no design step — take it out, or, when it must stay, answer not mine: design must add what asks for it" "$_f"

# ── T2 ───────────────────────────────────────────────────────────────────────
print_test_section "T2: build's round traces to its steps and its answers"
# shellcheck source=../../scripts/lib/stage-answers.sh
source "$REPO_ROOT/scripts/lib/stage-answers.sh"
# shellcheck source=../../scripts/lib/test-paths.sh
source "$REPO_ROOT/scripts/lib/test-paths.sh"
# shellcheck source=../../plugins/agent/build/lib/steps-trace.sh
source "$REPO_ROOT/plugins/agent/build/lib/steps-trace.sh" 2>/dev/null
_BUILD_STEP_DESC=("emit outcome and reason" "amend the ADR")
_BUILD_STEP_AREAS=("plugins/tool/test/lib/acceptance-check.sh plugins/tool/test/lib/acceptance-reason.sh" "docs/adr/")
_t2() {   # <files> — _BUILD_STEP_FINDINGS joined
    _BUILD_STEP_FINDINGS=()
    _build_trace_check "$1" "$REPO_ROOT" 2>/dev/null
    printf '%s\n' "${_BUILD_STEP_FINDINGS[@]+"${_BUILD_STEP_FINDINGS[@]}"}"
}
_BUILD_ANSWERS=()
_r="$(_t2 $'plugins/tool/test/lib/acceptance-check.sh\nscripts/lib/acceptance-block.sh\ndocs/adr/ADR-040.md')"
assert_contains "[T2] a file in no step's areas is a finding naming it" "$_r" "scripts/lib/acceptance-block.sh traces to no design step"
assert_contains "[T2] ...saying take it out, or not mine to design" "$_r" "take it out, or, when it must stay, answer not mine: design"
assert_eq "[T2] ...one finding: the files in a step's areas are none" "1" "$(grep -c 'traces to no' <<< "$_r")"
_BUILD_ANSWERS=("TEFND-3: done — scripts/lib/acceptance-block.sh | [[ \$in_block -eq 1 ]] && return 1")
assert_eq "[T2] a file a done answer to a finding names is none" "" "$(_t2 'scripts/lib/acceptance-block.sh')"
_BUILD_ANSWERS=("TEFND-3: wrong — scripts/lib/acceptance-block.sh is fine")
assert_contains "[T2] a wrong answer naming it does not count" "$(_t2 'scripts/lib/acceptance-block.sh')" "traces to no design step"
_BUILD_ANSWERS=()
assert_eq "[T2] a file in the test folders is none (build may not change them)" "" "$(_t2 'tests/unit/x-test.sh')"
_BUILD_STEP_DESC=(); _BUILD_STEP_AREAS=()
assert_eq "[T2] a plan with no steps is not checked" "" "$(_t2 'scripts/lib/acceptance-block.sh')"

# ── T3 ───────────────────────────────────────────────────────────────────────
print_test_section "T3: build's prompt"
# shellcheck source=../../plugins/agent/build/lib/prompt.sh
source "$REPO_ROOT/plugins/agent/build/lib/prompt.sh"
_bp="$(_flat "$(_build_compose_instructions)")"
assert_contains "[T3] a done answer to a finding names each file it changed" "$_bp" \
    "A done answer to a finding names each file you changed for it: ANSWER <its id>: done — <file> | <a line you added> — <what you changed>"
assert_contains "[T3] ...every change traces to a step or a finding, in the rule" "$_bp" \
    "Everything here must trace to a design step or a finding you were given."

# ── T4 ───────────────────────────────────────────────────────────────────────
print_test_section "T4: every SPEC covers a requirement intake listed"
# shellcheck source=../../scripts/lib/acceptance-block.sh
source "$REPO_ROOT/scripts/lib/acceptance-block.sh"
# shellcheck source=../../plugins/agent/design/lib/checks.sh
source "$REPO_ROOT/plugins/agent/design/lib/checks.sh"
_ROOT="$TEST_TEMP_DIR/repo"; mkdir -p "$_ROOT/scripts"; printf 'one\n' > "$_ROOT/scripts/x.sh"
export ZBUILD_REPO_ROOT="$_ROOT"
_t4() {   # <name> <covers-for-WORK-1> <covers-for-WORK-2> [no-req]
    local _a="$TEST_TEMP_DIR/t4-$1"; mkdir -p "$_a"
    printf '%s\n' '# Design' '```acceptance' \
        "DSWORK-1[code]: the gate fails on a missing file$2" "  When: it runs" "  Then: it fails" \
        "DSWORK-2[code]: the gate names the file$3" "  When: it runs" "  Then: it names it" \
        'WIRING: none' '```' > "$_a/design.md"
    [[ "${4:-}" == no-req ]] || printf '%s\n' '{"schema_version":1,"source":"model","requirements":[' \
        '{"id":"RQGATE-1","text":"fail on a missing file"},{"id":"LMSHAP-1","text":"Do not emit shape events","limit":true}]}' > "$_a/requirements.json"
    _design_checks "$_a/design.md" "$_ROOT" "$_a/requirements.json"
    _VIOL="$(printf '%s\n' "${_DESIGN_VIOLATIONS[@]+"${_DESIGN_VIOLATIONS[@]}"}")"
    local _v; _FB="$(for _v in "${_DESIGN_VIOLATIONS[@]+"${_DESIGN_VIOLATIONS[@]}"}"; do _dck_plain "$_v"; printf '\n'; done)"
}
_t4 none " covers: RQGATE-1" ""
assert_contains "[T4] a SPEC that covers nothing is refused" "$_VIOL" "SPEC_COVERS_NOTHING DSWORK-2"
assert_contains "[T4] ...in the rule's words" "$_FB" "DSWORK-2, which covers no requirement, traces to no requirement intake listed — take it out"
_t4 unknown " covers: RQGATE-1" " covers: RQNAME-1"
assert_contains "[T4] a SPEC covering an id intake did not list is refused" "$_VIOL" "SPEC_COVERS_UNKNOWN DSWORK-2 RQNAME-1"
assert_contains "[T4] ...saying so" "$_FB" "DSWORK-2 covers RQNAME-1, which is not a requirement or limit intake listed"
_t4 listed " covers: RQGATE-1" " covers: RQGATE-1"
_lacks "[T4] SPECs covering a listed requirement are not refused" "$_VIOL" "SPEC_COVERS_"
_t4 nolist "" "" no-req
_lacks "[T4] with no requirements list nothing is asked" "$_VIOL" "SPEC_COVERS_"

# ── T5 ───────────────────────────────────────────────────────────────────────
print_test_section "T5: intake's check names an item the issue does not state"
# shellcheck source=../../plugins/agent/intake/lib/requirements.sh
source "$REPO_ROOT/plugins/agent/intake/lib/requirements.sh"
_IREQ_PX=RQ; _IREQ_LX=LM
_ip="$(_flat "$(_ireq_check_own)")"
assert_contains "[T5] a listed item the issue does not state gets a NOT-A-REQUIREMENT line" "$_ip" \
    "A listed item the issue does not state — no sentence of the issue asks for it — is not a requirement either: give it that line"
assert_contains "[T5] ...in the rule's words" "$_ip" "Everything here must trace to a sentence of the issue."

# ── T6 ───────────────────────────────────────────────────────────────────────
print_test_section "T6: test-author's unasked check"
# shellcheck source=../../plugins/agent/test-author/plugin.sh
source "$REPO_ROOT/plugins/agent/test-author/plugin.sh" >/dev/null 2>&1
_lines=("tests/a-test.sh line 3: assert_eq x y z")
_tp="$(_flat "$(_ta_unasked_prompt "THE SPECS: SPEC-1" _lines)")"
assert_contains "[T6] the check is given the rule" "$_tp" "Everything here must trace to a SPEC or a design step's change."
_TA_UNASKED_FINDINGS=()
_ta_unasked_finding_v _tf "tests/a-test.sh line 3" "it pins a list no SPEC mentions" 2>/dev/null
assert_contains "[T6] its finding is the shared one" "${_tf:-}" "tests/a-test.sh line 3 (it pins a list no SPEC mentions) traces to no SPEC or design step — take it out, or, when it must stay, answer not mine: design must add what asks for it"

# ── T7 ───────────────────────────────────────────────────────────────────────
print_test_section "T7: issue-acceptance's reverse question"
# shellcheck source=../../plugins/agent/issue-acceptance/plugin.sh
source "$REPO_ROOT/plugins/agent/issue-acceptance/plugin.sh" >/dev/null 2>&1
_ap="$(_flat "$(_ia_prompt "ISSUE-TEXT" "SPEC-TEXT" "DIFF-TEXT" "pass")")"
assert_contains "[T7] the reverse question gives the rule" "$_ap" "Everything here must trace to a requirement of the issue."
_lacks "[T7] ...a file a test needs is no longer asked for by that test's requirement" "$_ap" "a file that test needs, are asked for by that requirement"
assert_contains "[T7] its accepted if is the change without it, or a requirement asking for it" "$_ap" \
    "accepted if: <the change without it, or the requirement that would ask for it — nothing else>"

# ── T8 ───────────────────────────────────────────────────────────────────────
print_test_section "T8: the scope lens"
# shellcheck source=../../plugins/agent/review-lens/lib/charters.sh
source "$REPO_ROOT/plugins/agent/review-lens/lib/charters.sh" >/dev/null 2>&1
_sc="$(_flat "$(cat "$REPO_ROOT/plugins/agent/review-lens/lenses/scope.md")")"
_lacks "[T8] a file a test needs is not exempt" "$_sc" "a test for something the issue asks for, and a file that test needs"
_ch="$(_flat "$(_rl_build_lens_prompt scope "DIFF-TEXT" 2>/dev/null)")"
assert_contains "[T8] the scope lens judges by the rule" "$_ch" "Everything here must trace to a requirement of the issue."
_lacks "[T8] ...its job names no placeholder" "$_ch" "@TRACE_RULE@"

print_test_results
exit $((FAIL > 0))
