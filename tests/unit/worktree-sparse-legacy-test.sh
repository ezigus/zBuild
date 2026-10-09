#!/usr/bin/env bash
# tests/unit/worktree-sparse-legacy-test.sh
# Per-worktree sparse-checkout excludes legacy-DoNotUse/ from issue worktrees (#1802).
#
# [#1802/SPEC-1]: zbuild_worktree_acquire produces a worktree with none of
#                 legacy-DoNotUse/ — no subdirectory excepted — and returns 0
# [#1802/SPEC-2]: zbuild_worktree_enter in all modes does the same
# [#1802/SPEC-3]: the exclusion survives a git checkout inside the worktree
# [#1802/SPEC-4]: zbuild_worktree_acquire on the reuse path re-applies the pattern
# [#1802/SPEC-5]: extensions.worktreeConfig leaves the main checkout non-sparse
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "per-worktree sparse-checkout excludes legacy-DoNotUse/ (#1802)"
setup_test_env "worktree-sparse-legacy"

# shellcheck source=../../scripts/lib/worktree.sh
source "$REPO_ROOT/scripts/lib/worktree.sh"
set +e

# ── fixture: a real git repo with files under legacy-DoNotUse/ ─────────────
# _KEPT names the subdirectory an earlier rule kept in every worktree; it is now
# left out like the rest (ADR-059 §2).
_KEPT=migrated
_R="$TEST_TEMP_DIR/repo"
mkdir -p "$_R/legacy-DoNotUse/$_KEPT" "$_R/src"
printf 'frozen\n'   > "$_R/legacy-DoNotUse/frozen.sh"
printf 'tombstone\n' > "$_R/legacy-DoNotUse/$_KEPT/tombstone.md"
printf 'work\n'     > "$_R/src/work.sh"
git -C "$_R" init -q -b main 2>/dev/null
git -C "$_R" config user.email t@t
git -C "$_R" config user.name t
git -C "$_R" config commit.gpgsign false
git -C "$_R" add -A
git -C "$_R" commit -qm init 2>/dev/null

# Create extra branches used by adopt_local (SPEC-2) and branch-switch (SPEC-3).
git -C "$_R" branch second 2>/dev/null
git -C "$_R" branch third  2>/dev/null

# Redirect all worktrees into the sandbox; $TEST_TEMP_DIR is outside $_R.
export ZBUILD_WORKTREE_ROOT="$TEST_TEMP_DIR/wt"

# ── helper: assert nothing under legacy-DoNotUse/ is checked out ────────────
_assert_sparse() {
    local tag="$1" wt="$2"
    if [[ -f "$wt/legacy-DoNotUse/frozen.sh" ]]; then
        assert_fail "[$tag] legacy-DoNotUse/frozen.sh must not be checked out in the worktree" \
            "found: $wt/legacy-DoNotUse/frozen.sh"
    else
        assert_pass "[$tag] legacy-DoNotUse/frozen.sh is absent from the worktree"
    fi
    if [[ -e "$wt/legacy-DoNotUse/$_KEPT/tombstone.md" ]]; then
        assert_fail "[$tag] no subdirectory of legacy-DoNotUse/ is excepted" \
            "found: $wt/legacy-DoNotUse/$_KEPT/tombstone.md"
    else
        assert_pass "[$tag] legacy-DoNotUse/$_KEPT/ is left out too (no exception)"
    fi
}

# ── SPEC-1: zbuild_worktree_acquire (new worktree) ───────────────────────────
_WT_ACQ="$(zbuild_worktree_acquire spec1 "$_R" 2>/dev/null)"; _rc=$?
if [[ "$_rc" -eq 0 && -d "$_WT_ACQ" ]]; then
    assert_pass "[#1802/SPEC-1] zbuild_worktree_acquire returns 0 and creates the worktree"
else
    assert_fail "[#1802/SPEC-1] zbuild_worktree_acquire must return 0 and create the worktree" \
        "rc=$_rc path=${_WT_ACQ:-<empty>}"
fi
_assert_sparse "#1802/SPEC-1" "$_WT_ACQ"

