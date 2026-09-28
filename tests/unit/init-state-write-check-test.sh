#!/usr/bin/env bash
# Tests: #1773 — init_state must check its state-file write.
#
# The ADR-006 resume contract's origin point is `init_state`. Before #1773 it
# piped jq into atomic_write and checked nothing, then fell through to
# emit_event (which always returns 0) — so a refused write produced a run with
# no persisted state, no diagnostic, and rc=0.
#
# SPEC-1[change]: a refused atomic_write makes init_state fail with a diagnostic.
# SPEC-2[change]: pipeline.init is NOT emitted when the state file was not written.
# SPEC-3[change]: atomic_write drains stdin before refusing, so its producer's
#                 status is uniformly 0 and atomic_write's own rc is the signal
#                 — independent of payload size relative to the pipe buffer.
# SPEC-4[guard]:  a normal init is unchanged (rc=0, valid JSON, pipeline.init).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/state/resume.sh
source "$REPO_ROOT/core/state/resume.sh"

print_test_header "init_state write-failure check (#1773)"

setup_test_env "init-state-write-check"

EVENT_LOG="$TEST_TEMP_DIR/emitted-events.txt"
: > "$EVENT_LOG"

# Capture emits instead of writing to the real bus — the assertion is about
# whether pipeline.init is reached at all.
emit_event() {
    printf '%s\n' "$1" >> "$EVENT_LOG"
    return 0
}

# ─── SPEC-4[guard]: normal init is unchanged ────────────────────────────────
GOOD_STATE="$TEST_TEMP_DIR/good/pipeline-state.json"
good_rc=0
init_state "$GOOD_STATE" "run-ok" 1773 >/dev/null 2>&1 || good_rc=$?
assert_eq "SPEC-4: normal init_state returns 0" "0" "$good_rc"
assert_file_exists "SPEC-4: normal init_state writes the state file" "$GOOD_STATE"
assert_eq "SPEC-4: normal init_state writes valid schema_version" "1" \
    "$(jq -r .schema_version "$GOOD_STATE")"
assert_eq "SPEC-4: normal init_state records the issue" "1773" \
    "$(jq -r .issue "$GOOD_STATE")"
assert_contains "SPEC-4: normal init_state emits pipeline.init" \
    "$(cat "$EVENT_LOG")" "pipeline.init"

# ─── SPEC-1 / SPEC-2: a refused write must fail, and must not emit ──────────
: > "$EVENT_LOG"
_REAL_ATOMIC_WRITE_DEF="$(declare -f atomic_write)"
# Simulate the refusal exactly as atomic_write now behaves: consume stdin
# (so the producer exits 0), write nothing, return 1.
atomic_write() { cat > /dev/null; return 1; }

BAD_STATE="$TEST_TEMP_DIR/bad/pipeline-state.json"
bad_rc=0
bad_err="$(init_state "$BAD_STATE" "run-refused" 1773 2>&1 >/dev/null)" || bad_rc=$?

assert_gt "SPEC-1: init_state fails when the state write is refused" "$bad_rc" "0"
assert_contains "SPEC-1: init_state explains the failure" "$bad_err" "$BAD_STATE"
assert_contains "SPEC-1: diagnostic names the stateless-run consequence" \
    "$bad_err" "resume"
assert_file_not_exists "SPEC-1: no state file is left behind" "$BAD_STATE"
assert_eq "SPEC-2: pipeline.init is not emitted when the write was refused" \
    "" "$(cat "$EVENT_LOG")"

eval "$_REAL_ATOMIC_WRITE_DEF"

# ─── SPEC-3: atomic_write drains stdin before refusing ──────────────────────
# Shadow df so the disk-space precheck refuses. Field 4 of the last line is
# what atomic_write reads as free MB.
df() { printf 'Filesystem 1M-blocks Used Avail Capacity Mounted\n/dev/fake 100 99 1 99%% /\n'; }

DRAIN_TARGET="$TEST_TEMP_DIR/drain/out.json"
mkdir -p "$(dirname "$DRAIN_TARGET")"

# A payload far larger than any pipe buffer (64KB on macOS, 64KB on Linux).
BIG_PAYLOAD="$TEST_TEMP_DIR/big.txt"
head -c 524288 /dev/zero | tr '\0' 'x' > "$BIG_PAYLOAD"

set +e
cat "$BIG_PAYLOAD" | atomic_write "$DRAIN_TARGET" 2>/dev/null
# Snapshot the whole array in one assignment — reading PIPESTATUS[0] into a
# variable would itself reset PIPESTATUS before [1] could be read.
drain_pipes=("${PIPESTATUS[@]}")
set -e
drain_producer_rc="${drain_pipes[0]}"
drain_writer_rc="${drain_pipes[1]}"

assert_eq "SPEC-3: producer exits 0 even for a payload larger than the pipe buffer" \
    "0" "$drain_producer_rc"
assert_eq "SPEC-3: atomic_write reports the refusal in its own rc" \
    "1" "$drain_writer_rc"
assert_file_not_exists "SPEC-3: refused atomic_write leaves no target file" "$DRAIN_TARGET"

# Same refusal with a tiny payload — the rc must not depend on payload size.
set +e
printf '{"a":1}' | atomic_write "$DRAIN_TARGET" 2>/dev/null
small_pipes=("${PIPESTATUS[@]}")
set -e
small_producer_rc="${small_pipes[0]}"
small_writer_rc="${small_pipes[1]}"
assert_eq "SPEC-3: small-payload producer rc matches the large-payload case" \
    "$drain_producer_rc" "$small_producer_rc"
assert_eq "SPEC-3: small-payload writer rc matches the large-payload case" \
    "$drain_writer_rc" "$small_writer_rc"

unset -f df

cleanup_test_env
print_test_results
exit $((FAIL > 0))
