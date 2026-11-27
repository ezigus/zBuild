#!/usr/bin/env bash
# tests/unit/checks-held-to-findings-test.sh — a check is held to its earlier
# findings: for a part it refused before, it is shown that finding and the
# stage's answer to it, and says whether the answer resolves it (#2569 R1,
# ADR-072 §5).
#
# Why: on #1764 run 44530053809 design's check let the step "Create
# core/claim/claim.sh: thin wiring bridge …" pass in try 2 and refused it,
# word for word the same, in try 3. Every check was composed from scratch: it
# was never shown its own earlier finding, or design's `done` answer to it —
# only a `wrong` answer reached it, as a dispute.
#
# H1 [change] #1764's case: design's check refused the steps in try 1, design
#             answered `done`, the steps are unchanged in try 2 — the try-2
#             check is asked about the steps again, shown its earlier finding
#             with its ACCEPTED IF and design's answer, and asked whether the
#             answer resolves it
# H2 [change] a part the check never refused is not among its earlier findings
# H3 [change] a `not mine` answer reaches the check too
# H4 [change] the shared reader gives a check every answer to its findings —
#             done, wrong and not mine
# H5 [change] test-author's check: a SPEC it refused, answered `done`, unchanged
#             — it is judged again, shown its finding and the answer
# H6 [change] issue-acceptance: build's `done` answer to its finding has it
#             judge again, shown the finding and the answer
# H7 [change] build's step check: a step it refused before is judged with its
#             earlier finding beside build's new answer
# H8 [change] (review, #1764's flip) the answer is not in the fingerprint: a
#             part refused, answered done, judged again and passed, is not
#             judged again on the next try, which gives no answer — its kept
#             pass is used, with no call; test-author's check the same
# H9 [change] (review) each earlier finding tells the check whether the part is
#             word for word as it was when it refused it: a done answer to an
#             unchanged part is visibly unsupported, and a check that passes a
#             part only when told it changed refuses it again
# H10 [change] (review) the earlier-findings block is capped: entries, and each
#             finding's and answer's length
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "a check is held to its earlier findings (#2569 R1)"
setup_test_env "checks-held-to-findings"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"
HELD="YOUR EARLIER FINDINGS, AND THE ANSWERS TO THEM"
ASK="say whether the answer resolves it"
ACC="the engine itself calls the claim coordinator's claim and release hooks through the plugin registry"
# What each earlier finding says about its part (H9): the same, or changed.
SAME="the same, word for word, as when you refused it"
CHGD="has changed since you refused it"