# ── SPEC-2 (create mode): zbuild_worktree_enter ──────────────────────────────
_WT_CREATE="$(cd "$_R" && zbuild_worktree_enter spec2-create zbuild/spec2-create create 2>/dev/null)"
_rc=$?
# Primary [#1802/SPEC-2] assertion checks the sparse outcome — not just exit code.
# On old code zbuild_worktree_enter succeeds (rc=0) but leaves legacy-DoNotUse/frozen.sh in
# the worktree; this assertion therefore fails before the fix and passes after it.
if [[ "$_rc" -ne 0 || ! -d "$_WT_CREATE" ]]; then
    assert_fail "[#1802/SPEC-2] zbuild_worktree_enter create must return 0 and produce a worktree" \
        "rc=$_rc path=${_WT_CREATE:-<empty>}"
elif [[ -f "$_WT_CREATE/legacy-DoNotUse/frozen.sh" ]]; then
    assert_fail "[#1802/SPEC-2] zbuild_worktree_enter create must not check out legacy-DoNotUse/ in the worktree" \
        "found: $_WT_CREATE/legacy-DoNotUse/frozen.sh"
else
    assert_pass "[#1802/SPEC-2] zbuild_worktree_enter create: legacy-DoNotUse/frozen.sh absent from worktree"
fi
_assert_sparse "#1802/SPEC-2 create" "$_WT_CREATE"

# ── SPEC-2 (adopt_local mode): ───────────────────────────────────────────────
_WT_LOCAL="$(cd "$_R" && zbuild_worktree_enter spec2-local second adopt_local 2>/dev/null)"
_rc=$?
if [[ "$_rc" -eq 0 && -d "$_WT_LOCAL" ]]; then
    assert_pass "[#1802/SPEC-2 adopt_local] zbuild_worktree_enter adopt_local returns 0"
else
    assert_fail "[#1802/SPEC-2 adopt_local] zbuild_worktree_enter adopt_local must return 0" \
        "rc=$_rc path=${_WT_LOCAL:-<empty>}"
fi
_assert_sparse "#1802/SPEC-2 adopt_local" "$_WT_LOCAL"

# ── SPEC-2 (adopt_remote mode): ──────────────────────────────────────────────
# Use a second local clone as the "remote" so the test stays hermetic.
_REMOTE="$TEST_TEMP_DIR/remote"
git clone --quiet "$_R" "$_REMOTE" 2>/dev/null
git -C "$_R" remote add origin "$_REMOTE" 2>/dev/null || true
git -C "$_R" fetch --quiet origin 2>/dev/null

_WT_REMOTE="$(cd "$_R" && zbuild_worktree_enter spec2-remote zbuild/spec2-remote adopt_remote origin/main 2>/dev/null)"
_rc=$?
if [[ "$_rc" -eq 0 && -d "$_WT_REMOTE" ]]; then
    assert_pass "[#1802/SPEC-2 adopt_remote] zbuild_worktree_enter adopt_remote returns 0"
else
    assert_fail "[#1802/SPEC-2 adopt_remote] zbuild_worktree_enter adopt_remote must return 0" \
        "rc=$_rc path=${_WT_REMOTE:-<empty>}"
fi
_assert_sparse "#1802/SPEC-2 adopt_remote" "$_WT_REMOTE"

# ── SPEC-3: sparse exclusion survives a git checkout inside the worktree ─────
# Create a fresh worktree then switch its branch; the sparse rules must persist.
_WT_SWITCH="$(cd "$_R" && zbuild_worktree_enter spec3 zbuild/spec3 create 2>/dev/null)"
_rc=$?
if [[ "$_rc" -eq 0 && -d "$_WT_SWITCH" ]]; then
    assert_pass "[#1802/SPEC-3] worktree for branch-switch test created"
    git -C "$_WT_SWITCH" checkout -q third 2>/dev/null; _rcc=$?
    if [[ "$_rcc" -eq 0 ]]; then
        assert_pass "[#1802/SPEC-3] git checkout to another branch inside the worktree succeeded"
    else
        assert_fail "[#1802/SPEC-3] git checkout inside the worktree failed" "rc=$_rcc"
    fi
    if [[ -f "$_WT_SWITCH/legacy-DoNotUse/frozen.sh" ]]; then
        assert_fail "[#1802/SPEC-3] legacy-DoNotUse/frozen.sh must remain absent after branch switch" \
            "found after checkout: $_WT_SWITCH/legacy-DoNotUse/frozen.sh"
    else
        assert_pass "[#1802/SPEC-3] legacy-DoNotUse/frozen.sh absent after branch switch (sparse persists)"
    fi
else
    assert_fail "[#1802/SPEC-3] SETUP: could not create worktree for branch-switch test" \
        "rc=$_rc"
