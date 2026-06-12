#!/usr/bin/env bash
# Tests: ADR-029 G1 — per-feedback-field context budget + tail_truncate (#814)
#
# When the cycle copies a feedback file to iter N+1, it now measures the
# file size. If it exceeds ZBUILD_CYCLE_MAX_FIELD_CHARS (default 50000),
# it truncates the file to the last N chars + prepends a sentinel marker
# so the downstream agent knows truncation happened. Emits
# cycle.context.compressed for postmortem.
#
# Within-budget files pass through untouched.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "cycle G1 — feedback context budget (ADR-029)"
setup_test_env "cycle-g1-budget"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"

# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"

_CYCLE_TRAP_CYCLE_ID="build-test"
STATE_DIR="$TEST_TEMP_DIR/state"
mkdir -p "$STATE_DIR/artifacts/test"

# ─── T1: oversized feedback file → tail_truncate + compressed event ───────
# Build a 200K oversized file (well above the default 50000 budget).
# Use a deterministic filler (1024-char block × 200) so pipelines don't
# SIGPIPE under set -o pipefail.
oversize_src="$STATE_DIR/artifacts/test/big.txt"
_g1_filler="$(printf 'X%.0s' $(seq 1 1024))"
{
    printf 'HEAD_MARKER_should_be_dropped\n'
    for _ in $(seq 1 200); do printf '%s\n' "$_g1_filler"; done
    printf '\nTAIL_MARKER_should_be_kept\n'
} > "$oversize_src"

: > "$ZBUILD_EVENTS_JSONL"
unset ZBUILD_CYCLE_MAX_FIELD_CHARS  # default budget = 50000
_CYCLE_FEEDBACK=("test:big.txt|build:prior_test_result:false")
set +e; _cycle_apply_feedback 2 "$STATE_DIR"; rc=$?; set -e
assert_eq "T1: feedback copy succeeds → rc=0" "0" "$rc"

dst="$STATE_DIR/cycle-build-test/iter-2/feedback/prior_test_result.txt"
assert_file_exists "T1: dst file written" "$dst"
dst_size="$(wc -c < "$dst" | tr -d ' ')"
# Truncation marker adds a ~100-char header, so file should be 50000 + marker.
if [[ "$dst_size" -le 50500 ]] && [[ "$dst_size" -ge 50000 ]]; then
    assert_pass "T1: dst file truncated to budget+marker (~50000 chars, got $dst_size)"
else
    assert_fail "T1: dst file size unexpected" "expected ~50000, got $dst_size"
fi

# Header sentinel.
head_line="$(head -1 "$dst")"
assert_contains "T1: truncation marker present at head" "$head_line" "ADR-029 G1"
assert_contains "T1: marker names the strategy" "$head_line" "tail_truncate"

# Verify tail content was preserved.
if grep -q "TAIL_MARKER_should_be_kept" "$dst"; then
    assert_pass "T1: most-recent tail content preserved"
else
    assert_fail "T1: tail content missing — truncation kept the wrong half"
fi
# Verify head content was dropped.
if grep -q "HEAD_MARKER_should_be_dropped" "$dst"; then
    assert_fail "T1: head content was NOT dropped — tail_truncate failed"
else
    assert_pass "T1: oldest head content dropped"
fi

# Event audit.
ev_c="$(grep -c '"type":"cycle.context.compressed"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; true)"
if [[ "$ev_c" -ge 1 ]]; then
    assert_pass "T1: cycle.context.compressed emitted (count=$ev_c)"
else
    assert_fail "T1: no cycle.context.compressed event"
fi

# ─── T2: under-budget file passes through untouched ────────────────────────
small_src="$STATE_DIR/artifacts/test/small.txt"
printf 'tiny feedback content\n' > "$small_src"
small_expected_size="$(wc -c < "$small_src" | tr -d ' ')"

: > "$ZBUILD_EVENTS_JSONL"
_CYCLE_FEEDBACK=("test:small.txt|build:prior_test_result:false")
set +e; _cycle_apply_feedback 3 "$STATE_DIR"; rc=$?; set -e
assert_eq "T2: small file copy → rc=0" "0" "$rc"
dst2="$STATE_DIR/cycle-build-test/iter-3/feedback/prior_test_result.txt"
dst2_size="$(wc -c < "$dst2" | tr -d ' ')"
assert_eq "T2: under-budget file passes through byte-for-byte" \
    "$small_expected_size" "$dst2_size"
ev_c2="$(grep -c '"type":"cycle.context.compressed"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; true)"
assert_eq "T2: no compression event for under-budget file" "0" "$ev_c2"

# ─── T3: env override lowers the budget — triggers compression on a
#         medium file that would have passed at default ──────────────────────
medium_src="$STATE_DIR/artifacts/test/medium.txt"
{ for _ in $(seq 1 9); do printf '%s\n' "$_g1_filler"; done; } > "$medium_src"
: > "$ZBUILD_EVENTS_JSONL"
export ZBUILD_CYCLE_MAX_FIELD_CHARS=1000
_CYCLE_FEEDBACK=("test:medium.txt|build:prior_test_result:false")
set +e; _cycle_apply_feedback 4 "$STATE_DIR"; rc=$?; set -e
assert_eq "T3: medium file copy → rc=0" "0" "$rc"
dst3="$STATE_DIR/cycle-build-test/iter-4/feedback/prior_test_result.txt"
dst3_size="$(wc -c < "$dst3" | tr -d ' ')"
if [[ "$dst3_size" -le 1500 ]]; then
    assert_pass "T3: env override budget=1000 enforced (size=$dst3_size)"
else
    assert_fail "T3: env override not honored — file size $dst3_size > 1500"
fi
ev_c3="$(grep -c '"type":"cycle.context.compressed"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; true)"
if [[ "$ev_c3" -ge 1 ]]; then
    assert_pass "T3: cycle.context.compressed emitted with env override"
else
    assert_fail "T3: no compression event with env override"
fi
unset ZBUILD_CYCLE_MAX_FIELD_CHARS

# ─── T4: invalid env override falls back to the 50000 default ──────────────
medium2_src="$STATE_DIR/artifacts/test/medium2.txt"
{ for _ in $(seq 1 4); do printf '%s\n' "$_g1_filler"; done; } > "$medium2_src"
: > "$ZBUILD_EVENTS_JSONL"
export ZBUILD_CYCLE_MAX_FIELD_CHARS="not-a-number"
_CYCLE_FEEDBACK=("test:medium2.txt|build:prior_test_result:false")
set +e; _cycle_apply_feedback 5 "$STATE_DIR"; rc=$?; set -e
assert_eq "T4: invalid env override accepted as default → rc=0" "0" "$rc"
# 4500 < 50000 → no truncation expected.
ev_c4="$(grep -c '"type":"cycle.context.compressed"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; true)"
assert_eq "T4: invalid env override falls back to 50000 → no compression" \
    "0" "$ev_c4"
unset ZBUILD_CYCLE_MAX_FIELD_CHARS

cleanup_test_env
print_test_results
exit $((FAIL > 0))
