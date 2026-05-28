#!/usr/bin/env bash
# Tests: core/pipeline/runner.sh — flag parsing, --resume, state export, ZBUILD_STATE_FILE
# cross-check; issue #368.
#
# Strategy: test runner.sh by executing it as a subprocess with mocked dependencies
# so we can exercise argument parsing and early-exit paths without requiring a full
# live environment. For state-export tests we source just the flag-parsing layer
# using a thin wrapper approach.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/pipeline/runner — flag parsing + state export (#368)"

setup_test_env "core-pipeline-runner"

# ── Environment shared by all subprocess tests ────────────────────────────────
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_MODEL_TIER="${ZBUILD_MODEL_TIER:-T1}"
export NO_GITHUB=true
export GIT_TERMINAL_PROMPT=0
mkdir -p "$ZBUILD_STATE_DIR" "$ZBUILD_PLUGINS_ROOT" "$TEST_TEMP_DIR/events"

# Helper: run runner.sh in subprocess and capture stdout+stderr
_run_runner() {
    bash "$REPO_ROOT/core/pipeline/runner.sh" "$@" 2>&1 || true
}

# Helper: run runner.sh in subprocess and capture only exit code
_run_runner_rc() {
    local rc=0
    bash "$REPO_ROOT/core/pipeline/runner.sh" "$@" >/dev/null 2>&1 || rc=$?
    echo "$rc"
}

# Helper: run runner.sh with an extra env var set in the subprocess
_run_runner_rc_env() {
    local envvar="$1"; shift
    local rc=0
    env "$envvar" bash "$REPO_ROOT/core/pipeline/runner.sh" "$@" >/dev/null 2>&1 || rc=$?
    echo "$rc"
}

# ─── Section 1: missing required argument → exit 2 ───────────────────────────
print_test_section "Section 1: missing --issue and --goal → exit 2"

rc="$(_run_runner_rc)"
assert_eq "no args → exit 2" "2" "$rc"

# ─── Section 2: --help exits 0 ───────────────────────────────────────────────
print_test_section "Section 2: --help → exit 0"

rc="$(_run_runner_rc --help)"
assert_eq "--help → exit 0" "0" "$rc"

# ─── Section 3: -h exits 0 ───────────────────────────────────────────────────
rc="$(_run_runner_rc -h)"
assert_eq "-h → exit 0" "0" "$rc"

# ─── Section 4: unknown argument → exit 2 ────────────────────────────────────
print_test_section "Section 4: unknown argument → exit 2"

rc="$(_run_runner_rc --bogus-flag)"
assert_eq "unknown arg → exit 2" "2" "$rc"

# ─── Section 5: --issue missing value → exit 2 ───────────────────────────────
print_test_section "Section 5: --issue with no value → exit 2"

rc="$(_run_runner_rc --issue)"
assert_eq "--issue with no value → exit 2" "2" "$rc"

# ─── Section 6: --goal missing value → exit 2 ────────────────────────────────
print_test_section "Section 6: --goal with no value → exit 2"

rc="$(_run_runner_rc --goal)"
assert_eq "--goal with no value → exit 2" "2" "$rc"

# ─── Section 7: --template missing value → exit 2 ────────────────────────────
print_test_section "Section 7: --template with no value → exit 2"

rc="$(_run_runner_rc --template)"
assert_eq "--template with no value → exit 2" "2" "$rc"

# ─── Section 8: --from-stage without --resume → exit 2 ──────────────────────
print_test_section "Section 8: --from-stage without --resume → exit 2"

rc="$(_run_runner_rc --issue 42 --from-stage intake)"
assert_eq "--from-stage without --resume → exit 2" "2" "$rc"

# ─── Section 9: --from-stage with no value → exit 2 ─────────────────────────
print_test_section "Section 9: --from-stage with no value → exit 2"

rc="$(_run_runner_rc --issue 42 --resume --from-stage)"
assert_eq "--from-stage with no value → exit 2" "2" "$rc"

