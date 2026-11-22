#!/usr/bin/env bash
# plugins/agent/build/tests/build-step-stands-test.sh — an accepted step answer
# stands, and a step's quote needs no label (#2582 R4 R5; ADR-068 §6, ADR-072
# §3 §4, amended 2026-11-21).
#
# Why: on #1764 run 44910536811 try 1's step check refused only step 7. Try 2
# answered only step 7, and steps 1-6 and 8 were marked "no answer" before their
# kept verdicts were read — a try lost. Later build quoted part of the README
# line it added ("not a line this change added"), and wrote `done — <file> |
# <line>` without `QUOTE:` ("no quote") — the last try lost.
#
# SA1 [R4] a step accepted on an earlier try and not answered now keeps its
#          answer and verdict: no "no answer", the judge is not asked again
# SA2 [R4, review] the quoted file changed elsewhere: the kept answer is judged
#          again, in the same call; SA2b its line is gone: answer it again
# SA3 [R4] the step's words changed: answer it again, saying why
# SA4 [R4] a SPEC it serves changed: answer it again, saying why
# SA5 [R4] a step refused on an earlier try and not answered now: "no answer"
# SA6 [R4] build's prompt says accepted steps stand unless it changes them
# SQ1 [R5] `step N: done — <file> | <line>`, with no QUOTE:, is a quote
# SQ2 [R5] the issue's case: part of exactly one added line is accepted, and
#          the judge is shown the whole line
# SQ3 [R5] part of more than one added line is refused, saying so
# SQ4 [R5] part of a line that was there before is refused, with the whole line
# SQ5 [R5] a quote in no line of the file is refused, saying so
# SQ6 [R5] a done with no `<file> | <line>` is refused, naming the form
# SQ7 [review] a leading elision mark (... or …) is set aside like a trailing one
# SQ8 [review] a quote is tried as written and with its escapes read before it
#          is refused as part of more than one line
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "an accepted step stands; a quote needs no label (#2582)"
setup_test_env "plugin-build-step-stands"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"; : > "$ZBUILD_EVENTS_JSONL"
export ZBUILD_RUN_ID="build-step-stands-$$" ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
ZBUILD_ISSUE="$(zb_test_issue)"; export ZBUILD_ISSUE

# ── The design, written by design's own writer ───────────────────────────────
STEP1='make claim_take add the zbuild:claimed label'
STEP2='describe the claim label in the README'
SPEC1='claim_take labels the issue zbuild:claimed'
SPEC2='the README names the zbuild:claimed label'
DESIGN_MD="$TEST_TEMP_DIR/design.md"; STEPS="$TEST_TEMP_DIR/design-steps.json"
_design() {   # <step 1> <step 2> <SPEC 1> — design's writer makes design-steps.json
    printf '# Claim\n\n## Decision\nOne label.\n\n```steps\n- %s | areas: lib/claim.sh | serves: DSCLM-1\n- %s | areas: README.md | serves: DSCLM-2\n```\n\n```acceptance\nDSCLM-1[code]: %s\n  When: an issue is claimed\n  Then: it has the label\nDSCLM-2[code]: %s\n  When: the README is read\n  Then: it names the label\nWIRING: none\n```\n' \
        "$1" "$2" "$3" "$SPEC2" > "$DESIGN_MD"
    (
        # shellcheck source=../../../../plugins/agent/design/plugin.sh
        source "$REPO_ROOT/plugins/agent/design/plugin.sh" >/dev/null 2>&1
        _design_write_steps "$DESIGN_MD" "$STEPS"
    )
}
_design "$STEP1" "$STEP2" "$SPEC1"
assert_eq "[setup] design wrote two steps, each serving a SPEC" "DSCLM-1 DSCLM-2" \
    "$(jq -r '[.steps[].serves[0]] | join(" ")' "$STEPS" 2>/dev/null)"

# ── The repository: the base, and a branch that added lines ──────────────────
R="$TEST_TEMP_DIR/repo"
CLAIM_LINE='    gh issue edit "$1" --add-label zbuild:claimed'
README_LINE='Default cross-machine claim coordinator for the zbuild daemon. Uses a single shared GitHub issue label (`zbuild:claimed`) on every machine.'
OLD_LINE='The daemon picks up issues labelled zbuild-run and works them one at a time.'
mkdir -p "$R/lib"
(
    cd "$R" && git init -q -b main && git config user.email t@zbuild && git config user.name t
    printf '%s\n' 'claim_take() {' '    :' '}' > lib/claim.sh
    printf '%s\n' '# zbuild' "$OLD_LINE" > README.md
    git add -A && git commit -q -m base
    git checkout -q -b zbuild/issue-1764
    printf '%s\n' 'claim_take() {' "$CLAIM_LINE" '    echo "claimed by zbuild:claimed"' '}' > lib/claim.sh
    printf '%s\n' '# zbuild' "$OLD_LINE" "$README_LINE" > README.md
    git add -A && git commit -q -m "claim label"
) >/dev/null 2>&1
export ZBUILD_REPO_ROOT="$R"

