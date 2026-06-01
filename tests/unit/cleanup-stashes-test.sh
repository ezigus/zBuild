#!/usr/bin/env bash
# Tests: scripts/lib/cleanup.sh — stash + tmpdir scanners + restore (#594)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "cleanup stash + tmpdir scanners (#594)"
setup_test_env "cleanup-stashes"

# shellcheck source=../../scripts/lib/cleanup.sh
source "$REPO_ROOT/scripts/lib/cleanup.sh"

# ── Build a real git repo and seed stashes ──────────────────────────────────
REPO="$TEST_TEMP_DIR/repo"
git init -q -b main "$REPO"
cd "$REPO"
git config user.email "t@example.com"
git config user.name "t"
git config commit.gpgsign false
echo seed > seed.txt
git add seed.txt
git commit -q -m seed

# Helper: create a stash with given message + back-date its commit timestamp.
_make_stash() {
    local message="$1" age_seconds="${2:-0}"
    local fname; fname="f-$RANDOM.txt"
    echo "dirty $message" > "$fname"
    git add "$fname"
    if [[ "$age_seconds" -gt 0 ]]; then
        local ts=$(( $(date +%s) - age_seconds ))
        GIT_COMMITTER_DATE="@$ts +0000" GIT_AUTHOR_DATE="@$ts +0000" \
            git stash push -q -u -m "$message"
    else
        git stash push -q -u -m "$message"
    fi
}

# Seed: 2 zb-applycheck-* stashes (one old, one new) + 1 unrelated stash.
_make_stash "zb-applycheck-fwd-30693" 7200   # 2 hours old
_make_stash "zb-applycheck-fwd-39827" 60     # 1 min old
_make_stash "my-feature-wip"          7200   # 2 hours old, NOT prefixed

# State dir with an in-progress pipeline matching run_id 99999
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
mkdir -p "$ZBUILD_STATE_DIR"
jq -n '{schema_version:1, run_id:"99999", issue:1, status:"in_progress", stage_statuses:{}, current_iteration:0, self_heal_count:{}, updated_at:"2026-06-01T00:00:00.000Z"}' \
    > "$ZBUILD_STATE_DIR/pipeline-state.json"

# ── TC-1: prefix match — non-prefix stash NEVER scanned ─────────────────────
plan="$(_cleanup_scan_stashes false 1 || true)"
if grep -q "my-feature-wip" <<<"$plan"; then
    assert_fail "non-zb-applycheck stash skipped" "got: $plan"
else
    assert_pass "non-zb-applycheck stash skipped"
fi

# ── TC-2: age cutoff — recent stash (60s) skipped at age_hours=1 ────────────
if grep -E '(prune.*39827|39827.*prune)' <<<"$plan" >/dev/null 2>&1; then
    assert_fail "recent stash skipped at age_hours=1" "got: $plan"
else
    assert_pass "recent stash skipped at age_hours=1"
fi

# ── TC-3: old stash is a prune candidate ────────────────────────────────────
if grep -E 'prune' <<<"$plan" | grep -q "30693"; then
    assert_pass "old zb-applycheck stash marked prune"
else
    assert_fail "old zb-applycheck stash marked prune" "got: $plan"
fi

# ── TC-4: active-run skip — add a stash whose run_id matches in-progress ────
_make_stash "zb-applycheck-fwd-99999" 7200
plan2="$(_cleanup_scan_stashes false 1 || true)"
if grep -E 'prune' <<<"$plan2" | grep -q "99999"; then
    assert_fail "active-run stash skipped (fail-CLOSED)" "got: $plan2"
else
    assert_pass "active-run stash skipped (fail-CLOSED)"
fi

# ── TC-5: predicate _cleanup_is_active_run ──────────────────────────────────
if _cleanup_is_active_run "99999"; then
    assert_pass "_cleanup_is_active_run detects in_progress match"
else
    assert_fail "_cleanup_is_active_run detects in_progress match"
fi
if _cleanup_is_active_run "00000"; then
    assert_fail "_cleanup_is_active_run rejects unknown run_id"
else
    assert_pass "_cleanup_is_active_run rejects unknown run_id"
fi

# ── TC-6: dry-run apply does NOT drop ───────────────────────────────────────
count_before="$(git stash list | wc -l | tr -d ' ')"
_cleanup_apply_stash_plan "$plan" true >/dev/null 2>&1 || true
count_after="$(git stash list | wc -l | tr -d ' ')"
if [[ "$count_before" == "$count_after" ]]; then
    assert_pass "dry-run does NOT drop stashes"
