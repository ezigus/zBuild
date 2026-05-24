#!/usr/bin/env bash
# sw-snapshot-guard-test.sh — Validates HEAD guard logic for the snapshot step
# Tests that git update-ref + symbolic-ref + reset --mixed guard operates correctly
# in simulated GHA detached/wrong-branch environments.
set -euo pipefail

PASS=0
FAIL=0
ERRORS=""

# ─── Helpers ──────────────────────────────────────────────────────────────────

pass() { PASS=$((PASS + 1)); printf "  \033[32m✓ %s\033[0m\n" "$1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS="${ERRORS}\n  ✗ $1"; printf "  \033[31m✗ %s\033[0m\n" "$1"; }

assert_eq() {
    local actual="$1" expected="$2" msg="$3"
    if [[ "$actual" == "$expected" ]]; then
        pass "$msg"
    else
        fail "$msg (expected '$expected', got '$actual')"
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" msg="$3"
    if printf '%s\n' "$haystack" | grep -Fq "$needle" 2>/dev/null; then
        pass "$msg"
    else
        fail "$msg (expected to contain '$needle', got: $haystack)"
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" msg="$3"
    if printf '%s\n' "$haystack" | grep -Fq "$needle" 2>/dev/null; then
        fail "$msg (should NOT contain '$needle')"
    else
        pass "$msg"
    fi
}

# ─── Temp dir + cleanup ───────────────────────────────────────────────────────

TMPROOT=""
cleanup() {
    if [[ -n "$TMPROOT" && -d "$TMPROOT" ]]; then
        rm -rf "$TMPROOT"
    fi
}
trap cleanup EXIT

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/sw-snapshot-guard-test.XXXXXX")"

# ─── Guard function ───────────────────────────────────────────────────────────
# Runs the guard logic under test inside a subshell cd'd to a repo dir.
# Usage: run_guard <repo_dir> <BRANCH>
# Output streams directly to the caller; exit code is preserved.
run_guard() {
    local repo_dir="$1"
    local branch="$2"
    (
        cd "$repo_dir"
        set +e
        if [[ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" != "$branch" ]]; then
            git fetch --no-tags origin "$branch" 2>/dev/null || true
            if git rev-parse --verify "refs/remotes/origin/$branch" >/dev/null 2>&1; then
                BASE_REF="refs/remotes/origin/$branch"
            else
                BASE_REF="refs/remotes/origin/main"
            fi
            git update-ref "refs/heads/$branch" "$BASE_REF" \
              || { echo "::error::Snapshot guard: update-ref failed for $branch — aborting"; exit 1; }
            git symbolic-ref HEAD "refs/heads/$branch" \
              || { echo "::error::Snapshot guard: symbolic-ref failed for $branch — aborting"; exit 1; }
            git reset --mixed HEAD 2>/dev/null \
              || { echo "::error::Snapshot guard: reset --mixed failed for $branch — aborting"; exit 1; }
            if [[ "$(git rev-parse --abbrev-ref HEAD)" != "$branch" ]]; then
                echo "::error::Snapshot guard failed to move HEAD to $branch — aborting"
                exit 1
            fi
        fi
        exit 0
    )
}

# ─── Repo factory ─────────────────────────────────────────────────────────────
# Creates a bare "remote" repo and a clone with:
#   - main branch: one commit ("initial")
#   - feature/wip branch (on remote): one additional commit ("wip work")
# The working repo is left on the branch specified by $1 ("main" or "feature/wip").
# Sets global REMOTE_DIR and WORK_DIR.
REMOTE_DIR=""
WORK_DIR=""
_MAKE_REPOS_COUNT=0
make_repos() {
    local initial_branch="${1:-main}"
    _MAKE_REPOS_COUNT=$((_MAKE_REPOS_COUNT + 1))

    REMOTE_DIR="$(mktemp -d "$TMPROOT/remote-${_MAKE_REPOS_COUNT}.XXXXXX")"
    WORK_DIR="$(mktemp -d "$TMPROOT/work-${_MAKE_REPOS_COUNT}.XXXXXX")"
    # Remove the pre-created dirs so git init / clone can create them cleanly
    rm -rf "$REMOTE_DIR" "$WORK_DIR"

    # Create the bare "origin" repo
    git init --bare "$REMOTE_DIR" -q
    git -C "$REMOTE_DIR" symbolic-ref HEAD refs/heads/main

    # Bootstrap with an initial commit via a temp clone
    local seed_dir
    seed_dir="$(mktemp -d "$TMPROOT/seed-${_MAKE_REPOS_COUNT}.XXXXXX")"
    rm -rf "$seed_dir"
    git clone -q "$REMOTE_DIR" "$seed_dir" 2>/dev/null
    git -C "$seed_dir" config user.email "test@test.com"
    git -C "$seed_dir" config user.name "Test"
    echo "initial" > "$seed_dir/readme.txt"
    git -C "$seed_dir" add readme.txt
    git -C "$seed_dir" commit -q -m "initial"
    git -C "$seed_dir" push -q origin main

    # Create feature/wip branch on remote (from seed).
    # readme.txt is modified on feature/wip so tracked-file content diverges from
    # main — this reproduces the real failure mode where git checkout -B would refuse.
    git -C "$seed_dir" checkout -q -b "feature/wip"
    echo "wip-version" > "$seed_dir/readme.txt"
    echo "wip-file" > "$seed_dir/wip.txt"
    git -C "$seed_dir" add readme.txt wip.txt
    git -C "$seed_dir" commit -q -m "wip work"
    git -C "$seed_dir" push -q origin "feature/wip"

    rm -rf "$seed_dir"

    # Clone the working repo
    git clone -q "$REMOTE_DIR" "$WORK_DIR" 2>/dev/null
    git -C "$WORK_DIR" config user.email "test@test.com"
    git -C "$WORK_DIR" config user.name "Test"

    # Fetch all remote refs
    git -C "$WORK_DIR" fetch -q --all 2>/dev/null

    # Move to the requested starting branch
    if [[ "$initial_branch" == "main" ]]; then
        git -C "$WORK_DIR" checkout -q main
    else
        git -C "$WORK_DIR" checkout -q -b "$initial_branch" "origin/$initial_branch" 2>/dev/null || \
            git -C "$WORK_DIR" checkout -q "$initial_branch"
    fi
}

# ─── Suite header ─────────────────────────────────────────────────────────────
echo ""
echo "═══ Snapshot HEAD Guard Tests ═══"

# ═══════════════════════════════════════════════════════════════════════════════
# Scenario 1: HEAD already on correct branch — guard is a no-op
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "  ── Scenario 1: HEAD already on correct branch ──"

make_repos "feature/wip"
BRANCH="feature/wip"

head_before="$(git -C "$WORK_DIR" rev-parse HEAD)"
run_guard "$WORK_DIR" "$BRANCH"
head_after="$(git -C "$WORK_DIR" rev-parse HEAD)"
current_branch="$(git -C "$WORK_DIR" rev-parse --abbrev-ref HEAD)"

assert_eq "$current_branch" "$BRANCH" "scenario 1: branch unchanged after no-op"
assert_eq "$head_before" "$head_after" "scenario 1: HEAD commit unchanged after no-op"

# ═══════════════════════════════════════════════════════════════════════════════
# Scenario 2: HEAD on wrong branch, WIP branch exists on remote
#             → HEAD moved to WIP branch; index reset confirmed
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "  ── Scenario 2: HEAD on wrong branch, WIP branch on remote ──"

make_repos "main"
BRANCH="feature/wip"

# Confirm we start on main
start_branch="$(git -C "$WORK_DIR" rev-parse --abbrev-ref HEAD)"
assert_eq "$start_branch" "main" "scenario 2: starts on main"

run_guard "$WORK_DIR" "$BRANCH"

after_branch="$(git -C "$WORK_DIR" rev-parse --abbrev-ref HEAD)"
assert_eq "$after_branch" "$BRANCH" "scenario 2: HEAD moved to feature/wip"

# Verify HEAD now points to the same commit as origin/feature/wip
head_sha="$(git -C "$WORK_DIR" rev-parse HEAD)"
origin_sha="$(git -C "$WORK_DIR" rev-parse "refs/remotes/origin/$BRANCH")"
assert_eq "$head_sha" "$origin_sha" "scenario 2: HEAD SHA matches origin/feature/wip"

# Index reset: add a file and check only that file is staged
echo "artifact content" > "$WORK_DIR/artifact.md"
(cd "$WORK_DIR" && git add -f artifact.md)
staged="$(git -C "$WORK_DIR" diff --cached --name-only)"
assert_eq "$staged" "artifact.md" "scenario 2: only artifact.md staged after add"
# wip.txt should not appear as a modification in the index (it is already tracked at HEAD)
assert_not_contains "$staged" "wip.txt" "scenario 2: wip.txt not in staged changes"

# ═══════════════════════════════════════════════════════════════════════════════
# Scenario 3: HEAD on wrong branch, WIP branch does NOT exist on remote
#             → falls back to main, HEAD moved
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "  ── Scenario 3: WIP branch absent from remote, falls back to main ──"

make_repos "main"
BRANCH="feature/nonexistent"

start_branch="$(git -C "$WORK_DIR" rev-parse --abbrev-ref HEAD)"
assert_eq "$start_branch" "main" "scenario 3: starts on main"

run_guard "$WORK_DIR" "$BRANCH"

after_branch="$(git -C "$WORK_DIR" rev-parse --abbrev-ref HEAD)"
assert_eq "$after_branch" "$BRANCH" "scenario 3: HEAD symbolic-ref set to feature/nonexistent"

# HEAD SHA must match origin/main (the fallback)
head_sha="$(git -C "$WORK_DIR" rev-parse HEAD)"
main_sha="$(git -C "$WORK_DIR" rev-parse "refs/remotes/origin/main")"
assert_eq "$head_sha" "$main_sha" "scenario 3: HEAD commit matches origin/main (fallback)"

# ═══════════════════════════════════════════════════════════════════════════════
# Scenario 4: After guard succeeds, commit parent is origin/BRANCH (not old wrong branch commit)
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "  ── Scenario 4: Post-guard commit parent is origin/BRANCH ──"

make_repos "main"
BRANCH="feature/wip"

# Record the main HEAD before the guard (the "wrong branch" commit)
wrong_commit="$(git -C "$WORK_DIR" rev-parse HEAD)"

run_guard "$WORK_DIR" "$BRANCH"

# Stage and commit a new file
echo "snapshot output" > "$WORK_DIR/artifact.md"
(cd "$WORK_DIR" && git add -f artifact.md)
git -C "$WORK_DIR" commit -q -m "snapshot artifact"

# The new commit's parent should be origin/feature/wip, not the main commit
new_commit_parent="$(git -C "$WORK_DIR" rev-parse HEAD^)"
origin_wip_sha="$(git -C "$WORK_DIR" rev-parse "refs/remotes/origin/$BRANCH")"

assert_eq "$new_commit_parent" "$origin_wip_sha" "scenario 4: commit parent is origin/feature/wip"
# Confirm it is NOT the old main/wrong-branch commit
if [[ "$new_commit_parent" != "$wrong_commit" ]]; then
    pass "scenario 4: commit parent is NOT the original wrong-branch commit"
else
    fail "scenario 4: commit parent should not be the wrong-branch commit"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Scenario 5: Index reset — only artifact.md staged, no feature-branch extras
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "  ── Scenario 5: Index reset — diff --cached shows only artifact.md ──"

make_repos "main"
BRANCH="feature/wip"

run_guard "$WORK_DIR" "$BRANCH"

# Create and stage artifact only
echo "snapshot data" > "$WORK_DIR/artifact.md"
(cd "$WORK_DIR" && git add -f artifact.md)

staged_files="$(git -C "$WORK_DIR" diff --cached --name-only)"

assert_eq "$staged_files" "artifact.md" "scenario 5: diff --cached shows only artifact.md"
assert_not_contains "$staged_files" "readme.txt" "scenario 5: readme.txt not staged"
assert_not_contains "$staged_files" "wip.txt" "scenario 5: wip.txt not staged"

# ═══════════════════════════════════════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "═══════════════════════════════════════════"
TOTAL=$((PASS + FAIL))
if [[ "$FAIL" -eq 0 ]]; then
    printf "\033[32m  ALL %d TESTS PASSED\033[0m\n" "$TOTAL"
else
    printf "\033[31m  %d/%d PASSED, %d FAILED\033[0m\n" "$PASS" "$TOTAL" "$FAIL"
    echo ""
    echo "  Failures:"
    printf "%b\n" "$ERRORS"
fi
echo "═══════════════════════════════════════════"
echo ""

exit "$FAIL"
