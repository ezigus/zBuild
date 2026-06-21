#!/usr/bin/env bash
# Integration: zbuild cleanup CLI end-to-end (#570)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "zbuild cleanup CLI e2e (#570)"
setup_test_env "cleanup-cli-e2e"

ZBUILD="$REPO_ROOT/scripts/zbuild"

# ── Build a real git repo with upstream so push works ───────────────────────
UPSTREAM="$TEST_TEMP_DIR/upstream.git"
REPO="$TEST_TEMP_DIR/repo"
git init -q --bare -b main "$UPSTREAM"
git init -q -b main "$REPO"
_outer_cwd="$(pwd)"   # capture caller CWD so SPEC-1 asserts it is unchanged
(
cd "$REPO"
git config user.email "t@example.com"
git config user.name "t"
git config commit.gpgsign false
echo seed > seed.txt
git add seed.txt
git commit -q -m seed
git remote add origin "$UPSTREAM"
git push -q origin main

# Clean pushed branch with merged PR
git checkout -q -b zbuild/issue-300
git push -q -u origin zbuild/issue-300

# Clean pushed branch WITHOUT merged PR
git checkout -q main
git checkout -q -b zbuild/issue-301
git push -q -u origin zbuild/issue-301

# Unpushed branch (would-be-deleted candidate but safety stops it)
git checkout -q main
git checkout -q -b zbuild/issue-302
echo local > local-only.txt
git add local-only.txt
git commit -q -m local

# Back to main (safe current branch)
git checkout -q main
)
if [[ "$(pwd)" == "$_outer_cwd" ]]; then
    assert_pass "[SPEC-1] init subshell preserves outer CWD (bare-cd in init block does not pollute top-level shell)"
else
    assert_fail "[SPEC-1] init subshell preserves outer CWD" "cwd=$(pwd) expected=$_outer_cwd"
fi

# State dir
STATE_DIR="$TEST_TEMP_DIR/state"
mkdir -p "$STATE_DIR"
jq -n '{schema_version:1, run_id:"old-complete", issue:1, status:"complete", stage_statuses:{}, current_iteration:0, self_heal_count:{}, updated_at:"2026-01-01T00:00:00.000Z"}' \
    > "$STATE_DIR/pipeline-state-old.json"
# Age it by 30 days
if touch -d "@$(( $(date +%s) - 2592000 ))" "$STATE_DIR/pipeline-state-old.json" 2>/dev/null; then :; else
    ts="$(date -r $(( $(date +%s) - 2592000 )) "+%Y%m%d%H%M.%S")"
    touch -t "$ts" "$STATE_DIR/pipeline-state-old.json"
fi

# Recent state file (should survive --age-days 14)
jq -n '{schema_version:1, run_id:"recent", issue:1, status:"complete", stage_statuses:{}, current_iteration:0, self_heal_count:{}, updated_at:"2026-05-30T00:00:00.000Z"}' \
    > "$STATE_DIR/pipeline-state-recent.json"

# Shim gh: branch zbuild/issue-300 reports merged PR; others don't
mock_binary "gh" '
if [[ "$1" == "pr" && "$2" == "list" ]]; then
    for arg in "$@"; do
        if [[ "$arg" == "zbuild/issue-300" ]]; then echo 1; exit 0; fi
    done
    echo 0
    exit 0
fi
exit 0'

export ZBUILD_STATE_DIR="$STATE_DIR"

# ── TC-1: bare invocation → dry-run, exit 0, no deletes ─────────────────────
# Restore CWD on exit via the harness cleanup hook — the master EXIT trap calls
# _test_cleanup_hook before removing the tracked TEST_TEMP_DIR. A competing
# `trap … EXIT` here would clobber _test_harness_cleanup and leak the temp dir.
_test_cleanup_hook() { cd "$REPO_ROOT" 2>/dev/null || true; }
cd "$REPO"
out="$("$ZBUILD" cleanup 2>&1)"; rc=$?
assert_exit_code "bare cleanup exit 0" 0 "$rc"
assert_contains "bare cleanup says dry-run" "$out" "dry-run"
if [[ -f "$STATE_DIR/pipeline-state-old.json" ]]; then
    assert_pass "bare cleanup deletes nothing (state)"
