#!/usr/bin/env bash
# Tests: #1919 (C10) — permissions.sh builds acceptEdits settings file.
# SPEC-2: settings file contains correct allowedDirectories.
# SPEC-3: missing jq causes spawn refusal (rc≠0), not silent bypass.
# SPEC-4: grep core/router/ for skip-permissions returns nothing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "router-permissions — #1919 C10 acceptEdits settings (#1919)"
setup_test_env "router-permissions"
_test_cleanup_hook() { cleanup_test_env; }

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$TEST_TEMP_DIR/events"

# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../core/router/permissions.sh
source "$REPO_ROOT/core/router/permissions.sh"

# ─── P1: SPEC-2 — settings file contains correct allowedDirectories ──────────
export ZBUILD_STAGE_SCRATCH="$TEST_TEMP_DIR/scratch-p1"
export ZBUILD_REPO_ROOT="$TEST_TEMP_DIR/repo-p1"
mkdir -p "$ZBUILD_STAGE_SCRATCH" "$ZBUILD_REPO_ROOT"

_ZBUILD_PERMISSIONS_SETTINGS_FILE=""
set +e
_zbuild_build_permissions_settings
rc_p1=$?
set -e

assert_eq "[SPEC-2] P1: _zbuild_build_permissions_settings returns rc=0" "0" "$rc_p1"
if [[ -n "$_ZBUILD_PERMISSIONS_SETTINGS_FILE" ]]; then
    assert_pass "[SPEC-2] P1: settings file path is non-empty"
else
    assert_fail "[SPEC-2] P1: settings file path is non-empty" "path is empty"
fi

if [[ -f "$_ZBUILD_PERMISSIONS_SETTINGS_FILE" ]]; then
    assert_pass "[SPEC-2] P1: settings file exists on disk"
else
    assert_fail "[SPEC-2] P1: settings file exists on disk" "file missing: $_ZBUILD_PERMISSIONS_SETTINGS_FILE"
fi

# Validate allowedDirectories contains repo root.
_dirs="$(jq -r '.permissions.allowedDirectories[]' "$_ZBUILD_PERMISSIONS_SETTINGS_FILE" 2>/dev/null || true)"
if grep -qxF "$ZBUILD_REPO_ROOT" <<< "$_dirs"; then
    assert_pass "[SPEC-2] P1: allowedDirectories contains ZBUILD_REPO_ROOT"
else
    assert_fail "[SPEC-2] P1: allowedDirectories contains ZBUILD_REPO_ROOT" "dirs: $_dirs"
fi

# Validate allowedDirectories contains scratch dir.
if grep -qxF "$ZBUILD_STAGE_SCRATCH" <<< "$_dirs"; then
    assert_pass "[SPEC-2] P1: allowedDirectories contains ZBUILD_STAGE_SCRATCH"
else
    assert_fail "[SPEC-2] P1: allowedDirectories contains ZBUILD_STAGE_SCRATCH" "dirs: $_dirs"
fi

unset ZBUILD_STAGE_SCRATCH ZBUILD_REPO_ROOT

# ─── P2: SPEC-2 — scratch fallback when ZBUILD_STAGE_SCRATCH unset ───────────
unset ZBUILD_STAGE_SCRATCH
export ZBUILD_REPO_ROOT="$TEST_TEMP_DIR/repo-p2"
mkdir -p "$ZBUILD_REPO_ROOT"
: > "$ZBUILD_EVENTS_JSONL"

_ZBUILD_PERMISSIONS_SETTINGS_FILE=""
set +e
_zbuild_build_permissions_settings
rc_p2=$?
set -e

assert_eq "[SPEC-2] P2: fallback path returns rc=0" "0" "$rc_p2"
if [[ -f "$_ZBUILD_PERMISSIONS_SETTINGS_FILE" ]]; then
    assert_pass "[SPEC-2] P2: settings file still written on scratch fallback"
else
    assert_fail "[SPEC-2] P2: settings file still written on scratch fallback" ""
fi

fallback_evt="$(grep '"router.permissions.scratch_fallback"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
if [[ "$fallback_evt" -gt 0 ]]; then
    assert_pass "[SPEC-2] P2: scratch_fallback event emitted"
else
    assert_fail "[SPEC-2] P2: scratch_fallback event emitted" "event not found"
fi

unset ZBUILD_REPO_ROOT

# ─── P3: SPEC-3 — spawn refusal when scratch dir is not writable ─────────────
# Use a read-only scratch dir so the settings file write fails.
export ZBUILD_STAGE_SCRATCH="$TEST_TEMP_DIR/scratch-p3-readonly"
export ZBUILD_REPO_ROOT="$TEST_TEMP_DIR/repo-p3"
mkdir -p "$ZBUILD_STAGE_SCRATCH" "$ZBUILD_REPO_ROOT"
chmod -w "$TEST_TEMP_DIR/scratch-p3-readonly"

_ZBUILD_PERMISSIONS_SETTINGS_FILE=""
set +e
_zbuild_build_permissions_settings 2>/dev/null
rc_p3=$?
set -e
chmod +w "$TEST_TEMP_DIR/scratch-p3-readonly"

if [[ "$rc_p3" -ne 0 ]]; then
    assert_pass "[SPEC-3] P3: unwritable scratch causes rc≠0 (spawn refusal)"
else
    assert_fail "[SPEC-3] P3: unwritable scratch should cause rc≠0 (spawn refusal)" "rc=$rc_p3"
fi

unset ZBUILD_STAGE_SCRATCH ZBUILD_REPO_ROOT

# ─── P4: SPEC-4 — no dangerously-skip-permissions in core/router/ ────────────
_skips="$(grep -rn 'dangerously-skip-permissions' "$REPO_ROOT/core/router/" \
    | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' || true)"
if [[ -z "$_skips" ]]; then
    assert_pass "[SPEC-4] P4: no non-comment dangerously-skip-permissions in core/router/"
else
    assert_fail "[SPEC-4] P4: dangerously-skip-permissions found in core/router/" "$_skips"
fi

# ─── P5: SPEC-2 — _zbuild_permission_args emits correct tokens ───────────────
export ZBUILD_STAGE_SCRATCH="$TEST_TEMP_DIR/scratch-p5"
export ZBUILD_REPO_ROOT="$TEST_TEMP_DIR/repo-p5"
mkdir -p "$ZBUILD_STAGE_SCRATCH" "$ZBUILD_REPO_ROOT"

_ZBUILD_PERMISSIONS_SETTINGS_FILE=""
_zbuild_build_permissions_settings

_perm_args="$(_zbuild_permission_args)"
if grep -qx -- "--permission-mode" <<< "$_perm_args"; then
    assert_pass "[SPEC-2] P5: _zbuild_permission_args emits --permission-mode"
else
    assert_fail "[SPEC-2] P5: _zbuild_permission_args emits --permission-mode" "args: $_perm_args"
fi
if grep -qx -- "acceptEdits" <<< "$_perm_args"; then
    assert_pass "[SPEC-2] P5: _zbuild_permission_args emits acceptEdits"
else
    assert_fail "[SPEC-2] P5: _zbuild_permission_args emits acceptEdits" "args: $_perm_args"
fi
if grep -qx -- "--settings" <<< "$_perm_args"; then
    assert_pass "[SPEC-2] P5: _zbuild_permission_args emits --settings"
else
    assert_fail "[SPEC-2] P5: _zbuild_permission_args emits --settings" "args: $_perm_args"
fi

unset ZBUILD_STAGE_SCRATCH ZBUILD_REPO_ROOT

cleanup_test_env
print_test_results
exit $((FAIL > 0))
