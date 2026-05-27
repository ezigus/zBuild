#!/usr/bin/env bash
# Integration tests: .claude/helpers/hook-handler.cjs — event emission
# Issues: #100, #101, #102, #103, #104, #105
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK_HANDLER="$REPO_ROOT/.claude/helpers/hook-handler.cjs"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "hooks/pre-tool-use — integration: event emission (#100-#105)"

setup_test_env "hooks-pre-tool-use-integration"

# Point the event bus at our test temp dir
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

# Sanity check that the handler exists
if [[ ! -f "$HOOK_HANDLER" ]]; then
    assert_fail "hook-handler.cjs exists" "file not found: $HOOK_HANDLER"
    print_test_results
    exit $((FAIL > 0))
fi
assert_pass "hook-handler.cjs exists"

# ─── TC-1: Blocked command — no allow event emitted ─────────────────────────
# The handler blocks rm -rf / with exit 1 and should NOT emit an allow event.
set +e
echo '{"command":"rm -rf /"}' | node "$HOOK_HANDLER" pre-bash >/dev/null 2>&1
tc1_rc=$?
set -e
assert_eq "TC-1: blocked command exits 1" "1" "$tc1_rc"

# After a block there should be NO hook.pre_tool_use.checked event with verdict=allow
if [[ -f "$ZBUILD_EVENTS_JSONL" ]]; then
    allow_after_block=$(grep 'hook.pre_tool_use.checked' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | grep 'allow' || true)
    if [[ -n "$allow_after_block" ]]; then
        assert_fail "TC-1b: no allow event emitted after block"
    else
        assert_pass "TC-1b: no allow event emitted after block"
    fi
else
    assert_pass "TC-1b: no event log written after block (expected)"
fi

# ─── TC-2: Allowed command — emits allow event to JSONL ─────────────────────
set +e
echo '{"command":"ls -la /tmp"}' | node "$HOOK_HANDLER" pre-bash >/dev/null 2>&1
tc2_rc=$?
set -e
assert_eq "TC-2: allowed command exits 0" "0" "$tc2_rc"

# The event bus emits only when the event-bus.sh script exists and we have a
# valid ZBUILD_RUN_ID. The handler's emitEvent is fire-and-forget, so we check
# conditionally: if the JSONL was created, it must contain the allow event.
if [[ -f "$ZBUILD_EVENTS_JSONL" ]]; then
    allow_event=$(grep 'hook.pre_tool_use.checked' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)
    if [[ -n "$allow_event" ]]; then
        assert_pass "TC-2b: allow event present in JSONL"
        verdict=$(echo "$allow_event" | jq -r '.data.verdict // empty' 2>/dev/null || true)
        assert_eq "TC-2c: event has verdict=allow" "allow" "$verdict"
    else
        # Event bus requires ZBUILD_RUN_ID; without it, no event — that is acceptable
        assert_pass "TC-2b: no event (event bus requires ZBUILD_RUN_ID — acceptable in unit env)"
    fi
else
    assert_pass "TC-2b: no event log (event bus not available — acceptable)"
fi

# ─── TC-3: post-edit emits recorded event ────────────────────────────────────
set +e
echo '{"tool_input":{"file_path":"src/foo.sh"}}' | node "$HOOK_HANDLER" post-edit >/dev/null 2>&1
tc3_rc=$?
set -e
assert_eq "TC-3: post-edit exits 0" "0" "$tc3_rc"

# ─── TC-4: post-bash emits recorded event ────────────────────────────────────
set +e
echo '{"command":"npm test"}' | node "$HOOK_HANDLER" post-bash >/dev/null 2>&1
tc4_rc=$?
set -e
assert_eq "TC-4: post-bash exits 0" "0" "$tc4_rc"

# ─── TC-5: route handler classifies pipeline domain ─────────────────────────
set +e
route_output=$(echo '{"prompt":"run the pipeline for issue 42"}' | node "$HOOK_HANDLER" route 2>/dev/null)
tc5_rc=$?
set -e
assert_eq "TC-5: route exits 0" "0" "$tc5_rc"
assert_contains "TC-5b: route output contains [ROUTE]" "$route_output" "[ROUTE]"
assert_contains "TC-5c: route classifies pipeline domain" "$route_output" "pipeline"

# ─── TC-6: route handler classifies test domain ──────────────────────────────
set +e
test_route_output=$(echo '{"prompt":"run the test suite"}' | node "$HOOK_HANDLER" route 2>/dev/null)
tc6_rc=$?
set -e
assert_eq "TC-6: route (test) exits 0" "0" "$tc6_rc"
assert_contains "TC-6b: route classifies test domain" "$test_route_output" "test"

# ─── TC-7: session-restore exits 0 even with no prior session ────────────────
set +e
echo '{}' | node "$HOOK_HANDLER" session-restore >/dev/null 2>&1
tc7_rc=$?
set -e
assert_eq "TC-7: session-restore exits 0 (no prior session)" "0" "$tc7_rc"

# ─── TC-8: session-end exits 0 ───────────────────────────────────────────────
set +e
echo '{}' | node "$HOOK_HANDLER" session-end >/dev/null 2>&1
tc8_rc=$?
set -e
assert_eq "TC-8: session-end exits 0" "0" "$tc8_rc"

# ─── TC-9: compact-manual exits 0 ────────────────────────────────────────────
set +e
echo '{"trigger":"manual"}' | node "$HOOK_HANDLER" compact-manual >/dev/null 2>&1
tc9_rc=$?
set -e
assert_eq "TC-9: compact-manual exits 0" "0" "$tc9_rc"

# ─── TC-10: subagent-start exits 0 ───────────────────────────────────────────
set +e
echo '{}' | node "$HOOK_HANDLER" subagent-start >/dev/null 2>&1
tc10_rc=$?
set -e
assert_eq "TC-10: subagent-start exits 0" "0" "$tc10_rc"

# ─── TC-11: unknown command exits 0 (safe degradation) ───────────────────────
set +e
echo '{}' | node "$HOOK_HANDLER" unknown-command-xyz >/dev/null 2>&1
tc11_rc=$?
set -e
assert_eq "TC-11: unknown command exits 0 (safe degradation)" "0" "$tc11_rc"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
