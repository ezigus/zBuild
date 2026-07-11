#!/usr/bin/env bash
# Unit test (#608, #1329): _build_parse_commit_summary.
#   #608  — single-response fallback: extract COMMIT_SUMMARY, trim, ≤72, fall back
#           to plan_title, then synthetic default.
#   #1329 — summaries-only cumulative composition: given the router's per-iteration
#           COMMIT_SUMMARY values (arg 3, newline-separated) + iteration count
#           (arg 4), a multi-iteration build gets subject = plan_title (whole-build
#           descriptor) + a de-duped per-iteration bullet body; single iteration is
#           unchanged; every line is control-char sanitized (injection-safe).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "build #608/#1329: _build_parse_commit_summary unit"
setup_test_env "build-608-commit-parser"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../plugins/agent/build/plugin.sh
source "$REPO_ROOT/plugins/agent/build/plugin.sh"

# ── (1) marker present, simple (single-response fallback path) ─────────────
out="$(_build_parse_commit_summary "did some work
COMMIT_SUMMARY: add foo bar
LOOP_COMPLETE" "fallback title")"
assert_eq "extracts simple COMMIT_SUMMARY" "add foo bar" "$out"

# ── (2) marker missing → fallback to plan_title ───────────────────────────
out="$(_build_parse_commit_summary "did some work
LOOP_COMPLETE" "plan title here")"
assert_eq "falls back to plan_title when marker missing" "plan title here" "$out"

# ── (3) marker + plan_title both empty → synthetic fallback ───────────────
export ZBUILD_CYCLE_ITER=3
out="$(_build_parse_commit_summary "nothing here
LOOP_COMPLETE" "")"
unset ZBUILD_CYCLE_ITER
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

# ── (6) last match wins when LLM emits twice (fallback path) ──────────────
out="$(_build_parse_commit_summary "COMMIT_SUMMARY: first try
some prose
COMMIT_SUMMARY: corrected message
LOOP_COMPLETE" "fb")"
assert_eq "last COMMIT_SUMMARY wins (single-response)" "corrected message" "$out"

# ── (7) plan_title also truncated when used as fallback ───────────────────
LONG_TITLE=$(printf 'b%.0s' {1..120})
out="$(_build_parse_commit_summary "no marker
LOOP_COMPLETE" "$LONG_TITLE")"
if [[ "${#out}" -le 72 ]]; then
    assert_pass "plan_title fallback truncated to <=72 chars (got ${#out})"
else
    assert_fail "plan_title fallback truncated to <=72 chars" "got ${#out}"
fi

# ── SPEC tests: summaries-only cumulative behavior (#1329) ─────────────────
# The router now hands the plugin the parsed per-iteration COMMIT_SUMMARY values
# as arg 3 (newline-separated) + the iteration count as arg 4.

# [SPEC-3] GUARD: single iteration (count=1) → subject = the summary, NO body.
out="$(_build_parse_commit_summary "" "plan title" "add frobber" 1)"
assert_eq "[SPEC-3] single-iter: subject = the summary, no body" "add frobber" "$out"
if [[ "$out" == *$'\n'* ]]; then
    assert_fail "[SPEC-3] single-iter: no body (no newline in output)" "got: $out"
else
    assert_pass "[SPEC-3] single-iter: no body (no newline in output)"
fi

# Two-iteration summaries (newline-separated) + count.
SUMS2=$'add first feature\nfix second bug'

# [SPEC-1] CHANGE: multi-iter → subject = plan_title (whole-build descriptor),
# NOT the last iteration's incremental summary.
out="$(_build_parse_commit_summary "" "Fix the whole build" "$SUMS2" 2)"
subject="$(printf '%s' "$out" | head -1)"
assert_eq "[SPEC-1] multi-iter: subject = plan_title (cumulative descriptor)" \
    "Fix the whole build" "$subject"

# [SPEC-2] CHANGE: multi-iter → body has a bullet for each distinct summary.
if grep -q -- '- add first feature' <<< "$out" \
   && grep -q -- '- fix second bug' <<< "$out"; then
    assert_pass "[SPEC-2] multi-iter: body contains a bullet for each distinct summary"
else
    assert_fail "[SPEC-2] multi-iter: body contains a bullet for each distinct summary" \
        "output: $(head -10 <<< "$out")"
fi

# [SPEC-4] CHANGE: 3 distinct summaries → body has exactly 3 bullet lines.
SUMS3=$'add first feature\nfix second bug\npolish third item'
out3="$(_build_parse_commit_summary "" "" "$SUMS3" 3)"
bullet_count="$(grep -c '^- ' <<< "$out3" || true)"
if [[ "$bullet_count" -eq 3 ]]; then
    assert_pass "[SPEC-4] 3 distinct summaries → body has exactly 3 bullets (got $bullet_count)"
else
    assert_fail "[SPEC-4] 3 distinct summaries → body has exactly 3 bullets" \
        "got $bullet_count; output: $out3"
fi

# Duplicate summaries across iterations collapse (dedup preserving order).
SUMS_DUP=$'same summary\nsame summary'
outd="$(_build_parse_commit_summary "" "title" "$SUMS_DUP" 2)"
dup_bullets="$(grep -c '^- ' <<< "$outd" || true)"
# 1 distinct summary → not a multi-summary cumulative build → single-line, no body.
if [[ "$dup_bullets" -eq 0 && "$outd" != *$'\n'* ]]; then
    assert_pass "[SPEC-4] duplicate summaries collapse (single distinct → no body)"
else
    assert_fail "[SPEC-4] duplicate summaries collapse" "output: $outd"
fi

# [SPEC-5] CHANGE: injection-safe — control chars stripped; an injected trailer
# stays a bulleted body line, never a bare trailing git trailer.
ESC=$'\x1b'
INJ="add feature${ESC}[31m"$'\nSigned-off-by: evil <e@e>'
out5="$(_build_parse_commit_summary "" "Real cumulative title" "$INJ" 2)"
if LC_ALL=C grep -q "$ESC" <<< "$out5"; then
    assert_fail "[SPEC-5] control chars (ESC) stripped from message" "ESC survived: $out5"
else
    assert_pass "[SPEC-5] control chars (ESC) stripped from message"
fi
if grep -q '^- Signed-off-by: evil' <<< "$out5" \
   && ! grep -qx 'Signed-off-by: evil <e@e>' <<< "$out5"; then
    assert_pass "[SPEC-5] injected trailer contained as a bullet, not a bare trailer"
else
    assert_fail "[SPEC-5] injected trailer contained as a bullet, not a bare trailer" \
        "output: $out5"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
