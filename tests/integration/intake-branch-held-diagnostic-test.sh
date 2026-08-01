#!/usr/bin/env bash
# tests/integration/intake-branch-held-diagnostic-test.sh
# SPEC-4: _intake_checkout_branch emits a clear diagnostic (naming the holding
# worktree path and the reclaim command) when the target branch is already
# checked out in another worktree. (change-behavior — fails at merge-base where
# only a generic reason=checkout_failed is emitted.)
set -uo pipefail
# Deliberately NOT `set -e`: assert_fail returns non-zero, which aborts under -e
# before print_test_results, making a failing test appear to pass.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

for _dep in scripts/lib/helpers.sh scripts/lib/test-helpers.sh; do
    if [[ ! -f "$REPO_ROOT/$_dep" ]]; then
        printf 'intake-branch-held-diagnostic-test: required dependency missing: %s\n' \
            "$REPO_ROOT/$_dep" >&2
        exit 2
    fi
done
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/worktree.sh
source "$REPO_ROOT/scripts/lib/worktree.sh"

print_test_header "intake: branch-held-by-worktree diagnostic (#1658)"
setup_test_env "intake-branch-held-diagnostic"

# ── Build a git repo with an upstream and two worktrees ─────────────────────
REPO="$TEST_TEMP_DIR/repo"
WT_HOLDER="$TEST_TEMP_DIR/wt-holder"

git init -q -b main "$REPO" 2>/dev/null
(
    cd "$REPO"
    git config user.email "t@t"
    git config user.name "t"
    git config commit.gpgsign false
    printf 'seed\n' > seed.txt
    git add seed.txt
    git commit -q -m seed

    # Create the branch that will be held by the first worktree
    git checkout -q -b zbuild/issue-1658-held
    printf 'work\n' > work.txt
    git add work.txt
    git commit -q -m work
    git checkout -q main

    # Add a worktree on the target branch — this "holds" it
    ZBUILD_WORKTREE_ROOT="$TEST_TEMP_DIR" zbuild_worktree_enter "wt-holder" "zbuild/issue-1658-held" "adopt_local" >/dev/null 2>&1
)

# Canonicalise the holder path so the grep below survives macOS symlinks.
_canon_holder="$(cd "$WT_HOLDER" && pwd -P)"

# Source the intake branch-ops functions (emit_event stub is in helpers.sh).
# shellcheck disable=SC1091
source "$REPO_ROOT/plugins/agent/intake/lib/branch-names.sh" 2>/dev/null || true
# shellcheck disable=SC1091
source "$REPO_ROOT/plugins/agent/intake/lib/branch-ops.sh"

# ── Invoke _intake_checkout_branch from the main repo ───────────────────────
cd "$REPO"
_diag_out="$(_intake_checkout_branch "zbuild/issue-1658-held" 2>&1)"; _diag_rc=$?

# ── SPEC-4 assertions ────────────────────────────────────────────────────────
# (a) checkout must fail (rc != 0)
if [[ "$_diag_rc" -ne 0 ]]; then
    assert_pass "[SPEC-4] _intake_checkout_branch returns non-zero when branch is held"
else
    assert_fail "[SPEC-4] checkout must fail when branch is held by another worktree" \
        "rc=$_diag_rc but expected non-zero"
fi

# (b) output must name the holding path
if grep -qF "$_canon_holder" <<< "$_diag_out"; then
    assert_pass "[SPEC-4] diagnostic names the holding worktree path"
else
    # Accept the non-canonicalised path as well (e.g. on Linux where /tmp is not a symlink)
    if grep -qF "$WT_HOLDER" <<< "$_diag_out"; then
        assert_pass "[SPEC-4] diagnostic names the holding worktree path (non-canonical)"
    else
        assert_fail "[SPEC-4] diagnostic must name the holding worktree path" \
            "expected '$_canon_holder' in output: $_diag_out"
    fi
fi

# (c) output must mention zbuild cleanup --worktrees
if grep -qF "zbuild cleanup --worktrees" <<< "$_diag_out"; then
    assert_pass "[SPEC-4] diagnostic mentions the reclaim command (zbuild cleanup --worktrees)"
else
    assert_fail "[SPEC-4] diagnostic must mention zbuild cleanup --worktrees" \
        "output: $_diag_out"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
