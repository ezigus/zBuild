#!/usr/bin/env bash
# Tests: scripts/lib/doctor.sh — unit-level checks for individual _check_* functions
# Covers: issues #58, #90 — zbuild doctor command
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/doctor.sh
source "$REPO_ROOT/scripts/lib/doctor.sh"

print_test_header "zbuild doctor — unit tests (issues #58, #90)"

setup_test_env "doctor-unit"

_test_cleanup_hook() { cleanup_test_env; }

# ─── TC-1: _check_bash_version passes when running bash 5 ───────────────────
# Current shell must be bash 5 (enforced by compat.sh) so BASH_VERSINFO[0] == 5
DOCTOR_PASS=0 DOCTOR_WARN=0 DOCTOR_FAIL=0
_check_bash_version
assert_eq "TC-1: bash 5 → PASS incremented" "1" "$DOCTOR_PASS"
assert_eq "TC-1: bash 5 → FAIL stays 0" "0" "$DOCTOR_FAIL"

# ─── TC-2: _check_zbuild_path fails when zbuild is not in PATH ───────────────
DOCTOR_PASS=0 DOCTOR_WARN=0 DOCTOR_FAIL=0
# Use a PATH that cannot contain zbuild
_old_path="$PATH"
PATH="$TEST_TEMP_DIR/bin:/usr/bin:/bin"
_check_zbuild_path
PATH="$_old_path"
assert_eq "TC-2: zbuild missing from PATH → FAIL incremented" "1" "$DOCTOR_FAIL"
assert_eq "TC-2: zbuild missing from PATH → PASS stays 0" "0" "$DOCTOR_PASS"

# ─── TC-3: _check_state_dir passes when dir exists and is writable ───────────
DOCTOR_PASS=0 DOCTOR_WARN=0 DOCTOR_FAIL=0
_test_state_dir="$TEST_TEMP_DIR/state-check"
mkdir -p "$_test_state_dir"
ZBUILD_STATE_DIR="$_test_state_dir" _check_state_dir
assert_eq "TC-3: writable state dir → PASS incremented" "1" "$DOCTOR_PASS"
assert_eq "TC-3: writable state dir → FAIL stays 0" "0" "$DOCTOR_FAIL"

# ─── TC-4: _check_plugin_registry warns when plugins dir is empty ─────────────
DOCTOR_PASS=0 DOCTOR_WARN=0 DOCTOR_FAIL=0
_empty_plugins="$TEST_TEMP_DIR/empty-plugins"
mkdir -p "$_empty_plugins"
ZBUILD_PLUGINS_ROOT="$_empty_plugins" _check_plugin_registry
assert_eq "TC-4: empty plugins dir → WARN incremented" "1" "$DOCTOR_WARN"
assert_eq "TC-4: empty plugins dir → FAIL stays 0" "0" "$DOCTOR_FAIL"

# ─── TC-5: _check_config_files fails when models.json is missing ─────────────
# Both models.json and event-schema.json are absent → DOCTOR_FAIL >= 1
DOCTOR_PASS=0 DOCTOR_WARN=0 DOCTOR_FAIL=0
_empty_repo="$TEST_TEMP_DIR/empty-repo"
mkdir -p "$_empty_repo"
ZBUILD_REPO_ROOT="$_empty_repo" _check_config_files
assert_gt "TC-5: missing config files → FAIL >= 1" "$DOCTOR_FAIL" "0"

# ─── TC-6: _check_config_files passes when both config files are valid JSON ───
# Both files present and valid → DOCTOR_PASS == 2, DOCTOR_FAIL == 0
DOCTOR_PASS=0 DOCTOR_WARN=0 DOCTOR_FAIL=0
_config_repo="$TEST_TEMP_DIR/config-repo"
mkdir -p "$_config_repo/config"
echo '{"models": []}' > "$_config_repo/config/models.json"
echo '{"schema": "v1"}' > "$_config_repo/config/event-schema.json"
ZBUILD_REPO_ROOT="$_config_repo" _check_config_files
assert_eq "TC-6: valid config files → PASS==2 (one per file)" "2" "$DOCTOR_PASS"
assert_eq "TC-6: valid config files → FAIL stays 0" "0" "$DOCTOR_FAIL"

