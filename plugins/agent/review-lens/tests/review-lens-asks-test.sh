#!/usr/bin/env bash
# plugins/agent/review-lens/tests/review-lens-asks-test.sh — what a lens is
# asked for, and where its answers go (#2584 R2 R4 R5 R6; ADR-038, ADR-040,
# amended 2026-11-22).
#
# Why: on #1764 run 44910536811 each fix covered only the instance a lens found
# (the interrupt and control-character forms were never raised); red-team
# reasoned its way to the claim-before-trap gap and reported nothing; sre's job
# text excused a stderr-only skip; no lens could see that a label did not exist.
#
# S1 [change] the prompt asks each finding to list every other place in the
#             change with the same kind of problem (also_at)
# S2 [change] those places reach the stage that fixes it: they are in the
#             routed finding's text
# S9 [change] (review) each place is held to the change as the finding's quote
#             is: one whose line is not there is left out, with a note
# S3 [change] the prompt says a problem it suspects but cannot confirm goes in
#             unclear, with what would confirm it (confirm_by)
# S4 [change] (amended by #2630, ADR-040) such a suspicion, the first time,
#             sends the change round once: the lens does not pass, and the stage
#             its fix word names — which can run commands — is asked to run what
#             would confirm it and answer done (it holds, and is fixed) or wrong
#             (with what it ran and what that showed); it is kept in the result
#             (suspected)
# S11 [change] (#2630) a suspicion sent round once in a run blocks nothing
#             for the rest of the run — a round with none between, and the same
#             one again: the lens passes, and a person sees it
# S12 [change] a new suspicion after one was sent still sends the change round
# S13 [change] a suspicion is the line it is about (file and quote): reworded,
#             it was still sent
# S14 [change] a lens result from before this run started does not count
# S15 [change] with no run-start marker, each round counts it new — the loop's
#             rounds bound it
# S16 [change] (review) a round that ends early keeps what was sent
# S17 [change] (review) two different suspicions about the same line are one:
#             the line was sent, so the second blocks nothing
# S5 [change] a suspicion that says nothing would confirm it is not sent on; a
#             note says why
# S8 [change] in a round that otherwise passes, an open suspicion is in the
#             lens's summary and in the run's open questions (the reports and
#             the PR body read them), so a person sees it (review of #2584)
# S6 [change] the job texts ask for partial or paginated reads and data trusted
#             without checking who wrote it (red-team); external calls with no
#             timeout and what a crash or interrupt leaves behind (sre); tests
#             that fake our own code and Enforced-by entries naming the wrong
#             test (tests, #2630); "fails loudly" means an event or a status line,
#             and a deliberate fail-open is visible that way (sre)
# S7 [change] the lens is told the rule on outside assumptions, and that it may
#             look GitHub up, read-only, to check one
# S10 [change] (#2615, ADR-040) behaviour the issue asks for, which no
#             requirement covers, is fix: design — so a requirement and its test
#             come first; fix: code is for wrong code a requirement and its test
#             already cover, or for how code is written. On #1722 run
#             45739271221 three lenses sent such a gap to build alone, and the
#             next round found the new code untested.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "plugin: review-lens — every place, suspicions, job texts, outside assumptions (#2584)"
setup_test_env "plugin-review-lens-asks"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events" ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; mkdir -p "$ZBUILD_EVENTS_DIR"
_flat() { tr -s '[:space:]' ' ' <<< "$1"; }
_lacks() { if [[ "$2" == *"$3"* ]]; then assert_fail "$1" "it has: $3"; else assert_pass "$1"; fi; }

XR="$TEST_TEMP_DIR/repo"; mkdir -p "$XR"
(
    cd "$XR" && /usr/bin/git init -q -b main && /usr/bin/git config user.email t@t && /usr/bin/git config user.name t
    printf '# a\n' > a.sh; printf '# b\n' > b.sh; /usr/bin/git add -A && /usr/bin/git commit -qm base
    /usr/bin/git checkout -q -b zbuild/issue-1
    printf 'gh label add "$L"\n' >> a.sh; printf 'gh label add "$M"\n' >> b.sh; /usr/bin/git commit -qam change
) >/dev/null 2>&1
export ZBUILD_REPO_ROOT="$XR"

