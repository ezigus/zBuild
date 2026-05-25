#!/usr/bin/env bash
# Tests: zbuild CLI verb routing — help, pipeline start/resume
# E2E: invokes real scripts/zbuild with PATH-shadowed externals
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ZBUILD_CLI="$REPO_ROOT/scripts/zbuild"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "zbuild CLI verbs — help, pipeline start, pipeline resume (E2E)"
setup_test_env "e2e-cli-verbs"

export ZBUILD_TEST_TMP="$TEST_TEMP_DIR"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
mkdir -p "$ZBUILD_STATE_DIR" "$TEST_TEMP_DIR/events"

# PATH-shadow claude and gh with no-op mocks
mock_claude
mock_gh
mock_git

_test_cleanup_hook() { cleanup_test_env; }

# ─── Test 1: zbuild --help exits 0 and output contains "Usage" or "zbuild" ────
set +e; out="$(bash "$ZBUILD_CLI" --help 2>&1)"; rc=$?; set -e
assert_eq "zbuild --help exits 0" "0" "$rc"
if echo "$out" | grep -qiE 'Usage|zbuild'; then
    assert_pass "zbuild --help output contains 'Usage' or 'zbuild'"
else
    assert_fail "zbuild --help output contains 'Usage' or 'zbuild'" "got: $out"
fi

# ─── Test 2: zbuild pipeline start --help exits 0 ─────────────────────────────
# runner.sh --help returns 0; zbuild pipeline start passes args through to runner.sh
# Create minimal stub plugins so runner.sh --help path doesn't error out first
PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
mkdir -p "$PLUGINS_ROOT/agent/intake" "$PLUGINS_ROOT/agent/security-lens" "$PLUGINS_ROOT/tool/output"

for stage in intake security-lens; do
    cat > "$PLUGINS_ROOT/agent/$stage/manifest.yaml" <<YAML
id: $stage
name: Stub $stage
kind: agent
version: 0.0.1
hooks:
  run: ${stage//-/_}_run
requires:
  core:
    - redaction
YAML
    printf '%s() { return 0; }\n' "${stage//-/_}_run" > "$PLUGINS_ROOT/agent/$stage/plugin.sh"
done

cat > "$PLUGINS_ROOT/tool/output/manifest.yaml" <<YAML
id: output
name: Stub output
kind: tool
version: 0.0.1
hooks:
  run: output_run
YAML
printf 'output_run() { return 0; }\n' > "$PLUGINS_ROOT/tool/output/plugin.sh"
export ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT"

set +e
out="$(ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" bash "$ZBUILD_CLI" pipeline start --help 2>&1)"
rc=$?
set -e
assert_eq "zbuild pipeline start --help exits 0" "0" "$rc"

# ─── Test 3: zbuild pipeline start with no args exits non-zero ────────────────
set +e
out="$(ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" bash "$ZBUILD_CLI" pipeline start 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
    assert_pass "zbuild pipeline start (no args) exits non-zero (rc=$rc)"
else
    assert_fail "zbuild pipeline start (no args) exits non-zero" "exited 0 unexpectedly; output: $out"
fi

# ─── Test 4: zbuild pipeline resume --help or non-zero usage ──────────────────
# resume requires a state file; calling with no state file exits non-zero (no-state path)
# That is the current implemented behavior — assert it.
set +e
out="$(ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state-empty" bash "$ZBUILD_CLI" pipeline resume 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
    assert_pass "zbuild pipeline resume (no state file) exits non-zero (rc=$rc)"
else
    assert_fail "zbuild pipeline resume (no state file) exits non-zero" "exited 0 unexpectedly; output: $out"
fi

cleanup_test_env
print_test_results
