#!/usr/bin/env bash
# tests/unit/checks-accepted-if-test.sh — every check's refusal says what would
# be accepted, in the check's own words, and the engine writes no advice of its
# own (#2569 R2 R3, ADR-072 §3, ADR-073 §5, ADR-038).
#
# Why: on #1764 run 44530053809 design's check refused a step with "make the
# step agree with the issue" — advice the engine adds from a fixed menu, as it
# does for test-author's check ("make it do what this line says") and
# issue-acceptance ("What would settle it: …"). Design read "through the plugin
# registry" as "call the hook functions". Only design's INSTEAD, written by the
# check for the case, had worked (#1764 run 44417314654).
#
# A1 [change] the shared reader reads ACCEPTED IF beside WHY and QUOTE, written
#             plain or bold; an old INSTEAD is read as ACCEPTED IF; (review)
#             the fields are written back in one order, WHY, ACCEPTED IF,
#             QUOTE — an ACCEPTED IF after the QUOTE is not part of the quote —
#             and a label after a `|` is read in any case
# A2 [change] design's check: a refusal with no ACCEPTED IF is asked again —
#             a step, a SPEC line, a SPEC's first line, a requirement
# A3 [change] design's finding carries the check's ACCEPTED IF, and none of the
#             engine's fixed advice
# A4 [change] design's check is told ACCEPTED IF says what must be true, in the
#             issue's words, never how to build it, with #1764's example
# A5 [change] test-author's check: its finding carries the check's ACCEPTED IF
#             and no fixed advice; it is told ACCEPTED IF names the line it
#             judges against. (review) A part's line with no ACCEPTED IF is
#             judged against that part's own line, which is used: not asked
#             again; a sections line, whose ACCEPTED IF the check writes, is
# A6 [change] issue-acceptance: the same, for UNMET and UNSURE (the
#             requirement is the line); UNASKED, whose ACCEPTED IF the check
#             writes, is asked again without one
# A7 [change] build's step check: the same, for a `does not` (the step is the
#             line); (review) a reply with a good line for one step and none
#             for another keeps the good one: only the other is unread
# A8 [change] a lens finding carries accepted_if; the routed finding shows it;
#             the lens is told what it says. (review) A finding without it is
#             asked again, then costs only itself: the report's other findings
#             are used
# A9 [change] a run's open items read a finding's ACCEPTED IF as what would
#             settle it
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "every check's refusal says what would be accepted (#2569 R2 R3)"
setup_test_env "checks-accepted-if"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"
_lacks() { if [[ "$2" == *"$3"* ]]; then assert_fail "$1" "it has: $3"; else assert_pass "$1"; fi; }
ACC="the engine itself calls the claim coordinator's claim and release hooks through the plugin registry"
NOT_THIS="runner.sh calls plugin_hook_call on the claim-coordinator folder"
JUDGED="ACCEPTED IF names the line you judge against"

# ── A1: the shared reader ────────────────────────────────────────────────────
print_test_section "A1: ACCEPTED IF is read beside WHY and QUOTE"
source "$REPO_ROOT/scripts/lib/reply-units.sh"
_rl() { local v; judge_reply_line_v v "$1"; printf '%s' "$v"; }
assert_eq "[A1] plain" "X-1 Then: how | WHY: w | ACCEPTED IF: a | QUOTE: q" "$(_rl 'X-1 Then: how | WHY: w | ACCEPTED IF: a | QUOTE: q')"
assert_eq "[A1] bold" "X-1 Then: how | WHY: w | ACCEPTED IF: a | QUOTE: q" "$(_rl '**X-1** Then: how | **WHY:** w | **ACCEPTED IF:** a | QUOTE: q')"
assert_eq "[A1] an old INSTEAD is read as ACCEPTED IF" "X-1 Then: how | WHY: w | ACCEPTED IF: a | QUOTE: q" "$(_rl 'X-1 Then: how | WHY: w | INSTEAD: a | QUOTE: q')"
assert_eq "[A1] with no QUOTE" "1: does not | WHY: w | ACCEPTED IF: a" "$(_rl '1: does not | WHY: w | ACCEPTED IF: a')"
assert_eq "[A1] an ACCEPTED IF after the QUOTE is not part of the quote" "X-1 Then: how | WHY: w | ACCEPTED IF: a | QUOTE: q" \
    "$(_rl 'X-1 Then: how | WHY: w | QUOTE: q | ACCEPTED IF: a')"
