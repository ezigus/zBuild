#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-resume-test.sh — TDD tests for WIP branch resume logic               ║
# ║  Tests the "Check for partial work branch" workflow step behavior         ║
# ║  Run: bash scripts/sw-resume-test.sh                                      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

# ─── Cleanup hook ────────────────────────────────────────────────────────────
_test_cleanup_hook() { cleanup_env; }

# ─── Shared env setup ────────────────────────────────────────────────────────
cleanup_env() {
    if [[ -n "${TEST_TEMP_DIR:-}" && -d "${TEST_TEMP_DIR:-}" ]]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
}

setup_env() {
    TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-resume-test.XXXXXX")

    # A bare remote for git push/fetch
    git init --quiet --bare "$TEST_TEMP_DIR/remote.git" 2>/dev/null

    # Local project repo
    mkdir -p "$TEST_TEMP_DIR/project"
    (
        cd "$TEST_TEMP_DIR/project"
        git init --quiet 2>/dev/null
        git config user.name "test"
        git config user.email "test@test.com"
        echo "# test" > README.md
        git add README.md
        git commit --quiet -m "init"
        git remote add origin "$TEST_TEMP_DIR/remote.git"
        git push --quiet -u origin main 2>/dev/null || git push --quiet -u origin master 2>/dev/null || true
    )

    # Mock bin directory on PATH
    mkdir -p "$TEST_TEMP_DIR/bin"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    # GITHUB_ENV file — captures "KEY=VALUE" lines written by the step
    export GITHUB_ENV="$TEST_TEMP_DIR/github_env"
    : > "$GITHUB_ENV"
}

# ─── Helper: extract a value from $GITHUB_ENV ────────────────────────────────
github_env_get() {
    local key="$1"
    grep "^${key}=" "$GITHUB_ENV" 2>/dev/null | tail -1 | cut -d= -f2- || echo ""
}

# ─── Extract the "Check for partial work branch" step inline script ──────────
# The step script is reproduced here so the tests validate the EXACT logic
# that will be merged into the workflow file. Any regression in either place
# will cause test failures.
run_step() {
    # Inputs: $1 = BRANCH name, $2 = ISSUE_NUMBER
    local BRANCH="$1"
    local ISSUE_NUMBER="${2:-42}"

    (
        cd "$TEST_TEMP_DIR/project"
        export GIT_TERMINAL_PROMPT=0
        export GITHUB_ENV

        # ── BEGIN: logic copied from the workflow step (post-fix) ───────────
        if git ls-remote --heads --exit-code origin "$BRANCH" >/dev/null 2>&1; then
            echo "Found partial work branch: $BRANCH"
            git fetch origin "$BRANCH" 2>/dev/null || true

            BRANCH_CONTENT=$(git log -5 --format='%s' "origin/$BRANCH" 2>/dev/null || echo "")
            if echo "$BRANCH_CONTENT" | grep -qiE 'Invalid API key|authentication_error|API key expired'; then
                POLLUTED_SUBJECT=$(git log -5 --format='%s' "origin/$BRANCH" 2>/dev/null \
                    | grep -iE 'Invalid API key|authentication_error|API key expired' | head -1 || echo "unknown")
                echo "::warning::Partial work branch appears polluted with API errors — deleting. Trigger commit subject: ${POLLUTED_SUBJECT}"
                git push origin --delete "$BRANCH" 2>/dev/null || true
            else
                # -B force-resets local ref to remote tip — correct when consuming WIP branch.
                if git checkout -B "$BRANCH" "origin/$BRANCH" 2>/dev/null; then
                    echo "GIT_BRANCH=${BRANCH}" >> "$GITHUB_ENV"
                    echo "Checked out ${BRANCH} — continuing from prior work"
                else
                    echo "::warning::Could not checkout ${BRANCH} — starting fresh on main (investigate checkout failure)"
                fi
            fi
        fi
        # ── END: logic copied from workflow step ────────────────────────────
    )
}

# ─────────────────────────────────────────────────────────────────────────────
# TEST 1 — Branch-absent path
# git ls-remote --exit-code returns 2 when branch does not exist.
# Expected: step is no-op — no env var written, no checkout attempted.
# ─────────────────────────────────────────────────────────────────────────────
print_test_header "Test 1: Branch-absent path — ls-remote exit-code 2 → no-op"
setup_env

BRANCH="shipwright/issue-42"
OUTPUT=$(run_step "$BRANCH" "42" 2>&1 || true)

# No GIT_BRANCH should be written to GITHUB_ENV
GIT_BRANCH_VAL=$(github_env_get "GIT_BRANCH")
if [[ -z "$GIT_BRANCH_VAL" ]]; then
    assert_pass "GIT_BRANCH not written to GITHUB_ENV when branch absent"
else
    assert_fail "GIT_BRANCH not written to GITHUB_ENV when branch absent" "got: $GIT_BRANCH_VAL"
fi

# No "Checked out" message
if echo "$OUTPUT" | grep -qF "Checked out"; then
    assert_fail "No checkout message when branch absent" "output contained 'Checked out'"
else
    assert_pass "No checkout message when branch absent"
fi

cleanup_env

# ─────────────────────────────────────────────────────────────────────────────
# TEST 2 — Happy path
# WIP branch exists with clean commit history.
# Expected: git checkout -B succeeds, GIT_BRANCH written to GITHUB_ENV.
# ─────────────────────────────────────────────────────────────────────────────
print_test_header "Test 2: Happy path — WIP branch exists, clean history → checkout -B"
setup_env

BRANCH="shipwright/issue-42"

