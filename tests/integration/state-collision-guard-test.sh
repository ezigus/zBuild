#!/usr/bin/env bash
# Integration: SPEC-G collision guard — locked_state_update refuses to overwrite
# a live (in_progress, < 24h) state file owned by a different run_id (issue #1215).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/state/atomic.sh
source "$REPO_ROOT/core/state/atomic.sh"

print_test_header "SPEC-G collision guard — live-run state protection (#1215)"
setup_test_env "state-collision-guard"

STATE_FILE="$TEST_TEMP_DIR/pipeline-state.json"
mkdir -p "$(dirname "$STATE_FILE")"

EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_DIR="$EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$EVENTS_DIR"

# Minimal no-op update function used across all cases.
_guard_noop() { cat; }

# Write a state file with the given run_id, status, and updated_at.
_write_state() {
    local run_id="$1" status="$2" updated_at="$3"
    printf '{"schema_version":1,"run_id":"%s","status":"%s","updated_at":"%s","current_iteration":0}' \
        "$run_id" "$status" "$updated_at" > "$STATE_FILE"
}

NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
STALE_ISO="2020-01-01T00:00:00Z"
STDERR_F="$TEST_TEMP_DIR/stderr.txt"

# ── SPEC-1 + SPEC-2: collision — different run_id, in_progress, fresh (<24h) ──
_write_state "live-run-aaa" "in_progress" "$NOW_ISO"
export ZBUILD_RUN_ID="new-run-bbb"
set +e
locked_state_update "$STATE_FILE" "_guard_noop" >/dev/null 2>"$STDERR_F"
sg_rc=$?
set -e
assert_eq "[SPEC-1] collision: rc=3 when different run_id + in_progress + fresh" "3" "$sg_rc"
sg_stderr="$(cat "$STDERR_F")"
case "$sg_stderr" in
    *"SPEC-G"*) assert_pass "[SPEC-2] collision: stderr contains SPEC-G message" ;;
    *) assert_fail "[SPEC-2] collision: stderr must contain SPEC-G" "got: $sg_stderr" ;;
esac

# ── SPEC-3: same run_id + in_progress → proceeds normally (rc=0) ─────────────
_write_state "run-same" "in_progress" "$NOW_ISO"
export ZBUILD_RUN_ID="run-same"
set +e
locked_state_update "$STATE_FILE" "_guard_noop" >/dev/null 2>/dev/null
same_rc=$?
set -e
assert_eq "[SPEC-3] same run_id + in_progress → rc=0 (no collision)" "0" "$same_rc"

# ── SPEC-4: different run_id + status=complete → proceeds normally (rc=0) ────
_write_state "finished-run" "complete" "$NOW_ISO"
export ZBUILD_RUN_ID="new-run-ccc"
set +e
locked_state_update "$STATE_FILE" "_guard_noop" >/dev/null 2>/dev/null
complete_rc=$?
set -e
assert_eq "[SPEC-4] different run_id + complete → rc=0 (run finished, not live)" "0" "$complete_rc"

# ── SPEC-5: different run_id + in_progress + stale (>=24h) → proceeds ────────
_write_state "stale-run" "in_progress" "$STALE_ISO"
export ZBUILD_RUN_ID="new-run-ddd"
set +e
locked_state_update "$STATE_FILE" "_guard_noop" >/dev/null 2>/dev/null
stale_rc=$?
set -e
assert_eq "[SPEC-5] different run_id + in_progress + stale → rc=0 (updated_at >=24h old)" "0" "$stale_rc"

# ── SPEC-6: ZBUILD_RUN_ID unset → proceeds (ad-hoc callers exempt) ───────────
_write_state "live-run-eee" "in_progress" "$NOW_ISO"
unset ZBUILD_RUN_ID
set +e
locked_state_update "$STATE_FILE" "_guard_noop" >/dev/null 2>/dev/null
unset_rc=$?
set -e
assert_eq "[SPEC-6] ZBUILD_RUN_ID unset → rc=0 (ad-hoc callers exempt from guard)" "0" "$unset_rc"

# ── SPEC-7: no pre-existing state file → proceeds (fresh start) ──────────────
rm -f "$STATE_FILE"
export ZBUILD_RUN_ID="brand-new-run"
set +e
locked_state_update "$STATE_FILE" "_guard_noop" >/dev/null 2>/dev/null
fresh_rc=$?
set -e
assert_eq "[SPEC-7] no existing state file → rc=0 (fresh start, no collision)" "0" "$fresh_rc"

# ─── Cost (ADR-065 §5, round 4): one guarded update ──────────────────────────
# A state update started about twenty programs: dirname, two mktemps, a cp, three
# jqs and two or three dates for the guard alone, then the write. The guard now
# reads run id, status and age in one jq, against the shell's clock.
print_test_section "cost: one guarded update"
_write_state "other-run" "in_progress" "$STALE_ISO"
_CALLS="$TEST_TEMP_DIR/lsu-calls"; : > "$_CALLS"
for _c in dirname mktemp cp date jq; do
    eval "$_c() { printf '%s\\n' $_c >> \"\$_CALLS\"; command $_c \"\$@\"; }"
done
_jq_upd() { command jq -c '.current_iteration = 7'; }
ZBUILD_RUN_ID="this-run" locked_state_update "$STATE_FILE" _jq_upd 2>/dev/null; _rc_c=$?
unset -f dirname mktemp cp date jq
assert_eq "cost: a stale other run's file is updated" "0|7" "$_rc_c|$(jq -r .current_iteration "$STATE_FILE")"
assert_eq "cost: no dirname or date" "0|0" "$(grep -c '^dirname$' "$_CALLS" || true)|$(grep -c '^date$' "$_CALLS" || true)"
assert_eq "cost: one jq to validate and one for the guard (the update's own jq is not counted)" "2" "$(grep -c '^jq$' "$_CALLS" || true)"
assert_eq "cost: mktemp and cp only for the .bak (one each)" "1|1" "$(grep -c '^mktemp$' "$_CALLS" || true)|$(grep -c '^cp$' "$_CALLS" || true)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