assert_eq "[A1] ...nor a WHY after it" "X-1 Then: how | WHY: w | ACCEPTED IF: a | QUOTE: f.sh | q" \
    "$(_rl 'X-1 Then: how | ACCEPTED IF: a | QUOTE: f.sh | q | WHY: w')"
assert_eq "[A1] a label after a | is read in any case" "X-1 Then: how | WHY: w | ACCEPTED IF: a | QUOTE: q" \
    "$(_rl 'X-1 Then: how | why: w | Accepted if: a | quote: q')"
assert_eq "[A1] ...a lowercase word inside a field is not a label" "X-1 Then: how | WHY: it does not quote: anything | QUOTE: q" \
    "$(_rl 'X-1 Then: how | WHY: it does not quote: anything | QUOTE: q')"
_rf=""; judge_reply_field_v _rf "$(_rl 'X-1 Then: how | WHY: w | QUOTE: q | Accepted If: a')" QUOTE
assert_eq "[A1] the quote read from such a line is the quote alone" "q" "$_rf"

# ── A2–A4: design's check ────────────────────────────────────────────────────
( # shellcheck source=../../plugins/agent/design/plugin.sh
  source "$REPO_ROOT/plugins/agent/design/plugin.sh"
  _P_FILE="$TEST_TEMP_DIR/design-prompt.txt"
  route_to_model() { printf '%s' "$2" >> "$_P_FILE"; printf '%s' "$_REPLY"; return 0; }
  XR="$TEST_TEMP_DIR/repo"; mkdir -p "$XR"; export _DESIGN_BASE_DIR="$XR"
  D="$TEST_TEMP_DIR/design.md"
  cat > "$D" <<'MD'
# Design
## Decision
Claim through the coordinator.

```steps
- Create core/claim/claim.sh: thin wiring bridge that adds zbuild:claimed | areas: core/claim/claim.sh
```
```acceptance
CLA-1[code]: the run adds the claimed label before the first stage covers: RQCL-1
  When: a run starts on an issue with no claimed label
  Then: the claimed label is on the issue
  And: pipeline.claimed is registered in config/event-schema.json
WIRING: core/pipeline/runner.sh
```
MD
  REQS=$'- RQCL-1: the run adds the claimed label before the first stage\n- RQCL-2: the run releases the label when it ends'
  _run() { : > "$_P_FILE"; _REPLY="$1"; ZBUILD_REPO_ROOT="$XR" _design_coverage "$D" "$REQS" T2
           printf '%s|%s\n' "$_DESIGN_COV_OUTCOME" "$(_design_coverage_findings | tr '\n\036' '  ')"; }
  OK=$'RQCL-1: covered\nRQCL-2: covered\nDecision: ok'
  echo "A2a|$(_run "$OK"$'\nCLA-1: ok\nSteps: contradicts | WHY: bypassing plugin_hook_call | QUOTE: Create core/claim/claim.sh: thin wiring bridge')|$(tr -s '[:space:]' ' ' < "$_P_FILE")"
  echo "A2b|$(_run "$OK"$'\nSteps: ok\nCLA-1 And: untestable | WHY: it is what a file contains | QUOTE: is registered in config/event-schema.json')|$(tr -s '[:space:]' ' ' < "$_P_FILE")"
  echo "A2c|$(_run "$OK"$'\nSteps: ok\nCLA-1 Title: not-asked | WHY: no requirement asks for a stage order | QUOTE: before the first stage')|$(tr -s '[:space:]' ' ' < "$_P_FILE")"
  echo "A2d|$(_run $'RQCL-1: covered\nRQCL-2: uncovered | WHY: no SPEC releases it | QUOTE: the run releases the label when it ends\nDecision: ok\nSteps: ok\nCLA-1: ok')|$(tr -s '[:space:]' ' ' < "$_P_FILE")"
  echo "A3a|$(_run "$OK"$'\nCLA-1: ok\nSteps: contradicts | WHY: bypassing plugin_hook_call | ACCEPTED IF: '"$ACC"$' | QUOTE: Create core/claim/claim.sh: thin wiring bridge')"
  echo "A3b|$(_run "$OK"$'\nSteps: ok\nCLA-1 And: untestable | WHY: it is what a file contains | ACCEPTED IF: a test sees pipeline.claimed emitted with no unknown-event warning | QUOTE: is registered in config/event-schema.json')"
  echo "A3c|$(_run "$OK"$'\nSteps: ok\nCLA-1 Title: not-asked | WHY: no requirement asks for a stage order | ACCEPTED IF: the SPEC asks only that the run adds the label | QUOTE: before the first stage')"
  echo "A3d|$(_run $'RQCL-1: covered\nRQCL-2: uncovered | WHY: no SPEC releases it | ACCEPTED IF: a SPEC says the label is gone once the run ends | QUOTE: the run releases the label when it ends\nDecision: ok\nSteps: ok\nCLA-1: ok')"
  echo "A4|$(tr -s '[:space:]' ' ' < "$_P_FILE")"
) > "$TEST_TEMP_DIR/design.out" 2>/dev/null
_d() { /usr/bin/grep "^$1|" "$TEST_TEMP_DIR/design.out"; }
print_test_section "A2: design's refusal with no ACCEPTED IF is asked again"
for _c in A2a:Steps A2b:"CLA-1 And" A2c:"CLA-1 Title" A2d:RQCL-2; do
    _k="${_c%%:*}" _w="${_c#*:}"
    assert_contains "[A2] $_w with no ACCEPTED IF cannot be used" "$(_d "$_k")" "$_k|unusable|"
    assert_contains "[A2] ...the re-ask says so" "$(_d "$_k")" "$_w"
    assert_contains "[A2] ...naming ACCEPTED IF" "$(_d "$_k")" "has no ACCEPTED IF"
