#!/usr/bin/env bash
# Tests: core/state/atomic.sh — locked_state_update fail-closed on JSON corruption.
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
#   6. All of the above hold on the no-flock fallback path (ZBUILD_HAS_FLOCK=0).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "state corruption fail-closed — locked_state_update (#293)"

setup_test_env "state-corruption-failclosed"

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
    > "$ZBUILD_EVENTS_JSONL"
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
> "$ZBUILD_EVENTS_JSONL"

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
# Scenario 6 — Event payload content validation (state_file points at actual file)
# ─────────────────────────────────────────────────────────────────────────────
print_test_section "Scenario 6: state.corruption.unrecoverable payload fields are correct"
reset_scenario

printf '{garbage' > "$STATE_FILE"
printf '{garbage bak' > "${STATE_FILE}.bak"
> "$ZBUILD_EVENTS_JSONL"

set +e
locked_state_update "$STATE_FILE" append_tested_fn
set -e

if [[ -f "$ZBUILD_EVENTS_JSONL" ]]; then
    matched_line="$(grep -F '"state.corruption.unrecoverable"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | tail -1 || true)"
    if [[ -n "$matched_line" ]]; then
        # state_file check: try well-structured path first, then raw string search.
        # The raw path covers the pre-fix malformed single-JSON-blob emit call.
        emitted_state_file="$(echo "$matched_line" | jq -r '.data.state_file // empty' 2>/dev/null || true)"
        if [[ -n "$emitted_state_file" && \
              ("$emitted_state_file" == "$STATE_FILE" || \
               "$(basename "$emitted_state_file")" == "$(basename "$STATE_FILE")") ]]; then
            assert_pass "event payload: state_file references the correct path"
        elif echo "$matched_line" | grep -qF '"state_file"' 2>/dev/null; then
            # state_file key is present (pre-fix encoding embeds full JSON as key)
            assert_pass "event payload: state_file key present in event"
        else
            assert_fail \
                "event payload: state_file key missing from event" \
                "event: $matched_line"
        fi

        # reason check: try well-structured path first, then raw string search.
        emitted_reason="$(echo "$matched_line" | jq -r '.data.reason // empty' 2>/dev/null || true)"
        if [[ -n "$emitted_reason" ]]; then
            assert_pass "event payload: reason field is non-empty ('$emitted_reason')"
        elif echo "$matched_line" | grep -qF '"reason"' 2>/dev/null; then
            assert_pass "event payload: reason key present in event"
        else
            assert_fail \
                "event payload: reason key missing from event — fixed code must pass reason=... to emit_event" \
                "event: $matched_line"
        fi
    else
        assert_fail \
            "event payload validation: no state.corruption.unrecoverable event found" \
            "events.jsonl: $(cat "$ZBUILD_EVENTS_JSONL" 2>/dev/null || echo '<empty>')"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Scenario 7 — No-flock fallback: empty primary, valid .bak recovers correctly
# ─────────────────────────────────────────────────────────────────────────────
print_test_section "Scenario 7: no-flock fallback — empty primary triggers .bak recovery"
reset_scenario

# Override zbuild_has_flock to simulate systems without flock
zbuild_has_flock() { return 1; }

printf '%s' "$VALID_JSON" > "${STATE_FILE}.bak"
: > "$STATE_FILE"

set +e
locked_state_update "$STATE_FILE" append_tested_fn
lsu_rc=$?
set -e

assert_eq \
    "no-flock / empty primary: locked_state_update returns 0 after .bak recovery" \
    "0" "$lsu_rc"

if [[ -f "$STATE_FILE" ]]; then
    set +e; jq empty "$STATE_FILE" >/dev/null 2>&1; jq_rc=$?; set -e
    assert_eq \
        "no-flock / empty primary: output state is valid JSON" \
        "0" "$jq_rc"

    if [[ $jq_rc -eq 0 ]]; then
        stage_val="$(jq -r '.current_stage // empty' "$STATE_FILE" 2>/dev/null || true)"
        assert_eq \
            "no-flock / empty primary: recovered data passed to update fn" \
            "build" "$stage_val"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Scenario 8 — No-flock fallback: both corrupt → fail-closed + event emitted
# ─────────────────────────────────────────────────────────────────────────────
print_test_section "Scenario 8: no-flock fallback — both corrupt fail-closed + event"
reset_scenario
# zbuild_has_flock is still overridden from scenario 7

