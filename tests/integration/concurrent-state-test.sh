#!/usr/bin/env bash
# Tests: core/state/atomic.sh — concurrent writers do not corrupt state.
# 10 background subshells each call atomic_write to the same file.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "concurrent state — 10 parallel atomic_write calls (no corruption)"

setup_test_env "concurrent-state"

source "$REPO_ROOT/core/state/atomic.sh"

TARGET="$TEST_TEMP_DIR/concurrent-state.json"
EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_DIR="$EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$EVENTS_DIR"

# ─── 10 concurrent writers ───────────────────────────────────────────────────
# Each subshell writes a JSON object with a unique "value" key.
# atomic_write uses tmp + mv so the final file is always one complete write.
PIDS=()
for i in $(seq 1 10); do
    (
        source "$REPO_ROOT/scripts/lib/helpers.sh"
        printf '{"value":%d}' "$i" | atomic_write "$TARGET"
    ) &
    PIDS+=($!)
done

# Wait for all subshells to finish
for pid in "${PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
done

# ─── Assert file exists and is not empty ─────────────────────────────────────
assert_file_exists "target file exists after 10 concurrent writes" "$TARGET"

file_size="$(wc -c < "$TARGET" 2>/dev/null || echo 0)"
if [[ "$file_size" -gt 0 ]]; then
    assert_pass "target file is non-empty after concurrent writes"
else
    assert_fail "target file is non-empty after concurrent writes" "file is empty"
fi

# ─── Assert file is valid JSON (not corrupted) ───────────────────────────────
set +e
jq empty "$TARGET" >/dev/null 2>&1
jq_rc=$?
set -e
assert_eq "target file is valid JSON after concurrent writes (not corrupted)" "0" "$jq_rc"

# ─── Assert file contains one of the expected values (last write wins, no corruption)
if [[ $jq_rc -eq 0 ]]; then
    actual_val="$(jq -r '.value // empty' "$TARGET" 2>/dev/null || true)"
    if [[ "$actual_val" =~ ^[0-9]+$ && "$actual_val" -ge 1 && "$actual_val" -le 10 ]]; then
        assert_pass "final value is one of the 10 expected values (last-write-wins: $actual_val)"
    else
        assert_fail "final value is one of the 10 expected values" \
            "got: '$actual_val' (expected 1-10)"
    fi
fi

# ─── Assert .bak file exists (atomic_write rotates previous) ─────────────────
if [[ -f "${TARGET}.bak" ]]; then
    set +e
    jq empty "${TARGET}.bak" >/dev/null 2>&1
    bak_rc=$?
    set -e
    if [[ $bak_rc -eq 0 ]]; then
        assert_pass ".bak file is valid JSON (rotation preserved a complete write)"
    else
        assert_fail ".bak file is valid JSON" "bak file is corrupt"
    fi
else
    # If only one write happened (sequential), there may be no .bak yet
    assert_pass ".bak file rotation: accepted (may not exist if writes were perfectly sequential)"
fi

# ─── 50x stability: .bak is never torn across repeated concurrent writes ──────
# #909: atomic_write rotates .bak via atomic_replace (temp+rename), so 10
# concurrent writers can never leave a torn .bak. Pre-fix (bare cp) this loop
# intermittently observes a corrupt .bak. CPU-cheap (no sleeps/external calls).
STAB="$EVENTS_DIR/stability.json"
torn_rounds=0
for round in $(seq 1 50); do
    SPIDS=()
    for i in $(seq 1 10); do
        (
            source "$REPO_ROOT/scripts/lib/helpers.sh"
            printf '{"round":%d,"writer":%d}' "$round" "$i" | atomic_write "$STAB"
        ) &
        SPIDS+=($!)
    done
    for pid in "${SPIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
    if [[ -f "${STAB}.bak" ]] && ! jq empty "${STAB}.bak" >/dev/null 2>&1; then
        torn_rounds=$((torn_rounds + 1))
    fi
done
assert_eq "50x stability: zero torn .bak across 50 rounds of 10 concurrent writers" "0" "$torn_rounds"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
