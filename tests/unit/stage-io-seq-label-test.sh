#!/usr/bin/env bash
# Tests: stage_io_begin --seq-label flag (#682, Wave 15-D)
#
# Covers:
#   - When --seq-label "1.2" is passed, banner heading renders `seq=1.2`
#   - When --seq-label is omitted, banner falls back to cardinal `seq=N`
#     (back-compat preserved)
#   - The internal _STAGE_IO_LAST_SEQ counter remains the cardinal integer
#     (so stage_io_end --seq <N> pairing still works untouched)
#   - End-side banner renders the same label (output line uses seq=1.2 too)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "stage_io_begin --seq-label hierarchical label (#682)"
setup_test_env "stage-io-seq-label"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="seq-label-test"
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
    for k in "${!_STAGE_IO_PENDING_LABEL[@]}"; do unset '_STAGE_IO_PENDING_LABEL[$k]'; done
    for k in "${!_STAGE_IO_START_NS[@]}";      do unset '_STAGE_IO_START_NS[$k]';      done
}

# ─── L1: --seq-label "1.2" renders banner as seq=1.2 ─────────────────────────
_reset_pending
fd3="$TEST_TEMP_DIR/l1.fd3"
: > "$fd3"
exec 3>"$fd3"
ZBUILD_STAGE_IO_FD=3 \
ZBUILD_TERM_WIDTH_OVERRIDE=100 \
ZBUILD_STAGE_IO_NOW_MS_OVERRIDE=12345000 \
    stage_io_begin --stage build --kind llm --input "PROMPT" \
        --seq-label "1.2" >/dev/null
input_seq="$_STAGE_IO_LAST_SEQ"
ZBUILD_STAGE_IO_FD=3 \
ZBUILD_TERM_WIDTH_OVERRIDE=100 \
ZBUILD_STAGE_IO_NOW_MS_OVERRIDE=12346200 \
    stage_io_end --stage build --kind llm --seq "$input_seq" \
        --output "RESP" --duration-ms 1200 >/dev/null
exec 3>&-
banner="$(cat "$fd3")"

input_header="$(printf '%s\n' "$banner" | grep -m1 'input' || true)"
output_header="$(printf '%s\n' "$banner" | grep -m1 'output OK' || true)"

assert_contains "L1 banner input header uses literal seq=1.2 label"  "$input_header"  "seq=1.2 input"
assert_contains "L1 banner output header uses literal seq=1.2 label" "$output_header" "seq=1.2 output OK"
# Internal cardinal seq (returned to caller for pairing) remains integer 1
assert_eq "L1 _STAGE_IO_LAST_SEQ stays cardinal integer" "1" "$input_seq"

# ─── L2: omitting --seq-label falls back to today's cardinal seq ─────────────
_reset_pending
fd3="$TEST_TEMP_DIR/l2.fd3"
: > "$fd3"
exec 3>"$fd3"
ZBUILD_STAGE_IO_FD=3 \
ZBUILD_TERM_WIDTH_OVERRIDE=100 \
ZBUILD_STAGE_IO_NOW_MS_OVERRIDE=12345000 \
    stage_io_begin --stage plan --kind llm --input "PROMPT" >/dev/null
seq_v="$_STAGE_IO_LAST_SEQ"
ZBUILD_STAGE_IO_FD=3 \
ZBUILD_TERM_WIDTH_OVERRIDE=100 \
ZBUILD_STAGE_IO_NOW_MS_OVERRIDE=12346000 \
    stage_io_end --stage plan --kind llm --seq "$seq_v" \
        --output "RESP" --duration-ms 1000 >/dev/null
exec 3>&-
banner="$(cat "$fd3")"

input_header="$(printf '%s\n' "$banner" | grep -m1 'input' || true)"
output_header="$(printf '%s\n' "$banner" | grep -m1 'output OK' || true)"
assert_contains "L2 back-compat: input header is seq=1"  "$input_header"  "seq=1 input"
assert_contains "L2 back-compat: output header is seq=1" "$output_header" "seq=1 output OK"

# ─── L3: env-var fallback ZBUILD_STAGE_IO_SEQ_LABEL also works ───────────────
# (Used by orchestrator/runner to thread label through router → stage_io_begin
# without modifying every caller signature.)
_reset_pending
fd3="$TEST_TEMP_DIR/l3.fd3"
: > "$fd3"
exec 3>"$fd3"
ZBUILD_STAGE_IO_FD=3 \
ZBUILD_TERM_WIDTH_OVERRIDE=100 \
ZBUILD_STAGE_IO_NOW_MS_OVERRIDE=12345000 \
ZBUILD_STAGE_IO_SEQ_LABEL="3.1" \
    stage_io_begin --stage test --kind llm --input "PROMPT" >/dev/null
seq_v="$_STAGE_IO_LAST_SEQ"
ZBUILD_STAGE_IO_FD=3 \
ZBUILD_TERM_WIDTH_OVERRIDE=100 \
ZBUILD_STAGE_IO_NOW_MS_OVERRIDE=12346000 \
ZBUILD_STAGE_IO_SEQ_LABEL="3.1" \
    stage_io_end --stage test --kind llm --seq "$seq_v" \
        --output "RESP" --duration-ms 1000 >/dev/null
