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
#   SPEC-2: orch_load_backend "sequential" → hardcoded path to the fallback backend
#           via hardcoded path → sources it → returns 0.
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
#   old code: sources the fallback backend via hardcoded _ZBUILD_ROOT path → BACKEND_LOADED=1
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
_SPEC2_ERR="$(orch_load_backend "sequential" 2>&1)" || _SPEC2_RC=$?

if [[ "$_SPEC2_RC" -ne 0 ]]; then
    assert_pass "[#1801/SPEC-2] orch_load_backend 'sequential' returns non-zero (sequential fallback removed)"
else
    assert_fail "[#1801/SPEC-2] orch_load_backend 'sequential' must return non-zero (sequential fallback removed)" \
        "returned 0; old code finds the fallback backend via hardcoded _ZBUILD_ROOT path and sources it"
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
_SPEC4_ERR="$(orch_load_backend "orch-absent-spec4" 2>&1)" || _SPEC4_RC=$?

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
_SPEC10_ERR="$(orch_load_backend "orch-broken-spec10" 2>&1)" || _SPEC10_RC=$?

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

# ── SPEC-4 static: runner.sh gates on _ZBUILD_ORCH_BACKEND_DISPOSITION ────────
# runner.sh must check _ZBUILD_ORCH_BACKEND_DISPOSITION immediately after
# sourcing contract.sh and exit 1 naming the backend when the disposition is
# `misconfigured`, before dispatching any stage.
#
# Old code: no such check in runner.sh → grep fails → assertion FAILS on old code.
# New code: the check exists → grep succeeds → assertion PASSES.
print_test_section "[#1801/SPEC-4] static: runner.sh contains _ZBUILD_ORCH_BACKEND_DISPOSITION gate"

if grep -q '_ZBUILD_ORCH_BACKEND_DISPOSITION' "$REPO_ROOT/core/pipeline/runner.sh"; then
    assert_pass "[#1801/SPEC-4] runner.sh contains _ZBUILD_ORCH_BACKEND_DISPOSITION gate (checked after contract.sh)"
else
    assert_fail "[#1801/SPEC-4] runner.sh must check _ZBUILD_ORCH_BACKEND_DISPOSITION after sourcing contract.sh" \
        "grep found no _ZBUILD_ORCH_BACKEND_DISPOSITION in runner.sh; old code has no disposition gate"
fi

# ── SPEC-4 e2e: absent backend fails full pipeline run as misconfigured ───────
# Create a minimal installed tree (rsync), remove orch-bash-parallel from it,
# then run bash $ZBUILD_HOME/core/pipeline/runner.sh. With _ZBUILD_ROOT pointing
# at the temp install, the last-resort check ($ZBUILD_HOME/plugins/tool/orch-bash-
# parallel/plugin.sh) also fails — so both the registry path and last resort agree
# the backend is absent.
#
# Old code: runner.sh ignores _ZBUILD_ORCH_BACKEND_DISPOSITION → continues →
#   eventually fails with "orch_spawn: not implemented" or similar (not "misconfigured").
# New code: runner.sh gates early → exits 1 with "misconfigured" naming the backend.
print_test_section "[#1801/SPEC-4] e2e: absent backend fails pipeline as misconfigured"

if ! command -v rsync >/dev/null 2>&1; then
    SKIP=$((SKIP + 1))
    printf '  \033[38;2;250;204;21mSKIP\033[0m: [#1801/SPEC-4] e2e: rsync not available\n' >&2
else
    _E2E_S4_INSTALL="$TEST_TEMP_DIR/e2e-install-spec4"
    mkdir -p "$_E2E_S4_INSTALL"
    rsync -aL --quiet \
        "$REPO_ROOT/core" \
        "$REPO_ROOT/plugins" \
        "$REPO_ROOT/config" \
        "$REPO_ROOT/scripts" \
        "$_E2E_S4_INSTALL/"
    # Remove the default backend from the temp install so both the registry scan
    # and the bash-parallel last-resort check fail.
    rm -rf "$_E2E_S4_INSTALL/plugins/tool/orch-bash-parallel"

    _E2E_S4_STATE="$TEST_TEMP_DIR/e2e-s4-state"
    _E2E_S4_EVDIR="$TEST_TEMP_DIR/e2e-s4-events"
    mkdir -p "$_E2E_S4_STATE" "$_E2E_S4_EVDIR"
    _E2E_S4_RC=0
    _E2E_S4_OUT="$(
        ZBUILD_STATE_DIR="$_E2E_S4_STATE" \
        ZBUILD_EVENTS_DIR="$_E2E_S4_EVDIR" \
        ZBUILD_EVENTS_JSONL="$_E2E_S4_EVDIR/events.jsonl" \
        ZBUILD_MODELS_FILE="$_E2E_S4_INSTALL/config/models.json" \
        ZBUILD_EVENT_SCHEMA="$_E2E_S4_INSTALL/config/event-schema.json" \
        ZBUILD_CONTRACT_VALIDATOR=warn \
        ZBUILD_CYCLES_ENABLED=0 \
        ZBUILD_VISION_GATE=off \
        bash "$_E2E_S4_INSTALL/core/pipeline/runner.sh" \
            --template simple --goal "e2e-spec4-absent" 2>&1
    )" || _E2E_S4_RC=$?

    if [[ "$_E2E_S4_RC" -ne 0 ]]; then
        assert_pass "[#1801/SPEC-4] e2e: absent backend causes pipeline to exit non-zero"
    else
        assert_fail "[#1801/SPEC-4] e2e: absent backend must cause pipeline to exit non-zero" \
            "runner exited 0; expected non-zero when backend missing from installed tree"
    fi

    if grep -q 'misconfigured' <<< "$_E2E_S4_OUT"; then
        assert_pass "[#1801/SPEC-4] e2e: pipeline output names absent backend as 'misconfigured'"
    else
        assert_fail "[#1801/SPEC-4] e2e: pipeline output must name absent backend as 'misconfigured'" \
            "output did not contain 'misconfigured'; old code: no runner.sh gate, orch_spawn stub fires with 'not implemented' instead; got: ${_E2E_S4_OUT:0:300}"
    fi

    if grep -q 'bash-parallel' <<< "$_E2E_S4_OUT"; then
        assert_pass "[#1801/SPEC-4] e2e: pipeline output names the missing backend 'bash-parallel'"
    else
        assert_fail "[#1801/SPEC-4] e2e: pipeline output must name the missing backend" \
            "output did not contain 'bash-parallel'; got: ${_E2E_S4_OUT:0:300}"
    fi
