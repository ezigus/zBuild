#!/usr/bin/env bash
# Integration Tests: core/config/config.sh — backend validation and find_plugin_for_role
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/config — integration: backend validation + find_plugin_for_role"

setup_test_env "core-config-backends"

# Prevent picking up the project's real .zbuild/config.yaml
export ZBUILD_CONFIG_FILE="/dev/null"
export ZBUILD_PROJECT_ROOT="$TEST_TEMP_DIR/project"

# Source dependencies
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
# shellcheck source=../../core/config/config.sh
source "$REPO_ROOT/core/config/config.sh"

# ─── Helper: create a fake plugin directory with manifest ───────────────────
make_plugin() {
    local plugin_dir="$1"
    local id="$2"
    local kind="$3"
    local role="$4"
    local alias="$5"
    mkdir -p "$plugin_dir"
    cat > "$plugin_dir/manifest.yaml" <<MANIFEST
id: $id
name: Test Plugin $id
kind: $kind
version: 0.1.0
provides:
  role: $role
  alias: $alias
MANIFEST
    # plugin.sh stub (required by validate_manifest for 'agent' kind — check redaction)
    cat > "$plugin_dir/plugin.sh" <<'PLUGIN'
#!/usr/bin/env bash
plugin_run() { echo "stub"; }
PLUGIN
}

# ─── Test 1: find_plugin_for_role — finds plugin by role + alias ─────────────
print_test_section "1. find_plugin_for_role: match by alias"
PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
mkdir -p "$PLUGINS_ROOT"
make_plugin "$PLUGINS_ROOT/tool/memory-sqlite" "memory-sqlite" "tool" "memory-backend" "sqlite"

result="$(find_plugin_for_role "memory-backend" "sqlite" "$PLUGINS_ROOT" 2>/dev/null || true)"
assert_eq "find_plugin_for_role matches by alias=sqlite" \
    "$PLUGINS_ROOT/tool/memory-sqlite" "$result"

# ─── Test 2: find_plugin_for_role — matches by plugin id directly ─────────────
print_test_section "2. find_plugin_for_role: match by plugin id"
make_plugin "$PLUGINS_ROOT/tool/orchestrator-bash-parallel" \
    "bash-parallel" "tool" "orchestrator-backend" "bash-parallel"

result="$(find_plugin_for_role "orchestrator-backend" "bash-parallel" "$PLUGINS_ROOT" 2>/dev/null || true)"
assert_eq "find_plugin_for_role matches by plugin id=bash-parallel" \
    "$PLUGINS_ROOT/tool/orchestrator-bash-parallel" "$result"

# ─── Test 3: find_plugin_for_role — returns 1 when not found ─────────────────
print_test_section "3. find_plugin_for_role: returns 1 when not found"
set +e
find_plugin_for_role "memory-backend" "nonexistent-backend" "$PLUGINS_ROOT" 2>/dev/null
rc=$?
set -e
assert_eq "find_plugin_for_role returns 1 when not found" "1" "$rc"

# ─── Test 4: zbuild_config_validate_backends — warns for missing non-default backend
print_test_section "4. zbuild_config_validate_backends: warns on missing non-default backend"

# Config: memory=ruflo but no ruflo plugin exists
cfg="$TEST_TEMP_DIR/config.yaml"
printf 'backends:\n  memory: ruflo\n' > "$cfg"
export ZBUILD_CONFIG_FILE="$cfg"
export ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT"
unset ZBUILD_MEMORY_BACKEND ZBUILD_ORCHESTRATOR_BACKEND ZBUILD_CACHE_BACKEND 2>/dev/null || true

# Capture stderr to check for warn
warn_output="$(zbuild_config_validate_backends 2>&1 || true)"
# Should warn about missing backend but NOT hard-fail
assert_contains "validate_backends warns about missing ruflo plugin" \
    "$warn_output" "backend.missing"

# ─── Test 5: zbuild_config_validate_backends — no warn when plugin present ────
print_test_section "5. zbuild_config_validate_backends: no warn when plugin present"
make_plugin "$PLUGINS_ROOT/tool/memory-ruflo" "memory-ruflo" "tool" "memory-backend" "ruflo"

cfg2="$TEST_TEMP_DIR/config2.yaml"
printf 'backends:\n  memory: ruflo\n' > "$cfg2"
export ZBUILD_CONFIG_FILE="$cfg2"
export ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT"
unset ZBUILD_MEMORY_BACKEND 2>/dev/null || true

warn_output2="$(zbuild_config_validate_backends 2>&1 || true)"
# Should NOT warn since ruflo plugin now exists
if grep -q "backend.missing" <<< "$warn_output2"; then
    assert_fail "no backend.missing warn when plugin is present" \
        "unexpected warn output: $warn_output2"
else
    assert_pass "no backend.missing warn when plugin is present"
fi

# ─── Cleanup ─────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
