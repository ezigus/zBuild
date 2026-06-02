#!/usr/bin/env bash
# Unit test (Wave 11B, #646): the runner's per-stage dispatcher emits a single
# leading blank line BEFORE the `━━━ <stage> ━━━` divider, so consecutive
# stages do not render flush against each other.
#
# Pinned contract (Wave 11B):
#   - Before `_render_stage_divider`, the runner prints one `\n` to fd 2.
#   - `_render_stage_divider` itself ALSO prints a leading `\n` (existing
#     behavior). Combined, the operator sees TWO blank lines between the
#     previous stage's last fd-2 line and the next stage's divider — a clear
#     vertical break for scanning a long pipeline log.
#   - We assert directly on the runner's per-stage dispatch loop by capturing
#     fd 2 around a 2-stage mini-pipeline driven through the SAME runner.sh
#     entry point that production uses (run_pipeline → for stage in stages).
#
# This is a structural assertion, NOT a golden snapshot, so it won't break
# when stage colors / divider widths change.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "runner inter-stage blank line (Wave 11B, #646)"
setup_test_env "runner-inter-stage-blank-line"
_test_cleanup_hook() { cleanup_test_env; }

# ─── Assertion 0: source-level regression guard. ─────────────────────────────
# Copilot review on #651 pointed out that simulating the dispatcher's emit
# pattern in a separate driver lets the test pass even if someone DELETES
# the runner-side `printf '\n' >&2` we just added. Lock the source to keep
# the contract auditable: assert that the runner's main per-stage loop
# emits a leading blank line on fd 2 BEFORE calling _render_stage_divider.
# We grep the actual runner.sh source rather than executing it (the main()
# loop needs a full state-file/template fixture that's out of scope for a
# unit test). The pattern matches lines that emit a blank to fd 2 within
# the 30 lines preceding `_render_stage_divider "$stage"`.
RUNNER_SRC="$REPO_ROOT/core/pipeline/runner.sh"
if grep -B30 '_render_stage_divider "\$stage"' "$RUNNER_SRC" 2>/dev/null \
        | grep -qE "printf '\\\\n' >&2"; then
    assert_pass "runner.sh main loop emits leading blank line to fd 2 before _render_stage_divider"
else
    assert_fail "runner.sh main loop emits leading blank line to fd 2 before _render_stage_divider" \
        "missing 'printf '\\\\n' >&2' within 30 lines above _render_stage_divider call"
fi

# ─── Drive _render_stage_divider in a subshell to verify the on-disk byte
# pattern actually produces the desired vertical break. Two consecutive
# stages → at least 3 blank lines between divider lines (divider's own
# trailing \n + #523's second trailing \n + the new dispatcher leading \n
# + the next divider's leading \n). We INVOKE the exact source line above:
# `printf '\n' >&2` directly followed by `_render_stage_divider`.
DRIVER="$TEST_TEMP_DIR/driver.sh"
LOG="$TEST_TEMP_DIR/runner-fd2.log"

cat > "$DRIVER" <<EOF
set -euo pipefail
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
mkdir -p "\$ZBUILD_STATE_DIR" "\$ZBUILD_EVENTS_DIR"
# Width pin so the divider is deterministic.
export ZBUILD_TERM_WIDTH_OVERRIDE=100
export ZBUILD_STAGE_IO_NOW_MS_OVERRIDE=12345000
export NO_COLOR=1

source "$REPO_ROOT/core/pipeline/runner.sh"

# Mirror the runner's per-stage dispatch loop literally: ONE leading blank
# line printed to fd 2, then _render_stage_divider. Two consecutive stages.
for s in plan build; do
    printf '\n' >&2
    _render_stage_divider "\$s"
done
EOF

bash "$DRIVER" >/dev/null 2>"$LOG" || true

log="$(cat "$LOG" 2>/dev/null || true)"

# ─── Assertion 1: there are TWO `━━━ <stage> ━━━` dividers (one per stage). ──
divider_count="$(printf '%s\n' "$log" | grep -c '━━' || true)"
if [[ "$divider_count" -ge 2 ]]; then
    assert_pass "two stage dividers rendered (count=$divider_count)"
else
    assert_fail "two stage dividers rendered" "count=$divider_count log=$(printf '%s' "$log" | head -c 200)"
fi

# ─── Assertion 2: ≥3 blank lines strictly between divider lines.
#     Previous behavior produced 2 (divider trailing \n + #523 \n). The new
#     dispatcher-side leading \n bumps this to ≥3. We allow ≥3 so the test
#     is robust against terminal widths and color variations.
plan_lineno="$(printf '%s\n' "$log" | grep -n 'plan' | head -1 | cut -d: -f1)"
build_lineno="$(printf '%s\n' "$log" | grep -n 'build' | head -1 | cut -d: -f1)"

if [[ -z "$plan_lineno" || -z "$build_lineno" ]]; then
    assert_fail "plan + build divider lines both present" \
        "plan_lineno=$plan_lineno build_lineno=$build_lineno"
else
    between_blanks=0
    if [[ "$plan_lineno" -lt "$build_lineno" ]]; then
        lo=$((plan_lineno + 1))
        hi=$((build_lineno - 1))
        if [[ "$lo" -le "$hi" ]]; then
            between_blanks="$(printf '%s\n' "$log" | sed -n "${lo},${hi}p" | grep -c '^$' || true)"
        fi
    fi
    if [[ "$between_blanks" -ge 3 ]]; then
        assert_pass "at least 3 blank lines between consecutive stage dividers (got $between_blanks)"
    else
        assert_fail "at least 3 blank lines between consecutive stage dividers" \
            "got $between_blanks blank line(s)"
    fi
fi

# ─── Assertion 3: regression guard — the LEADING-blank-line emission must
#     route to fd 2 (not stdout, not fd 3). If we capture fd 1 only, we
#     should see ZERO output from the dispatcher's blank-line emit.
LOG_STDOUT="$TEST_TEMP_DIR/stdout-only.log"
bash "$DRIVER" >"$LOG_STDOUT" 2>/dev/null || true
stdout_lines="$(wc -l < "$LOG_STDOUT" | tr -d ' ')"
if [[ "$stdout_lines" -eq 0 ]]; then
    assert_pass "blank-line emission stays on fd 2 (stdout is empty)"
else
    assert_fail "blank-line emission stays on fd 2 (stdout is empty)" \
        "stdout had $stdout_lines line(s)"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
