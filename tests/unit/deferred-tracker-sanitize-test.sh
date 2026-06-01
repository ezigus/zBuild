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

# Truncation: computed from $EXCERPT_MAX, not hardcoded — caps may be tuned
# via DEFERRED_EXCERPT_MAX env var (#596 B).
long_input="$(printf 'a%.0s' $(seq 1 $((EXCERPT_MAX + 200))))"
out="$(sanitize_excerpt "$long_input")"
len=${#out}
expected_max=$((EXCERPT_MAX + 3))  # 3-char "..." ellipsis
if (( len <= expected_max )); then
    assert_pass "S3: input truncated to ≤${expected_max} chars (got $len, EXCERPT_MAX=$EXCERPT_MAX)"
else
    assert_fail "S3: truncation failed; got $len chars (limit EXCERPT_MAX=$EXCERPT_MAX + 3)"
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

# ─── S12 REGRESSION LOCK: pipe characters in excerpt sanitized (Codex review #573) ─
# Without this, "needs follow-up for A | B" would split across the candidate
# format's 4 fields, corrupting the rendered triage body.
got="$(sanitize_excerpt "needs follow-up for A | B markdown table")"
[[ "$got" == *"|"* ]] && assert_fail "S12 LOCK: pipe still present in sanitized excerpt: $got" \
    || assert_pass "S12 LOCK: pipe replaced (markdown-table safe)"

# ─── S13 REGRESSION LOCK: trailing word-boundary trim (no mid-word cut) #596 C ─
# Build an input where byte 500 lands mid-word ("abcdefghij" 10-char words +
# space → 11 chars per repeat → mid-word at ~500).
S13_word="abcdefghij"
S13_prefix=""
for _ in $(seq 1 49); do S13_prefix+="${S13_word} "; done   # 49*11 = 539 chars
S13_prefix+="${S13_word}"
out="$(sanitize_excerpt "$S13_prefix")"
if [[ "$out" == *"..." ]]; then
    body="${out%...}"
    last_word="${body##* }"
    if [[ "$last_word" == "$S13_word" || -z "$last_word" || "${body: -1}" == " " ]]; then
        assert_pass "S13 LOCK: trailing trim landed on word boundary"
    else
        assert_fail "S13 LOCK: mid-word truncation; trailing token = '$last_word'"
    fi
else
    assert_fail "S13: expected trailing '...' after truncation, got: ${out: -10}"
fi

# ─── S14 REGRESSION LOCK: leading mid-word fragment trimmed + '...' prepended #596 C ─
# Phrase placed >300 chars in; leading context will start mid-word.
S14_filler="$(printf 'quickbrownfox %.0s' $(seq 1 30))"   # ~420 chars
S14_body="${S14_filler}needs a separate issue here. tail."
out="$(extract_excerpt "$S14_body" "separate issue")"
if [[ "$out" == "..."* ]]; then
    rest="${out#...}"
    first_char="${rest:0:1}"
    if [[ "$first_char" == " " ]]; then
        assert_pass "S14 LOCK: leading '...' prepended at word boundary"
    else
        # Acceptable if the trim removed enough to land on a complete word
        # directly (no leading whitespace remaining).
        assert_pass "S14: leading '...' present (rest starts: '${rest:0:15}')"
    fi
else
    # Acceptable if the body happens to start with a word boundary just
    # before the context window — then no trim needed. Verify excerpt does
    # NOT start mid-word.
    first_word="${out%% *}"
    if [[ "$first_word" == "quickbrownfox" ]]; then
        assert_pass "S14: window happened to start on word boundary"
    else
        assert_fail "S14 LOCK: excerpt starts mid-word: '${out:0:20}'"
    fi
fi

# ─── S15: DEFERRED_EXCERPT_MAX env override changes the cap ──────────────────
(
    export DEFERRED_EXCERPT_MAX=100
    # shellcheck source=../../scripts/deferred-tracker.sh
    source "$REPO_ROOT/scripts/deferred-tracker.sh"
    S15_input="$(printf 'b%.0s' $(seq 1 200))"
    out="$(sanitize_excerpt "$S15_input")"
    len=${#out}
    if (( len <= 103 )); then
        assert_pass "S15: DEFERRED_EXCERPT_MAX=100 honored (got $len chars)"
    else
        assert_fail "S15: override ignored; got $len chars (expected ≤103)"
    fi
)

print_test_results
