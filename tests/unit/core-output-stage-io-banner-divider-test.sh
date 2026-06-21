#!/usr/bin/env bash
# Tests: core/output/stage-io.sh — I/O banner divider glyph + color (#499)
#
# Covers (ADR-015 §v5 / #499):
#   - input  banner header uses ═ (U+2550), NOT ─ (U+2500)
#   - output banner header uses ═ (U+2550), NOT ─ (U+2500)
#   - end-trailer keeps ── (U+2500) for the lighter close
#   - colored: stage name wrapped in $BLUE+$BOLD (uniform palette per #499)
#   - colored: ═ runs wrapped in $LIGHT_BLUE
#   - substring invariant: asserted v4 prefix ("stage-io: <stage> [...] seq=N
#     <input|output>") byte-identical (no color escape inside the substring)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

export FORCE_COLOR=1
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/output/stage-io — banner ═ dividers + LIGHT_BLUE (#499)"
setup_test_env "stage-io-banner-divider"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="banner-divider"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR"

# shellcheck source=../../core/output/stage-io.sh
source "$REPO_ROOT/core/output/stage-io.sh"
_MOCK_DESTS="stdout"
template_stage_io_dests()      { printf '%s\n' "$_MOCK_DESTS"; }
template_stage_io_tail_lines() { printf ''; }
template_stage_io_redact()     { printf ''; }

_reset_pending() {
    local k
    for k in "${!_STAGE_IO_PENDING[@]}";       do unset '_STAGE_IO_PENDING[$k]';       done
    for k in "${!_STAGE_IO_PENDING_INPUT[@]}"; do unset '_STAGE_IO_PENDING_INPUT[$k]'; done
    for k in "${!_STAGE_IO_PENDING_KIND[@]}";  do unset '_STAGE_IO_PENDING_KIND[$k]';  done
    for k in "${!_STAGE_IO_PENDING_DESTS[@]}"; do unset '_STAGE_IO_PENDING_DESTS[$k]'; done
    for k in "${!_STAGE_IO_START_NS[@]}";      do unset '_STAGE_IO_START_NS[$k]';      done
}

# ─── D1: plain-text (non-tty fd) — header is ═, end-trailer is ── ───────────
_reset_pending
fd3="$TEST_TEMP_DIR/d1.fd3"
: > "$fd3"
exec 3>"$fd3"
ZBUILD_STAGE_IO_FD=3 \
ZBUILD_TERM_WIDTH_OVERRIDE=100 \
ZBUILD_STAGE_IO_NOW_MS_OVERRIDE=12345000 \
    stage_io_begin --stage plan --kind llm --input "PROMPT" >/dev/null
ZBUILD_STAGE_IO_FD=3 \
ZBUILD_TERM_WIDTH_OVERRIDE=100 \
ZBUILD_STAGE_IO_NOW_MS_OVERRIDE=12346200 \
    stage_io_end --stage plan --kind llm --seq "$_STAGE_IO_LAST_SEQ" \
        --output "RESP" --duration-ms 1200 >/dev/null
exec 3>&-
banner="$(cat "$fd3")"

# Extract just the input-header line (first line) and output-header line
# (line containing "seq=1 output OK").
input_header="$(printf '%s\n' "$banner" | grep -m1 'seq=1 input' || true)"
output_header="$(printf '%s\n' "$banner" | grep -m1 'seq=1 output OK' || true)"
end_trailer="$(printf '%s\n' "$banner" | grep -m1 'end stage-io: plan' || true)"

assert_contains "D1 input header uses ═ glyph"  "$input_header"  "═"
assert_contains "D1 output header uses ═ glyph" "$output_header" "═"
# Input header MUST NOT contain ── (light dashes); the only ── in the file
# belongs to the end-trailer.
if grep -q "──" <<< "$input_header"; then
    assert_fail "D1 input header has NO ── glyphs" "found in: $input_header"
else
    assert_pass "D1 input header has NO ── glyphs"
fi
if grep -q "──" <<< "$output_header"; then
    assert_fail "D1 output header has NO ── glyphs" "found in: $output_header"
else
    assert_pass "D1 output header has NO ── glyphs"
fi
assert_contains "D1 end-trailer keeps lighter ── glyph" "$end_trailer" "── end stage-io: plan"

# #523: v4 substring invariant updated — "stage-io:" prefix dropped from
# heading. Bracketed [kind] token retained (load-bearing). End-trailer prefix
# at L1049 unchanged (closer aids scrollback search).
assert_contains "D1 input header preserves v4 (post-#523) substring"  "$input_header"  "plan [llm] seq=1 input"
assert_contains "D1 output header preserves v4 (post-#523) substring" "$output_header" "plan [llm] seq=1 output OK 1.2s"
# #523 negative assertion: heading lines must NOT carry the legacy "stage-io:"
# label any more (only the end-trailer keeps it).
if grep -q "stage-io:" <<< "$input_header"; then
    assert_fail "D1 input header has NO 'stage-io:' prefix (#523)" "found in: $input_header"
else
    assert_pass "D1 input header has NO 'stage-io:' prefix (#523)"
fi
if grep -q "stage-io:" <<< "$output_header"; then
    assert_fail "D1 output header has NO 'stage-io:' prefix (#523)" "found in: $output_header"
else
    assert_pass "D1 output header has NO 'stage-io:' prefix (#523)"
fi
# Positive: end-trailer prefix still retained.
assert_contains "D1 end-trailer keeps 'end stage-io:' prefix (#523)" "$end_trailer" "end stage-io: plan"

# ─── D2: colored fd → stage name wrapped in $BLUE+$BOLD (uniform per #499) ──
_reset_pending
fd3c="$TEST_TEMP_DIR/d2.fd3"
: > "$fd3c"
exec 3>"$fd3c"
ZBUILD_STAGE_IO_FORCE_COLOR=1 \
ZBUILD_STAGE_IO_FD=3 \
ZBUILD_TERM_WIDTH_OVERRIDE=100 \
ZBUILD_STAGE_IO_NOW_MS_OVERRIDE=12345000 \
    stage_io_begin --stage plan --kind llm --input "P" >/dev/null
ZBUILD_STAGE_IO_FORCE_COLOR=1 \
ZBUILD_STAGE_IO_FD=3 \
ZBUILD_TERM_WIDTH_OVERRIDE=100 \
ZBUILD_STAGE_IO_NOW_MS_OVERRIDE=12345500 \
    stage_io_end --stage plan --kind llm --seq "$_STAGE_IO_LAST_SEQ" \
        --output "R" --duration-ms 500 >/dev/null
exec 3>&-
banner_c="$(cat "$fd3c")"

# Resolved escape strings: helpers stores literal '\033[…' which expand on %b.
# Match against the real ESC ($'\033') byte that the banner actually wrote.
ESC_BLUE=$'\033[38;2;0;102;255m'
ESC_LIGHT_BLUE=$'\033[38;2;100;200;255m'
ESC_BOLD=$'\033[1m'
ESC_RESET=$'\033[0m'

# Stage name wrapped in BLUE+BOLD (the registry collapsed everything to BLUE).
assert_contains "D2 colored: stage name 'plan' wrapped in BLUE+BOLD" \
    "$banner_c" "${ESC_BLUE}${ESC_BOLD}plan${ESC_RESET}"

# ═ runs wrapped in LIGHT_BLUE somewhere on the header line.
if grep -qF "${ESC_LIGHT_BLUE}══" <<< "$banner_c"; then
    assert_pass "D2 colored: ═ runs wrapped in LIGHT_BLUE"
else
    assert_fail "D2 colored: ═ runs wrapped in LIGHT_BLUE" \
        "no LIGHT_BLUE-prefixed ══ run found in banner"
fi

# Make sure NO legacy YELLOW/CYAN/PURPLE/GREEN/RED escape wraps the stage
# name 'plan' (#499 collapse: every built-in stage is BLUE now).
ESC_CYAN=$'\033[38;2;0;212;255m'
ESC_YELLOW=$'\033[38;2;250;204;21m'
ESC_PURPLE=$'\033[38;2;124;58;237m'
for legacy in "$ESC_CYAN" "$ESC_YELLOW" "$ESC_PURPLE"; do
    if grep -qF "${legacy}${ESC_BOLD}plan" <<< "$banner_c"; then
        assert_fail "D2 no legacy non-BLUE escape wraps stage 'plan'" \
            "found legacy escape wrapping plan"
    fi
done
assert_pass "D2 no legacy non-BLUE escape wraps stage 'plan'"

cleanup_test_env
print_test_results
exit "$FAIL"
