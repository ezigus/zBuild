#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright swarm test — Dynamic agent swarm management tests            ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/bin"

    # Link real jq
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi

    # Mock git
    cat > "$TEST_TEMP_DIR/bin/git" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse) echo "/tmp/mock-repo" ;;
    log) echo "abc1234 fix: something" ;;
    diff) echo "" ;;
    *) echo "" ;;
esac
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/git"

    # Mock gh
    cat > "$TEST_TEMP_DIR/bin/gh" <<'MOCK'
#!/usr/bin/env bash
echo '[]'
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/gh"

    # Mock claude
    cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
echo "Mock claude response"
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/claude"

    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
}

_test_cleanup_hook() {
    # Kill any tmux sessions spawned during tests before removing temp dir.
    # Use process substitution with || true so grep returning 1 (no matches)
    # does not fail the pipeline under set -euo pipefail.
    if command -v tmux >/dev/null 2>&1; then
        while IFS= read -r s; do
            tmux kill-session -t "$s" 2>/dev/null || true
        done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -E '^swarm-' || true)
    fi
    cleanup_test_env
}

echo ""
print_test_header "Shipwright Swarm Tests"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""

setup_env

# ─── Test 1: Help output ─────────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-swarm.sh" help 2>&1) || true
if echo "$output" | grep -q "shipwright swarm"; then
    assert_pass "help shows usage text"
else
    assert_fail "help shows usage text"
fi

# ─── Test 2: Help exits 0 ────────────────────────────────────────────────────
bash "$SCRIPT_DIR/sw-swarm.sh" help >/dev/null 2>&1
assert_eq "help exits 0" "0" "$?"

# ─── Test 3: --help flag works ───────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-swarm.sh" --help 2>&1) || true
assert_contains "--help flag works" "$output" "COMMANDS"

# ─── Test 4: Status with empty registry ──────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-swarm.sh" status 2>&1) || true
assert_contains "status shows empty swarm" "$output" "No agents in swarm"

# ─── Test 5: Spawn creates agent in registry ─────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-swarm.sh" spawn standard 2>&1) || true
assert_contains "spawn standard creates agent" "$output" "Spawned agent"

# ─── Test 6: Registry file exists after spawn ────────────────────────────────
if [[ -f "$HOME/.shipwright/swarm/registry.json" ]]; then
    assert_pass "registry.json exists after spawn"
else
    assert_fail "registry.json exists after spawn"
fi

# ─── Test 7: Registry has active_count 1 ─────────────────────────────────────
active_count=$(jq -r '.active_count' "$HOME/.shipwright/swarm/registry.json" 2>/dev/null)
assert_eq "active_count is 1 after spawn" "1" "$active_count"

# ─── Test 8: Config file initialized ─────────────────────────────────────────
if [[ -f "$HOME/.shipwright/swarm/config.json" ]]; then
    assert_pass "config.json exists after operations"
else
    assert_fail "config.json exists after operations"
fi

# ─── Test 9: Spawn invalid type fails ────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-swarm.sh" spawn nonexistent 2>&1) || true
assert_contains "spawn invalid type returns error" "$output" "Invalid agent type"

# ─── Test 10: Health check with agents ───────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-swarm.sh" health 2>&1) || true
assert_contains "health shows agent status" "$output" "Agent Health Status"

# ─── Test 11: Top leaderboard ────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-swarm.sh" top 2>&1) || true
assert_contains "top shows leaderboard" "$output" "Agent Performance Leaderboard"

# ─── Test 12: Config show ────────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-swarm.sh" config show 2>&1) || true
assert_contains "config show displays settings" "$output" "auto_scaling_enabled"

# ─── Test 13: Config set ─────────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-swarm.sh" config set max_agents 12 2>&1) || true
new_val=$(jq -r '.max_agents' "$HOME/.shipwright/swarm/config.json" 2>/dev/null)
assert_eq "config set updates value" "12" "$new_val"

