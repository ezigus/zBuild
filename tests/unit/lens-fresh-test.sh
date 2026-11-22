#!/usr/bin/env bash
# tests/unit/lens-fresh-test.sh — a lens reviews the whole change fresh in
# every round (#2584 R1; ADR-038, ADR-072 §4 §5, amended 2026-11-22).
#
# Why: on #1764 run 44910536811 each changed file came into the lens round as
# an earlier "clean" verdict on older code, and a new finding counted only on
# a line changed since: judge.held dropped three medium findings. A lens keeps
# no verdict and holds no pass: each round it is called, over the whole
# change, and every finding it gives is taken. Checks that judge fixed items
# (design, issue-acceptance, build's steps) keep theirs.
#
# LF1 [change] the first round: one call over the whole change; no verdict is
#              kept (no lens-<id>-judged.json)
# LF2 [change] nothing changed: the next round calls the lens again, over the
#              whole change, and its finding stands as given
# LF3 [change] build answers the finding: the next round is called over the
#              whole change and is shown the answer
# LF4 [change] a file found clean before, the code moved: a finding quoting a
#              line that was there before is taken — no judge.held, and the
#              lens is not told it passed the file before
# LF5 [change] build hands a finding to test-author (not mine): the next round
#              still calls the lens over the whole change; nothing waits
# LF6 [change] the check of the lens's findings is called every round: it
#              keeps no answer (no lens-<id>-check-judged.json)
# LF7 [guard]  each lens's findings' code is its whole name; two lenses of a
#              run that would share one, or a name too long, are refused
# LF8 [guard]  under the caller's IFS=, the call still reviews the change and
#              its finding is taken
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "a lens reviews the whole change fresh in every round (#2584 R1)"
setup_test_env "lens-fresh"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"

# The repository: a base on main, and a branch that changed a.sh and b.sh.
XR="$TEST_TEMP_DIR/repo"; mkdir -p "$XR"
(
    cd "$XR" && /usr/bin/git init -q -b main && /usr/bin/git config user.email t@t && /usr/bin/git config user.name t
    printf '# a line\n' > a.sh; printf '# b line\n' > b.sh
    /usr/bin/git add -A && /usr/bin/git commit -qm base
    /usr/bin/git checkout -q -b zbuild/issue-1
    printf 'read_cfg "$1"\n' >> a.sh; printf 'b=1\n' >> b.sh; /usr/bin/git commit -qam change
) >/dev/null 2>&1
export ZBUILD_REPO_ROOT="$XR"
_commit() { /usr/bin/git -C "$XR" add -A >/dev/null 2>&1; /usr/bin/git -C "$XR" commit -qm "$1" >/dev/null 2>&1; }

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
_N="$TEST_TEMP_DIR/n"; _P="$TEST_TEMP_DIR/p"; _CK="$TEST_TEMP_DIR/ck"
route_to_model() {
    if zb_test_lens_check_answer "$2"; then printf 'x\n' >> "$_CK"; return 0; fi
    local n; n=$(( $(cat "$_N" 2>/dev/null || echo 0) + 1 )); printf '%s' "$n" > "$_N"; printf '%s' "$2" > "$_P.$n"
    printf '{"score":5,"findings":%s}' "$FINDINGS"
}
_lens() {
    rm -f "$_N" "$_P".* "$_CK"
    ZBUILD_CURRENT_STAGE=review_lenses ZBUILD_REVIEW_LENS_ID=red-team _TPL_STAGE_FAIL_ON_review_lenses="high critical" \
        _review_lens_run_inner red-team "$TEST_TEMP_DIR/scope.md" "$ART/diff.patch" "$ART/lens-red-team.json" "$ART" >/dev/null 2>&1
    CALLS="$(cat "$_N" 2>/dev/null || echo 0)"
    CHECKS="$(wc -l < "$_CK" 2>/dev/null | tr -d ' ')"; CHECKS="${CHECKS:-0}"
    OUT="$(jq -r '.outcome // "MISSING"' "$ART/lens-red-team.json" 2>/dev/null)"
    MSGS="$(jq -r '[.findings[].message] | join("|")' "$ART/lens-red-team.json" 2>/dev/null)"
    PROMPT="$(cat "$_P.1" 2>/dev/null)"
}
ONLY="REVIEW ONLY THESE FILES"
_lacks() { if [[ "$2" == *"$3"* ]]; then assert_fail "$1" "it has: $3"; else assert_pass "$1"; fi; }
_absent() { if [[ -e "$2" ]]; then assert_fail "$1" "$2 exists"; else assert_pass "$1"; fi; }

print_test_section "LF1: the first round"
_lens
assert_eq "[LF1] one call" "1" "$CALLS"
_lacks "[LF1] ...over the whole change" "$PROMPT" "$ONLY"
assert_eq "[LF1] b's finding fails the lens" "fail" "$OUT"
_absent "[LF1] no verdict is kept" "$ART/lens-red-team-judged.json"

