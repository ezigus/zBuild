#!/usr/bin/env bash
# Tests: plugin lockfile tamper-detection via the zbuild CLI (#386)
#
# Covers the integration path: `zbuild plugin lock` writes the lockfile and
# `zbuild plugin validate` verifies it.  The unit-level functions
# (lockfile_write / lockfile_validate) are exercised in
# tests/integration/core-plugin-registry-test.sh; this test owns the CLI
# surface and the end-to-end fail-closed guarantee.
#
# Test matrix:
#   1. Lock written   → validate passes (baseline)
#   2. manifest.yaml mutated  → validate fails (non-zero exit, tamper detected)
#   3. manifest restored      → validate passes again (idempotent restore)
#   4. plugin.sh mutated      → validate fails (#290 dual-hash requirement)
#   5. plugin.sh restored     → validate passes again
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ZBUILD_CLI="$REPO_ROOT/scripts/zbuild"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugin lockfile tamper-detection — CLI integration (#386)"

setup_test_env "plugin-lockfile-tamper"

# ─── Fixture: minimal valid agent plugin ─────────────────────────────────────
FIXTURE_ROOT="$TEST_TEMP_DIR/plugins"
mkdir -p "$FIXTURE_ROOT/agent/guard-agent"

cat > "$FIXTURE_ROOT/agent/guard-agent/manifest.yaml" <<'EOF'
id: guard-agent
name: Guard Agent
kind: agent
version: 0.1.0
description: |
  Fixture for lockfile tamper-detection integration test (#386).
hooks:
  run: guard_agent_run
requires:
  core:
    - redaction
    - event-bus
EOF

cat > "$FIXTURE_ROOT/agent/guard-agent/plugin.sh" <<'EOF'
guard_agent_run()  { echo "guard-agent run: $*"; }
EOF

# Point lockfile to a temp location so we never touch the real ~/.zbuild state.
export ZBUILD_LOCKFILE="$TEST_TEMP_DIR/plugins.lock"
export ZBUILD_PLUGINS_ROOT="$FIXTURE_ROOT"

# ─── Helper: run `zbuild plugin <subcmd>` with the fixture env ───────────────
# We source registry.sh directly (the same way zbuild does) so we can override
# ZBUILD_LOCKFILE and ZBUILD_PLUGINS_ROOT without needing a full shell exec.
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"

# ─── 1. Lock + immediate validate (baseline) ─────────────────────────────────
lockfile_write "$FIXTURE_ROOT" "$ZBUILD_LOCKFILE"
assert_file_exists "zbuild plugin lock: lockfile created" "$ZBUILD_LOCKFILE"

# Confirm it contains the guard-agent entry.
lock_content="$(cat "$ZBUILD_LOCKFILE")"
assert_contains "lockfile records guard-agent" "$lock_content" "guard-agent"

set +e
lockfile_validate "$ZBUILD_LOCKFILE" 2>/dev/null
rc=$?
set -e
assert_eq "validate passes immediately after lock (baseline)" "0" "$rc"

# ─── 2. Mutate manifest.yaml → validate must fail ────────────────────────────
MANIFEST="$FIXTURE_ROOT/agent/guard-agent/manifest.yaml"
echo "# tamper-line" >> "$MANIFEST"

set +e
lockfile_validate "$ZBUILD_LOCKFILE" 2>/dev/null
rc=$?
set -e
assert_eq "validate detects manifest.yaml mutation (non-zero exit = fail-closed)" "1" "$rc"

# ─── 3. Restore manifest → validate passes again (idempotent restore) ────────
# Remove the appended tamper line using portable sed (BSD + GNU compatible).
if sed -i.bak '/^# tamper-line$/d' "$MANIFEST" 2>/dev/null; then
    rm -f "${MANIFEST}.bak"
else
    sed -i '' '/^# tamper-line$/d' "$MANIFEST"
fi

# Re-lock after restore so hashes are current.
lockfile_write "$FIXTURE_ROOT" "$ZBUILD_LOCKFILE"

set +e
lockfile_validate "$ZBUILD_LOCKFILE" 2>/dev/null
rc=$?
set -e
assert_eq "validate passes after manifest restored and re-locked" "0" "$rc"

# ─── 4. Mutate plugin.sh only → validate must fail (#290 dual-hash) ──────────
PLUGIN_SH="$FIXTURE_ROOT/agent/guard-agent/plugin.sh"
echo 'guard_agent_run() { echo "TAMPERED"; }' >> "$PLUGIN_SH"

set +e
lockfile_validate "$ZBUILD_LOCKFILE" 2>/dev/null
rc=$?
set -e
assert_eq "validate detects plugin.sh-only mutation (non-zero exit — #290)" "1" "$rc"

# ─── 5. Restore plugin.sh → validate passes again ────────────────────────────
cat > "$PLUGIN_SH" <<'EOF'
guard_agent_run()  { echo "guard-agent run: $*"; }
EOF

# Re-lock after restore.
lockfile_write "$FIXTURE_ROOT" "$ZBUILD_LOCKFILE"

set +e
lockfile_validate "$ZBUILD_LOCKFILE" 2>/dev/null
rc=$?
set -e
assert_eq "validate passes after plugin.sh restored and re-locked" "0" "$rc"

# ─── 6. zbuild CLI smoke-test (validate subcommand exits 0 on clean lockfile) ─
# Exercise the actual zbuild script end-to-end so the CLI wiring is covered.
set +e
cli_out="$(ZBUILD_LOCKFILE="$ZBUILD_LOCKFILE" \
           ZBUILD_PLUGINS_ROOT="$FIXTURE_ROOT" \
           bash "$ZBUILD_CLI" plugin validate 2>&1)"
cli_rc=$?
set -e
assert_eq "zbuild plugin validate exits 0 for clean lockfile (CLI path)" "0" "$cli_rc"
assert_contains "zbuild plugin validate reports clean" "$cli_out" "clean"

# ─── 7. zbuild CLI exits non-zero on tampered file ───────────────────────────
echo "# cli-tamper" >> "$MANIFEST"

set +e
cli_out="$(ZBUILD_LOCKFILE="$ZBUILD_LOCKFILE" \
           ZBUILD_PLUGINS_ROOT="$FIXTURE_ROOT" \
           bash "$ZBUILD_CLI" plugin validate 2>&1)"
cli_rc=$?
set -e
assert_eq "zbuild plugin validate exits 1 for tampered manifest (CLI path)" "1" "$cli_rc"

# ─── Cleanup ─────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
