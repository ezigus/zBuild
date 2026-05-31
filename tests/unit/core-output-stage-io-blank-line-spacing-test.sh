#!/usr/bin/env bash
# Tests: core/pipeline/runner.sh — _render_stage_divider blank-line spacing
# (#523, ADR-015 §v5 amendment).
#
# Pin: option (a) — a single trailing blank line at the END of every stage
# divider invocation. Combined with the existing leading '\n' the divider
# already emits, this produces TWO stacked blank lines before each subsequent
# stage's content (consecutive-stage breathing room). Cycle sub-dividers
# (ADR-015 §v6) intentionally do NOT add this blank line.
#
# We drive two sequential _render_stage_divider calls, capture fd 2, and
# assert that exactly one blank line precedes each banner heading.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/pipeline/runner — divider blank-line spacing (#523)"
setup_test_env "stage-io-blank-line-spacing"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR"

# Drive two sequential dividers in a subshell with width pinned and color off.
out_file="$TEST_TEMP_DIR/dividers.out"
NO_COLOR=1 ZBUILD_TERM_WIDTH_OVERRIDE=100 ZBUILD_STAGE_IO_NOW_MS_OVERRIDE=12345000 \
    bash -c "
        source '$REPO_ROOT/core/pipeline/runner.sh'
        _render_stage_divider plan
        _render_stage_divider build
    " 2>"$out_file"

content="$(cat "$out_file")"

# ─── B1: total blank-line count between two dividers is 4 ────────────────────
# Layout: \n + plan-line + \n + \n  + \n + build-line + \n + \n
#         (leading)  (label) (trailing pair)  (leading) (label) (trailing pair)
# So: between the two heading lines there are EXACTLY 3 blank lines
# (1 trailing-of-plan + 1 trailing-blank-of-plan + 1 leading-of-build).
# After the build heading there are 2 trailing blank lines.
heading_count="$(printf '%s\n' "$content" | grep -cE '^.*(plan|build).*$' | head -1 || true)"
# The lines containing "plan" or "build" labels (the dividers).
divider_lines="$(printf '%s\n' "$content" | grep -nE '━━ (plan|build) ━━' | cut -d: -f1)"
plan_line="$(printf '%s\n' "$divider_lines" | head -1)"
build_line="$(printf '%s\n' "$divider_lines" | tail -1)"

if [[ -n "$plan_line" && -n "$build_line" && "$plan_line" -lt "$build_line" ]]; then
    assert_pass "B1 plan divider precedes build divider"
else
    assert_fail "B1 plan divider precedes build divider" \
        "plan=$plan_line build=$build_line; content=$content"
fi

# ─── B2: count blank lines between plan and build heading ──────────────────
# Number of empty lines strictly between plan_line and build_line MUST be 3
# (#523: trailing pair after plan + leading single before build).
blanks_between="$(printf '%s\n' "$content" | sed -n "$((plan_line+1)),$((build_line-1))p" | grep -c '^$' || true)"
assert_eq "B2 exactly 3 blank lines between two dividers (#523)" "3" "$blanks_between"

# ─── B3: blank lines after the SECOND divider == 2 ─────────────────────────
# build_line is followed by 2 trailing blanks (the new pair from #523).
# Read from file directly to preserve trailing newlines (command substitution
# strips them, which would drop the last blank).
blanks_after="$(sed -n "$((build_line+1)),\$p" "$out_file" | grep -c '^$' || true)"
assert_eq "B3 exactly 2 trailing blank lines after final divider (#523)" "2" "$blanks_after"

# ─── B4: blank line BEFORE first divider == 1 ───────────────────────────────
blanks_before="$(printf '%s\n' "$content" | sed -n "1,$((plan_line-1))p" | grep -c '^$' || true)"
assert_eq "B4 exactly 1 blank line before first divider (existing leading \\n)" "1" "$blanks_before"

cleanup_test_env
print_test_results
exit "$FAIL"