# ── H1–H3, H8, H9: design's check ────────────────────────────────────────────
( # shellcheck source=../../plugins/agent/design/plugin.sh
  source "$REPO_ROOT/plugins/agent/design/plugin.sh"
  _P_FILE="$TEST_TEMP_DIR/design-prompt.txt"; _CALLS="$TEST_TEMP_DIR/design-calls"
  # H9: this check passes the steps only when it is told they changed since it
  # refused them; told nothing, or that they are the same, it refuses again.
  REFUSE="Steps: contradicts | WHY: bypassing plugin_hook_call | ACCEPTED IF: $ACC | QUOTE: Create core/claim/claim.sh: thin wiring bridge"
  route_to_model() {
      printf 'x\n' >> "$_CALLS"; printf '%s' "$2" >> "$_P_FILE"
      if [[ "$2" == *"$CHGD"* || ( -n "${_OK_WHEN_HELD:-}" && "$2" == *"$HELD"* ) ]]; then printf '%s' $'RQCL-1: covered\nCLA-1: ok\nSteps: ok\nDecision: ok'
      else printf '%s' $'RQCL-1: covered\nCLA-1: ok\n'"$REFUSE"$'\nDecision: ok'; fi
      return 0; }
  XR="$TEST_TEMP_DIR/repo"; mkdir -p "$XR"; export _DESIGN_BASE_DIR="$XR"
  export artifact_dir="$TEST_TEMP_DIR/design-art"; mkdir -p "$artifact_dir"
  D="$TEST_TEMP_DIR/design.md"
  _design() { cat > "$D" <<MD
# Design
## Decision
Claim through the coordinator.

\`\`\`steps
- Create core/claim/claim.sh: thin wiring bridge that adds zbuild:claimed$1 | areas: core/claim/claim.sh
\`\`\`
\`\`\`acceptance
CLA-1[code]: the run adds the claimed label before the first stage covers: RQCL-1
  When: a run starts on an issue with no claimed label
  Then: the claimed label is on the issue
WIRING: core/pipeline/runner.sh
\`\`\`
MD
  }
  _design ""
  REQS='- RQCL-1: the run adds the claimed label before the first stage'
  _run() { : > "$_P_FILE"; : > "$_CALLS"; ZBUILD_REPO_ROOT="$XR" _design_coverage "$D" "$REQS" T2 "${1:-}"
           printf '%s: outcome=%s findings=%s calls=%s\n' "$2" "$_DESIGN_COV_OUTCOME" \
               "$(_design_coverage_findings | grep -c . || true)" "$(grep -c x "$_CALLS" || true)"; }
  # Try 1: the steps refused. Design's result is written by design's writer,
  # with the check's findings as design's run carries them.
  _run "" try1
  _design_write_outcome "$artifact_dir" unusable "the design fails 1 of its checks" \
      "$(_design_coverage_findings | stage_findings_json)"
  # H3: a not mine answer, the steps word for word the same.
  _run "design finding 1: not mine — the steps are build's to carry out" h3
  cp "$_P_FILE" "$TEST_TEMP_DIR/h3-prompt.txt"
  # H1: design answered its finding done; the steps are word for word the same.
  _run "design finding 1: done — the step now calls the coordinator's hooks through the plugin registry" h1
  cp "$_P_FILE" "$TEST_TEMP_DIR/h1-prompt.txt"
  # H9: design changed the step and answered done.
  _design " through plugin_hook_call"
  _run "design finding 1: done — the step now calls the coordinator's hooks through the plugin registry" h9
  cp "$_P_FILE" "$TEST_TEMP_DIR/h9-prompt.txt"
  # H8: the next try gives no answer; the steps are as in the try that passed them.
  _run "" h8
  # H8b: #1764's sequence on unchanged steps, with a check that accepts the
  # done answer: refused, answered done and passed, then a try with no answer.
  export artifact_dir="$TEST_TEMP_DIR/design-art-8b"; mkdir -p "$artifact_dir"; _design ""; _OK_WHEN_HELD=1
  _run "" h8b-try1
  _design_write_outcome "$artifact_dir" unusable "the design fails 1 of its checks" \
      "$(_design_coverage_findings | stage_findings_json)"
  _run "design finding 1: done — the step now calls the coordinator's hooks through the plugin registry" h8b-try2
  _design_write_outcome "$artifact_dir" pass "the design passes its checks" "[]"
  _run "" h8b-try3
) > "$TEST_TEMP_DIR/design.log" 2>&1
_log="$(cat "$TEST_TEMP_DIR/design.log")"
assert_contains "[H1] setup: try 1 refused the steps" "$_log" "try1: outcome= findings=1 calls=1"
_h1="$(cat "$TEST_TEMP_DIR/h1-prompt.txt" 2>/dev/null)"
_h1s="$(tr -s '[:space:]' ' ' <<< "$_h1")"
print_test_section "H1: #1764 — the unchanged steps are judged against the earlier finding"
assert_contains "[H1] the check is asked about the steps again" "$_h1" "STEPS —"
assert_contains "[H1] ...shown its earlier findings" "$_h1" "$HELD"
assert_contains "[H1] ...its finding on the steps" "$_h1" "bypassing plugin_hook_call"
assert_contains "[H1] ...with its ACCEPTED IF" "$_h1" "ACCEPTED IF: $ACC"
assert_contains "[H1] ...and design's answer to it" "$_h1" "answered: done — the step now calls the coordinator's hooks through the plugin registry"
assert_contains "[H1] ...and asked whether the answer resolves it" "$_h1s" "$ASK"

print_test_section "H2: a part never refused is judged from scratch"
assert_eq "[H2] one earlier finding is shown" "1" "$(grep -c '^- design finding ' <<< "$_h1" || true)"
_held_block="$(awk -v h="$HELD" 'index($0, h) { f = 1; next } f && /^[[:space:]]*$/ { f = 0 } f' <<< "$_h1")"
assert_contains "[H2] ...the steps' finding is in the block" "$_held_block" "bypassing plugin_hook_call"
assert_eq "[H2] ...and CLA-1, never refused, is not in it" "0" "$(grep -c 'CLA-1' <<< "$_held_block" || true)"

print_test_section "H3: a not mine answer reaches the check"
assert_contains "[H3] the not mine answer is shown with the finding" "$(cat "$TEST_TEMP_DIR/h3-prompt.txt" 2>/dev/null)" \
    "answered: not mine — the steps are build's to carry out"

print_test_section "H9: the check is told whether the part changed since it refused it"
assert_contains "[H9] a done answer to the unchanged steps: the check is told they are the same" "$_h1s" "$SAME"
_lacks9() { if [[ "$2" == *"$3"* ]]; then assert_fail "$1" "it has: $3"; else assert_pass "$1"; fi; }
_lacks9 "[H9] ...and not that they changed" "$_h1s" "$CHGD"
assert_contains "[H9] ...so the check, which passes them only when they changed, refuses them again" "$_log" "h1: outcome= findings=1 calls=1"
assert_contains "[H9] the steps changed and answered done: the check is told they changed" \
    "$(tr -s '[:space:]' ' ' < "$TEST_TEMP_DIR/h9-prompt.txt" 2>/dev/null)" "$CHGD"
assert_contains "[H9] ...and passes them" "$_log" "h9: outcome= findings=0 calls=1"

print_test_section "H8: a part passed after its answer is not judged again on the next try"
assert_contains "[H8] the next try, with no answer, keeps the pass: no finding, no call" "$_log" "h8: outcome= findings=0 calls=0"
assert_contains "[H8] #1764's sequence: refused in try 1" "$_log" "h8b-try1: outcome= findings=1 calls=1"
assert_contains "[H8] ...answered done, judged again and passed in try 2" "$_log" "h8b-try2: outcome= findings=0 calls=1"
assert_contains "[H8] ...try 3, with no answer, uses the kept pass: no call" "$_log" "h8b-try3: outcome= findings=0 calls=0"

# ── H4: the shared reader ────────────────────────────────────────────────────
print_test_section "H4: every answer to a check's findings reaches it"
( source "$REPO_ROOT/scripts/lib/stage-result.sh"; source "$REPO_ROOT/scripts/lib/judge.sh"
  A4="$TEST_TEMP_DIR/h4"; mkdir -p "$A4"
  stage_result_write "$A4/test-author-result.json" pass "tests written" \
      '{"answers":["lens-sre-code finding 1: not mine — a code fix"]}' >/dev/null
  stage_result_write "$A4/build-summary.json" pass "built" \
      '{"answers":["lens-sre-code finding 2: done — emits an event","lens-sre-code finding 3: wrong — the write cannot fail there"]}' >/dev/null
  _a=""; judge_answers_to_v _a "$A4" lens-sre-code
  printf '%s\n' "$_a" | sort ) > "$TEST_TEMP_DIR/h4.txt" 2>&1
assert_eq "[H4] done, wrong and not mine all reach the check" \
    $'lens-sre-code finding 1: not mine — a code fix\nlens-sre-code finding 2: done — emits an event\nlens-sre-code finding 3: wrong — the write cannot fail there' \
    "$(cat "$TEST_TEMP_DIR/h4.txt")"

# ── H5, H8, H9: test-author's check ─────────────────────────────────────────
print_test_section "H5: test-author's check is held to its finding"
( # shellcheck source=../../plugins/agent/test-author/plugin.sh
  source "$REPO_ROOT/plugins/agent/test-author/plugin.sh"
  _P_FILE="$TEST_TEMP_DIR/ta-prompt.txt"; _CALLS="$TEST_TEMP_DIR/ta-calls"
  # As in H9 for design: it passes the SPEC only when told its test changed.
  route_to_model() {
      cat >/dev/null; printf 'x\n' >> "$_CALLS"; printf '%s' "$2" >> "$_P_FILE"
      if [[ "$2" == *"$CHGD"* ]]; then printf '%s' 'SPEC-1: ok'; else printf '%s' "$_REFUSE"; fi
      return 0; }
  _REFUSE='SPEC-1 Then: missing | WHY: one case of several | ACCEPTED IF: the test asserts thing 1 holds for every case | QUOTE: thing 1 holds for every case'
  R="$TEST_TEMP_DIR/ta-repo"; mkdir -p "$R/tests"; git -C "$R" init -q; D="$TEST_TEMP_DIR/ta-design.md"
  printf '# Design\n```acceptance\nSPEC-1[code]: thing 1 holds for every case\nWIRING: none\n```\n' > "$D"
  printf 'assert_eq "[SPEC-1] thing 1 holds" "1" "$got"\n' > "$R/tests/acc-test.sh"
  ART="$TEST_TEMP_DIR/ta-art"; mkdir -p "$ART"
  _ta() { : > "$_CALLS"; : > "$_P_FILE"; _ta_correspondence "$D" "$R" T2 "$ART" >/dev/null 2>&1
          printf '%s: calls=%s findings=%s\n' "$1" "$(grep -c x "$_CALLS" || true)" "${#_TA_CORR_FINDINGS[@]}"
          cp "$_P_FILE" "$TEST_TEMP_DIR/ta-$1-prompt.txt"; }
  _TA_ANSWERS=(); _ta try1
  _ta_write_result "$ART" unusable "the check found 1" 1 "$(printf '%s\n' "${_TA_CORR_FINDINGS[@]}" | stage_findings_json)" >/dev/null 2>&1
  # H5/H9: answered done, the test word for word the same.
  _TA_ANSWERS=("test-author finding 1: done — the test now asserts every case"); _ta same
  # H9: the test changed, answered done.
  printf 'assert_eq "[SPEC-1] thing 1 holds for every case" "3" "$cases_that_hold"\n' > "$R/tests/acc-test.sh"
  _ta changed
  # H8: the next try, no answer, the test as it was when it passed.
  _TA_ANSWERS=(); _ta next ) > "$TEST_TEMP_DIR/h5.log" 2>&1
_h5="$(cat "$TEST_TEMP_DIR/ta-same-prompt.txt" 2>/dev/null)"; _h5l="$(cat "$TEST_TEMP_DIR/h5.log")"
assert_contains "[H5] setup: try 1 refused the SPEC" "$_h5l" "try1: calls=1 findings=1"
assert_contains "[H5] the SPEC answered done is judged again" "$_h5l" "same: calls=1"
assert_contains "[H5] ...shown its earlier findings" "$_h5" "$HELD"
assert_contains "[H5] ...its finding, with its ACCEPTED IF" "$_h5" "ACCEPTED IF: the test asserts thing 1 holds for every case"
assert_contains "[H5] ...and test-author's answer" "$_h5" "answered: done — the test now asserts every case"
assert_contains "[H9] test-author's check is told the test is the same" "$(tr -s '[:space:]' ' ' <<< "$_h5")" "$SAME"
assert_contains "[H9] ...and refuses it again" "$_h5l" "same: calls=1 findings=1"
assert_contains "[H9] the test changed: it is told so" "$(tr -s '[:space:]' ' ' < "$TEST_TEMP_DIR/ta-changed-prompt.txt" 2>/dev/null)" "$CHGD"
assert_contains "[H9] ...and passes it" "$_h5l" "changed: calls=1 findings=0"
assert_contains "[H8] test-author: the next try, with no answer, keeps the pass with no call" "$_h5l" "next: calls=0 findings=0"

# ── H6: issue-acceptance ─────────────────────────────────────────────────────
print_test_section "H6: issue-acceptance is held to its finding"
( PLUGIN_DIR="$REPO_ROOT/plugins/agent/issue-acceptance"
  # shellcheck source=../../plugins/agent/issue-acceptance/plugin.sh
  source "$PLUGIN_DIR/plugin.sh" 2>/dev/null
  source "$REPO_ROOT/scripts/lib/stage-result.sh"
  set +e
  _IA_PROMPT="$TEST_TEMP_DIR/ia-prompt.txt"; _IA_CALLS="$TEST_TEMP_DIR/ia-calls"
  route_to_model() { printf 'x\n' >> "$_IA_CALLS"; printf '%s' "$2" > "$_IA_PROMPT"; printf '%s\n' "$_IA_ANSWER"; return 0; }
  resolve_tier() { printf 'T2'; }
  _S="$TEST_TEMP_DIR/ia"; _A="$_S/artifacts"; _in="$_S/inputs"; mkdir -p "$_A" "$_in"
  printf '{}' > "$_S/pipeline-state.json"
  zb_test_issue_output "$_in" "Add --from-stage. Acceptance: - [ ] --from-stage starts the run at that stage" >/dev/null
  printf '%s\n' '# Design' '```acceptance' 'DSFSTG-1[code]: --from-stage starts the run at that stage' 'WIRING: none' '```' > "$_in/design.md"
  printf '%s\n' 'from_stage="$1"' 'resume_required=0' > "$_S/runner.sh"
  printf '%s\n' 'diff --git a/runner.sh b/runner.sh' '+from_stage="$1"' '+resume_required=0' > "$_in/diff.patch"
  zb_test_test_run_output "$_in" pass 1 0 >/dev/null
  jq -n --arg i "$_in/intake-result.json" --arg d "$_in/design.md" --arg p "$_in/diff.patch" --arg t "$_in/test-results.json" \
      '{inputs: {a: $i, b: $d, c: $p, d: $t}}' > "$_S/stage-inputs.json"
  export ZBUILD_STAGE_INPUTS="$_S/stage-inputs.json" ZBUILD_ARTIFACT_DIR="$_A" ZBUILD_REPO_ROOT="$_S"
  _IA_ANSWER=$'MET: --from-stage starts the run at that stage\nUNASKED: it drops the rule that --from-stage needs --resume | WHY: no requirement asks to drop it | ACCEPTED IF: the change keeps the rule that --from-stage needs --resume | QUOTE: runner.sh | resume_required=0'
  : > "$_IA_CALLS"; issue_acceptance_run issue-acceptance "$_S/pipeline-state.json" >/dev/null 2>&1
  # #2574: named by its id.
  _fid="$(jq -r '.data.findings[0].id' "$_A/issue-acceptance-code-result.json")"
  stage_result_write "$_A/build-summary.json" pass "built" \
      "{\"answers\":[\"$_fid: done — the rule is back\"]}" >/dev/null
  _IA_ANSWER=$'MET: --from-stage starts the run at that stage\nUNASKED: none'
  : > "$_IA_CALLS"; : > "$_IA_PROMPT"; issue_acceptance_run issue-acceptance "$_S/pipeline-state.json" >/dev/null 2>&1
  printf 'calls=%s outcome=%s\n' "$(grep -c x "$_IA_CALLS" || true)" "$(jq -r .outcome "$_A/issue-acceptance-result.json")" ) > "$TEST_TEMP_DIR/h6.log" 2>&1
_h6="$(cat "$TEST_TEMP_DIR/ia-prompt.txt" 2>/dev/null)"
assert_contains "[H6] build's done answer has it judge again" "$(cat "$TEST_TEMP_DIR/h6.log")" "calls=1 outcome=pass"
assert_contains "[H6] ...shown its earlier findings" "$_h6" "$HELD"
assert_contains "[H6] ...its finding, with its ACCEPTED IF (#2629: an unasked part's is the rule's)" "$_h6" "ACCEPTED IF: the change without it, or a requirement that asks for it"
assert_contains "[H6] ...and build's answer" "$_h6" "answered: done — the rule is back"

# ── H7: build's step check ───────────────────────────────────────────────────
print_test_section "H7: build's step check is held to its finding"
( # shellcheck source=../../plugins/agent/build/plugin.sh
  source "$REPO_ROOT/plugins/agent/build/plugin.sh" >/dev/null 2>&1
  JP="$TEST_TEMP_DIR/build-prompt.txt"
  route_to_model() { printf '%s' "$2" > "$JP"; printf '%s\n' "$JUDGE_REPLY"; return 0; }
  BR="$TEST_TEMP_DIR/build-repo"; mkdir -p "$BR"; BA="$TEST_TEMP_DIR/build-art"; mkdir -p "$BA"
  export ZBUILD_REPO_ROOT="$BR"
  _BUILD_STEP_DESC=("make the claim hook add zbuild:claimed"); _BUILD_STEP_AREAS=("plugins/claim/plugin.sh")
  JUDGE_REPLY='1: does not | WHY: the hook still adds claimed:<machine> | ACCEPTED IF: the claim hook adds zbuild:claimed'
  _build_steps_check "step 1: not needed — the hook already claims the issue" "$BR" "$BA" T2
  printf 'try1=%s\n' "${#_BUILD_STEP_FINDINGS[@]}"
  JUDGE_REPLY='1: does'
  _build_steps_check "step 1: not needed — the hook adds zbuild:claimed since the base" "$BR" "$BA" T2
  printf 'try2=%s\n' "${#_BUILD_STEP_FINDINGS[@]}" ) > "$TEST_TEMP_DIR/h7.log" 2>&1
_h7="$(cat "$TEST_TEMP_DIR/build-prompt.txt" 2>/dev/null)"
assert_contains "[H7] setup: try 1 refused the step" "$(cat "$TEST_TEMP_DIR/h7.log")" "try1=1"
assert_contains "[H7] the try-2 check is shown build's new answer" "$_h7" "the hook adds zbuild:claimed since the base"
assert_contains "[H7] ...and its earlier finding on the step" "$_h7" "the hook still adds claimed:<machine>"
assert_contains "[H7] ...with its ACCEPTED IF" "$_h7" "ACCEPTED IF: the claim hook adds zbuild:claimed"
assert_contains "[H7] ...and is asked whether the answer resolves it" "$(tr -s '[:space:]' ' ' <<< "$_h7")" "$ASK"
assert_contains "[H7] an answer that resolves it leaves no finding" "$(cat "$TEST_TEMP_DIR/h7.log")" "try2=0"

# ── H10: the block is capped ─────────────────────────────────────────────────
print_test_section "H10: the earlier-findings block is capped"
( source "$REPO_ROOT/scripts/lib/stage-result.sh"; source "$REPO_ROOT/scripts/lib/stage-summary.sh"
  source "$REPO_ROOT/scripts/lib/judge.sh"
  A10="$TEST_TEMP_DIR/h10"; mkdir -p "$A10"
  _long="$(printf 'w%.0s' $(seq 1 3000))"
  _f=""; _a=""
  for i in $(seq 1 40); do _f+="finding $i $_long"$'\n'; _a+="lens-x-code finding $i: wrong — $(printf 'r%.0s' $(seq 1 900))"$'\n'; done
  stage_result_write "$A10/r.json" fail "found" "$(printf '%s' "$_f" | stage_findings_json | jq -c '{findings: .}')" >/dev/null
  _e=""; judge_held_entries_v _e "$_a" "lens-x-code=$A10/r.json"
  _b=""; judge_held_block_v _b "$_e"
  printf '%s' "$_b" ) > "$TEST_TEMP_DIR/h10.txt" 2>&1
_h10="$(cat "$TEST_TEMP_DIR/h10.txt")"
assert_contains "[H10] setup: entries are shown" "$_h10" "- lens-x-code finding 1: finding 1 w"
_n10="$(grep -c '^- lens-x-code finding ' <<< "$_h10" || true)"
if (( _n10 > 0 && _n10 <= 20 )); then assert_pass "[H10] at most 20 entries are shown ($_n10)"; else assert_fail "[H10] at most 20 entries are shown" "got $_n10"; fi
assert_contains "[H10] ...and the block says how many more were left out" "$_h10" "more earlier findings are not shown"
_w10="$(awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }' <<< "$_h10")"
if (( _w10 <= 1600 )); then assert_pass "[H10] each finding and answer is capped ($_w10 chars)"; else assert_fail "[H10] each finding and answer is capped" "a line of $_w10 chars"; fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