fi

# ── SPEC-10 e2e: unreadable plugin.sh fails full pipeline run as misconfigured ─
# Same minimal-install approach: rsync, then chmod 000 the backend plugin.sh.
# The plugin directory and manifest are present (discovery succeeds) but plugin.sh
# is unreadable, simulating a corrupt or permission-denied installation.
#
# Old code: runner.sh ignores disposition → continues without the check.
# New code: disposition=misconfigured is caught by the runner gate → exits 1.
print_test_section "[#1801/SPEC-10] e2e: unreadable plugin.sh fails pipeline as misconfigured"

if ! command -v rsync >/dev/null 2>&1; then
    SKIP=$((SKIP + 1))
    printf '  \033[38;2;250;204;21mSKIP\033[0m: [#1801/SPEC-10] e2e: rsync not available\n' >&2
else
    _E2E_S10_INSTALL="$TEST_TEMP_DIR/e2e-install-spec10"
    mkdir -p "$_E2E_S10_INSTALL"
    rsync -aL --quiet \
        "$REPO_ROOT/core" \
        "$REPO_ROOT/plugins" \
        "$REPO_ROOT/config" \
        "$REPO_ROOT/scripts" \
        "$_E2E_S10_INSTALL/"
    # Make orch-bash-parallel's plugin.sh unreadable.
    chmod 000 "$_E2E_S10_INSTALL/plugins/tool/orch-bash-parallel/plugin.sh"

    _E2E_S10_STATE="$TEST_TEMP_DIR/e2e-s10-state"
    _E2E_S10_EVDIR="$TEST_TEMP_DIR/e2e-s10-events"
    mkdir -p "$_E2E_S10_STATE" "$_E2E_S10_EVDIR"
    _E2E_S10_RC=0
    _E2E_S10_OUT="$(
        ZBUILD_STATE_DIR="$_E2E_S10_STATE" \
        ZBUILD_EVENTS_DIR="$_E2E_S10_EVDIR" \
        ZBUILD_EVENTS_JSONL="$_E2E_S10_EVDIR/events.jsonl" \
        ZBUILD_MODELS_FILE="$_E2E_S10_INSTALL/config/models.json" \
        ZBUILD_EVENT_SCHEMA="$_E2E_S10_INSTALL/config/event-schema.json" \
        ZBUILD_CONTRACT_VALIDATOR=warn \
        ZBUILD_CYCLES_ENABLED=0 \
        ZBUILD_VISION_GATE=off \
        bash "$_E2E_S10_INSTALL/core/pipeline/runner.sh" \
            --template simple --goal "e2e-spec10-unreadable" 2>&1
    )" || _E2E_S10_RC=$?

    # Restore permissions so cleanup_test_env can remove the directory.
    chmod 644 "$_E2E_S10_INSTALL/plugins/tool/orch-bash-parallel/plugin.sh" 2>/dev/null || true

    if [[ "$_E2E_S10_RC" -ne 0 ]]; then
        assert_pass "[#1801/SPEC-10] e2e: unreadable plugin.sh causes pipeline to exit non-zero"
    else
        assert_fail "[#1801/SPEC-10] e2e: unreadable plugin.sh must cause pipeline to exit non-zero" \
            "runner exited 0; expected non-zero when plugin.sh is chmod 000"
    fi

    if grep -q 'misconfigured' <<< "$_E2E_S10_OUT"; then
        assert_pass "[#1801/SPEC-10] e2e: pipeline output names unreadable plugin.sh as 'misconfigured'"
    else
        assert_fail "[#1801/SPEC-10] e2e: pipeline output must name unreadable plugin.sh as 'misconfigured'" \
            "output did not contain 'misconfigured'; old code: no runner.sh gate; got: ${_E2E_S10_OUT:0:300}"
    fi

    if grep -q 'bash-parallel' <<< "$_E2E_S10_OUT"; then
        assert_pass "[#1801/SPEC-10] e2e: pipeline output names the misconfigured backend 'bash-parallel'"
    else
        assert_fail "[#1801/SPEC-10] e2e: pipeline output must name the misconfigured backend" \
            "output did not contain 'bash-parallel'; got: ${_E2E_S10_OUT:0:300}"
    fi
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
