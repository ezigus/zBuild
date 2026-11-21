#!/usr/bin/env bash
# tests/unit/lens-per-item-test.sh — a lens keeps its verdict per finding area:
# per file of the change it reviews (#2574 R3; ADR-072 §4 §5, ADR-038,
# amended 2026-11-20).
#
# Why: a lens kept one report for the whole change, with the answers to its
# findings in its fingerprint: any change, or any answer, had it review the
# whole change again, where its findings flip. A lens finding names the file
# it is about, so the item is the file: a file's kept findings — or that it
# had none — stand while the file and what the call read for it are
# unchanged; an answer only has a file whose kept report found something
# reviewed again, held to its findings; only the changed files are asked, in
# one call. What is not about a file of the change (and the report's score and
# questions) is one more item, judged whenever the lens is called.
#
# LP1 [change] the first call reviews every file of the change, and a report is
#              kept for each file
# LP2 [change] one file changes: the call reviews only that file; the other
#              file's kept finding still stands, and a finding the reply gives
#              about a file it was not asked about is set aside
# LP3 [change] build answers the finding, nothing changed: only its file is
#              reviewed again, shown the finding and the answer
# LP4 [change] the next try gives no answer and nothing changed: no call — the
#              kept reports stand
# LP5 [change] an answer to a finding about a file whose kept report found
#              nothing does not have it reviewed again
# LP6 [change] (review) a file's report depends on the other changed files the
#              call opened for it: one of them changes, and it is reviewed again
# LP7 [change] (review) a file whose kept report found something depends on
#              every file of the change: any of them changes, and it is
#              reviewed again
# LP8 [change] (review) a file renamed with nothing else changed keeps its
#              report under its new path: it is not reviewed again
# LP9 [change] (review) build answers a lens finding not mine — the test must
#              change, and build-tests carries it to test-author: that file
#              waits, its findings standing; once test-author has run it is
#              reviewed again
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "a lens keeps a verdict per file of the change (#2574 R3)"
setup_test_env "lens-per-item"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"

# The repository: a base on main, and a branch that changed a.sh and b.sh.
XR="$TEST_TEMP_DIR/repo"; mkdir -p "$XR"
(
    cd "$XR" && /usr/bin/git init -q -b main && /usr/bin/git config user.email t@t && /usr/bin/git config user.name t
    # Ten lines each, so git sees a moved file as renamed.
    { for i in 1 2 3 4 5 6 7 8 9 10; do printf '# a line %s\n' "$i"; done; } > a.sh; cp a.sh b.sh; sed -i.bak 's/a line/b line/' b.sh; rm -f b.sh.bak
    /usr/bin/git add -A && /usr/bin/git commit -qm base
    /usr/bin/git checkout -q -b zbuild/issue-1
    printf 'read_cfg "$1"\n' >> a.sh; printf 'b=1\n' >> b.sh; /usr/bin/git commit -qam change
) >/dev/null 2>&1
export ZBUILD_REPO_ROOT="$XR"

# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
# shellcheck source=../../plugins/agent/review-lens/plugin.sh
source "$REPO_ROOT/plugins/agent/review-lens/plugin.sh"
# shellcheck source=../../scripts/lib/stage-result.sh
source "$REPO_ROOT/scripts/lib/stage-result.sh"
ART="$TEST_TEMP_DIR/artifacts"; mkdir -p "$ART"
printf 'diff --git a/a.sh b/a.sh\n+read_cfg "$1"\ndiff --git a/b.sh b/b.sh\n+b=1\n' > "$ART/diff.patch"
printf 'scope: all\n' > "$TEST_TEMP_DIR/scope.md"

