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
assert_contains "[T1] ...a change only a test would pass with is asked for by nothing" "$_rule" "never by a test that would pass with it: such a test asks for more than it was given, and neither is asked for"
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
# shellcheck source=../../plugins/agent/build/lib/steps-specs.sh
source "$REPO_ROOT/plugins/agent/build/lib/steps-specs.sh"
# shellcheck source=../../plugins/agent/build/lib/steps-trace.sh
source "$REPO_ROOT/plugins/agent/build/lib/steps-trace.sh" 2>/dev/null
# The steps as design writes them (its own writer, not by hand).
TR="$TEST_TEMP_DIR/t2-repo"; mkdir -p "$TR"
_t2_steps() {   # <steps block lines> — loads them as build does
    printf '# D\n\n```steps\n%s\n```\n' "$1" > "$TEST_TEMP_DIR/t2-design.md"
    ( source "$REPO_ROOT/plugins/agent/design/plugin.sh" >/dev/null 2>&1
      _design_write_steps "$TEST_TEMP_DIR/t2-design.md" "$TEST_TEMP_DIR/t2-steps.json" ) >/dev/null 2>&1
    _build_steps_load "$(cat "$TEST_TEMP_DIR/t2-steps.json" 2>/dev/null)"
}
# The findings build is shown, as Previous work lists them, and its reply.
SHOWN=$'- TEFND-3 (opened by test): tests/unit/design-checks-test.sh fails: ✗ [G1] the violation names it\n- BUFND-7 (opened by build): scripts/lib/old.sh traces to no design step and no finding you answered done — take it out'
_t2() {   # <files> <reply> — the findings, one a line
    _BUILD_STEP_FINDINGS=() _BUILD_STEP_WAITING=() _BUILD_ANSWERS=()
    zb_answers_finish _BUILD_ANSWERS "$SHOWN" "$2"
    _build_trace_check "$1" "$TR" 2>/dev/null
    printf '%s\n' "${_BUILD_STEP_FINDINGS[@]+"${_BUILD_STEP_FINDINGS[@]}"}"
}
_t2_steps '- emit outcome and reason | areas: plugins/tool/test/lib/acceptance-check.sh | serves: DSEVNT-1
- amend the ADR | areas: docs/adr/ | serves: DSADR-4'
F=scripts/lib/acceptance-block.sh
_r="$(_t2 $'plugins/tool/test/lib/acceptance-check.sh\nscripts/lib/acceptance-block.sh\ndocs/adr/ADR-040.md' "")"
assert_contains "[T2] a file in no step's areas is a finding naming it" "$_r" "$F traces to no design step"
assert_contains "[T2] ...saying take it out, or not mine to design" "$_r" "take it out, or, when it must stay, answer not mine: design"
assert_eq "[T2] ...one finding: the files in a step's areas are none" "1" "$(grep -c 'traces to no' <<< "$_r")"
assert_eq "[T2] a done answer to a finding build was given, naming the file in its slot, traces it" "" \
    "$(_t2 "$F" "ANSWER TEFND-3: done — $F | [[ \$in_block -eq 1 ]] && return 1 — an unclosed block is malformed")"
assert_contains "[T2] ...not one to a finding build was never given" \
    "$(_t2 "$F" "ANSWER TEFND-99: done — $F | x — y")" "$F traces to no design step"
assert_contains "[T2] ...not one that names the file only in its words" \
    "$(_t2 "$F" "ANSWER TEFND-3: done — fixed the parser in $F so the block reads")" "$F traces to no design step"
assert_contains "[T2] ...not one whose slot names another file" \
    "$(_t2 "$F" "ANSWER TEFND-3: done — scripts/lib/other.sh | x — y")" "$F traces to no design step"
assert_contains "[T2] ...not one whose slot only contains the path" \
    "$(_t2 "$F" "ANSWER TEFND-3: done — $F.bak | x — y")" "$F traces to no design step"
assert_contains "[T2] ...not one to build's own untraced finding" \
    "$(_t2 "scripts/lib/old.sh" "ANSWER BUFND-7: done — scripts/lib/old.sh | x — kept it")" "scripts/lib/old.sh traces to no design step"
