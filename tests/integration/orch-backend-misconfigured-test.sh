#!/usr/bin/env bash
# tests/integration/orch-backend-misconfigured-test.sh
#
# SPEC-2 (#1801): Running with a backend configured as `sequential` (or any
# name that resolves to no plugin) fails the run as `misconfigured` naming the
# backend; the sequential fallback in `orch_load_backend` is removed.
#
# SPEC-4 (#1801): A configured backend plugin that is absent from the installed
# tree (not the checkout) fails the run as `misconfigured` naming the missing
# backend.
#
# SPEC-10 (#1801): A backend whose plugin directory is present but whose config
# file is unreadable (permissions, corrupt, or missing) fails the run as
# `misconfigured` naming the backend — tested from the installed tree.
#
# All three must FAIL on old code (which has the sequential fallback) and PASS
# on new code (which removes the fallback and returns 1 naming the backend).
#
# Old code behaviour under each SPEC:
#   SPEC-2: orch_load_backend "sequential" → hardcoded path to orch-sequential/plugin.sh
#           found at _ZBUILD_ROOT → sources it → returns 0.
#   SPEC-4: orch_load_backend "absent-backend" → _orch_find_backend_dir fails →
#           general sequential fallback fires → returns 0 with a warning.
#   SPEC-10: source on unreadable plugin.sh fails silently (no set -e in contract.sh) →
#            _ZBUILD_ORCH_BACKEND_LOADED=1 runs anyway → returns 0.
#
# New code: every case returns 1, _ZBUILD_ORCH_BACKEND_LOADED stays 0, and
# stderr names the backend.
#
# [#1801/SPEC-2] [#1801/SPEC-4] [#1801/SPEC-10]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "orch_load_backend fails misconfigured naming backend when fallback removed (#1801 SPEC-2,4,10)"
setup_test_env "orch-backend-misconfigured"

# Prevent auto-config-file reads from picking up the project's real config.
export ZBUILD_CONFIG_FILE="/dev/null"
export ZBUILD_PROJECT_ROOT="$TEST_TEMP_DIR/project"

# Source contract.sh — it auto-calls _orch_load_backend at end.
# With ZBUILD_PLUGINS_ROOT pointing at an empty dir and no zbuild_config_get_backend
# available, it defaults to "sequential" and:
#   old code: sources orch-sequential via hardcoded _ZBUILD_ROOT path → BACKEND_LOADED=1
#   new code: no fallback → orch_load_backend returns 1 (silenced by || true) → BACKEND_LOADED=0
# We reset _ZBUILD_ORCH_BACKEND_LOADED=0 before each SPEC section so the
# explicit call we are testing starts from a clean state.
_EMPTY_PLUGINS="$TEST_TEMP_DIR/empty-plugins"
mkdir -p "$_EMPTY_PLUGINS"
export ZBUILD_PLUGINS_ROOT="$_EMPTY_PLUGINS"
export ZBUILD_ORCHESTRATOR_BACKEND="sequential"

# shellcheck source=../../core/orch/contract.sh
source "$REPO_ROOT/core/orch/contract.sh"

# ── SPEC-2: "sequential" name resolves to no plugin (fallback removed) ───────
print_test_section "[#1801/SPEC-2] orch_load_backend 'sequential' fails when sequential fallback is removed"

_ZBUILD_ORCH_BACKEND_LOADED=0
export ZBUILD_PLUGINS_ROOT="$_EMPTY_PLUGINS"
_SPEC2_ERR=""
_SPEC2_RC=0
set +e
_SPEC2_ERR="$(orch_load_backend "sequential" 2>&1)"
_SPEC2_RC=$?
set -e

if [[ "$_SPEC2_RC" -ne 0 ]]; then
    assert_pass "[#1801/SPEC-2] orch_load_backend 'sequential' returns non-zero (sequential fallback removed)"
else
    assert_fail "[#1801/SPEC-2] orch_load_backend 'sequential' must return non-zero (sequential fallback removed)" \
        "returned 0; old code finds orch-sequential via hardcoded _ZBUILD_ROOT path and sources it"
fi

