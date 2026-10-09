#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-ruflo-bridge-test — Mock-driven tests for the ruflo unix socket      ║
# ║  bridge (#500). No real ruflo binary, no real ruflo npm package.         ║
# ║                                                                           ║
# ║  Coverage (10 cases):                                                     ║
# ║    1.  Bridge unavailable initially (socket missing → fail-open)          ║
# ║    2.  _ruflo_bridge_start spawns bridge, socket + PID file appear        ║
# ║    3.  ping responds with success:true and uptime_ms field                ║
# ║    4.  memory_store via subprocess fallback returns success:true          ║
# ║    5.  memory_search via subprocess fallback returns results array        ║
# ║    6.  Unknown tool falls back to subprocess; mock returns shape          ║
# ║    7.  JSON injection-safe args round-trip via jq encoding                ║
# ║    8.  Concurrent calls all succeed (per-connection isolation)            ║
# ║    9.  Re-source guard: RUFLO_BRIDGE_SOCK override is preserved           ║
# ║    10. SIGTERM via _ruflo_bridge_stop unlinks socket and PID file         ║
# ║    11. In-process import path dispatches without subprocess fallback      ║
# ║                                                                           ║
# ║  Run:  bash scripts/sw-ruflo-bridge-test.sh                               ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/test-helpers.sh
source "$SCRIPT_DIR/lib/test-helpers.sh"

# ─── Skip on systems without nc -U (unix-socket netcat) ────────────────────
if ! command -v nc >/dev/null 2>&1; then
    echo "SKIP: nc (netcat) not available — ruflo-bridge requires unix-socket nc"
    exit 0
fi
if ! command -v node >/dev/null 2>&1; then
    echo "SKIP: node not available — ruflo-bridge requires Node.js"
    exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: jq not available — ruflo-mcp-call requires jq"
    exit 0
fi

setup_test_env "sw-ruflo-bridge"

# ─── Per-test config ─────────────────────────────────────────────────────────
# Use a deterministic socket path inside the test sandbox so leaks (if any)
# are isolated to TEST_TEMP_DIR and reaped by the harness EXIT trap.
export RUFLO_BRIDGE_SOCK="$TEST_TEMP_DIR/ruflo-bridge.sock"
export RUFLO_BRIDGE_TIMEOUT=2
export RUFLO_BRIDGE_START_TIMEOUT_DECIS=50  # 5s — generous for slow CI
export RUFLO_BRIDGE_SCRIPT="$SCRIPT_DIR/lib/ruflo-bridge.mjs"
export RUFLO_BRIDGE_NODE="node"

# ─── Mock `ruflo` binary — answers `mcp exec --tool X --args Y` ────────────
# The bridge falls back to this whenever `import('ruflo')` is unavailable
# (which is the default in test env — no package installed).
cat > "$TEST_TEMP_DIR/bin/ruflo" <<'MOCK_RUFLO'
#!/usr/bin/env bash
# Mock ruflo: returns JSON shaped like the real MCP exec response.
if [[ "${1:-}" == "mcp" && "${2:-}" == "exec" ]]; then
    shift 2
    tool=""
    args="{}"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tool) tool="$2"; shift 2 ;;
            --args) args="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    case "$tool" in
        memory_store)
            printf '{"stored":true,"echo_args":%s}\n' "$args" ;;
        memory_search)
            printf '{"results":[{"id":"r1","value":"hit"}],"echo_args":%s}\n' "$args" ;;
        *)
            printf '{"mock":true,"tool":"%s","echo_args":%s}\n' "$tool" "$args" ;;
    esac
    exit 0
fi
exit 0
MOCK_RUFLO
chmod +x "$TEST_TEMP_DIR/bin/ruflo"
export RUFLO_BIN="$TEST_TEMP_DIR/bin/ruflo"

# ─── Cleanup hook — stop bridge on exit so we never leak processes ─────────
_test_cleanup_hook() {
    if [[ -n "${_RUFLO_MCP_CALL_LOADED:-}" ]]; then
        _ruflo_bridge_stop 2>/dev/null || true
    fi
    # Also stop any in-process variant we spawned with a different socket.
    if [[ -n "${_INPROC_PID:-}" ]]; then
        kill -TERM "$_INPROC_PID" 2>/dev/null || true
    fi
}

# ─── Source the wrapper under test ─────────────────────────────────────────
# shellcheck source=scripts/lib/ruflo-mcp-call.sh
source "$SCRIPT_DIR/lib/ruflo-mcp-call.sh"

print_test_header "ruflo-bridge — unix socket transport (issue #500)"

# ─── Test 1: bridge unavailable initially (fail-open) ──────────────────────
print_test_section "Test 1: bridge unavailable → ruflo_bridge_available returns 1"
if ruflo_bridge_available; then
    assert_fail "bridge should be unavailable before start" "socket exists at $RUFLO_BRIDGE_SOCK"
else
    assert_pass "bridge unavailable before start (exit 1)"
fi