# ─── Test 14: Config reset ───────────────────────────────────────────────────
bash "$SCRIPT_DIR/sw-swarm.sh" config reset >/dev/null 2>&1 || true
reset_val=$(jq -r '.max_agents' "$HOME/.shipwright/swarm/config.json" 2>/dev/null)
assert_eq "config reset restores defaults" "8" "$reset_val"

# ─── Test 15: Unknown command exits 1 ────────────────────────────────────────
if bash "$SCRIPT_DIR/sw-swarm.sh" nonexistent >/dev/null 2>&1; then
    assert_fail "unknown command exits 1"
else
    assert_pass "unknown command exits 1"
fi

# ─── Test 16: prune removes stale agents ─────────────────────────────────────
# Spawn an agent then backdate its heartbeat to simulate staleness
bash "$SCRIPT_DIR/sw-swarm.sh" spawn standard >/dev/null 2>&1 || true
stale_id=$(jq -r '.agents[0].id' "$HOME/.shipwright/swarm/registry.json" 2>/dev/null)
# Backdate heartbeat to 2020 (well past any threshold)
tmp_reg=$(mktemp)
jq '.agents[0].last_heartbeat = "2020-01-01T00:00:00Z"' \
    "$HOME/.shipwright/swarm/registry.json" > "$tmp_reg" && mv "$tmp_reg" "$HOME/.shipwright/swarm/registry.json"
output=$(bash "$SCRIPT_DIR/sw-swarm.sh" prune 2>&1) || true
if echo "$output" | grep -qiE "Pruned|stale"; then
    assert_pass "prune removes stale agents"
else
    assert_fail "prune removes stale agents" "$output"
fi

# ─── Test 17: prune keeps active agents ──────────────────────────────────────
# Spawn a fresh agent — heartbeat is recent, should survive prune
bash "$SCRIPT_DIR/sw-swarm.sh" spawn standard >/dev/null 2>&1 || true
count_before=$(jq -r '.agents | length' "$HOME/.shipwright/swarm/registry.json" 2>/dev/null)
bash "$SCRIPT_DIR/sw-swarm.sh" prune >/dev/null 2>&1 || true
count_after=$(jq -r '.agents | length' "$HOME/.shipwright/swarm/registry.json" 2>/dev/null)
if [[ "$count_after" -ge "$count_before" ]]; then
    assert_pass "prune keeps active agents"
else
    assert_fail "prune keeps active agents" "before=$count_before after=$count_after"
fi

# ─── Test 18: prune mixed — removes stale, keeps active ──────────────────────
# Fresh state: spawn 2 agents, backdate one
bash "$SCRIPT_DIR/sw-swarm.sh" config reset >/dev/null 2>&1 || true
# Reset registry
echo '{"agents":[],"active_count":0,"last_updated":"2025-01-01T00:00:00Z"}' > "$HOME/.shipwright/swarm/registry.json"
bash "$SCRIPT_DIR/sw-swarm.sh" spawn standard >/dev/null 2>&1 || true
bash "$SCRIPT_DIR/sw-swarm.sh" spawn standard >/dev/null 2>&1 || true
# Backdate first agent
tmp_reg=$(mktemp)
jq '.agents[0].last_heartbeat = "2020-01-01T00:00:00Z"' \
    "$HOME/.shipwright/swarm/registry.json" > "$tmp_reg" && mv "$tmp_reg" "$HOME/.shipwright/swarm/registry.json"
count_before=$(jq -r '.agents | length' "$HOME/.shipwright/swarm/registry.json")
bash "$SCRIPT_DIR/sw-swarm.sh" prune >/dev/null 2>&1 || true
count_after=$(jq -r '.agents | length' "$HOME/.shipwright/swarm/registry.json")
if [[ "$count_after" -eq $((count_before - 1)) ]]; then
    assert_pass "prune mixed: removes stale, keeps active"
else
    assert_fail "prune mixed: removes stale, keeps active" "before=$count_before after=$count_after (expected $((count_before - 1)))"
fi

