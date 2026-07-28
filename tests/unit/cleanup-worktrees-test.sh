#!/usr/bin/env bash
# tests/unit/cleanup-worktrees-test.sh
# Reclaiming per-run worktrees (#888), per the `--age-days` decision.
#
# A per-run worktree is the largest artifact a run leaves — a full working tree
# each — so default-on worktrees need a pruner. A pruner that can eat work is
# worse than none, so most of these SPECs assert what it REFUSES to touch.
#
# SPEC-1: an old, clean, pushed worktree is a candidate
# SPEC-2: a worktree newer than the age threshold is kept   [NOT mutation-verified]
# SPEC-3: a worktree with uncommitted work is kept          [NOT mutation-verified]
#
# HONEST CAVEAT on SPEC-2 and SPEC-3: both are ABSENCE-based ("the scanner must not
# report X"), and absence is produced by every guard, not just the one under test.
# Removing the age guard and the dirty guard individually — verified applied, inside
# _cleanup_scan_worktrees specifically — did NOT redden either assertion, so
# something else is also excluding those fixtures and these two currently prove
# less than they claim. The fixtures themselves were checked and are correct
# (pushed, upstream set, dirty file present, ages 0d/30d).
#
# SPEC-1, SPEC-4, SPEC-5 and SPEC-6 ARE meaningful: SPEC-4 is mutation-verified,
# SPEC-1 asserts presence (a scanner that finds nothing fails it), SPEC-6 asserts
# the git registration is gone.
#
# Do not treat SPEC-2/3 as protection until the exclusion is explained. Tracked as
# a follow-up rather than left as a green tick implying coverage.
# SPEC-4: the ACTIVE run's worktree is kept (resume needs it)
# SPEC-5: worktrees outside the zbuild run root are ignored entirely
# SPEC-6: applying removes the worktree AND its git registration (not just rm -rf)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "cleanup: per-run worktree reclamation (#888)"
setup_test_env "cleanup-worktrees"

# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/lib/cleanup.sh"
set +e   # cleanup.sh may set errexit; we assert on intentional non-zero returns

export ZBUILD_RUN_ROOT="$TEST_TEMP_DIR/rr"
RUNS="$ZBUILD_RUN_ROOT/runs"

R="$TEST_TEMP_DIR/repo"
mkdir -p "$R"
git -C "$R" init -q 2>/dev/null
git -C "$R" config user.email t@t; git -C "$R" config user.name t
: > "$R/f"; git -C "$R" add -A; git -C "$R" commit -qm init 2>/dev/null
# A bare origin, so "pushed" is a state a branch can actually be in.
ORIGIN="$TEST_TEMP_DIR/origin.git"
git init -q --bare "$ORIGIN" 2>/dev/null
git -C "$R" remote add origin "$ORIGIN" 2>/dev/null

# _mk <run_id> <branch> <age_days> — a worktree under the run root, backdated.
# Every fixture is PUSHED. Without that, the unpushed-commits guard rejects them
# all and each "is kept" assertion passes for the wrong reason — mutation-testing
# the age, dirty and active-run guards showed all three were inert until this.
_mk() {
    local id="$1" br="$2" age="${3:-0}"
    mkdir -p "$RUNS/$id"
    git -C "$R" worktree add -q "$RUNS/$id/worktree" -b "$br" 2>/dev/null
    git -C "$RUNS/$id/worktree" push -q -u origin "$br" 2>/dev/null
    if [[ "$age" -gt 0 ]]; then
        local when; when="$(( $(date +%s) - age * 86400 ))"
        # BSD and GNU touch take different -t/-d forms; try both.
        touch -t "$(date -r "$when" +%Y%m%d%H%M 2>/dev/null || date -d "@$when" +%Y%m%d%H%M)" \
            "$RUNS/$id/worktree" 2>/dev/null || true
    fi
    printf '%s' "$RUNS/$id/worktree"
}

