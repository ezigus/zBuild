#!/usr/bin/env bash
# Tests: scripts/zbuild -- --mcp-server / --mcp-transport / --mcp-timeout flags
# Covers: issue #96 — MCP server connection flags for zbuild CLI
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "zbuild CLI --mcp-* flags — unit tests (issue #96)"

setup_test_env "cli-mcp-flags"

_test_cleanup_hook() { cleanup_test_env; }

# Locate bash 5 (required by compat.sh).
_BASH5="$(command -v bash)"

# ─── Fake repo root setup ────────────────────────────────────────────────────
# zbuild resolves REPO_ROOT as the parent of the directory containing the
# zbuild script (SCRIPT_DIR). We build:
#   $_fake_root/
#     scripts/
#       zbuild          <- copy of real zbuild (SCRIPT_DIR resolves to here)
#       lib/            <- symlink to real scripts/lib
#     core/pipeline/
#       runner.sh       <- stub that prints MCP env vars
#
# Because SCRIPT_DIR resolves to $_fake_root/scripts, REPO_ROOT resolves to
# $_fake_root, so exec picks up our stub runner.

_fake_root="$TEST_TEMP_DIR/fake-root"
mkdir -p "$_fake_root/scripts" "$_fake_root/core/pipeline"

# Real scripts/lib (helpers, test-helpers, compat, etc.)
ln -sf "$REPO_ROOT/scripts/lib" "$_fake_root/scripts/lib"

# Stub runner: dump the three MCP env vars, then exit 0.
cat > "$_fake_root/core/pipeline/runner.sh" <<'RUNNER'
#!/usr/bin/env bash
printf 'ZBUILD_MCP_SERVERS=%s\n'   "${ZBUILD_MCP_SERVERS:-__unset__}"
printf 'ZBUILD_MCP_TRANSPORT=%s\n' "${ZBUILD_MCP_TRANSPORT:-__unset__}"
printf 'ZBUILD_MCP_TIMEOUT=%s\n'   "${ZBUILD_MCP_TIMEOUT:-__unset__}"
exit 0
RUNNER
chmod +x "$_fake_root/core/pipeline/runner.sh"

# Copy the real zbuild into our fake scripts/ directory.
# Because it is a plain file (not a symlink), SCRIPT_DIR will resolve to
# $_fake_root/scripts and REPO_ROOT to $_fake_root.
cp "$REPO_ROOT/scripts/zbuild" "$_fake_root/scripts/zbuild"
chmod +x "$_fake_root/scripts/zbuild"

# Helper: run the fake zbuild with pipeline start + caller args.
_run_mcp() {
    "$_BASH5" "$_fake_root/scripts/zbuild" pipeline start "$@" 2>/dev/null
}

# ─── TC-1: --mcp-server populates ZBUILD_MCP_SERVERS ────────────────────────
_out="$(_run_mcp --mcp-server "http://mcp.example.com:8080" --issue 1)"
assert_contains "TC-1: ZBUILD_MCP_SERVERS contains the URL" \
    "$_out" "ZBUILD_MCP_SERVERS=http://mcp.example.com:8080"

# ─── TC-2: multiple --mcp-server flags → both URLs present in output ─────────
_out="$(_run_mcp \
    --mcp-server "http://a.example.com" \
    --mcp-server "http://b.example.com" \
    --issue 1)"
assert_contains "TC-2: first server URL present"  "$_out" "http://a.example.com"
assert_contains "TC-2: second server URL present" "$_out" "http://b.example.com"

# ─── TC-3: --mcp-transport sse sets ZBUILD_MCP_TRANSPORT=sse ─────────────────
_out="$(_run_mcp --mcp-transport sse --issue 1)"
assert_contains "TC-3: ZBUILD_MCP_TRANSPORT=sse" "$_out" "ZBUILD_MCP_TRANSPORT=sse"

# ─── TC-4: --mcp-transport stdio sets ZBUILD_MCP_TRANSPORT=stdio ─────────────
_out="$(_run_mcp --mcp-transport stdio --issue 1)"
assert_contains "TC-4: ZBUILD_MCP_TRANSPORT=stdio" "$_out" "ZBUILD_MCP_TRANSPORT=stdio"

# ─── TC-5: --mcp-timeout sets ZBUILD_MCP_TIMEOUT ────────────────────────────
_out="$(_run_mcp --mcp-timeout 60 --issue 1)"
assert_contains "TC-5: ZBUILD_MCP_TIMEOUT=60" "$_out" "ZBUILD_MCP_TIMEOUT=60"

# ─── TC-6: no MCP flags → vars remain unset (stub reports __unset__) ─────────
_out="$(_run_mcp --issue 1)"
assert_contains "TC-6: ZBUILD_MCP_SERVERS unset"   "$_out" "ZBUILD_MCP_SERVERS=__unset__"
assert_contains "TC-6: ZBUILD_MCP_TRANSPORT unset" "$_out" "ZBUILD_MCP_TRANSPORT=__unset__"
assert_contains "TC-6: ZBUILD_MCP_TIMEOUT unset"   "$_out" "ZBUILD_MCP_TIMEOUT=__unset__"

# ─── TC-7: unknown --mcp-transport value exits 1 ────────────────────────────
_rc=0
"$_BASH5" "$_fake_root/scripts/zbuild" pipeline start \
    --mcp-transport grpc --issue 1 >/dev/null 2>&1 || _rc=$?
assert_eq "TC-7: unknown --mcp-transport exits 1" "1" "$_rc"

print_test_results