print_test_section "LF2: nothing changed"
_lens
assert_eq "[LF2] the lens is called again" "1" "$CALLS"
_lacks "[LF2] ...over the whole change" "$PROMPT" "$ONLY"
assert_contains "[LF2] its finding stands as given" "$MSGS" "b is set twice"

print_test_section "LF3: build answers the finding"
FID="$(jq -r '.data.findings[] | select(.text | contains("set twice")) | .id' "$ART/lens-red-team-code-result.json" 2>/dev/null | head -n 1)"
FTXT="$(jq -r '.data.findings[] | select(.text | contains("set twice")) | .text' "$ART/lens-red-team-code-result.json" 2>/dev/null | head -n 1)"
stage_result_write "$ART/build-summary.json" pass "built" \
    "$(jq -nc --arg a "$FID: done — b is set once now" --arg k "$FID" --arg t "$FTXT" '{answers: [$a], answer_findings: {($k): $t}}')" >/dev/null
FINDINGS="[]"
_lens
assert_eq "[LF3] one call" "1" "$CALLS"
_lacks "[LF3] ...over the whole change" "$PROMPT" "$ONLY"
assert_contains "[LF3] ...shown the answer" "$(tr -s '[:space:]' ' ' <<< "$PROMPT")" "done — b is set once now"
assert_eq "[LF3] nothing found: it passes" "pass" "$OUT"

print_test_section "LF4: a file found clean before; the code moved"
stage_result_write "$ART/build-summary.json" pass "built" '{}' >/dev/null
FINDINGS="[]"; _lens
printf '# unrelated\n' >> "$XR/a.sh"; _commit "a, unrelated"
FINDINGS="[$FA]"; : > "$ZBUILD_EVENTS_JSONL"
_lens
assert_contains "[LF4] a finding quoting a line that was there before is taken" "$MSGS" "the config is read unchecked"
_lacks "[LF4] ...no judge.held" "$(cat "$ZBUILD_EVENTS_JSONL")" '"judge.held"'
_lacks "[LF4] ...and the lens is not told it passed the file" "$PROMPT" "YOUR EARLIER VERDICTS ON PARTS YOU PASSED"

print_test_section "LF5: a finding handed to test-author"
# shellcheck source=../../scripts/lib/stage-dispatch-mark.sh
source "$REPO_ROOT/scripts/lib/stage-dispatch-mark.sh"
STATE="$TEST_TEMP_DIR"; printf '{}' > "$STATE/pipeline-state.json"
export ZBUILD_STATE_DIR="$STATE" ZBUILD_INPUTS_FLOW="design test-author build test issue-acceptance review_lenses"
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
assert_eq "[LF5] the lens is called" "1" "$CALLS"
_lacks "[LF5] ...over the whole change" "$PROMPT" "$ONLY"
_lacks "[LF5] ...and nothing waits" "$(cat "$ART/lens-red-team-summary.md" 2>/dev/null)" "waiting"
unset ZBUILD_STATE_DIR ZBUILD_INPUTS_FLOW

print_test_section "LF6: the check is called every round"
FINDINGS="[$FB]"; _lens
assert_eq "[LF6] the check is called" "1" "$CHECKS"
_lens
assert_eq "[LF6] ...and called again, nothing changed" "1" "$CHECKS"
_absent "[LF6] the check keeps no answer" "$ART/lens-red-team-check-judged.json"

print_test_section "LF7: each lens's code is its own, by construction"
_c1=""; _c2=""; _rl_finding_code_v _c1 security; _rl_finding_code_v _c2 secrets
assert_eq "[LF7] security's code is its whole name" "RLSECURITY" "$_c1"
assert_eq "[LF7] ...secrets' is its own" "RLSECRETS" "$_c2"
_rl_finding_code_v _c1 red-team
assert_eq "[LF7] a name's letters and digits, upper case" "RLREDTEAM" "$_c1"
_TPL_MAP_ELEMENTS_review_lenses="red-team,red_team" ZBUILD_CURRENT_STAGE=review_lenses _rl_lens_code_ok_v _c1 red-team "$ART/lens-x.json" >/dev/null 2>&1
assert_eq "[LF7] red-team and red_team in one run would share RLREDTEAM: refused" "1 misconfigured" "$? $(jq -r .outcome "$ART/lens-x.json" 2>/dev/null)"
rm -f "$ART/lens-x.json"
_rl_lens_code_ok_v _c1 an-extremely-long-lens-name-indeed "$ART/lens-x.json" >/dev/null 2>&1
assert_eq "[LF7] a name too long for a code: refused" "1 misconfigured" "$? $(jq -r .outcome "$ART/lens-x.json" 2>/dev/null)"

print_test_section "LF8: the caller's IFS"
FINDINGS="[$FA]"
_ifs_lens() { local IFS=,; _lens; }
_ifs_lens
assert_eq "[LF8] under IFS=, one call" "1" "$CALLS"
assert_contains "[LF8] ...and its finding is taken" "$MSGS" "the config is read unchecked"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