# _backdate <path> <age_days> — must run AFTER any git work in the tree, since
# git operations touch the directory and would undo it.
_backdate() {
    local d="$1" age="$2" when
    when="$(( $(date +%s) - age * 86400 ))"
    touch -t "$(date -r "$when" +%Y%m%d%H%M 2>/dev/null || date -d "@$when" +%Y%m%d%H%M)" "$d" 2>/dev/null || true
}

_scan() { (cd "$R" && _cleanup_scan_worktrees "${1:-14}"); }

# The scanner reports git's RESOLVED paths; $TEST_TEMP_DIR is under the macOS
# /var -> /private/var symlink. Compare canonically or every match silently fails.
_canon() { (cd "$1" 2>/dev/null && pwd -P) || printf '%s' "$1"; }
# String-only canonicalisation for paths that no longer exist (post-removal checks):
# resolve the parent, which still does, and re-attach the basename.
_canon_str() {
    local d b; d="$(dirname "$1")"; b="$(basename "$1")"
    printf '%s/%s' "$( (cd "$d" 2>/dev/null && pwd -P) || printf '%s' "$d" )" "$b"
}
# Capture then match: `producer | grep -q` SIGPIPEs the producer when grep exits
# early (#1015/#1260), which under pipefail turns a correct scan into a failure.
_scan_has() {
    local _out; _out="$(_scan "${2:-14}")"
    grep -qF "$(_canon "$1")" <<< "$_out"
}

# ── SPEC-1: old, clean, PUSHED worktree is a candidate ──────────────────────
# The branch must genuinely be pushed. A branch with no upstream cannot be proven
# pushed, and _cleanup_has_unpushed_commits correctly refuses those — the first
# draft of this SPEC asserted the opposite and was wrong about the code, not the
# code wrong about the branch.
WT_OLD="$(_mk old-run zbuild/issue-1-old 0)"
_backdate "$WT_OLD" 30   # after _mk's push: git touches the directory
if _scan_has "$WT_OLD" 14; then
    assert_pass "[SPEC-1] an old, clean worktree is reported as reclaimable"
else
    assert_fail "[SPEC-1] the scanner must find an old clean worktree" "scan: $(_scan 14)"
fi

# ── SPEC-2: newer than the threshold is kept ────────────────────────────────
WT_NEW="$(_mk new-run zbuild/issue-2-new 0)"
if ! _scan_has "$WT_NEW" 14; then
    assert_pass "[SPEC-2] a worktree newer than --age-days is kept"
else
    assert_fail "[SPEC-2] a fresh worktree must not be reclaimed" "scan: $(_scan 14)"
fi

# ── SPEC-3: uncommitted work is kept, however old ───────────────────────────
WT_DIRTY="$(_mk dirty-run zbuild/issue-3-dirty 0)"
printf 'work in progress\n' > "$WT_DIRTY/uncommitted.txt"
_backdate "$WT_DIRTY" 30
if ! _scan_has "$WT_DIRTY" 14; then
    assert_pass "[SPEC-3] a worktree with uncommitted work is kept"
else
    assert_fail "[SPEC-3] never reclaim a worktree holding uncommitted work" "scan: $(_scan 14)"
fi

# ── SPEC-4: the active run is kept ──────────────────────────────────────────
WT_ACTIVE="$(_mk active-run zbuild/issue-4-active 0)"
_backdate "$WT_ACTIVE" 30
_out_active="$(cd "$R" && ZBUILD_RUN_ID=active-run _cleanup_scan_worktrees 14)"
if ! grep -qF "$(_canon "$WT_ACTIVE")" <<< "$_out_active"; then
    assert_pass "[SPEC-4] the active run's worktree is kept (resume needs it)"
else
    assert_fail "[SPEC-4] must never reclaim the active run's worktree" "scan: $_out_active"
fi