done
print_test_section "A3: design's finding carries the check's ACCEPTED IF, and no fixed advice"
assert_contains "[A3] a step's finding" "$(_d A3a)" "A3a||Steps: a step goes against the issue: bypassing plugin_hook_call"
assert_contains "[A3] ...carries the check's ACCEPTED IF" "$(_d A3a)" "ACCEPTED IF: $ACC"
_lacks "[A3] ...and not the engine's advice" "$(_d A3a)" "make the step agree with the issue"
assert_contains "[A3] a SPEC line's mark carries the check's WHY and ACCEPTED IF" "$(_d A3b)" \
    "[FIX IN DESIGN: it is what a file contains — ACCEPTED IF: a test sees pipeline.claimed emitted with no unknown-event warning]"
_lacks "[A3] ...and not the engine's advice" "$(_d A3b)" "say what a test can see the code do"
assert_contains "[A3] a first line's mark carries it" "$(_d A3c)" "ACCEPTED IF: the SPEC asks only that the run adds the label"
_lacks "[A3] ...and not the engine's advice" "$(_d A3c)" "take it out, or make it what the issue asks"
assert_contains "[A3] an uncovered requirement's finding carries it" "$(_d A3d)" "ACCEPTED IF: a SPEC says the label is gone once the run ends"
_lacks "[A3] ...and not the engine's advice" "$(_d A3d)" "add or widen a SPEC so it covers this"
print_test_section "A4: design's check is told what ACCEPTED IF says"
assert_contains "[A4] what must be true, in the issue's words, never how to build it" "$(_d A4)" \
    "ACCEPTED IF says what must be true for the part to be accepted, in the issue's words — never how to build it: no file, function, command or change to make."
