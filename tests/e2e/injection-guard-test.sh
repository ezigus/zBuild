#!/usr/bin/env bash
# Tests: shell metacharacter injection guard in ZBUILD_GOAL and --goal
# E2E: invokes real scripts/zbuild with PATH-shadowed externals
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ZBUILD_CLI="$REPO_ROOT/scripts/zbuild"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "injection-guard — shell metacharacter safety in goal (E2E)"
setup_test_env "e2e-injection-guard"

export ZBUILD_TEST_TMP="$TEST_TEMP_DIR"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
mkdir -p "$ZBUILD_STATE_DIR" "$TEST_TEMP_DIR/events"

# PATH-shadow claude and gh with no-op mocks
mock_claude
mock_gh
mock_git

_test_cleanup_hook() { cleanup_test_env; }

# Build minimal stub plugins
PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
mkdir -p "$PLUGINS_ROOT/agent/intake" "$PLUGINS_ROOT/agent/security-lens" "$PLUGINS_ROOT/tool/output"

for stage in intake security-lens; do
    cat > "$PLUGINS_ROOT/agent/$stage/manifest.yaml" <<YAML
id: $stage
name: Stub $stage
kind: agent
version: 0.0.1
hooks:
  run: ${stage//-/_}_run
requires:
  core:
    - redaction
YAML
    printf '%s() { return 0; }\n' "${stage//-/_}_run" > "$PLUGINS_ROOT/agent/$stage/plugin.sh"
done

cat > "$PLUGINS_ROOT/tool/output/manifest.yaml" <<YAML
id: output
name: Stub output
kind: tool
version: 0.0.1
hooks:
  run: output_run
YAML
printf 'output_run() { return 0; }\n' > "$PLUGINS_ROOT/tool/output/plugin.sh"
export ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT"

# ─── Helper: run CLI with a goal and capture combined output ──────────────────
_run_with_goal() {
    local goal_val="$1"
    local out rc
    set +e
    out="$(ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" \
           ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state" \
           bash "$ZBUILD_CLI" pipeline start --goal "$goal_val" --dry-run 2>&1)"
    rc=$?
    set -e
    printf '%s' "$out"
    return $rc
}

# ─── Test 1: goal='$(id)' — id command must NOT execute (no uid= in output) ───
out="$(_run_with_goal '$(id)' 2>&1 || true)"
if echo "$out" | grep -q 'uid='; then
    assert_fail "goal=\$(id): id command did not execute (no uid= in output)" \
        "INJECTION DETECTED: output contained uid=; goal value was expanded"
else
    assert_pass "goal=\$(id): id command did not execute (no uid= in output)"
fi

# ─── Test 2: goal='`id`' (backtick) — id command must NOT execute ─────────────
out="$(_run_with_goal '`id`' 2>&1 || true)"
if echo "$out" | grep -q 'uid='; then
    assert_fail "goal=\`id\`: backtick id command did not execute (no uid= in output)" \
        "INJECTION DETECTED: output contained uid=; backtick expansion occurred"
else
    assert_pass "goal=\`id\`: backtick id command did not execute (no uid= in output)"
fi

# ─── Test 3: goal='hello; echo INJECTED' — semicolon injection ───────────────
# The CLI may echo the goal value back (e.g. "goal=hello; echo INJECTED" in
# the dry-run header). That is safe — the goal is handled as a quoted string.
# What we must NOT see is "INJECTED" appearing on its own line (the output of
# an actual `echo INJECTED` command execution).
out="$(_run_with_goal 'hello; echo INJECTED' 2>&1 || true)"
if echo "$out" | grep -qxF 'INJECTED'; then
    assert_fail "goal='hello; echo INJECTED': semicolon injection not executed (echo INJECTED ran)" \
        "INJECTION DETECTED: 'INJECTED' appeared as a standalone output line"
else
    assert_pass "goal='hello; echo INJECTED': semicolon injection not executed (no standalone INJECTED line)"
fi

# ─── Test 4: goal with unicode — CLI exits without crashing ───────────────────
set +e
out="$(ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" \
       ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state" \
       bash "$ZBUILD_CLI" pipeline start --goal 'héllo wörld' --dry-run 2>&1)"
rc=$?
set -e
# The CLI should not segfault or crash with signal (rc > 128 means signal)
if [[ "$rc" -gt 128 ]]; then
    assert_fail "goal with unicode does not crash (rc=$rc — looks like signal/crash)"
else
    assert_pass "goal with unicode: CLI exits without crashing (rc=$rc)"
fi

cleanup_test_env
print_test_results