FA='{"accepted_if":"a missing config is refused","trigger":"a run with no config file","quote":"read_cfg \"$1\"","file":"a.sh","severity":"high","message":"the config is read unchecked","introduced":true,"fix":"code"}'
FB='{"accepted_if":"b is set once","trigger":"any run","quote":"b=1","file":"b.sh","severity":"high","message":"b is set twice","introduced":true,"fix":"code"}'
FINDINGS="[$FB]"
_N="$TEST_TEMP_DIR/n"; _P="$TEST_TEMP_DIR/p"
OPENS=""
route_to_model() {
    zb_test_lens_check_answer "$2" && return 0
    local n; n=$(( $(cat "$_N" 2>/dev/null || echo 0) + 1 )); printf '%s' "$n" > "$_N"; printf '%s' "$2" > "$_P.$n"
    # The files the call opens, as the router lists them.
    [[ -n "$OPENS" && -n "${ZBUILD_ROUTER_OPENED_FILE:-}" ]] && printf '%s\n' $OPENS >> "$ZBUILD_ROUTER_OPENED_FILE"
    printf '{"score":5,"findings":%s}' "$FINDINGS"
}
_lens() {
    rm -f "$_N" "$_P".*
    ZBUILD_CURRENT_STAGE=review_lenses ZBUILD_REVIEW_LENS_ID=red-team _TPL_STAGE_FAIL_ON_review_lenses="high critical" \
        _review_lens_run_inner red-team "$TEST_TEMP_DIR/scope.md" "$ART/diff.patch" "$ART/lens-red-team.json" "$ART" >/dev/null 2>&1
    CALLS="$(cat "$_N" 2>/dev/null || echo 0)"
    OUT="$(jq -r '.outcome // "MISSING"' "$ART/lens-red-team.json" 2>/dev/null)"
    MSGS="$(jq -r '[.findings[].message] | join("|")' "$ART/lens-red-team.json" 2>/dev/null)"
}
ONLY="THIS TIME, REVIEW ONLY THESE FILES OF THE CHANGE"
_only() { sed -n "/$ONLY/,/^\$/p" "$_P.1" 2>/dev/null; }
# _asked <file> — "yes" when the call reviewed <file>: every file (no list of
# the files to review only), or a list naming it.
_asked() { local p; p="$(cat "$_P.1" 2>/dev/null)"; [[ -n "$p" ]] || { echo no; return; }
    if [[ "$p" != *"$ONLY"* || "$(_only)" == *"- $1"* ]]; then echo yes; else echo no; fi; }
_lacks() { if [[ "$2" == *"$3"* ]]; then assert_fail "$1" "it has: $3"; else assert_pass "$1"; fi; }

print_test_section "LP1: every file, one call, a report each"
_lens
assert_eq "[LP1] one call" "1" "$CALLS"
_lacks "[LP1] ...over the whole change" "$(cat "$_P.1" 2>/dev/null)" "$ONLY"
assert_eq "[LP1] b's finding fails the lens" "fail" "$OUT"
_keys="$(jq -r 'keys | join(" ")' "$ART/lens-red-team-judged.json" 2>/dev/null)"
assert_contains "[LP1] a report is kept for a.sh" " $_keys " " a.sh "
assert_contains "[LP1] ...and for b.sh" " $_keys " " b.sh "

print_test_section "LP2: b.sh changes"
printf 'b=2\n' >> "$XR/b.sh"; /usr/bin/git -C "$XR" commit -qam "b again" >/dev/null 2>&1
FINDINGS="[$FB, $FA]"
_lens
assert_eq "[LP2] one call" "1" "$CALLS"
assert_contains "[LP2] ...told to review only b.sh" "$(_only)" "- b.sh"
_lacks "[LP2] ...not a.sh, whose report found nothing and read nothing that changed" "$(_only)" "- a.sh"
assert_contains "[LP2] b.sh's finding is there" "$MSGS" "b is set twice"
_lacks "[LP2] a finding about a file it was not asked about is set aside" "$MSGS" "the config is read unchecked"

print_test_section "LP3: build answers b.sh's finding; nothing changed"
FID="$(jq -r '.data.findings[] | select(.text | contains("set twice")) | .id' "$ART/lens-red-team-code-result.json" 2>/dev/null | head -n 1)"
FTXT="$(jq -r '.data.findings[] | select(.text | contains("set twice")) | .text' "$ART/lens-red-team-code-result.json" 2>/dev/null | head -n 1)"
assert_eq "[LP3] the finding has the lens's id" "RLRED-" "${FID%%[0-9]*}"
stage_result_write "$ART/build-summary.json" pass "built" \
    "$(jq -nc --arg a "$FID: done — b is set once now" --arg k "$FID" --arg t "$FTXT" '{answers: [$a], answer_findings: {($k): $t}}')" >/dev/null
FINDINGS="[]"
_lens
assert_eq "[LP3] one call" "1" "$CALLS"
assert_contains "[LP3] ...told to review only b.sh" "$(_only)" "- b.sh"
_lacks "[LP3] ...not a.sh" "$(_only)" "- a.sh"
assert_contains "[LP3] ...shown the finding and the answer" "$(tr -s '[:space:]' ' ' < "$_P.1")" "answered: done — b is set once now"
_lacks "[LP3] b.sh's finding is gone" "$MSGS" "set twice"

print_test_section "LP4: no answer, nothing changed"
stage_result_write "$ART/build-summary.json" pass "built" '{}' >/dev/null
FINDINGS="[$FA, $FB]"
_lens
assert_eq "[LP4] no call" "0" "$CALLS"
assert_eq "[LP4] the kept reports stand: nothing found" "" "$MSGS"

