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

# ─── Test 4: helpers.sh is sourced — verify via subshell with clean load guard ──
# Run in a subshell that unsets the helpers load guard so we can verify
# zbuild_plugin_bootstrap actually sources helpers.sh rather than relying on
# the outer shell's already-sourced state.
print_test_section "4. helpers.sh sourced — warn and error functions exist in fresh env"
helpers_sourced_ok="$(
    unset _ZBUILD_HELPERS_LOADED 2>/dev/null || true
    unset -f warn error 2>/dev/null || true
    # Re-source bootstrap with cleared state (must unset the load guard too)
    unset _ZBUILD_PLUGIN_BOOTSTRAP_LOADED 2>/dev/null || true
    # shellcheck source=../../scripts/lib/plugin-bootstrap.sh
    source "$REPO_ROOT/scripts/lib/plugin-bootstrap.sh"
    _ZBUILD_PLUGIN_DIR=""
    _ZBUILD_PLUGIN_ROOT=""
    zbuild_plugin_bootstrap "$REPO_ROOT/plugins/agent/build/plugin.sh" 2>/dev/null
    if declare -f warn >/dev/null 2>&1 && declare -f error >/dev/null 2>&1; then
        echo "ok"
    else
        echo "missing"
    fi
)"
assert_eq "warn and error defined after zbuild_plugin_bootstrap" "ok" "$helpers_sourced_ok"

# ─── Test 5: _ZBUILD_HELPERS_LOADED guard is set (helpers.sh sourced) ─────────
print_test_section "5. _ZBUILD_HELPERS_LOADED is set in fresh env after zbuild_plugin_bootstrap"
helpers_loaded="$(
    unset _ZBUILD_HELPERS_LOADED 2>/dev/null || true
    unset _ZBUILD_PLUGIN_BOOTSTRAP_LOADED 2>/dev/null || true
    # shellcheck source=../../scripts/lib/plugin-bootstrap.sh
    source "$REPO_ROOT/scripts/lib/plugin-bootstrap.sh"
    zbuild_plugin_bootstrap "$REPO_ROOT/plugins/agent/build/plugin.sh" 2>/dev/null
    echo "${_ZBUILD_HELPERS_LOADED:-unset}"
)"
assert_eq "_ZBUILD_HELPERS_LOADED set in fresh env" "1" "$helpers_loaded"

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
zbuild_plugin_bootstrap "/tmp/fake-plugin.sh" 2>/dev/null
rc=$?
set -e
assert_exit_code "bad path exits 1" "1" "$rc"

cleanup_test_env
print_test_results
