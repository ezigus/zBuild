#!/usr/bin/env bash
# tests/unit/router-permissions-deny-test.sh — the spawn's deny list carries the
# Edit() rules the engine hands it (#2022).
#
# #1919 P5 measured that `permissions.deny` IS honoured, but only in Edit(...)
# form — a Write(...) rule silently matches nothing. permissions.sh has written
# `{permissions:{deny:[]}}` ever since, with a comment reserving the list for
# "the evidence-based deny list from the #1809 sweep". This is its first
# occupant: the acceptance TESTFILES, denied to every spawn that does not own
# them, so build cannot rewrite an assertion to agree with its own code.
#
# The POLICY (who owns the assertions) is the engine's and is not decided here.
# permissions.sh renders what it is handed — the same discipline as the ADR-059
# note already in the file: derive from exported env, never from a path literal.
#
#   SPEC-1 [change]: a path in ZBUILD_PERMISSION_DENY_EDIT becomes an Edit()
#                    rule in the written settings file
#   SPEC-2 [change]: every path is rendered, not just the first
#   SPEC-3 [guard] : with the variable unset the deny list stays empty — the
#                    shipped behaviour is unchanged for every existing spawn
#   SPEC-4 [guard] : the file still passes jq validation with rules present;
#                    SPEC-3 of #1919 refuses the spawn if it does not
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "spawn deny list carries the engine's Edit() rules (#2022)"
setup_test_env "router-permissions-deny"
_test_cleanup_hook() { cleanup_test_env; }

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$TEST_TEMP_DIR/events"

# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../core/router/permissions.sh
source "$REPO_ROOT/core/router/permissions.sh"

export ZBUILD_STAGE_SCRATCH="$TEST_TEMP_DIR/scratch"
export ZBUILD_REPO_ROOT="$TEST_TEMP_DIR/repo"
export ZBUILD_ARTIFACT_DIR="$TEST_TEMP_DIR/run/artifacts"
mkdir -p "$ZBUILD_STAGE_SCRATCH" "$ZBUILD_REPO_ROOT" "$ZBUILD_ARTIFACT_DIR"

_TF1="$ZBUILD_REPO_ROOT/tests/acceptance-a-test.sh"
_TF2="$ZBUILD_REPO_ROOT/plugins/tool/test/tests/test-test.sh"

# ─── With rules handed in ───────────────────────────────────────────────────
export ZBUILD_PERMISSION_DENY_EDIT="$_TF1
$_TF2"
_ZBUILD_PERMISSIONS_SETTINGS_FILE=""
set +e; _zbuild_build_permissions_settings; _rc=$?; set -e
assert_eq "[SPEC-1] the builder still returns rc=0 with rules present" "0" "$_rc"

_DENY="$(jq -r '.permissions.deny[]?' "$_ZBUILD_PERMISSIONS_SETTINGS_FILE" 2>/dev/null || true)"
assert_contains "[SPEC-1][change] the first testfile becomes an Edit() deny rule" \
    "$_DENY" "Edit($_TF1)"
assert_contains "[SPEC-2][change] the second is rendered too, not just the first" \
    "$_DENY" "Edit($_TF2)"

assert_eq "[SPEC-4][guard] the settings file still passes jq validation" \
    "0" "$(jq empty "$_ZBUILD_PERMISSIONS_SETTINGS_FILE" >/dev/null 2>&1; echo $?)"

# ─── With the variable unset — shipped behaviour is untouched ───────────────
unset ZBUILD_PERMISSION_DENY_EDIT
_ZBUILD_PERMISSIONS_SETTINGS_FILE=""
set +e; _zbuild_build_permissions_settings; _rc2=$?; set -e
assert_eq "[SPEC-3] the builder returns rc=0 with no rules" "0" "$_rc2"
assert_eq "[SPEC-3][guard] the deny list stays empty when the engine hands nothing" \
    "0" "$(jq -r '.permissions.deny | length' "$_ZBUILD_PERMISSIONS_SETTINGS_FILE" 2>/dev/null || echo BAD)"

print_test_results
exit $((FAIL > 0))
