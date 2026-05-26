#!/usr/bin/env bash
# Tests: core/plugin-registry/registry.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"

print_test_header "core/plugin-registry — discovery + lifecycle (ADR-001)"

setup_test_env "core-registry"
FIXTURE_ROOT="$TEST_TEMP_DIR/plugins"
mkdir -p "$FIXTURE_ROOT/agent/test-lens" "$FIXTURE_ROOT/tool/test-tool" "$FIXTURE_ROOT/agent/bad-no-redaction"

# ─── Fixture 1: valid agent plugin ──────────────────────────────────────────
cat > "$FIXTURE_ROOT/agent/test-lens/manifest.yaml" <<'EOF'
id: test-lens
name: Test Lens
kind: agent
version: 0.0.1
description: |
  Fixture for registry tests.
hooks:
  init: test_lens_init
  run: test_lens_run
requires:
  core:
    - redaction
    - event-bus
EOF

cat > "$FIXTURE_ROOT/agent/test-lens/plugin.sh" <<'EOF'
test_lens_init() { echo "init called"; }
test_lens_run() { echo "run called: $*"; }
EOF

# ─── Fixture 2: valid tool plugin ───────────────────────────────────────────
cat > "$FIXTURE_ROOT/tool/test-tool/manifest.yaml" <<'EOF'
id: test-tool
name: Test Tool
kind: tool
version: 0.0.1
hooks:
  run: test_tool_run
EOF
cat > "$FIXTURE_ROOT/tool/test-tool/plugin.sh" <<'EOF'
test_tool_run() { echo "tool ran"; }
EOF

# ─── Fixture 3: invalid agent (no redaction required) ──────────────────────
cat > "$FIXTURE_ROOT/agent/bad-no-redaction/manifest.yaml" <<'EOF'
id: bad-no-redaction
name: Bad Agent (no redaction in requires)
kind: agent
version: 0.0.1
hooks:
  run: bad_run
requires:
  core:
    - event-bus
EOF
cat > "$FIXTURE_ROOT/agent/bad-no-redaction/plugin.sh" <<'EOF'
bad_run() { echo "should not be loaded"; }
EOF

# ─── Tests ──────────────────────────────────────────────────────────────────

# Valid manifest passes
set +e
validate_manifest "$FIXTURE_ROOT/agent/test-lens/manifest.yaml" >/dev/null 2>&1
rc=$?
set -e
assert_eq "validate_manifest accepts valid agent manifest" "0" "$rc"

# Tool manifest also valid (no redaction requirement for tool)
set +e
validate_manifest "$FIXTURE_ROOT/tool/test-tool/manifest.yaml" >/dev/null 2>&1
rc=$?
set -e
assert_eq "validate_manifest accepts valid tool manifest" "0" "$rc"

# Bad agent manifest (no redaction in requires) is rejected
set +e
validate_manifest "$FIXTURE_ROOT/agent/bad-no-redaction/manifest.yaml" >/dev/null 2>&1
rc=$?
set -e
assert_eq "validate_manifest rejects agent without redaction in requires.core (ADR-004 enforcement)" "1" "$rc"

# Discovery returns the two valid plugins, skips the invalid one
discovered="$(discover_plugins "$FIXTURE_ROOT" | sort)"
expected_count=2
actual_count=$(echo "$discovered" | grep -c .)
assert_eq "discover_plugins returns only valid manifests" "$expected_count" "$actual_count"

assert_contains "discovery includes test-lens" "$discovered" "agent/test-lens"
assert_contains "discovery includes test-tool" "$discovered" "tool/test-tool"
if echo "$discovered" | grep -q "bad-no-redaction"; then
    assert_fail "discovery should have skipped bad-no-redaction"
else
    assert_pass "discovery skipped bad-no-redaction"
fi

# Lockfile write + validate
ZBUILD_LOCKFILE="$TEST_TEMP_DIR/plugins.lock"
lockfile_write "$FIXTURE_ROOT" "$ZBUILD_LOCKFILE"
assert_file_exists "lockfile created" "$ZBUILD_LOCKFILE"

# Lockfile validates clean immediately after write
set +e
lockfile_validate "$ZBUILD_LOCKFILE"
rc=$?
set -e
assert_eq "lockfile validates clean after write" "0" "$rc"

# Mutate a manifest and check validation fails
echo "# extra comment" >> "$FIXTURE_ROOT/agent/test-lens/manifest.yaml"
set +e
lockfile_validate "$ZBUILD_LOCKFILE" 2>/dev/null
rc=$?
set -e
assert_eq "lockfile_validate detects manifest mutation" "1" "$rc"