fi

# ── SPEC-4: reuse (resume) path re-applies the sparse pattern ────────────────
# Create a worktree directly via git (no zbuild, so no sparse-checkout applied),
# then call zbuild_worktree_acquire for the same path — the reuse branch must
# apply the sparse pattern even though the tree already exists.
_WT4_PATH="$TEST_TEMP_DIR/wt/spec4-resume"
mkdir -p "$(dirname "$_WT4_PATH")"
git -C "$_R" worktree add --detach "$_WT4_PATH" 2>/dev/null; _rc=$?
if [[ "$_rc" -eq 0 ]]; then
    assert_pass "[#1802/SPEC-4] manually created worktree (no sparse) setup succeeded"
    if [[ -f "$_WT4_PATH/legacy-DoNotUse/frozen.sh" ]]; then
        assert_pass "[#1802/SPEC-4] pre-condition: legacy-DoNotUse/frozen.sh present before acquire"
    else
        assert_fail "[#1802/SPEC-4] SETUP: legacy-DoNotUse/frozen.sh must be present before acquire" \
            "(git worktree add without sparse should include all files)"
    fi
    _WT4_OUT="$(zbuild_worktree_acquire spec4-resume "$_R" 2>/dev/null)"; _rcr=$?
    if [[ "$_rcr" -eq 0 ]]; then
        assert_pass "[#1802/SPEC-4] zbuild_worktree_acquire reuse path returns 0"
    else
        assert_fail "[#1802/SPEC-4] zbuild_worktree_acquire reuse path must return 0" "rc=$_rcr"
    fi
    if [[ -f "$_WT4_PATH/legacy-DoNotUse/frozen.sh" ]]; then
        assert_fail "[#1802/SPEC-4] reuse path must apply sparse: legacy-DoNotUse/frozen.sh must be absent" \
            "found after acquire: $_WT4_PATH/legacy-DoNotUse/frozen.sh"
    else
        assert_pass "[#1802/SPEC-4] reuse path applied sparse: legacy-DoNotUse/frozen.sh absent"
    fi
    if [[ -e "$_WT4_PATH/legacy-DoNotUse/$_KEPT/tombstone.md" ]]; then
        assert_fail "[#1802/SPEC-4] reuse path must leave out all of legacy-DoNotUse/, migrated/ included" \
            "found after acquire: $_WT4_PATH/legacy-DoNotUse/$_KEPT/tombstone.md"
    else
        assert_pass "[#1802/SPEC-4] reuse path left out legacy-DoNotUse/$_KEPT/ too"
    fi
else
    assert_fail "[#1802/SPEC-4] SETUP: git worktree add for resume fixture failed" "rc=$_rc"
fi

# ── SPEC-5: main checkout is left non-sparse ─────────────────────────────────
# extensions.worktreeConfig must isolate per-worktree sparse config so the main
# checkout's core.sparseCheckout is absent or false.
_sparse="$(git -C "$_R" config --local core.sparseCheckout 2>/dev/null || printf '')"
if [[ -z "$_sparse" || "$_sparse" == "false" ]]; then
    assert_pass "[#1802/SPEC-5] main checkout core.sparseCheckout is absent or false"
else
    assert_fail "[#1802/SPEC-5] main checkout must not have core.sparseCheckout set to true" \
        "value: $_sparse"
fi
# The isolation mechanism requires extensions.worktreeConfig=true in the main repo.
_wtcfg="$(git -C "$_R" config --local extensions.worktreeConfig 2>/dev/null || printf '')"
if [[ "$_wtcfg" == "true" ]]; then
    assert_pass "[#1802/SPEC-5] extensions.worktreeConfig=true (per-worktree isolation active)"
else
    assert_fail "[#1802/SPEC-5] extensions.worktreeConfig must be true in the main checkout" \
        "value: ${_wtcfg:-<not set>}"
fi
# Working tree of the main checkout must still contain legacy-DoNotUse/ (it is not sparse).
if [[ -f "$_R/legacy-DoNotUse/frozen.sh" ]]; then
    assert_pass "[#1802/SPEC-5] main checkout working tree still has legacy-DoNotUse/frozen.sh (not sparse)"
else
    assert_fail "[#1802/SPEC-5] main checkout working tree must not be sparse" \
        "legacy-DoNotUse/frozen.sh absent from main checkout"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
