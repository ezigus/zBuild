#!/usr/bin/env bash
# tests/unit/worktree-reclaim-test.sh
# zbuild_worktree_reclaim_dead — releasing a finished run's worktree so its
# branch can be checked out again (#1869).
#
# The premise the whole primitive rests on is SPEC-1's second half: a branch ref
# lives in the repository, not in the worktree holding it, so removing a clean
# tree loses NOTHING — the commits the dead run made are still on the branch
# afterwards. Every other SPEC here is a refusal, because the cases where that
# premise does not hold are the ones that would eat work:
#
# SPEC-1: a finished run's clean worktree is released, branch + commits intact
# SPEC-2 [guard]: a LIVE run's worktree is never touched
# SPEC-3 [guard]: uncommitted work is never destroyed (git's own refusal)
# SPEC-4 [guard]: a run whose liveness cannot be established is refused
# SPEC-5: an abandoned in_progress run (stale timestamp) is not "live"
# SPEC-6: run-id recovery covers both worktree layouts
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "worktree: reclaiming a dead run's worktree (#1869)"
setup_test_env "worktree-reclaim"

# shellcheck source=../../scripts/lib/worktree.sh
source "$REPO_ROOT/scripts/lib/worktree.sh"
set +e

export ZBUILD_RUN_ROOT="$TEST_TEMP_DIR/rr"
export ZBUILD_STATE_ROOT="$TEST_TEMP_DIR/state"
RUNS="$ZBUILD_RUN_ROOT/runs"

R="$TEST_TEMP_DIR/repo"
mkdir -p "$R"
git -C "$R" init -q -b main 2>/dev/null
git -C "$R" config user.email t@t; git -C "$R" config user.name t
git -C "$R" config commit.gpgsign false
: > "$R/seed"; git -C "$R" add -A; git -C "$R" commit -qm seed 2>/dev/null

# _state <run_id> <status> [updated_at] — the run's pipeline-state.json.
# Deliberately NOT pushed anywhere and never given an upstream: a run that dies
# before its first push is the case this primitive exists for.
_state() {
    local id="$1" status="$2" ts="${3:-}"
    [[ -n "$ts" ]] || ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    mkdir -p "$ZBUILD_STATE_ROOT/runs/$id"
    printf '{"schema_version":1,"run_id":"%s","issue":1,"status":"%s","updated_at":"%s"}\n' \
        "$id" "$status" "$ts" > "$ZBUILD_STATE_ROOT/runs/$id/pipeline-state.json"
}

# _mk_run <run_id> <branch> — a per-run worktree holding <branch>, with one
# commit made inside it (the "work the dead run got done" this must preserve).
_mk_run() {
    local id="$1" br="$2"
    mkdir -p "$RUNS/$id"
    git -C "$R" worktree add -q "$RUNS/$id/worktree" -b "$br" 2>/dev/null
    printf 'progress\n' > "$RUNS/$id/worktree/work.txt"
    git -C "$RUNS/$id/worktree" add -A
    git -C "$RUNS/$id/worktree" commit -qm "run $id progress" 2>/dev/null
    printf '%s' "$RUNS/$id/worktree"
}

# ── SPEC-1: a finished run's clean worktree is released ─────────────────────
WT_DEAD="$(_mk_run dead-1 zbuild/issue-1-dead)"
_state dead-1 aborted
_sha_before="$(git -C "$R" rev-parse zbuild/issue-1-dead)"

_out="$( (cd "$R" && zbuild_worktree_reclaim_dead "$WT_DEAD") 2>&1 )"; _rc=$?
if [[ "$_rc" -eq 0 ]]; then
    assert_pass "[SPEC-1] a finished run's worktree is reclaimed (rc=0)"
else
    assert_fail "[SPEC-1] a finished run's clean worktree must be reclaimable" "rc=$_rc out=$_out"
fi
if [[ ! -d "$WT_DEAD" ]]; then
    assert_pass "[SPEC-1] the worktree directory is gone"
else
    assert_fail "[SPEC-1] the worktree directory must be removed" "still at $WT_DEAD"