exec 3>&-
banner="$(cat "$fd3")"
input_header="$(printf '%s\n' "$banner" | grep -m1 'input' || true)"
output_header="$(printf '%s\n' "$banner" | grep -m1 'output OK' || true)"
assert_contains "L3 env-var fallback: input header uses seq=3.1"  "$input_header"  "seq=3.1 input"
assert_contains "L3 env-var fallback: output header uses seq=3.1" "$output_header" "seq=3.1 output OK"

# ─── L4: explicit --seq-label overrides env-var fallback ─────────────────────
_reset_pending
fd3="$TEST_TEMP_DIR/l4.fd3"
: > "$fd3"
exec 3>"$fd3"
ZBUILD_STAGE_IO_FD=3 \
ZBUILD_TERM_WIDTH_OVERRIDE=100 \
ZBUILD_STAGE_IO_NOW_MS_OVERRIDE=12345000 \
ZBUILD_STAGE_IO_SEQ_LABEL="99.99" \
    stage_io_begin --stage review --kind llm --input "PROMPT" \
        --seq-label "4" >/dev/null
seq_v="$_STAGE_IO_LAST_SEQ"
exec 3>&-
banner="$(cat "$fd3")"
input_header="$(printf '%s\n' "$banner" | grep -m1 'input' || true)"
assert_contains "L4 explicit --seq-label wins over env" "$input_header" "seq=4 input"

# ─── L5: Wave 19-B — recursive prefix labels render verbatim ─────────────────
# When ZBUILD_SEQ_PREFIX accumulates through nested cycles, the orchestrator
# computes labels with arbitrary depth ("3.1.1.1.1" for 2-level nest,
# "3.1.1.1.1.1.1" for 3-level). stage_io_begin must render WHATEVER it gets —
# no parsing, no truncation, no segment-count assumption.
_reset_pending
fd3="$TEST_TEMP_DIR/l5.fd3"
: > "$fd3"
exec 3>"$fd3"
ZBUILD_STAGE_IO_FD=3 \
ZBUILD_TERM_WIDTH_OVERRIDE=120 \
ZBUILD_STAGE_IO_NOW_MS_OVERRIDE=12345000 \
    stage_io_begin --stage build --kind llm --input "PROMPT" \
        --seq-label "3.1.1.1.1" >/dev/null
seq_v="$_STAGE_IO_LAST_SEQ"
ZBUILD_STAGE_IO_FD=3 \
ZBUILD_TERM_WIDTH_OVERRIDE=120 \
ZBUILD_STAGE_IO_NOW_MS_OVERRIDE=12346000 \
    stage_io_end --stage build --kind llm --seq "$seq_v" \
        --output "RESP" --duration-ms 1000 >/dev/null
exec 3>&-
banner="$(cat "$fd3")"
input_header="$(printf '%s\n' "$banner" | grep -m1 'input' || true)"
output_header="$(printf '%s\n' "$banner" | grep -m1 'output OK' || true)"
assert_contains "L5 (Wave 19-B) 5-segment label renders verbatim (input)" \
    "$input_header" "seq=3.1.1.1.1 input"
assert_contains "L5 (Wave 19-B) 5-segment label renders verbatim (output)" \
    "$output_header" "seq=3.1.1.1.1 output OK"

# ─── L6: Wave 19-B — 7-segment (3-level nest) label renders verbatim ─────────
_reset_pending
fd3="$TEST_TEMP_DIR/l6.fd3"
: > "$fd3"
exec 3>"$fd3"
ZBUILD_STAGE_IO_FD=3 \
ZBUILD_TERM_WIDTH_OVERRIDE=120 \
ZBUILD_STAGE_IO_NOW_MS_OVERRIDE=12345000 \
    stage_io_begin --stage build --kind llm --input "PROMPT" \
        --seq-label "3.1.1.1.1.1.1" >/dev/null
seq_v="$_STAGE_IO_LAST_SEQ"
ZBUILD_STAGE_IO_FD=3 \
ZBUILD_TERM_WIDTH_OVERRIDE=120 \
ZBUILD_STAGE_IO_NOW_MS_OVERRIDE=12346000 \
    stage_io_end --stage build --kind llm --seq "$seq_v" \
        --output "RESP" --duration-ms 1000 >/dev/null
exec 3>&-
banner="$(cat "$fd3")"
input_header="$(printf '%s\n' "$banner" | grep -m1 'input' || true)"
assert_contains "L6 (Wave 19-B) 7-segment label renders verbatim" \
    "$input_header" "seq=3.1.1.1.1.1.1 input"

# Clear pending state before cleanup so the EXIT orphan-finalizer doesn't
# recreate $TEST_TEMP_DIR / write partial artifacts after cleanup_test_env
# has wiped it. L4 intentionally skips stage_io_end to validate flag wins
# over env at begin-time; we drain pending here instead of pairing.
_reset_pending

print_test_results
cleanup_test_env