# ─── Test 2: _ruflo_bridge_start spawns bridge ─────────────────────────────
print_test_section "Test 2: _ruflo_bridge_start brings up socket and PID file"
if _ruflo_bridge_start; then
    assert_pass "_ruflo_bridge_start returned 0"
else
    assert_fail "_ruflo_bridge_start failed" "socket=$RUFLO_BRIDGE_SOCK script=$RUFLO_BRIDGE_SCRIPT"
fi
if [[ -S "$RUFLO_BRIDGE_SOCK" ]]; then
    assert_pass "socket file exists at expected path"
else
    assert_fail "socket file missing" "$RUFLO_BRIDGE_SOCK"
fi
if [[ -f "${RUFLO_BRIDGE_SOCK}.pid" ]]; then
    assert_pass "PID file exists"
else
    assert_fail "PID file missing" "${RUFLO_BRIDGE_SOCK}.pid"
fi

# ─── Test 3: ping ──────────────────────────────────────────────────────────
print_test_section "Test 3: ping returns success:true with uptime_ms"
ping_resp=$(ruflo_mcp_call ping || true)
assert_contains "ping response includes success:true" "$ping_resp" '"success":true'
assert_contains "ping response includes pong:true" "$ping_resp" '"pong":true'
assert_contains "ping response includes uptime_ms" "$ping_resp" '"uptime_ms"'

# ─── Test 4: memory_store via subprocess fallback ──────────────────────────
print_test_section "Test 4: memory_store fallback returns success:true"
store_resp=$(ruflo_mcp_call memory_store key=alpha value=one namespace=ns1 || true)
assert_contains "memory_store success" "$store_resp" '"success":true'
assert_contains "memory_store result includes stored:true" "$store_resp" '"stored":true'
assert_contains "memory_store echoed args.key=alpha" "$store_resp" '"key":"alpha"'
assert_contains "memory_store echoed args.value=one" "$store_resp" '"value":"one"'

# ─── Test 5: memory_search returns results array ───────────────────────────
print_test_section "Test 5: memory_search returns results array"
search_resp=$(ruflo_mcp_call memory_search query=foo limit=10 || true)
assert_contains "memory_search success" "$search_resp" '"success":true'
assert_contains "memory_search has results array" "$search_resp" '"results":'
assert_contains "memory_search echoed args.query=foo" "$search_resp" '"query":"foo"'

# ─── Test 6: unknown tool falls through subprocess (mock returns shape) ────
print_test_section "Test 6: unknown tool delegates to subprocess fallback"
unk_resp=$(ruflo_mcp_call totally_made_up_tool flag=1 || true)
assert_contains "unknown tool returns success:true (mock answers anything)" \
    "$unk_resp" '"success":true'
assert_contains "unknown tool result includes mock:true marker" \
    "$unk_resp" '"mock":true'

# ─── Test 7: JSON injection-safe args round-trip ───────────────────────────
print_test_section "Test 7: JSON injection in arg value cannot escape jq encoding"
# Embed quotes, backslash, newline, ${VAR}-looking string in a single value.
# If the wrapper used string interpolation, the inner double-quote would close
# the JSON string and corrupt the request. With jq --arg, it round-trips
# verbatim and ends up nested under args.value.
inject_payload='","drop":"oops","more":"hi'
inject_resp=$(ruflo_mcp_call memory_store key=safe value="$inject_payload" || true)
assert_contains "injection payload arrives as success:true" "$inject_resp" '"success":true'
# The mock echoes args verbatim — verify the raw payload survived encoding.
# We check for the literal substring inside the echoed args, which proves
# jq treated it as a string value rather than as JSON syntax.
if printf '%s' "$inject_resp" | grep -qF '"value":"\",\"drop\":\"oops\",\"more\":\"hi"'; then
    assert_pass "injection payload preserved verbatim under args.value"
else
    assert_fail "injection payload corrupted or interpreted as JSON" "$inject_resp"
fi

# ─── Test 8: concurrent calls (per-connection isolation) ───────────────────
print_test_section "Test 8: 5 concurrent calls all succeed"
concurrent_dir="$TEST_TEMP_DIR/concurrent"
mkdir -p "$concurrent_dir"
# Fire 5 calls in parallel, each writing its response to a separate file.
# Collect PIDs and wait on each individually — bare `wait` would also block
# on the long-lived bridge process started by _ruflo_bridge_start.
concurrent_pids=()
for i in 1 2 3 4 5; do
    ( ruflo_mcp_call memory_store key="k$i" value="v$i" >"$concurrent_dir/r$i" 2>&1 || true ) &
    concurrent_pids+=($!)
done
for pid in "${concurrent_pids[@]}"; do
    wait "$pid" 2>/dev/null || true
done
ok=0
for i in 1 2 3 4 5; do
    if grep -qF '"success":true' "$concurrent_dir/r$i" 2>/dev/null; then
        ok=$((ok + 1))
    fi
done
assert_eq "5 concurrent calls all returned success:true" "5" "$ok"

