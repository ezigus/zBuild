#!/usr/bin/env bash
# tests/unit/judge-change-list-test.sh — a judge is pointed at the change, not
# given it: issue-acceptance and the lenses are told the commit the branch
# started from and the files it changed, and diff for themselves (#2507,
# ADR-072 §7).
#
# Why: on #1805 run 42556446368 each issue-acceptance prompt was ~250 KB, 214 KB
# of it the diff (69% test files), and the judges had no git to read it with.
#
# L1 [change] issue-acceptance's prompt names the starting commit and each
#             changed file, and holds no diff
# L2 [change] its kept answer is judged again when a changed file's content
#             changes, and kept when nothing changed
# L3 [change] a lens's prompt names the starting commit and each changed file,
#             and holds no diff
# L4 [change] a lens's kept report is judged again when a changed file's
#             content changes
# L5 [change] a lens's quote of a line the change removed is still found
# L6 [change] with no starting commit known, the judge is pointed at the patch
#             file, and the patch is not pasted in
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "a judge is pointed at the change, not given it (#2507)"
setup_test_env "judge-change-list"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"

# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
# shellcheck source=../../plugins/agent/issue-acceptance/plugin.sh
source "$REPO_ROOT/plugins/agent/issue-acceptance/plugin.sh" 2>/dev/null
# shellcheck source=../../plugins/agent/review-lens/plugin.sh
source "$REPO_ROOT/plugins/agent/review-lens/plugin.sh" 2>/dev/null
set +e

# A repository whose main holds the code from before; the branch changes a
# file, adds a test and deletes another file.
G="$TEST_TEMP_DIR/repo"; mkdir -p "$G/core" "$G/tests"
(
    cd "$G" && git init -q -b main && git config user.email t@t && git config user.name t
    printf 'keep\nOLD_LINE_REMOVED\n' > core/a.sh; printf 'gone\n' > core/old.sh
    git add -A && git commit -q -m base
    git checkout -q -b feature
    printf 'keep\nNEW_LINE_ADDED\n' > core/a.sh; printf 'TEST_BODY\n' > tests/a-test.sh; git rm -q core/old.sh
    git add -A && git commit -q -m change
) >/dev/null 2>&1
BASE="$(git -C "$G" rev-parse main)"
export ZBUILD_REPO_ROOT="$G"

PROMPT="$TEST_TEMP_DIR/prompt.txt"; CALLS="$TEST_TEMP_DIR/calls"
ANSWER=""
route_to_model() { printf '%s' "$2" > "$PROMPT"; printf 'x\n' >> "$CALLS"; printf '%s\n' "$ANSWER"; }
resolve_tier() { printf 'T2'; }
stage_prompt_compose_parts() { printf '%s' "${@: -1}"; }
_no_diff() {  # <label> <prompt>
    if [[ "$2" == *"diff --git"* || "$2" == *NEW_LINE_ADDED* || "$2" == *OLD_LINE_REMOVED* || "$2" == *TEST_BODY* ]]; then
        assert_fail "$1" "a diff is in the prompt"
    else
        assert_pass "$1"
    fi
}

# ── L1 / L2 ──────────────────────────────────────────────────────────────────
print_test_section "L1/L2: issue-acceptance"
S="$TEST_TEMP_DIR/ia"; A="$S/artifacts"; IN="$S/inputs"; mkdir -p "$A" "$IN"
printf '{}' > "$S/pipeline-state.json"
zb_test_issue_output "$IN" "Print each line once." >/dev/null
printf '%s\n' '# Design' '```acceptance' 'SPEC-1[change]: each line is printed once' 'TESTFILES:' 'SPEC-1: tests/a-test.sh' 'WIRING: none' '```' > "$IN/design.md"
zb_test_test_run_output "$IN" pass 1 0 >/dev/null
jq -n --arg i "$IN/intake-result.json" --arg d "$IN/design.md" --arg t "$IN/test-results.json" \
    '{inputs: {a: $i, b: $d, d: $t}}' > "$S/stage-inputs.json"
export ZBUILD_STAGE_INPUTS="$S/stage-inputs.json" ZBUILD_ARTIFACT_DIR="$A"
_ia() { : > "$PROMPT"; ( cd "$G" && issue_acceptance_run issue-acceptance "$S/pipeline-state.json" ) >/dev/null 2>&1; }
ANSWER='MET: each line is printed once'
: > "$CALLS"; _ia
_p="$(cat "$PROMPT")"
assert_contains "[L1] the prompt names the commit the branch started from" "$_p" "$BASE"
assert_contains "[L1] ...each changed file" "$_p" "core/a.sh"
assert_contains "[L1] ...the added test" "$_p" "tests/a-test.sh"
assert_contains "[L1] ...the deleted file" "$_p" "core/old.sh"
assert_contains "[L1] ...and how to see a change" "$_p" "git diff $BASE HEAD"
_no_diff "[L1] ...and holds no diff" "$_p"
: > "$CALLS"; _ia
assert_eq "[L2] nothing changed: the kept answer is used" "0" "$(grep -c . "$CALLS")"
( cd "$G" && printf 'keep\nNEW_LINE_CHANGED_AGAIN\n' > core/a.sh && git commit -qam again ) >/dev/null 2>&1
: > "$CALLS"; _ia
assert_eq "[L2] a changed file's content changed: judged again" "1" "$(grep -c . "$CALLS")"

