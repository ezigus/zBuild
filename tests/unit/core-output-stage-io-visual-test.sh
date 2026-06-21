#!/usr/bin/env bash
# Tests: core/output/stage-io.sh — visual hierarchy + timestamps (#492)
#
# Covers:
#   - _stage_io_now_short renders HH:MM:SS UTC (and honors override)
#   - _term_width respects ZBUILD_TERM_WIDTH_OVERRIDE
#   - banner heading contains right-aligned timestamp
#   - end-trailer carries a status icon (✓ on OK, ✗ on FAIL)
#   - NO_COLOR / non-tty fd → no ANSI escapes in banner stream
#   - truncation hint appears when content exceeds tail_lines
#   - color-asymmetry: gh_comment body assembly path stays plain text
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Pin colors ON for the whole test so T6 can verify ANSI emission. Tests that
# need NO_COLOR behavior toggle ZBUILD_STAGE_IO_FORCE_COLOR per-case (the fd
# tty check still wins for the non-tty fd-3 stream when ZBUILD_STAGE_IO_FORCE_COLOR is 0).
export FORCE_COLOR=1
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/output/stage-io — visual hierarchy (ADR-015 §v5 #492)"
setup_test_env "stage-io-visual"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="visual-test"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR"

# shellcheck source=../../core/output/stage-io.sh
source "$REPO_ROOT/core/output/stage-io.sh"
# Mock destinations: only stdout so the file dest doesn't try to write.
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

# ─── T1: _stage_io_now_short renders HH:MM:SS UTC with override ───────────────
# 12345000 ms = 12345 seconds since epoch = 1970-01-01 03:25:45 UTC.
ts="$(ZBUILD_STAGE_IO_NOW_MS_OVERRIDE=12345000 _stage_io_now_short)"
assert_eq "T1 _stage_io_now_short with override == 03:25:45 UTC" "03:25:45 UTC" "$ts"

# ─── T2: _term_width honors ZBUILD_TERM_WIDTH_OVERRIDE ────────────────────────
unset _ZBUILD_TERM_WIDTH
w="$(ZBUILD_TERM_WIDTH_OVERRIDE=120 _term_width)"
assert_eq "T2 _term_width override returns 120" "120" "$w"

# ─── T3: banner heading carries right-aligned timestamp ──────────────────────
_reset_pending
fd3="$TEST_TEMP_DIR/t3.fd3"
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
assert_contains "T3 input banner carries HH:MM:SS UTC stamp"  "$banner" "03:25:45 UTC"
assert_contains "T3 output banner carries HH:MM:SS UTC stamp" "$banner" "03:25:46 UTC"
assert_contains "T3 token order preserved: seq=1 input"       "$banner" "seq=1 input"
assert_contains "T3 token order preserved: seq=1 output OK"   "$banner" "seq=1 output OK 1.2s"

# ─── T4: end-trailer carries status icon (✓ on OK) ───────────────────────────
assert_contains "T4 end-trailer carries ✓ icon for OK" "$banner" "end stage-io: plan ✓"

# ─── T5: NO_COLOR / non-tty fd → banner contains no ANSI escapes ─────────────
# fd 3 is a file (not a tty); _stage_io_banner_use_color returns false.
if grep -q $'\x1b\\[' <<< "$banner"; then
    assert_fail "T5 non-tty fd → no ANSI escapes" "found ESC[ in banner"
else
    assert_pass "T5 non-tty fd → no ANSI escapes"
fi

# ─── T6: FORCE_COLOR=1 reinstates ANSI escapes ───────────────────────────────
_reset_pending
fd3b="$TEST_TEMP_DIR/t6.fd3"
: > "$fd3b"
exec 3>"$fd3b"
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
banner_c="$(cat "$fd3b")"
if grep -q $'\x1b\\[' <<< "$banner_c"; then
    assert_pass "T6 FORCE_COLOR=1 reinstates ANSI escapes"
else
    assert_fail "T6 FORCE_COLOR=1 reinstates ANSI escapes" "no ESC[ found"
fi

# ─── T7: truncation hint when output exceeds tail_lines ──────────────────────
_reset_pending
big_output="$(for i in $(seq 1 50); do echo "line-$i"; done)"
fd3c="$TEST_TEMP_DIR/t7.fd3"
: > "$fd3c"
exec 3>"$fd3c"
# tail_lines comes from template_stage_io_tail_lines; default = 40 when empty.
ZBUILD_STAGE_IO_FD=3 \
ZBUILD_TERM_WIDTH_OVERRIDE=100 \
    stage_io_begin --stage plan --kind llm --input "P" >/dev/null
ZBUILD_STAGE_IO_FD=3 \
ZBUILD_TERM_WIDTH_OVERRIDE=100 \
    stage_io_end --stage plan --kind llm --seq "$_STAGE_IO_LAST_SEQ" \
        --output "$big_output" --duration-ms 10 >/dev/null
exec 3>&-
banner_t="$(cat "$fd3c")"
assert_contains "T7 truncation hint glyph appears" "$banner_t" "↪ ["
assert_contains "T7 truncation hint mentions more lines" "$banner_t" "more lines"
assert_contains "T7 truncation hint includes artifact path" "$banner_t" "artifacts/stage-io/plan-"

# ─── T8: short content does NOT emit truncation hint ─────────────────────────
_reset_pending
rm -rf "$ZBUILD_STATE_DIR/artifacts"
fd3d="$TEST_TEMP_DIR/t8.fd3"
: > "$fd3d"
exec 3>"$fd3d"
ZBUILD_STAGE_IO_FD=3 \
    stage_io_begin --stage plan --kind llm --input "short" >/dev/null
ZBUILD_STAGE_IO_FD=3 \
    stage_io_end --stage plan --kind llm --seq "$_STAGE_IO_LAST_SEQ" \
        --output "short out" --duration-ms 10 >/dev/null
exec 3>&-
banner_s="$(cat "$fd3d")"
if grep -q '↪ \[' <<< "$banner_s"; then
    assert_fail "T8 short content has NO truncation hint" "found hint in: $banner_s"
else
    assert_pass "T8 short content has NO truncation hint"
fi

# ─── T9: FAIL status → ✗ icon on end-trailer ─────────────────────────────────
_reset_pending
rm -rf "$ZBUILD_STATE_DIR/artifacts"
fd3e="$TEST_TEMP_DIR/t9.fd3"
: > "$fd3e"
exec 3>"$fd3e"
ZBUILD_STAGE_IO_FD=3 \
    stage_io_begin --stage build --kind command --input "false" >/dev/null
ZBUILD_STAGE_IO_FD=3 \
    stage_io_end --stage build --kind command --seq "$_STAGE_IO_LAST_SEQ" \
        --output "err" --exit-code 1 --duration-ms 5 >/dev/null
exec 3>&-
banner_f="$(cat "$fd3e")"
assert_contains "T9 output banner has FAIL status" "$banner_f" "output FAIL"
assert_contains "T9 end-trailer has ✗ icon for FAIL" "$banner_f" "end stage-io: build ✗"

# ─── T10: #499 — stage-name escape is BLUE for plan/build/test (uniform) ────
_reset_pending
rm -rf "$ZBUILD_STATE_DIR/artifacts"
fd_t10="$TEST_TEMP_DIR/t10.fd3"
: > "$fd_t10"
exec 3>"$fd_t10"
for s in plan build test; do
    ZBUILD_STAGE_IO_FORCE_COLOR=1 ZBUILD_STAGE_IO_FD=3 \
    ZBUILD_TERM_WIDTH_OVERRIDE=100 \
        stage_io_begin --stage "$s" --kind llm --input "p" >/dev/null
    ZBUILD_STAGE_IO_FORCE_COLOR=1 ZBUILD_STAGE_IO_FD=3 \
    ZBUILD_TERM_WIDTH_OVERRIDE=100 \
        stage_io_end --stage "$s" --kind llm --seq "$_STAGE_IO_LAST_SEQ" \
            --output "r" --duration-ms 1 >/dev/null
done
exec 3>&-
banner_t10="$(cat "$fd_t10")"
ESC_BLUE_T10=$'\033[38;2;0;102;255m'
ESC_BOLD_T10=$'\033[1m'
ESC_RESET_T10=$'\033[0m'
for s in plan build test; do
    assert_contains "T10 #499: stage '$s' wrapped in uniform \$BLUE+\$BOLD" \
        "$banner_t10" "${ESC_BLUE_T10}${ESC_BOLD_T10}${s}${ESC_RESET_T10}"
done

# ─── T11: #499 — NO_COLOR strips ANSI but ═ glyph survives ──────────────────
_reset_pending
rm -rf "$ZBUILD_STATE_DIR/artifacts"
fd_t11="$TEST_TEMP_DIR/t11.fd3"
: > "$fd_t11"
exec 3>"$fd_t11"
# Use NO_COLOR via env, with fd 3 a plain file (banner_use_color → false anyway).
NO_COLOR=1 ZBUILD_STAGE_IO_FD=3 ZBUILD_TERM_WIDTH_OVERRIDE=100 \
    stage_io_begin --stage plan --kind llm --input "P" >/dev/null
NO_COLOR=1 ZBUILD_STAGE_IO_FD=3 ZBUILD_TERM_WIDTH_OVERRIDE=100 \
    stage_io_end --stage plan --kind llm --seq "$_STAGE_IO_LAST_SEQ" \
        --output "R" --duration-ms 1 >/dev/null
exec 3>&-
banner_t11="$(cat "$fd_t11")"
if grep -q $'\x1b\\[' <<< "$banner_t11"; then
    assert_fail "T11 NO_COLOR strips all ANSI from banner" "found ESC[ in: $banner_t11"
else
    assert_pass "T11 NO_COLOR strips all ANSI from banner"
fi
assert_contains "T11 NO_COLOR keeps ═ divider glyph" "$banner_t11" "═"
assert_contains "T11 NO_COLOR keeps ── end-trailer glyph" "$banner_t11" "── end stage-io: plan"

cleanup_test_env
print_test_results
exit "$FAIL"
