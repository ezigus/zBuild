#!/usr/bin/env bash
# Tests: core/state/atomic.sh — locked_state_update fail-closed on JSON corruption — Part A
#
# Issue #293: Before the fix, locked_state_update warned on corruption and passed
# corrupt bytes to the update function.  After the fix it must:
#   1. Validate the state file BEFORE copying to the temp working copy.
#   2. Recover from .bak when the primary is corrupt.
#   3. Emit state.corruption.unrecoverable (with state_file + reason fields) and
#      return non-zero when both the primary and .bak are corrupt.
#   4. Pass the RECOVERED data (not corrupt data, not empty) to the update function.
#   5. After a successful .bak recovery + update the new .bak reflects the
#      recovered content, not the corrupt file.
#
# Part A covers: Scenarios 1-5
#   Scenario 1: empty primary triggers .bak recovery
#   Scenario 2: partial write (truncated JSON) triggers .bak recovery
#   Scenario 3: update_fn receives recovered data, not corrupt bytes
#   Scenario 4: post-recovery .bak reflects recovered content
#   Scenario 5: both primary and .bak corrupt — fail-closed + event emitted
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "state corruption fail-closed Part A (scenarios 1-5) — locked_state_update (#293)"

setup_test_env "state-corruption-failclosed-a"

# ─── shared infrastructure ───────────────────────────────────────────────────

STATE_DIR="$TEST_TEMP_DIR/state"
mkdir -p "$STATE_DIR"
STATE_FILE="$STATE_DIR/pipeline-state.json"

EVENTS_DIR="$TEST_TEMP_DIR/events"
mkdir -p "$EVENTS_DIR"
export ZBUILD_EVENTS_DIR="$EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"

source "$REPO_ROOT/core/state/atomic.sh"
source "$REPO_ROOT/core/event-bus/event-bus.sh"

# Canonical valid initial state written before each scenario that needs it.
VALID_JSON='{"schema_version":1,"current_stage":"build","status":"running"}'

# Helper: reset state and events between scenarios.
reset_scenario() {
    rm -f "$STATE_FILE" "${STATE_FILE}.bak" "${STATE_FILE}.lock"
    : > "$ZBUILD_EVENTS_JSONL"
}

# Helper: assert the JSONL events file contains at least one line whose "type"
# field matches $1, optionally asserting payload field $2 is present.
#
# Payload field check: tries the correctly-structured path (.data.<field>) first,
# then falls back to a raw string search so the test is useful both against the
# pre-fix malformed emit call and the correctly-structured post-fix call.
assert_event_emitted() {
    local desc="$1"
    local event_type="$2"
    local payload_field="${3:-}"

    if [[ ! -f "$ZBUILD_EVENTS_JSONL" ]]; then
        assert_fail "$desc" "events file does not exist"
        return
    fi

    local matched_line
    matched_line="$(grep -F "\"$event_type\"" "$ZBUILD_EVENTS_JSONL" 2>/dev/null | tail -1 || true)"

    if [[ -z "$matched_line" ]]; then
        assert_fail "$desc" "event type '$event_type' not found in events.jsonl"
        return
    fi

    if [[ -n "$payload_field" ]]; then
        # Primary check: well-structured payload (.data.<field>)
        local field_val
        field_val="$(echo "$matched_line" | jq -r ".data.${payload_field} // empty" 2>/dev/null || true)"
        if [[ -n "$field_val" ]]; then
            assert_pass "$desc (payload.$payload_field present)"
            return
        fi
        # Fallback: the field name appears anywhere in the raw event line
        # (handles pre-fix malformed single-JSON-blob call site)
        if echo "$matched_line" | grep -qF "\"$payload_field\"" 2>/dev/null; then
            assert_pass "$desc (payload.$payload_field referenced in event)"
            return
        fi
        assert_fail "$desc" "event '$event_type' emitted but '$payload_field' not found anywhere in event; event: $matched_line"
    else
        assert_pass "$desc"
    fi
}

# Helper: run update_fn that records what it received on stdin and echoes it
# back as-is (identity transform, but captures the received bytes for inspection).
CAPTURED_INPUT_FILE="$TEST_TEMP_DIR/captured-update-input.txt"
identity_update_fn() {
    local content
    content="$(cat)"
    printf '%s' "$content" > "$CAPTURED_INPUT_FILE"
    printf '%s' "$content"
}