# shellcheck source=../../../../plugins/agent/build/plugin.sh
source "$REPO_ROOT/plugins/agent/build/plugin.sh"
apply_scope_redaction() { cp "$1" "$2"; }
_route_loop_close_final_banner() { return 0; }
MOCK_LOOP_RESPONSE=""
route_to_model_loop() {
    _ROUTE_LOOP_ITERATIONS=1; _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
    _ROUTE_LOOP_INPUT_TOKENS=1; _ROUTE_LOOP_OUTPUT_TOKENS=1
    _ROUTE_LOOP_LAST_RESPONSE="$MOCK_LOOP_RESPONSE"
    return 0
}
CALLS="$TEST_TEMP_DIR/calls"; JPROMPT="$TEST_TEMP_DIR/judge-prompt"; JUDGE_REPLY=""
route_to_model() {
    printf '%s\n' "${ZBUILD_ROUTE_CALL:-main}" >> "$CALLS"
    printf '%s' "$2" > "$JPROMPT"
    printf '%s\n' "$JUDGE_REPLY"
}
AD=""
_run() {   # <case> <build reply> [reuse] — one build try; reuse keeps the case's folder
    AD="$TEST_TEMP_DIR/$1"
    [[ "${3:-}" == reuse ]] || { rm -rf "$AD"; mkdir -p "$AD"; }
    cp "$STEPS" "$AD/design-steps.json"
    MOCK_LOOP_RESPONSE="$2"; : > "$CALLS"; rm -f "$JPROMPT"
    _build_stage_run_inner "" "$AD/design-steps.json" "$AD/diff.patch" "$AD/build-summary.json" "$AD" >"$AD/log" 2>&1 || true
}
_outcome() { jq -r '.outcome // "none"' "$AD/build-summary.json" 2>/dev/null || echo none; }
_findings() { jq -r '[.data.findings[]?.text] | join("\n")' "$AD/build-summary.json" 2>/dev/null; }
_ncalls() { local n=0 l; while IFS= read -r l; do [[ -n "$l" ]] && n=$((n + 1)); done < "$CALLS"; printf '%s' "$n"; }
_lacks() { if [[ "$2" == *"$3"* ]]; then assert_fail "$1" "it has: $3"; else assert_pass "$1"; fi; }
_jp() { cat "$JPROMPT" 2>/dev/null; }

DONE1="step 1: done — QUOTE: lib/claim.sh | $CLAIM_LINE"
DONE2="step 2: done — QUOTE: README.md | $README_LINE"
NN2="step 2: not needed — the README already describes the label"
_try1() {   # <case> — try 1: step 1 done and accepted; step 2 not needed, refused
    JUDGE_REPLY=$'1: does\n2: does not | WHY: the README does not name the label | ACCEPTED IF: the README describes the claim label'
    _run "$1" "$DONE1"$'\n'"$NN2"
}

# ── SA1 ──────────────────────────────────────────────────────────────────────
print_test_section "SA1: a step accepted earlier and not answered now stands"
_try1 sa1
assert_eq "[SA1] try 1: step 2 refused, the try unusable" "unusable" "$(_outcome)"
JUDGE_REPLY='2: does'
_run sa1 "$DONE2" reuse
_f="$(_findings)"
_lacks "[SA1] try 2 answered only step 2: step 1 is not 'no answer'" "$_f" "step 1 has no answer"
assert_eq "[SA1] the judge is asked once, about step 2 only" "1" "$(_ncalls)"
_lacks "[SA1] ...step 1 is not in what it is asked" "$(_jp)" "### step 1"
assert_eq "[SA1] build passes on step 1's kept answer and step 2's new verdict" "pass" "$(_outcome)"
assert_contains "[SA1] the summary shows step 1's answer, kept" \
    "$(cat "$AD/build-summary.md" 2>/dev/null)" 'step 1: done — lib/claim.sh | gh issue edit "$1" --add-label zbuild:claimed'

