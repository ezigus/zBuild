#!/usr/bin/env bash
# Tests: host-wide concurrent run cap (issue #1932, ADR-059 §7).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/state/run-cap.sh
source "$REPO_ROOT/core/state/run-cap.sh"

print_test_header "host-wide concurrent run cap (#1932)"
setup_test_env "zb-run-cap"

# ─── helpers ─────────────────────────────────────────────────────────────────

_mk_live_state() {
    local f="$1"
    mkdir -p "$(dirname "$f")"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"status":"in_progress","updated_at":"%s"}\n' "$ts" > "$f"
}

_mk_dead_state() {
    local f="$1"
    mkdir -p "$(dirname "$f")"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"status":"complete","updated_at":"%s"}\n' "$ts" > "$f"
}

# Admit a run as a subprocess so its slot file persists after exit.
# ZBUILD_STATE_ROOT and ZBUILD_MAX_CONCURRENT_RUNS are inherited from the caller.
_cap_admit_subprocess() {
    local _run_id="$1" _state_file="${2:-}"
    bash -c '
        source "'"$REPO_ROOT"'/scripts/lib/helpers.sh"
        source "'"$REPO_ROOT"'/core/state/run-cap.sh"
        zbuild_run_cap_admit "'"$_run_id"'" "'"$_state_file"'" || true
    ' >/dev/null 2>&1 || true
}

# ─── [#1932/SPEC-1] no cap: returns 0, no slot written, silent ───────────────
print_test_section "[#1932/SPEC-1] unset ZBUILD_MAX_CONCURRENT_RUNS"

export ZBUILD_STATE_ROOT="$TEST_TEMP_DIR/spec1-state"
unset ZBUILD_MAX_CONCURRENT_RUNS

_s1_state="$TEST_TEMP_DIR/spec1/run.json"
_mk_live_state "$_s1_state"

_s1_out=""
_s1_rc=0
_s1_out="$(zbuild_run_cap_admit "run-s1" "$_s1_state" 2>&1)" || _s1_rc=$?

assert_eq "[#1932/SPEC-1] no cap: returns 0" "0" "$_s1_rc"
assert_eq "[#1932/SPEC-1] no cap: no output produced" "" "$_s1_out"

# No files must have been written under the state root
_s1_file_count=0
if [[ -d "$ZBUILD_STATE_ROOT" ]]; then
    while IFS= read -r _; do
        _s1_file_count=$((_s1_file_count + 1))
    done < <(find "$ZBUILD_STATE_ROOT" -type f 2>/dev/null)
fi
assert_eq "[#1932/SPEC-1] no cap: no slot file written" "0" "$_s1_file_count"

# ─── [#1932/SPEC-6] below cap: returns 0, slot written, silent ───────────────
print_test_section "[#1932/SPEC-6] cap set, fewer live slots than cap"

export ZBUILD_STATE_ROOT="$TEST_TEMP_DIR/spec6-state"
export ZBUILD_MAX_CONCURRENT_RUNS=2

_s6_state_a="$TEST_TEMP_DIR/spec6-a/run.json"
_s6_state_new="$TEST_TEMP_DIR/spec6-new/run.json"
_mk_live_state "$_s6_state_a"
_mk_live_state "$_s6_state_new"

# One existing live slot (cap=2, so 1 < 2)
_cap_admit_subprocess "run-s6-a" "$_s6_state_a"

_s6_out=""
_s6_rc=0
_s6_out="$(zbuild_run_cap_admit "run-s6-new" "$_s6_state_new" 2>&1)" || _s6_rc=$?

assert_eq "[#1932/SPEC-6] below cap: returns 0" "0" "$_s6_rc"
assert_eq "[#1932/SPEC-6] below cap: no cap output produced" "" "$_s6_out"

# A slot file must now exist for the admitted run
_s6_slot_found=0
while IFS= read -r _f; do
    if grep -q "run-s6-new" "$_f" 2>/dev/null; then
        _s6_slot_found=1
    fi
done < <(find "$ZBUILD_STATE_ROOT" -type f 2>/dev/null)
assert_eq "[#1932/SPEC-6] below cap: slot file written for admitted run" "1" "$_s6_slot_found"

# ─── [#1932/SPEC-2] at cap: returns 1, blockers named, stderr message ────────
print_test_section "[#1932/SPEC-2] cap set, N live slots present"

export ZBUILD_STATE_ROOT="$TEST_TEMP_DIR/spec2-state"
export ZBUILD_MAX_CONCURRENT_RUNS=2

