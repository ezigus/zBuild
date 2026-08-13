#!/usr/bin/env bash
# tests/integration/intake-branch-reclaim-test.sh
# Re-running an issue after a run died picks the branch back up (#1869).
#
# Every `zbuild pipeline start` mints a new run with its own worktree, and a run
# that aborts leaves that tree behind holding the issue's branch. Git allows a
# branch in exactly one worktree, so the NEXT run's intake could not check it
# out — and the collision was terminal. An operator re-running the same issue,
# with no flags and no cleanup, therefore hit a hard abort at intake for as long
# as the dead tree existed. This is the behaviour test for the fix.
#
# SPEC-1: intake reclaims a finished run's tree and continues on that branch,
#         with the commits the dead run made still present
# SPEC-2 [guard]: a LIVE run still holds its branch — intake refuses, with the
#         diagnostic, rather than pulling the tree out from under it
#
# Shape matches production deliberately: intake runs INSIDE the new run's own
# worktree (ADR-052), not in the main checkout, so the collision and its repair
# are exercised from a linked worktree the way the engine does it.
set -uo pipefail
# Deliberately NOT `set -e`: assert_fail returns non-zero, which aborts under -e
# before print_test_results, making a failing test appear to pass.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "intake: re-run reclaims a dead run's branch (#1869)"
setup_test_env "intake-branch-reclaim"

# shellcheck disable=SC1091
source "$REPO_ROOT/plugins/agent/intake/lib/branch-names.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/plugins/agent/intake/lib/branch-ops.sh"
set +e

export ZBUILD_RUN_ROOT="$TEST_TEMP_DIR/rr"
export ZBUILD_STATE_ROOT="$TEST_TEMP_DIR/state"
RUNS="$ZBUILD_RUN_ROOT/runs"

REPO="$TEST_TEMP_DIR/repo"
git init -q -b main "$REPO" 2>/dev/null
git -C "$REPO" config user.email "t@t"
git -C "$REPO" config user.name "t"
git -C "$REPO" config commit.gpgsign false
printf 'seed\n' > "$REPO/seed.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -qm seed 2>/dev/null

# _state <run_id> <status> — the run's pipeline-state.json, the only evidence
# intake has for whether the holding run is still working.
_state() {
    mkdir -p "$ZBUILD_STATE_ROOT/runs/$1"
    printf '{"schema_version":1,"run_id":"%s","issue":1869,"status":"%s","updated_at":"%s"}\n' \
        "$1" "$2" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$ZBUILD_STATE_ROOT/runs/$1/pipeline-state.json"
}

# _prior_run <run_id> <branch> — a run that created <branch>, committed on it,
# and then died without pushing. Never given an upstream: a run that dies at
# plan or build has nothing pushed yet, which is the whole case under test.
_prior_run() {
    local id="$1" br="$2"
    mkdir -p "$RUNS/$id"
    git -C "$REPO" worktree add -q "$RUNS/$id/worktree" -b "$br" 2>/dev/null
    printf 'work from the first attempt\n' > "$RUNS/$id/worktree/progress.txt"
    git -C "$RUNS/$id/worktree" add -A
    git -C "$RUNS/$id/worktree" commit -qm "first attempt" 2>/dev/null
    printf '%s' "$RUNS/$id/worktree"
}

# _new_run <run_id> — the tree the engine hands the next run: detached, clean.
_new_run() {
    local id="$1"
    mkdir -p "$RUNS/$id"
    git -C "$REPO" worktree add -q --detach "$RUNS/$id/worktree" 2>/dev/null
    printf '%s' "$RUNS/$id/worktree"
}

# ── SPEC-1: the re-run picks the branch back up ─────────────────────────────
BR1="zbuild/issue-1869-reclaim"
WT_DEAD="$(_prior_run dead-run "$BR1")"
_state dead-run aborted
WT_NEW="$(_new_run second-run)"

_out="$( cd "$WT_NEW" && _intake_checkout_branch "$BR1" 2>&1 )"; _rc=$?

if [[ "$_rc" -eq 0 ]]; then
    assert_pass "[SPEC-1] intake succeeds on a branch the dead run left checked out"
else
    assert_fail "[SPEC-1] a re-run must not abort because the previous run's tree exists" \
        "rc=$_rc out=$_out"
fi
_head="$(git -C "$WT_NEW" symbolic-ref --short HEAD 2>/dev/null || echo DETACHED)"
if [[ "$_head" == "$BR1" ]]; then
    assert_pass "[SPEC-1] the new run's worktree is on the issue branch"
else
    assert_fail "[SPEC-1] the new run must end up ON the branch, not merely not-fail" \
        "HEAD=$_head"
fi
# The point of reusing the branch rather than starting over: the first attempt's
# commits are here. A "fix" that freed the branch by resetting or recreating it
# would satisfy the two assertions above and silently discard a run's work.
if [[ "$(cat "$WT_NEW/progress.txt" 2>/dev/null)" == "work from the first attempt" ]]; then
    assert_pass "[SPEC-1] the dead run's committed work is present in the new tree"
else
    assert_fail "[SPEC-1] the previous attempt's commits must carry over" \
        "progress.txt: $(cat "$WT_NEW/progress.txt" 2>&1)"
fi
if [[ ! -d "$WT_DEAD" ]]; then
    assert_pass "[SPEC-1] the dead run's worktree was released"
else
    assert_fail "[SPEC-1] the dead run's worktree must be released, not left registered" \
        "still at $WT_DEAD"
fi

# ── SPEC-2 [guard]: a live run keeps its branch ─────────────────────────────
# Without this, "reclaim on collision" would let a second run yank the tree out
# from under a running one — two runs on one branch, one of them with a silently
# stale HEAD. The refusal, not the reclaim, is the safety property.
BR2="zbuild/issue-1869-live"
WT_LIVE="$(_prior_run live-run "$BR2")"
_state live-run in_progress
WT_NEW2="$(_new_run third-run)"

_out2="$( cd "$WT_NEW2" && _intake_checkout_branch "$BR2" 2>&1 )"; _rc2=$?

if [[ "$_rc2" -ne 0 ]]; then
    assert_pass "[SPEC-2] intake refuses a branch held by a live run"
else
    assert_fail "[SPEC-2] must never reclaim a live run's worktree" "rc=$_rc2 out=$_out2"
fi
if [[ -d "$WT_LIVE" ]]; then
    assert_pass "[SPEC-2] the live run's worktree is untouched"
else
    assert_fail "[SPEC-2] the live run's worktree must survive" "removed: $WT_LIVE"
fi
if grep -qF "already checked out at" <<< "$_out2"; then
    assert_pass "[SPEC-2] the refusal still names the holding worktree"
else
    assert_fail "[SPEC-2] the diagnostic must survive the reclaim path" "out=$_out2"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
