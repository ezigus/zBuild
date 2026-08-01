#!/usr/bin/env bash
# tests/unit/cleanup-worktrees-test.sh
# Reclaiming per-run worktrees (#888), per the `--age-days` decision.
#
# A per-run worktree is the largest artifact a run leaves — a full working tree
# each — so default-on worktrees need a pruner. A pruner that can eat work is
# worse than none, so most of these SPECs assert what it REFUSES to touch.
#
# SPEC-1: an old, clean, pushed worktree is a candidate
# SPEC-2: a worktree newer than the age threshold is kept   [mutation-verified — see below]
# SPEC-3: a worktree with uncommitted work is kept          [mutation-verified — see below]
#
# #1635 CORRECTION. That issue reported SPEC-2/3 as inert: "removing the age guard
# and the dirty guard individually reddened NEITHER", concluding some unexplained
# third exclusion was masking them. THAT OBSERVATION WAS WRONG. Re-running the
# mutation by hand — neutering each guard inside _cleanup_scan_worktrees (and
# nowhere else), against BOTH this revision and the merge-base — reddens the
# matching assertion every time:
#
#   age guard   -> `[SPEC-2] a fresh worktree must not be reclaimed`   FAILS
#   dirty guard -> `[SPEC-3] never reclaim a worktree holding ...`     FAILS
#
# Both were already load-bearing before #1635 changed anything. The likeliest
# cause of the original mis-observation is mutating a copy the test never reads —
# the installed engine under ~/.local/share/zbuild, or a stale
# $TMPDIR/zbuild-tier-buf.* harness buffer — since this file sources
# $REPO_ROOT/scripts/lib/cleanup.sh. Mutate the repo copy, and confirm the
# mutation is present in the tree the test actually sources.
#
# The claim is no longer a comment anyone has to trust: it is enforced by the
# mutation tier on every CI run —
#   tests/mutation/cleanup-worktree-age-guard.md
#   tests/mutation/cleanup-worktree-dirty-guard.md
#
# The positive-flip companions below are kept, but note what they do and do NOT
# prove. They vary the INPUT (age=0; remove the dirty file) and show the fixture
# is not permanently excluded for some unrelated reason — a real and different
# failure mode. They are NOT mutation verification, which varies the CODE.
#
# #1634 adds a THIRD companion per guard, and it closes a gap the other two
# cannot. Both existing forms are still satisfied by a scanner that examined
# nothing at all — absence proves the worktree was not reclaimed, never that it
# was considered. Since #1634 the scanner emits `<path>\tskip\t<reason>` for every
# worktree it examined and kept, so each SPEC additionally asserts the NAMED guard
# fired. Note this changes what the scan output contains: `_scan_has` now requires
# a `prune` decision, because a path alone now also appears on skip lines.
#
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
# Matches the PRUNE decision, not merely the path. Since #1634 the scanner also
# emits `skip` lines for worktrees it examined and kept, so a path-only match is
# satisfied by a worktree the scanner REFUSED to reclaim — which would invert the
# meaning of every `! _scan_has` assertion below.
_scan_has() {
    local _out _line; _out="$(_scan "${2:-14}")"
    _line="$(grep -F "$(_canon "$1")" <<< "$_out" || true)"
    grep -qF $'\tprune\t' <<< "$_line"
}

