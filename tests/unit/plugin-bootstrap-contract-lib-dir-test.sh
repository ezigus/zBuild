#!/usr/bin/env bash
# Unit: scripts/lib/plugin-bootstrap.sh publishes _ZBUILD_CONTRACT_LIB_DIR so
# contract-reader plugins can be redirected to a working-tree grammar (#963).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugin-bootstrap — _ZBUILD_CONTRACT_LIB_DIR redirect (#963)"
setup_test_env "plugin-bootstrap-contract-lib"

# ─── SPEC-1: defaults to <repo_root>/scripts/lib when override is unset ────────
print_test_section "1. default → repo scripts/lib (normal run unchanged)"
default_dir="$(
    unset ZBUILD_CONTRACT_LIB_DIR 2>/dev/null || true
    unset _ZBUILD_PLUGIN_BOOTSTRAP_LOADED 2>/dev/null || true
    # shellcheck source=../../scripts/lib/plugin-bootstrap.sh
    source "$REPO_ROOT/scripts/lib/plugin-bootstrap.sh"
    zbuild_plugin_bootstrap "$REPO_ROOT/plugins/agent/build/plugin.sh" 2>/dev/null
    printf '%s' "${_ZBUILD_CONTRACT_LIB_DIR:-UNSET}"
)"
assert_eq "[SPEC-1] _ZBUILD_CONTRACT_LIB_DIR defaults to repo scripts/lib" \
    "$REPO_ROOT/scripts/lib" "$default_dir"

# ─── SPEC-2: an exported ZBUILD_CONTRACT_LIB_DIR override is honored ───────────
print_test_section "2. ZBUILD_CONTRACT_LIB_DIR override is published verbatim"
override_target="$TEST_TEMP_DIR/wt-grammar/scripts/lib"
override_dir="$(
    export ZBUILD_CONTRACT_LIB_DIR="$override_target"
    unset _ZBUILD_PLUGIN_BOOTSTRAP_LOADED 2>/dev/null || true
    # shellcheck source=../../scripts/lib/plugin-bootstrap.sh
    source "$REPO_ROOT/scripts/lib/plugin-bootstrap.sh"
    zbuild_plugin_bootstrap "$REPO_ROOT/plugins/agent/build/plugin.sh" 2>/dev/null
    printf '%s' "${_ZBUILD_CONTRACT_LIB_DIR:-UNSET}"
)"
assert_eq "[SPEC-2] ZBUILD_CONTRACT_LIB_DIR override is honored" \
    "$override_target" "$override_dir"

cleanup_test_env
print_test_results