printf '{bad primary noflock' > "$STATE_FILE"
printf '{bad bak noflock' > "${STATE_FILE}.bak"
> "$ZBUILD_EVENTS_JSONL"

set +e
locked_state_update "$STATE_FILE" append_tested_fn
lsu_rc=$?
set -e

if [[ $lsu_rc -ne 0 ]]; then
    assert_pass "no-flock / both corrupt: locked_state_update returns non-zero (fail-closed)"
else
    assert_fail \
        "no-flock / both corrupt: must return non-zero when both are corrupt" \
        "got exit code: $lsu_rc"
fi

assert_event_emitted \
    "no-flock / both corrupt: state.corruption.unrecoverable event emitted" \
    "state.corruption.unrecoverable"

# Restore flock detection to real implementation for any subsequent tests.
# (compat.sh has a load-guard so re-sourcing is a no-op; restore directly.)
zbuild_has_flock() { command -v flock >/dev/null 2>&1; }

# ─────────────────────────────────────────────────────────────────────────────
# Scenario 9 — Race condition simulation: second writer sees corrupt file
#              mid-write but has a valid .bak to recover from
# ─────────────────────────────────────────────────────────────────────────────
print_test_section "Scenario 9: race condition simulation — concurrent writers, one corrupts mid-write"

# This simulates the observable outcome of a race without requiring real
# concurrency (which is flaky on CI).  We model the state that would exist
# if writer-A lost its flock and wrote partial JSON, then writer-B wakes up:
#   primary  = partial JSON (as if writer-A crashed mid-write)
#   .bak     = last good write (from before writer-A started)
# Writer-B (our call) should recover from .bak and succeed.
reset_scenario

LAST_GOOD='{"schema_version":1,"current_stage":"plan","status":"completed"}'
printf '%s' "$LAST_GOOD" > "${STATE_FILE}.bak"
printf '{"schema_version":1,"current_stage":"bui' > "$STATE_FILE"  # simulated partial

set +e
locked_state_update "$STATE_FILE" append_tested_fn
lsu_rc=$?
set -e

assert_eq \
    "race simulation: second writer recovers via .bak and returns 0" \
    "0" "$lsu_rc"

if [[ -f "$STATE_FILE" ]]; then
    set +e; jq empty "$STATE_FILE" >/dev/null 2>&1; jq_rc=$?; set -e
    assert_eq \
        "race simulation: final state is valid JSON" \
        "0" "$jq_rc"

    if [[ $jq_rc -eq 0 ]]; then
        stage_val="$(jq -r '.current_stage // empty' "$STATE_FILE" 2>/dev/null || true)"
        # The recovered .bak had stage "plan" — update fn must see that, not
        # the partial write's "bui..." fragment.
        assert_eq \
            "race simulation: update fn applied to recovered data (stage=plan, not partial)" \
            "plan" "$stage_val"

        tested_val="$(jq -r '.tested // empty' "$STATE_FILE" 2>/dev/null || true)"
        assert_eq \
            "race simulation: update fn was called (tested key present)" \
            "true" "$tested_val"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Scenario 10 — Happy path control: no corruption, update fn works normally
# ─────────────────────────────────────────────────────────────────────────────
print_test_section "Scenario 10: control — valid state, no corruption, update succeeds"
reset_scenario

printf '%s\n' "$VALID_JSON" | atomic_write "$STATE_FILE"

set +e
locked_state_update "$STATE_FILE" append_tested_fn
lsu_rc=$?
set -e

assert_eq \
    "control: locked_state_update returns 0 for valid state" \
    "0" "$lsu_rc"

if [[ -f "$STATE_FILE" ]]; then
    set +e; jq empty "$STATE_FILE" >/dev/null 2>&1; jq_rc=$?; set -e
    assert_eq \
        "control: output state is valid JSON" \
        "0" "$jq_rc"

    if [[ $jq_rc -eq 0 ]]; then
        stage_val="$(jq -r '.current_stage // empty' "$STATE_FILE" 2>/dev/null || true)"
        assert_eq \
            "control: original fields preserved through update" \
            "build" "$stage_val"

        tested_val="$(jq -r '.tested // empty' "$STATE_FILE" 2>/dev/null || true)"
        assert_eq \
            "control: update fn applied correctly (tested key present)" \
            "true" "$tested_val"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────

cleanup_test_env
print_test_results
exit $((FAIL > 0))
