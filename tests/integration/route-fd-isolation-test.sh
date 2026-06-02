#!/usr/bin/env bash
# Integration: _route_call_claude does not leak fd 3 or ZBUILD_STAGE_IO_FD
# into the claude subprocess (issue #647 — proactive defense-in-depth).
#
# Wave 11A (#645) fixes the real leak in the test plugin. This wave fixes
# the same leak class at the router chokepoint — `_route_call_claude` is
# the synchronous spawn used by route_to_model, which 4 agent plugins
# (plan, test_assessment, review, security-lens) route through. Closing
# fd 3 + unsetting ZBUILD_STAGE_IO_FD here covers all of them.
#
# Strategy: parent opens fd 3 → sentinel file, exports ZBUILD_STAGE_IO_FD=3,
# then drives route_to_model with a stub `claude` that writes a marker
# to stderr if either the fd or the env is observable. Assert no marker.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "integration: route_to_model fd 3 / ZBUILD_STAGE_IO_FD isolation (#647)"
setup_test_env "route-fd-isolation"

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

# Stub claude: writes ENV_LEAK and/or FD3_LEAK to stderr if the parent's
# fd 3 or ZBUILD_STAGE_IO_FD leaks into this subprocess. Otherwise emits
# a clean response and exits 0.
mkdir -p "$TEST_TEMP_DIR/bin"
cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
leak=0
if [[ -n "${ZBUILD_STAGE_IO_FD:-}" ]]; then
    echo "ENV_LEAK ZBUILD_STAGE_IO_FD=${ZBUILD_STAGE_IO_FD}" >&2
    leak=1
fi
# Probe fd 3: if it's open for write, this succeeds and proves the leak.
# Use a subshell so a closed-fd write doesn't kill the script under set -e.
if ( : >&3 ) 2>/dev/null; then
    echo "FD3_LEAK fd 3 writable in child" >&2
    leak=1
fi
if [[ $leak -ne 0 ]]; then
    exit 1
fi
echo "OK-RESPONSE"
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"

source "$REPO_ROOT/core/router/route.sh"

# Sentinel that fd 3 would write to if not closed.
SENTINEL="$TEST_TEMP_DIR/fd3-sentinel.txt"
: > "$SENTINEL"

# Open fd 3 in this shell pointing at the sentinel, export the stage-io fd,
# then drive route_to_model. _route_call_claude must close fd 3 and unset
# ZBUILD_STAGE_IO_FD before exec'ing claude.
exec 3>"$SENTINEL"
export ZBUILD_STAGE_IO_FD=3

set +e
out="$(route_to_model "T2" "ping" --skip-precondition 2>"$TEST_TEMP_DIR/claude.stderr")"
rc=$?
set -e

# Close fd 3 in parent.
exec 3>&-

stderr_content="$(cat "$TEST_TEMP_DIR/claude.stderr" 2>/dev/null || true)"
sentinel_content="$(cat "$SENTINEL" 2>/dev/null || true)"

assert_eq "route_to_model returns rc=0" "0" "$rc"
assert_eq "route_to_model stdout is OK-RESPONSE" "OK-RESPONSE" "$out"

env_leak=0
fd3_leak=0
grep -qF "ENV_LEAK" <<< "$stderr_content" 2>/dev/null && env_leak=1
grep -qF "FD3_LEAK" <<< "$stderr_content" 2>/dev/null && fd3_leak=1
assert_eq "no ENV_LEAK marker on stderr" "0" "$env_leak"
assert_eq "no FD3_LEAK marker on stderr" "0" "$fd3_leak"
assert_eq "fd 3 sentinel file is empty (no leaked writes)" "" "$sentinel_content"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