assert_contains "[A4] ...not this" "$(_d A4)" "$NOT_THIS"
assert_contains "[A4] ...this" "$(_d A4)" "ACCEPTED IF: $ACC"
assert_contains_lines "[A4] the refusal forms carry ACCEPTED IF" "$(_d A4)" \
    $'Steps: contradicts\nwhy: <which requirement, limit or term, and how>\naccepted if: <what must be true for the steps to be accepted>\nquote: <the step\'s words>'
_lacks "[A4] ...and INSTEAD is gone" "$(_d A4)" "INSTEAD:"

# ── A5: test-author's check ──────────────────────────────────────────────────
print_test_section "A5: test-author's check"
( # shellcheck source=../../plugins/agent/test-author/plugin.sh
  source "$REPO_ROOT/plugins/agent/test-author/plugin.sh"
  _P_FILE="$TEST_TEMP_DIR/ta-prompt.txt"
  route_to_model() { cat >/dev/null; printf '%s' "$2" >> "$_P_FILE"; printf '%s' "$_REPLY"; return 0; }
  R="$TEST_TEMP_DIR/ta-repo"; mkdir -p "$R/tests"; git -C "$R" init -q; D="$TEST_TEMP_DIR/ta-design.md"
  printf '# Design\n```acceptance\nSPEC-1[code]: thing 1 holds for every case\nWIRING: none\n```\n' > "$D"
  printf 'assert_eq "[SPEC-1] thing 1 holds" "1" "$got"\n' > "$R/tests/acc-test.sh"
  _REPLY='SPEC-1 Then: missing | WHY: one case of several | QUOTE: thing 1 holds for every case'
  : > "$_P_FILE"; _ta_correspondence "$D" "$R" T2 >/dev/null 2>&1
  echo "A5a|$_TA_CORR_OUTCOME|${_TA_CORR_FINDINGS[0]:-}|$(tr -s '[:space:]' ' ' < "$_P_FILE")"
  _REPLY='SPEC-1 sections: missing | WHY: no When heading | QUOTE: tests/acc-test.sh | assert_eq "[SPEC-1] thing 1 holds" "1" "$got"'
  : > "$_P_FILE"; _ta_correspondence "$D" "$R" T2 >/dev/null 2>&1
  echo "A5c|$_TA_CORR_OUTCOME|$(tr -s '[:space:]' ' ' < "$_P_FILE")"
  _REPLY='SPEC-1 Then: missing | WHY: one case of several | ACCEPTED IF: the test asserts thing 1 holds for every case | QUOTE: thing 1 holds for every case'
  : > "$_P_FILE"; _ta_correspondence "$D" "$R" T2 >/dev/null 2>&1
  echo "A5b|$_TA_CORR_OUTCOME|${_TA_CORR_FINDINGS[0]:-}|$(tr -s '[:space:]' ' ' < "$_P_FILE")"
  # #2609: the same answer as a block, as the prompt asks.
  _REPLY=$'SPEC-1 Then: missing\nwhy: one case of several\naccepted if: the test asserts thing 1 holds for every case\nquote: thing 1 holds for every case'
  : > "$_P_FILE"; _ta_correspondence "$D" "$R" T2 >/dev/null 2>&1
  echo "A5d|$_TA_CORR_OUTCOME|${_TA_CORR_FINDINGS[0]:-}" ) > "$TEST_TEMP_DIR/ta.out" 2>/dev/null
