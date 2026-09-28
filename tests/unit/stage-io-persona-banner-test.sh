#!/usr/bin/env bash
# Tests: core/output/stage-io.sh — ZBUILD_STAGE_IO_PERSONA banner rendering
#
# Covers:
#   P1: ZBUILD_STAGE_IO_PERSONA=<id> → INPUT banner contains "persona: <id>"
#   P2: ZBUILD_STAGE_IO_PERSONA=<id>:fallback → INPUT banner contains "persona: none (fallback)"
#   P3: ZBUILD_STAGE_IO_PERSONA unset → INPUT banner contains no "persona:" line
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

export FORCE_COLOR=1
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/output/stage-io — ZBUILD_STAGE_IO_PERSONA banner"
setup_test_env "stage-io-persona-banner"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="persona-banner-test"
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

# ─── P1: ZBUILD_STAGE_IO_PERSONA=plan-writer → "persona: plan-writer" in banner ─
_reset_pending
fd3_p1="$TEST_TEMP_DIR/p1.fd3"
: > "$fd3_p1"
exec 3>"$fd3_p1"
ZBUILD_STAGE_IO_FD=3 ZBUILD_STAGE_IO_PERSONA=plan-writer \
ZBUILD_TERM_WIDTH_OVERRIDE=100 \
    stage_io_begin --stage plan --kind llm --input "PROMPT" >/dev/null
ZBUILD_STAGE_IO_FD=3 ZBUILD_STAGE_IO_PERSONA=plan-writer \
ZBUILD_TERM_WIDTH_OVERRIDE=100 \
    stage_io_end --stage plan --kind llm --seq "$_STAGE_IO_LAST_SEQ" \
        --output "RESP" --duration-ms 100 >/dev/null
exec 3>&-
banner_p1="$(cat "$fd3_p1")"
assert_contains "P1 [SPEC-4] persona id rendered in INPUT banner" "$banner_p1" "persona: plan-writer"

# ─── P2: ZBUILD_STAGE_IO_PERSONA=plan-writer:fallback → "persona: none (fallback)"
_reset_pending
fd3_p2="$TEST_TEMP_DIR/p2.fd3"
: > "$fd3_p2"
exec 3>"$fd3_p2"
ZBUILD_STAGE_IO_FD=3 ZBUILD_STAGE_IO_PERSONA=plan-writer:fallback \
ZBUILD_TERM_WIDTH_OVERRIDE=100 \
    stage_io_begin --stage plan --kind llm --input "PROMPT" >/dev/null
ZBUILD_STAGE_IO_FD=3 ZBUILD_STAGE_IO_PERSONA=plan-writer:fallback \
ZBUILD_TERM_WIDTH_OVERRIDE=100 \
    stage_io_end --stage plan --kind llm --seq "$_STAGE_IO_LAST_SEQ" \
        --output "RESP" --duration-ms 100 >/dev/null
exec 3>&-
banner_p2="$(cat "$fd3_p2")"
assert_contains "P2 [SPEC-5] fallback persona renders as none (fallback)" "$banner_p2" "persona: none (fallback)"

# ─── P3: ZBUILD_STAGE_IO_PERSONA unset → no "persona:" line in banner ──────────
_reset_pending
fd3_p3="$TEST_TEMP_DIR/p3.fd3"
: > "$fd3_p3"
exec 3>"$fd3_p3"
unset ZBUILD_STAGE_IO_PERSONA
ZBUILD_STAGE_IO_FD=3 ZBUILD_TERM_WIDTH_OVERRIDE=100 \
    stage_io_begin --stage plan --kind llm --input "PROMPT" >/dev/null
ZBUILD_STAGE_IO_FD=3 ZBUILD_TERM_WIDTH_OVERRIDE=100 \
    stage_io_end --stage plan --kind llm --seq "$_STAGE_IO_LAST_SEQ" \
        --output "RESP" --duration-ms 100 >/dev/null
exec 3>&-
banner_p3="$(cat "$fd3_p3")"
if grep -q "^persona:" <<< "$banner_p3"; then
    assert_fail "P3 [SPEC-6] no persona: line when ZBUILD_STAGE_IO_PERSONA unset" "found in: $banner_p3"
else
    assert_pass "P3 [SPEC-6] no persona: line when ZBUILD_STAGE_IO_PERSONA unset"
fi

cleanup_test_env
print_test_results
exit "$FAIL"