# ─── TC-7: _check_config_files fails when models.json is corrupt JSON ─────────
DOCTOR_PASS=0 DOCTOR_WARN=0 DOCTOR_FAIL=0
_corrupt_repo="$TEST_TEMP_DIR/corrupt-repo"
mkdir -p "$_corrupt_repo/config"
echo 'not valid json {{{' > "$_corrupt_repo/config/models.json"
echo '{"schema": "v1"}' > "$_corrupt_repo/config/event-schema.json"
ZBUILD_REPO_ROOT="$_corrupt_repo" _check_config_files
assert_eq "TC-7: corrupt models.json → FAIL incremented" "1" "$DOCTOR_FAIL"

# ─── TC-8: _check_jq passes when jq is available ─────────────────────────────
DOCTOR_PASS=0 DOCTOR_WARN=0 DOCTOR_FAIL=0
# jq is in PATH (setup_test_env links it)
_check_jq
assert_eq "TC-8: jq available → PASS incremented" "1" "$DOCTOR_PASS"
assert_eq "TC-8: jq available → FAIL stays 0" "0" "$DOCTOR_FAIL"

# ─── TC-9: _check_jq fails when jq is not available ─────────────────────────
DOCTOR_PASS=0 DOCTOR_WARN=0 DOCTOR_FAIL=0
_old_path="$PATH"
# Remove jq from temp bin so it can't be found
rm -f "$TEST_TEMP_DIR/bin/jq"
PATH="$TEST_TEMP_DIR/bin:/usr/bin:/bin"  # no real jq
# Only run this sub-check if jq is truly gone from this PATH
if ! command -v jq >/dev/null 2>&1; then
    _check_jq
    assert_eq "TC-9: jq missing → FAIL incremented" "1" "$DOCTOR_FAIL"
else
    assert_pass "TC-9: jq still on PATH (skip jq-removal test on this platform)"
fi
PATH="$_old_path"
# Restore jq symlink for remaining tests
if command -v jq >/dev/null 2>&1; then
    ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq" 2>/dev/null || true
fi

# ─── TC-10: _check_sqlite3 warns (not fails) when sqlite3 is absent ──────────
DOCTOR_PASS=0 DOCTOR_WARN=0 DOCTOR_FAIL=0
_old_path="$PATH"
PATH="$TEST_TEMP_DIR/bin:/usr/bin:/bin"
rm -f "$TEST_TEMP_DIR/bin/sqlite3"
if ! command -v sqlite3 >/dev/null 2>&1; then
    _check_sqlite3
    assert_eq "TC-10: sqlite3 missing → WARN (not FAIL)" "1" "$DOCTOR_WARN"
    assert_eq "TC-10: sqlite3 missing → FAIL stays 0" "0" "$DOCTOR_FAIL"
else
    assert_pass "TC-10: sqlite3 on PATH (skip absence test on this platform)"
fi
PATH="$_old_path"

# ─── TC-11: _check_gh warns (not fails) when gh is absent ────────────────────
DOCTOR_PASS=0 DOCTOR_WARN=0 DOCTOR_FAIL=0
_old_path="$PATH"
PATH="$TEST_TEMP_DIR/bin:/usr/bin:/bin"
rm -f "$TEST_TEMP_DIR/bin/gh"
if ! command -v gh >/dev/null 2>&1; then
    _check_gh
    assert_eq "TC-11: gh missing → WARN (not FAIL)" "1" "$DOCTOR_WARN"
    assert_eq "TC-11: gh missing → FAIL stays 0" "0" "$DOCTOR_FAIL"
else
    assert_pass "TC-11: gh on PATH (skip absence test on this platform)"
fi
PATH="$_old_path"

print_test_results
exit $((FAIL > 0))