else
    assert_fail "dry-run does NOT drop stashes" "before=$count_before after=$count_after"
fi

# ── TC-7: apply mode drops only prune entries ───────────────────────────────
# Re-scan now that the in_progress state file exists (so the 99999 stash is
# scanned as skip, but old 30693 is still pruned).
plan_apply="$(_cleanup_scan_stashes false 1 || true)"
_cleanup_apply_stash_plan "$plan_apply" false >/dev/null 2>&1 || true
# my-feature-wip MUST survive. (case is SIGPIPE-safe under pipefail.)
sl="$(git stash list)"
case "$sl" in
    *my-feature-wip*) assert_pass "apply preserves non-prefix stash" ;;
    *) assert_fail "apply preserves non-prefix stash" "$sl" ;;
esac
# The 30693 stash should be gone
sl="$(git stash list)"
case "$sl" in
    *30693*) assert_fail "apply dropped 30693" "$sl" ;;
    *) assert_pass "apply dropped old zb-applycheck stash" ;;
esac

# ── TC-8: _cleanup_restore_stash refuses non-prefix stash ───────────────────
# Locate my-feature-wip index
mw_idx="$(git stash list | grep -n "my-feature-wip" | head -1 | cut -d: -f1)"
mw_idx=$(( mw_idx - 1 ))
if _cleanup_restore_stash "$mw_idx" 2>/dev/null; then
    assert_fail "restore refuses non-zb-applycheck stash"
else
    assert_pass "restore refuses non-zb-applycheck stash"
fi

# ── TC-9: _cleanup_restore_stash pops a zb-applycheck stash ─────────────────
# Make a fresh applycheck stash (age irrelevant for restore)
_make_stash "zb-applycheck-fwd-77777" 0
ac_idx="$(git stash list | grep -n "zb-applycheck-fwd-77777" | head -1 | cut -d: -f1)"
ac_idx=$(( ac_idx - 1 ))
if _cleanup_restore_stash "$ac_idx" >/dev/null 2>&1; then
    assert_pass "restore pops zb-applycheck stash"
else
    assert_fail "restore pops zb-applycheck stash"
fi

# ── TC-10: tmpdir scanner picks up matching old dirs ────────────────────────
FAKE_TMP="$TEST_TEMP_DIR/faketmp"
mkdir -p "$FAKE_TMP"
mkdir -p "$FAKE_TMP/zb-applycheck-fwd-12345" "$FAKE_TMP/zbuild-test-stage.ABCDE" "$FAKE_TMP/pipeline-runner.XYZ" "$FAKE_TMP/unrelated-dir"
# Age all by 2 hours
if touch -d "@$(( $(date +%s) - 7200 ))" "$FAKE_TMP/zb-applycheck-fwd-12345" 2>/dev/null; then :; else
    ts="$(date -r $(( $(date +%s) - 7200 )) "+%Y%m%d%H%M.%S")"
    touch -t "$ts" "$FAKE_TMP/zb-applycheck-fwd-12345" "$FAKE_TMP/zbuild-test-stage.ABCDE" "$FAKE_TMP/pipeline-runner.XYZ" "$FAKE_TMP/unrelated-dir"
fi
TMPDIR="$FAKE_TMP" plan_tmp="$(TMPDIR="$FAKE_TMP" _cleanup_scan_zbuild_tmpdirs 1 || true)"
if grep -q "zb-applycheck-fwd-12345" <<<"$plan_tmp"; then
    assert_pass "tmpdir scanner finds zb-applycheck-* dir"
else
    assert_fail "tmpdir scanner finds zb-applycheck-* dir" "got: $plan_tmp"
fi
if grep -q "zbuild-test-stage.ABCDE" <<<"$plan_tmp"; then
    assert_pass "tmpdir scanner finds zbuild-test-stage.* dir"
else
    assert_fail "tmpdir scanner finds zbuild-test-stage.* dir" "got: $plan_tmp"
fi
if grep -q "pipeline-runner.XYZ" <<<"$plan_tmp"; then
    assert_pass "tmpdir scanner finds pipeline-runner.* dir"
else
    assert_fail "tmpdir scanner finds pipeline-runner.* dir" "got: $plan_tmp"
fi
if grep -q "unrelated-dir" <<<"$plan_tmp"; then
    assert_fail "tmpdir scanner ignores unrelated dirs" "got: $plan_tmp"
else
    assert_pass "tmpdir scanner ignores unrelated dirs"
fi

print_test_results
