#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/ci-reconcile-state test — Unit tests                     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: ci-reconcile-state Tests"

setup_test_env "sw-lib-ci-reconcile-state-test"
_test_cleanup_hook() { cleanup_test_env; }

# Source the helper under test
source "$SCRIPT_DIR/lib/ci-reconcile-state.sh"

# ─── Fixture builders ────────────────────────────────────────────────────────
# make_state_file: log-only fixture (no YAML stages block)
make_state_file() {
    local filepath="$1"
    local status="$2"
    shift 2
    # remaining args: "stage:outcome" pairs to put in the log
    cat > "$filepath" <<YAML
---
pipeline: autonomous
goal: "Test goal"
status: ${status}
current_stage: build
---

## Log

YAML
    while [[ $# -gt 0 ]]; do
        local pair="$1"; shift
        local stage="${pair%%:*}"
        local outcome="${pair#*:}"
        printf '### %s (12:00:00)\n' "$stage" >> "$filepath"
        printf '%s (1m 0s)\n\n' "$outcome" >> "$filepath"
    done
}

# make_state_file_with_yaml: fixture with both YAML stages block and log section
make_state_file_with_yaml() {
    local filepath="$1"
    local status="$2"
    shift 2
    # remaining args: "stage:outcome" pairs — written to YAML stages block only
    {
        printf -- '---\npipeline: autonomous\ngoal: "Test goal"\nstatus: %s\ncurrent_stage: build\nstages:\n' "$status"
        for pair in "$@"; do
            local stage="${pair%%:*}"
            local outcome="${pair#*:}"
            printf '  %s: %s\n' "$stage" "$outcome"
        done
        printf -- '---\n\n## Log\n\n'
    } > "$filepath"
}

# ─── Test 1: running → interrupted, extracts completed stages from YAML ──────
print_test_section "1. running → interrupted + YAML stage extraction"
STATE="$TEST_TEMP_DIR/state1.md"
make_state_file_with_yaml "$STATE" "running" \
    "intake:complete" "plan:complete" "design:complete" \
    "build:complete" "test:complete" "review:complete"

result="$(ci_reconcile_state "$STATE")"
rewritten_status="$(sed -n 's/^status: *//p' "$STATE" | head -1 | tr -d '[:space:]')"

assert_eq "status rewritten to interrupted" "interrupted" "$rewritten_status"
assert_contains "intake in result" "$result" "intake"
assert_contains "plan in result" "$result" "plan"
assert_contains "design in result" "$result" "design"
assert_contains "build in result" "$result" "build"
assert_contains "test in result" "$result" "test"
assert_contains "review in result" "$result" "review"

# ─── Test 2: paused → interrupted ────────────────────────────────────────────
print_test_section "2. paused → interrupted"
STATE="$TEST_TEMP_DIR/state2.md"
make_state_file_with_yaml "$STATE" "paused" "intake:complete" "plan:complete"

result="$(ci_reconcile_state "$STATE")"
rewritten_status="$(sed -n 's/^status: *//p' "$STATE" | head -1 | tr -d '[:space:]')"

assert_eq "status rewritten to interrupted" "interrupted" "$rewritten_status"
assert_contains "intake in result" "$result" "intake"
assert_contains "plan in result" "$result" "plan"

# ─── Test 3: failed — status left alone, completed stages still returned ─────
print_test_section "3. failed — status untouched, stages returned"
STATE="$TEST_TEMP_DIR/state3.md"
make_state_file_with_yaml "$STATE" "failed" "intake:complete" "plan:complete"

result="$(ci_reconcile_state "$STATE")"
rewritten_status="$(sed -n 's/^status: *//p' "$STATE" | head -1 | tr -d '[:space:]')"

assert_eq "status unchanged (failed)" "failed" "$rewritten_status"
assert_contains "intake returned for failed status" "$result" "intake"
assert_contains "plan returned for failed status" "$result" "plan"

# ─── Test 4: interrupted — status left alone, completed stages still returned ─
print_test_section "4. interrupted — status untouched, stages returned"
STATE="$TEST_TEMP_DIR/state4.md"
make_state_file_with_yaml "$STATE" "interrupted" "intake:complete" "plan:complete"

result="$(ci_reconcile_state "$STATE")"
rewritten_status="$(sed -n 's/^status: *//p' "$STATE" | head -1 | tr -d '[:space:]')"

assert_eq "status unchanged (interrupted)" "interrupted" "$rewritten_status"
assert_contains "intake returned for interrupted status" "$result" "intake"
assert_contains "plan returned for interrupted status" "$result" "plan"

# ─── Test 5: stuck_cycling — status left alone, completed stages returned ─────
print_test_section "5. stuck_cycling — status untouched, stages returned"
STATE="$TEST_TEMP_DIR/state5.md"
make_state_file_with_yaml "$STATE" "stuck_cycling" "intake:complete"

result="$(ci_reconcile_state "$STATE")"
rewritten_status="$(sed -n 's/^status: *//p' "$STATE" | head -1 | tr -d '[:space:]')"

assert_eq "status unchanged (stuck_cycling)" "stuck_cycling" "$rewritten_status"
assert_contains "intake returned for stuck_cycling" "$result" "intake"

# ─── Test 6: mixed-case stage IDs (COMPOUND_QUALITY, test_2) ─────────────────
print_test_section "6. mixed-case stage IDs"
STATE="$TEST_TEMP_DIR/state6.md"
make_state_file_with_yaml "$STATE" "running" \
    "intake:complete" "COMPOUND_QUALITY:complete" "test_2:complete"

result="$(ci_reconcile_state "$STATE")"

assert_contains "COMPOUND_QUALITY in result" "$result" "COMPOUND_QUALITY"
assert_contains "test_2 in result" "$result" "test_2"
assert_contains "intake in result" "$result" "intake"

# ─── Test 7: YAML is authoritative — log-only completed entries are ignored ───
# The YAML `stages:` block is the single source of truth. If a stage is
# complete in the log but not in the YAML (e.g. interrupted mid-persist),
# it is NOT returned. The YAML reflects the last successful mark_stage_complete.
print_test_section "7. YAML-only: log entries don't affect result"
STATE="$TEST_TEMP_DIR/state7.md"
make_state_file_with_yaml "$STATE" "interrupted" "intake:complete" "build:complete"
# Append a log showing build failed (YAML says complete — YAML wins)
cat >> "$STATE" <<LOG

### intake (12:00:00)
complete (58s)

### build (12:01:00)
failed (2m 0s)

LOG

result="$(ci_reconcile_state "$STATE")"

assert_contains "build in result (completed after retry)" "$result" "build"
# Should appear exactly once (no duplication from log)
count="$(echo "$result" | tr ',' '\n' | grep -c "^build$" || true)"
count="${count:-0}"
assert_eq "build deduped to single occurrence" "1" "$count"

# ─── Test 8: no ## Log section → empty stdout, status still rewritten ─────────
print_test_section "8. no ## Log section"
STATE="$TEST_TEMP_DIR/state8.md"
cat > "$STATE" <<YAML
---
status: running
current_stage: build
---
YAML

result="$(ci_reconcile_state "$STATE")"
rewritten_status="$(sed -n 's/^status: *//p' "$STATE" | head -1 | tr -d '[:space:]')"

assert_eq "status rewritten even without log" "interrupted" "$rewritten_status"
assert_eq "empty stdout when no log section" "" "$result"

# ─── Test 10: complete — empty stdout (re-run should start fresh) ─────────────
print_test_section "10. complete — empty stdout (re-run starts fresh)"
STATE="$TEST_TEMP_DIR/state10.md"
make_state_file "$STATE" "complete" "intake:complete" "plan:complete"

result="$(ci_reconcile_state "$STATE")"
rewritten_status="$(sed -n 's/^status: *//p' "$STATE" | head -1 | tr -d '[:space:]')"

assert_eq "status unchanged (complete)" "complete" "$rewritten_status"
assert_eq "empty stdout for complete status" "" "$result"

# ─── Test 11: YAML stages block as source — no log entries ───────────────────
print_test_section "11. YAML stages block — completed stages returned without log"
STATE="$TEST_TEMP_DIR/state11.md"
make_state_file_with_yaml "$STATE" "interrupted" \
    "intake:complete" "plan:complete" "design:complete"

result="$(ci_reconcile_state "$STATE")"

assert_contains "intake from YAML stages" "$result" "intake"
assert_contains "plan from YAML stages" "$result" "plan"
assert_contains "design from YAML stages" "$result" "design"

# ─── Test 12: YAML + log union — deduped, non-complete log entries ignored ───
print_test_section "12. YAML + log union — non-complete log entries excluded"
STATE="$TEST_TEMP_DIR/state12.md"
make_state_file_with_yaml "$STATE" "running" \
    "intake:complete" "plan:complete"
# Append a log section where only intake is complete
cat >> "$STATE" <<LOG
### intake (12:00:00)
complete (58s)

### plan (12:01:00)
failed (2m 0s)

LOG

result="$(ci_reconcile_state "$STATE")"
rewritten_status="$(sed -n 's/^status: *//p' "$STATE" | head -1 | tr -d '[:space:]')"

assert_eq "status rewritten (running in test 12)" "interrupted" "$rewritten_status"
assert_contains "intake in union result" "$result" "intake"
assert_contains "plan from YAML even though log says failed" "$result" "plan"

# ─── Test 9: non-existent file → empty stdout, exit 0 ────────────────────────
print_test_section "9. non-existent file"
result="$(ci_reconcile_state "$TEST_TEMP_DIR/does-not-exist.md")"
exit_code=$?

assert_eq "exit code 0 for missing file" "0" "$exit_code"
assert_eq "empty stdout for missing file" "" "$result"

# ─── Results ─────────────────────────────────────────────────────────────────
print_test_results
