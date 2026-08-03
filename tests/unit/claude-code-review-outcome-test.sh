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
setup_test_env "claude-code-review-outcome"

# Source the helper under test.
# shellcheck source=../../scripts/lib/ci-review-outcome.sh
source "$REPO_ROOT/scripts/lib/ci-review-outcome.sh"

# ─── Shared env that compute_review_status reads ────────────────────────────
export GITHUB_REPOSITORY="owner/repo"
export PR="42"
export REVIEW_OUTCOME="success"
export RUN_URL="https://github.com/owner/repo/actions/runs/1"
# Own directory, not /tmp: _reviewer_ran() keys on the presence of the action's
# execution log here, so a stray /tmp/claude-execution-output.json from any other
# process would silently decide these cases. Default state is "the reviewer ran";
# SPEC-7 below points RUNNER_TEMP at an empty dir to exercise the opposite.
export RUNNER_TEMP="$TEST_TEMP_DIR/runner"
mkdir -p "$RUNNER_TEMP"
printf '{}' > "$RUNNER_TEMP/claude-execution-output.json"

# ─── Wiring reachability: workflow must source the helper ───────────────────
# Reverting .github/workflows/claude-code-review.yml to merge-base removes the
# source line; this assertion flips fail → proves the wiring is load-bearing.
workflow_yml="$REPO_ROOT/.github/workflows/claude-code-review.yml"
wf_content="$(cat "$workflow_yml")"
assert_contains "[SPEC-1] workflow run: block sources ci-review-outcome.sh" \
    "$wf_content" "ci-review-outcome.sh"

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

# ─── T6 / SPEC-6: the FILTERS run for real, against real-shaped payloads ────
# T1-T5 above stub _gh_inline_count/_gh_top_count/_gh_verdict, which is right for
# exercising compute_review_status's branching — but it means the jq that decides
# WHOSE comments count never executes. That is precisely how this file shipped
# filtering on `github-actions[bot]` (the summary poster) instead of the reviewer:
# every SPEC passed against constants while the real lookups returned zero on
# every real PR. These cases drive filter_top_count/filter_verdict directly, so
# the login is covered by an executed line. See #1694.
#
# Payload shape is copied from a real `gh api repos/:o/:r/issues/:n/comments`
# response: the reviewer posts as claude[bot]; the outcome summary this very
# file writes posts as github-actions[bot].
# Two reviewer comments and one summary, so the expected count (2) differs from
# what the wrong login would yield (1) — a 1-vs-1 fixture cannot tell them apart.
_payload_findings_in_comment='[
  {"user":{"login":"claude[bot]"},"body":"## Review\n\nFirst pass."},
  {"user":{"login":"github-actions[bot]"},"body":"✅ **Claude review of `abc1234`: no findings.**"},
  {"user":{"login":"claude[bot]"},"body":"## Review\n\nOne real finding.\n\n<!-- verdict: findings -->"}
]'
_payload_clean='[
  {"user":{"login":"claude[bot]"},"body":"Nothing significant.\n\n<!-- verdict: clean -->"},
  {"user":{"login":"github-actions[bot]"},"body":"✅ **Claude review of `abc1234`: no findings.**"}
]'

assert_eq "[SPEC-6] filter_top_count counts the REVIEWER's comments, not the summary bot's" \
    "2" "$(filter_top_count <<< "$_payload_findings_in_comment")"
assert_eq "[SPEC-6] filter_verdict reads the marker from the reviewer's comment" \
    "<!-- verdict: findings -->" "$(filter_verdict <<< "$_payload_findings_in_comment")"
assert_eq "[SPEC-6] filter_verdict reads a clean marker" \
    "<!-- verdict: clean -->" "$(filter_verdict <<< "$_payload_clean")"
# The regression in one line: had the filter kept github-actions[bot], the count
# would be 1 (the summary) and the verdict empty — a findings review read as clean.
assert_eq "[SPEC-6] outcome-summary comments are excluded by construction" \
    "0" "$(filter_top_count <<< '[{"user":{"login":"github-actions[bot]"},"body":"✅ no findings."}]')"

# ─── T7 / SPEC-7: reviewer never ran → not reported as clean ────────────────
# The action skips outright when the workflow file differs from the default
# branch's copy — every PR editing this workflow — yet the STEP still reports
# outcome=success. PR #1690 did exactly this to itself: a green "no findings"
# for a review that never executed.
export RUNNER_TEMP="$TEST_TEMP_DIR/noexec"
mkdir -p "$RUNNER_TEMP"     # deliberately no claude-execution-output.json
_gh_inline_count() { echo "0"; }
_gh_top_count()    { echo "0"; }
_gh_verdict()      { echo ""; }
result="$(compute_review_status "pqr4444444444")"
if /usr/bin/grep -q "no findings" <<< "$result"; then
    assert_fail "[SPEC-7] a skipped review must not be reported as 'no findings'" "got: $result"
else
    assert_pass "[SPEC-7] a skipped review must not be reported as 'no findings'"
fi
assert_contains "[SPEC-7] a skipped review says so explicitly" "$result" "did not run"

# ─── T8 / SPEC-8: a PARTIAL API failure is not a clean result ───────────────
# Requiring BOTH counts to be '?' let _safe_add coerce the failed side to 0 and
# report a confident "no findings" built on one successful query.
printf '{}' > "$RUNNER_TEMP/claude-execution-output.json"   # reviewer DID run
_gh_inline_count() { echo "?"; }
_gh_top_count()    { echo "0"; }
_gh_verdict()      { echo ""; }
result="$(compute_review_status "stu5555555555")"
assert_contains "[SPEC-8] one failed lookup → 'outcome unknown'" "$result" "outcome unknown"
if /usr/bin/grep -q "no findings" <<< "$result"; then
    assert_fail "[SPEC-8] a partial API failure must not produce 'no findings'" "got: $result"
else
    assert_pass "[SPEC-8] a partial API failure must not produce 'no findings'"
fi

print_test_results