# ── SA2 ──────────────────────────────────────────────────────────────────────
# Review round 1: a change elsewhere in the quoted file has the kept answer
# judged again, in the same call; only a quoted line that is gone voids it.
print_test_section "SA2: the quoted file changed elsewhere — the kept answer is judged again"
_try1 sa2
printf '%s\n' 'claim_take() {' "$CLAIM_LINE" '    echo "claimed by zbuild:claimed"' '    return 0' '}' > "$R/lib/claim.sh"
JUDGE_REPLY=$'1: does\n2: does'
_run sa2 "$DONE2" reuse
_lacks "[SA2] step 1 is not 'no answer'" "$(_findings)" "step 1"
assert_eq "[SA2] one judge call" "1" "$(_ncalls)"
assert_contains "[SA2] ...asked about step 1 on its kept answer" "$(_jp)" 'the line: lib/claim.sh | gh issue edit "$1" --add-label zbuild:claimed'
assert_eq "[SA2] build passes" "pass" "$(_outcome)"
print_test_section "SA2b: the quoted line is gone — the earlier answer no longer stands"
_try1 sa2b
printf '%s\n' 'claim_take() {' '    gh issue edit "$1" --add-label zbuild:taken' '    echo "claimed by zbuild:claimed"' '}' > "$R/lib/claim.sh"
JUDGE_REPLY='2: does'
_run sa2b "$DONE2" reuse
assert_contains "[SA2b] step 1 is to be answered again, saying why" "$(_findings)" \
    "step 1's earlier answer no longer stands: the quoted line is no longer in lib/claim.sh — answer it again"
# Build commits what it finds; the file is put back as the branch first had it.
printf '%s\n' 'claim_take() {' "$CLAIM_LINE" '    echo "claimed by zbuild:claimed"' '}' > "$R/lib/claim.sh"

# ── SA3 ──────────────────────────────────────────────────────────────────────
print_test_section "SA3: the step's words changed — the kept answer does not stand"
_try1 sa3
_design "$STEP1 and nothing else" "$STEP2" "$SPEC1"
JUDGE_REPLY='2: does'
_run sa3 "$DONE2" reuse
assert_contains "[SA3] step 1 is to be answered again, saying why" "$(_findings)" \
    "step 1's earlier answer no longer stands: the step or a SPEC it serves changed — answer it again"
_design "$STEP1" "$STEP2" "$SPEC1"

# ── SA4 ──────────────────────────────────────────────────────────────────────
print_test_section "SA4: a SPEC the step serves changed — the kept answer does not stand"
_try1 sa4
_design "$STEP1" "$STEP2" "$SPEC1, and only that label"
JUDGE_REPLY='2: does'
_run sa4 "$DONE2" reuse
assert_contains "[SA4] step 1 is to be answered again, saying why" "$(_findings)" \
    "step 1's earlier answer no longer stands: the step or a SPEC it serves changed — answer it again"
_design "$STEP1" "$STEP2" "$SPEC1"

# ── SA5 ──────────────────────────────────────────────────────────────────────
print_test_section "SA5: a step refused earlier and not answered now has no answer"
_try1 sa5
JUDGE_REPLY='1: does'
_run sa5 "$DONE1"$'\n'"$NN2" reuse
_run sa5 "$DONE1" reuse
assert_contains "[SA5] step 2 is 'no answer'" "$(_findings)" "step 2 has no answer"

# ── SA6 ──────────────────────────────────────────────────────────────────────
print_test_section "SA6: build's prompt says accepted steps stand"
_sa6_p=""; _build_steps_load "$(cat "$STEPS")"
_build_steps_instructions_v _sa6_p
assert_contains "[SA6] the prompt says a step accepted earlier stands unless build changes it" \
    "$_sa6_p" "A step accepted on an earlier try stands"
assert_contains "[SA6] ...is judged again when the code its line is in changes" \
    "$_sa6_p" "When the code its line is in changes, it is judged again on that answer"
assert_contains "[SA6] ...and is asked again when its line is gone or the step or a SPEC changes" \
    "$_sa6_p" "when its line is gone, or the step or a SPEC it serves changes, you are asked to answer it again"

