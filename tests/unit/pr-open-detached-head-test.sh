#!/usr/bin/env bash
# tests/unit/pr-open-detached-head-test.sh — pr-open never switches the tree back
# to a stale branch ref (#2264).
#
# Why: #1844 run 37066147994 reached pr-open with HEAD detached three commits
# ahead of the run branch's ref (origin already held HEAD, from the stage-end
# pushes). pr-open saw "not on the target branch" and ran `git checkout
# <target>`: the tree went back to the stale ref, the push reconcile saw the
# remote ahead and skipped, and `gh pr create` refused — "you must first push
# the current branch". No PR, and the run's work was off the branch.
#
# P1 [change] the run branch ends at HEAD's commit — the work is not dropped
# P2 [change] HEAD is on the run branch
# P3 [guard]  origin still holds HEAD's commit
# P4 [change] gh pr create is told the branch (--head), never left to infer it
# P5 [change] HEAD and the branch diverged → pr-open refuses, names why, and
#             neither pushes nor calls gh
# P6 [change] the HEAD check itself fails (git error) → pr-open refuses and says
#             so, instead of falling through to a checkout (review on #2266)
# M1 [change] merge (same checkout plumbing) also ends with the run branch at
#             HEAD's commit, and HEAD on it
# M2 [change] merge also refuses a diverged HEAD, and calls no gh
# M3 [change] merge also refuses when the HEAD check fails
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "pr-open never switches back to a stale branch ref (#2264)"
setup_test_env "pr-open-detached-head"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"
export ZBUILD_EVENTS_DB="/dev/null"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_RUN_ID="pr-open-2264-$$"

B="zbuild/issue-2264-ci"
GH_LOG="$TEST_TEMP_DIR/gh.log"
cat > "$TEST_TEMP_DIR/bin/gh" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GH_LOG"
case "\$*" in
  "pr list"*) exit 0 ;;
  "pr create"*) echo "https://github.com/mock/repo/pull/2264"; exit 0 ;;
esac
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/gh"

# _fixture <name> — origin + a clone whose run branch ref is stale and whose
# HEAD is detached ahead of it, with origin already at HEAD (the #1844 shape).
_fixture() {
    REMOTE="$TEST_TEMP_DIR/$1.git"; REPO="$TEST_TEMP_DIR/$1"
    git init -q --bare "$REMOTE"; mkdir -p "$REPO"
    (
        cd "$REPO" || exit 1
        git init -q -b main .
        git config user.email t@e.st; git config user.name t
        git remote add origin "$REMOTE"
        printf 'seed\n' > SEED; git add SEED; git commit -q -m baseline
        git push -q origin main
        git checkout -q -b "$B"
        printf 'a\n' > a; git add a; git commit -q -m "test-author"
        git push -q origin "$B"
        git checkout -q --detach
        printf 'b\n' > b; git add b; git commit -q -m "build 1"
        printf 'c\n' > c; git add c; git commit -q -m "build 2"
        git push -q --force origin "HEAD:refs/heads/$B"
    ) >/dev/null 2>&1
    STATE_DIR="$TEST_TEMP_DIR/state-$1"; mkdir -p "$STATE_DIR/artifacts"
    printf '{"schema_version":1,"verdict":"approve","issues":[],"summary":"t"}\n' > "$STATE_DIR/artifacts/review.json"
    STATE_FILE="$STATE_DIR/pipeline-state.json"
    printf '{"issue":2264,"branch":"%s"}\n' "$B" > "$STATE_FILE"
    : > "$GH_LOG"
}
_sha() { git -C "$1" rev-parse -q --verify "$2" 2>/dev/null; }

# shellcheck source=../../plugins/tool/pr-open/plugin.sh
source "$REPO_ROOT/plugins/tool/pr-open/plugin.sh"

print_test_section "P1–P4: the #1844 replay"
_fixture p1; HEAD_SHA="$(_sha "$REPO" HEAD)"
( cd "$REPO" && pr_open_run "pr" "$STATE_FILE" ) >/dev/null 2>&1
assert_eq "[P1] the run branch ends at HEAD's commit" "$HEAD_SHA" "$(_sha "$REPO" "refs/heads/$B")"
assert_eq "[P2] HEAD is on the run branch" "$B" "$(git -C "$REPO" symbolic-ref -q --short HEAD 2>/dev/null)"
assert_eq "[P3] origin still holds HEAD's commit" "$HEAD_SHA" "$(_sha "$REMOTE" "refs/heads/$B")"
_create="$(grep '^pr create' "$GH_LOG" 2>/dev/null || true)"
assert_contains "[P4] gh pr create is told the branch" "$_create" "--head $B"

print_test_section "P5: diverged — refuse, do not guess"
_fixture p5
( cd "$REPO" && git checkout -q "$B" && printf 'x\n' > x && git add x && git commit -q -m "branch-only" \
    && git checkout -q --detach "origin/$B" 2>/dev/null || git checkout -q --detach HEAD~1 ) >/dev/null 2>&1