if [[ "${_ZBUILD_ORCH_BACKEND_LOADED:-0}" -ne 1 ]]; then
    assert_pass "[#1801/SPEC-2] _ZBUILD_ORCH_BACKEND_LOADED is not 1 (backend correctly not loaded)"
else
    assert_fail "[#1801/SPEC-2] _ZBUILD_ORCH_BACKEND_LOADED must not be 1 when backend failed to load" \
        "sentinel set to 1; old code sets it after sourcing the hardcoded sequential path"
fi

if grep -q 'sequential' <<< "$_SPEC2_ERR"; then
    assert_pass "[#1801/SPEC-2] error output names the backend 'sequential'"
else
    assert_fail "[#1801/SPEC-2] error output must name the backend 'sequential'" \
        "stderr did not contain 'sequential'; got: ${_SPEC2_ERR:-<empty>}"
fi

# The run must be reported as `misconfigured` (not a generic failure).
# New code emits "misconfigured" in its error message or sets
# _ZBUILD_ORCH_BACKEND_DISPOSITION=misconfigured; old code silently succeeds
# so this never reaches a misconfigured path at all.
if grep -q 'misconfigured' <<< "$_SPEC2_ERR" || \
   [[ "${_ZBUILD_ORCH_BACKEND_DISPOSITION:-}" == "misconfigured" ]]; then
    assert_pass "[#1801/SPEC-2] backend failure is reported as 'misconfigured'"
else
    assert_fail "[#1801/SPEC-2] backend failure must be reported as 'misconfigured'" \
        "neither error output nor _ZBUILD_ORCH_BACKEND_DISPOSITION contained 'misconfigured'; got: ${_SPEC2_ERR:-<empty>}"
fi

# ── SPEC-4: absent backend plugin fails naming the missing backend ─────────────
# Backend name that is not present in the empty ZBUILD_PLUGINS_ROOT and has no
# hardcoded fallback. Old code falls back to sequential silently; new code fails.
print_test_section "[#1801/SPEC-4] orch_load_backend absent plugin fails naming backend (no general fallback)"

_ZBUILD_ORCH_BACKEND_LOADED=0
export ZBUILD_PLUGINS_ROOT="$_EMPTY_PLUGINS"
_SPEC4_ERR=""
_SPEC4_RC=0
set +e
_SPEC4_ERR="$(orch_load_backend "orch-absent-spec4" 2>&1)"
_SPEC4_RC=$?
set -e

if [[ "$_SPEC4_RC" -ne 0 ]]; then
    assert_pass "[#1801/SPEC-4] orch_load_backend absent plugin returns non-zero (no fallback)"
else
    assert_fail "[#1801/SPEC-4] orch_load_backend absent plugin must return non-zero (no fallback)" \
        "returned 0; old code's general sequential fallback fires for any missing backend"
fi

if [[ "${_ZBUILD_ORCH_BACKEND_LOADED:-0}" -ne 1 ]]; then
    assert_pass "[#1801/SPEC-4] _ZBUILD_ORCH_BACKEND_LOADED is not 1 (absent backend)"
else
    assert_fail "[#1801/SPEC-4] _ZBUILD_ORCH_BACKEND_LOADED must not be 1 for absent backend" \
        "sentinel set to 1; old code's general fallback to sequential sets it"
fi

if grep -q 'orch-absent-spec4' <<< "$_SPEC4_ERR"; then
    assert_pass "[#1801/SPEC-4] error output names the missing backend 'orch-absent-spec4'"
else
    assert_fail "[#1801/SPEC-4] error output must name the missing backend 'orch-absent-spec4'" \
        "stderr: ${_SPEC4_ERR:-<empty>}"
fi

if grep -q 'misconfigured' <<< "$_SPEC4_ERR" || \
   [[ "${_ZBUILD_ORCH_BACKEND_DISPOSITION:-}" == "misconfigured" ]]; then
    assert_pass "[#1801/SPEC-4] absent backend failure is reported as 'misconfigured'"
