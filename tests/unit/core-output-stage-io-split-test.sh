#!/usr/bin/env bash
# Tests: core/output/stage-io.sh — stage_io_begin / stage_io_end split (#481)
#
# Covers:
#   - input banner emits via begin BEFORE output banner emits via end
#   - missing --seq on end → rc=2
#   - end without prior begin → rc=2 + stage.io.error event
#   - per-stage seq counter (plan twice, build once)
#   - capture_stage_io shim continues to work identically
#   - timing via begin's stash, ZBUILD_STAGE_IO_NOW_MS_OVERRIDE deterministic
#   - --duration-ms override beats computed
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/output/stage-io — split begin/end (ADR-015 v1 #481)"
setup_test_env "stage-io-split"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="test-run-split"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR"

# shellcheck source=../../core/output/stage-io.sh
source "$REPO_ROOT/core/output/stage-io.sh"

# Mock destination accessor — defaults to "file,stdout" so banner emits to fd 3.
_MOCK_DESTS="file
stdout"
template_stage_io_dests() {
    local _stage="$1"
    [[ -z "$_MOCK_DESTS" ]] && return 0
    printf '%s\n' "$_MOCK_DESTS"
}
template_stage_io_tail_lines() { printf ''; }
template_stage_io_redact() { printf ''; }

# Reset pending maps each test (defensive against cross-test leakage).
_reset_pending() {
    local k
    for k in "${!_STAGE_IO_PENDING[@]}";       do unset '_STAGE_IO_PENDING[$k]';       done
    for k in "${!_STAGE_IO_PENDING_INPUT[@]}"; do unset '_STAGE_IO_PENDING_INPUT[$k]'; done
    for k in "${!_STAGE_IO_PENDING_KIND[@]}";  do unset '_STAGE_IO_PENDING_KIND[$k]';  done
    for k in "${!_STAGE_IO_PENDING_DESTS[@]}"; do unset '_STAGE_IO_PENDING_DESTS[$k]'; done
    for k in "${!_STAGE_IO_START_NS[@]}";      do unset '_STAGE_IO_START_NS[$k]';      done
}

# ─── S1: stage_io_begin emits input banner only, returns seq ────────────────
rm -rf "$ZBUILD_STATE_DIR/artifacts/stage-io"
_reset_pending
s1_fd3="$TEST_TEMP_DIR/s1.fd3"
: > "$s1_fd3"
exec 3>"$s1_fd3"
ZBUILD_STAGE_IO_FD=3
# Direct call (not $()) so assoc-array side effects survive in the caller's
# shell. Read the reserved seq from _STAGE_IO_LAST_SEQ.
stage_io_begin --stage plan --kind llm --input "PROMPT_BODY" >/dev/null
s1_seq="$_STAGE_IO_LAST_SEQ"
exec 3>&-
assert_eq "S1 seq == 1 on first begin" "1" "$s1_seq"
assert_eq "S1 _STAGE_IO_LAST_SEQ matches" "1" "$_STAGE_IO_LAST_SEQ"
s1_banner="$(cat "$s1_fd3")"
assert_contains "S1 banner has input header (#523)" "$s1_banner" "plan [llm] seq=1 input"
assert_contains "S1 banner has prompt body" "$s1_banner" "PROMPT_BODY"
# No output section yet
if printf '%s' "$s1_banner" | grep -q "seq=1 output"; then
    assert_fail "S1 begin must NOT emit output banner" "got: $s1_banner"
else
    assert_pass "S1 begin does NOT emit output banner"
fi
# No end-trailer yet
if printf '%s' "$s1_banner" | grep -q "end stage-io"; then
    assert_fail "S1 begin must NOT emit end-trailer" "got: $s1_banner"
else
    assert_pass "S1 begin does NOT emit end-trailer"
fi
# No file artifact yet
assert_file_not_exists "S1 no artifact until end" "$ZBUILD_STATE_DIR/artifacts/stage-io/plan-1.json"

# ─── S2: stage_io_end emits output banner + trailer, writes file ────────────
s2_fd3="$TEST_TEMP_DIR/s2.fd3"
: > "$s2_fd3"
exec 3>"$s2_fd3"
stage_io_end --stage plan --kind llm --seq 1 --output "RESPONSE_BODY" --duration-ms 1234
rc_s2=$?
exec 3>&-
assert_eq "S2 end rc=0" "0" "$rc_s2"
s2_banner="$(cat "$s2_fd3")"
assert_contains "S2 banner has output header with status+dur (#523)" "$s2_banner" "plan [llm] seq=1 output OK 1.2s"
assert_contains "S2 banner has response body" "$s2_banner" "RESPONSE_BODY"
assert_contains "S2 banner has end trailer" "$s2_banner" "end stage-io: plan"
assert_file_exists "S2 file artifact written at end" "$ZBUILD_STATE_DIR/artifacts/stage-io/plan-1.json"
s2_json="$(cat "$ZBUILD_STATE_DIR/artifacts/stage-io/plan-1.json")"
assert_json_key "S2 record input matches begin" "$s2_json" ".input" "PROMPT_BODY"
assert_json_key "S2 record output matches end"  "$s2_json" ".output" "RESPONSE_BODY"
assert_json_key "S2 record duration_ms"         "$s2_json" ".duration_ms" "1234"

# ─── S3: stage_io_end without --seq → rc=2 ──────────────────────────────────
set +e
err3="$(stage_io_end --stage plan --kind llm --output "x" 2>&1 1>/dev/null)"
rc_s3=$?
set -e
assert_eq "S3 missing --seq returns rc=2" "2" "$rc_s3"
assert_contains "S3 stderr mentions seq" "$err3" "seq"

# ─── S4: stage_io_end without prior begin → rc=2 + stage.io.error event ─────
_reset_pending
: > "$ZBUILD_EVENTS_JSONL"
set +e
stage_io_end --stage plan --kind llm --seq 99 --output "x" >/dev/null 2>&1
rc_s4=$?
set -e
assert_eq "S4 end-without-begin returns rc=2" "2" "$rc_s4"
assert_event_emitted "S4 stage.io.error emitted" "$ZBUILD_EVENTS_JSONL" "stage.io.error"
s4_evt="$(jq -c --arg t "stage.io.error" 'select(.type==$t)' "$ZBUILD_EVENTS_JSONL" | head -1)"
assert_contains "S4 event reason=end_without_begin" "$s4_evt" "end_without_begin"

# ─── S5: per-stage seq counter (plan→1, plan→2, build→1) ────────────────────
_reset_pending
rm -rf "$ZBUILD_STATE_DIR/artifacts/stage-io"
stage_io_begin --stage plan  --kind llm --input p1 >/dev/null 2>&1
s5a="$_STAGE_IO_LAST_SEQ"
stage_io_end   --stage plan  --kind llm --seq "$s5a" --output o1 --duration-ms 10 >/dev/null 2>&1
stage_io_begin --stage plan  --kind llm --input p2 >/dev/null 2>&1
s5b="$_STAGE_IO_LAST_SEQ"
stage_io_end   --stage plan  --kind llm --seq "$s5b" --output o2 --duration-ms 10 >/dev/null 2>&1
stage_io_begin --stage build --kind llm --input b1 >/dev/null 2>&1
s5c="$_STAGE_IO_LAST_SEQ"
stage_io_end   --stage build --kind llm --seq "$s5c" --output bo1 --duration-ms 10 >/dev/null 2>&1
assert_eq "S5 plan first seq == 1"  "1" "$s5a"
assert_eq "S5 plan second seq == 2" "2" "$s5b"
assert_eq "S5 build first seq == 1" "1" "$s5c"

# ─── S6: capture_stage_io shim still works (backward compat) ────────────────
_reset_pending
rm -rf "$ZBUILD_STATE_DIR/artifacts/stage-io"
: > "$ZBUILD_EVENTS_JSONL"
s6_fd3="$TEST_TEMP_DIR/s6.fd3"
: > "$s6_fd3"
exec 3>"$s6_fd3"
set +e
capture_stage_io --stage plan --kind llm --input "shim_in" --output "shim_out" \
    --duration-ms 500 --metadata "tier=T2"
rc_s6=$?
exec 3>&-
set -e
assert_eq "S6 shim rc=0" "0" "$rc_s6"
assert_file_exists "S6 shim writes file" "$ZBUILD_STATE_DIR/artifacts/stage-io/plan-1.json"
s6_banner="$(cat "$s6_fd3")"
assert_contains "S6 shim emits input banner" "$s6_banner" "seq=1 input"
assert_contains "S6 shim emits output banner" "$s6_banner" "seq=1 output OK 0.5s"
assert_contains "S6 shim emits end trailer"  "$s6_banner" "end stage-io: plan"
s6_json="$(cat "$ZBUILD_STATE_DIR/artifacts/stage-io/plan-1.json")"
assert_json_key "S6 shim record has metadata.tier" "$s6_json" ".metadata.tier" "T2"
assert_event_emitted "S6 shim emits stage.io.captured" "$ZBUILD_EVENTS_JSONL" "stage.io.captured"

# ─── S7: timing via begin stash + override env hook ─────────────────────────
_reset_pending
rm -rf "$ZBUILD_STATE_DIR/artifacts/stage-io"
# Use ZBUILD_STAGE_IO_NOW_MS_OVERRIDE to control both begin and end.
ZBUILD_STAGE_IO_NOW_MS_OVERRIDE=1000000 \
    stage_io_begin --stage plan --kind llm --input "in" >/dev/null 2>&1
s7_seq="$_STAGE_IO_LAST_SEQ"
ZBUILD_STAGE_IO_NOW_MS_OVERRIDE=1002500 \
    stage_io_end --stage plan --kind llm --seq "$s7_seq" --output "out" >/dev/null 2>&1
s7_json="$(cat "$ZBUILD_STATE_DIR/artifacts/stage-io/plan-${s7_seq}.json")"
assert_json_key "S7 computed duration_ms == 2500" "$s7_json" ".duration_ms" "2500"

# ─── S8: --duration-ms overrides computed ───────────────────────────────────
_reset_pending
rm -rf "$ZBUILD_STATE_DIR/artifacts/stage-io"
ZBUILD_STAGE_IO_NOW_MS_OVERRIDE=2000000 \
    stage_io_begin --stage plan --kind llm --input "in" >/dev/null 2>&1
s8_seq="$_STAGE_IO_LAST_SEQ"
ZBUILD_STAGE_IO_NOW_MS_OVERRIDE=2009999 \
    stage_io_end --stage plan --kind llm --seq "$s8_seq" --output "out" \
        --duration-ms 42 >/dev/null 2>&1
s8_json="$(cat "$ZBUILD_STATE_DIR/artifacts/stage-io/plan-${s8_seq}.json")"
assert_json_key "S8 --duration-ms wins over computed" "$s8_json" ".duration_ms" "42"

# ─── S9: ordering — input banner appears BEFORE any output marker ───────────
# Simulates an LLM call between begin/end by writing a MARK string to fd 3
# between the two calls.
_reset_pending
s9_fd3="$TEST_TEMP_DIR/s9.fd3"
: > "$s9_fd3"
exec 3>"$s9_fd3"
stage_io_begin --stage plan --kind llm --input "PROMPT" >/dev/null 2>&1
echo "__BETWEEN_CALL_MARK__" >&3
stage_io_end --stage plan --kind llm --seq "$_STAGE_IO_LAST_SEQ" --output "RESP" \
    --duration-ms 10 >/dev/null 2>&1
exec 3>&-
s9_content="$(cat "$s9_fd3")"
# #499: I/O banner header dividers switched from ── to ══.
s9_input_line="$(printf '%s\n' "$s9_content" | grep -n "input ══"  | head -1 | cut -d: -f1)"
s9_mark_line="$(printf '%s\n' "$s9_content"  | grep -n "__BETWEEN" | head -1 | cut -d: -f1)"
s9_output_line="$(printf '%s\n' "$s9_content" | grep -n "output OK" | head -1 | cut -d: -f1)"
if [[ -n "$s9_input_line" && -n "$s9_mark_line" && -n "$s9_output_line" \
      && "$s9_input_line" -lt "$s9_mark_line" \
      && "$s9_mark_line"  -lt "$s9_output_line" ]]; then
    assert_pass "S9 ordering: input < MARK < output"
else
    assert_fail "S9 ordering: input < MARK < output" \
        "input=$s9_input_line mark=$s9_mark_line output=$s9_output_line"
fi

# ─── S10: orphan begin → EXIT trap emits stage.io.error + partial record ────
# Run in a subshell so the EXIT trap fires there.
_reset_pending
rm -rf "$ZBUILD_STATE_DIR/artifacts/stage-io"
: > "$ZBUILD_EVENTS_JSONL"
# #491: previous test sections leaked ZBUILD_STAGE_IO_FD=3, but the subshell
# below re-sources stage-io.sh — _stage_io_validate_fd will refuse to load if
# the leaked fd isn't open. Reset to the default (fd 2) before re-source.
unset ZBUILD_STAGE_IO_FD
(
    # shellcheck source=../../core/output/stage-io.sh
    # Force a re-source so the trap installs in this subshell.
    unset _ZBUILD_STAGE_IO_LOADED _ZBUILD_STAGE_IO_TRAP_INSTALLED 2>/dev/null || true
    source "$REPO_ROOT/core/output/stage-io.sh"
    template_stage_io_dests() { printf 'file\n'; }
    template_stage_io_tail_lines() { printf ''; }
    template_stage_io_redact() { printf ''; }
    stage_io_begin --stage orphan_stage --kind llm --input "orphan_in" >/dev/null 2>&1
    # Subshell exits here without calling stage_io_end → EXIT trap fires.
) || true
assert_event_emitted "S10 EXIT trap emits stage.io.error" "$ZBUILD_EVENTS_JSONL" "stage.io.error"
s10_evt="$(jq -c --arg t "stage.io.error" 'select(.type==$t) | select(.data.reason=="output_never_emitted")' "$ZBUILD_EVENTS_JSONL" | head -1)"
assert_contains "S10 event reason=output_never_emitted" "$s10_evt" "output_never_emitted"
assert_file_exists "S10 partial record written" "$ZBUILD_STATE_DIR/artifacts/stage-io/orphan_stage-1.partial.json"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
