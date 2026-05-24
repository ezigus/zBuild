#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright ai-provider test — Router + adapter normalization tests       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "AI Provider Router Tests"

setup_test_env "sw-ai-provider-test"
_test_cleanup_hook() { cleanup_test_env; }

mock_git
mock_gh

mock_binary "claude" 'if echo " $* " | grep -q " --output-format json "; then
cat <<'"'"'JSON'"'"'
{"type":"result","result":"Claude says LOOP_COMPLETE","total_cost_usd":0.12,"usage":{"input_tokens":11,"output_tokens":5}}
JSON
exit 0
fi
echo "Claude text response"
exit 0'

mock_binary "codex" 'if [[ "${1:-}" == "exec" ]]; then
cat <<'"'"'JSON'"'"'
{"type":"thread.started","thread_id":"test-thread"}
{"type":"item.completed","item":{"type":"agent_message","text":"Codex says LOOP_COMPLETE"}}
{"type":"turn.completed","usage":{"input_tokens":17,"cached_input_tokens":3,"output_tokens":9}}
JSON
exit 0
fi
echo "Codex text response"
exit 0'

_AI_PROVIDER_LOADED=""
source "$SCRIPT_DIR/lib/ai-provider.sh"

print_test_section "provider resolution"
unset SHIPWRIGHT_AI_PROVIDER || true
resolved=$(ai_provider_resolve "")
assert_eq "default provider resolves from config" "claude" "$resolved"

SHIPWRIGHT_AI_PROVIDER=codex
resolved=$(ai_provider_resolve "")
assert_eq "env override provider" "codex" "$resolved"
unset SHIPWRIGHT_AI_PROVIDER || true

if ai_provider_resolve "unknown" >/dev/null 2>&1; then
    assert_fail "invalid provider should fail"
else
    assert_pass "invalid provider should fail"
fi

print_test_section "model mapping"
assert_eq "claude sonnet maps" "sonnet" "$(ai_provider_model_for_tier claude sonnet)"
assert_eq "codex haiku maps" "gpt-5.1-codex-mini" "$(ai_provider_model_for_tier codex haiku)"

print_test_section "doctor"
doctor_json=$(ai_provider_doctor_json "claude")
assert_json_key "doctor provider name" "$doctor_json" '.provider' "claude"
assert_json_key "doctor installed true" "$doctor_json" '.installed' "true"

print_test_section "run + normalize"
claude_json=$(ai_run_json "claude" "say ok" "sonnet" "1" "$TEST_TEMP_DIR/claude.out" "$TEST_TEMP_DIR/claude.err")
assert_json_key "claude provider tagged" "$claude_json" '.ai_provider' "claude"
assert_json_key "claude completion signal" "$claude_json" '.completion_signal_detected' "true"
assert_json_key "claude usage source exact" "$claude_json" '.usage_source' "exact"
assert_json_key "claude input tokens parsed" "$claude_json" '.input_tokens' "11"

codex_json=$(ai_run_json "codex" "say ok" "sonnet" "1" "$TEST_TEMP_DIR/codex.out" "$TEST_TEMP_DIR/codex.err")
assert_json_key "codex provider tagged" "$codex_json" '.ai_provider' "codex"
assert_json_key "codex completion signal" "$codex_json" '.completion_signal_detected' "true"
assert_json_key "codex usage source exact" "$codex_json" '.usage_source' "exact"
assert_json_key "codex output tokens parsed" "$codex_json" '.output_tokens' "9"

if ai_run_text "codex" "hello text" "sonnet" "1" "$TEST_TEMP_DIR/text.out" "$TEST_TEMP_DIR/text.err"; then
    assert_pass "ai_run_text executes for codex"
else
    assert_fail "ai_run_text executes for codex"
fi

print_test_results