# shellcheck source=../../../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
PLUGIN_DIR="$REPO_ROOT/plugins/agent/review-lens"
# shellcheck source=../../../../plugins/agent/review-lens/plugin.sh
source "$PLUGIN_DIR/plugin.sh"
ART="$TEST_TEMP_DIR/artifacts"; mkdir -p "$ART"
printf 'diff --git a/a.sh b/a.sh\n+gh label add "$L"\ndiff --git a/b.sh b/b.sh\n+gh label add "$M"\n' > "$ART/diff.patch"

REPLY=""
route_to_model() { zb_test_lens_check_answer "$2" && return 0; printf '%s' "$2" > "$TEST_TEMP_DIR/prompt"; zb_test_lens_lines "$REPLY"; }
_lens() {
    rm -f "$ART"/lens-red-team*.json
    ZBUILD_CURRENT_STAGE=review_lenses ZBUILD_REVIEW_LENS_ID=red-team _TPL_STAGE_FAIL_ON_review_lenses="medium high critical" \
        _review_lens_run_inner red-team "" "$ART/diff.patch" "$ART/lens-red-team.json" "$ART" >/dev/null 2>&1
    OUT="$(jq -r '.outcome // "MISSING"' "$ART/lens-red-team.json" 2>/dev/null)"
}
_texts() { jq -r '.data.findings[]? | "\(.blocking) \(.text)"' "$ART/lens-red-team-$1-result.json" 2>/dev/null; }

P="$(_flat "$(_rl_build_lens_prompt red-team "THE-CHANGE" "")")"

print_test_section "S1–S2: every place with the same kind of problem"
assert_contains "[S1] the prompt asks for every other place with the same kind of problem" "$P" \
    "every other place in the change with the same kind of problem"
assert_contains "[S1] ...in the also_at list" "$P" 'also at: <file> | <the line that shows it there>'
REPLY='{"score":4,"findings":[{"file":"a.sh","quote":"gh label add \"$L\"","trigger":"the label does not exist","accepted_if":"a missing label is created or reported","severity":"medium","category":"logic","message":"the label is assumed to exist","introduced":true,"fix":"code","also_at":["b.sh | gh label add \"$M\""]}]}'
_lens
assert_eq "[S2] setup: the finding fails the lens" "fail" "$OUT"
assert_contains "[S2] the routed finding names the other place" "$(_texts code)" \
    'the same kind of problem also at: b.sh | gh label add "$M"'

REPLY='{"score":4,"findings":[{"file":"a.sh","quote":"gh label add \"$L\"","trigger":"the label does not exist","accepted_if":"a missing label is created or reported","severity":"medium","category":"logic","message":"the label is assumed to exist","introduced":true,"fix":"code","also_at":["b.sh | gh label add \"$M\"","c.sh | gh label add \"$N\"","b.sh | gh label remove \"$M\"","somewhere else too"]}]}'
_lens
_t="$(_texts code)"
assert_contains "[S9] a place whose line is in the change is kept" "$_t" 'also at: b.sh | gh label add "$M"'
_lacks "[S9] a place in a file the change does not have is left out" "$_t" "c.sh"
_lacks "[S9] a place whose line is not in its file is left out" "$_t" "gh label remove"
_lacks "[S9] a place with no line is left out" "$_t" "somewhere else too"
assert_contains "[S9] ...a note says each was left out" "$(jq -r '.data.notes // [] | join(" ")' "$ART/lens-red-team.json" 2>/dev/null)" \
    "a place the same kind of problem is also at was left out, its line not found as quoted: c.sh | gh label add"
assert_eq "[S9] ...one note for each" "3" "$(jq -r '[.data.notes // [] | .[] | select(startswith("a place the same kind of problem"))] | length' "$ART/lens-red-team.json" 2>/dev/null)"

print_test_section "S3–S5: a suspicion is a question"
assert_contains "[S3] the prompt says a suspicion goes in unclear" "$P" \
    "A problem you suspect but cannot confirm is not left out: write it as a"
assert_contains "[S3] ...with what would confirm it" "$P" 'confirm by: <what would confirm it'
REPLY='{"score":9,"findings":[],"unclear":[{"file":"a.sh","quote":"gh label add \"$L\"","suspicion":"a SIGTERM between the claim and its trap leaves the label behind","confirm_by":"how bash runs a TERM trap set after a builtin has started","fix":"code"}]}'
_lens
assert_eq "[S4] a suspicion sends the change round, the first time" "fail" "$OUT"
assert_contains "[S4] it reaches the code's stage, blocking" "$(_texts code)" \
    "true The red-team lens suspects, and could not confirm: a SIGTERM between the claim and its trap leaves the label behind"