print_test_section "LP5: an answer about a file whose kept report found nothing"
stage_result_write "$ART/build-summary.json" pass "built" \
    '{"answers":["RLRED-90: wrong — it is checked"],"answer_findings":{"RLRED-90":"red-team lens, high: the config is read unchecked (a.sh: \"read_cfg\"; happens when: x; fix: code; ACCEPTED IF: y)"}}' >/dev/null
_lens
assert_eq "[LP5] no call: a.sh's kept clean report stands" "0" "$CALLS"

print_test_section "LP6: a file's report depends on the changed files the call opened for it"
_commit() { /usr/bin/git -C "$XR" add -A >/dev/null 2>&1; /usr/bin/git -C "$XR" commit -qm "$1" >/dev/null 2>&1; }
stage_result_write "$ART/build-summary.json" pass "built" '{}' >/dev/null
printf 'check_cfg\n' >> "$XR/a.sh"; _commit "a again"
FINDINGS="[]"; OPENS="$XR/b.sh"
_lens
assert_eq "[LP6] setup: a.sh reviewed, opening b.sh" "yes" "$(_asked a.sh)"
OPENS=""
printf 'b=3\n' >> "$XR/b.sh"; _commit "b, which a.sh's review read"
FINDINGS="[$FB]"
_lens
assert_eq "[LP6] b.sh changed: a.sh, whose review read it, is reviewed again" "yes" "$(_asked a.sh)"

print_test_section "LP7: a file with findings depends on every file of the change"
printf '# its finding\n' >> "$XR/a.sh"; _commit "a with its finding"
FINDINGS="[$FA]"
_lens
assert_contains "[LP7] setup: a.sh's report found something" "$MSGS" "the config is read unchecked"
printf 'b=4\n' >> "$XR/b.sh"; _commit "b, which a.sh's review did not read"
FINDINGS="[$FA, $FB]"
_lens
assert_eq "[LP7] b.sh changed: a.sh, whose report found something, is reviewed again" "yes" "$(_asked a.sh)"

print_test_section "LP8: a file renamed with nothing else changed keeps its report"
/usr/bin/git -C "$XR" mv b.sh c.sh >/dev/null 2>&1; _commit "rename b to c"
FINDINGS="[]"
_lens
assert_eq "[LP8] c.sh is not reviewed" "no" "$(_asked c.sh)"
assert_contains "[LP8] ...its findings, from b.sh, stand" "$MSGS" "b is set twice"

print_test_section "LP9: a file handed to test-author waits for it"
# shellcheck source=../../scripts/lib/stage-dispatch-mark.sh
source "$REPO_ROOT/scripts/lib/stage-dispatch-mark.sh"
STATE="$TEST_TEMP_DIR"; printf '{}' > "$STATE/pipeline-state.json"
export ZBUILD_STATE_DIR="$STATE" ZBUILD_INPUTS_FLOW="design test-author build test issue-acceptance review_lenses"
FINDINGS="[$FA]"; printf '# again\n' >> "$XR/a.sh"; _commit "a once more"
_lens
FID="$(jq -r '.data.findings[] | select(.text | contains("read unchecked")) | .id' "$ART/lens-red-team-code-result.json" | head -n 1)"
stage_dispatch_mark "$STATE/pipeline-state.json" test-author
touch -t 202001010000 "$(stage_dispatch_mark_path "$STATE" test-author)"
( # shellcheck source=../../plugins/agent/build/lib/answers.sh
  source "$REPO_ROOT/plugins/agent/build/lib/answers.sh"
  _ROUTE_LOOP_LAST_RESPONSE="ANSWER $FID: not mine — the test must change: tests/cfg-test.sh: it pins the unchecked read"
  _build_write_test_findings "$ART" ) >/dev/null 2>&1
stage_result_write "$ART/build-summary.json" pass "built" \
    "$(jq -nc --arg a "$FID: not mine — the test must change: tests/cfg-test.sh: it pins the unchecked read" '{answers: [$a]}')" >/dev/null
FINDINGS="[]"
_lens
assert_eq "[LP9] a.sh is not reviewed: no call" "0" "$CALLS"
assert_contains "[LP9] ...its finding stands" "$MSGS" "the config is read unchecked"
assert_contains "[LP9] ...and the summary says it waits" "$(cat "$ART/lens-red-team-summary.md")" "a.sh: handed to test-author, waiting"
stage_dispatch_mark "$STATE/pipeline-state.json" test-author
_lens
assert_eq "[LP9] test-author has run: a.sh is reviewed again" "yes" "$(_asked a.sh)"
assert_contains "[LP9] ...shown the not mine answer" "$(tr -s '[:space:]' ' ' < "$_P.1")" "not mine — the test must change"
_lacks "[LP9] ...and its finding is gone" "$MSGS" "read unchecked"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