assert_contains "[T2] ...and a wrong answer does not count" \
    "$(_t2 "$F" "ANSWER TEFND-3: wrong — $F | x — fine")" "$F traces to no design step"
_t2 "scripts/lib/old.sh" "ANSWER BUFND-7: not mine — design must add a step whose areas hold scripts/lib/old.sh" > "$TEST_TEMP_DIR/t2w"
_r="$(cat "$TEST_TEMP_DIR/t2w")"
assert_eq "[T2] not mine to design on an untraced file: no finding blocks the try" "" "$_r"
assert_contains "[T2] ...it waits for design, and the round ends" "${_BUILD_STEP_WAITING[*]:-}" "scripts/lib/old.sh"
_t2 "scripts/lib/old.sh" "ANSWER BUFND-7: not mine — test-author must change the test" > "$TEST_TEMP_DIR/t2w"
assert_contains "[T2] not mine naming another stage than design: still a finding" "$(cat "$TEST_TEMP_DIR/t2w")" "scripts/lib/old.sh traces to no design step"
assert_eq "[T2] ...and nothing waits" "" "${_BUILD_STEP_WAITING[*]:-}"
assert_eq "[T2] a slot written in backticks traces its file" "" \
    "$(_t2 "$F" "ANSWER TEFND-3: done — \`$F | [[ \$in_block -eq 1 ]] && return 1\` — an unclosed block is malformed")"
assert_eq "[T2] a file in the test folders is none (build may not change them)" "" "$(_t2 'tests/unit/x-test.sh' "")"
_t2_steps '- a | areas: ./scripts/lib/ | serves: DSEVNT-1
- b | areas: `config/x.json` | serves: DSEVNT-1'
assert_eq "[T2] an area written ./dir/ holds the files under it" "" "$(_t2 "$F" "")"
assert_eq "[T2] ...one in backticks holds its file" "" "$(_t2 "config/x.json" "")"
_t2_steps '- a | areas: . | serves: DSEVNT-1'
assert_eq "[T2] the area . is the whole repository" "" "$(_t2 "scripts/lib/x.sh" "")"
_BUILD_STEP_DESC=(); _BUILD_STEP_AREAS=()
assert_eq "[T2] a plan with no steps is not checked" "" "$(_t2 "$F" "")"

# ── T2b ──────────────────────────────────────────────────────────────────────
print_test_section "T2b: the files build's round changed"
G="$TEST_TEMP_DIR/t2b"; mkdir -p "$G"
( cd "$G" && git init -q -b main && git config user.email t@t && git config user.name t
  mkdir -p lib && printf 'a\n' > lib/old.sh && printf 'b\n' > lib/gone.sh && printf 'c\n' > keep.sh
  git add -A && git commit -qm base ) >/dev/null 2>&1
_base="$(git -C "$G" rev-parse HEAD)"
( cd "$G" && printf 'x\n' >> keep.sh && git commit -qam "Build earlier pass" -m "Zbuild-Stage: build"
  git mv lib/old.sh lib/new.sh && git rm -q lib/gone.sh && printf 'n\n' > "lib/with space.sh" && git add -N "lib/with space.sh" ) >/dev/null 2>&1
_fl=""; _build_trace_files_v _fl "$G" "$_base" 2>/dev/null
assert_contains "[T2b] an earlier pass's commit is in the round" "$_fl" "keep.sh"
assert_contains "[T2b] a moved file is its new path" "$_fl" "lib/new.sh"
_lacks "[T2b] ...not its old one" "$_fl" "lib/old.sh"
assert_contains "[T2b] a removed file is in it" "$_fl" "lib/gone.sh"
assert_contains "[T2b] a name with a space is read whole" "$_fl" "lib/with space.sh"

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
    [[ "${4:-}" == no-req ]] || cp "$T4_REQ" "$_a/requirements.json"
    _design_checks "$_a/design.md" "$_ROOT" "$_a/requirements.json"
    _VIOL="$(printf '%s\n' "${_DESIGN_VIOLATIONS[@]+"${_DESIGN_VIOLATIONS[@]}"}")"
    local _v; _FB="$(for _v in "${_DESIGN_VIOLATIONS[@]+"${_DESIGN_VIOLATIONS[@]}"}"; do _dck_plain "$_v"; printf '\n'; done)"
}
# The list intake's own writer makes, through the real router, with only the
# claude binary faked: the check's call is answered "none missing", the
# writer's with the requirement and the limit.
T4_REQ="$TEST_TEMP_DIR/t4-requirements.json"
mkdir -p "$TEST_TEMP_DIR/bin"
cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
p="$(cat)"
if [[ "$p" == *"Your job: check a list of requirements"* ]]; then r='MISSING: none'
else r=$'REQUIREMENT: RQGATE-1 Fail on a missing file.\nLIMIT: LMSHAP-1 Do not emit shape events.'; fi
jq -n --arg r "$r" '{type:"result",subtype:"success",result:$r,usage:{input_tokens:0,output_tokens:0},tool_uses:[]}'
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
( export ZBUILD_REPO_ROOT="$TEST_TEMP_DIR" PATH="$TEST_TEMP_DIR/bin:$PATH" ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json" \
      ZBUILD_RUN_ID=t4-run ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
      ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/t4-events" ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/t4-events/events.jsonl"
  mkdir -p "$ZBUILD_EVENTS_DIR"; : > "$ZBUILD_EVENTS_JSONL"
  # shellcheck source=../../plugins/agent/intake/plugin.sh
  source "$REPO_ROOT/plugins/agent/intake/plugin.sh" >/dev/null 2>&1
  _j=""; _intake_requirements_json_v _j '{"title":"Gate","body":"Fail on a missing file.\n\nDo not emit shape events."}' \
      && printf '%s\n' "$_j" > "$T4_REQ" ) >/dev/null 2>&1
assert_eq "[T4] (fixture) intake's writer listed the requirement and the limit" "RQGATE-1 LMSHAP-1" \
    "$(jq -r '[.requirements[].id] | join(" ")' "$T4_REQ" 2>/dev/null)"
_t4 none " covers: RQGATE-1" ""
assert_contains "[T4] a SPEC that covers nothing is refused" "$_VIOL" "SPEC_COVERS_NOTHING DSWORK-2"
assert_contains "[T4] ...in the rule's words" "$_FB" "DSWORK-2, which covers no requirement, traces to no requirement intake listed — take it out"
_t4 unknown " covers: RQGATE-1" " covers: RQNAME-1"
assert_contains "[T4] a SPEC covering an id intake did not list is refused" "$_VIOL" "SPEC_COVERS_UNKNOWN DSWORK-2 RQNAME-1"
assert_contains "[T4] ...saying so" "$_FB" "DSWORK-2 covers RQNAME-1, which is not a requirement or limit intake listed"
_t4 listed " covers: RQGATE-1" " covers: RQGATE-1"
_lacks "[T4] SPECs covering a listed requirement are not refused" "$_VIOL" "SPEC_COVERS_"
_t4 limit " covers: RQGATE-1" " covers: LMSHAP-1"
_lacks "[T4] a SPEC covering a limit is not refused as untraced" "$_VIOL" "SPEC_COVERS_"
assert_contains "[T4] ...it is refused as covering a limit (ADR-069, LIMIT_COVERED)" "$_VIOL" "LIMIT_COVERED DSWORK-2 LMSHAP-1"
_t4 prefix " covers: RQGATE-1" " covers: GATE-1"
assert_contains "[T4] an id without intake's prefix is not one intake listed" "$_VIOL" "SPEC_COVERS_UNKNOWN DSWORK-2 GATE-1"
# A file whose name the pattern would match, where the check runs.
: > "$TEST_TEMP_DIR/RQGATE-1x"; cd "$TEST_TEMP_DIR" || exit 1
_t4 glob " covers: RQGATE-1" " covers: RQGATE-*"
cd - >/dev/null || exit 1
assert_contains "[T4] a covers id is read as written, never a file pattern" "$_VIOL" "SPEC_COVERS_UNKNOWN DSWORK-2 RQGATE-*"
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
_rev="${_ap#*Then answer the reverse question}"; _rev="${_rev%%UNASKED: <what*}"
# A sentence that says what a test needs is asked for — not the rule's own,
# which says it is asked for only when a requirement asks for it.
# Meaning, not one word: no sentence lets what a test needs, requires or uses
# count as asked for.
_t7s="$(tr '.' '\n' <<< "$_rev" | grep -iE "test" | grep -iE "\b(needs?|needed|requires?|required|uses?|used)\b" | grep -iE "asked for|in scope" || true)"
if [[ -n "$_t7s" ]]; then
    assert_fail "[T7] ...no sentence says what a test needs is asked for" "$_t7s"
else assert_pass "[T7] ...no sentence says what a test needs is asked for"; fi
assert_contains "[T7] each part it names is taken out: its one outcome" "$_ap" \
    "Each part you name here is taken out of the change."

# ── T8 ───────────────────────────────────────────────────────────────────────
print_test_section "T8: the scope lens"
# shellcheck source=../../plugins/agent/review-lens/lib/charters.sh
source "$REPO_ROOT/plugins/agent/review-lens/lib/charters.sh" >/dev/null 2>&1
_sc="$(_flat "$(cat "$REPO_ROOT/plugins/agent/review-lens/lenses/scope.md")")"
_nf="$(awk '/^Not a finding:/{f=1;next} f&&/^$/{exit} f' "$REPO_ROOT/plugins/agent/review-lens/lenses/scope.md")"
_t8s="$(grep -iE "test" <<< "$_nf" | grep -iE "\b(needs?|needed|requires?|required|uses?|used)\b" || true)"
if [[ -n "$_t8s" ]]; then assert_fail "[T8] nothing under Not a finding exempts what a test needs" "$_nf"
else assert_pass "[T8] nothing under Not a finding exempts what a test needs"; fi
_ch="$(_flat "$(_rl_build_lens_prompt scope "DIFF-TEXT" 2>/dev/null)")"
assert_contains "[T8] scope's own sentence on it reaches the built prompt" "$_ch" \
    "A file the change edits because a test needs it is not in scope for that reason"
assert_contains "[T8] the scope lens judges by the rule" "$_ch" "Everything here must trace to a requirement of the issue."
_lacks "[T8] ...its job names no placeholder" "$_ch" "@TRACE_RULE@"

# ── T9 ───────────────────────────────────────────────────────────────────────
print_test_section "T9: a part nothing asks for is taken out"
_IA_REPO="$TEST_TEMP_DIR/t9"; mkdir -p "$_IA_REPO/scripts/lib"; printf 'if [[ $in_block -eq 1 ]]; then\n' > "$_IA_REPO/scripts/lib/acceptance-block.sh"
# ADR-075 §3 (amended 2026-11-27): an UNASKED part has one outcome, the change
# without it; its ACCEPTED IF is the engine's words, never a condition the
# check makes up. The reply as the model writes it, joined as the stage joins it.
_t9r=""; zb_reply_join_v _t9r "UNASKED: acceptance-block.sh refuses an unclosed block
why: no requirement asks for it
accepted if: the file stays under 500 lines
quote: scripts/lib/acceptance-block.sh | if [[ \$in_block -eq 1 ]]; then"
_IA_PROBLEM=""; _ia_parse "$_t9r" "" "the issue" "$_IA_REPO" "" "unasked" >/dev/null 2>&1
_un="$(printf '%s\n' "${_IA_UNASKED[@]+"${_IA_UNASKED[@]}"}")"
assert_contains "[T9] a part nothing asks for is taken, to be taken out: the change without it" "$_un" "ACCEPTED IF: the change without it"
_lacks "[T9] ...never on a condition the check made up" "$_un" "500 lines"
assert_eq "[T9] ...and the answer is not refused" "" "${_IA_PROBLEM:-}"
_t9r=""; zb_reply_join_v _t9r "UNASKED: acceptance-block.sh refuses an unclosed block
why: no requirement asks for it
quote: scripts/lib/acceptance-block.sh | if [[ \$in_block -eq 1 ]]; then"
_IA_PROBLEM=""; _ia_parse "$_t9r" "" "the issue" "$_IA_REPO" "" "unasked" >/dev/null 2>&1
assert_contains "[T9] one with no accepted if is taken the same way" \
    "$(printf '%s\n' "${_IA_UNASKED[@]+"${_IA_UNASKED[@]}"}")" "ACCEPTED IF: the change without it"
assert_eq "[T9] ...and is not asked again" "" "${_IA_PROBLEM:-}"

print_test_results
exit $((FAIL > 0))