else
    assert_fail "[#1801/SPEC-4] absent backend failure must be reported as 'misconfigured'" \
        "neither error output nor _ZBUILD_ORCH_BACKEND_DISPOSITION contained 'misconfigured'; got: ${_SPEC4_ERR:-<empty>}"
fi

# ── SPEC-10: present dir, unreadable plugin.sh — fails naming the backend ─────
# Plugin directory and manifest are present (discovery succeeds) but plugin.sh
# is unreadable (chmod 000), simulating a corrupt or permission-denied install.
#
# Old code: source on unreadable file fails silently (no set -e in contract.sh),
#   then sets _ZBUILD_ORCH_BACKEND_LOADED=1 and returns 0.
# New code: detects source failure, returns 1 naming the backend.
print_test_section "[#1801/SPEC-10] orch_load_backend unreadable plugin.sh fails naming backend"

_S10_PLUGINS="$TEST_TEMP_DIR/spec10-plugins"
_S10_PLUGIN_DIR="$_S10_PLUGINS/tool/orch-broken-spec10"
mkdir -p "$_S10_PLUGIN_DIR"
cat > "$_S10_PLUGIN_DIR/manifest.yaml" <<'MANIFEST'
id: orch-broken-spec10
name: Broken Backend Spec10
kind: tool
version: 0.0.1
provides:
  role: orchestrator-backend
  alias: orch-broken-spec10
MANIFEST
# Write a syntactically valid plugin.sh then remove read permission.
printf 'orch_spawn() { return 0; }\norch_capabilities() { printf '"'"'{}'"'"'; }\n' \
    > "$_S10_PLUGIN_DIR/plugin.sh"
chmod 000 "$_S10_PLUGIN_DIR/plugin.sh"

export ZBUILD_PLUGINS_ROOT="$_S10_PLUGINS"
_ZBUILD_ORCH_BACKEND_LOADED=0
_SPEC10_ERR=""
_SPEC10_RC=0
set +e
_SPEC10_ERR="$(orch_load_backend "orch-broken-spec10" 2>&1)"
_SPEC10_RC=$?
set -e

# Restore permissions so cleanup_test_env can remove the directory.
chmod 644 "$_S10_PLUGIN_DIR/plugin.sh" 2>/dev/null || true

if [[ "$_SPEC10_RC" -ne 0 ]]; then
    assert_pass "[#1801/SPEC-10] orch_load_backend with unreadable plugin.sh returns non-zero"
else
    assert_fail "[#1801/SPEC-10] orch_load_backend with unreadable plugin.sh must return non-zero" \
        "returned 0; old code: source fails silently, _ZBUILD_ORCH_BACKEND_LOADED=1 runs anyway, returns 0"
fi

if [[ "${_ZBUILD_ORCH_BACKEND_LOADED:-0}" -ne 1 ]]; then
    assert_pass "[#1801/SPEC-10] _ZBUILD_ORCH_BACKEND_LOADED is not 1 (unreadable plugin.sh)"
else
    assert_fail "[#1801/SPEC-10] _ZBUILD_ORCH_BACKEND_LOADED must not be 1 when plugin.sh unreadable" \
        "sentinel set to 1; old code sets it even when source fails"
fi

if grep -q 'orch-broken-spec10' <<< "$_SPEC10_ERR"; then
    assert_pass "[#1801/SPEC-10] error output names the backend 'orch-broken-spec10'"
else
    assert_fail "[#1801/SPEC-10] error output must name the backend 'orch-broken-spec10'" \
        "stderr: ${_SPEC10_ERR:-<empty>}"
fi

if grep -q 'misconfigured' <<< "$_SPEC10_ERR" || \
   [[ "${_ZBUILD_ORCH_BACKEND_DISPOSITION:-}" == "misconfigured" ]]; then
    assert_pass "[#1801/SPEC-10] unreadable plugin.sh failure is reported as 'misconfigured'"
else
    assert_fail "[#1801/SPEC-10] unreadable plugin.sh failure must be reported as 'misconfigured'" \
        "neither error output nor _ZBUILD_ORCH_BACKEND_DISPOSITION contained 'misconfigured'; got: ${_SPEC10_ERR:-<empty>}"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