git -C "$REPO" fetch -q origin >/dev/null 2>&1
git -C "$REPO" checkout -q --detach "refs/remotes/origin/$B" >/dev/null 2>&1
BR="$(_sha "$REPO" "refs/heads/$B")"; RM_BEFORE="$(_sha "$REMOTE" "refs/heads/$B")"
( cd "$REPO" && pr_open_run "pr" "$STATE_FILE" ) >/dev/null 2>&1; rc=$?
assert_eq "[P5] pr-open refuses (rc 1)" "1" "$rc"
assert_contains "[P5] the result names the divergence" \
    "$(jq -r '.reason // ""' "$STATE_DIR/artifacts/pr-result.json" 2>/dev/null)" "diverged"
assert_eq "[P5] the branch keeps its own commit" "$BR" "$(_sha "$REPO" "refs/heads/$B")"
assert_eq "[P5] origin is untouched" "$RM_BEFORE" "$(_sha "$REMOTE" "refs/heads/$B")"
assert_eq "[P5] gh was never called" "" "$(cat "$GH_LOG" 2>/dev/null)"

print_test_section "P6: the HEAD check fails — refuse, say why"
_fixture p6
( cd "$REPO" && zbuild_keep_head_on_branch() { ZBUILD_HEAD_OUTCOME="error"; return 2; }
  pr_open_run "pr" "$STATE_FILE" ) >/dev/null 2>&1; rc=$?
assert_eq "[P6] pr-open refuses (rc 1)" "1" "$rc"
assert_contains "[P6] the result says the HEAD check failed" \
    "$(jq -r '.reason // ""' "$STATE_DIR/artifacts/pr-result.json" 2>/dev/null)" "could not check"
assert_eq "[P6] gh was never called" "" "$(cat "$GH_LOG" 2>/dev/null)"

print_test_section "M: merge has the same plumbing"
# shellcheck source=../../plugins/tool/merge/plugin.sh
source "$REPO_ROOT/plugins/tool/merge/plugin.sh"
_gate_pass() {   # a passing gate, handed to merge by name
    printf '{"result_contract":2,"verdict":"pass","disposition":"complete","reason":"ok"}\n' \
        > "$STATE_DIR/artifacts/gate-aggregator-result.json"
    printf '{"inputs":{"gate_aggregator_result":"%s"}}\n' "$STATE_DIR/artifacts/gate-aggregator-result.json" \
        > "$STATE_DIR/stage-inputs.json"
}
_fixture m1; _gate_pass; HEAD_SHA="$(_sha "$REPO" HEAD)"
( cd "$REPO" && ZBUILD_STAGE_INPUTS="$STATE_DIR/stage-inputs.json" merge_run "pr" "$STATE_FILE" ) >/dev/null 2>&1
assert_eq "[M1] the run branch ends at HEAD's commit" "$HEAD_SHA" "$(_sha "$REPO" "refs/heads/$B")"
assert_eq "[M1] HEAD is on the run branch" "$B" "$(git -C "$REPO" symbolic-ref -q --short HEAD 2>/dev/null)"

_fixture m2; _gate_pass
( cd "$REPO" && git checkout -q "$B" && printf 'x\n' > x && git add x && git commit -q -m "branch-only" ) >/dev/null 2>&1
git -C "$REPO" checkout -q --detach "refs/remotes/origin/$B" >/dev/null 2>&1 \
    || { git -C "$REPO" fetch -q origin >/dev/null 2>&1; git -C "$REPO" checkout -q --detach "refs/remotes/origin/$B" >/dev/null 2>&1; }
BR="$(_sha "$REPO" "refs/heads/$B")"
( cd "$REPO" && ZBUILD_STAGE_INPUTS="$STATE_DIR/stage-inputs.json" merge_run "pr" "$STATE_FILE" ) >/dev/null 2>&1; rc=$?
assert_eq "[M2] merge refuses (rc 1)" "1" "$rc"
assert_eq "[M2] the branch keeps its own commit" "$BR" "$(_sha "$REPO" "refs/heads/$B")"
assert_eq "[M2] gh was never called" "" "$(cat "$GH_LOG" 2>/dev/null)"

_fixture m3; _gate_pass
( cd "$REPO" && zbuild_keep_head_on_branch() { ZBUILD_HEAD_OUTCOME="error"; return 2; }
  ZBUILD_STAGE_INPUTS="$STATE_DIR/stage-inputs.json" merge_run "pr" "$STATE_FILE" ) >/dev/null 2>&1; rc=$?
assert_eq "[M3] merge refuses when the HEAD check fails (rc 1)" "1" "$rc"
assert_eq "[M3] gh was never called" "" "$(cat "$GH_LOG" 2>/dev/null)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
