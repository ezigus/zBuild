#!/usr/bin/env bash
# Tests: scripts/deferred-tracker.sh::sanitize_excerpt, format_triage_title,
#                                    format_issue_body, extract_excerpt
#
# Behavioral coverage for ADR-020 §Markdown-injection mitigation. CRITICAL:
# - '#' must be escaped to prevent fake auto-close (Closes #123 attack)
# - '@' must be escaped to prevent notification spam (@mention attack)
# - Excerpts must be truncated to EXCERPT_MAX (200 chars)
# - Title format is locked: [deferred-tracker][automated] Candidates — <ts>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/deferred-tracker.sh
source "$REPO_ROOT/scripts/deferred-tracker.sh"

print_test_header "deferred-tracker — sanitize + format (ADR-020 / #531)"

# ─── REGRESSION LOCK: # escaped (prevents auto-close) ────────────────────────
out="$(sanitize_excerpt "needs Closes #999 later")"
assert_contains "S1: # escaped (REGRESSION LOCK auto-close)" "$out" "Closes \\#999"

# ─── REGRESSION LOCK: @ escaped (prevents mention spam) ──────────────────────
out="$(sanitize_excerpt "ping @octocat about this")"
assert_contains "S2: @ escaped (REGRESSION LOCK mention spam)" "$out" "\\@octocat"

# Truncation: 500 chars → 200 + "..." ASCII ellipsis = 203 chars
long_input="$(printf 'a%.0s' {1..500})"
out="$(sanitize_excerpt "$long_input")"
len=${#out}
if (( len <= 203 )); then
    assert_pass "S3: long input truncated to ≤203 chars (got $len)"
else
    assert_fail "S3: truncation failed; got $len chars (limit 200 + ... ellipsis)"
fi

# ─── Newlines stripped ───────────────────────────────────────────────────────
out="$(sanitize_excerpt "line1
line2")"
# Count newlines via tr → 0 means stripped successfully
nl_count="$(printf '%s' "$out" | tr -cd '\n' | wc -c | tr -d ' ')"
assert_eq "S4: newlines stripped from excerpt" "0" "$nl_count"

# ─── Title format locked ────────────────────────────────────────────────────
out="$(format_triage_title "2026-05-31 18:30 UTC")"
assert_eq "S5: title format locked" "[deferred-tracker][automated] Candidates — 2026-05-31 18:30 UTC" "$out"

# ─── format_issue_body wraps excerpts in code fences ─────────────────────────
body="$(printf '510|separate issue|need a separate issue here\n' | format_issue_body "2026-05-31" "12345" "2026-05-30")"
assert_contains "S6: body contains fenced code block" "$body" '```'
assert_contains "S7: body contains PR reference" "$body" "PR #510"
assert_contains "S8: body contains run id" "$body" "12345"
assert_contains "S9: body contains checklist marker" "$body" "- [ ]"
assert_contains "S10: body contains phrase label" "$body" "separate issue"

# ─── extract_excerpt returns enclosing sentence ──────────────────────────────
out="$(extract_excerpt "first sentence. needs a separate issue here. third sentence." "separate issue")"
assert_contains "S11: excerpt contains the phrase" "$out" "separate issue"

print_test_results