# ─── Test 9: re-source guard preserves caller's RUFLO_BRIDGE_SOCK ──────────
print_test_section "Test 9: re-sourcing wrapper does not clobber RUFLO_BRIDGE_SOCK override"
saved_sock="$RUFLO_BRIDGE_SOCK"
# `if (subshell)` is the safe form under `set -e` — a failing subshell here
# would otherwise terminate the test script before reaching the assertion.
if (
    unset _RUFLO_MCP_CALL_LOADED
    export RUFLO_BRIDGE_SOCK="/tmp/some/other/path.sock"
    # shellcheck source=scripts/lib/ruflo-mcp-call.sh
    source "$SCRIPT_DIR/lib/ruflo-mcp-call.sh"
    [[ "$RUFLO_BRIDGE_SOCK" == "/tmp/some/other/path.sock" ]]
); then
    assert_pass "RUFLO_BRIDGE_SOCK override preserved across (re-)source"
else
    assert_fail "RUFLO_BRIDGE_SOCK was clobbered by source" ""
fi
# Confirm outer env was not affected.
assert_eq "outer RUFLO_BRIDGE_SOCK still points to test socket" \
    "$saved_sock" "$RUFLO_BRIDGE_SOCK"

# ─── Test 10: SIGTERM via _ruflo_bridge_stop cleans up artifacts ──────────
print_test_section "Test 10: _ruflo_bridge_stop unlinks socket and PID file"
_ruflo_bridge_stop
assert_file_not_exists "socket file removed after stop" "$RUFLO_BRIDGE_SOCK"
assert_file_not_exists "PID file removed after stop" "${RUFLO_BRIDGE_SOCK}.pid"
if ruflo_bridge_available; then
    assert_fail "bridge should be unavailable after stop" ""
else
    assert_pass "ruflo_bridge_available returns 1 after stop"
fi

# ─── Test 11: in-process import path (skips subprocess fallback) ──────────
print_test_section "Test 11: in-process import path dispatches without RUFLO_BIN"
# Build a temp tree where `import('ruflo')` resolves to a stub ESM module.
# Node's ESM resolution walks up from the script's directory looking for
# node_modules, so placing both side-by-side under TEST_TEMP_DIR is enough.
inproc_dir="$TEST_TEMP_DIR/inproc"
mkdir -p "$inproc_dir/node_modules/ruflo"
cat > "$inproc_dir/node_modules/ruflo/package.json" <<'INPROC_PKG'
{"name":"ruflo","version":"0.0.0-stub","type":"module","main":"./index.mjs"}
INPROC_PKG
cat > "$inproc_dir/node_modules/ruflo/index.mjs" <<'INPROC_MOD'
export async function memory_store(args) {
    return { stored: true, in_process: true, args };
}
export async function memory_search(args) {
    return { results: ['stub'], in_process: true, args };
}
INPROC_MOD
cp "$SCRIPT_DIR/lib/ruflo-bridge.mjs" "$inproc_dir/ruflo-bridge.mjs"

# Spawn an isolated bridge with its own socket path. We deliberately point
# RUFLO_BIN at /bin/false so that subprocess fallback would *fail* — proving
# the in-process path is what served the call.
inproc_sock="$TEST_TEMP_DIR/inproc.sock"
RUFLO_BIN=/bin/false RUFLO_BRIDGE_SOCK="$inproc_sock" \
    nohup node "$inproc_dir/ruflo-bridge.mjs" </dev/null >/dev/null 2>&1 &
_INPROC_PID=$!

# Bounded wait for the socket — same failsafe pattern as _ruflo_bridge_start.
waited=0
while [[ $waited -lt 50 ]]; do
    [[ -S "$inproc_sock" ]] && break
    sleep 0.1
    waited=$((waited + 1))
done

if [[ -S "$inproc_sock" ]]; then
    assert_pass "in-process bridge socket appeared"
    inproc_resp=$(printf '{"tool":"memory_store","args":{"k":"v"}}\n' \
        | nc -U -w 2 "$inproc_sock" 2>/dev/null || true)
    assert_contains "in-process call returned success:true" "$inproc_resp" '"success":true'
    assert_contains "in-process marker present in result" "$inproc_resp" '"in_process":true'
    # If subprocess fallback had run, the mock would have inserted "echo_args".
    # The /bin/false fallback would have produced success:false. Either way the
    # absence of "echo_args" combined with success:true proves the in-process
    # ESM path served the request.
    if printf '%s' "$inproc_resp" | grep -qF 'echo_args'; then
        assert_fail "subprocess fallback ran when in-process should have served" "$inproc_resp"
    else
        assert_pass "subprocess fallback did NOT run (no echo_args field)"
    fi
else
    assert_fail "in-process bridge socket never appeared" "$inproc_sock"
fi

kill -TERM "${_INPROC_PID}" 2>/dev/null || true
unset _INPROC_PID

# ─── Summary ────────────────────────────────────────────────────────────────
print_test_results

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