else
    assert_fail "bare cleanup deletes nothing (state)"
fi
if git show-ref --verify --quiet refs/heads/zbuild/issue-300; then
    assert_pass "bare cleanup deletes nothing (branches)"
else
    assert_fail "bare cleanup deletes nothing (branches)"
fi

# ── TC-2: --dry-run lists merged-PR branch as candidate ─────────────────────
out="$("$ZBUILD" cleanup --dry-run --branches 2>&1)"; rc=$?
assert_exit_code "dry-run exit 0" 0 "$rc"
assert_contains "dry-run lists zbuild/issue-300" "$out" "zbuild/issue-300"

# ── TC-3: --apply --branches prunes merged-PR branch only ───────────────────
out="$("$ZBUILD" cleanup --apply --branches 2>&1)"; rc=$?
assert_exit_code "apply branches exit 0" 0 "$rc"
if git show-ref --verify --quiet refs/heads/zbuild/issue-300; then
    assert_fail "merged-PR branch deleted" "still present"
else
    assert_pass "merged-PR branch deleted"
fi
# Branch without merged PR survives
if git show-ref --verify --quiet refs/heads/zbuild/issue-301; then
    assert_pass "no-merged-PR branch survives"
else
    assert_fail "no-merged-PR branch survives"
fi
# Unpushed branch survives (safety predicate)
if git show-ref --verify --quiet refs/heads/zbuild/issue-302; then
    assert_pass "unpushed branch survives"
else
    assert_fail "unpushed branch survives"
fi

# ── TC-4: --force --branches prunes no-merged-PR branch but keeps unpushed ──
out="$("$ZBUILD" cleanup --force --branches 2>&1)"; rc=$?
assert_exit_code "force branches exit 0" 0 "$rc"
if git show-ref --verify --quiet refs/heads/zbuild/issue-301; then
    assert_fail "force prunes no-PR clean branch" "still present"
else
    assert_pass "force prunes no-PR clean branch"
fi
if git show-ref --verify --quiet refs/heads/zbuild/issue-302; then
    assert_pass "force still keeps unpushed branch (fail-CLOSED)"
else
    assert_fail "force still keeps unpushed branch (fail-CLOSED)"
fi

# ── TC-5: --apply --state-dirs --age-days 14 prunes old, keeps recent ───────
out="$("$ZBUILD" cleanup --apply --state-dirs --age-days 14 2>&1)"; rc=$?
assert_exit_code "apply state-dirs exit 0" 0 "$rc"
if [[ ! -f "$STATE_DIR/pipeline-state-old.json" ]]; then
    assert_pass "old state file pruned"
else
    assert_fail "old state file pruned"
fi
if [[ -f "$STATE_DIR/pipeline-state-recent.json" ]]; then
    assert_pass "recent state file survives"
else
    assert_fail "recent state file survives"
fi

# ── TC-6: cannot delete current branch even with --force ────────────────────
git checkout -q -b zbuild/issue-current
git push -q -u origin zbuild/issue-current 2>/dev/null || true
# Shim gh to claim it's merged
mock_binary "gh" '
if [[ "$1" == "pr" && "$2" == "list" ]]; then echo 1; exit 0; fi
exit 0'
out="$("$ZBUILD" cleanup --apply --force --branches 2>&1)"; rc=$?
if git show-ref --verify --quiet refs/heads/zbuild/issue-current; then
    assert_pass "current branch NEVER deleted (fail-CLOSED)"
else
    assert_fail "current branch NEVER deleted"
fi

print_test_results
