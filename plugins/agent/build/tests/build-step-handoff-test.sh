#!/usr/bin/env bash
# plugins/agent/build/tests/build-step-handoff-test.sh — a part a stage hands
# to another stage is not judged again until that stage has run (#2574 R1;
# ADR-072 §5, amended 2026-11-20).
#
# Why: on #1764 run 44782866204, in round 2, build answered design step 1's
# finding "not mine — the test must change". Its tries 2 and 3 were still
# asked about step 1, and refused again: about 17 minutes in all, while the
# stage that could change the test had not run.
#
# HO1 [change] round 2, try 1: build answers its step-1 finding not mine — the
#              test must change. Step 1 is not judged: the judge is not asked
#              about it, and it is not refused; its finding stays, shown as
#              handed to test-author, waiting. It is open, never a pass: build
#              fails and ends the round, so test-author runs; build-tests
#              carries the finding to it
# HO2 [change] a try again in the round, with no new answer, does not judge or
#              refuse step 1 either; it is still open, and build-tests still
#              carries the finding
# HO3 [change] round 3, after test-author has run: step 1 is judged again, with
#              the earlier finding and the not mine answer beside it
# HO4 [guard]  a not mine answer that hands the finding to no stage (no output
#              of build's carries it) pauses nothing: the step is judged
# HO5 [change] the shared code: the stages a finding is handed to are the
#              stages of this run that take the topic of the output carrying it
# HO6 [change] a step refused when it came back is not handed on again by the
#              reply judged with it; it is judged on the next try. A step waits
#              at most twice; then it is judged
# HO7 [change] a run whose template has no stage that takes the topic (no
#              test-author): nothing waits
# HO8 [change] on the loop's last round nothing waits: the step is judged
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "a handed-on part waits for the other stage (#2574 R1)"
setup_test_env "plugin-build-step-handoff"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"; : > "$ZBUILD_EVENTS_JSONL"
export ZBUILD_RUN_ID="build-handoff-$$" ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
ZBUILD_ISSUE="$(zb_test_issue)"; export ZBUILD_ISSUE

# ── The design's steps, written by design's own writer ───────────────────────
STEP1='Amend plugins/claim-coordinator/github-labels/plugin.sh: change claim_coordinator_claim to use zbuild:claimed; plugin.sh must not source core/claim/claim.sh'
STEP2='add the release helper beside it'
DESIGN_MD="$TEST_TEMP_DIR/design.md"
printf '# Claim label\n\n## Decision\nOne label.\n\n```steps\n- %s | areas: plugins/claim-coordinator/github-labels/plugin.sh\n- %s | areas: plugins/claim-coordinator/github-labels/\n```\n' \
    "$STEP1" "$STEP2" > "$DESIGN_MD"
STEPS="$TEST_TEMP_DIR/design-steps.json"
(
    # shellcheck source=../../../../plugins/agent/design/plugin.sh
    source "$REPO_ROOT/plugins/agent/design/plugin.sh" >/dev/null 2>&1
    _design_write_steps "$DESIGN_MD" "$STEPS"
)
assert_eq "[setup] design wrote two steps" "2" "$(jq '.steps | length' "$STEPS" 2>/dev/null)"

# ── The repository: the base, and a branch that added lines ──────────────────
R="$TEST_TEMP_DIR/repo"; P=plugins/claim-coordinator/github-labels
SRC_LINE='source "$_ccgl_plugin_dir/../../../core/claim/claim.sh"'
mkdir -p "$R/$P" "$R/core/claim"
(
    cd "$R" && git init -q -b main && git config user.email t@zbuild && git config user.name t
    printf '%s\n' '_ccgl_plugin_dir="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"' > "$P/plugin.sh"
    git add -A && git commit -q -m base
    git checkout -q -b zbuild/issue-1764
    printf '%s\n' '_ccgl_plugin_dir="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"' "$SRC_LINE" > "$P/plugin.sh"
    printf '%s\n' 'claim_release() {' '    gh issue edit "$1" --remove-label zbuild:claimed' '}' > "$P/release.sh"
    git add -A && git commit -q -m "earlier round"
) >/dev/null 2>&1
export ZBUILD_REPO_ROOT="$R"

# The run's state: the engine's own records of when each stage ran.
STATE="$TEST_TEMP_DIR/state"; AD="$STATE/artifacts"; mkdir -p "$AD"
printf '{}\n' > "$STATE/pipeline-state.json"
export ZBUILD_STATE_DIR="$STATE" ZBUILD_ARTIFACT_DIR="$AD"
# The run's stages: only a stage of this run is a receiver.
export ZBUILD_INPUTS_FLOW="design test-author build test issue-acceptance"
cp "$STEPS" "$AD/design-steps.json"

