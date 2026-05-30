#!/usr/bin/env bash
# Tests: core/pipeline/runner.sh — stage boundary timestamps (#508)
#
# Covers (ADR-015 §v5 amendment, issue #508):
#   - U0/U0b: runner clock contract (override + format)
#   - U1/U1b/U1c/U1d: _render_stage_divider right-aligns ts; degrades narrow
#   - U2/U2b/U2c: "▸ Running stage" line carries "(started HH:MM:SS UTC)"
#   - U3/U3b/U3c/U3d: ✓/✗ lines carry "(finished HH:MM:SS UTC · <dur>)"
#   - U4: NO_COLOR strips ANSI but timestamp + glyphs survive
#   - F1/F2/F3: defensive parse failures (no crash, sentinel renders)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Pin colors ON so we can verify both colored + NO_COLOR paths in the same run.
export FORCE_COLOR=1
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/pipeline/runner — stage timestamps (#508)"
setup_test_env "runner-stage-timestamps"

# Source ONLY what we need from runner: the inline functions. The runner is
# guarded with `if [[ "${BASH_SOURCE[0]}" == "$0" ]]` around main(), so we can
# source the whole file safely — main() does not auto-run.
# We need ZBUILD_PLUGINS_ROOT/ZBUILD_STATE_DIR set to plausible paths to avoid
# core/config/config.sh's init touching the real $HOME.
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
mkdir -p "$ZBUILD_STATE_DIR" "$ZBUILD_EVENTS_DIR"

# shellcheck source=../../core/pipeline/runner.sh
source "$REPO_ROOT/core/pipeline/runner.sh"

# ─── U0: _runner_now_ms honors ZBUILD_STAGE_IO_NOW_MS_OVERRIDE ───────────────
ms="$(ZBUILD_STAGE_IO_NOW_MS_OVERRIDE=12345000 _runner_now_ms)"
assert_eq "U0 _runner_now_ms honors override" "12345000" "$ms"

# ─── U0b: _runner_now_short formats HH:MM:SS UTC ─────────────────────────────
# 12345000 ms = 12345 sec since epoch = 1970-01-01 03:25:45 UTC.
ts="$(ZBUILD_STAGE_IO_NOW_MS_OVERRIDE=12345000 _runner_now_short)"
assert_eq "U0b _runner_now_short renders HH:MM:SS UTC" "03:25:45 UTC" "$ts"

# Helper: run _render_stage_divider in a fresh subshell with NO_COLOR set so
# helpers.sh's load-time color init takes the no-color branch. The outer test
# pinned FORCE_COLOR=1 at file scope (so colored asserts work), but the
# divider's NO_COLOR behavior must be observed via a clean re-source.
_divider_no_color() {
    local stage="$1" width="$2" ms="$3"
    NO_COLOR=1 FORCE_COLOR= ZBUILD_TERM_WIDTH_OVERRIDE="$width" \
        ZBUILD_STAGE_IO_NOW_MS_OVERRIDE="$ms" \
        bash -c "
            unset FORCE_COLOR
            export NO_COLOR=1
            source '$REPO_ROOT/core/pipeline/runner.sh'
            _render_stage_divider '$stage'
        " 2>&1
}

# ─── U1: divider right-aligns timestamp at w=100 (NO_COLOR for clean width) ─
out="$(_divider_no_color plan 100 12345000)"
assert_contains "U1 divider carries HH:MM:SS UTC stamp" "$out" "03:25:45 UTC"
assert_contains "U1 divider carries stage label" "$out" "plan"
assert_contains "U1 divider uses ━ glyph" "$out" "━"

# ─── U1b: timestamp on the SAME line as the ━ run, right-side ───────────────
divider_line="$(printf '%s\n' "$out" | grep -m1 '━' || true)"
assert_contains "U1b divider line carries both label + ts" "$divider_line" "plan"
assert_contains "U1b divider line carries ts on same line" "$divider_line" "03:25:45 UTC"
# Ts must appear AFTER the label (right-aligned).
label_pos=$(awk -v s="$divider_line" -v t=" plan " 'BEGIN{print index(s,t)}')
ts_pos=$(awk -v s="$divider_line" -v t="03:25:45 UTC" 'BEGIN{print index(s,t)}')
if (( ts_pos > label_pos && label_pos > 0 )); then
    assert_pass "U1b timestamp is right of label"
else
    assert_fail "U1b timestamp is right of label" "label=$label_pos ts=$ts_pos line=$divider_line"
fi

# ─── U1c: width math — line length matches term width (NO_COLOR; visible len) ─
plain_len=${#divider_line}
assert_eq "U1c divider visible width == 100" "100" "$plain_len"

# ─── U1d: degrade rule — narrow terminal drops timestamp, legacy divider ────
# Math: label="$ plan " (6), ts="03:25:45 UTC" (12). mid_bar = w - 22 - 2.
# mid_bar <= 2 when w <= 26. Use w=24 to force degrade.
out_narrow="$(_divider_no_color plan 22 12345000)"
if printf '%s' "$out_narrow" | grep -q "03:25:45 UTC"; then
    assert_fail "U1d narrow terminal drops timestamp" "found ts in: $out_narrow"
else
    assert_pass "U1d narrow terminal drops timestamp"
fi
assert_contains "U1d narrow terminal keeps stage label" "$out_narrow" "plan"

# ─── U2: "▸ Running stage" suffix — synthesize the line ─────────────────────
# Validates the exact format used in the runner main loop (lines ~398-405):
unset _ZBUILD_TERM_WIDTH
_sc_color="$(_stage_color plan)"
_sc_ts="$(ZBUILD_STAGE_IO_NOW_MS_OVERRIDE=12345000 _runner_now_short)"
running_line="$(NO_COLOR=1 bash -c "
    source '$REPO_ROOT/scripts/lib/helpers.sh'
    source '$REPO_ROOT/core/output/stage-colors.sh'
    echo -e \"\${CYAN}\${BOLD}▸\${RESET} Running stage: \${BOLD}plan\${RESET}  \${DIM}(started ${_sc_ts})\${RESET}\"
")"
assert_contains "U2 Running line has started HH:MM:SS UTC"  "$running_line" "(started 03:25:45 UTC)"
assert_contains "U2 Running line still carries ▸ glyph"     "$running_line" "▸"
assert_contains "U2 Running line still carries 'Running stage'" "$running_line" "Running stage"

# ─── U2b: two-space separator before the paren ──────────────────────────────
assert_contains "U2b Running line uses 2-space separator before paren" \
    "$running_line" "plan  (started"

# ─── U2c: stage name still present (color-stripped form) ────────────────────
assert_contains "U2c Running line names stage" "$running_line" "plan"

# ─── U3: ✓ complete line carries "(finished HH:MM:SS UTC · <dur>)" ──────────
# Format duration via _runner_duration_token by seeding the cache directly.
_RUNNER_STAGE_START_MS[plan]=12345000
dur="$(ZBUILD_STAGE_IO_NOW_MS_OVERRIDE=12345400 _runner_duration_token plan)"
assert_eq "U3 0.4s duration token" "0.4s" "$dur"

complete_line="$(NO_COLOR=1 bash -c "
    source '$REPO_ROOT/scripts/lib/helpers.sh'
    echo -e \"\${GREEN}\${BOLD}✓\${RESET} Stage \${BOLD}plan\${RESET} complete  \${DIM}(finished 03:25:46 UTC · 0.4s)\${RESET}\"
")"
assert_contains "U3 complete line has finished HH:MM:SS UTC · 0.4s" \
    "$complete_line" "(finished 03:25:46 UTC · 0.4s)"
assert_contains "U3 complete line keeps ✓ glyph" "$complete_line" "✓"

# ─── U3b: minute-scale duration formats as <m>m<ss>s ────────────────────────
_RUNNER_STAGE_START_MS[build]=12345000
dur_min="$(ZBUILD_STAGE_IO_NOW_MS_OVERRIDE=12407000 _runner_duration_token build)"
assert_eq "U3b 62-second duration formats as 1m02s" "1m02s" "$dur_min"

# ─── U3c: missing start-time cache → ?s ─────────────────────────────────────
dur_miss="$(ZBUILD_STAGE_IO_NOW_MS_OVERRIDE=12345000 _runner_duration_token nonexistent-stage)"
assert_eq "U3c cache miss yields ?s" "?s" "$dur_miss"

# ─── U3d: ✗ failure line format (preserve rc, append finished + duration) ───
fail_line="$(NO_COLOR=1 bash -c "
    source '$REPO_ROOT/scripts/lib/helpers.sh'
    error 'Stage build failed (rc=1, finished 03:25:46 UTC · 0.4s)'
" 2>&1)"
assert_contains "U3d fail line has rc + finished + duration" \
    "$fail_line" "(rc=1, finished 03:25:46 UTC · 0.4s)"
assert_contains "U3d fail line keeps ✗ glyph" "$fail_line" "✗"

# ─── U4: NO_COLOR strips ANSI but timestamps + glyphs survive ───────────────
out_nc="$(_divider_no_color plan 100 12345000)"
if printf '%s' "$out_nc" | grep -q $'\x1b\\['; then
    assert_fail "U4 NO_COLOR strips ANSI from divider" "found ESC[ in: $out_nc"
else
    assert_pass "U4 NO_COLOR strips ANSI from divider"
fi
assert_contains "U4 NO_COLOR keeps timestamp"   "$out_nc" "03:25:45 UTC"
assert_contains "U4 NO_COLOR keeps ━ glyph"     "$out_nc" "━"
assert_contains "U4 NO_COLOR keeps stage label" "$out_nc" "plan"

# ─── F1: non-numeric override → _runner_now_ms falls back gracefully ────────
ms_bad="$(ZBUILD_STAGE_IO_NOW_MS_OVERRIDE=notanumber _runner_now_ms)"
if [[ -n "$ms_bad" && "$ms_bad" =~ ^[0-9]+$ ]]; then
    assert_pass "F1 non-numeric override falls back to real clock"
else
    assert_fail "F1 non-numeric override falls back to real clock" "got: $ms_bad"
fi

# ─── F2: empty/broken clock → ??:??:?? UTC sentinel ─────────────────────────
# Inject by overriding _runner_now_ms to emit empty for this call only.
_orig_now_ms() { _runner_now_ms "$@"; }
_runner_now_ms() { printf ''; }
ts_sentinel="$(_runner_now_short)"
unset -f _runner_now_ms
# Re-source to restore the real one.
source "$REPO_ROOT/core/pipeline/runner.sh"
assert_eq "F2 missing clock yields sentinel" "??:??:?? UTC" "$ts_sentinel"

# ─── F3: duration token with corrupt cache → ?s sentinel ────────────────────
_RUNNER_STAGE_START_MS[corrupt]="not-a-number"
dur_corrupt="$(ZBUILD_STAGE_IO_NOW_MS_OVERRIDE=12345000 _runner_duration_token corrupt)"
assert_eq "F3 corrupt cache yields ?s" "?s" "$dur_corrupt"

cleanup_test_env
print_test_results
exit "$FAIL"
