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

cleanup_test_env
print_test_results
exit $((FAIL > 0))