_s2_state_a="$TEST_TEMP_DIR/spec2-a/run.json"
_s2_state_b="$TEST_TEMP_DIR/spec2-b/run.json"
_s2_state_new="$TEST_TEMP_DIR/spec2-new/run.json"
_mk_live_state "$_s2_state_a"
_mk_live_state "$_s2_state_b"
_mk_live_state "$_s2_state_new"

# Seed two live slots (cap=2, so count == cap)
_cap_admit_subprocess "run-s2-a" "$_s2_state_a"
_cap_admit_subprocess "run-s2-b" "$_s2_state_b"

_ZBUILD_RUN_CAP_BLOCKERS=""
_s2_stderr_file="$TEST_TEMP_DIR/spec2-stderr.txt"
_s2_rc=0
zbuild_run_cap_admit "run-s2-new" "$_s2_state_new" 2>"$_s2_stderr_file" || _s2_rc=$?

assert_eq "[#1932/SPEC-2] at cap: returns 1" "1" "$_s2_rc"
assert_contains "[#1932/SPEC-2] _ZBUILD_RUN_CAP_BLOCKERS names run-s2-a" \
    "$_ZBUILD_RUN_CAP_BLOCKERS" "run-s2-a"
assert_contains "[#1932/SPEC-2] _ZBUILD_RUN_CAP_BLOCKERS names run-s2-b" \
    "$_ZBUILD_RUN_CAP_BLOCKERS" "run-s2-b"

_s2_stderr="$(<"$_s2_stderr_file")"
assert_contains "[#1932/SPEC-2] stderr refusal names run-s2-a" "$_s2_stderr" "run-s2-a"
assert_contains "[#1932/SPEC-2] stderr refusal names run-s2-b" "$_s2_stderr" "run-s2-b"

# ─── [#1932/SPEC-3] stale slot reaped before counting ────────────────────────
print_test_section "[#1932/SPEC-3] stale slot reaped, does not block admission"

export ZBUILD_STATE_ROOT="$TEST_TEMP_DIR/spec3-state"
export ZBUILD_MAX_CONCURRENT_RUNS=2

_s3_state_live="$TEST_TEMP_DIR/spec3-live/run.json"
_s3_state_dead="$TEST_TEMP_DIR/spec3-dead/run.json"
_s3_state_new="$TEST_TEMP_DIR/spec3-new/run.json"
_mk_live_state "$_s3_state_live"
_mk_dead_state "$_s3_state_dead"
_mk_live_state "$_s3_state_new"

# Seed one live slot + one dead (complete) slot — total 2, but only 1 is live
_cap_admit_subprocess "run-s3-live" "$_s3_state_live"
_cap_admit_subprocess "run-s3-dead" "$_s3_state_dead"

# With cap=2 and 2 total slots (1 live, 1 stale), admission must succeed
# because zbuild_run_cap_reap_stale removes the dead slot before counting
_s3_rc=0
zbuild_run_cap_admit "run-s3-new" "$_s3_state_new" 2>/dev/null || _s3_rc=$?
assert_eq "[#1932/SPEC-3] stale slot reaped: admission succeeds" "0" "$_s3_rc"

# The stale slot must have been removed
_s3_dead_found=0
while IFS= read -r _f; do
    if grep -q "run-s3-dead" "$_f" 2>/dev/null; then
        _s3_dead_found=1
    fi
done < <(find "$ZBUILD_STATE_ROOT" -type f 2>/dev/null)
assert_eq "[#1932/SPEC-3] stale slot file removed by reap" "0" "$_s3_dead_found"

# Negative control: two live slots still refuse — reaping alone does not open the gate
export ZBUILD_STATE_ROOT="$TEST_TEMP_DIR/spec3b-state"
_s3b_state_a="$TEST_TEMP_DIR/spec3b-a/run.json"
_s3b_state_b="$TEST_TEMP_DIR/spec3b-b/run.json"
_s3b_state_new="$TEST_TEMP_DIR/spec3b-new/run.json"
_mk_live_state "$_s3b_state_a"
_mk_live_state "$_s3b_state_b"
_mk_live_state "$_s3b_state_new"
_cap_admit_subprocess "run-s3b-a" "$_s3b_state_a"
_cap_admit_subprocess "run-s3b-b" "$_s3b_state_b"
_s3b_rc=0
zbuild_run_cap_admit "run-s3b-new" "$_s3b_state_new" 2>/dev/null || _s3b_rc=$?
assert_eq "[#1932/SPEC-3] control: two live slots still refuse" "1" "$_s3b_rc"

# ─── [#1932/SPEC-4] ZBUILD_NO_RUN_CAP=1: bypass regardless of cap and count ──
print_test_section "[#1932/SPEC-4] ZBUILD_NO_RUN_CAP=1 overrides cap and slot count"