# ── SPEC-5: worktrees outside the run root are ignored ──────────────────────
WT_FOREIGN="$TEST_TEMP_DIR/foreign-wt"
git -C "$R" worktree add -q "$WT_FOREIGN" -b zbuild/issue-5-foreign 2>/dev/null
if ! _scan_has "$WT_FOREIGN" 0; then
    assert_pass "[SPEC-5] worktrees outside the zbuild run root are ignored"
else
    assert_fail "[SPEC-5] only zbuild's own run worktrees are in scope" "scan: $(_scan 0)"
fi

# ── SPEC-6: applying removes the tree AND its git registration ─────────────
(cd "$R" && _cleanup_apply_worktree_plan "$WT_OLD") >/dev/null 2>&1
_gone=0; [[ ! -d "$WT_OLD" ]] && _gone=1
_unregistered=0
_wt_list="$(git -C "$R" worktree list --porcelain 2>/dev/null)"
grep -qF "$(_canon_str "$WT_OLD")" <<< "$_wt_list" || _unregistered=1
if [[ "$_gone" -eq 1 && "$_unregistered" -eq 1 ]]; then
    assert_pass "[SPEC-6] applying removes the worktree and its git registration"
else
    assert_fail "[SPEC-6] rm -rf alone would leave a registration git still reports" \
        "dir_gone=$_gone unregistered=$_unregistered"
fi

# ── SPEC-7: the ZBUILD_WORKTREE_ROOT override layout is also reclaimed ───────
# zbuild_worktree_path supports two layouts; the scanner originally matched only
# the co-located one, so cleanup was a silent no-op for override installs —
# worktrees piling up forever with no error. Regression guard for that.
# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/lib/worktree.sh" 2>/dev/null || true
OVR="$TEST_TEMP_DIR/ovr"
mkdir -p "$OVR"
git -C "$R" worktree add -q "$OVR/ovr-run" -b zbuild/issue-7-ovr 2>/dev/null
git -C "$OVR/ovr-run" push -q -u origin zbuild/issue-7-ovr 2>/dev/null
_backdate "$OVR/ovr-run" 30
_ovr_out="$(cd "$R" && ZBUILD_WORKTREE_ROOT="$OVR" _cleanup_scan_worktrees 14)"
if grep -qF "$(_canon "$OVR/ovr-run")" <<< "$_ovr_out"; then
    assert_pass "[SPEC-7] worktrees under ZBUILD_WORKTREE_ROOT are reclaimable too"
else
    assert_fail "[SPEC-7] the override layout must not be a silent cleanup no-op" \
        "scan: $_ovr_out"
fi

# ── SPEC-8: called outside a git repo, the scanner errors rather than returning empty ──
( cd "$TEST_TEMP_DIR" && _cleanup_scan_worktrees 14 ) >/dev/null 2>&1; _rc_norepo=$?
assert_eq "[SPEC-8] outside a git repo the scanner errors (rc=2), not a silent empty scan" \
    "2" "$_rc_norepo"

# ── SPEC-9: applying to an override-layout worktree must NOT delete the root ──
# For the override layout the parent of $wt is the operator's configured root, not
# a per-run dir. rmdir'ing it would silently remove their directory once the last
# worktree went — and `|| true` would hide it. SPEC-7 scanned this layout but never
# applied to it, which is how the bug survived.
(cd "$R" && ZBUILD_WORKTREE_ROOT="$OVR" _cleanup_apply_worktree_plan "$OVR/ovr-run") >/dev/null 2>&1
if [[ ! -d "$OVR/ovr-run" && -d "$OVR" ]]; then
    assert_pass "[SPEC-9] override-layout apply removes the worktree but keeps the configured root"
else
    assert_fail "[SPEC-9] the operator's ZBUILD_WORKTREE_ROOT must survive cleanup" \
        "worktree_gone=$([[ ! -d "$OVR/ovr-run" ]] && echo yes || echo no) root_exists=$([[ -d "$OVR" ]] && echo yes || echo NO)"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
