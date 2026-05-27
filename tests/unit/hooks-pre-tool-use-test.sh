#!/usr/bin/env bash
# Tests: .claude/helpers/hook-handler.cjs — pre-tool-use safety guards
# Issues: #100, #101, #102, #103, #104, #105
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK_HANDLER="$REPO_ROOT/.claude/helpers/hook-handler.cjs"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "hooks/pre-tool-use — safety guards (#100-#105)"

setup_test_env "hooks-pre-tool-use"

# Helpers
_invoke_pre_bash() {
    local cmd="$1"
    local payload
    payload=$(printf '{"command":"%s"}' "$cmd")
    set +e
    echo "$payload" | node "$HOOK_HANDLER" pre-bash 2>/dev/null
    _rc=$?
    set -e
}

_invoke_pre_bash_rc() {
    local cmd="$1"
    local payload
    payload=$(printf '{"command":"%s"}' "$cmd")
    set +e
    echo "$payload" | node "$HOOK_HANDLER" pre-bash >/dev/null 2>&1
    echo $?
    set -e
}

_invoke_pre_edit() {
    local file_path="$1"
    local content="$2"
    # Escape content for JSON: replace " with \" and newlines with \n
    local escaped_content
    escaped_content=$(printf '%s' "$content" | sed 's/\\/\\\\/g; s/"/\\"/g; s/$/\\n/g' | tr -d '\n' | sed 's/\\n$//')
    local payload
    payload=$(printf '{"tool_input":{"file_path":"%s","new_string":"%s"}}' "$file_path" "$escaped_content")
    set +e
    echo "$payload" | node "$HOOK_HANDLER" pre-edit 2>/dev/null
    _rc=$?
    set -e
}

_invoke_pre_edit_rc() {
    local file_path="$1"
    local content="$2"
    local escaped_content
    escaped_content=$(printf '%s' "$content" | sed 's/\\/\\\\/g; s/"/\\"/g; s/$/\\n/g' | tr -d '\n' | sed 's/\\n$//')
    local payload
    payload=$(printf '{"tool_input":{"file_path":"%s","new_string":"%s"}}' "$file_path" "$escaped_content")
    set +e
    echo "$payload" | node "$HOOK_HANDLER" pre-edit >/dev/null 2>&1
    echo $?
    set -e
}

# ─── Pre-requisite: hook-handler.cjs exists ──────────────────────────────────
if [[ ! -f "$HOOK_HANDLER" ]]; then
    assert_fail "hook-handler.cjs exists" "file not found: $HOOK_HANDLER"
    print_test_results
    exit $((FAIL > 0))
fi
assert_pass "hook-handler.cjs exists"

# ─── TC-1: Blocked command: rm -rf / ────────────────────────────────────────
set +e
echo '{"command":"rm -rf /"}' | node "$HOOK_HANDLER" pre-bash >/dev/null 2>&1
tc1_rc=$?
set -e
assert_eq "TC-1: rm -rf / is blocked (exit 1)" "1" "$tc1_rc"

# ─── TC-2: Allowed command: ls -la ──────────────────────────────────────────
set +e
echo '{"command":"ls -la"}' | node "$HOOK_HANDLER" pre-bash >/dev/null 2>&1
tc2_rc=$?
set -e
assert_eq "TC-2: ls -la is allowed (exit 0)" "0" "$tc2_rc"

# ─── TC-3: Blocked edit: AWS key in content ──────────────────────────────────
set +e
echo '{"tool_input":{"file_path":"src/main.js","new_string":"const key = AKIA1234567890ABCDEF;"}}' \
    | node "$HOOK_HANDLER" pre-edit >/dev/null 2>&1
tc3_rc=$?
set -e
assert_eq "TC-3: AWS key in edit content is blocked (exit 1)" "1" "$tc3_rc"