# shellcheck source=../../../../plugins/agent/build/plugin.sh
source "$REPO_ROOT/plugins/agent/build/plugin.sh"
# shellcheck source=../../../../scripts/lib/stage-dispatch-mark.sh
source "$REPO_ROOT/scripts/lib/stage-dispatch-mark.sh"
apply_scope_redaction() { cp "$1" "$2"; }
_route_loop_close_final_banner() { return 0; }
MOCK_LOOP_RESPONSE=""
route_to_model_loop() {
    _ROUTE_LOOP_ITERATIONS=1; _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
    _ROUTE_LOOP_INPUT_TOKENS=1; _ROUTE_LOOP_OUTPUT_TOKENS=1
    _ROUTE_LOOP_LAST_RESPONSE="$MOCK_LOOP_RESPONSE"
    return 0
}
# The judge: each call's prompt is kept; it answers JUDGE_REPLY.
CALLS="$TEST_TEMP_DIR/calls"; JPROMPT="$TEST_TEMP_DIR/judge-prompt"; JUDGE_REPLY=""
route_to_model() {
    printf '%s\n' "${ZBUILD_ROUTE_CALL:-main}" >> "$CALLS"
    printf '%s' "$2" > "$JPROMPT"
    printf '%s\n' "$JUDGE_REPLY"
    return 0
}
_try() {   # <build reply> — one build try, dispatched as the engine does
    stage_dispatch_mark "$STATE/pipeline-state.json" build
    MOCK_LOOP_RESPONSE="$1"; : > "$CALLS"; rm -f "$JPROMPT"
    _build_stage_run_inner "" "$AD/design-steps.json" "$AD/diff.patch" "$AD/build-summary.json" "$AD" >"$AD/log" 2>&1 || true
}
_outcome() { jq -r '.outcome // "none"' "$AD/build-summary.json" 2>/dev/null || echo none; }
_findings() { jq -r '[.data.findings[]?.text] | join("\n")' "$AD/build-summary.json" 2>/dev/null; }
_ncalls() { local n=0 l; while IFS= read -r l; do [[ -n "$l" ]] && n=$((n + 1)); done < "$CALLS"; printf '%s' "$n"; }
_lacks() { if [[ "$2" == *"$3"* ]]; then assert_fail "$1" "it has: $3"; else assert_pass "$1"; fi; }
_jp() { cat "$JPROMPT" 2>/dev/null; }
# _refusals <n> — how many of build's findings refuse step <n> (one a line).
_refusals() { local c=0 l; while IFS= read -r l; do [[ "$l" == "step $1: the line you quoted"* || "$l" == "step $1: your reason"* ]] && c=$((c + 1)); done <<< "$(_findings)"; printf '%s' "$c"; }

DONE1="step 1: done — QUOTE: $P/plugin.sh | $SRC_LINE"
DONE2="step 2: done — QUOTE: $P/release.sh | claim_release() {"
WHY1="the line sources core/claim/claim.sh, which the step says plugin.sh must not do"

# ── Round 1: step 1 refused ──────────────────────────────────────────────────
print_test_section "round 1: the judge refuses step 1"
stage_dispatch_mark "$STATE/pipeline-state.json" test-author
JUDGE_REPLY="1: does not | WHY: $WHY1 | ACCEPTED IF: plugin.sh does not source core/claim/claim.sh"$'\n2: does'
_try "$DONE1"$'\n'"$DONE2"$'\nLOOP_COMPLETE'
assert_eq "[setup] round 1: build is unusable" "unusable" "$(_outcome)"
F1="$(jq -r '.data.findings[0].id // empty' "$AD/build-summary.json")"
assert_eq "[setup] step 1's finding has an id" "BUFND-1" "$F1"