assert_contains "[S4] ...saying what would confirm it" "$(_texts code)" \
    "what would confirm it: how bash runs a TERM trap set after a builtin has started"
assert_contains "[S4] ...and asking the stage to run it, and answer" "$(_texts code)" \
    "Run what would confirm it: answer done when it holds and you fixed it, or wrong with what you ran and what it showed."
assert_eq "[S4] it is kept in the result" "a.sh" "$(jq -r '.suspected[0].file // ""' "$ART/lens-red-team.json" 2>/dev/null)"
# S11–S15: rounds of one run. The run started before them (ZBUILD_RUN_START_MARKER);
# a round keeps the lens's earlier results, as the engine does.
MARK="$TEST_TEMP_DIR/run-start"
_round() {
    ZBUILD_RUN_START_MARKER="${1:-}" ZBUILD_CURRENT_STAGE=review_lenses ZBUILD_REVIEW_LENS_ID=red-team \
        _TPL_STAGE_FAIL_ON_review_lenses="medium high critical" \
        _review_lens_run_inner red-team "" "$ART/diff.patch" "$ART/lens-red-team.json" "$ART" >/dev/null 2>&1
    OUT="$(jq -r '.outcome // "MISSING"' "$ART/lens-red-team.json" 2>/dev/null)"
}
SUS1="$REPLY"
CLEAN='{"score":10,"findings":[]}'
_fresh() { rm -f "$ART"/lens-red-team*.json; touch -t 202001010000 "$MARK"; }
_fresh
REPLY="$SUS1";  _round "$MARK"; assert_eq "[S11] round 1: the suspicion sends the change round" "fail" "$OUT"
REPLY="$CLEAN"; _round "$MARK"; assert_eq "[S11] round 2: no suspicion" "pass" "$OUT"
REPLY="$SUS1";  _round "$MARK"; assert_eq "[S11] round 3: the same suspicion, sent already in this run, blocks nothing" "pass" "$OUT"
assert_contains "[S11] ...it is still asked, blocking nothing" "$(_texts code)" "false The red-team lens suspects, and could not confirm"
REPLY="${SUS1/a SIGTERM between the claim and its trap leaves the label behind/the label can be left behind by a signal}"
_round "$MARK"; assert_eq "[S13] reworded, about the same line: still sent already" "pass" "$OUT"
REPLY='{"score":9,"findings":[],"unclear":[{"file":"b.sh","quote":"gh label add \"$M\"","suspicion":"the second label is never removed","confirm_by":"a run that fails after it is added","fix":"code"}]}'
_round "$MARK"; assert_eq "[S12] a new suspicion after one was sent: it sends the change round" "fail" "$OUT"
_fresh; REPLY="$SUS1"; _round "$MARK"
touch -t 201901010000 "$ART/lens-red-team.json"
_round "$MARK"; assert_eq "[S14] a result from before this run started does not count" "fail" "$OUT"
_fresh; REPLY="$SUS1"; _round "$MARK"
REPLY='this is not a lens answer'; _round "$MARK"
assert_eq "[S16] (fixture) a round that ends early" "unusable" "$OUT"
REPLY="$SUS1"; _round "$MARK"
assert_eq "[S16] ...still keeps what was sent: the same suspicion after it blocks nothing" "pass" "$OUT"
# S17: two suspicions about the same line are one — the line is what was sent.
_fresh; REPLY="$SUS1"; _round "$MARK"
REPLY="${SUS1/a SIGTERM between the claim and its trap leaves the label behind/the label is added twice when the call is retried}"
REPLY="${REPLY/how bash runs a TERM trap set after a builtin has started/a retried call}"
_round "$MARK"; assert_eq "[S17] a different suspicion about a line already sent blocks nothing: one line, one round" "pass" "$OUT"
_fresh; rm -f "$MARK"; REPLY="$SUS1"; _round ""; _round ""
assert_eq "[S15] with no run-start marker every round counts it new: the loop's rounds bound it" "fail" "$OUT"
# Leave a run whose last round passed with the suspicion open, for S8.
_fresh; REPLY="$SUS1"; _round "$MARK"; _round "$MARK"
_sum="$(_flat "$(cat "$ART/lens-red-team-summary.md" 2>/dev/null)")"
assert_contains "[S8] a round that passes: the suspicion is in the lens's summary" "$_sum" \
    "suspected, not confirmed: a SIGTERM between the claim and its trap leaves the label behind (a.sh"
