#!/usr/bin/env bash
# Tests: issue #1618 — claude-code-review outcome summary accuracy.
# Verifies that ci-review-outcome.sh correctly computes the status string
# for all comment-shape scenarios (inline-only, top-level-only, verdict markers,
# API failures, and combined counts).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "claude-code-review-outcome — issue #1618 outcome accuracy"

# Source the helper under test.
# shellcheck source=../../scripts/lib/ci-review-outcome.sh
source "$REPO_ROOT/scripts/lib/ci-review-outcome.sh"

# ─── Shared env that compute_review_status reads ────────────────────────────
export GITHUB_REPOSITORY="owner/repo"
export PR="42"
export REVIEW_OUTCOME="success"
export RUN_URL="https://github.com/owner/repo/actions/runs/1"
export RUNNER_TEMP="/tmp"

# ─── T1 / SPEC-1: top-level findings → NOT "no findings" ───────────────────
# When Claude posts findings exclusively via gh pr comment (top-level issue
# comments), n_inline == 0 but n_top > 0.  The old baseline reported
# "no findings" because it only counted inline comments.
_gh_inline_count() { echo "0"; }
_gh_top_count()    { echo "3"; }
_gh_verdict()      { echo ""; }
result="$(compute_review_status "abc1234567890")"
if /usr/bin/grep -q "no findings" <<< "$result"; then
    assert_fail "[SPEC-1] top-level findings must not produce 'no findings' status" "got: $result"
else
    assert_pass "[SPEC-1] top-level findings must not produce 'no findings' status"
fi
assert_contains "[SPEC-1] status includes comment count when top-level findings exist" "$result" "3 comment"

# ─── T2 / SPEC-2: verdict:findings marker → summary says "findings posted" ─
# When the reviewer emits <!-- verdict: findings --> in its comment, the
# summary must say "findings posted" regardless of raw comment counts.
_gh_inline_count() { echo "0"; }
_gh_top_count()    { echo "0"; }
_gh_verdict()      { echo "<!-- verdict: findings -->"; }
result="$(compute_review_status "def0000000000")"
assert_contains "[SPEC-2] verdict:findings → status contains 'findings posted'" "$result" "findings posted"
if /usr/bin/grep -q "no findings" <<< "$result"; then
    assert_fail "[SPEC-2] verdict:findings must not produce 'no findings' status" "got: $result"
else
    assert_pass "[SPEC-2] verdict:findings must not produce 'no findings' status"
fi

# ─── T3 / SPEC-3: both API calls fail → diagnostic, not fabricated count ───
# When both gh api calls return '?' the old baseline emitted
# "? inline comment(s) posted above" — a fabricated and misleading count.
# The new helper must emit "outcome unknown" instead.
_gh_inline_count() { echo "?"; }
_gh_top_count()    { echo "?"; }
_gh_verdict()      { echo ""; }
result="$(compute_review_status "ghi1111111111")"
assert_contains "[SPEC-3] API failure → status contains 'outcome unknown'" "$result" "outcome unknown"
if /usr/bin/grep -q "no findings" <<< "$result"; then
    assert_fail "[SPEC-3] API failure must not produce 'no findings' status" "got: $result"
else
    assert_pass "[SPEC-3] API failure must not produce 'no findings' status"
fi

# ─── T4 / SPEC-4: verdict:clean → "no findings" is valid ──────────────────
# When the reviewer explicitly signals clean, a "no findings" outcome is
# correct and should be reported.
_gh_inline_count() { echo "0"; }
_gh_top_count()    { echo "0"; }
_gh_verdict()      { echo "<!-- verdict: clean -->"; }
result="$(compute_review_status "jkl2222222222")"
assert_contains "[SPEC-4] verdict:clean → status contains 'no findings'" "$result" "no findings"

# ─── T5 / SPEC-5: combined count used in fallback path ────────────────────
# When no verdict marker is present but both inline and top-level counts are
# non-zero, the status must report the COMBINED count (n_inline + n_top),
# not just the inline count.
_gh_inline_count() { echo "2"; }
_gh_top_count()    { echo "3"; }
_gh_verdict()      { echo ""; }
result="$(compute_review_status "mno3333333333")"
assert_contains "[SPEC-5] combined count (2+3=5) appears in status" "$result" "5 comment"
if /usr/bin/grep -q "no findings" <<< "$result"; then
    assert_fail "[SPEC-5] combined count > 0 must not produce 'no findings' status" "got: $result"
else
    assert_pass "[SPEC-5] combined count > 0 must not produce 'no findings' status"
fi

print_test_results
