#!/usr/bin/env bash
# Integration: _route_call_claude spawn subshell uses _zbuild_make_fresh_shell —
# all ZBUILD_* vars (not just ZBUILD_STAGE_IO_FD) are scrubbed before claude
# exec, and fd 3 is closed (ADR-024, #671).
#
# Strictly supersets Wave 11C (#647)'s ZBUILD_STAGE_IO_FD-only test — that
# one still passes alongside this one.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "integration: route_to_model fresh-user-shell scrub (#671)"
setup_test_env "route-fresh-shell"

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_RUN_ID="route-run-671"
mkdir -p "$ZBUILD_EVENTS_DIR"
: > "$ZBUILD_EVENTS_JSONL"

export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
# Token must match ZBUILD_RUN_ID (else router C6 precondition rejects).
printf '%s' "$ZBUILD_RUN_ID" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

# Stub claude: asserts NONE of ZBUILD_RUN_ID, ZBUILD_EVENTS_JSONL, or
# ZBUILD_STAGE_IO_FD is visible AND fd 3 is closed. Writes per-leak marker
# to stderr; success path emits OK-RESPONSE and exits 0.
mkdir -p "$TEST_TEMP_DIR/bin"
cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
leak=0
if [[ -n "${ZBUILD_RUN_ID:-}" ]]; then
    echo "LEAK_RUN_ID ZBUILD_RUN_ID=${ZBUILD_RUN_ID}" >&2
    leak=1
fi
if [[ -n "${ZBUILD_EVENTS_JSONL:-}" ]]; then
    echo "LEAK_EVENTS_JSONL ZBUILD_EVENTS_JSONL=${ZBUILD_EVENTS_JSONL}" >&2
    leak=1
fi
if [[ -n "${ZBUILD_STAGE_IO_FD:-}" ]]; then
    echo "LEAK_STAGE_IO_FD ZBUILD_STAGE_IO_FD=${ZBUILD_STAGE_IO_FD}" >&2
    leak=1
fi
if ( : >&3 ) 2>/dev/null; then
    echo "LEAK_FD3 fd 3 writable in child" >&2
    leak=1
fi
if [[ $leak -ne 0 ]]; then
    exit 1
fi
echo "OK-RESPONSE"
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
export PATH="$TEST_TEMP_DIR/bin:$PATH"

source "$REPO_ROOT/core/router/route.sh"

SENTINEL="$TEST_TEMP_DIR/fd3-sentinel.txt"
: > "$SENTINEL"

exec 3>"$SENTINEL"
export ZBUILD_STAGE_IO_FD=3

set +e
out="$(route_to_model "T2" "ping" --skip-precondition 2>"$TEST_TEMP_DIR/claude.stderr")"
rc=$?
set -e

exec 3>&-

stderr_content="$(cat "$TEST_TEMP_DIR/claude.stderr" 2>/dev/null || true)"
sentinel_content="$(cat "$SENTINEL" 2>/dev/null || true)"

assert_eq "route_to_model returns rc=0" "0" "$rc"
assert_eq "route_to_model stdout is OK-RESPONSE" "OK-RESPONSE" "$out"

for leak in LEAK_RUN_ID LEAK_EVENTS_JSONL LEAK_STAGE_IO_FD LEAK_FD3; do
    found=0
    grep -qF "$leak" <<< "$stderr_content" 2>/dev/null && found=1
    assert_eq "no $leak marker on stderr" "0" "$found"
done

assert_eq "fd 3 sentinel file is empty (no leaked writes)" "" "$sentinel_content"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