# ─── Test 19: prune empty registry ───────────────────────────────────────────
echo '{"agents":[],"active_count":0,"last_updated":"2025-01-01T00:00:00Z"}' > "$HOME/.shipwright/swarm/registry.json"
exit_code=0
output=$(bash "$SCRIPT_DIR/sw-swarm.sh" prune 2>&1) || exit_code=$?
if [[ $exit_code -eq 0 ]]; then
    assert_pass "prune empty registry exits cleanly"
else
    assert_fail "prune empty registry exits cleanly" "exit_code=$exit_code"
fi

# ─── Test 19b: prune with corrupt registry exits cleanly ────────────────────
echo "corrupt{not json" > "$HOME/.shipwright/swarm/registry.json"
exit_code=0
output=$(bash "$SCRIPT_DIR/sw-swarm.sh" prune 2>&1) || exit_code=$?
if [[ $exit_code -eq 0 ]]; then
    assert_pass "prune corrupt registry exits cleanly"
else
    assert_fail "prune corrupt registry exits cleanly" "exit_code=$exit_code output=$output"
fi
# Verify it attempted the tmux fallback scan (message mentions scanning or orphaned)
if echo "$output" | grep -qiE "scanning|orphan|No orphaned"; then
    assert_pass "prune corrupt registry triggers tmux fallback"
else
    assert_fail "prune corrupt registry triggers tmux fallback" "output=$output"
fi

# ─── Test 19c: prune with missing registry file exits cleanly ───────────────
rm -f "$HOME/.shipwright/swarm/registry.json"
exit_code=0
output=$(bash "$SCRIPT_DIR/sw-swarm.sh" prune 2>&1) || exit_code=$?
if [[ $exit_code -eq 0 ]]; then
    assert_pass "prune missing registry exits cleanly"
else
    assert_fail "prune missing registry exits cleanly" "exit_code=$exit_code output=$output"
fi

# ─── Test 20: prune --quiet suppresses output ────────────────────────────────
echo '{"agents":[],"active_count":0,"last_updated":"2025-01-01T00:00:00Z"}' > "$HOME/.shipwright/swarm/registry.json"
bash "$SCRIPT_DIR/sw-swarm.sh" spawn standard >/dev/null 2>&1 || true
tmp_reg=$(mktemp)
jq '.agents[0].last_heartbeat = "2020-01-01T00:00:00Z"' \
    "$HOME/.shipwright/swarm/registry.json" > "$tmp_reg" && mv "$tmp_reg" "$HOME/.shipwright/swarm/registry.json"
output=$(bash "$SCRIPT_DIR/sw-swarm.sh" prune --quiet 2>&1) || true
if [[ -z "$output" ]]; then
    assert_pass "prune --quiet produces no output"
else
    assert_fail "prune --quiet produces no output" "got: $output"
fi

# ─── Test 21: health auto-prunes stale agents ────────────────────────────────
echo '{"agents":[],"active_count":0,"last_updated":"2025-01-01T00:00:00Z"}' > "$HOME/.shipwright/swarm/registry.json"
bash "$SCRIPT_DIR/sw-swarm.sh" spawn standard >/dev/null 2>&1 || true
tmp_reg=$(mktemp)
jq '.agents[0].last_heartbeat = "2020-01-01T00:00:00Z"' \
    "$HOME/.shipwright/swarm/registry.json" > "$tmp_reg" && mv "$tmp_reg" "$HOME/.shipwright/swarm/registry.json"
count_before=$(jq -r '.agents | length' "$HOME/.shipwright/swarm/registry.json")
bash "$SCRIPT_DIR/sw-swarm.sh" health >/dev/null 2>&1 || true
count_after=$(jq -r '.agents | length' "$HOME/.shipwright/swarm/registry.json")
if [[ "$count_after" -lt "$count_before" ]]; then
    assert_pass "health auto-prunes stale agents"
else
    assert_fail "health auto-prunes stale agents" "before=$count_before after=$count_after"
fi

echo ""
echo ""
print_test_results