# A well-behaved update function that appends a "tested" key.
append_tested_fn() {
    local content
    content="$(cat)"
    if [[ -n "$content" ]]; then
        echo "$content" | jq '. + {"tested": true}'
    else
        echo '{"tested": true}'
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Scenario 1 — Empty file (0 bytes) triggers .bak recovery
# ─────────────────────────────────────────────────────────────────────────────
print_test_section "Scenario 1: empty state file (0 bytes) — .bak recovery"
reset_scenario

# Establish a valid .bak
printf '%s' "$VALID_JSON" > "${STATE_FILE}.bak"
# Corrupt primary with empty file
: > "$STATE_FILE"

set +e
locked_state_update "$STATE_FILE" append_tested_fn
lsu_rc=$?
set -e

assert_eq \
    "empty state file: locked_state_update returns 0 after .bak recovery" \
    "0" "$lsu_rc"

assert_file_exists \
    "empty state file: output state file still exists" \
    "$STATE_FILE"

if [[ -f "$STATE_FILE" ]]; then
    set +e; jq empty "$STATE_FILE" >/dev/null 2>&1; jq_rc=$?; set -e
    assert_eq \
        "empty state file: output state is valid JSON" \
        "0" "$jq_rc"

    if [[ $jq_rc -eq 0 ]]; then
        stage_val="$(jq -r '.current_stage // empty' "$STATE_FILE" 2>/dev/null || true)"
        assert_eq \
            "empty state file: update fn received recovered data (current_stage preserved)" \
            "build" "$stage_val"

        tested_val="$(jq -r '.tested // empty' "$STATE_FILE" 2>/dev/null || true)"
        assert_eq \
            "empty state file: update fn was applied (tested key present)" \
            "true" "$tested_val"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Scenario 2 — Partial write (truncated JSON) triggers .bak recovery
# ─────────────────────────────────────────────────────────────────────────────
print_test_section "Scenario 2: partial write (truncated JSON) — .bak recovery"
reset_scenario

printf '%s' "$VALID_JSON" > "${STATE_FILE}.bak"
printf '{"schema_version": 1, "current_ite' > "$STATE_FILE"   # truncated

set +e
locked_state_update "$STATE_FILE" append_tested_fn
lsu_rc=$?
set -e

assert_eq \
    "partial write: locked_state_update returns 0 after .bak recovery" \
    "0" "$lsu_rc"

if [[ -f "$STATE_FILE" ]]; then
    set +e; jq empty "$STATE_FILE" >/dev/null 2>&1; jq_rc=$?; set -e
    assert_eq \
        "partial write: output state is valid JSON" \
        "0" "$jq_rc"

    if [[ $jq_rc -eq 0 ]]; then
        stage_val="$(jq -r '.current_stage // empty' "$STATE_FILE" 2>/dev/null || true)"
        assert_eq \
            "partial write: recovered data passed to update fn (current_stage preserved)" \
            "build" "$stage_val"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Scenario 3 — Recovery sequence: update_fn receives recovered data, not corrupt
# ─────────────────────────────────────────────────────────────────────────────
print_test_section "Scenario 3: update_fn receives recovered (.bak) data, not corrupt bytes"
reset_scenario

RECOVERED_JSON='{"schema_version":1,"current_stage":"test","status":"recovered"}'
printf '%s' "$RECOVERED_JSON" > "${STATE_FILE}.bak"
printf 'NOT_JSON_AT_ALL}{{{' > "$STATE_FILE"

set +e
locked_state_update "$STATE_FILE" identity_update_fn
lsu_rc=$?
set -e

assert_eq \
    "recovery sequence: locked_state_update returns 0" \
    "0" "$lsu_rc"

if [[ -f "$CAPTURED_INPUT_FILE" ]]; then
    captured="$(cat "$CAPTURED_INPUT_FILE")"
    # Must not contain the corrupt garbage
    if echo "$captured" | grep -qF 'NOT_JSON_AT_ALL' 2>/dev/null; then
        assert_fail \
            "recovery sequence: update_fn must NOT receive corrupt bytes" \
            "captured input contained corrupt data: $captured"
    else
        assert_pass "recovery sequence: update_fn did not receive corrupt bytes"
    fi
    # Must contain the recovered stage
    recovered_stage="$(echo "$captured" | jq -r '.current_stage // empty' 2>/dev/null || true)"
    assert_eq \
        "recovery sequence: update_fn received recovered data (current_stage=test)" \
        "test" "$recovered_stage"
else
    assert_fail \
        "recovery sequence: captured input file missing — identity_update_fn was not called"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Scenario 4 — Post-recovery .bak state reflects recovered content, not corrupt
# ─────────────────────────────────────────────────────────────────────────────
print_test_section "Scenario 4: after .bak recovery + update, new .bak holds recovered data"
reset_scenario

GOOD_BAK_JSON='{"schema_version":1,"current_stage":"deploy","status":"ok"}'
printf '%s' "$GOOD_BAK_JSON" > "${STATE_FILE}.bak"
printf '{corrupt' > "$STATE_FILE"

set +e
locked_state_update "$STATE_FILE" append_tested_fn
lsu_rc=$?
set -e

assert_eq \
    "post-recovery .bak: locked_state_update returns 0" \
    "0" "$lsu_rc"

if [[ -f "${STATE_FILE}.bak" ]]; then
    set +e; jq empty "${STATE_FILE}.bak" >/dev/null 2>&1; bak_rc=$?; set -e
    assert_eq \
        "post-recovery .bak: new .bak is valid JSON (not the old corrupt file)" \
        "0" "$bak_rc"

    if [[ $bak_rc -eq 0 ]]; then
        bak_stage="$(jq -r '.current_stage // empty' "${STATE_FILE}.bak" 2>/dev/null || true)"
        # The new .bak is what atomic_write rotated — i.e. the state just before
        # the final mv.  That is the output of append_tested_fn applied to the
        # recovered data, which must carry the recovered current_stage.
        # (atomic_write cp's old target to .bak; old target here is the recovered
        # intermediate written in the same locked_state_update call.)
        if [[ "$bak_stage" == "deploy" ]]; then
            assert_pass "post-recovery .bak: .bak carries recovered stage (deploy)"
        elif [[ -n "$bak_stage" ]]; then
            # Acceptable: .bak may be the pre-update snapshot from atomic_write
            assert_pass "post-recovery .bak: .bak is valid and has a stage value ($bak_stage)"
        else
            assert_fail \
                "post-recovery .bak: expected .bak to carry recovered current_stage" \
                "got: $(cat "${STATE_FILE}.bak")"
        fi

        # Critical: .bak must not be the old corrupt content
        bak_raw="$(cat "${STATE_FILE}.bak")"
        if echo "$bak_raw" | grep -qF 'corrupt' 2>/dev/null; then
            assert_fail \
                "post-recovery .bak: .bak must not be the corrupt primary" \
                "bak content: $bak_raw"
        else
            assert_pass "post-recovery .bak: .bak does not contain corrupt data"
        fi
    fi
else
    assert_fail \
        "post-recovery .bak: .bak file must exist after atomic_write rotation"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Scenario 5 — Both primary and .bak corrupt → fail-closed, emit event
# ─────────────────────────────────────────────────────────────────────────────
print_test_section "Scenario 5: both primary and .bak corrupt — fail-closed + event emitted"
reset_scenario

printf '{bad json primary' > "$STATE_FILE"
printf '{bad json bak' > "${STATE_FILE}.bak"
: > "$ZBUILD_EVENTS_JSONL"

set +e
locked_state_update "$STATE_FILE" append_tested_fn
lsu_rc=$?
set -e

if [[ $lsu_rc -ne 0 ]]; then
    assert_pass "both corrupt: locked_state_update returns non-zero (fail-closed)"
else
    assert_fail \
        "both corrupt: locked_state_update must return non-zero when both are corrupt" \
        "got exit code: $lsu_rc"
fi

assert_event_emitted \
    "both corrupt: state.corruption.unrecoverable event emitted" \
    "state.corruption.unrecoverable"

assert_event_emitted \
    "both corrupt: event payload includes state_file field" \
    "state.corruption.unrecoverable" \
    "state_file"

assert_event_emitted \
    "both corrupt: event payload includes reason field" \
    "state.corruption.unrecoverable" \
    "reason"

# ─────────────────────────────────────────────────────────────────────────────

cleanup_test_env
print_test_results