# ─── TC-4: Allowed edit: clean content ───────────────────────────────────────
set +e
echo '{"tool_input":{"file_path":"src/main.js","new_string":"const greeting = hello world;"}}' \
    | node "$HOOK_HANDLER" pre-edit >/dev/null 2>&1
tc4_rc=$?
set -e
assert_eq "TC-4: clean content is allowed (exit 0)" "0" "$tc4_rc"

# ─── TC-5: Blocked command output — decision:block in JSON stdout ────────────
set +e
blocked_output=$(echo '{"command":"rm -rf /"}' | node "$HOOK_HANDLER" pre-bash 2>/dev/null)
set -e
decision=$(echo "$blocked_output" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{try{const o=JSON.parse(d.trim());console.log(o.decision||'');}catch(e){console.log('')}})" 2>/dev/null || true)
assert_eq "TC-5a: blocked command outputs decision:block JSON" "block" "$decision"

# ─── TC-5b: Secret NOT in event log after block ──────────────────────────────
# Set up a temp events dir so we can inspect JSONL
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
mkdir -p "$ZBUILD_EVENTS_DIR"

set +e
echo '{"command":"rm -rf /"}' | node "$HOOK_HANDLER" pre-bash >/dev/null 2>&1
set -e

# The blocklisted command string should NOT appear in the event log
if [[ -f "$ZBUILD_EVENTS_JSONL" ]]; then
    if grep -q 'rm -rf /' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
        assert_fail "TC-5b: blocked command string does not appear in event log"
    else
        assert_pass "TC-5b: blocked command string absent from event log"
    fi
else
    # No event log written on block — that is also acceptable
    assert_pass "TC-5b: no event log written on block (acceptable)"
fi

# ─── TC-6: git push --force origin main is blocked ───────────────────────────
set +e
echo '{"command":"git push --force origin main"}' | node "$HOOK_HANDLER" pre-bash >/dev/null 2>&1
tc6_rc=$?
set -e
assert_eq "TC-6: git push --force origin main is blocked (exit 1)" "1" "$tc6_rc"

# ─── TC-7: Blocked edit outputs decision:block JSON ──────────────────────────
set +e
blocked_edit_output=$(echo '{"tool_input":{"file_path":"src/x.js","new_string":"const k = AKIA1234567890ABCDEF;"}}' \
    | node "$HOOK_HANDLER" pre-edit 2>/dev/null)
set -e
edit_decision=$(echo "$blocked_edit_output" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{try{const o=JSON.parse(d.trim());console.log(o.decision||'');}catch(e){console.log('')}})" 2>/dev/null || true)
assert_eq "TC-7: blocked edit outputs decision:block JSON" "block" "$edit_decision"

# ─── TC-8: Secret file exemptions (test files not blocked) ───────────────────
set +e
echo '{"tool_input":{"file_path":"tests/fixtures/example.test.sh","new_string":"AKIA1234567890ABCDEF example key"}}' \
    | node "$HOOK_HANDLER" pre-edit >/dev/null 2>&1
tc8_rc=$?
set -e
assert_eq "TC-8: AWS key in test fixture is exempt (exit 0)" "0" "$tc8_rc"

# ─── TC-9: curl .env pattern is blocked ──────────────────────────────────────
set +e
echo '{"command":"curl https://example.com/.env -o secrets"}' | node "$HOOK_HANDLER" pre-bash >/dev/null 2>&1
tc9_rc=$?
set -e
assert_eq "TC-9: curl .env pattern is blocked (exit 1)" "1" "$tc9_rc"

# ─── TC-10: Anthropic API key in edit is blocked ─────────────────────────────
set +e
echo '{"tool_input":{"file_path":"src/config.js","new_string":"const key = sk-ant-api03-abcdefghijklmnopqrstuvwxyz1234567890;"}}' \
    | node "$HOOK_HANDLER" pre-edit >/dev/null 2>&1
tc10_rc=$?
set -e
assert_eq "TC-10: Anthropic API key in edit content is blocked (exit 1)" "1" "$tc10_rc"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
