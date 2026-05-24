#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright sw-ci-reset-stale-state test — Unit tests                    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Tests scripts/sw-ci-reset-stale-state.sh: rewriting stale blocking statuses
# (`running` / `paused` / `interrupted`) to `failed` in pipeline-state.md so a
# crashed CI run does not block the next one.
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Script: sw-ci-reset-stale-state Tests"

setup_test_env "sw-ci-reset-stale-state-test"
_test_cleanup_hook() { cleanup_test_env; }

HELPER="$SCRIPT_DIR/sw-ci-reset-stale-state.sh"

# ─── Fixture builder ────────────────────────────────────────────────────────
make_state_file() {
    local filepath="$1"
    local status_line="$2"
    cat > "$filepath" <<YAML
---
pipeline: autonomous
goal: "Test goal"
${status_line}
current_stage: build
issue: "#999"
---

## Log

YAML
}

read_status() {
    sed -n 's/^status: *//p' "$1" | head -1 | tr -d '[:space:]'
}

# ─── Test 1: running → failed ───────────────────────────────────────────────
print_test_section "1. running → failed"
STATE="$TEST_TEMP_DIR/state1.md"
make_state_file "$STATE" "status: running"
result="$(bash "$HELPER" "$STATE")"
assert_eq "stdout reports prior status" "running" "$result"
assert_eq "file status is now 'failed'" "failed" "$(read_status "$STATE")"

# ─── Test 2: paused → failed ────────────────────────────────────────────────
print_test_section "2. paused → failed"
STATE="$TEST_TEMP_DIR/state2.md"
make_state_file "$STATE" "status: paused"
result="$(bash "$HELPER" "$STATE")"
assert_eq "stdout reports prior status" "paused" "$result"
assert_eq "file status is now 'failed'" "failed" "$(read_status "$STATE")"

# ─── Test 3: interrupted → failed ───────────────────────────────────────────
print_test_section "3. interrupted → failed"
STATE="$TEST_TEMP_DIR/state3.md"
make_state_file "$STATE" "status: interrupted"
result="$(bash "$HELPER" "$STATE")"
assert_eq "stdout reports prior status" "interrupted" "$result"
assert_eq "file status is now 'failed'" "failed" "$(read_status "$STATE")"

# ─── Test 4: failed → no-op ─────────────────────────────────────────────────
print_test_section "4. failed → no-op (idempotent)"
STATE="$TEST_TEMP_DIR/state4.md"
make_state_file "$STATE" "status: failed"
before_sha=$(shasum "$STATE" | awk '{print $1}')
result="$(bash "$HELPER" "$STATE")"
after_sha=$(shasum "$STATE" | awk '{print $1}')
assert_eq "stdout is empty (no rewrite)" "" "$result"
assert_eq "file unchanged" "$before_sha" "$after_sha"

# ─── Test 5: complete → no-op ───────────────────────────────────────────────
print_test_section "5. complete → no-op"
STATE="$TEST_TEMP_DIR/state5.md"
make_state_file "$STATE" "status: complete"
before_sha=$(shasum "$STATE" | awk '{print $1}')
result="$(bash "$HELPER" "$STATE")"
after_sha=$(shasum "$STATE" | awk '{print $1}')
assert_eq "stdout is empty" "" "$result"
assert_eq "file unchanged" "$before_sha" "$after_sha"

# ─── Test 6: stuck_cycling → no-op ──────────────────────────────────────────
print_test_section "6. stuck_cycling → no-op (operator must abort)"
STATE="$TEST_TEMP_DIR/state6.md"
make_state_file "$STATE" "status: stuck_cycling"
before_sha=$(shasum "$STATE" | awk '{print $1}')
result="$(bash "$HELPER" "$STATE")"
after_sha=$(shasum "$STATE" | awk '{print $1}')
assert_eq "stdout is empty" "" "$result"
assert_eq "file unchanged" "$before_sha" "$after_sha"

# ─── Test 7: trailing whitespace tolerated ──────────────────────────────────
print_test_section "7. trailing whitespace on status line"
STATE="$TEST_TEMP_DIR/state7.md"
# Note: trailing spaces intentional in this fixture
make_state_file "$STATE" "status: running   "
result="$(bash "$HELPER" "$STATE")"
assert_eq "stdout reports prior status" "running" "$result"
assert_eq "file status is now 'failed'" "failed" "$(read_status "$STATE")"

# ─── Test 8: missing file → exit 0 silently ─────────────────────────────────
print_test_section "8. missing file → no-op exit 0"
MISSING="$TEST_TEMP_DIR/does-not-exist.md"
set +e
result="$(bash "$HELPER" "$MISSING")"
exit_code=$?
set -e
assert_eq "exit 0 for missing file" "0" "$exit_code"
assert_eq "empty stdout for missing file" "" "$result"

# ─── Test 9: default state file path when no arg given ──────────────────────
print_test_section "9. default state file path"
# Run from a temp dir with no .claude/pipeline-state.md — should be a no-op
TEST_HOME="$TEST_TEMP_DIR/no-state"
mkdir -p "$TEST_HOME"
set +e
result="$(cd "$TEST_HOME" && bash "$HELPER")"
exit_code=$?
set -e
assert_eq "default path: exit 0 when file missing" "0" "$exit_code"
assert_eq "default path: empty stdout" "" "$result"

# ─── Test 10: full file content preserved except status line ────────────────
print_test_section "10. rewrite preserves other content"
STATE="$TEST_TEMP_DIR/state10.md"
cat > "$STATE" <<'YAML'
---
pipeline: autonomous
goal: "Some goal"
status: running
current_stage: build
issue: "#460"
extra: "preserve me"
---

## Log

### intake (12:00:00)
complete (1m 0s)

### plan (12:01:00)
complete (1m 0s)
YAML
bash "$HELPER" "$STATE" > /dev/null
assert_eq "status rewritten" "failed" "$(read_status "$STATE")"
assert_contains "goal preserved" "$(cat "$STATE")" 'goal: "Some goal"'
assert_contains "current_stage preserved" "$(cat "$STATE")" "current_stage: build"
assert_contains "issue preserved" "$(cat "$STATE")" 'issue: "#460"'
assert_contains "extra field preserved" "$(cat "$STATE")" "preserve me"
assert_contains "intake log entry preserved" "$(cat "$STATE")" "### intake (12:00:00)"
assert_contains "plan log entry preserved" "$(cat "$STATE")" "### plan (12:01:00)"

# ─── Test 11: multiple status: lines (defensive) ────────────────────────────
print_test_section "11. multiple status: lines all rewritten"
STATE="$TEST_TEMP_DIR/state11.md"
cat > "$STATE" <<'YAML'
---
status: running
stages:
  build:
    status: running
---
YAML
bash "$HELPER" "$STATE" > /dev/null
# Both top-level and nested `status: running` rewritten — defensive behavior:
# the helper rewrites every matching line rather than just the first.
remaining=$(grep -c '^status: running$' "$STATE" || true)
assert_eq "no top-level 'status: running' lines remain" "0" "$remaining"
# Top-level read function reports the new value
assert_eq "top-level status now 'failed'" "failed" "$(read_status "$STATE")"

# ─── Results ─────────────────────────────────────────────────────────────────
print_test_results