assert_contains "[S8] ...with what would confirm it" "$_sum" "what would confirm it: how bash runs a TERM trap set after a builtin has started"
# shellcheck source=../../../../scripts/lib/run-open-items.sh
source "$REPO_ROOT/scripts/lib/run-open-items.sh"
_oq="$(_flat "$(open_items_questions "$TEST_TEMP_DIR")")"
assert_contains "[S8] ...and in the run's open questions, for a person" "$_oq" \
    "a SIGTERM between the claim and its trap leaves the label behind"
assert_contains "[S8] ...saying what would confirm it" "$_oq" "what would confirm it: how bash runs a TERM trap set after a builtin has started"
REPLY='{"score":9,"findings":[],"unclear":[{"file":"a.sh","quote":"gh label add \"$L\"","suspicion":"the label may be missing","fix":"code"}]}'
_lens
assert_eq "[S5] a suspicion with nothing to confirm it is not sent on" "" "$(_texts code)"
assert_contains "[S5] ...a note says why" "$(jq -r '.data.notes // [] | join(" ")' "$ART/lens-red-team.json" 2>/dev/null)" \
    "a suspicion was left out: it says nothing would confirm it"

print_test_section "S6: the job texts"
_J() { _flat "$(cat "$PLUGIN_DIR/lenses/$1.md")"; }
assert_contains "[S6] red-team: partial or paginated reads" "$(_J red-team)" "a read that gets only part of the data — one page of a paginated list"
assert_contains "[S6] red-team: data trusted without checking who wrote it" "$(_J red-team)" "data trusted without checking who wrote it"
assert_contains "[S6] sre: an external call with no timeout" "$(_J sre)" "a call to something outside the program with no timeout"
assert_contains "[S6] sre: what a crash or interrupt leaves behind" "$(_J sre)" "anything taken — a claim, a lock, a label, a file — that a crash or an interrupt leaves behind"
assert_contains "[S6] sre: fails loudly is an event or a status line" "$(_J sre)" "Fails loudly means an event or a status line"
assert_contains "[S6] sre: a deliberate fail-open is visible that way" "$(_J sre)" "A deliberate fail-open must be visible the same way"
_lacks "[S6] sre: a message alone no longer excuses a step" "$(_J sre)" "a step that already fails loudly, with a message saying why"
# #2630: what a test proves is the tests lens's now, not correctness's.
assert_contains "[S6] tests: a test that replaces the project's own code, not an outside service" "$(_J tests)" "rather than replacing an outside service at the project's own wrapper around it (the network, GitHub, a model)"
assert_contains "[S6] tests: an Enforced by entry naming the wrong test" "$(_J tests)" "an Enforced by entry that names a test which does not check what it says"

print_test_section "S7: outside assumptions"
# shellcheck source=../../../../scripts/lib/outside-assumptions.sh
source "$REPO_ROOT/scripts/lib/outside-assumptions.sh"
assert_contains "[S7] the lens is told the rule" "$P" "$(_flat "${ZB_OUTSIDE_ASSUMPTIONS_RULE:-<no rule>}")"
assert_contains "[S7] ...and that one not handled is a finding" "$P" "An outside assumption the change does not handle is a finding"
assert_contains "[S7] ...checked with the read-only lookup, not guessed" "$P" "look it up, read-only, with zbuild-gh-get <endpoint> [jq-filter]"

print_test_section "S10: behaviour no requirement covers is design's (#2615)"
assert_contains "[S10] the prompt says such behaviour is fix: design" "$P" \
    'Behaviour the issue asks for that the change does not do, and that no requirement covers, is `design`: a requirement, and then its test, come before the code.'
assert_contains "[S10] ...and when code applies" "$P" \
    '`code` is for code that is wrong where a requirement and its test already cover the behaviour, or for how the code is written.'

cleanup_test_env
print_test_results
exit $((FAIL > 0))
