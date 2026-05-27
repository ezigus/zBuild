#!/usr/bin/env bash
# Tests: zbuild doctor command — integration (subprocess) tests
# Covers: issues #58, #90 — all tools, state dir, config, exit codes
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "zbuild doctor — integration tests (issues #58, #90)"

setup_test_env "doctor-integration"

_test_cleanup_hook() { cleanup_test_env; }

# ─── Create mock binaries in $TEST_TEMP_DIR/bin ──────────────────────────────
# Determine the real bash 5 path (needed for restricted-PATH tests)
_REAL_BASH="$(command -v bash)"

# zbuild shim that invokes the real script using the absolute bash path
cat > "$TEST_TEMP_DIR/bin/zbuild" <<MOCKEOF
#!/usr/bin/env bash
exec "$_REAL_BASH" "$REPO_ROOT/scripts/zbuild" "\$@"
MOCKEOF
chmod +x "$TEST_TEMP_DIR/bin/zbuild"

# Also symlink the real bash into the mock bin so restricted-PATH invocations work
ln -sf "$_REAL_BASH" "$TEST_TEMP_DIR/bin/bash"

# Mock claude
cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCKEOF'
#!/usr/bin/env bash
echo "Mock claude response"
exit 0
MOCKEOF
chmod +x "$TEST_TEMP_DIR/bin/claude"

# Mock gh with successful auth status
cat > "$TEST_TEMP_DIR/bin/gh" <<'MOCKEOF'
#!/usr/bin/env bash
case "${1:-}" in
    auth)
        case "${2:-}" in
            status) exit 0 ;;
        esac ;;
esac
echo ""
exit 0
MOCKEOF
chmod +x "$TEST_TEMP_DIR/bin/gh"

# Mock sqlite3
cat > "$TEST_TEMP_DIR/bin/sqlite3" <<'MOCKEOF'
#!/usr/bin/env bash
echo "3.39.0"
exit 0
MOCKEOF
chmod +x "$TEST_TEMP_DIR/bin/sqlite3"

# Mock git
mock_git

# Real jq is symlinked by setup_test_env already

# Set up state dir and config env
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_REPO_ROOT="$REPO_ROOT"
export ZBUILD_PLUGINS_ROOT="$REPO_ROOT/plugins"
mkdir -p "$ZBUILD_STATE_DIR"

# ─── TC-1: All tools present + state dir OK → exit 0, output contains "passed" ─
set +e
out="$(zbuild doctor 2>&1)"
rc=$?
set -e
assert_eq "TC-1: all tools present → exit 0" "0" "$rc"
assert_contains "TC-1: output contains 'passed'" "$out" "passed"

# ─── TC-2: claude removed → exit 1, output mentions Fix ─────────────────────
# Build a PATH that includes essential system dirs but NOT any location where real claude lives.
# $TEST_TEMP_DIR/bin is first (our mocks); /usr/bin and /bin have bash/sed/grep but not claude.
_SAFE_PATH="$TEST_TEMP_DIR/bin:/usr/bin:/bin:/usr/sbin:/sbin"
rm -f "$TEST_TEMP_DIR/bin/claude"
set +e
out="$(PATH="$_SAFE_PATH" zbuild doctor 2>&1)"
rc=$?
set -e
assert_eq "TC-2: claude missing → exit 1" "1" "$rc"
assert_contains "TC-2: output contains Fix hint for claude" "$out" "npm install"
# Restore claude
cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCKEOF'
#!/usr/bin/env bash
echo "Mock claude response"
exit 0
MOCKEOF
chmod +x "$TEST_TEMP_DIR/bin/claude"

# ─── TC-3: gh auth status returns 1 → exit 0 (warn only), mentions gh auth login ─
cat > "$TEST_TEMP_DIR/bin/gh" <<'MOCKEOF'
#!/usr/bin/env bash
case "${1:-}" in
    auth)
        case "${2:-}" in
            status) exit 1 ;;
        esac ;;
esac
echo ""
exit 0
MOCKEOF
chmod +x "$TEST_TEMP_DIR/bin/gh"
set +e
out="$(zbuild doctor 2>&1)"
rc=$?
set -e
assert_eq "TC-3: gh auth failure → exit 0 (warn only)" "0" "$rc"
assert_contains "TC-3: output mentions gh auth login" "$out" "gh auth login"
# Restore gh with good auth
cat > "$TEST_TEMP_DIR/bin/gh" <<'MOCKEOF'
#!/usr/bin/env bash
case "${1:-}" in
    auth)
        case "${2:-}" in
            status) exit 0 ;;
        esac ;;
esac
echo ""
exit 0
MOCKEOF
chmod +x "$TEST_TEMP_DIR/bin/gh"

# ─── TC-4: sqlite3 removed → exit 0 (warn only), output mentions sqlite3 ─────
rm -f "$TEST_TEMP_DIR/bin/sqlite3"
set +e
out="$(zbuild doctor 2>&1)"
rc=$?
set -e
assert_eq "TC-4: sqlite3 missing → exit 0 (warn only)" "0" "$rc"
assert_contains "TC-4: output mentions sqlite3" "$out" "sqlite3"
# Restore sqlite3
cat > "$TEST_TEMP_DIR/bin/sqlite3" <<'MOCKEOF'
#!/usr/bin/env bash
echo "3.39.0"
exit 0
MOCKEOF
chmod +x "$TEST_TEMP_DIR/bin/sqlite3"

# ─── TC-5: missing config/models.json → exit 1 ───────────────────────────────
_no_config_dir="$TEST_TEMP_DIR/no-config"
mkdir -p "$_no_config_dir"
set +e
out="$(ZBUILD_REPO_ROOT="$_no_config_dir" zbuild doctor 2>&1)"
rc=$?
set -e
assert_eq "TC-5: missing models.json → exit 1" "1" "$rc"
# Restore
export ZBUILD_REPO_ROOT="$REPO_ROOT"

# ─── TC-6: Summary line format matches expected pattern ───────────────────────
set +e
out="$(zbuild doctor 2>&1)"
rc=$?
set -e
assert_contains_regex "TC-6: summary line format correct" "$out" "[0-9]+ passed.*[0-9]+ warnings.*[0-9]+ failed"

# ─── TC-7: exit 0 when all checks pass ───────────────────────────────────────
set +e
zbuild doctor
rc=$?
set -e
assert_eq "TC-7: exit 0 all pass" "0" "$rc"

# ─── TC-8: exit 1 when any FAIL (remove claude) ──────────────────────────────
rm -f "$TEST_TEMP_DIR/bin/claude"
_SAFE_PATH="$TEST_TEMP_DIR/bin:/usr/bin:/bin:/usr/sbin:/sbin"
set +e
PATH="$_SAFE_PATH" zbuild doctor
rc=$?
set -e
assert_eq "TC-8: exit 1 on fail (no claude)" "1" "$rc"

print_test_results
exit $((FAIL > 0))