# ── Round 2: test-author runs, then build hands step 1 on ────────────────────
print_test_section "HO1: round 2, try 1 — build hands step 1 to test-author"
stage_dispatch_mark "$STATE/pipeline-state.json" test-author
# The round's test-author run started before build's try (its time, mocked).
touch -t 202001010000 "$(stage_dispatch_mark_path "$STATE" test-author)"
NOTMINE="ANSWER $F1: not mine — the test must change: tests/claim-test.sh: it pins the old claimed:<machine> label"
JUDGE_REPLY='2: does'
_try "$NOTMINE"$'\n'"$DONE1"$'\n'"$DONE2"$'\nLOOP_COMPLETE'
_lacks "[HO1] the judge is not asked about step 1" "$(_jp)" "plugin.sh must not source"
_f="$(_findings)"
assert_eq "[HO1] step 1 is not refused" "0" "$(_refusals 1)"
assert_contains "[HO1] step 1's finding stays, handed to test-author, waiting" "$_f" "handed to test-author, waiting"
assert_contains "[HO1] ...with the check's earlier WHY" "$_f" "$WHY1"
assert_eq "[HO1] it is open: build fails" "fail" "$(_outcome)"
assert_eq "[HO1] ...and ends the round, so test-author runs" "true" "$(jq -r '.data.ends_round // false' "$AD/build-summary.json")"
assert_eq "[HO1] the waiting finding blocks" "null" \
    "$(jq -r '[.data.findings[] | select(.text | contains("waiting"))][0].blocking' "$AD/build-summary.json")"
assert_contains "[HO1] build-tests carries the finding to test-author" "$(jq -r '[.data.findings[].text] | join("|")' "$AD/build-tests-result.json" 2>/dev/null)" "tests/claim-test.sh"

print_test_section "HO2: a try again in the round does not judge or refuse step 1"
JUDGE_REPLY='1: does not | WHY: asked again | ACCEPTED IF: x'$'\n2: does'
_try "$DONE1"$'\n'"$DONE2"$'\nLOOP_COMPLETE'
assert_eq "[HO2] the judge is not asked" "0" "$(_ncalls)"
assert_eq "[HO2] step 1 is not refused again" "0" "$(_refusals 1)"
assert_contains "[HO2] step 1 is still shown waiting" "$(_findings)" "handed to test-author, waiting"
assert_eq "[HO2] still open: build fails, ending the round" "fail true" "$(_outcome) $(jq -r '.data.ends_round // false' "$AD/build-summary.json")"
assert_contains "[HO2] build-tests still carries the finding" "$(jq -r '[.data.findings[].text] | join("|")' "$AD/build-tests-result.json" 2>/dev/null)" "tests/claim-test.sh"

# ── Round 3: test-author has run since ───────────────────────────────────────
print_test_section "HO3: round 3 — test-author has run; step 1 is judged again"
stage_dispatch_mark "$STATE/pipeline-state.json" test-author
JUDGE_REPLY='1: does'
_try "$DONE1"$'\n'"$DONE2"$'\nLOOP_COMPLETE'
assert_eq "[HO3] the judge is asked again" "1" "$(_ncalls)"
assert_contains "[HO3] ...about step 1" "$(_jp)" "plugin.sh must not source"
assert_contains "[HO3] ...held to its earlier finding" "$(_jp)" "YOUR EARLIER FINDINGS, AND THE ANSWERS TO THEM"
assert_contains "[HO3] ...the finding's WHY" "$(_jp)" "$WHY1"
assert_contains "[HO3] ...and the not mine answer" "$(_jp)" "not mine — the test must change"
_lacks "[HO3] step 1 no longer waits" "$(_findings)" "waiting"
assert_eq "[HO3] accepted: build passes" "pass" "$(_outcome)"

# _fresh — a new step-1 refusal, its hand-off records gone: F1 is its finding.
_fresh() {
    rm -f "$AD"/build-steps-judged* "$AD/build-summary.json" "$AD/build-tests-result.json"
    JUDGE_REPLY="1: does not | WHY: $WHY1 | ACCEPTED IF: plugin.sh does not source core/claim/claim.sh"$'\n2: does'
    _try "$DONE1"$'\n'"$DONE2"$'\nLOOP_COMPLETE'
    F1="$(jq -r '.data.findings[0].id // empty' "$AD/build-summary.json")"
    NOTMINE="ANSWER $F1: not mine — the test must change: tests/claim-test.sh: it pins the old claimed:<machine> label"
}

# ── HO4: a not mine handed to no stage ───────────────────────────────────────
print_test_section "HO4: a not mine that hands the finding to no stage pauses nothing"
_fresh
JUDGE_REPLY='1: does'
_try "ANSWER $F1: not mine — someone else should look at it"$'\n'"$DONE1"$'\n'"$DONE2"$'\nLOOP_COMPLETE'
assert_contains "[HO4] the step is judged" "$(_jp)" "plugin.sh must not source"
_lacks "[HO4] ...and nothing waits" "$(_findings)" "waiting"

