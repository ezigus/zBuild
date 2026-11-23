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
# S4 [change] such a suspicion reaches the stage its fix word names as a
#             question that blocks nothing: the lens still passes; it is kept
#             in the result (suspected)
# S5 [change] a suspicion that says nothing would confirm it is not sent on; a
#             note says why
# S8 [change] in a round that otherwise passes, an open suspicion is in the
#             lens's summary and in the run's open questions (the reports and
#             the PR body read them), so a person sees it (review of #2584)
# S6 [change] the job texts ask for partial or paginated reads and data trusted
#             without checking who wrote it (red-team); external calls with no
#             timeout and what a crash or interrupt leaves behind (sre); tests
#             that reach real services and Enforced-by entries naming the wrong
#             test (correctness); "fails loudly" means an event or a status line,
#             and a deliberate fail-open is visible that way (sre)
# S7 [change] the lens is told the rule on outside assumptions, and that it may
#             look GitHub up, read-only, to check one
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
assert_eq "[S4] a suspicion does not send the change back" "pass" "$OUT"
assert_contains "[S4] it reaches the code's stage as a question that blocks nothing" "$(_texts code)" \
    "false The red-team lens suspects, and could not confirm: a SIGTERM between the claim and its trap leaves the label behind"
assert_contains "[S4] ...saying what would confirm it" "$(_texts code)" \
    "what would confirm it: how bash runs a TERM trap set after a builtin has started"
assert_contains "[S4] ...and asking it as a question" "$(_texts code)" "A question: say whether it holds"
assert_eq "[S4] it is kept in the result" "a.sh" "$(jq -r '.suspected[0].file // ""' "$ART/lens-red-team.json" 2>/dev/null)"
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
assert_contains "[S6] correctness: a test that reaches a real service" "$(_J correctness)" "a test that reaches a real service"
assert_contains "[S6] correctness: an Enforced by entry naming the wrong test" "$(_J correctness)" "an Enforced by entry that names a test which does not check what it says"

print_test_section "S7: outside assumptions"
# shellcheck source=../../../../scripts/lib/outside-assumptions.sh
source "$REPO_ROOT/scripts/lib/outside-assumptions.sh"
assert_contains "[S7] the lens is told the rule" "$P" "$(_flat "${ZB_OUTSIDE_ASSUMPTIONS_RULE:-<no rule>}")"
assert_contains "[S7] ...and that one not handled is a finding" "$P" "An outside assumption the change does not handle is a finding"
assert_contains "[S7] ...checked with the read-only lookup, not guessed" "$P" "look it up, read-only, with zbuild-gh-get <endpoint> [jq-filter]"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