# ─── Plugin.sh tamper detection (#290) ──────────────────────────────────────
# Re-lock with manifest restored; tamper plugin.sh only.
sed -i.bak '/^# extra comment$/d' "$FIXTURE_ROOT/agent/test-lens/manifest.yaml" 2>/dev/null \
    || sed -i '' '/^# extra comment$/d' "$FIXTURE_ROOT/agent/test-lens/manifest.yaml"
rm -f "$FIXTURE_ROOT/agent/test-lens/manifest.yaml.bak"
lockfile_write "$FIXTURE_ROOT" "$ZBUILD_LOCKFILE"
set +e
lockfile_validate "$ZBUILD_LOCKFILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "lockfile clean after re-lock" "0" "$rc"

# Append malicious-looking code to plugin.sh (manifest untouched).
echo 'test_lens_run() { echo "TAMPERED-RUN: $*"; }' >> "$FIXTURE_ROOT/agent/test-lens/plugin.sh"
set +e
lockfile_validate "$ZBUILD_LOCKFILE" 2>/dev/null
rc=$?
set -e
assert_eq "lockfile_validate detects plugin.sh tamper (manifest untouched) (#290)" "1" "$rc"

# Under ZBUILD_STRICT_PLUGIN_LOCK=1, plugin_hook_call refuses to source.
set +e
output="$(ZBUILD_STRICT_PLUGIN_LOCK=1 plugin_hook_call "$FIXTURE_ROOT/agent/test-lens" "run" "arg1" 2>&1)"
rc=$?
set -e
assert_eq "strict mode refuses tampered plugin.sh (rc != 0)" "1" "$rc"
if echo "$output" | grep -q "TAMPERED-RUN"; then
    assert_fail "strict mode must NOT execute tampered code" "got: $output"
else
    assert_pass "strict mode blocks tampered code execution"
fi

# Default (non-strict): warn but still source — keeps current behavior for
# users who haven't opted in.
set +e
output="$(plugin_hook_call "$FIXTURE_ROOT/agent/test-lens" "run" "arg1" 2>&1)"
rc=$?
set -e
# rc=0: hook still ran. A regression that started refusing in non-strict
# would surface here, not get hidden behind the warning-text check.
assert_eq "non-strict mode still returns rc=0 (hook ran)" "0" "$rc"
if echo "$output" | grep -q "tamper\|hash mismatch"; then
    assert_pass "non-strict mode emits tamper warning"
else
    assert_fail "non-strict mode emits tamper warning" "got: $output"
fi
# And the tampered code actually executed (TAMPERED-RUN output present).
if echo "$output" | grep -q "TAMPERED-RUN"; then
    assert_pass "non-strict mode sourced the tampered file (warn-only path)"
else
    assert_fail "non-strict mode sourced the tampered file" "got: $output"
fi

# Restore plugin.sh so the later dispatch tests see a clean file.
cat > "$FIXTURE_ROOT/agent/test-lens/plugin.sh" <<'EOF'
test_lens_init() { echo "init called"; }
test_lens_run() { echo "run called: $*"; }
EOF
lockfile_write "$FIXTURE_ROOT" "$ZBUILD_LOCKFILE"

# Legacy single-hash lockfile entry is detected and flagged.
# Manually craft a legacy-format record (no colon).
LEGACY_LOCKFILE="$TEST_TEMP_DIR/plugins-legacy.lock"
legacy_hash="$(shasum -a 256 "$FIXTURE_ROOT/agent/test-lens/manifest.yaml" | cut -d' ' -f1)"
echo "test-lens $legacy_hash $FIXTURE_ROOT/agent/test-lens/manifest.yaml" > "$LEGACY_LOCKFILE"
set +e
lockfile_validate "$LEGACY_LOCKFILE" 2>/dev/null
rc=$?
set -e
assert_eq "lockfile_validate flags legacy single-hash records (#290 migration)" "1" "$rc"

# Hook dispatch: call init on test-lens
output="$(plugin_hook_call "$FIXTURE_ROOT/agent/test-lens" "init" 2>&1)"
assert_contains "plugin_hook_call dispatches init hook" "$output" "init called"

# Hook dispatch: pass args to run
output="$(plugin_hook_call "$FIXTURE_ROOT/agent/test-lens" "run" "arg1" "arg2" 2>&1)"
assert_contains "plugin_hook_call dispatches run hook with args" "$output" "run called: arg1 arg2"

# Disabled plugin: create disabled file
ZBUILD_DISABLED_FILE="$TEST_TEMP_DIR/plugins.disabled"
echo "test-tool" > "$ZBUILD_DISABLED_FILE"
discovered="$(ZBUILD_DISABLED_FILE="$ZBUILD_DISABLED_FILE" discover_plugins "$FIXTURE_ROOT" | sort)"
if echo "$discovered" | grep -q "test-tool"; then
    assert_fail "disabled plugin should not be discovered"
else
    assert_pass "disabled plugin (test-tool) excluded from discovery"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