# ── SQ1 ──────────────────────────────────────────────────────────────────────
print_test_section "SQ1: done — <file> | <line>, with no QUOTE:, is a quote"
JUDGE_REPLY=$'1: does\n2: does'
_run sq1 "step 1: done — lib/claim.sh | $CLAIM_LINE"$'\n'"step 2: done — README.md | $README_LINE"
assert_eq "[SQ1] both quotes are read; build passes" "pass" "$(_outcome)"
assert_contains "[SQ1] the judge is shown the line" "$(_jp)" 'the line: lib/claim.sh | gh issue edit "$1" --add-label zbuild:claimed'

# ── SQ2 ──────────────────────────────────────────────────────────────────────
print_test_section "SQ2: the issue's case — part of one added line is accepted, judged whole"
JUDGE_REPLY=$'1: does\n2: does'
_run sq2 "$DONE1"$'\n''step 2: done — README.md | Uses a single shared GitHub issue label (`zbuild:claimed`)'
_lacks "[SQ2] the part is not refused" "$(_findings)" "step 2"
assert_contains "[SQ2] the judge is shown the whole line" "$(_jp)" "the line: README.md | $README_LINE"
assert_eq "[SQ2] build passes" "pass" "$(_outcome)"

# ── SQ3 ──────────────────────────────────────────────────────────────────────
print_test_section "SQ3: part of more than one added line is refused, saying so"
JUDGE_REPLY='2: does'
_run sq3 'step 1: done — lib/claim.sh | zbuild:claimed'$'\n'"$DONE2"
assert_contains "[SQ3] the finding says the quote is part of more than one added line" \
    "$(_findings)" "step 1's quote is part of more than one line this change added in lib/claim.sh"

# ── SQ4 ──────────────────────────────────────────────────────────────────────
print_test_section "SQ4: part of a line that was there before is refused, with the whole line"
JUDGE_REPLY='1: does'
_run sq4 "$DONE1"$'\n''step 2: done — README.md | picks up issues labelled zbuild-run'
assert_contains "[SQ4] the finding says it is part of a line that was already there, and gives it" \
    "$(_findings)" "step 2's quote is part of a line this change did not add in README.md: $OLD_LINE"

# ── SQ5 ──────────────────────────────────────────────────────────────────────
print_test_section "SQ5: a quote in no line of the file is refused, saying so"
JUDGE_REPLY='1: does'
_run sq5 "$DONE1"$'\n''step 2: done — README.md | nothing like this is written anywhere'
assert_contains "[SQ5] the finding says it is in no line of the file" \
    "$(_findings)" "step 2's quote is not in any line of README.md"

# ── SQ6 ──────────────────────────────────────────────────────────────────────
print_test_section "SQ6: a done with no <file> | <line> names the form"
JUDGE_REPLY='1: does'
_run sq6 "$DONE1"$'\n''step 2: done — I described the label in the README'
assert_contains "[SQ6] the finding names the form an answer takes" \
    "$(_findings)" "step 2 is answered done with no \`<file> | <line>\`"

# ── SQ7 ──────────────────────────────────────────────────────────────────────
print_test_section "SQ7: a leading elision mark is not part of the line"
JUDGE_REPLY=$'1: does\n2: does'
_run sq7 "$DONE1"$'\n''step 2: done — README.md | ...Uses a single shared GitHub issue label (`zbuild:claimed`)'
assert_contains "[SQ7] ...the part is found, and judged whole" "$(_jp)" "the line: README.md | $README_LINE"
_run sq7b "$DONE1"$'\n''step 2: done — README.md | …Uses a single shared GitHub issue label'
assert_eq "[SQ7] ...with … too" "pass" "$(_outcome)"

# ── SQ8 ──────────────────────────────────────────────────────────────────────
# Review on PR #2583: the quote as written is part of several added lines, but
# with its escapes read it is part of exactly one — it is taken.
print_test_section "SQ8: a quote whose escaped form is in several lines but read form in one is taken"
PLAIN_LINE='The coordinator uses `zbuild:held` on every machine.'
printf '%s\n' '# zbuild' "$OLD_LINE" "$README_LINE" 'one uses \`zbuild:held\` on Monday' 'two uses \`zbuild:held\` on Tuesday' "$PLAIN_LINE" > "$R/README.md"
JUDGE_REPLY=$'1: does\n2: does'
_run sq8 "$DONE1"$'\n''step 2: done — README.md | uses \`zbuild:held\` on'
_lacks "[SQ8] the quote is not refused as in more than one line" "$(_findings)" "more than one line"
assert_contains "[SQ8] ...the one line its read form is in is judged" "$(_jp)" "the line: README.md | $PLAIN_LINE"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