# ─── Section 10: --resume with no existing state file → exit 1 ───────────────
print_test_section "Section 10: --resume with no state file → exit 1"

unset ZBUILD_STATE_FILE
rm -f "$ZBUILD_STATE_DIR/pipeline-state.json"
rc="$(_run_runner_rc --issue 42 --resume)"
assert_eq "--resume + no state file → exit 1" "1" "$rc"

# ─── Section 11: --dry-run prints plan, exits 0 ──────────────────────────────
print_test_section "Section 11: --dry-run exits 0 with plan output"

out="$(_run_runner --issue 99 --dry-run 2>&1)" || true
rc="$(_run_runner_rc --issue 99 --dry-run)"
assert_eq "--dry-run → exit 0" "0" "$rc"
assert_contains "--dry-run output mentions 'dry-run'" "$out" "dry-run"

# ─── Section 12: ZBUILD_STATE_FILE issue mismatch → exit 2 ───────────────────
print_test_section "Section 12: ZBUILD_STATE_FILE with wrong issue → exit 2"

MISMATCH_STATE="$TEST_TEMP_DIR/state/mismatch-state.json"
jq -n '{schema_version:1,run_id:"r1",issue:7,stage_statuses:{},
         current_iteration:0,self_heal_count:{},
         scope_manifest_hash:"",cost_ledger_pointer:0,
         claim_lease_id:"",plugin_state:{},
         status:"in_progress",
         updated_at:"2026-01-01T00:00:00Z"}' > "$MISMATCH_STATE"

rc="$(_run_runner_rc_env "ZBUILD_STATE_FILE=$MISMATCH_STATE" --issue 42)"
assert_eq "ZBUILD_STATE_FILE issue mismatch → exit 2" "2" "$rc"

# ─── Section 13: ZBUILD_STATE_FILE with corrupt JSON → exit 2 ────────────────
print_test_section "Section 13: ZBUILD_STATE_FILE with corrupt JSON → exit 2"

CORRUPT_STATE="$TEST_TEMP_DIR/state/corrupt-state.json"
printf 'not valid json {{{\n' > "$CORRUPT_STATE"
rc="$(_run_runner_rc_env "ZBUILD_STATE_FILE=$CORRUPT_STATE" --issue 42)"
assert_eq "ZBUILD_STATE_FILE corrupt JSON → exit 2" "2" "$rc"

# ─── Section 14: ZBUILD_STATE_FILE matching issue passes the cross-check ──────
print_test_section "Section 14: ZBUILD_STATE_FILE with matching issue passes cross-check"

MATCH_STATE="$TEST_TEMP_DIR/state/match-state.json"
jq -n '{schema_version:1,run_id:"r2",issue:42,stage_statuses:{},
         current_iteration:0,self_heal_count:{},
         scope_manifest_hash:"",cost_ledger_pointer:0,
         claim_lease_id:"",plugin_state:{},
         status:"in_progress",
         updated_at:"2026-01-01T00:00:00Z"}' > "$MATCH_STATE"

# The cross-check only fires; the run still fails downstream (no plugin). rc != 2.
rc="$(_run_runner_rc_env "ZBUILD_STATE_FILE=$MATCH_STATE" --issue 42)"
# Should NOT be rc=2 (the mismatch sentinel); the cross-check passes.
if [[ "$rc" != "2" ]]; then
    assert_pass "ZBUILD_STATE_FILE matching issue does not hit mismatch guard (rc=$rc)"
else
    out_check="$(env "ZBUILD_STATE_FILE=$MATCH_STATE" bash "$REPO_ROOT/core/pipeline/runner.sh" --issue 42 2>&1)" || true
    if echo "$out_check" | grep -q "mismatch"; then
        assert_fail "ZBUILD_STATE_FILE matching issue should not trigger mismatch guard"
    else
        assert_pass "ZBUILD_STATE_FILE matching issue does not trigger mismatch guard"
    fi
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
