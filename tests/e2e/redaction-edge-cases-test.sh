#!/usr/bin/env bash
# Tests: redaction edge-case scope manifests — missing, empty, CRLF
# E2E: invokes real scripts/zbuild with PATH-shadowed externals
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ZBUILD_CLI="$REPO_ROOT/scripts/zbuild"
REDACTION_LIB="$REPO_ROOT/core/redaction/scope-redaction.sh"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "redaction edge-cases — missing/empty/CRLF scope manifests (E2E)"
setup_test_env "e2e-redaction-edge"

export ZBUILD_TEST_TMP="$TEST_TEMP_DIR"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
mkdir -p "$ZBUILD_STATE_DIR" "$TEST_TEMP_DIR/events"

mock_claude
mock_gh
mock_git

_test_cleanup_hook() { cleanup_test_env; }

# Source the event-bus shim so emit_event is available for redaction library
# The event-bus needs ZBUILD_EVENTS_JSONL set (done above)
source "$REPO_ROOT/core/event-bus/event-bus.sh" 2>/dev/null || true

# ─── Test 1: Missing scope manifest → apply_scope_redaction returns non-zero ──
# We test the library directly (unit-style) since the CLI would need a full plugin
# pipeline to trigger redaction. The spec says: "exits non-zero with a clear error".
_redact_missing_input="$TEST_TEMP_DIR/input.txt"
_redact_missing_output="$TEST_TEMP_DIR/output.txt"
printf 'test content\n' > "$_redact_missing_input"

set +e
(
    source "$REDACTION_LIB"
    apply_scope_redaction "$_redact_missing_input" "$_redact_missing_output" \
        "/nonexistent/scope-manifest.md" 2>/dev/null
)
redaction_missing_rc=$?
set -e

if [[ "$redaction_missing_rc" -ne 0 ]]; then
    assert_pass "missing scope manifest: apply_scope_redaction returns non-zero (rc=$redaction_missing_rc)"
else
    assert_fail "missing scope manifest: apply_scope_redaction returns non-zero" \
        "returned 0 (should have refused)"
fi

# ─── Test 2: Empty scope manifest (0 bytes) → returns non-zero ───────────────
_redact_empty_input="$TEST_TEMP_DIR/input2.txt"
_redact_empty_output="$TEST_TEMP_DIR/output2.txt"
_empty_manifest="$TEST_TEMP_DIR/empty-scope.md"
printf 'test content\n' > "$_redact_empty_input"
: > "$_empty_manifest"   # 0-byte file

set +e
(
    source "$REDACTION_LIB"
    apply_scope_redaction "$_redact_empty_input" "$_redact_empty_output" \
        "$_empty_manifest" 2>/dev/null
)
redaction_empty_rc=$?
set -e

if [[ "$redaction_empty_rc" -ne 0 ]]; then
    assert_pass "empty scope manifest: apply_scope_redaction returns non-zero (rc=$redaction_empty_rc)"
else
    assert_fail "empty scope manifest: apply_scope_redaction returns non-zero" \
        "returned 0 (should have refused)"
fi

# ─── Test 3: CRLF scope manifest — proceeds without crash ────────────────────
# A CRLF manifest with a valid entry should either succeed (0) or fail with a
# clear error (non-zero). It must not crash (rc > 128 = signal).
_redact_crlf_input="$TEST_TEMP_DIR/input3.txt"
_redact_crlf_output="$TEST_TEMP_DIR/output3.txt"
_crlf_manifest="$TEST_TEMP_DIR/crlf-scope.md"
printf 'test content in src/main.sh\n' > "$_redact_crlf_input"
# Write manifest with CRLF line endings
printf '# Scope manifest\r\n+ src\r\n' > "$_crlf_manifest"

set +e
(
    source "$REDACTION_LIB"
    apply_scope_redaction "$_redact_crlf_input" "$_redact_crlf_output" \
        "$_crlf_manifest" 2>/dev/null
)
redaction_crlf_rc=$?
set -e

if [[ "$redaction_crlf_rc" -gt 128 ]]; then
    assert_fail "CRLF scope manifest: does not crash (rc=$redaction_crlf_rc — signal/crash)" \
        "redaction crashed on CRLF manifest"
else
    assert_pass "CRLF scope manifest: exits without crash (rc=$redaction_crlf_rc)"
fi

# ─── Test 4: CLI pipeline start with --scope pointing to empty manifest ────────
# The zbuild CLI --scope flag passes a path to the runner. With an empty scope
# manifest the pipeline should fail with a clear error, not crash.
EMPTY_SCOPE="$TEST_TEMP_DIR/empty-scope-cli.md"
: > "$EMPTY_SCOPE"

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

set +e
ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" \
ZBUILD_STATE_DIR="$ZBUILD_STATE_DIR" \
bash "$ZBUILD_CLI" pipeline start --goal "test scope" --scope "$EMPTY_SCOPE" --dry-run >/dev/null 2>&1
rc=$?
set -e

# --scope with empty file: CLI should either pass (dry-run skips redaction) or
# fail non-zero with a clear message. It must not crash.
if [[ "$rc" -gt 128 ]]; then
    assert_fail "CLI --scope with empty manifest does not crash (rc=$rc — signal/crash)"
else
    assert_pass "CLI --scope with empty manifest: does not crash (rc=$rc)"
fi

cleanup_test_env
print_test_results