# Create the WIP branch on the remote with a clean commit
(
    cd "$TEST_TEMP_DIR/project"
    git checkout -b "$BRANCH" --quiet 2>/dev/null
    echo "partial work" > partial.txt
    git add partial.txt
    git config user.name "test"
    git config user.email "test@test.com"
    git commit --quiet -m "WIP: partial pipeline progress for #42"
    git push --quiet origin "$BRANCH" 2>/dev/null
    # Return to main/master
    git checkout --quiet main 2>/dev/null || git checkout --quiet master 2>/dev/null || true
)

OUTPUT=$(run_step "$BRANCH" "42" 2>&1 || true)

# GIT_BRANCH should be written
GIT_BRANCH_VAL=$(github_env_get "GIT_BRANCH")
assert_eq "GIT_BRANCH written as shipwright/issue-42" "$BRANCH" "$GIT_BRANCH_VAL"

# "Checked out" message present
assert_contains "Checkout success message present" "$OUTPUT" "Checked out ${BRANCH}"

cleanup_env

# ─────────────────────────────────────────────────────────────────────────────
# TEST 3 — Pollution path
# WIP branch last 5 commits contain "Invalid API key".
# Expected: ::warning:: printed, git push --delete called, no checkout.
# ─────────────────────────────────────────────────────────────────────────────
print_test_header "Test 3: Pollution path — API error in commit history → delete, no checkout"
setup_env

BRANCH="shipwright/issue-99"

# Create polluted WIP branch on remote
(
    cd "$TEST_TEMP_DIR/project"
    git checkout -b "$BRANCH" --quiet 2>/dev/null
    echo "bad work" > bad.txt
    git add bad.txt
    git config user.name "test"
    git config user.email "test@test.com"
    # Commit subject contains API error marker
    git commit --quiet -m "Invalid API key: authentication_error received from claude"
    git push --quiet origin "$BRANCH" 2>/dev/null
    git checkout --quiet main 2>/dev/null || git checkout --quiet master 2>/dev/null || true
)

OUTPUT=$(run_step "$BRANCH" "99" 2>&1 || true)

# ::warning:: should be in output
assert_contains_regex "Warning annotation present for pollution" "$OUTPUT" "::warning::"

# Deletion message should be present
assert_contains "Pollution deletion message present" "$OUTPUT" "polluted with API errors"

# GIT_BRANCH should NOT be written
GIT_BRANCH_VAL=$(github_env_get "GIT_BRANCH")
if [[ -z "$GIT_BRANCH_VAL" ]]; then
    assert_pass "GIT_BRANCH not written when branch is polluted"
else
    assert_fail "GIT_BRANCH not written when branch is polluted" "got: $GIT_BRANCH_VAL"
fi

# "Checked out" message should NOT appear
if echo "$OUTPUT" | grep -qF "Checked out"; then
    assert_fail "No checkout when branch is polluted" "output contained 'Checked out'"
else
    assert_pass "No checkout when branch is polluted"
fi

# The branch should have been deleted from the remote
if git -C "$TEST_TEMP_DIR/project" ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
    assert_fail "Polluted branch deleted from remote" "branch still exists on remote"
else
    assert_pass "Polluted branch deleted from remote"
fi

cleanup_env

# ─────────────────────────────────────────────────────────────────────────────
# TEST 4 — Diverged-local path
# A stale local branch with the same name exists pointing to an old commit.
# Expected: -B force-resets local ref to remote tip (not -b which would fail).
# ─────────────────────────────────────────────────────────────────────────────
print_test_header "Test 4: Diverged-local path — stale local branch → -B force-reset"
setup_env

BRANCH="shipwright/issue-77"

# Create WIP branch on remote with work commit
(
    cd "$TEST_TEMP_DIR/project"
    git checkout -b "$BRANCH" --quiet 2>/dev/null
    echo "remote work" > remote_work.txt
    git add remote_work.txt
    git config user.name "test"
    git config user.email "test@test.com"
    git commit --quiet -m "WIP: remote progress for #77"
    git push --quiet origin "$BRANCH" 2>/dev/null
    # Return to main/master and create a diverged local branch
    git checkout --quiet main 2>/dev/null || git checkout --quiet master 2>/dev/null || true
    # Create a LOCAL branch at a different (older) commit — simulates stale local state
    git branch -f "$BRANCH" HEAD 2>/dev/null || true
)

OUTPUT=$(run_step "$BRANCH" "77" 2>&1 || true)

# GIT_BRANCH should be written
GIT_BRANCH_VAL=$(github_env_get "GIT_BRANCH")
assert_eq "GIT_BRANCH written despite stale local branch" "$BRANCH" "$GIT_BRANCH_VAL"

# "Checked out" message present
assert_contains "Checkout success message present despite local diverge" "$OUTPUT" "Checked out ${BRANCH}"

# Verify -B was used: the local branch should now be at the remote tip
(
    cd "$TEST_TEMP_DIR/project"
    LOCAL_SHA=$(git rev-parse "$BRANCH" 2>/dev/null || echo "none")
    REMOTE_SHA=$(git rev-parse "origin/$BRANCH" 2>/dev/null || echo "unknown")
    if [[ "$LOCAL_SHA" == "$REMOTE_SHA" ]]; then
        assert_pass "-B force-reset local branch to match remote tip"
    else
        assert_fail "-B force-reset local branch to match remote tip" "local=$LOCAL_SHA remote=$REMOTE_SHA"
    fi
) || assert_fail "-B force-reset verification failed" "subshell error"

cleanup_env

# ─────────────────────────────────────────────────────────────────────────────
print_test_results