_t() { /usr/bin/grep "^$1|" "$TEST_TEMP_DIR/ta.out"; }
assert_contains "[A5] a part's line with no ACCEPTED IF is used" "$(_t A5a)" "A5a||"
assert_contains "[A5] ...judged against the part's own line" "$(_t A5a)" "[FIX IN TEST: one case of several — ACCEPTED IF: thing 1 holds for every case]"
_lacks "[A5] ...and not asked again" "$(_t A5a)" "has no ACCEPTED IF"
assert_contains "[A5] a block answer is read the same (#2609)" "$(_t A5d)" "[FIX IN TEST: one case of several — ACCEPTED IF: the test asserts thing 1 holds for every case]"
assert_contains "[A5] a sections line with no ACCEPTED IF cannot be used" "$(_t A5c)" "A5c|unusable|"
assert_contains "[A5] ...the re-ask says so" "$(_t A5c)" "SPEC-1 sections has no ACCEPTED IF"
assert_contains "[A5] the finding carries the check's ACCEPTED IF" "$(_t A5b)" "[FIX IN TEST: one case of several — ACCEPTED IF: the test asserts thing 1 holds for every case]"
_lacks "[A5] ...and not the engine's advice" "$(_t A5b)" "assert this, so the test fails"
assert_contains "[A5] the check is told ACCEPTED IF names the SPEC line" "$(_t A5b)" "$JUDGED: the SPEC's line"
assert_contains_lines "[A5] ...and the forms carry it" "$(_t A5b)" $'<identifier> <part>: missing\nwhy: <what the test does not do>\naccepted if:'

# ── A6: issue-acceptance ─────────────────────────────────────────────────────
print_test_section "A6: issue-acceptance"
( PLUGIN_DIR="$REPO_ROOT/plugins/agent/issue-acceptance"
  # shellcheck source=../../plugins/agent/issue-acceptance/plugin.sh
  source "$PLUGIN_DIR/plugin.sh" 2>/dev/null
  set +e
  _IA_PROMPT="$TEST_TEMP_DIR/ia-prompt.txt"
  route_to_model() { printf '%s' "$2" >> "$_IA_PROMPT"; printf '%s\n' "$_IA_ANSWER"; return 0; }
  resolve_tier() { printf 'T2'; }
  _ia_case() {
      _S="$TEST_TEMP_DIR/ia-$1"; _A="$_S/artifacts"; local _in="$_S/inputs"; mkdir -p "$_A" "$_in"
      printf '{}' > "$_S/pipeline-state.json"
      zb_test_issue_output "$_in" "Add --from-stage. Acceptance: - [ ] --from-stage starts the run at that stage" >/dev/null
      printf '%s\n' '# Design' '```acceptance' 'DSFSTG-1[code]: --from-stage starts the run at that stage' 'WIRING: none' '```' > "$_in/design.md"
      printf '%s\n' 'from_stage="$1"' 'resume_required=0' > "$_S/runner.sh"
      printf '%s\n' 'diff --git a/runner.sh b/runner.sh' '+from_stage="$1"' '+resume_required=0' > "$_in/diff.patch"
      zb_test_test_run_output "$_in" pass 1 0 >/dev/null
      jq -n --arg i "$_in/intake-result.json" --arg d "$_in/design.md" --arg p "$_in/diff.patch" --arg t "$_in/test-results.json" \
          '{inputs: {a: $i, b: $d, c: $p, d: $t}}' > "$_S/stage-inputs.json"
      ZBUILD_STAGE_INPUTS="$_S/stage-inputs.json" ZBUILD_ARTIFACT_DIR="$_A" ZBUILD_REPO_ROOT="$_S" \
          issue_acceptance_run issue-acceptance "$_S/pipeline-state.json" >/dev/null 2>&1
      printf '%s|%s|%s|%s\n' "$1" "$(jq -r .outcome "$_A/issue-acceptance-result.json")" \
          "$(jq -r '[.data.findings[]?.text] | join(" || ")' "$_A/issue-acceptance-result.json")" "$(tr -s '[:space:]' ' ' < "$_IA_PROMPT")"
      : > "$_IA_PROMPT"
  }
  _IA_ANSWER=$'UNMET: [fix-code] --from-stage starts the run at that stage | WHY: the run starts at stage one | QUOTE: --from-stage starts the run at that stage\nUNASKED: none'
  _ia_case A6a
  _IA_ANSWER=$'UNMET: [fix-code] --from-stage starts the run at that stage | WHY: the run starts at stage one | ACCEPTED IF: a run given --from-stage starts at that stage | QUOTE: --from-stage starts the run at that stage\nUNASKED: none'
  _ia_case A6b
  _IA_ANSWER=$'UNSURE: --from-stage starts the run at that stage | WHY: no test runs it | ACCEPTED IF: a test that runs --from-stage and sees the first stage skipped | QUOTE: --from-stage starts the run at that stage\nUNASKED: it drops the rule | WHY: nothing asks to drop it | ACCEPTED IF: the change without dropping the rule that --from-stage needs --resume | QUOTE: runner.sh | resume_required=0'
  _ia_case A6c
  _IA_ANSWER=$'MET: --from-stage starts the run at that stage\nUNASKED: it drops the rule | WHY: nothing asks to drop it | QUOTE: runner.sh | resume_required=0'
  _ia_case A6d ) > "$TEST_TEMP_DIR/ia.out" 2>/dev/null
