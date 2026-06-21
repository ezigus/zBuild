#!/usr/bin/env bash
# Integration: zbuild cleanup --stashes / --tmpdirs / --restore-stash CLI (#594)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "zbuild cleanup stash/tmpdir CLI e2e (#594)"
setup_test_env "cleanup-stashes-e2e"

ZBUILD="$REPO_ROOT/scripts/zbuild"

REPO="$TEST_TEMP_DIR/repo"
git init -q -b main "$REPO"

# Seed: one old applycheck stash, one new applycheck stash, one unrelated.
_make_stash() {
    local message="$1" age_seconds="${2:-0}"
    echo "x $RANDOM" > "f-$RANDOM.txt"
    git add -A
    if [[ "$age_seconds" -gt 0 ]]; then
        local ts=$(( $(date +%s) - age_seconds ))
        GIT_COMMITTER_DATE="@$ts +0000" GIT_AUTHOR_DATE="@$ts +0000" \
            git stash push -q -u -m "$message"
    else
        git stash push -q -u -m "$message"
    fi
}

_outer_cwd="$(pwd)"   # capture caller CWD so SPEC-2 asserts it is unchanged
(
    cd "$REPO"
    git config user.email "t@example.com"
    git config user.name "t"
    git config commit.gpgsign false
    echo seed > seed.txt
    git add seed.txt
    git commit -q -m seed
    _make_stash "zb-applycheck-fwd-30693" 7200
    _make_stash "zb-applycheck-fwd-39827" 60
    _make_stash "manual-leftover" 7200
)
if [[ "$(pwd)" == "$_outer_cwd" ]]; then
    assert_pass "[SPEC-2] init subshell preserves outer CWD (bare-cd in init block does not pollute top-level shell)"
else
    assert_fail "[SPEC-2] init subshell preserves outer CWD" "cwd=$(pwd) expected=$_outer_cwd"
fi

# State dir (empty: nothing in-progress)
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
mkdir -p "$ZBUILD_STATE_DIR"

# Mock gh so cleanup --branches path doesn't try real GitHub.
mock_binary "gh" 'exit 0'

# ── TC-1: bare cleanup → dry-run banner, no stashes dropped ─────────────────
# Restore CWD on exit via the harness cleanup hook — the master EXIT trap calls
# _test_cleanup_hook before removing the tracked TEST_TEMP_DIR. A competing
# `trap … EXIT` here would clobber _test_harness_cleanup and leak the temp dir.
_test_cleanup_hook() { cd "$REPO_ROOT" 2>/dev/null || true; }
cd "$REPO"
count_before="$(git stash list | wc -l | tr -d ' ')"
out="$("$ZBUILD" cleanup 2>&1)"; rc=$?
assert_exit_code "bare cleanup exit 0" 0 "$rc"
assert_contains "bare cleanup says dry-run" "$out" "dry-run"
count_after="$(git stash list | wc -l | tr -d ' ')"
if [[ "$count_before" == "$count_after" ]]; then
    assert_pass "bare cleanup drops nothing"
else
    assert_fail "bare cleanup drops nothing" "before=$count_before after=$count_after"
fi

# ── TC-2: --dry-run --stashes lists old prefix stash ────────────────────────
out="$("$ZBUILD" cleanup --dry-run --stashes --age-hours 1 2>&1)"; rc=$?
assert_exit_code "dry-run stashes exit 0" 0 "$rc"
assert_contains "lists zb-applycheck-fwd-30693" "$out" "30693"

# ── TC-3: --force --stashes --age-hours 0 prunes all matching prefix stashes
out="$("$ZBUILD" cleanup --force --stashes --age-hours 0 2>&1)"; rc=$?
assert_exit_code "force stashes exit 0" 0 "$rc"
# manual-leftover survives
sl="$(git stash list)"
case "$sl" in
    *manual-leftover*) assert_pass "non-prefix stash survives --force" ;;
    *) assert_fail "non-prefix stash survives --force" "$sl" ;;
esac
# applycheck stashes gone
case "$sl" in
    *zb-applycheck*) assert_fail "applycheck stashes pruned" "$sl" ;;
    *) assert_pass "applycheck stashes pruned" ;;
esac

# ── TC-4: --restore-stash on a fresh applycheck stash pops it ───────────────
_make_stash "zb-applycheck-fwd-77777" 0
# Restore the stash at index 0 (newest)
out="$("$ZBUILD" cleanup --restore-stash 0 --apply 2>&1)"; rc=$?
assert_exit_code "restore-stash exit 0" 0 "$rc"
sl="$(git stash list)"
case "$sl" in
    *zb-applycheck-fwd-77777*) assert_fail "restore-stash drops the stash after pop" "$sl" ;;
    *) assert_pass "restore-stash pops the applycheck stash" ;;
esac

# ── TC-5: --restore-stash refuses non-applycheck stash ──────────────────────
sl="$(git stash list)"
mw_idx=0
while IFS= read -r ln; do
    case "$ln" in
        *manual-leftover*) break ;;
    esac
    mw_idx=$(( mw_idx + 1 ))
done <<<"$sl"
rc=0
out="$("$ZBUILD" cleanup --restore-stash "$mw_idx" --apply 2>&1)" || rc=$?
if [[ "$rc" -ne 0 ]]; then
    assert_pass "restore-stash refuses non-applycheck (nonzero exit)"
else
    assert_fail "restore-stash refuses non-applycheck" "rc=$rc, out=$out"
fi

print_test_results