fi
# git's own registration must go too, or `git worktree list` keeps reporting it
# and the branch stays locked — a removal that only rm -rf'd would pass the
# assertion above while changing nothing that matters.
# Captured first, then matched: `producer | grep -q` SIGPIPEs the producer when
# grep exits early (#1015/#1260), which under pipefail fails a correct check.
_wt_list="$(git -C "$R" worktree list --porcelain 2>/dev/null || true)"
if ! grep -qF "$WT_DEAD" <<< "$_wt_list"; then
    assert_pass "[SPEC-1] the git worktree registration is gone, not just the directory"
else
    assert_fail "[SPEC-1] git must no longer list the reclaimed worktree" "$_wt_list"
fi
# THE PREMISE: nothing the dead run committed was lost.
_sha_after="$(git -C "$R" rev-parse zbuild/issue-1-dead 2>/dev/null || echo MISSING)"
if [[ "$_sha_after" == "$_sha_before" ]]; then
    assert_pass "[SPEC-1] the branch still points at the dead run's commit"
else
    assert_fail "[SPEC-1] reclaiming must not disturb the branch ref" \
        "before=$_sha_before after=$_sha_after"
fi
if [[ "$(git -C "$R" show "zbuild/issue-1-dead:work.txt" 2>/dev/null)" == "progress" ]]; then
    assert_pass "[SPEC-1] the dead run's committed work is still reachable"
else
    assert_fail "[SPEC-1] the committed work must survive reclamation" \
        "show: $(git -C "$R" show 'zbuild/issue-1-dead:work.txt' 2>&1)"
fi
# ...and the freed branch can now be checked out again, which is the point.
if git -C "$R" worktree add -q "$RUNS/next/worktree" zbuild/issue-1-dead 2>/dev/null; then
    assert_pass "[SPEC-1] the branch is checkoutable again after reclamation"
    git -C "$R" worktree remove "$RUNS/next/worktree" 2>/dev/null
else
    assert_fail "[SPEC-1] the whole point: the freed branch must be checkoutable" \
        "git worktree add still refuses"
fi

# ── SPEC-2 [guard]: a live run's worktree is never touched ──────────────────
WT_LIVE="$(_mk_run live-1 zbuild/issue-2-live)"
_state live-1 in_progress                      # updated_at = now
_out="$( (cd "$R" && zbuild_worktree_reclaim_dead "$WT_LIVE") 2>&1 )"; _rc=$?
if [[ "$_rc" -eq 3 && -d "$WT_LIVE" ]]; then
    assert_pass "[SPEC-2] a live run's worktree is refused (rc=3) and left in place"
else
    assert_fail "[SPEC-2] must never reclaim the worktree of an in-progress run" \
        "rc=$_rc present=$([[ -d "$WT_LIVE" ]] && echo yes || echo NO) out=$_out"
fi
# Positive flip: the SAME fixture becomes reclaimable once its run reports done,
# proving liveness was the barrier and not some unrelated exclusion.
_state live-1 complete
_out="$( (cd "$R" && zbuild_worktree_reclaim_dead "$WT_LIVE") 2>&1 )"; _rc=$?
if [[ "$_rc" -eq 0 && ! -d "$WT_LIVE" ]]; then
    assert_pass "[SPEC-2] positive flip: once the run reports complete it is reclaimed"
else
    assert_fail "[SPEC-2] the same worktree must be reclaimable once the run is done" \
        "rc=$_rc out=$_out"
fi

# ── SPEC-3 [guard]: uncommitted work is never destroyed ─────────────────────
WT_DIRTY="$(_mk_run dirty-1 zbuild/issue-3-dirty)"
_state dirty-1 aborted
printf 'unsaved\n' > "$WT_DIRTY/scratch.txt"
_out="$( (cd "$R" && zbuild_worktree_reclaim_dead "$WT_DIRTY") 2>&1 )"; _rc=$?
if [[ "$_rc" -ne 0 && -d "$WT_DIRTY" && -f "$WT_DIRTY/scratch.txt" ]]; then
    assert_pass "[SPEC-3] a worktree holding uncommitted work is refused, file intact"