_i() { /usr/bin/grep "^$1|" "$TEST_TEMP_DIR/ia.out"; }
_lacks "[A6] an UNMET with no ACCEPTED IF is used" "$(_i A6a)" "A6a|unusable|"
assert_contains "[A6] ...judged against the requirement it names" "$(_i A6a)" "ACCEPTED IF: --from-stage starts the run at that stage"
_lacks "[A6] ...and not asked again" "$(_i A6a)" "has no ACCEPTED IF"
assert_contains "[A6] an UNASKED with no ACCEPTED IF cannot be used" "$(_i A6d)" "A6d|unusable|"
assert_contains "[A6] ...the re-ask says so" "$(_i A6d)" "UNASKED it drops the rule has no ACCEPTED IF"
assert_contains "[A6] an unmet finding carries the check's ACCEPTED IF" "$(_i A6b)" "ACCEPTED IF: a run given --from-stage starts at that stage"
_lacks "[A6] ...and not the engine's advice" "$(_i A6b)" "a change that meets this requirement in full"
assert_contains "[A6] an unsure finding carries it" "$(_i A6c)" "ACCEPTED IF: a test that runs --from-stage and sees the first stage skipped"
_lacks "[A6] ...and not the engine's advice" "$(_i A6c)" "a test that fails when this requirement is not met, or the code"
assert_contains "[A6] an unasked finding carries it" "$(_i A6c)" "ACCEPTED IF: the change without dropping the rule that --from-stage needs --resume"
_lacks "[A6] ...and not the engine's advice" "$(_i A6c)" "the change without this part, or a requirement that asks for it"
assert_contains "[A6] the check is told ACCEPTED IF names the requirement" "$(_i A6b)" "$JUDGED: the requirement"

