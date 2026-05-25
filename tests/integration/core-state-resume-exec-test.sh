#!/usr/bin/env bash
# Tests: resume contract across a REAL process boundary.
# Two bash processes: writer (initializes + writes), reader (resume + read).
# Proves state survives process exit, not just function re-call.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/state — resume across process boundary"

setup_test_env "core-state-resume-exec"
STATE_FILE="$TEST_TEMP_DIR/state.json"

# ─── Process 1: writer ──────────────────────────────────────────────────────
bash -c "
    set -euo pipefail
    source '$REPO_ROOT/scripts/lib/helpers.sh'
    source '$REPO_ROOT/core/state/resume.sh'
    init_state '$STATE_FILE' 'exec-test-run' 99 >/dev/null
    increment_iteration '$STATE_FILE' >/dev/null
    increment_iteration '$STATE_FILE' >/dev/null
    increment_iteration '$STATE_FILE' >/dev/null
    set_state_field '$STATE_FILE' '.plugin_state.\"test-plugin\".score' '88'
"
writer_rc=$?
assert_eq "writer process exits 0" "0" "$writer_rc"

# ─── Verify state file exists in this process ──────────────────────────────
assert_file_exists "state file persisted after writer exit" "$STATE_FILE"

# ─── Process 2: reader (simulates restart / resume) ────────────────────────
read_output="$(bash -c "
    set -euo pipefail
    source '$REPO_ROOT/scripts/lib/helpers.sh'
    source '$REPO_ROOT/core/state/resume.sh'
    resume_state '$STATE_FILE' >/dev/null
    iter=\$(get_state_field '$STATE_FILE' '.current_iteration' '0')
    score=\$(get_state_field '$STATE_FILE' '.plugin_state.\"test-plugin\".score' '0')
    echo \"iter=\$iter score=\$score\"
")"

assert_contains "reader process sees current_iteration=3 (FIXES legacy resume gap)" "$read_output" "iter=3"
assert_contains "reader process sees plugin_state.test-plugin.score=88" "$read_output" "score=88"

# ─── Process 3: writer continues after resume ──────────────────────────────
bash -c "
    set -euo pipefail
    source '$REPO_ROOT/scripts/lib/helpers.sh'
    source '$REPO_ROOT/core/state/resume.sh'
    resume_state '$STATE_FILE' >/dev/null
    increment_iteration '$STATE_FILE' >/dev/null
"
final_iter=$(bash -c "
    source '$REPO_ROOT/scripts/lib/helpers.sh'
    source '$REPO_ROOT/core/state/resume.sh'
    get_state_field '$STATE_FILE' '.current_iteration' '0'
")
assert_eq "iteration continues from where resume picked up (3 → 4)" "4" "$final_iter"

# ─── Test A1: goal with embedded quotes produces valid state JSON ─────────────
# The bug is in runner.sh line 252: set_state_field ... '.goal' "\"$goal\""
# A goal containing double-quotes breaks the JSON; jq rejects the state file.
# We test this by directly invoking jq with the buggy vs safe pattern.
A1_STATE="$TEST_TEMP_DIR/a1-state.json"
A1_EVENTS_DIR="$TEST_TEMP_DIR/a1-events"
mkdir -p "$A1_EVENTS_DIR"

# Pre-build a valid initial state file using jq directly (no emit_event needed)
jq -n \
    --arg run_id "a1-run" \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{schema_version:1, run_id:$run_id, issue:1, stage_statuses:{},
      current_iteration:0, self_heal_count:{}, scope_manifest_hash:"",
      cost_ledger_pointer:0, claim_lease_id:"", plugin_state:{},
      updated_at:$now}' > "$A1_STATE"

# Simulate the BUGGY pattern from runner.sh line 252:
#   set_state_field "$state_file" '.goal' "\"$goal\""
# with goal='hello "world"' this produces the malformed token: "hello "world""
goal_with_quotes='hello "world"'
buggy_json_value="\"${goal_with_quotes}\""   # produces: "hello "world""
set +e
jq --argjson value "$buggy_json_value" '.goal = $value' "$A1_STATE" > /dev/null 2>&1
buggy_jq_rc=$?
set -e

# Before the fix: jq should reject the malformed JSON token
if [[ $buggy_jq_rc -ne 0 ]]; then
    assert_pass "A1 pre-fix: buggy quote-concat produces invalid JSON (jq rejects it)"
else
    assert_fail "A1 pre-fix: expected jq to reject malformed goal JSON"
fi

# THE SAFE PATTERN (post-fix): use jq --arg to encode the value
safe_json_value="$(jq -n --arg g "$goal_with_quotes" '$g')"
set +e
updated_json="$(jq --argjson value "$safe_json_value" '.goal = $value' "$A1_STATE" 2>/dev/null)"
safe_jq_rc=$?
set -e
assert_eq "A1 safe pattern: jq --arg encoding exits 0" "0" "$safe_jq_rc"

# Write the safe value and verify round-trip
echo "$updated_json" > "$A1_STATE"
stored_goal="$(jq -r '.goal // empty' "$A1_STATE" 2>/dev/null || true)"
assert_eq "A1 safe pattern: goal round-trips correctly" 'hello "world"' "$stored_goal"
a1_jq_rc=0
jq . < "$A1_STATE" >/dev/null 2>&1 || a1_jq_rc=$?
assert_eq "A1 safe pattern: state.json is valid JSON after round-trip" "0" "$a1_jq_rc"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
