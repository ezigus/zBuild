#!/usr/bin/env bash
# Tests: core/pipeline/runner.sh — issue #296 Δ-4
# ZBUILD_STATE_FILE vs --issue cross-check: when both are set and the
# state file records a different issue, the runner must fail-closed
# rather than silently honoring the env var.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER="$REPO_ROOT/core/pipeline/runner.sh"

# shellcheck source=../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "runner — ZBUILD_STATE_FILE vs --issue cross-check (#296 Δ-4)"
setup_test_env "runner-state-file-issue-cross-check"

# Mirror the standard runner test scaffolding so the runner can boot.
PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
STATE_DIR="$TEST_TEMP_DIR/state"
EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT"
export ZBUILD_STATE_DIR="$STATE_DIR"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$EVENTS_JSONL"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$STATE_DIR" "$TEST_TEMP_DIR/events"

# Minimal plugins so the runner has stages to traverse.
_make_plugin() {
    local id="$1" kind="${2:-agent}"
    local dir="$TEST_TEMP_DIR/plugins/$kind/$id"
    mkdir -p "$dir"
    local fn; fn="${id//-/_}_run"
    cat > "$dir/manifest.yaml" <<EOF
id: $id
name: Test $id
kind: $kind
version: 0.0.1
hooks:
  run: $fn
requires:
  core:
    - redaction
EOF
    cat > "$dir/plugin.sh" <<EOF
${fn}() { return 0; }
EOF
}
_make_plugin "intake"        "agent"
_make_plugin "security-lens" "agent"
_make_plugin "output"        "tool"

# ─── Setup: a fabricated state file claiming issue 100 ─────────────────────
STATE_FILE="$TEST_TEMP_DIR/external-state.json"
mkdir -p "$(dirname "$STATE_FILE")"
cat > "$STATE_FILE" <<EOF
{
  "schema_version": 1,
  "run_id": "20260526120000-9999",
  "issue": 100,
  "status": "in_progress",
  "current_iteration": 0,
  "self_heal_count": 0,
  "scope_manifest_hash": "",
  "cost_ledger_pointer": 0,
  "stage_statuses": {}
}
EOF

# ─── Test 1: ZBUILD_STATE_FILE points at issue 100 + --issue 200 → exits 2 ─
set +e
ZBUILD_STATE_FILE="$STATE_FILE" bash "$RUNNER" --issue 200 --resume 2>"$TEST_TEMP_DIR/stderr1"
rc=$?
set -e
assert_eq "mismatch (state=100, --issue=200) exits non-zero" "2" "$rc"
if grep -q "mismatch\|aborting" "$TEST_TEMP_DIR/stderr1"; then
    assert_pass "mismatch error message is clear"
else
    assert_fail "mismatch error message is clear" "stderr: $(cat "$TEST_TEMP_DIR/stderr1")"
fi

# ─── Test 2: ZBUILD_STATE_FILE points at issue 100 + --issue 100 → no error ─
# (Run with --dry-run so we don't actually traverse stages — we just want to
# confirm the cross-check doesn't reject matching values.)
set +e
ZBUILD_STATE_FILE="$STATE_FILE" bash "$RUNNER" --issue 100 --dry-run >/dev/null 2>"$TEST_TEMP_DIR/stderr2"
rc=$?
set -e
if [[ "$rc" -ne 2 ]] || ! grep -q "mismatch" "$TEST_TEMP_DIR/stderr2"; then
    assert_pass "matching (state=100, --issue=100) does not trigger cross-check error"
else
    assert_fail "matching values should not trigger cross-check error" \
        "rc=$rc stderr=$(cat "$TEST_TEMP_DIR/stderr2")"
fi

# ─── Test 3: ZBUILD_STATE_FILE set, --issue omitted → no error ─────────────
set +e
ZBUILD_STATE_FILE="$STATE_FILE" bash "$RUNNER" --goal "test goal" --dry-run >/dev/null 2>"$TEST_TEMP_DIR/stderr3"
rc=$?
set -e
if ! grep -q "mismatch" "$TEST_TEMP_DIR/stderr3"; then
    assert_pass "no --issue (goal-mode) does not trigger cross-check error"
else
    assert_fail "no --issue should not trigger cross-check error" \
        "rc=$rc stderr=$(cat "$TEST_TEMP_DIR/stderr3")"
fi

# ─── Test 4: ZBUILD_STATE_FILE unset → no cross-check at all ───────────────
set +e
bash "$RUNNER" --issue 42 --dry-run >/dev/null 2>"$TEST_TEMP_DIR/stderr4"
rc=$?
set -e
if ! grep -q "mismatch" "$TEST_TEMP_DIR/stderr4"; then
    assert_pass "ZBUILD_STATE_FILE unset → no cross-check applied"
else
    assert_fail "no env var should not trigger cross-check error" \
        "rc=$rc stderr=$(cat "$TEST_TEMP_DIR/stderr4")"
fi

# ─── Test 5: ZBUILD_STATE_FILE set but file doesn't exist → no error here ──
# (The cross-check only fires when the file exists; missing-file is handled
# downstream by the resume logic.)
set +e
ZBUILD_STATE_FILE="$TEST_TEMP_DIR/nonexistent-state.json" \
    bash "$RUNNER" --issue 42 --dry-run >/dev/null 2>"$TEST_TEMP_DIR/stderr5"
rc=$?
set -e
if ! grep -q "mismatch" "$TEST_TEMP_DIR/stderr5"; then
    assert_pass "missing state file → no cross-check applied (resume logic handles)"
else
    assert_fail "missing state file should not trigger cross-check error" \
        "rc=$rc stderr=$(cat "$TEST_TEMP_DIR/stderr5")"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