# The decision+reason for one worktree, or "" when the scanner never examined it.
_scan_line() {
    local _out; _out="$(_scan "${2:-14}")"
    grep -F "$(_canon "$1")" <<< "$_out" || true
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
# Positive-flip: at age_days=0 the threshold drops to zero; WT_NEW (brand-new, clean,
# pushed) must appear, proving the age guard above was the only exclusion mechanism.
if _scan_has "$WT_NEW" 0; then
    assert_pass "[SPEC-2] positive flip: WT_NEW appears at age_days=0 — age guard was the barrier"
else
    assert_fail "[SPEC-2] WT_NEW must appear at age_days=0; something other than age excludes it" \
        "scan0: $(_scan 0)"
fi
# #1634 reason assertion. The two above prove the worktree is not reclaimed and
# that age is what excludes it. Neither can tell "kept, because too new" from
# "never examined" — the silence this issue exists to remove. Assert the named
# guard, so an empty scan can no longer satisfy SPEC-2.
_new_line="$(_scan_line "$WT_NEW" 14)"
if grep -qF $'\tskip\t' <<< "$_new_line" && grep -qF "newer than" <<< "$_new_line"; then
    assert_pass "[SPEC-2] the fresh worktree is reported as skip:newer-than, not silently absent"
else
    assert_fail "[SPEC-2] a kept-because-fresh worktree must emit skip with the age reason" \
        "line: ${_new_line:-<worktree never examined>}"
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
# #1634 reason assertion — see the SPEC-2 note above. Asserted BEFORE the
# positive flip below, which deletes the untracked file the dirty guard fires on.
_dirty_line="$(_scan_line "$WT_DIRTY" 14)"
if grep -qF $'\tskip\t' <<< "$_dirty_line" && grep -qF "uncommitted" <<< "$_dirty_line"; then
    assert_pass "[SPEC-3] the dirty worktree is reported as skip:uncommitted, not silently absent"
else
    assert_fail "[SPEC-3] a kept-because-dirty worktree must emit skip with the uncommitted reason" \
        "line: ${_dirty_line:-<worktree never examined>}"
fi
# Positive-flip: remove the untracked file so the worktree becomes clean; re-backdate
# because rm touches the parent directory. The now-clean old worktree must appear —
# proving the dirty check above was the only exclusion mechanism.
rm -f "$WT_DIRTY/uncommitted.txt"
_backdate "$WT_DIRTY" 30
if _scan_has "$WT_DIRTY" 14; then
    assert_pass "[SPEC-3] positive flip: once clean, worktree appears — dirty check was the barrier"
else
    assert_fail "[SPEC-3] a now-clean, old worktree must be reclaimable" \
        "scan: $(_scan 14)"
fi

# ── SPEC-4: the active run is kept ──────────────────────────────────────────
WT_ACTIVE="$(_mk active-run zbuild/issue-4-active 0)"
_backdate "$WT_ACTIVE" 30
_out_active="$(cd "$R" && ZBUILD_RUN_ID=active-run _cleanup_scan_worktrees 14)"
_active_line="$(grep -F "$(_canon "$WT_ACTIVE")" <<< "$_out_active" || true)"
if ! grep -qF $'\tprune\t' <<< "$_active_line"; then
    assert_pass "[SPEC-4] the active run's worktree is kept (resume needs it)"
else
    assert_fail "[SPEC-4] must never reclaim the active run's worktree" "scan: $_out_active"
fi
# #1634 reason assertion — see the SPEC-2 note above.
if grep -qF $'\tskip\t' <<< "$_active_line" && grep -qF "active run" <<< "$_active_line"; then
    assert_pass "[SPEC-4] the active run's worktree is reported as skip:active-run"
else
    assert_fail "[SPEC-4] the active run must emit skip naming it as the reason" \
        "line: ${_active_line:-<worktree never examined>}"
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

# ── SPEC-3 (change): applier defence-in-depth — refuses dirty worktree ───────
# The scanner already excludes dirty worktrees; this verifies the applier has
# its own pre-check so a hand-crafted plan or race cannot force-remove work.
# At merge-base _cleanup_apply_worktree_plan used --force with no pre-check;
# this assertion FAILS there and passes after the hardening. (change-behavior)
WT_APPLIER_DIRTY="$(_mk applier-dirty zbuild/issue-30-applier-dirty 0)"
printf 'uncommitted\n' > "$WT_APPLIER_DIRTY/uncommitted.txt"
_backdate "$WT_APPLIER_DIRTY" 30
(cd "$R" && _cleanup_apply_worktree_plan "$WT_APPLIER_DIRTY") >/dev/null 2>&1
if [[ -d "$WT_APPLIER_DIRTY" ]]; then
    assert_pass "[SPEC-3] applier refuses worktree with uncommitted work (defence-in-depth)"
else
    assert_fail "[SPEC-3] applier must not force-remove a worktree with uncommitted work" \
        "worktree removed despite uncommitted files"
fi

# ── SPEC-10: override layout with run_id='worktree' must not delete the root ──
# When run_id='worktree' the path is $ZBUILD_WORKTREE_ROOT/worktree, which matches
# */worktree. The old suffix check would rmdir $ZBUILD_WORKTREE_ROOT once the
# worktree was removed — silently deleting the operator's configured root.
# SPEC-9 used run_id='ovr-run' so the suffix never matched and the bug survived.
OVR2="$TEST_TEMP_DIR/ovr2"
mkdir -p "$OVR2"
git -C "$R" worktree add -q "$OVR2/worktree" -b zbuild/issue-10-ovr2-wt 2>/dev/null
git -C "$OVR2/worktree" push -q -u origin zbuild/issue-10-ovr2-wt 2>/dev/null
_backdate "$OVR2/worktree" 30
# OVR2 sits OUTSIDE the run root, so the protection here comes from the path
# comparison (dirname($OVR2) != run root) — not from ZBUILD_WORKTREE_ROOT being
# set. SPEC-11 below covers the case where that comparison alone is not enough.
(cd "$R" && ZBUILD_WORKTREE_ROOT="$OVR2" _cleanup_apply_worktree_plan "$OVR2/worktree") >/dev/null 2>&1
if [[ ! -d "$OVR2/worktree" && -d "$OVR2" ]]; then
    assert_pass "[SPEC-10] run_id=worktree in override layout: worktree gone, configured root survives"
else
    assert_fail "[SPEC-10] run_id='worktree' must not cause the configured root to be rmdir'd" \
        "worktree_gone=$([[ ! -d "$OVR2/worktree" ]] && echo yes || echo no) root_exists=$([[ -d "$OVR2" ]] && echo yes || echo NO)"
fi

# ── SPEC-11: an override root NESTED under the run root must still survive ───
# The natural operator choice `ZBUILD_WORKTREE_ROOT=$ZBUILD_RUN_ROOT/runs/wt`
# defeats every path-SHAPE test: the parent is the configured root AND its
# grandparent is the run root, so "grandparent == run_root" says co-located and
# rmdir's the operator's directory. Only knowing the configured root — rather
# than inferring the layout — distinguishes them.
OVR3="$RUNS/wt-overrides"
mkdir -p "$OVR3"
git -C "$R" worktree add -q "$OVR3/some-run" -b zbuild/issue-11-nested 2>/dev/null
git -C "$OVR3/some-run" push -q -u origin zbuild/issue-11-nested 2>/dev/null
_backdate "$OVR3/some-run" 30
(cd "$R" && ZBUILD_WORKTREE_ROOT="$OVR3" _cleanup_apply_worktree_plan "$OVR3/some-run") >/dev/null 2>&1
if [[ ! -d "$OVR3/some-run" && -d "$OVR3" ]]; then
    assert_pass "[SPEC-11] override root nested under the run root survives reclamation"
else
    assert_fail "[SPEC-11] a configured worktree root inside the run root must never be rmdir'd" \
        "worktree_gone=$([[ ! -d "$OVR3/some-run" ]] && echo yes || echo no) root_exists=$([[ -d "$OVR3" ]] && echo yes || echo NO)"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
