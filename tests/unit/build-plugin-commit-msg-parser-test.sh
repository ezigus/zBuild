#!/usr/bin/env bash
# Unit test (#608): _build_parse_commit_summary extracts COMMIT_SUMMARY marker,
# trims, truncates to 72 chars, and falls back to plan_title when absent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "build #608: _build_parse_commit_summary unit"
setup_test_env "build-608-commit-parser"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../plugins/agent/build/plugin.sh
source "$REPO_ROOT/plugins/agent/build/plugin.sh"

# ── (1) marker present, simple ─────────────────────────────────────────────
out="$(_build_parse_commit_summary "did some work
COMMIT_SUMMARY: add foo bar
LOOP_COMPLETE" "fallback title")"
assert_eq "extracts simple COMMIT_SUMMARY" "add foo bar" "$out"

# ── (2) marker missing → fallback to plan_title ───────────────────────────
out="$(_build_parse_commit_summary "did some work
LOOP_COMPLETE" "plan title here")"
assert_eq "falls back to plan_title when marker missing" "plan title here" "$out"

# ── (3) marker + plan_title both empty → synthetic fallback ───────────────
ZBUILD_CYCLE_ITER=3
out="$(_build_parse_commit_summary "nothing here
LOOP_COMPLETE" "")"
unset ZBUILD_CYCLE_ITER
# Synthetic message includes the iter number
case "$out" in
    *"iter 3"*) assert_pass "synthetic fallback includes iter number" ;;
    *) assert_fail "synthetic fallback includes iter number" "got: $out" ;;
esac

# ── (4) extra whitespace stripped ─────────────────────────────────────────
out="$(_build_parse_commit_summary "COMMIT_SUMMARY:    spaced message
LOOP_COMPLETE" "fb")"
assert_eq "trims leading/trailing whitespace" "spaced message" "$out"

# ── (5) truncates to 72 chars ─────────────────────────────────────────────
LONG=$(printf 'a%.0s' {1..100})
out="$(_build_parse_commit_summary "COMMIT_SUMMARY: $LONG
LOOP_COMPLETE" "fb")"
if [[ "${#out}" -le 72 ]]; then
    assert_pass "truncates to <=72 chars (got ${#out})"
else
    assert_fail "truncates to <=72 chars" "got ${#out}"
fi

# ── (6) last match wins when LLM emits twice ──────────────────────────────
out="$(_build_parse_commit_summary "COMMIT_SUMMARY: first try
some prose
COMMIT_SUMMARY: corrected message
LOOP_COMPLETE" "fb")"
assert_eq "last COMMIT_SUMMARY wins" "corrected message" "$out"

# ── (7) plan_title also truncated when used as fallback ───────────────────
LONG_TITLE=$(printf 'b%.0s' {1..120})
out="$(_build_parse_commit_summary "no marker
LOOP_COMPLETE" "$LONG_TITLE")"
if [[ "${#out}" -le 72 ]]; then
    assert_pass "plan_title fallback truncated to <=72 chars (got ${#out})"
else
    assert_fail "plan_title fallback truncated to <=72 chars" "got ${#out}"
fi

# ── SPEC tests for multi-iteration RS-delimited cumulative behavior (#1329) ───
# [SPEC-3] GUARD: single-iter behavior unchanged — subject = COMMIT_SUMMARY,
# no body added. Passes at baseline (existing behavior) and after.
out="$(_build_parse_commit_summary $'wrote file\nCOMMIT_SUMMARY: add frobber\nLOOP_COMPLETE' "fallback")"
assert_eq "[SPEC-3] single-iter: subject = COMMIT_SUMMARY, no body added" \
    "add frobber" "$out"

# Build RS-delimited 2-iteration input for SPEC-1, SPEC-2.
RS=$'\x1e'
ITER1=$'did iter1\nCOMMIT_SUMMARY: add first feature\nmore text'
ITER2=$'did iter2\nCOMMIT_SUMMARY: fix second bug\nLOOP_COMPLETE'
TWO_ITERS="${ITER1}${RS}${ITER2}"

# [SPEC-1] CHANGE: multi-iter RS input → subject = first unique COMMIT_SUMMARY.
# Fails at baseline (old parser returns LAST match "fix second bug", not first).
out="$(_build_parse_commit_summary "$TWO_ITERS" "plan title")"
subject="$(printf '%s' "$out" | head -1)"
assert_eq "[SPEC-1] multi-iter: subject = first unique COMMIT_SUMMARY" \
    "add first feature" "$subject"

# [SPEC-2] CHANGE: multi-iter RS input → body contains bullet for each summary.
# Fails at baseline (old parser produces no body).
if grep -q -- '- add first feature' <<< "$out" \
   && grep -q -- '- fix second bug' <<< "$out"; then
    assert_pass "[SPEC-2] multi-iter: body contains bullets for each distinct summary"
else
    assert_fail "[SPEC-2] multi-iter: body contains bullets for each distinct summary" \
        "output: $(head -10 <<< "$out")"
fi

# [SPEC-4] CHANGE: 3-iter RS input → body has 3 bullet lines.
# Fails at baseline (old parser produces no body).
ITER3=$'did iter3\nCOMMIT_SUMMARY: polish third item\nLOOP_COMPLETE'
THREE_ITERS="${ITER1}${RS}${ITER2}${RS}${ITER3}"
out3="$(_build_parse_commit_summary "$THREE_ITERS" "")"
bullet_count="$(grep -c '^- ' <<< "$out3" || true)"
if [[ "$bullet_count" -eq 3 ]]; then
    assert_pass "[SPEC-4] 3-iter input: body has exactly 3 bullet lines (got $bullet_count)"
else
    assert_fail "[SPEC-4] 3-iter input: body has exactly 3 bullet lines" \
        "got $bullet_count bullets; output: $out3"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
