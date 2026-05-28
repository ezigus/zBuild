#!/usr/bin/env bash
# Tests: scripts/lib/plugin-bootstrap.sh — shared plugin preamble helper (issue #381)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "scripts/lib/plugin-bootstrap.sh — shared plugin preamble helper"

setup_test_env "plugin-bootstrap"

# ─── Source the helper under test ─────────────────────────────────────────────
# shellcheck source=../../scripts/lib/plugin-bootstrap.sh
source "$REPO_ROOT/scripts/lib/plugin-bootstrap.sh"

# ─── Test 1: double-source guard ─────────────────────────────────────────────
print_test_section "1. double-source guard — _ZBUILD_PLUGIN_BOOTSTRAP_LOADED is set"
assert_eq "load guard set" "1" "${_ZBUILD_PLUGIN_BOOTSTRAP_LOADED:-}"

# ─── Test 2: zbuild_plugin_bootstrap resolves _ZBUILD_PLUGIN_DIR correctly ───
print_test_section "2. zbuild_plugin_bootstrap resolves _ZBUILD_PLUGIN_DIR"

# Simulate a plugin located at plugins/agent/build/plugin.sh
_ZBUILD_PLUGIN_DIR=""
_ZBUILD_PLUGIN_ROOT=""

FAKE_PLUGIN_SOURCE="$REPO_ROOT/plugins/agent/build/plugin.sh"
zbuild_plugin_bootstrap "$FAKE_PLUGIN_SOURCE"

assert_eq "_ZBUILD_PLUGIN_DIR is the plugin's directory" \
    "$REPO_ROOT/plugins/agent/build" \
    "$_ZBUILD_PLUGIN_DIR"

# ─── Test 3: zbuild_plugin_bootstrap resolves _ZBUILD_PLUGIN_ROOT correctly ──
print_test_section "3. zbuild_plugin_bootstrap resolves _ZBUILD_PLUGIN_ROOT"
assert_eq "_ZBUILD_PLUGIN_ROOT is the repo root" \
    "$REPO_ROOT" \
    "$_ZBUILD_PLUGIN_ROOT"

# ─── Test 4: helpers.sh is sourced — warn/error functions are available ───────
print_test_section "4. helpers.sh sourced — warn and error functions exist"
assert_eq "warn function defined" "function" "$(type -t warn 2>/dev/null || echo missing)"
assert_eq "error function defined" "function" "$(type -t error 2>/dev/null || echo missing)"

# ─── Test 5: _ZBUILD_HELPERS_LOADED guard is set (helpers.sh sourced) ─────────
print_test_section "5. _ZBUILD_HELPERS_LOADED is set (helpers.sh was sourced)"
assert_eq "_ZBUILD_HELPERS_LOADED set" "1" "${_ZBUILD_HELPERS_LOADED:-}"

# ─── Test 6: works for a tool plugin (plugins/tool/<name>/) ───────────────────
print_test_section "6. zbuild_plugin_bootstrap works for plugins/tool/ path"
_ZBUILD_PLUGIN_DIR=""
_ZBUILD_PLUGIN_ROOT=""

FAKE_TOOL_SOURCE="$REPO_ROOT/plugins/tool/cache-local/plugin.sh"
zbuild_plugin_bootstrap "$FAKE_TOOL_SOURCE"

assert_eq "_ZBUILD_PLUGIN_DIR for tool plugin" \
    "$REPO_ROOT/plugins/tool/cache-local" \
    "$_ZBUILD_PLUGIN_DIR"
assert_eq "_ZBUILD_PLUGIN_ROOT for tool plugin" \
    "$REPO_ROOT" \
    "$_ZBUILD_PLUGIN_ROOT"

# ─── Test 7: missing argument returns exit 1 ──────────────────────────────────
print_test_section "7. missing argument exits 1"
set +e
zbuild_plugin_bootstrap "" 2>/dev/null
rc=$?
set -e
assert_exit_code "empty arg exits 1" "1" "$rc"

# ─── Test 8: path that cannot resolve repo root exits 1 ──────────────────────
print_test_section "8. bad path (helpers.sh absent) exits 1"
set +e
# Provide a path that is only 1 level inside a tmp dir so 3-levels-up hits /tmp
# or somewhere without scripts/lib/helpers.sh
zbuild_plugin_bootstrap "/tmp/fake-plugin.sh" 2>/dev/null
rc=$?
set -e
assert_exit_code "bad path exits 1" "1" "$rc"

print_test_results