# ── L3 / L4 / L5 ─────────────────────────────────────────────────────────────
print_test_section "L3-L5: a lens"
LS="$TEST_TEMP_DIR/lens"; LA="$LS/artifacts"; mkdir -p "$LA"
printf '{}' > "$LS/pipeline-state.json"
export ZBUILD_ARTIFACT_DIR="$LA" ZBUILD_STATE_DIR="$LS"
unset ZBUILD_STAGE_INPUTS
_lens() {
    : > "$PROMPT"
    ( cd "$G" && export ZBUILD_MAP_ELEMENT=correctness ZBUILD_REVIEW_LENS_ID=correctness
      review_lens_run lens-correctness "$LS/pipeline-state.json" ) >/dev/null 2>&1
}
ANSWER='{"score":9,"findings":[]}'
: > "$CALLS"; _lens
_p="$(cat "$PROMPT")"
assert_contains "[L3] the prompt names the commit the branch started from" "$_p" "$BASE"
assert_contains "[L3] ...each changed file" "$_p" "core/a.sh"
assert_contains "[L3] ...the added test" "$_p" "tests/a-test.sh"
assert_contains "[L3] ...and how to see a change" "$_p" "git diff $BASE HEAD"
_no_diff "[L3] ...and holds no diff" "$_p"
: > "$CALLS"; _lens
assert_eq "[L4] nothing changed: the kept report is used" "0" "$(grep -c . "$CALLS")"
( cd "$G" && printf 'keep\nNEW_LINE_THIRD\n' > core/a.sh && git commit -qam third ) >/dev/null 2>&1
: > "$CALLS"; _lens
assert_eq "[L4] a changed file's content changed: judged again" "1" "$(grep -c . "$CALLS")"
ANSWER='{"score":4,"findings":[{"file":"core/a.sh","category":"logic","severity":"medium","line":2,"message":"the old guard is gone","quote":"OLD_LINE_REMOVED","introduced":true,"fix":"code"}]}'
( cd "$G" && printf 'keep\nNEW_LINE_FOURTH\n' > core/a.sh && git commit -qam fourth ) >/dev/null 2>&1
: > "$CALLS"; _lens
assert_eq "[L5] a quote of a line the change removed is found: no second ask" "1" "$(grep -c . "$CALLS")"
assert_eq "[L5] ...and the finding stands" "1" "$(jq -r '.findings | length' "$LA/lens-correctness.json" 2>/dev/null)"

# ── L6 ───────────────────────────────────────────────────────────────────────
print_test_section "L6: no starting commit known"
N="$TEST_TEMP_DIR/norepo"; NA="$N/artifacts"; NIN="$N/inputs"; mkdir -p "$NA" "$NIN"
printf '{}' > "$N/pipeline-state.json"
zb_test_issue_output "$NIN" "Print each line once." >/dev/null
cp "$IN/design.md" "$NIN/design.md"
printf '%s\n' 'diff --git a/p.sh b/p.sh' '+PATCH_LINE_ADDED' > "$NIN/diff.patch"
jq -n --arg i "$NIN/intake-result.json" --arg d "$NIN/design.md" --arg p "$NIN/diff.patch" \
    '{inputs: {a: $i, b: $d, c: $p}}' > "$N/stage-inputs.json"
ANSWER='MET: each line is printed once'
( export ZBUILD_STAGE_INPUTS="$N/stage-inputs.json" ZBUILD_ARTIFACT_DIR="$NA" ZBUILD_REPO_ROOT="$N"
  cd "$N" && issue_acceptance_run issue-acceptance "$N/pipeline-state.json" ) >/dev/null 2>&1
_p="$(cat "$PROMPT")"
assert_contains "[L6] the judge is pointed at the patch file" "$_p" "$NIN/diff.patch"
assert_contains "[L6] ...and told the files in it" "$_p" "p.sh"
if [[ "$_p" == *PATCH_LINE_ADDED* ]]; then assert_fail "[L6] ...and the patch is not pasted in" "it is"
else assert_pass "[L6] ...and the patch is not pasted in"; fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
