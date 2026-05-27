#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  zBuild plugin-registry — facade                                          ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# ADR-001 implementation. Plugins live in plugins/<kind>/<name>/ with a
# manifest.yaml and plugin.sh. The registry discovers them, validates
# manifests, applies a lockfile, and dispatches lifecycle hooks.
#
# Issue #364: this file used to be the monolithic 668-line implementation. It
# now sources three focused modules so each stays under the 500-line limit:
#
#   - manifest-validation.sh  → yaml_get/yaml_get_list/_yaml_get_requires_core_list,
#                                ZBUILD_PLUGIN_KINDS / _required_hooks_for_kind,
#                                validate_manifest
#   - discovery.sh            → discover_plugins, list_plugins_table,
#                                lockfile_write/validate, _hash_plugin_pair,
#                                verify_plugin_for_source, find_plugin_for_role,
#                                ZBUILD_LOCKFILE / ZBUILD_DISABLED_FILE
#   - lifecycle.sh            → scan_plugin_outputs, plugin_hook_call
#
# Every previous public entry point (and the ZBUILD_* env vars + the
# _ZBUILD_REGISTRY_LOADED guard) is preserved, so existing callers see no
# change in surface or behavior.
# Sourced library: inherits caller's pipefail settings; do not add set -euo pipefail here.

[[ -n "${_ZBUILD_REGISTRY_LOADED:-}" ]] && return 0
_ZBUILD_REGISTRY_LOADED=1

_ZBUILD_REGISTRY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ZBUILD_ROOT="$(cd "$_ZBUILD_REGISTRY_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$_ZBUILD_ROOT/scripts/lib/helpers.sh"

# Order matters: discovery + lifecycle call yaml_get / validate_manifest /
# verify_plugin_for_source from the earlier modules.
# shellcheck source=manifest-validation.sh
source "$_ZBUILD_REGISTRY_DIR/manifest-validation.sh"
# shellcheck source=discovery.sh
source "$_ZBUILD_REGISTRY_DIR/discovery.sh"
# shellcheck source=lifecycle.sh
source "$_ZBUILD_REGISTRY_DIR/lifecycle.sh"