# ── A7: build's step check ───────────────────────────────────────────────────
print_test_section "A7: build's step check"
( # shellcheck source=../../plugins/agent/build/plugin.sh
  source "$REPO_ROOT/plugins/agent/build/plugin.sh" >/dev/null 2>&1
  JP="$TEST_TEMP_DIR/build-prompt.txt"
  route_to_model() { printf '%s' "$2" >> "$JP"; printf '%s\n' "$JUDGE_REPLY"; return 0; }
  BR="$TEST_TEMP_DIR/build-repo"; mkdir -p "$BR"; export ZBUILD_REPO_ROOT="$BR"
  _BUILD_STEP_DESC=("make the claim hook add zbuild:claimed"); _BUILD_STEP_AREAS=("plugins/claim/plugin.sh")
  _b() { local ad="$TEST_TEMP_DIR/build-$1"; mkdir -p "$ad"; : > "$JP"
         _build_steps_check "step 1: not needed — the hook already claims the issue" "$BR" "$ad" T2
         printf '%s|%s|%s|%s\n' "$1" "${_BUILD_STEP_NOTE}" "${_BUILD_STEP_FINDINGS[*]:-}" "$(tr -s '[:space:]' ' ' < "$JP")"; }
  JUDGE_REPLY='1: does not | WHY: the hook still adds claimed:<machine>'; _b A7a
  JUDGE_REPLY='1: does not | WHY: the hook still adds claimed:<machine> | ACCEPTED IF: the claim hook adds zbuild:claimed'; _b A7b
  # Two steps, a line for the first only, on both tries.
  _BUILD_STEP_DESC=("make the claim hook add zbuild:claimed" "release the label at the end"); _BUILD_STEP_AREAS=("plugins/claim/plugin.sh" "plugins/claim/plugin.sh")
  _b2() { local ad="$TEST_TEMP_DIR/build-$1"; mkdir -p "$ad"; : > "$JP"
         _build_steps_check $'step 1: not needed — the hook already claims the issue\nstep 2: not needed — the hook releases it' "$BR" "$ad" T2
         printf '%s|%s|%s\n' "$1" "${_BUILD_STEP_NOTE}" "$(printf '%s\n' "${_BUILD_STEP_FINDINGS[@]}" | tr '\n' '#')"; }
  JUDGE_REPLY='1: does not | WHY: the hook still adds claimed:<machine> | ACCEPTED IF: the claim hook adds zbuild:claimed'; _b2 A7c
) > "$TEST_TEMP_DIR/build.out" 2>/dev/null
_b() { /usr/bin/grep "^$1|" "$TEST_TEMP_DIR/build.out"; }
_lacks "[A7] a does not with no ACCEPTED IF is read" "$(_b A7a)" "could not be read"
assert_contains "[A7] ...judged against the step" "$(_b A7a)" "ACCEPTED IF: make the claim hook add zbuild:claimed"
_lacks "[A7] ...and not asked again" "$(_b A7a)" "has no ACCEPTED IF"
assert_contains "[A7] a reply with no line for step 2: step 1's verdict is used" "$(_b A7c)" "step 1: your reason it is not needed does not hold: the hook still adds claimed:<machine>"
assert_contains "[A7] ...only step 2 could not be read" "$(_b A7c)" "the check of step 2 could not be read"
_lacks "[A7] ...not step 1" "$(_b A7c)" "the check of step 1 could not be read"
assert_contains "[A7] the finding carries the check's ACCEPTED IF" "$(_b A7b)" "ACCEPTED IF: the claim hook adds zbuild:claimed"
_lacks "[A7] ...and not the engine's advice" "$(_b A7b)" "do the step, then quote the line that does it"
assert_contains "[A7] the check is told ACCEPTED IF names the step" "$(_b A7b)" "$JUDGED: the step"