export ZBUILD_STATE_ROOT="$TEST_TEMP_DIR/spec4-state"
export ZBUILD_MAX_CONCURRENT_RUNS=1

_s4_state_blocker="$TEST_TEMP_DIR/spec4-blocker/run.json"
_s4_state_new="$TEST_TEMP_DIR/spec4-new/run.json"
_mk_live_state "$_s4_state_blocker"
_mk_live_state "$_s4_state_new"

# Seed one live slot (cap=1, so count == cap — would normally refuse)
_cap_admit_subprocess "run-s4-blocker" "$_s4_state_blocker"

export ZBUILD_NO_RUN_CAP=1
_s4_stderr_file="$TEST_TEMP_DIR/spec4-stderr.txt"
_s4_rc=0
zbuild_run_cap_admit "run-s4-new" "$_s4_state_new" 2>"$_s4_stderr_file" || _s4_rc=$?
unset ZBUILD_NO_RUN_CAP

assert_eq "[#1932/SPEC-4] NO_RUN_CAP=1: returns 0 regardless of cap" "0" "$_s4_rc"
_s4_stderr="$(<"$_s4_stderr_file")"
if [[ -n "$_s4_stderr" ]]; then
    assert_pass "[#1932/SPEC-4] NO_RUN_CAP=1: emits a warning to stderr"
else
    assert_fail "[#1932/SPEC-4] NO_RUN_CAP=1: emits a warning to stderr" "no warning emitted"
fi

# ─── [#1932/SPEC-5] unreadable slot dir: warns and fails open ────────────────
print_test_section "[#1932/SPEC-5] unreadable slot dir fails open"

export ZBUILD_STATE_ROOT="$TEST_TEMP_DIR/spec5-state"
export ZBUILD_MAX_CONCURRENT_RUNS=1

_s5_state="$TEST_TEMP_DIR/spec5-new/run.json"
_mk_live_state "$_s5_state"

# Make the slot root unreadable/untraversable so the function cannot count slots
mkdir -p "$ZBUILD_STATE_ROOT"
chmod 000 "$ZBUILD_STATE_ROOT"

_s5_stderr_file="$TEST_TEMP_DIR/spec5-stderr.txt"
_s5_rc=0
zbuild_run_cap_admit "run-s5" "$_s5_state" 2>"$_s5_stderr_file" || _s5_rc=$?

# Restore before any assertions so cleanup_test_env can remove the tree
chmod 755 "$ZBUILD_STATE_ROOT"

assert_eq "[#1932/SPEC-5] unreadable slot dir: returns 0 (fail-open)" "0" "$_s5_rc"
_s5_stderr="$(<"$_s5_stderr_file")"
if [[ -n "$_s5_stderr" ]]; then
    assert_pass "[#1932/SPEC-5] unreadable slot dir: emits a warning to stderr"
else
    assert_fail "[#1932/SPEC-5] unreadable slot dir: emits a warning to stderr" "no warning emitted"
fi

# ─── [#1932/SPEC-7] ADR-059 §7 and event-schema.json ────────────────────────
print_test_section "[#1932/SPEC-7] ADR-059 §7 and pipeline.refused.run_cap"

_adr_file="$REPO_ROOT/docs/adr/ADR-059-issue-vs-run-keying.md"
assert_file_exists "[#1932/SPEC-7] ADR-059 file exists" "$_adr_file"

if grep -q "Host-wide run cap, off unless configured" "$_adr_file"; then
    assert_pass "[#1932/SPEC-7] ADR-059 §7 titled 'Host-wide run cap, off unless configured'"
else
    assert_fail "[#1932/SPEC-7] ADR-059 §7 titled 'Host-wide run cap, off unless configured'" \
        "section heading not found in ADR-059"
fi

if grep -q "tests/unit/run-cap-test.sh" "$_adr_file"; then
    assert_pass "[#1932/SPEC-7] ADR-059 Enforced-by names tests/unit/run-cap-test.sh"
else
    assert_fail "[#1932/SPEC-7] ADR-059 Enforced-by names tests/unit/run-cap-test.sh" \
        "not found in ADR-059 Enforced-by"
fi

_schema_file="$REPO_ROOT/config/event-schema.json"
if grep -q "pipeline.refused.run_cap" "$_schema_file"; then
    assert_pass "[#1932/SPEC-7] event-schema.json contains pipeline.refused.run_cap"
else
    assert_fail "[#1932/SPEC-7] event-schema.json contains pipeline.refused.run_cap" \
        "event type missing from config/event-schema.json"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