else
    assert_fail "[SPEC-3] never destroy uncommitted work" \
        "rc=$_rc present=$([[ -f "$WT_DIRTY/scratch.txt" ]] && echo yes || echo NO) out=$_out"
fi
# Positive flip: remove the stray file and the same dead run IS reclaimed —
# so SPEC-3 pins the dirty refusal, not a fixture that could never be reclaimed.
rm -f "$WT_DIRTY/scratch.txt"
_out="$( (cd "$R" && zbuild_worktree_reclaim_dead "$WT_DIRTY") 2>&1 )"; _rc=$?
if [[ "$_rc" -eq 0 && ! -d "$WT_DIRTY" ]]; then
    assert_pass "[SPEC-3] positive flip: once clean, the same worktree is reclaimed"
else
    assert_fail "[SPEC-3] a now-clean dead run's worktree must be reclaimable" \
        "rc=$_rc out=$_out"
fi

# ── SPEC-4 [guard]: unprovable liveness is refused ──────────────────────────
# No state file at all: the run may still be working for all we can tell, and
# guessing "probably dead" here would put a live run's tree at risk.
WT_UNKNOWN="$(_mk_run unknown-1 zbuild/issue-4-unknown)"
_out="$( (cd "$R" && zbuild_worktree_reclaim_dead "$WT_UNKNOWN") 2>&1 )"; _rc=$?
if [[ "$_rc" -eq 4 && -d "$WT_UNKNOWN" ]]; then
    assert_pass "[SPEC-4] a run with no state is refused (rc=4), not assumed dead"
else
    assert_fail "[SPEC-4] must refuse when liveness cannot be established" \
        "rc=$_rc present=$([[ -d "$WT_UNKNOWN" ]] && echo yes || echo NO) out=$_out"
fi
if grep -qF "cannot prove it finished" <<< "$_out"; then
    assert_pass "[SPEC-4] the refusal names why, rather than failing silently"
else
    assert_fail "[SPEC-4] the refusal must say liveness could not be established" "out=$_out"
fi

# ── SPEC-5: an abandoned in_progress run is not live ────────────────────────
# A run killed mid-flight never gets to write a terminal status. Left as
# "in_progress" forever, it would lock its branch permanently — so liveness is
# in_progress AND recent, matching the 24h gate the resume contract already uses.
WT_STALE="$(_mk_run stale-1 zbuild/issue-5-stale)"
_stale_ts="$(date -u -d '@'"$(( $(date -u +%s) - 172800 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
             || date -u -r "$(( $(date -u +%s) - 172800 ))" +%Y-%m-%dT%H:%M:%SZ)"
_state stale-1 in_progress "$_stale_ts"
_out="$( (cd "$R" && zbuild_worktree_reclaim_dead "$WT_STALE") 2>&1 )"; _rc=$?
if [[ "$_rc" -eq 0 && ! -d "$WT_STALE" ]]; then
    assert_pass "[SPEC-5] an in_progress run stale by 48h is reclaimed, not live forever"
else
    assert_fail "[SPEC-5] a stale in_progress run must not hold its branch forever" \
        "rc=$_rc out=$_out"
fi

# ── SPEC-6: run-id recovery covers both layouts ─────────────────────────────
_id_colocated="$(zbuild_worktree_run_id "/x/.zbuild/runs/20260813-99/worktree")"
_id_override="$(zbuild_worktree_run_id "/custom/wt-root/20260813-99")"
_id_trailing="$(zbuild_worktree_run_id "/x/.zbuild/runs/20260813-99/worktree/")"
if [[ "$_id_colocated" == "20260813-99" && "$_id_override" == "20260813-99" \
      && "$_id_trailing" == "20260813-99" ]]; then
    assert_pass "[SPEC-6] run id recovered from co-located, override and trailing-slash paths"
else
    assert_fail "[SPEC-6] run id must be recoverable from both worktree layouts" \
        "colocated=$_id_colocated override=$_id_override trailing=$_id_trailing"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
