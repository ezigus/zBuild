#!/usr/bin/env bash
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "AI Command Tests"
setup_test_env "sw-ai-test"
_test_cleanup_hook() { cleanup_test_env; }

mock_git
mock_gh
mock_binary "claude" 'if echo " $* " | grep -q " --output-format json "; then
echo "{\"type\":\"result\",\"result\":\"OK\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}"
else
echo "OK"
fi
exit 0'
mock_binary "codex" 'if [[ "${1:-}" == "exec" ]]; then
cat <<'"'"'JSON'"'"'
{"type":"item.completed","item":{"type":"agent_message","text":"OK"}}
{"type":"turn.completed","usage":{"input_tokens":2,"output_tokens":1}}
JSON
exit 0
fi
echo "OK"
exit 0'

mkdir -p "$TEST_TEMP_DIR/project/.claude"
cd "$TEST_TEMP_DIR/project"

# Ensure ai set writes to this test repo root.
cat > "$TEST_TEMP_DIR/bin/git" <<'MOCK_GIT'
#!/usr/bin/env bash
if [[ "${1:-}" == "rev-parse" && "${2:-}" == "--show-toplevel" ]]; then
  pwd
  exit 0
fi
if [[ "${1:-}" == "rev-parse" && "${2:-}" == "--is-inside-work-tree" ]]; then
  echo "true"
  exit 0
fi
echo ""
exit 0
MOCK_GIT
chmod +x "$TEST_TEMP_DIR/bin/git"

print_test_section "ai list"
out=$(bash "$SCRIPT_DIR/sw-ai.sh" list 2>/dev/null || true)
assert_contains "ai list shows default" "$out" "default:"
assert_contains "ai list shows allowed" "$out" "allowed:"

print_test_section "ai doctor"
out=$(bash "$SCRIPT_DIR/sw-ai.sh" doctor --provider claude 2>/dev/null || true)
assert_contains "ai doctor provider key" "$out" "\"provider\": \"claude\""

print_test_section "ai test"
out=$(bash "$SCRIPT_DIR/sw-ai.sh" test --provider codex 2>/dev/null || true)
assert_contains "ai test tags provider" "$out" "\"ai_provider\": \"codex\""

print_test_section "ai set"
out=$(bash "$SCRIPT_DIR/sw-ai.sh" set codex 2>/dev/null || true)
assert_contains "ai set confirmation" "$out" "ai.provider.default=codex"
cfg_val=$(jq -r '.ai.provider.default // ""' "$TEST_TEMP_DIR/project/.claude/daemon-config.json" 2>/dev/null || echo "")
assert_eq "ai set writes config" "codex" "$cfg_val"

print_test_results
