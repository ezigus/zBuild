#!/usr/bin/env bash
# Tests: scripts/lib/cleanup.sh — safety predicates (#570)
# Each predicate is exercised in isolation against hermetic git fixtures.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "cleanup safety predicates (#570)"
setup_test_env "cleanup-predicates"

# shellcheck source=../../scripts/lib/cleanup.sh
source "$REPO_ROOT/scripts/lib/cleanup.sh"

# ── fixture: bare upstream + local clone ─────────────────────────────────────
_make_fixture_repo() {
    local upstream="$TEST_TEMP_DIR/upstream.git"
    local repo="$TEST_TEMP_DIR/work"
    git init -q --bare -b main "$upstream"
    git init -q -b main "$repo"
    (
        cd "$repo"
        git config user.email "t@example.com"
        git config user.name "t"
        git config commit.gpgsign false
        echo seed > seed.txt
        git add seed.txt
        git commit -q -m seed
        git remote add origin "$upstream"
        git push -q origin main
    )
    printf '%s\n' "$repo"
}

REPO="$(_make_fixture_repo)"
cd "$REPO"

# ── TC-1: is_current_branch true for HEAD branch ─────────────────────────────
git checkout -q -b zbuild/issue-100
if _cleanup_is_current_branch "zbuild/issue-100"; then
    assert_pass "is_current_branch true for HEAD"
else
    assert_fail "is_current_branch true for HEAD"
fi

# ── TC-2: is_current_branch false for other branch ───────────────────────────
git branch zbuild/issue-101
if _cleanup_is_current_branch "zbuild/issue-101"; then
    assert_fail "is_current_branch false for non-HEAD" "expected false"
else
    assert_pass "is_current_branch false for non-HEAD"
fi

# ── TC-3: has_uncommitted_work — clean branch (no worktree) ──────────────────
# zbuild/issue-101 has no checkout, so cannot be dirty
if _cleanup_has_uncommitted_work "zbuild/issue-101"; then
    assert_fail "has_uncommitted_work false for branch w/o worktree"
else
    assert_pass "has_uncommitted_work false for branch w/o worktree"
fi

# ── TC-4: has_uncommitted_work — unstaged change in checked-out branch ──────
git checkout -q -b zbuild/issue-102
echo dirty >> seed.txt
if _cleanup_has_uncommitted_work "zbuild/issue-102"; then
    assert_pass "has_uncommitted_work true for unstaged change"
else
    assert_fail "has_uncommitted_work true for unstaged change"
fi
git checkout -q -- seed.txt

# ── TC-5: has_uncommitted_work — staged change ──────────────────────────────
echo staged >> seed.txt
git add seed.txt
if _cleanup_has_uncommitted_work "zbuild/issue-102"; then
    assert_pass "has_uncommitted_work true for staged change"
else
    assert_fail "has_uncommitted_work true for staged change"
fi
git reset -q --hard

# ── TC-6: has_uncommitted_work — untracked file ─────────────────────────────
echo untracked > new-file.txt
if _cleanup_has_uncommitted_work "zbuild/issue-102"; then
    assert_pass "has_uncommitted_work true for untracked file"
else
    assert_fail "has_uncommitted_work true for untracked file"
fi
rm -f new-file.txt

# ── TC-7: has_unpushed_commits — no upstream ────────────────────────────────
# zbuild/issue-102 was never pushed → no upstream → unpushed (true / fail-closed)
if _cleanup_has_unpushed_commits "zbuild/issue-102"; then
    assert_pass "has_unpushed true when no upstream"
else
    assert_fail "has_unpushed true when no upstream"
fi

# ── TC-8: has_unpushed_commits — pushed, equal ──────────────────────────────
git checkout -q main
git checkout -q -b zbuild/issue-103
git push -q -u origin zbuild/issue-103
if _cleanup_has_unpushed_commits "zbuild/issue-103"; then
    assert_fail "has_unpushed false when fully pushed"
else
    assert_pass "has_unpushed false when fully pushed"
fi

# ── TC-9: has_unpushed_commits — ahead of upstream ──────────────────────────
echo more > new.txt
git add new.txt
git commit -q -m more
if _cleanup_has_unpushed_commits "zbuild/issue-103"; then
    assert_pass "has_unpushed true when ahead of upstream"
else
    assert_fail "has_unpushed true when ahead of upstream"
fi

# ── TC-10: has_merged_pr — gh shim returns merged ───────────────────────────
mock_binary "gh" '
if [[ "$1" == "pr" && "$2" == "list" ]]; then
    # Detect --head <b> argument
    for arg in "$@"; do
        if [[ "$arg" == "zbuild/issue-200" ]]; then
            echo "1"
            exit 0
        fi
    done
    echo "0"
    exit 0
fi
echo ""
exit 0'
if _cleanup_has_merged_pr "zbuild/issue-200"; then
    assert_pass "has_merged_pr true when gh returns >0"
else
    assert_fail "has_merged_pr true when gh returns >0"
fi
if _cleanup_has_merged_pr "zbuild/issue-201"; then
    assert_fail "has_merged_pr false when gh returns 0"
else
    assert_pass "has_merged_pr false when gh returns 0"
fi

# ── TC-11: has_merged_pr — gh missing → fail-closed (not merged) ────────────
rm -f "$TEST_TEMP_DIR/bin/gh"
# Provide a non-existent gh by pointing at /nonexistent via PATH stripping
PATH_SAVE="$PATH"
export PATH="$TEST_TEMP_DIR/bin"  # bin without gh
if _cleanup_has_merged_pr "zbuild/issue-200"; then
    assert_fail "has_merged_pr fail-closed when gh missing"
else
    assert_pass "has_merged_pr fail-closed when gh missing"
fi
export PATH="$PATH_SAVE"

print_test_results
