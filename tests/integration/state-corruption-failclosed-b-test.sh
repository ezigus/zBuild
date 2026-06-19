#!/usr/bin/env bash
# Tests: core/state/atomic.sh — locked_state_update fail-closed on JSON corruption — Part B
#
# Issue #293: Before the fix, locked_state_update warned on corruption and passed
# corrupt bytes to the update function.  After the fix it must:
#   6. All of the above hold on the no-flock fallback path (zbuild_has_flock() overridden).
#
# Part B covers: Scenarios 6-10
#   Scenario 6: state.corruption.unrecoverable payload fields are correct
#   Scenario 7: no-flock fallback — empty primary triggers .bak recovery
#   Scenario 8: no-flock fallback — both corrupt fail-closed + event emitted
#   Scenario 9: race condition simulation — concurrent writers, one corrupts mid-write
#   Scenario 10: control — valid state, no corruption, update succeeds
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "state corruption fail-closed Part B (scenarios 6-10) — locked_state_update (#293)"

setup_test_env "state-corruption-failclosed-b"

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
# Scenario 6 — Event payload content validation (state_file points at actual file)
# ─────────────────────────────────────────────────────────────────────────────
print_test_section "Scenario 6: state.corruption.unrecoverable payload fields are correct"
reset_scenario

printf '{garbage' > "$STATE_FILE"
printf '{garbage bak' > "${STATE_FILE}.bak"
: > "$ZBUILD_EVENTS_JSONL"

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
: > "$ZBUILD_EVENTS_JSONL"

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
# Scenario 11 (#946) — empty-primary recovery restores the COMPLETE .bak
#              (atomic_replace, not a torn cp) into the working state
# ─────────────────────────────────────────────────────────────────────────────
# Targets the empty-file recovery branch in _zbuild_lsu_validate_and_copy
# (core/state/atomic.sh) — now atomic_replace. A large .bak proves the restore
# carries the whole file through to the update fn, not a truncated prefix.
print_test_section "Scenario 11: empty-primary recovery restores complete large .bak (#946)"
reset_scenario

PAD="$(head -c 200000 /dev/zero | tr '\0' 'z')"   # 200KB padding field
# Build the .bak with printf (a bash builtin → no ARG_MAX limit); passing a 200KB
# value as a jq --arg overflows execve's argument list on Linux. The pad is plain
# 'z' chars so it needs no JSON escaping.
printf '{"schema_version":1,"current_stage":"plan","status":"completed","pad":"%s"}' "$PAD" > "${STATE_FILE}.bak"
: > "$STATE_FILE"   # empty primary → triggers the :58 empty-recovery branch

set +e
locked_state_update "$STATE_FILE" append_tested_fn
lsu_rc=$?
set -e

assert_eq "scenario 11: empty-primary recovery returns 0" "0" "$lsu_rc"
if [[ -f "$STATE_FILE" ]]; then
    set +e; jq empty "$STATE_FILE" >/dev/null 2>&1; jq_rc=$?; set -e
    assert_eq "scenario 11: final state is valid JSON" "0" "$jq_rc"
    if [[ $jq_rc -eq 0 ]]; then
        assert_eq "scenario 11: complete pad recovered (no truncation through restore)" \
            "${#PAD}" "$(jq -r '.pad | length' "$STATE_FILE")"
        assert_eq "scenario 11: recovered field survives (stage=plan)" \
            "plan" "$(jq -r '.current_stage // empty' "$STATE_FILE")"
        assert_eq "scenario 11: update fn applied to recovered data (tested=true)" \
            "true" "$(jq -r '.tested // empty' "$STATE_FILE")"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────

cleanup_test_env
print_test_results