# ── HO6: no hand-off without a judgement between; at most two ────────────────
print_test_section "HO6: a refused step is not handed on by the reply judged with it"
_fresh
JUDGE_REPLY='2: does'
_try "$NOTMINE"$'\n'"$DONE1"$'\n'"$DONE2"$'\nLOOP_COMPLETE'
assert_contains "[HO6] setup: hand-off 1 waits" "$(_findings)" "waiting"
stage_dispatch_mark "$STATE/pipeline-state.json" test-author
JUDGE_REPLY="1: does not | WHY: $WHY1 | ACCEPTED IF: x"
F1="$(jq -r '[.data.findings[] | select(.text | contains("waiting"))][0].id' "$AD/build-summary.json")"
_try "ANSWER $F1: not mine — the test must change: tests/claim-test.sh: still pins it"$'\n'"$DONE1"$'\n'"$DONE2"$'\nLOOP_COMPLETE'
assert_eq "[HO6] back: judged, and refused" "1 1" "$(_ncalls) $(_refusals 1)"
_lacks "[HO6] ...and the reply judged with it hands nothing on" "$(_findings)" "waiting"
F1="$(jq -r '[.data.findings[] | select(.text | startswith("step 1"))][0].id' "$AD/build-summary.json")"
JUDGE_REPLY='2: does'
_try "ANSWER $F1: not mine — the test must change: tests/claim-test.sh: still pins it"$'\n'"$DONE1"$'\n'"$DONE2"$'\nLOOP_COMPLETE'
assert_contains "[HO6] the next try may hand it on: hand-off 2 waits" "$(_findings)" "waiting"
stage_dispatch_mark "$STATE/pipeline-state.json" test-author
JUDGE_REPLY="1: does not | WHY: $WHY1 | ACCEPTED IF: x"
_try "$DONE1"$'\n'"$DONE2"$'\nLOOP_COMPLETE'
F1="$(jq -r '[.data.findings[] | select(.text | startswith("step 1"))][0].id' "$AD/build-summary.json")"
JUDGE_REPLY="1: does not | WHY: $WHY1 | ACCEPTED IF: x"
_try "ANSWER $F1: not mine — the test must change: tests/claim-test.sh: still pins it"$'\n'"$DONE1"$'\n'"$DONE2"$'\nLOOP_COMPLETE'
assert_eq "[HO6] a third hand-off is not taken: the step is judged and refused" "1 1" "$(_ncalls) $(_refusals 1)"
_lacks "[HO6] ...nothing waits" "$(_findings)" "waiting"

# ── HO7: no receiver in this run ─────────────────────────────────────────────
print_test_section "HO7: no stage of this run takes the topic"
_fresh
JUDGE_REPLY='1: does'
ZBUILD_INPUTS_FLOW="design build test" _try "$NOTMINE"$'\n'"$DONE1"$'\n'"$DONE2"$'\nLOOP_COMPLETE'
assert_contains "[HO7] the step is judged" "$(_jp)" "plugin.sh must not source"
_lacks "[HO7] ...and nothing waits" "$(_findings)" "waiting"

# ── HO8: the last round ──────────────────────────────────────────────────────
print_test_section "HO8: on the loop's last round nothing waits"
_fresh
JUDGE_REPLY='1: does'
ZBUILD_CYCLE_ITER=3 ZBUILD_CYCLE_MAX_ITER=3 _try "$NOTMINE"$'\n'"$DONE1"$'\n'"$DONE2"$'\nLOOP_COMPLETE'
assert_contains "[HO8] the step is judged" "$(_jp)" "plugin.sh must not source"
_lacks "[HO8] ...and nothing waits" "$(_findings)" "waiting"

# ── HO5: the shared code ─────────────────────────────────────────────────────
print_test_section "HO5: who a finding is handed to"
_rcv=""
judge_handoff_receivers_v _rcv "$REPO_ROOT/plugins/agent/build/manifest.yaml" "$AD" "BUFND-99"
assert_eq "[HO5] no output of build's carries BUFND-99: no stage" "" "$_rcv"
stage_result_write "$AD/build-tests-result.json" fail "one" \
    '{"findings":[{"n":1,"id":"BUFND-99","text":"BUFND-99: tests/claim-test.sh: it pins the old label"}]}' >/dev/null
judge_handoff_receivers_v _rcv "$REPO_ROOT/plugins/agent/build/manifest.yaml" "$AD" "BUFND-99"
assert_eq "[HO5] build-tests (test-findings) carries it: test-author, a stage of this run" "test-author" "$_rcv"
ZBUILD_INPUTS_FLOW="design build" judge_handoff_receivers_v _rcv "$REPO_ROOT/plugins/agent/build/manifest.yaml" "$AD" "BUFND-99"
assert_eq "[HO5] ...no test-author in the run: no stage" "" "$_rcv"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
