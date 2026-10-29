#!/usr/bin/env bash
# Tests: a stage's input and output are recorded whatever their size
# (ADR-015). On #1801 and #1944 (2026-10-28) a lens prompt of ~115 KB made
# stage_io_end fail with "jq: Argument list too long": the record was built by
# handing the whole input and output to jq as command-line arguments, which the
# OS caps (128 KB per argument on Linux, 1 MB in all on macOS). The record was
# lost and nothing said so.
#
# L1 a stage whose input and output are each 700 KB gets its record, whole
# L2 a stage that never reached its end leaves a partial record with its
#    whole input (1.1 MB)
# L3 when a temp file cannot be made, the end fails and leaves none behind
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "stage-io — a record is kept whatever its size (ADR-015)"
setup_test_env "stage-io-large"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="test-run-stage-io-large"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR"

# shellcheck source=../../core/output/stage-io.sh
source "$REPO_ROOT/core/output/stage-io.sh"
template_stage_io_dests()      { printf 'file\n'; }
template_stage_io_tail_lines() { printf ''; }
template_stage_io_redact()     { printf ''; }

# 700 KB each: over Linux's per-argument cap, and the two together over
# macOS's whole-command cap.
big_in="$(head -c 700000 /dev/zero | tr '\0' 'i')"
big_out="$(head -c 700000 /dev/zero | tr '\0' 'o')"
IO_DIR="$ZBUILD_STATE_DIR/artifacts/stage-io"

# ─── L1: begin + end ─────────────────────────────────────────────────────────
print_test_section "L1: a 700 KB input and output are recorded"
stage_io_begin --kind llm --stage big --input "$big_in" >/dev/null 2>&1
seq="$_STAGE_IO_LAST_SEQ"
rc=0
stage_io_end --stage big --kind llm --seq "$seq" --output "$big_out" --exit-code 0 \
    >/dev/null 2>"$TEST_TEMP_DIR/l1.err" || rc=$?
assert_eq "[L1] stage_io_end succeeds" "0" "$rc"
assert_eq "[L1] ...and says nothing is wrong" "" "$(cat "$TEST_TEMP_DIR/l1.err")"
rec="$IO_DIR/big-${seq}.json"
assert_eq "[L1] the record holds the whole input" "700000" "$(jq -r '.input | length' "$rec" 2>/dev/null || echo none)"
assert_eq "[L1] ...and the whole output" "700000" "$(jq -r '.output | length' "$rec" 2>/dev/null || echo none)"

# ─── L2: begin with no end — the orphan record ───────────────────────────────
print_test_section "L2: a stage cut off before its end keeps its whole input"
# A fresh bash, as a plugin's process is: the finalizer is its EXIT trap.
# 1.1 MB: one argument this size is over the cap on macOS as well as Linux.
big_cut="$(head -c 1100000 /dev/zero | tr '\0' 'c')"
bash -c '
    source "$1/scripts/lib/helpers.sh"; source "$1/core/output/stage-io.sh"
    template_stage_io_dests() { printf "file\n"; }
    template_stage_io_tail_lines() { :; }; template_stage_io_redact() { :; }
    stage_io_begin --kind llm --stage cutoff --input "$(cat "$2")" >/dev/null 2>&1
    printf "%s" "$_STAGE_IO_LAST_SEQ" > "$3"
' _ "$REPO_ROOT" <(printf '%s' "$big_cut") "$TEST_TEMP_DIR/l2.seq" 2>/dev/null
seq2="$(cat "$TEST_TEMP_DIR/l2.seq")"
assert_eq "[L2] the partial record holds the whole input" "1100000" \
    "$(jq -r '.input | length' "$IO_DIR/cutoff-${seq2}.partial.json" 2>/dev/null || echo none)"

# ─── L3: the second temp file cannot be made ─────────────────────────────────
print_test_section "L3: a failed temp file leaves none behind"
L3_TMP="$TEST_TEMP_DIR/l3-tmp"; mkdir -p "$L3_TMP"
stage_io_begin --kind llm --stage tmpfail --input "small" >/dev/null 2>&1
seq3="$_STAGE_IO_LAST_SEQ"
# The first mktemp succeeds, the second fails. Counted in a file: each call
# runs in a $( ) subshell.
_mk_count="$TEST_TEMP_DIR/l3-mktemp-calls"; : > "$_mk_count"
# shellcheck disable=SC2329
mktemp() { printf 'x' >> "$_mk_count"; [[ $(wc -c < "$_mk_count") -ge 2 ]] && return 1; command mktemp "$@"; }
rc=0
TMPDIR="$L3_TMP" stage_io_end --stage tmpfail --kind llm --seq "$seq3" --output "o" >/dev/null 2>&1 || rc=$?
unset -f mktemp
assert_eq "[L3] the end fails" "2" "$rc"
assert_eq "[L3] ...and leaves no temp file" "" "$(ls -A "$L3_TMP")"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