# ── A8: a lens ───────────────────────────────────────────────────────────────
print_test_section "A8: a lens finding carries accepted_if"
( source "$REPO_ROOT/core/plugin-registry/registry.sh"
  PLUGIN_DIR="$REPO_ROOT/plugins/agent/review-lens"
  # shellcheck source=../../plugins/agent/review-lens/plugin.sh
  source "$PLUGIN_DIR/plugin.sh" 2>/dev/null
  set +e
  G="$TEST_TEMP_DIR/lens-repo"; mkdir -p "$G/core"
  ( cd "$G" && git init -q -b main && git config user.email t@t && git config user.name t
    printf 'keep\n' > core/x.sh && git add -A && git commit -q -m base
    git checkout -q -b feature && printf 'keep\nguard_off() { :; }\n' > core/x.sh && git commit -qam change ) >/dev/null 2>&1
  export ZBUILD_REPO_ROOT="$G" ZBUILD_CURRENT_STAGE=review_lenses _TPL_STAGE_FAIL_ON_review_lenses="medium high critical"
  ART="$TEST_TEMP_DIR/lens-art"; mkdir -p "$ART"
  printf 'diff --git a/core/x.sh b/core/x.sh\n+guard_off() { :; }\n' > "$ART/diff.patch"
  route_to_model() { zb_test_lens_check_answer "$2" && return 0; printf '%s' "$2" >> "$TEST_TEMP_DIR/lens-prompt"; zb_test_lens_lines "$LENS_REPLY"; }
  _f() { jq -nc --arg a "$1" --arg m "${2:-guard_off turns the safety check off}" '{file: "core/x.sh", category: "logic", severity: "medium", message: $m,
        quote: "guard_off() { :; }", trigger: "a template turns the guard on", introduced: true, fix: "code"} + (if $a == "" then {} else {accepted_if: $a} end)'; }
  _lens() { : > "$TEST_TEMP_DIR/lens-prompt"; rm -f "$ART"/lens-red-team*.json "$ART"/*judged*.json
      ( export ZBUILD_MAP_ELEMENT=red-team ZBUILD_REVIEW_LENS_ID=red-team ZBUILD_PLUGIN_DIR="$PLUGIN_DIR"
        cd "$G" && _review_lens_run_inner red-team "" "$ART/diff.patch" "$ART/lens-red-team.json" "$ART" ) >/dev/null 2>&1
      printf '%s|%s|%s|%s\n' "$1" "$(jq -r .outcome "$ART/lens-red-team.json" 2>/dev/null)" \
          "$(jq -r '[.data.findings[]?.text] | join(" || ")' "$ART/lens-red-team-code-result.json" 2>/dev/null)" "$(tr -s '[:space:]' ' ' < "$TEST_TEMP_DIR/lens-prompt")"; }
  LENS_REPLY="{\"score\":4,\"findings\":[$(_f "nothing a template sets can turn the safety check off" "GOOD-FINDING"),$(_f "" "NO-ACCEPTED-IF-FINDING")]}"; _lens A8a
  LENS_REPLY="{\"score\":4,\"findings\":[$(_f "nothing a template sets can turn the safety check off")]}"; _lens A8b
) > "$TEST_TEMP_DIR/lens.out" 2>/dev/null
_l() { /usr/bin/grep "^$1|" "$TEST_TEMP_DIR/lens.out"; }
assert_contains "[A8] a finding with no accepted_if is asked again" "$(_l A8a)" "finding 2 has no accepted_if"
_lacks "[A8] ...then costs only itself: the report is used" "$(_l A8a)" "A8a|unusable|"
_l3() { _l "$1" | awk -F'|' '{ print $3 }'; }
assert_contains "[A8] ...its other finding reaches the stage" "$(_l3 A8a)" "GOOD-FINDING"
# #2598: still none after the re-ask, it reaches the stage marked unchecked
# and blocks: it costs only itself, and the lens never passes on it.
assert_contains "[A8] ...and the one with no accepted_if reaches it marked unchecked" "$(_l A8a)" "this finding could not be checked"
assert_contains "[A8] the routed finding shows the lens's ACCEPTED IF" "$(_l A8b)" "ACCEPTED IF: nothing a template sets can turn the safety check off"
assert_contains "[A8] the lens is told what ACCEPTED IF says" "$(_l A8b)" "never how to build it: no file, function, command or change to make."
assert_contains "[A8] ...with #1764's example" "$(_l A8b)" "$NOT_THIS"
assert_contains "[A8] ...and the field is in its schema" "$(_l A8b)" 'accepted if: <'

# ── A9: open items ───────────────────────────────────────────────────────────
print_test_section "A9: a run's open items read ACCEPTED IF as what would settle it"
source "$REPO_ROOT/scripts/lib/run-open-items.sh"
_o="$(open_items_render '[{"ref":"design finding 1","opener":"design","text":"Steps: a step goes against the issue: bypassing plugin_hook_call [FIX IN DESIGN: ACCEPTED IF: the engine calls the hooks through the registry]"}]')"
assert_contains "[A9] ACCEPTED IF is what would settle it" "$_o" "What would settle it: the engine calls the hooks through the registry"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
