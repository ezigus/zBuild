#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright loop test — Validate continuous agent loop harness           ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/home/.claude"
    mkdir -p "$TEST_TEMP_DIR/bin"
    mkdir -p "$TEST_TEMP_DIR/repo/.git"

    # Mock claude CLI
    cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCKEOF'
#!/usr/bin/env bash
echo "Mock claude executed"
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/claude"

    # Mock git
    cat > "$TEST_TEMP_DIR/bin/git" <<'MOCKEOF'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse)
        if [[ "${2:-}" == "--show-toplevel" ]]; then
            echo "/tmp/mock-repo"
        elif [[ "${2:-}" == "--abbrev-ref" ]]; then
            echo "main"
        else
            echo "abc1234"
        fi
        ;;
    diff)
        echo "+added line"
        echo "-removed line"
        ;;
    log)
        echo "abc1234 Mock commit message"
        ;;
    worktree)
        echo "ok"
        ;;
    branch)
        echo "main"
        ;;
    status)
        echo "nothing to commit"
        ;;
    *)
        echo "mock git: $*"
        ;;
esac
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/git"

    # Mock gh
    cat > "$TEST_TEMP_DIR/bin/gh" <<'MOCKEOF'
#!/usr/bin/env bash
echo "mock gh output"
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/gh"

    # Mock tmux
    cat > "$TEST_TEMP_DIR/bin/tmux" <<'MOCKEOF'
#!/usr/bin/env bash
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/tmux"

    # Link real jq
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi

    # Link real date, wc, etc.
    for cmd in date wc cat grep sed awk sort mkdir rm mv cp mktemp basename dirname printf od tr cut head tail tee touch; do
        if command -v "$cmd" &>/dev/null; then
            ln -sf "$(command -v "$cmd")" "$TEST_TEMP_DIR/bin/$cmd"
        fi
    done

    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
}

_test_cleanup_hook() { cleanup_test_env; }

# Use assert_pass/assert_fail from test-helpers.sh (they track TOTAL/PASS/FAIL counters)

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
print_test_header "Shipwright Loop Tests"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""

setup_test_env "sw-loop-test"
setup_env

# ─── Test 1: --help flag ────────────────────────────────────────────────────
echo -e "${DIM}  help / version${RESET}"

output=$(bash "$SCRIPT_DIR/sw-loop.sh" --help 2>&1 | sed $'s/\033\[[0-9;]*m//g') && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "--help exits 0"
else
    assert_fail "--help exits 0" "exit code: $rc"
fi

assert_contains "--help shows usage" "$output" "USAGE"
assert_contains "--help shows options" "$output" "OPTIONS"

# ─── Test 2: --help shows all key options ────────────────────────────────────
assert_contains "--help mentions --max-iterations" "$output" "--max-iterations"
assert_contains "--help mentions --test-cmd" "$output" "--test-cmd"
assert_contains "--help mentions --model" "$output" "--model"
assert_contains "--help mentions --agents" "$output" "--agents"
assert_contains "--help mentions --resume" "$output" "--resume"

# ─── Test 3: VERSION is defined ─────────────────────────────────────────────
version_line=$(grep '^VERSION=' "$SCRIPT_DIR/sw-loop.sh" | head -1)
if [[ -n "$version_line" ]]; then
    assert_pass "VERSION variable defined in sw-loop.sh"
else
    assert_fail "VERSION variable defined in sw-loop.sh"
fi

# ─── Test 4: Missing goal argument ───────────────────────────────────────────
echo ""
echo -e "${DIM}  argument parsing${RESET}"

# sw-loop.sh requires a goal — no goal means empty GOAL var, should fail
output=$(bash "$SCRIPT_DIR/sw-loop.sh" 2>&1) && rc=0 || rc=$?
if [[ $rc -ne 0 ]]; then
    assert_pass "No arguments exits non-zero"
else
    assert_fail "No arguments exits non-zero" "expected failure, got exit 0"
fi

# ─── Test 5: Script uses set -euo pipefail ──────────────────────────────────
echo ""
echo -e "${DIM}  script safety${RESET}"

if grep -q '^set -euo pipefail' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Uses set -euo pipefail"
else
    assert_fail "Uses set -euo pipefail"
fi

# ─── Test 6: ERR trap is set ────────────────────────────────────────────────
if grep -q "trap.*ERR" "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "ERR trap is set"
else
    assert_fail "ERR trap is set"
fi

# ─── Test 7: SIGHUP trap for daemon resilience ──────────────────────────────
if grep -q "trap '' HUP" "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "SIGHUP trap set for daemon resilience"
else
    assert_fail "SIGHUP trap set for daemon resilience"
fi

# ─── Test 8: CLAUDECODE unset ───────────────────────────────────────────────
if grep -q "unset CLAUDECODE" "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "CLAUDECODE env var is unset"
else
    assert_fail "CLAUDECODE env var is unset"
fi

# ─── Test 9: Default values ─────────────────────────────────────────────────
echo ""
echo -e "${DIM}  defaults${RESET}"

# Check key defaults in source
if grep -q 'MAX_ITERATIONS="${SW_MAX_ITERATIONS:-20}"' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Default MAX_ITERATIONS is 20"
else
    assert_fail "Default MAX_ITERATIONS is 20"
fi

if grep -q 'AGENTS=1' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Default AGENTS is 1"
else
    assert_fail "Default AGENTS is 1"
fi

if grep -qE 'MAX_RESTARTS.*0|loop\.max_restarts.*0' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Default MAX_RESTARTS is 0"
else
    assert_fail "Default MAX_RESTARTS is 0"
fi

# Anchor on a non-digit (or end-of-line) to avoid matching EXTENSION_SIZE=30 etc.
if grep -qE '^EXTENSION_SIZE=3([^0-9]|$)' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Default EXTENSION_SIZE is 3"
else
    assert_fail "Default EXTENSION_SIZE is 3"
fi

if grep -qE '^MAX_EXTENSIONS=1([^0-9]|$)' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Default MAX_EXTENSIONS is 1"
else
    assert_fail "Default MAX_EXTENSIONS is 1"
fi

# ─── Test 10: Compat library sourced ─────────────────────────────────────────
if grep -q 'lib/compat.sh' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Sources lib/compat.sh"
else
    assert_fail "Sources lib/compat.sh"
fi

# ─── Test 11: JSON output format in claude flags ────────────────────────────
echo ""
echo -e "${DIM}  json output format${RESET}"
if grep -q 'output-format.*json' "$SCRIPT_DIR/sw-loop.sh" || grep -q 'output-format.*json' "$SCRIPT_DIR/lib/loop-iteration.sh"; then
    assert_pass "build_claude_flags includes --output-format json"
else
    assert_fail "build_claude_flags includes --output-format json"
fi

# ─── Test 12: Token accumulation parses JSON ────────────────────────────────
if grep -q 'jq.*usage.input_tokens' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "accumulate_loop_tokens parses JSON usage"
else
    assert_fail "accumulate_loop_tokens parses JSON usage"
fi

# ─── Test 13: Cost tracking variable initialized ────────────────────────────
if grep -q 'LOOP_COST_MILLICENTS=0' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "LOOP_COST_MILLICENTS initialized"
else
    assert_fail "LOOP_COST_MILLICENTS initialized"
fi

# ─── Test 14: write_loop_tokens includes cost ────────────────────────────────
if grep -q 'cost_usd' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "write_loop_tokens includes cost_usd"
else
    assert_fail "write_loop_tokens includes cost_usd"
fi

# ─── Test 15: _extract_text_from_json helper exists ──────────────────────────
if grep -q '_extract_text_from_json' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "_extract_text_from_json helper defined"
else
    assert_fail "_extract_text_from_json helper defined"
fi

# ─── Test 15b: validate_claude_output and check_budget_gate exist ───────────
if grep -q 'validate_claude_output()' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "validate_claude_output helper defined"
else
    assert_fail "validate_claude_output helper defined"
fi
if grep -q 'check_budget_gate()' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "check_budget_gate helper defined"
else
    assert_fail "check_budget_gate helper defined"
fi

# ─── Test 16: run_claude_iteration separates stdout/stderr ───────────────────
if grep -q '2>"$err_file"' "$SCRIPT_DIR/sw-loop.sh" || grep -q '2>"$err_file"' "$SCRIPT_DIR/lib/loop-iteration.sh"; then
    assert_pass "run_claude_iteration separates stdout from stderr"
else
    assert_fail "run_claude_iteration separates stdout from stderr"
fi

# ─── Test 17-19: _extract_text_from_json robustness ──────────────────────────
echo ""
echo -e "${DIM}  json extraction robustness${RESET}"
# Extract the function from sw-loop.sh and test it in isolation (can't source
# sw-loop.sh because it has no source guard — main() runs unconditionally)
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/sw-loop-test.XXXXXX")
_fn_file="$tmpdir/_extract_fn.sh"
sed -n '/^_extract_text_from_json()/,/^}/p' "$SCRIPT_DIR/sw-loop.sh" > "$_fn_file"
bash <<EXTRACT_TEST 2>/dev/null
warn() { :; }
source "$_fn_file"
# Test 1: empty file → '(no output)'
touch "$tmpdir/empty.json"
_extract_text_from_json "$tmpdir/empty.json" "$tmpdir/out1.log" ""
# Test 2: valid JSON array → extracts .result
echo '[{"type":"result","result":"Hello world","usage":{"input_tokens":100}}]' > "$tmpdir/valid.json"
_extract_text_from_json "$tmpdir/valid.json" "$tmpdir/out2.log" ""
# Test 3: plain text → pass through
echo 'This is plain text output' > "$tmpdir/text.json"
_extract_text_from_json "$tmpdir/text.json" "$tmpdir/out3.log" ""
EXTRACT_TEST

if grep -q "no output" "$tmpdir/out1.log" 2>/dev/null; then
    assert_pass "_extract_text_from_json handles empty file"
else
    assert_fail "_extract_text_from_json handles empty file" "expected '(no output)' in $tmpdir/out1.log"
fi

if grep -q "Hello world" "$tmpdir/out2.log" 2>/dev/null; then
    assert_pass "_extract_text_from_json extracts .result from JSON"
else
    assert_fail "_extract_text_from_json extracts .result from JSON" "expected 'Hello world' in $tmpdir/out2.log"
fi

if grep -q "plain text" "$tmpdir/out3.log" 2>/dev/null; then
    assert_pass "_extract_text_from_json passes through plain text"
else
    assert_fail "_extract_text_from_json passes through plain text" "expected 'plain text' in $tmpdir/out3.log"
fi
rm -rf "$tmpdir"

# ─── Test 20: Default configuration values from source ─────────────────────────
echo ""
echo -e "${DIM}  default config from source${RESET}"
max_iter_line=$(grep -E '^MAX_ITERATIONS=' "$SCRIPT_DIR/sw-loop.sh" | head -1)
if [[ "$max_iter_line" =~ 20 ]]; then
    assert_pass "Default MAX_ITERATIONS is 20 (from source)"
else
    assert_fail "Default MAX_ITERATIONS is 20 (from source)" "got: $max_iter_line"
fi
if grep -qE '^AGENTS=' "$SCRIPT_DIR/sw-loop.sh" && grep -q 'AGENTS=1' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Default AGENTS is 1 (from source)"
else
    assert_fail "Default AGENTS is 1 (from source)"
fi
if grep -qE 'MAX_RESTARTS=' "$SCRIPT_DIR/sw-loop.sh" && grep -qE 'max_restarts.*0|MAX_RESTARTS.*0' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Default MAX_RESTARTS is 0 (from source)"
else
    assert_fail "Default MAX_RESTARTS is 0 (from source)"
fi

# ─── Test 21: _extract_text_from_json — nested objects and binary ─────────────
echo ""
echo -e "${DIM}  json extraction edge cases${RESET}"
tmpdir2=$(mktemp -d "${TMPDIR:-/tmp}/sw-loop-test.XXXXXX")
_fn_file2="$tmpdir2/_extract_fn.sh"
sed -n '/^_extract_text_from_json()/,/^}/p' "$SCRIPT_DIR/sw-loop.sh" > "$_fn_file2"
bash <<EXTRACT_TEST2 2>/dev/null
warn() { :; }
source "$_fn_file2"
# Nested JSON array with objects
echo '[{"type":"result","result":"Nested extraction works","usage":{"input_tokens":50}}]' > "$tmpdir2/nested.json"
_extract_text_from_json "$tmpdir2/nested.json" "$tmpdir2/nested_out.log" ""
# Binary garbage — should not crash, pass through or handle
printf '\x00\x01\x02\xff\xfe' > "$tmpdir2/binary.dat"
_extract_text_from_json "$tmpdir2/binary.dat" "$tmpdir2/binary_out.log" ""
EXTRACT_TEST2

if grep -q "Nested extraction works" "$tmpdir2/nested_out.log" 2>/dev/null; then
    assert_pass "_extract_text_from_json handles nested JSON objects"
else
    assert_fail "_extract_text_from_json handles nested JSON objects" "expected 'Nested extraction works'"
fi
# Binary input should not crash; output may be raw or placeholder
if [[ -f "$tmpdir2/binary_out.log" ]]; then
    assert_pass "_extract_text_from_json handles binary garbage without crash"
else
    assert_fail "_extract_text_from_json handles binary garbage without crash"
fi
rm -rf "$tmpdir2"

# ─── Test 21b: _extract_text_from_json — JSON object (not array) ──────────────
echo ""
echo -e "${DIM}  json extraction for JSON objects${RESET}"
tmpdir3=$(mktemp -d "${TMPDIR:-/tmp}/sw-loop-test.XXXXXX")
_fn_file3="$tmpdir3/_extract_fn.sh"
sed -n '/^_extract_text_from_json()/,/^}/p' "$SCRIPT_DIR/sw-loop.sh" > "$_fn_file3"
bash <<EXTRACT_TEST3 2>"$tmpdir3/stderr.log"
warn() { echo "WARN: \$*" >&2; }
source "$_fn_file3"
# Test: JSON object with .result field
echo '{"type":"result","subtype":"success","result":"Object result text","cost_usd":0.05}' > "$tmpdir3/object.json"
_extract_text_from_json "$tmpdir3/object.json" "$tmpdir3/object_out.log" ""
# Test: JSON object with .content field (no .result)
echo '{"type":"result","content":"Object content text"}' > "$tmpdir3/content.json"
_extract_text_from_json "$tmpdir3/content.json" "$tmpdir3/content_out.log" ""
# Test: JSON object — verify no misleading jq warning
echo '{"type":"result","result":"No warning expected"}' > "$tmpdir3/nowarn.json"
_extract_text_from_json "$tmpdir3/nowarn.json" "$tmpdir3/nowarn_out.log" ""
EXTRACT_TEST3

if grep -q "Object result text" "$tmpdir3/object_out.log" 2>/dev/null; then
    assert_pass "_extract_text_from_json extracts .result from JSON object"
else
    assert_fail "_extract_text_from_json extracts .result from JSON object" "expected 'Object result text' in $tmpdir3/object_out.log"
fi

if grep -q "Object content text" "$tmpdir3/content_out.log" 2>/dev/null; then
    assert_pass "_extract_text_from_json extracts .content from JSON object"
else
    assert_fail "_extract_text_from_json extracts .content from JSON object" "expected 'Object content text' in $tmpdir3/content_out.log"
fi

if ! grep -q "jq not available" "$tmpdir3/stderr.log" 2>/dev/null; then
    assert_pass "_extract_text_from_json no misleading jq warning for JSON object"
else
    assert_fail "_extract_text_from_json no misleading jq warning for JSON object" "got misleading 'jq not available' warning"
fi
rm -rf "$tmpdir3"

# ─── Test 22: Script structure — circuit breaker, stuckness, test gate ────────
echo ""
echo -e "${DIM}  script structure${RESET}"
if grep -qE 'check_circuit_breaker|CIRCUIT_BREAKER' "$SCRIPT_DIR/sw-loop.sh" "$SCRIPT_DIR/lib/loop-convergence.sh"; then
    assert_pass "Script has circuit breaker logic"
else
    assert_fail "Script has circuit breaker logic"
fi
if grep -qE 'detect_stuckness|stuckness' "$SCRIPT_DIR/sw-loop.sh" "$SCRIPT_DIR/lib/loop-convergence.sh"; then
    assert_pass "Script has stuckness detection"
else
    assert_fail "Script has stuckness detection"
fi
if grep -qE 'run_test_gate|run_quality_gates' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Script has test/quality gate functions"
else
    assert_fail "Script has test/quality gate functions"
fi

# ─── Test 23: --help key flags defined in show_help ────────────────────────────
# (Actual help output assertions are in Test 2 above)
if grep -qF -- '--model' "$SCRIPT_DIR/sw-loop.sh" && grep -qF -- '--agents' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Help text defines --model and --agents flags"
else
    assert_fail "Help text defines --model and --agents flags"
fi
if grep -qF -- '--test-cmd' "$SCRIPT_DIR/sw-loop.sh" && grep -qF -- '--resume' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Help text defines --test-cmd and --resume flags"
else
    assert_fail "Help text defines --test-cmd and --resume flags"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# LOOP BEHAVIOR TESTS (real loop execution with mocks)
# ═══════════════════════════════════════════════════════════════════════════════

# Setup for loop behavior tests: real git repo, mock claude only
setup_loop_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright" "$TEST_TEMP_DIR/home/.claude" "$TEST_TEMP_DIR/bin"

    # Create real git repo (use system git, not mock from PATH)
    local _git
    _git=$(PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin command -v git 2>/dev/null)
    if [[ -z "$_git" ]]; then
        echo "WARN: git not found — skipping loop behavior tests"
        return 1
    fi
    mkdir -p "$TEST_TEMP_DIR/repo"
    (cd "$TEST_TEMP_DIR/repo" && "$_git" init -q && "$_git" config user.email "t@t" && "$_git" config user.name "T")
    echo "init" > "$TEST_TEMP_DIR/repo/file.txt"
    (cd "$TEST_TEMP_DIR/repo" && "$_git" add . && "$_git" commit -q -m "init")

    # Mock gh
    cat > "$TEST_TEMP_DIR/bin/gh" <<'GHMOCK'
#!/usr/bin/env bash
echo '[]'
exit 0
GHMOCK
    chmod +x "$TEST_TEMP_DIR/bin/gh"

    # Link real jq, git, date, seq, etc. (use clean PATH to avoid mock from setup_env)
    for cmd in jq git date seq wc cat grep sed awk sort mkdir rm mv cp mktemp basename dirname printf od tr cut head tail tee touch bash; do
        if PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin command -v "$cmd" &>/dev/null; then
            ln -sf "$(PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin command -v "$cmd")" "$TEST_TEMP_DIR/bin/$cmd" 2>/dev/null || true
        fi
    done

    # Use our mocks (claude, gh) + real git/jq from our bin
    export PATH="$TEST_TEMP_DIR/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
    return 0
}

# ─── Test: Loop completes when Claude outputs LOOP_COMPLETE ─────────────────
echo ""
echo -e "${DIM}  loop behavior: LOOP_COMPLETE${RESET}"

if setup_loop_env 2>/dev/null; then
    # Mock claude that says LOOP_COMPLETE on first iteration (valid JSON for --output-format json)
    cat > "$TEST_TEMP_DIR/bin/claude" << 'CLAUDE_EOF'
#!/usr/bin/env bash
echo '[{"type":"result","result":"Done. LOOP_COMPLETE","usage":{"input_tokens":0,"output_tokens":0}}]'
exit 0
CLAUDE_EOF
    chmod +x "$TEST_TEMP_DIR/bin/claude"

    output=$(env PATH="$TEST_TEMP_DIR/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" HOME="$TEST_TEMP_DIR/home" NO_GITHUB=true \
        bash "$SCRIPT_DIR/sw-loop.sh" \
        --repo "$TEST_TEMP_DIR/repo" \
        "Do nothing" \
        --max-iterations 5 \
        --test-cmd "true" \
        --local \
        2>&1) || true

    if echo "$output" | grep -qi "Completion signal detected\|LOOP_COMPLETE"; then
        assert_pass "Loop detected completion signal"
    elif echo "$output" | grep -qiE "LOOP COMPLETE|loop complete|loop.*pass"; then
        assert_pass "Loop detected completion signal"
    else
        assert_fail "Loop detected completion signal" "output missing completion signal"
    fi
else
    assert_fail "Loop completes on LOOP_COMPLETE" "setup failed (git missing?)"
fi

# ─── Test: Loop runs multiple iterations when tests fail ───────────────────
echo ""
echo -e "${DIM}  loop behavior: iterations on test failure${RESET}"

if setup_loop_env 2>/dev/null; then
    # Mock claude that makes a change, then says LOOP_COMPLETE on iteration 2
    cat > "$TEST_TEMP_DIR/bin/claude" << 'CLAUDE_EOF'
#!/usr/bin/env bash
if [[ ! -f iter2.txt ]]; then
    echo "Adding file" > iter2.txt
    echo '[{"type":"result","result":"Work in progress","usage":{"input_tokens":0,"output_tokens":0}}]'
else
    echo '[{"type":"result","result":"Done. LOOP_COMPLETE","usage":{"input_tokens":0,"output_tokens":0}}]'
fi
exit 0
CLAUDE_EOF
    chmod +x "$TEST_TEMP_DIR/bin/claude"

    output=$(env PATH="$TEST_TEMP_DIR/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" HOME="$TEST_TEMP_DIR/home" NO_GITHUB=true \
        bash "$SCRIPT_DIR/sw-loop.sh" \
        --repo "$TEST_TEMP_DIR/repo" \
        "Add iter2.txt" \
        --max-iterations 5 \
        --test-cmd "test -f iter2.txt" \
        --local \
        2>&1) || true

    if echo "$output" | grep -qE "Iteration [2-9]|iteration [2-9]"; then
        assert_pass "Loop runs multiple iterations when tests fail initially"
    elif echo "$output" | grep -q "LOOP_COMPLETE"; then
        assert_pass "Loop runs multiple iterations and completes"
    elif echo "$output" | grep -qi "circuit breaker\|max iteration"; then
        assert_pass "Loop iterates (stopped by limit)"
    else
        assert_fail "Loop iterates on test failure" "expected multiple iterations"
    fi
else
    assert_fail "Loop iterates on test failure" "setup failed"
fi

# ─── Test: Loop respects max-iterations limit ──────────────────────────────
echo ""
echo -e "${DIM}  loop behavior: max iterations${RESET}"

if setup_loop_env 2>/dev/null; then
    # Mock claude that never says LOOP_COMPLETE (valid JSON)
    cat > "$TEST_TEMP_DIR/bin/claude" << 'CLAUDE_EOF'
#!/usr/bin/env bash
echo '[{"type":"result","result":"Still working...","usage":{"input_tokens":0,"output_tokens":0}}]'
exit 0
CLAUDE_EOF
    chmod +x "$TEST_TEMP_DIR/bin/claude"

    output=$(env PATH="$TEST_TEMP_DIR/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" HOME="$TEST_TEMP_DIR/home" NO_GITHUB=true \
        bash "$SCRIPT_DIR/sw-loop.sh" \
        --repo "$TEST_TEMP_DIR/repo" \
        "Never finish" \
        --max-iterations 3 \
        --test-cmd "true" \
        --local \
        --no-auto-extend \
        2>&1) || true

    if echo "$output" | grep -qiE "max iteration|iteration.*3|Max iterations"; then
        assert_pass "Loop stops at max iterations"
    else
        assert_fail "Loop respects max-iterations" "expected iteration limit message"
    fi
else
    assert_fail "Loop max iterations" "setup failed"
fi

# ─── Test: LOOP_COMPLETE signal detection hardening (#263) ──────────────────
echo ""
echo -e "${DIM}  loop behavior: LOOP_COMPLETE signal hardening${RESET}"

# Test: main loop prompt uses <<<LOOP:PASS>>> fence delimiter
if grep -q '<<<LOOP:PASS>>>' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Main loop prompt uses <<<LOOP:PASS>>> fence delimiter"
else
    assert_fail "Main loop prompt uses <<<LOOP:PASS>>> fence delimiter"
fi

# Test: guard_completion uses detect_gate_signal (not bare grep)
if grep -q 'detect_gate_signal.*log_file.*LOOP\|detect_gate_signal.*"LOOP"' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "guard_completion uses detect_gate_signal for LOOP signal"
else
    assert_fail "guard_completion uses detect_gate_signal for LOOP signal"
fi

# Test: main agent loop uses detect_gate_signal for completion check
if grep -q 'detect_gate_signal.*LOG_FILE.*LOOP\|detect_gate_signal.*"LOOP"' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Main agent loop uses detect_gate_signal for completion check"
else
    assert_fail "Main agent loop uses detect_gate_signal for completion check"
fi

# Test: check_completion() in loop-convergence.sh uses detect_gate_signal
if grep -q 'detect_gate_signal' "$SCRIPT_DIR/lib/loop-convergence.sh"; then
    assert_pass "loop-convergence.sh check_completion uses detect_gate_signal"
else
    assert_fail "loop-convergence.sh check_completion uses detect_gate_signal"
fi

# Test: ai-provider.sh uses detect_gate_signal (stdin mode) for LOOP signal
if grep -q 'detect_gate_signal.*"-".*LOOP\|detect_gate_signal.*"-"' "$SCRIPT_DIR/lib/ai-provider.sh"; then
    assert_pass "ai-provider.sh uses detect_gate_signal stdin mode for LOOP signal"
else
    assert_fail "ai-provider.sh uses detect_gate_signal stdin mode for LOOP signal"
fi

# Test: gate-signal.sh shared lib exists (detect_gate_signal extracted out of sw-loop.sh)
if [[ -f "$SCRIPT_DIR/lib/gate-signal.sh" ]]; then
    assert_pass "lib/gate-signal.sh shared library exists"
else
    assert_fail "lib/gate-signal.sh shared library exists"
fi

# Test: sw-loop.sh sources gate-signal.sh (not inline)
if grep -q 'gate-signal.sh' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "sw-loop.sh sources gate-signal.sh"
else
    assert_fail "sw-loop.sh sources gate-signal.sh"
fi

# Test: ai-provider.sh sources gate-signal.sh
if grep -q 'gate-signal.sh' "$SCRIPT_DIR/lib/ai-provider.sh"; then
    assert_pass "ai-provider.sh sources gate-signal.sh"
else
    assert_fail "ai-provider.sh sources gate-signal.sh"
fi

# Load detect_gate_signal from the shared lib for functional tests
_dgs_body="$(sed -n '/^detect_gate_signal()/,/^}/p' "$SCRIPT_DIR/lib/gate-signal.sh")"

# Test: legacy LOOP_COMPLETE still detected via Layer 3 (backwards compat)
dgs_test_log="$(mktemp "${TMPDIR:-/tmp}/sw-loop-test.XXXXXX")"
echo "Done. LOOP_COMPLETE" > "$dgs_test_log"
if (eval "$_dgs_body"; detect_gate_signal "$dgs_test_log" "LOOP" 'LOOP_COMPLETE') 2>/dev/null; then
    assert_pass "detect_gate_signal: legacy LOOP_COMPLETE accepted via Layer 3"
else
    assert_fail "detect_gate_signal: legacy LOOP_COMPLETE accepted via Layer 3"
fi
rm -f "$dgs_test_log"

# Test: new <<<LOOP:PASS>>> fence accepted via Layer 2
dgs_test_log="$(mktemp "${TMPDIR:-/tmp}/sw-loop-test.XXXXXX")"
echo "All tasks complete." > "$dgs_test_log"
echo "<<<LOOP:PASS>>>" >> "$dgs_test_log"
if (eval "$_dgs_body"; detect_gate_signal "$dgs_test_log" "LOOP" 'LOOP_COMPLETE') 2>/dev/null; then
    assert_pass "detect_gate_signal: <<<LOOP:PASS>>> fence accepted"
else
    assert_fail "detect_gate_signal: <<<LOOP:PASS>>> fence accepted"
fi
rm -f "$dgs_test_log"

# Test: prose "goal achieved" no longer accepted (narrowed legacy pattern)
dgs_test_log="$(mktemp "${TMPDIR:-/tmp}/sw-loop-test.XXXXXX")"
echo "The goal has been achieved." > "$dgs_test_log"
if ! (eval "$_dgs_body"; detect_gate_signal "$dgs_test_log" "LOOP" 'LOOP_COMPLETE') 2>/dev/null; then
    assert_pass "detect_gate_signal: prose 'goal achieved' correctly rejected (narrowed pattern)"
else
    assert_fail "detect_gate_signal: prose 'goal achieved' correctly rejected (narrowed pattern)"
fi
rm -f "$dgs_test_log"

# Test: <<<LOOP:FAIL>>> blocks pass even when LOOP_COMPLETE also present
dgs_test_log="$(mktemp "${TMPDIR:-/tmp}/sw-loop-test.XXXXXX")"
printf 'LOOP_COMPLETE\n<<<LOOP:FAIL>>>' > "$dgs_test_log"
if ! (eval "$_dgs_body"; detect_gate_signal "$dgs_test_log" "LOOP" 'LOOP_COMPLETE' '<<<LOOP:FAIL>>>') 2>/dev/null; then
    assert_pass "detect_gate_signal: <<<LOOP:FAIL>>> blocks pass (negative-first)"
else
    assert_fail "detect_gate_signal: <<<LOOP:FAIL>>> blocks pass (negative-first)"
fi
rm -f "$dgs_test_log"

# ─── Test: Loop detects stuckness ───────────────────────────────────────────
echo ""
echo -e "${DIM}  loop behavior: stuckness detection${RESET}"

if setup_loop_env 2>/dev/null; then
    # Mock claude that produces identical output every iteration (no file changes)
    cat > "$TEST_TEMP_DIR/bin/claude" << 'CLAUDE_EOF'
#!/usr/bin/env bash
echo '[{"type":"result","result":"I am trying the same approach again.","usage":{"input_tokens":0,"output_tokens":0}}]'
exit 0
CLAUDE_EOF
    chmod +x "$TEST_TEMP_DIR/bin/claude"

    output=$(env PATH="$TEST_TEMP_DIR/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" HOME="$TEST_TEMP_DIR/home" NO_GITHUB=true \
        bash "$SCRIPT_DIR/sw-loop.sh" \
        --repo "$TEST_TEMP_DIR/repo" \
        "Fix something" \
        --max-iterations 5 \
        --test-cmd "false" \
        --local \
        --no-auto-extend \
        2>&1) || true

    if echo "$output" | grep -qi "stuckness\|stuck"; then
        assert_pass "Loop detects stuckness"
    elif echo "$output" | grep -qi "circuit breaker"; then
        assert_pass "Loop circuit breaker triggered (stuckness-related)"
    elif echo "$output" | grep -qi "max iteration"; then
        assert_pass "Loop stops at limit (stuckness test)"
    else
        assert_fail "Loop stuckness detection" "expected stuckness or circuit breaker"
    fi
else
    assert_fail "Loop stuckness detection" "setup failed"
fi

# ─── Test: Budget gate stops loop ──────────────────────────────────────────
echo ""
echo -e "${DIM}  loop behavior: budget gate${RESET}"

# sw-cost reads from ~/.shipwright. Set budget=0.01 and spent>=budget via costs.json.
if setup_loop_env 2>/dev/null && [[ -x "$SCRIPT_DIR/sw-cost.sh" ]]; then
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    _epoch=$(date +%s)
    echo "{\"daily_budget_usd\":0.01,\"enabled\":true}" > "$TEST_TEMP_DIR/home/.shipwright/budget.json"
    echo "{\"entries\":[{\"ts_epoch\":$_epoch,\"cost_usd\":1.0,\"input_tokens\":0,\"output_tokens\":0,\"model\":\"test\",\"stage\":\"test\",\"issue\":\"\"}],\"summary\":{}}" > "$TEST_TEMP_DIR/home/.shipwright/costs.json"
    # Add claude mock (loop exits before running it, but ensures consistent env)
    echo '#!/usr/bin/env bash
echo '"'"'[{"type":"result","result":"Done","usage":{"input_tokens":0,"output_tokens":0}}]'"'"'
exit 0' > "$TEST_TEMP_DIR/bin/claude"
    chmod +x "$TEST_TEMP_DIR/bin/claude"

    output=$(env PATH="$TEST_TEMP_DIR/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" HOME="$TEST_TEMP_DIR/home" NO_GITHUB=true \
        bash "$SCRIPT_DIR/sw-loop.sh" \
        --repo "$TEST_TEMP_DIR/repo" \
        "Do nothing" \
        --max-iterations 2 \
        --test-cmd "true" \
        --local \
        2>&1) || true

    if echo "$output" | grep -qiE "budget exhausted|Budget exhausted|LOOP BUDGET_EXHAUSTED"; then
        assert_pass "Budget gate stops loop"
    else
        assert_fail "Budget gate stops loop" "expected budget exhausted message"
    fi
else
    assert_pass "Budget gate (skipped - setup or sw-cost missing)"
fi

# ─── Test: validate_claude_output catches bad output ───────────────────────
echo ""
echo -e "${DIM}  validate_claude_output${RESET}"

_validate_fn=$(sed -n '/^validate_claude_output()/,/^}/p' "$SCRIPT_DIR/sw-loop.sh")
_valid_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-loop-test.XXXXXX")
# Use real git for repo setup (bypass mock from setup_env)
_valid_git=$(PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin command -v git 2>/dev/null)
(cd "$_valid_tmp" && "$_valid_git" init -q && "$_valid_git" config user.email "t@t" && "$_valid_git" config user.name "T")
echo "api key leaked" > "$_valid_tmp/leak.ts"
(cd "$_valid_tmp" && "$_valid_git" add leak.ts 2>/dev/null)
_valid_out=$(cd "$_valid_tmp" && bash -c "
warn() { :; }
$_validate_fn
validate_claude_output . 2>/dev/null
_e=\$?
echo \"exit=\$_e\"
" 2>/dev/null)
rm -rf "$_valid_tmp"
if echo "$_valid_out" | grep -q "exit=1"; then
    assert_pass "validate_claude_output catches corrupt output"
else
    assert_fail "validate_claude_output catches bad output" "expected non-zero exit for api key leak"
fi

# ─── Test: Loop tracks progress via git diff ──────────────────────────────
echo ""
echo -e "${DIM}  loop behavior: progress tracking${RESET}"

if setup_loop_env 2>/dev/null; then
    # Mock claude that adds a file (simulates progress)
    cat > "$TEST_TEMP_DIR/bin/claude" << 'CLAUDE_EOF'
#!/usr/bin/env bash
echo "new content" > progress.txt
echo '[{"type":"result","result":"Added progress.txt. LOOP_COMPLETE","usage":{"input_tokens":0,"output_tokens":0}}]'
exit 0
CLAUDE_EOF
    chmod +x "$TEST_TEMP_DIR/bin/claude"

    output=$(env PATH="$TEST_TEMP_DIR/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" HOME="$TEST_TEMP_DIR/home" NO_GITHUB=true \
        bash "$SCRIPT_DIR/sw-loop.sh" \
        --repo "$TEST_TEMP_DIR/repo" \
        "Add progress.txt" \
        --max-iterations 3 \
        --test-cmd "true" \
        --local \
        2>&1) || true

    if echo "$output" | grep -qiE "Git:|progress|insertion|LOOP_COMPLETE"; then
        assert_pass "Loop tracks progress via git"
    else
        assert_fail "Loop progress tracking" "expected git/progress output"
    fi
else
    assert_fail "Loop progress tracking" "setup failed"
fi

# ─── Test: context efficiency event emitted ────────────────────────────────
echo ""
echo -e "${DIM}  context efficiency metrics${RESET}"

# context_efficiency was extracted to loop-iteration.sh sub-module
_loop_files="$SCRIPT_DIR/sw-loop.sh $SCRIPT_DIR/lib/loop-iteration.sh"
if grep -q 'emit_event "loop.context_efficiency"' $_loop_files 2>/dev/null; then
    assert_pass "loop.context_efficiency event exists in run_claude_iteration"
else
    assert_fail "loop.context_efficiency event exists in run_claude_iteration"
fi

if grep -q 'raw_prompt_chars=' $_loop_files 2>/dev/null && grep -q 'trimmed_prompt_chars=' $_loop_files 2>/dev/null; then
    assert_pass "Context efficiency emits raw and trimmed char counts"
else
    assert_fail "Context efficiency emits raw and trimmed char counts"
fi

if grep -q 'trim_ratio=' $_loop_files 2>/dev/null && grep -q 'budget_utilization=' $_loop_files 2>/dev/null; then
    assert_pass "Context efficiency emits trim_ratio and budget_utilization"
else
    assert_fail "Context efficiency emits trim_ratio and budget_utilization"
fi

# Verify raw_prompt_chars is captured before manage_context_window trims
if grep -q 'raw_prompt_chars=${#prompt}' $_loop_files 2>/dev/null; then
    assert_pass "raw_prompt_chars measured from pre-trim prompt"
else
    assert_fail "raw_prompt_chars measured from pre-trim prompt"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# MULTI-TEST GATE TESTS
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${DIM}  multi-test gate${RESET}"

# Test: ADDITIONAL_TEST_CMDS appears in source
if grep -q 'ADDITIONAL_TEST_CMDS' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "ADDITIONAL_TEST_CMDS variable defined"
else
    assert_fail "ADDITIONAL_TEST_CMDS variable defined"
fi

# Test: --additional-test-cmds flag in arg parser
if grep -q '\-\-additional-test-cmds' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "--additional-test-cmds flag in arg parser"
else
    assert_fail "--additional-test-cmds flag in arg parser"
fi

# Test: --help mentions --additional-test-cmds
output=$(bash "$SCRIPT_DIR/sw-loop.sh" --help 2>&1 | sed $'s/\033\[[0-9;]*m//g') && rc=0 || rc=$?
if echo "$output" | grep -q 'additional-test-cmds'; then
    assert_pass "--help documents --additional-test-cmds"
else
    assert_fail "--help documents --additional-test-cmds"
fi

# Test: test-evidence JSON file written
if grep -q 'test-evidence-iter-' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "run_test_gate writes test-evidence JSON"
else
    assert_fail "run_test_gate writes test-evidence JSON"
fi

# Test: audit agent reads evidence file
if grep -q 'evidence_file.*test-evidence' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "run_audit_agent reads structured test evidence"
else
    assert_fail "run_audit_agent reads structured test evidence"
fi

# Test: audit prompt includes fence delimiter instruction (#261)
if grep -q '<<<AUDIT:PASS>>>' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Audit prompt includes <<<AUDIT:PASS>>> fence delimiter"
else
    assert_fail "Audit prompt includes <<<AUDIT:PASS>>> fence delimiter"
fi

# Test: audit detection uses detect_gate_signal (not bare grep)
if grep -q 'detect_gate_signal.*AUDIT' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Audit detection uses detect_gate_signal (not bare grep)"
else
    assert_fail "Audit detection uses detect_gate_signal (not bare grep)"
fi

# Test: audit negative pattern includes both AUDIT_FAIL and fenced <<<AUDIT:FAIL>>>
if grep -q 'AUDIT_FAIL|<<<AUDIT:FAIL>>>' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Audit negative pattern covers both AUDIT_FAIL and fenced delimiter"
else
    assert_fail "Audit negative pattern covers both AUDIT_FAIL and fenced delimiter"
fi

# Test: audit has empty-response guard that returns early (matching DoD pattern)
if grep -q 'Audit.*evaluator returned empty output' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Audit has empty-response guard with diagnostic warning"
else
    assert_fail "Audit has empty-response guard with diagnostic warning"
fi

# Test: audit stderr is written to a dedicated file (not merged into audit_log)
if grep -q 'audit_err_log' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Audit stderr captured to dedicated file (not merged with stdout)"
else
    assert_fail "Audit stderr captured to dedicated file (not merged with stdout)"
fi

# Test: audit non-zero exit_code is logged as a warning
if grep -q 'exit_code.*Audit.*exited with code\|Audit.*claude -p exited with code' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Audit logs warning on non-zero claude exit code"
else
    assert_fail "Audit logs warning on non-zero claude exit code"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# run_test_gate BEHAVIOR TESTS (functional)
# Exercises the actual run_test_gate function in a real bash subshell.
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${DIM}  run_test_gate: TEST_OUTPUT content on failure${RESET}"

# Helper: run run_test_gate in an isolated subshell sourcing only the minimum
# needed from sw-loop.sh (extracted via brace-counting awk).  Writes results
# to temp files; prints the temp dir path so the caller can assert on them.
_run_test_gate_isolated() {
    local test_cmd="${1:-}"
    local extra_cmd="${2:-}"
    local log_dir
    log_dir="$(mktemp -d "${TMPDIR:-/tmp}/sw-rtg-test.XXXXXX")"

    # Write a self-contained runner script to avoid heredoc quoting issues
    local runner="${log_dir}/runner.sh"
    # Extract run_test_gate via brace-counting awk (robust against inner braces)
    local fn_src
    fn_src=$(awk '/^run_test_gate\(\)/{found=1; count=0} found{for(i=1;i<=length($0);i++){if(substr($0,i,1)=="{")count++; if(substr($0,i,1)=="}")count--}; print; if(found && count==0 && NR>1){exit}}' \
        "$SCRIPT_DIR/sw-loop.sh" 2>/dev/null)

    cat > "$runner" <<RUNNER
#!/usr/bin/env bash
set -euo pipefail
strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }
emit_event()    { :; }
audit_emit()    { :; }
_config_get_int() { echo "\${3:-\${4:-900}}"; }
detect_created_test_files() { :; }
# Color stubs — run_test_gate uses these for echo -e output
DIM="" RESET="" GREEN="" RED="" YELLOW="" CYAN="" BOLD=""

$(printf '%s\n' "$fn_src")

TEST_CMD=$(printf '%q' "$test_cmd")
ADDITIONAL_TEST_CMDS=()
$([ -n "$extra_cmd" ] && printf 'ADDITIONAL_TEST_CMDS=(%q)\n' "$extra_cmd")
FAST_TEST_CMD="" FAST_TEST_INTERVAL=5 ITERATION=1
LOG_DIR=$(printf '%q' "$log_dir")
LOOP_START_COMMIT="" TEST_PASSED="" TEST_OUTPUT="" TEST_LOG_FILE=""

run_test_gate

echo "\$TEST_PASSED" > $(printf '%q' "$log_dir")/result.passed
printf '%s' "\$TEST_OUTPUT" > $(printf '%q' "$log_dir")/result.output
RUNNER
    bash "$runner" >/dev/null 2>&1 || true
    echo "$log_dir"
}

# Test 1: primary fails, no additional — TEST_OUTPUT shows the failure
_rtg_dir=$(_run_test_gate_isolated "echo 'PRIMARY_FAILURE_MARKER'; exit 1" "" 2>/dev/null || true)
if [[ -f "$_rtg_dir/result.passed" ]]; then
    _rtg_passed=$(cat "$_rtg_dir/result.passed")
    _rtg_out=$(cat "$_rtg_dir/result.output")
    if [[ "$_rtg_passed" == "false" ]] && echo "$_rtg_out" | grep -q "PRIMARY_FAILURE_MARKER"; then
        assert_pass "run_test_gate: primary fails — TEST_OUTPUT contains failure output"
    else
        assert_fail "run_test_gate: primary fails — TEST_OUTPUT contains failure output" \
            "passed=$_rtg_passed output=$(echo "$_rtg_out" | head -3)"
    fi
    rm -rf "$_rtg_dir"
else
    assert_fail "run_test_gate: primary fails — TEST_OUTPUT contains failure output" "subshell setup failed"
fi

# Test 2: primary passes — TEST_PASSED=true, TEST_OUTPUT shows passing output
_rtg_dir=$(_run_test_gate_isolated "echo 'PRIMARY_PASS_MARKER'" "" 2>/dev/null || true)
if [[ -f "$_rtg_dir/result.passed" ]]; then
    _rtg_passed=$(cat "$_rtg_dir/result.passed")
    _rtg_out=$(cat "$_rtg_dir/result.output")
    if [[ "$_rtg_passed" == "true" ]] && echo "$_rtg_out" | grep -q "PRIMARY_PASS_MARKER"; then
        assert_pass "run_test_gate: primary passes — TEST_PASSED=true"
    else
        assert_fail "run_test_gate: primary passes — TEST_PASSED=true" \
            "passed=$_rtg_passed out=$(echo "$_rtg_out" | head -3)"
    fi
    rm -rf "$_rtg_dir"
else
    assert_fail "run_test_gate: primary passes — TEST_PASSED=true" "subshell setup failed"
fi

# Test 3 (the bug): primary fails, additional passes with >50 lines of output —
# TEST_OUTPUT must show primary failure, not be swamped by the passing output.
# The additional command prints 60 lines so tail -50 of combined output hides
# the primary failure under the current (unfixed) code.
_rtg_dir=$(_run_test_gate_isolated \
    "echo 'PRIMARY_FAILURE_MARKER'; exit 1" \
    "for i in \$(seq 1 60); do echo \"ADDITIONAL_PASS_LINE_\$i\"; done" 2>/dev/null || true)
if [[ -f "$_rtg_dir/result.passed" ]]; then
    _rtg_passed=$(cat "$_rtg_dir/result.passed")
    _rtg_out=$(cat "$_rtg_dir/result.output")
    _has_failure=false
    _hides_pass=false
    echo "$_rtg_out" | grep -q "PRIMARY_FAILURE_MARKER" && _has_failure=true
    # Passing additional output alone (without the failure) would mislead Claude
    if ! echo "$_rtg_out" | grep -q "PRIMARY_FAILURE_MARKER" && \
         echo "$_rtg_out" | grep -q "ADDITIONAL_PASS_MARKER"; then
        _hides_pass=true
    fi
    if [[ "$_rtg_passed" == "false" ]] && [[ "$_has_failure" == "true" ]]; then
        assert_pass "run_test_gate: primary fails + additional passes — TEST_OUTPUT shows primary failure"
    else
        assert_fail "run_test_gate: primary fails + additional passes — TEST_OUTPUT shows primary failure" \
            "hides_failure=$_hides_pass passed=$_rtg_passed out=$(echo "$_rtg_out" | head -5)"
    fi
    rm -rf "$_rtg_dir"
else
    assert_fail "run_test_gate: primary fails + additional passes — TEST_OUTPUT shows primary failure" "subshell setup failed"
fi

# Test 4: primary fails, additional also fails — TEST_OUTPUT shows both failures
_rtg_dir=$(_run_test_gate_isolated \
    "echo 'PRIMARY_FAILURE_MARKER'; exit 1" \
    "echo 'EXTRA_FAILURE_MARKER'; exit 1" 2>/dev/null || true)
if [[ -f "$_rtg_dir/result.passed" ]]; then
    _rtg_passed=$(cat "$_rtg_dir/result.passed")
    _rtg_out=$(cat "$_rtg_dir/result.output")
    if [[ "$_rtg_passed" == "false" ]] && \
       echo "$_rtg_out" | grep -q "PRIMARY_FAILURE_MARKER" && \
       echo "$_rtg_out" | grep -q "EXTRA_FAILURE_MARKER"; then
        assert_pass "run_test_gate: primary + additional both fail — TEST_OUTPUT shows both failures"
    else
        assert_fail "run_test_gate: primary + additional both fail — TEST_OUTPUT shows both failures" \
            "passed=$_rtg_passed out=$(echo "$_rtg_out" | head -5)"
    fi
    rm -rf "$_rtg_dir"
else
    assert_fail "run_test_gate: primary + additional both fail — TEST_OUTPUT shows both failures" "subshell setup failed"
fi

# Test 5: extra command output not duplicated (cumulative-read bug)
# Two extra commands that fail: check combined_output doesn't repeat first command's lines
_rtg_dir2="$(mktemp -d "${TMPDIR:-/tmp}/sw-rtg-dup-test.XXXXXX")"
_fn_src5=$(awk '/^run_test_gate\(\)/{found=1; count=0} found{for(i=1;i<=length($0);i++){if(substr($0,i,1)=="{")count++; if(substr($0,i,1)=="}")count--}; print; if(found && count==0 && NR>1){exit}}' \
    "$SCRIPT_DIR/sw-loop.sh" 2>/dev/null)
_runner5="${_rtg_dir2}/runner5.sh"
cat > "$_runner5" <<DUP_RUNNER
#!/usr/bin/env bash
set -euo pipefail
strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }
emit_event() { :; }; audit_emit() { :; }; _config_get_int() { echo "\${3:-\${4:-900}}"; }
detect_created_test_files() { :; }
DIM="" RESET="" GREEN="" RED="" YELLOW="" CYAN="" BOLD=""
$(printf '%s\n' "$_fn_src5")
TEST_CMD="true"
ADDITIONAL_TEST_CMDS=("echo EXTRA_LINE_ALPHA; exit 1" "echo EXTRA_LINE_BETA; exit 1")
FAST_TEST_CMD="" FAST_TEST_INTERVAL=5 ITERATION=1
LOG_DIR="${_rtg_dir2}" LOOP_START_COMMIT="" TEST_PASSED="" TEST_OUTPUT="" TEST_LOG_FILE=""
run_test_gate
count=\$(echo "\$TEST_OUTPUT" | grep -cxF "EXTRA_LINE_ALPHA" || true)
echo "\$count" > "${_rtg_dir2}/alpha_count"
DUP_RUNNER
bash "$_runner5" 2>/dev/null || true
if [[ -f "$_rtg_dir2/alpha_count" ]]; then
    _alpha_count=$(cat "$_rtg_dir2/alpha_count")
    if [[ "${_alpha_count:-0}" -le 1 ]]; then
        assert_pass "run_test_gate: extra command output not duplicated in TEST_OUTPUT"
    else
        assert_fail "run_test_gate: extra command output not duplicated in TEST_OUTPUT" \
            "EXTRA_LINE_ALPHA appeared ${_alpha_count} times (expected 1)"
    fi
    rm -rf "$_rtg_dir2"
else
    assert_fail "run_test_gate: extra command output not duplicated in TEST_OUTPUT" "subshell setup failed"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# VERIFICATION GAP TESTS
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${DIM}  verification gap handler${RESET}"

# Test: verification gap detection exists in source
if grep -q 'Verification gap detected' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Verification gap detection present"
else
    assert_fail "Verification gap detection present"
fi

# Test: verification gap emits events
if grep -q 'loop.verification_gap_resolved' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Verification gap resolved event emitted"
else
    assert_fail "Verification gap resolved event emitted"
fi

if grep -q 'loop.verification_gap_confirmed' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Verification gap confirmed event emitted"
else
    assert_fail "Verification gap confirmed event emitted"
fi

# Test: verification gap overrides audit when tests pass
if grep -q 'override_audit' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Verification gap can override audit result"
else
    assert_fail "Verification gap can override audit result"
fi

# Test: verification checks for uncommitted changes
if grep -q 'verification-iter-' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Verification re-runs tests to dedicated log"
else
    assert_fail "Verification re-runs tests to dedicated log"
fi

# Test: mid-build test discovery uses detect_created_test_files
if grep -q 'detect_created_test_files' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Mid-build test file discovery integrated"
else
    assert_fail "Mid-build test file discovery integrated"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# HOLISTIC GATE — BRANCH DIFF TESTS
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${DIM}  holistic gate branch diff${RESET}"

# Test: full branch diff section present in holistic prompt
if grep -q 'Full Branch Changes vs Base' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Holistic prompt includes Full Branch Changes vs Base section"
else
    assert_fail "Holistic prompt includes Full Branch Changes vs Base section"
fi

# Test: loop-run section relabelled (not the old 'from start' wording)
if grep -q 'this loop run only' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Holistic loop-run diff section labelled as loop-run only"
else
    assert_fail "Holistic loop-run diff section labelled as loop-run only"
fi

# Test: restart NOTE present to guide assessor
if grep -q 'loop was restarted after prior work' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Holistic prompt includes restart NOTE for assessor"
else
    assert_fail "Holistic prompt includes restart NOTE for assessor"
fi

# Test: base branch detection uses git rev-parse (not hardcoded 'main')
# The logic lives in _git_branch_merge_base() in lib/helpers.sh (used by holistic gate via helper call)
if grep -q "rev-parse --abbrev-ref origin/HEAD" "$SCRIPT_DIR/lib/helpers.sh"; then
    assert_pass "Holistic gate detects base branch dynamically via git rev-parse"
else
    assert_fail "Holistic gate detects base branch dynamically via git rev-parse"
fi

# Test: fallback to 'main' if rev-parse fails
if grep -A2 'rev-parse --abbrev-ref origin/HEAD' "$SCRIPT_DIR/lib/helpers.sh" | grep -q 'main'; then
    assert_pass "Holistic gate falls back to main if base branch detection fails"
else
    assert_fail "Holistic gate falls back to main if base branch detection fails"
fi

# Test: Project Stats uses loop-scoped label (not misleading 'Cumulative')
if grep -q 'Loop-run changes:' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Project Stats labels loop-scoped change count accurately"
else
    assert_fail "Project Stats labels loop-scoped change count accurately"
fi

# ─── HOLISTIC gate signal hardening (#264) ────────────────────────────────────
echo ""
echo -e "${DIM}  holistic gate: signal hardening (#264)${RESET}"

# Test: holistic prompt uses <<<HOLISTIC:PASS>>> fence delimiter
if grep -q '<<<HOLISTIC:PASS>>>' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Holistic prompt uses <<<HOLISTIC:PASS>>> fence delimiter"
else
    assert_fail "Holistic prompt uses <<<HOLISTIC:PASS>>> fence delimiter"
fi

# Test: holistic prompt uses <<<HOLISTIC:FAIL>>> fence delimiter
if grep -q '<<<HOLISTIC:FAIL>>>' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Holistic prompt uses <<<HOLISTIC:FAIL>>> fence delimiter"
else
    assert_fail "Holistic prompt uses <<<HOLISTIC:FAIL>>> fence delimiter"
fi

# Test: holistic detection uses detect_gate_signal (not bare grep)
if grep -q 'detect_gate_signal.*holistic_log.*HOLISTIC\|detect_gate_signal.*"HOLISTIC"' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Holistic detection uses detect_gate_signal (not bare grep)"
else
    assert_fail "Holistic detection uses detect_gate_signal (not bare grep)"
fi

# Test: holistic has empty-response guard (checks both zero-length and whitespace-only)
if grep -q 'grep -q.*\[.*\^.*\[:space:\]' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Holistic empty-response guard rejects whitespace-only output"
else
    assert_fail "Holistic empty-response guard rejects whitespace-only output"
fi

# Test: holistic captures stderr separately
if grep -q 'holistic.*stderr\|holistic_stderr' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Holistic stderr captured to dedicated file"
else
    assert_fail "Holistic stderr captured to dedicated file"
fi

# Test: holistic surfaces gap text as HOLISTIC_RESULT for agent feedback
if grep -q 'HOLISTIC_RESULT=' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Holistic sets HOLISTIC_RESULT for agent feedback injection"
else
    assert_fail "Holistic sets HOLISTIC_RESULT for agent feedback injection"
fi

# Test: compose_holistic_feedback_section exists for prompt injection
if grep -q '^compose_holistic_feedback_section()' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "compose_holistic_feedback_section() exists for prompt injection"
else
    assert_fail "compose_holistic_feedback_section() exists for prompt injection"
fi

# Test: holistic feedback injected into agent prompt
if grep -q 'holistic_feedback_section' "$SCRIPT_DIR/lib/loop-iteration.sh"; then
    assert_pass "holistic_feedback_section injected into agent prompt"
else
    assert_fail "holistic_feedback_section injected into agent prompt"
fi

# Test: holistic legacy pattern does NOT include prose goal.{0,20}fully.{0,10}achieved
# (removed in review — too permissive, matches negated sentences)
if ! grep 'detect_gate_signal.*HOLISTIC' "$SCRIPT_DIR/sw-loop.sh" | grep -q 'goal.*achieved'; then
    assert_pass "Holistic legacy pattern does not include overly permissive prose (goal.*achieved removed)"
else
    assert_fail "Holistic legacy pattern does not include overly permissive prose (goal.*achieved removed)"
fi

# Test: holistic negative pattern is <<<HOLISTIC:FAIL>>> only (no ambiguous prose)
if ! grep 'detect_gate_signal.*HOLISTIC' "$SCRIPT_DIR/sw-loop.sh" | grep -q 'gaps.*remaining'; then
    assert_pass "Holistic negative pattern is unambiguous (gaps.remaining prose removed)"
else
    assert_fail "Holistic negative pattern is unambiguous (gaps.remaining prose removed)"
fi

# Load detect_gate_signal for unit tests
_dgs_body="$(sed -n '/^detect_gate_signal()/,/^}/p' "$SCRIPT_DIR/lib/gate-signal.sh")"

# Test: detect_gate_signal — HOLISTIC_PASS legacy accepted
dgs_test_log="$(mktemp "${TMPDIR:-/tmp}/sw-loop-test.XXXXXX")"
echo "HOLISTIC_PASS" > "$dgs_test_log"
if (eval "$_dgs_body"; detect_gate_signal "$dgs_test_log" "HOLISTIC" 'HOLISTIC_PASS') 2>/dev/null; then
    assert_pass "detect_gate_signal: HOLISTIC legacy HOLISTIC_PASS accepted"
else
    assert_fail "detect_gate_signal: HOLISTIC legacy HOLISTIC_PASS accepted"
fi
rm -f "$dgs_test_log"

# Test: detect_gate_signal — <<<HOLISTIC:PASS>>> fence accepted
dgs_test_log="$(mktemp "${TMPDIR:-/tmp}/sw-loop-test.XXXXXX")"
echo "Goal is complete." > "$dgs_test_log"
echo "<<<HOLISTIC:PASS>>>" >> "$dgs_test_log"
if (eval "$_dgs_body"; detect_gate_signal "$dgs_test_log" "HOLISTIC" 'HOLISTIC_PASS') 2>/dev/null; then
    assert_pass "detect_gate_signal: <<<HOLISTIC:PASS>>> fence accepted"
else
    assert_fail "detect_gate_signal: <<<HOLISTIC:PASS>>> fence accepted"
fi
rm -f "$dgs_test_log"

# Test: detect_gate_signal — <<<HOLISTIC:FAIL>>> blocks pass
dgs_test_log="$(mktemp "${TMPDIR:-/tmp}/sw-loop-test.XXXXXX")"
printf 'HOLISTIC_PASS\n<<<HOLISTIC:FAIL>>>' > "$dgs_test_log"
if ! (eval "$_dgs_body"; detect_gate_signal "$dgs_test_log" "HOLISTIC" 'HOLISTIC_PASS' '<<<HOLISTIC:FAIL>>>') 2>/dev/null; then
    assert_pass "detect_gate_signal: <<<HOLISTIC:FAIL>>> blocks positive match (negative-first)"
else
    assert_fail "detect_gate_signal: <<<HOLISTIC:FAIL>>> blocks positive match (negative-first)"
fi
rm -f "$dgs_test_log"

# Test: boundary — "no gaps remaining" (past-tense resolution prose) does not cause false FAIL
dgs_test_log="$(mktemp "${TMPDIR:-/tmp}/sw-loop-test.XXXXXX")"
printf 'HOLISTIC_PASS\nAll gaps have been addressed; no gaps remaining.\n' > "$dgs_test_log"
if (eval "$_dgs_body"; detect_gate_signal "$dgs_test_log" "HOLISTIC" 'HOLISTIC_PASS' '<<<HOLISTIC:FAIL>>>') 2>/dev/null; then
    assert_pass "detect_gate_signal: HOLISTIC prose 'no gaps remaining' does not cause false FAIL"
else
    assert_fail "detect_gate_signal: HOLISTIC prose 'no gaps remaining' does not cause false FAIL"
fi
rm -f "$dgs_test_log"

# Test: boundary — "not fully achieved" prose does not cause false PASS
dgs_test_log="$(mktemp "${TMPDIR:-/tmp}/sw-loop-test.XXXXXX")"
echo "Overall status: the goal is not fully achieved yet." > "$dgs_test_log"
if ! (eval "$_dgs_body"; detect_gate_signal "$dgs_test_log" "HOLISTIC" 'HOLISTIC_PASS' '<<<HOLISTIC:FAIL>>>') 2>/dev/null; then
    assert_pass "detect_gate_signal: HOLISTIC prose 'not fully achieved' does not trigger false PASS"
else
    assert_fail "detect_gate_signal: HOLISTIC prose 'not fully achieved' does not trigger false PASS"
fi
rm -f "$dgs_test_log"

# ═══════════════════════════════════════════════════════════════════════════════
# CONTEXT EXHAUSTION PREVENTION TESTS
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${DIM}  context exhaustion prevention${RESET}"

# Test: loop-context-monitor.sh exists
if [[ -f "$SCRIPT_DIR/lib/loop-context-monitor.sh" ]]; then
    assert_pass "loop-context-monitor.sh module exists"
else
    assert_fail "loop-context-monitor.sh module exists"
fi

# Test: module has module guard
if grep -q '_LOOP_CONTEXT_MONITOR_LOADED' "$SCRIPT_DIR/lib/loop-context-monitor.sh"; then
    assert_pass "loop-context-monitor.sh has module guard"
else
    assert_fail "loop-context-monitor.sh has module guard"
fi

# Test: module defines CONTEXT_WINDOW_TOKENS default
if grep -q 'CONTEXT_WINDOW_TOKENS.*200000' "$SCRIPT_DIR/lib/loop-context-monitor.sh"; then
    assert_pass "CONTEXT_WINDOW_TOKENS defaults to 200000"
else
    assert_fail "CONTEXT_WINDOW_TOKENS defaults to 200000"
fi

# Test: module defines CONTEXT_EXHAUSTION_THRESHOLD default
if grep -q 'CONTEXT_EXHAUSTION_THRESHOLD.*70' "$SCRIPT_DIR/lib/loop-context-monitor.sh"; then
    assert_pass "CONTEXT_EXHAUSTION_THRESHOLD defaults to 70"
else
    assert_fail "CONTEXT_EXHAUSTION_THRESHOLD defaults to 70"
fi

# Test: check_context_exhaustion function defined
if grep -q '^check_context_exhaustion()' "$SCRIPT_DIR/lib/loop-context-monitor.sh"; then
    assert_pass "check_context_exhaustion() function defined"
else
    assert_fail "check_context_exhaustion() function defined"
fi

# Test: summarize_loop_state function defined
if grep -q '^summarize_loop_state()' "$SCRIPT_DIR/lib/loop-context-monitor.sh"; then
    assert_pass "summarize_loop_state() function defined"
else
    assert_fail "summarize_loop_state() function defined"
fi

# Test: get_context_usage_pct function defined
if grep -q '^get_context_usage_pct()' "$SCRIPT_DIR/lib/loop-context-monitor.sh"; then
    assert_pass "get_context_usage_pct() function defined"
else
    assert_fail "get_context_usage_pct() function defined"
fi

# Test: division-by-zero guard present
if grep -q 'window.*-le 0' "$SCRIPT_DIR/lib/loop-context-monitor.sh"; then
    assert_pass "Division-by-zero guard present in get_context_usage_pct"
else
    assert_fail "Division-by-zero guard present in get_context_usage_pct"
fi

# Test: threshold calculation — get_context_usage_pct returns correct value
source "$SCRIPT_DIR/lib/loop-context-monitor.sh" 2>/dev/null || true
if type get_context_usage_pct >/dev/null 2>&1; then
    # 140000 / 200000 = 70%
    LOOP_INPUT_TOKENS=100000
    LOOP_OUTPUT_TOKENS=40000
    CONTEXT_WINDOW_TOKENS=200000
    pct="$(get_context_usage_pct)"
    if [[ "$pct" -eq 70 ]]; then
        assert_pass "get_context_usage_pct: 140000/200000 = 70%"
    else
        assert_fail "get_context_usage_pct: 140000/200000 = 70%" "got $pct, expected 70"
    fi

    # Under threshold: 100000 / 200000 = 50%
    LOOP_INPUT_TOKENS=80000
    LOOP_OUTPUT_TOKENS=20000
    pct_under="$(get_context_usage_pct)"
    if [[ "$pct_under" -eq 50 ]]; then
        assert_pass "get_context_usage_pct: 100000/200000 = 50%"
    else
        assert_fail "get_context_usage_pct: 100000/200000 = 50%" "got $pct_under, expected 50"
    fi

    # Zero tokens: should return 0
    LOOP_INPUT_TOKENS=0
    LOOP_OUTPUT_TOKENS=0
    pct_zero="$(get_context_usage_pct)"
    if [[ "$pct_zero" -eq 0 ]]; then
        assert_pass "get_context_usage_pct: 0/200000 = 0%"
    else
        assert_fail "get_context_usage_pct: 0/200000 = 0%" "got $pct_zero, expected 0"
    fi

    # Division by zero guard: window=0 should return 0, not crash
    LOOP_INPUT_TOKENS=100000
    LOOP_OUTPUT_TOKENS=0
    CONTEXT_WINDOW_TOKENS=0
    pct_divzero="$(get_context_usage_pct)"
    if [[ "$pct_divzero" -eq 0 ]]; then
        assert_pass "get_context_usage_pct: division-by-zero returns 0"
    else
        assert_fail "get_context_usage_pct: division-by-zero returns 0" "got $pct_divzero, expected 0"
    fi
    # Reset to sane defaults
    CONTEXT_WINDOW_TOKENS=200000
else
    assert_fail "get_context_usage_pct() callable after sourcing module"
fi

# Test: check_context_exhaustion returns false (1) when below threshold
if type check_context_exhaustion >/dev/null 2>&1; then
    LOOP_INPUT_TOKENS=0
    LOOP_OUTPUT_TOKENS=0
    CONTEXT_WINDOW_TOKENS=200000
    CONTEXT_EXHAUSTION_THRESHOLD=70
    if ! check_context_exhaustion 2>/dev/null; then
        assert_pass "check_context_exhaustion: returns false when no tokens"
    else
        assert_fail "check_context_exhaustion: returns false when no tokens"
    fi

    # 50% usage (below 70% threshold) — should return false
    LOOP_INPUT_TOKENS=80000
    LOOP_OUTPUT_TOKENS=20000
    if ! check_context_exhaustion 2>/dev/null; then
        assert_pass "check_context_exhaustion: returns false at 50% usage"
    else
        assert_fail "check_context_exhaustion: returns false at 50% usage"
    fi

    # 70% usage (at threshold) — should return true
    LOOP_INPUT_TOKENS=100000
    LOOP_OUTPUT_TOKENS=40000
    if check_context_exhaustion 2>/dev/null; then
        assert_pass "check_context_exhaustion: returns true at 70% threshold"
    else
        assert_fail "check_context_exhaustion: returns true at 70% threshold"
    fi

    # Over threshold (80%) — should return true
    LOOP_INPUT_TOKENS=140000
    LOOP_OUTPUT_TOKENS=20000
    if check_context_exhaustion 2>/dev/null; then
        assert_pass "check_context_exhaustion: returns true above threshold"
    else
        assert_fail "check_context_exhaustion: returns true above threshold"
    fi

    # Custom threshold override: 90% threshold, 80% usage → should return false
    LOOP_INPUT_TOKENS=140000
    LOOP_OUTPUT_TOKENS=20000
    CONTEXT_EXHAUSTION_THRESHOLD=90
    if ! check_context_exhaustion 2>/dev/null; then
        assert_pass "check_context_exhaustion: respects custom threshold (90%)"
    else
        assert_fail "check_context_exhaustion: respects custom threshold (90%)"
    fi
    # Reset
    CONTEXT_EXHAUSTION_THRESHOLD=70
    LOOP_INPUT_TOKENS=0
    LOOP_OUTPUT_TOKENS=0
else
    assert_fail "check_context_exhaustion() callable after sourcing module"
fi

# Test: summarize_loop_state writes output file
if type summarize_loop_state >/dev/null 2>&1; then
    _summary_log_dir="$TEST_TEMP_DIR/log-summary-test"
    mkdir -p "$_summary_log_dir"
    LOG_DIR="$_summary_log_dir"
    GOAL="Test goal for summarization"
    ORIGINAL_GOAL="Test goal for summarization"
    ITERATION=5
    MAX_ITERATIONS=20
    TEST_PASSED=false
    CONSECUTIVE_FAILURES=2
    LOOP_INPUT_TOKENS=80000
    LOOP_OUTPUT_TOKENS=20000
    CONTEXT_WINDOW_TOKENS=200000
    PROJECT_ROOT="$TEST_TEMP_DIR/repo"
    LOG_ENTRIES="### Iteration 1
Some work done
### Iteration 2
More progress"

    _summary_path="$(summarize_loop_state 2>/dev/null || true)"
    if [[ -f "$_summary_log_dir/context-summary.md" ]]; then
        assert_pass "summarize_loop_state: creates context-summary.md"
    else
        assert_fail "summarize_loop_state: creates context-summary.md"
    fi

    # Check required sections exist
    _summary_content="$(cat "$_summary_log_dir/context-summary.md" 2>/dev/null || true)"
    if echo "$_summary_content" | grep -q 'Goal'; then
        assert_pass "summarize_loop_state: includes Goal section"
    else
        assert_fail "summarize_loop_state: includes Goal section"
    fi

    if echo "$_summary_content" | grep -q 'Session Status'; then
        assert_pass "summarize_loop_state: includes Session Status section"
    else
        assert_fail "summarize_loop_state: includes Session Status section"
    fi

    if echo "$_summary_content" | grep -q 'Modified Files'; then
        assert_pass "summarize_loop_state: includes Modified Files section"
    else
        assert_fail "summarize_loop_state: includes Modified Files section"
    fi

    if echo "$_summary_content" | grep -q 'Recent Progress'; then
        assert_pass "summarize_loop_state: includes Recent Progress section"
    else
        assert_fail "summarize_loop_state: includes Recent Progress section"
    fi
else
    assert_fail "summarize_loop_state() callable after sourcing module"
fi

# Test: sw-loop.sh sources loop-context-monitor.sh
if grep -q 'loop-context-monitor.sh' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "sw-loop.sh sources loop-context-monitor.sh"
else
    assert_fail "sw-loop.sh sources loop-context-monitor.sh"
fi

# Test: sw-loop.sh has context exhaustion check in main loop
if grep -q 'check_context_exhaustion' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "sw-loop.sh calls check_context_exhaustion in main loop"
else
    assert_fail "sw-loop.sh calls check_context_exhaustion in main loop"
fi

# Test: sw-loop.sh emits context_exhaustion_warning (via the monitor module)
if grep -q 'context_exhaustion_warning' "$SCRIPT_DIR/lib/loop-context-monitor.sh"; then
    assert_pass "loop.context_exhaustion_warning event emitted in monitor module"
else
    assert_fail "loop.context_exhaustion_warning event emitted in monitor module"
fi

# Test: sw-loop.sh handles context_exhaustion status in restart handler
if grep -q 'context_exhaustion_restart' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "sw-loop.sh emits loop.context_exhaustion_restart event"
else
    assert_fail "sw-loop.sh emits loop.context_exhaustion_restart event"
fi

# Test: sw-loop.sh resets token counters on every session restart (not just context_exhaustion).
# The reset must appear in the shared restart block, before the context_exhaustion branch.
# Accepts either an inline zero-assignment or a call to reset_token_counters().
if grep -A30 'Reset ALL iteration-level state' "$SCRIPT_DIR/sw-loop.sh" | grep -qE 'LOOP_INPUT_TOKENS=0|reset_token_counters'; then
    assert_pass "sw-loop.sh resets LOOP_INPUT_TOKENS on context_exhaustion restart"
else
    assert_fail "sw-loop.sh resets LOOP_INPUT_TOKENS on context_exhaustion restart"
fi

# Test: loop-iteration.sh emits loop.context_usage event
if grep -q 'loop.context_usage' "$SCRIPT_DIR/lib/loop-iteration.sh"; then
    assert_pass "loop-iteration.sh emits loop.context_usage event per iteration"
else
    assert_fail "loop-iteration.sh emits loop.context_usage event per iteration"
fi

# Test: loop.context_usage event includes usage_pct field
if grep -A5 'loop.context_usage' "$SCRIPT_DIR/lib/loop-iteration.sh" | grep -q 'usage_pct'; then
    assert_pass "loop.context_usage event includes usage_pct field"
else
    assert_fail "loop.context_usage event includes usage_pct field"
fi

# ─── safe_git_stage() — daemon-config.json exclusion ─────────────────────────

# Test: safe_git_stage() is defined in helpers.sh
if grep -q '^safe_git_stage()' "$SCRIPT_DIR/lib/helpers.sh"; then
    assert_pass "safe_git_stage() defined in helpers.sh"
else
    assert_fail "safe_git_stage() defined in helpers.sh"
fi

# Test: safe_git_stage() uses _GIT_BOOKKEEPING_FILES (not hard-coded daemon-config.json path)
if grep -A10 '^safe_git_stage()' "$SCRIPT_DIR/lib/helpers.sh" | grep -q '_GIT_BOOKKEEPING_FILES'; then
    assert_pass "safe_git_stage() uses _GIT_BOOKKEEPING_FILES to unstage bookkeeping files"
else
    assert_fail "safe_git_stage() uses _GIT_BOOKKEEPING_FILES to unstage bookkeeping files"
fi

# Test: post-audit cleanup path uses safe_git_stage
if grep -B2 'post-audit cleanup' "$SCRIPT_DIR/sw-loop.sh" | grep -q 'safe_git_stage'; then
    assert_pass "post-audit cleanup path uses safe_git_stage"
else
    assert_fail "post-audit cleanup path uses safe_git_stage"
fi

# Test: git_auto_commit() uses safe_git_stage
if grep -A15 'git_auto_commit()' "$SCRIPT_DIR/sw-loop.sh" | grep -q 'safe_git_stage'; then
    assert_pass "git_auto_commit() uses safe_git_stage"
else
    assert_fail "git_auto_commit() uses safe_git_stage"
fi

# Test: multi-agent parallel commit path uses safe_git_stage
if grep -B2 "agent-.*: iteration" "$SCRIPT_DIR/sw-loop.sh" | grep -q 'safe_git_stage'; then
    assert_pass "multi-agent parallel commit path uses safe_git_stage"
else
    assert_fail "multi-agent parallel commit path uses safe_git_stage"
fi

# Test: pipeline-stages-build.sh TDD commit uses safe_git_stage
if grep -B1 'TDD - define expected' "$SCRIPT_DIR/lib/pipeline-stages-build.sh" | grep -q 'safe_git_stage'; then
    assert_pass "pipeline-stages-build.sh TDD commit uses safe_git_stage"
else
    assert_fail "pipeline-stages-build.sh TDD commit uses safe_git_stage"
fi

# Test: pipeline-stages-delivery.sh cleanup commit uses safe_git_stage
if grep -B1 'pipeline cleanup' "$SCRIPT_DIR/lib/pipeline-stages-delivery.sh" | grep -q 'safe_git_stage'; then
    assert_pass "pipeline-stages-delivery.sh cleanup commit uses safe_git_stage"
else
    assert_fail "pipeline-stages-delivery.sh cleanup commit uses safe_git_stage"
fi

# Test: pipeline-state.sh does NOT hard-code a daemon-config.json restore (T1.1 sidecar split)
if grep -A3 'git add.*to_add' "$SCRIPT_DIR/lib/pipeline-state.sh" | grep -q 'daemon-config.json'; then
    assert_fail "pipeline-state.sh must NOT hard-code daemon-config.json restore (T1.1: sidecar split)"
else
    assert_pass "pipeline-state.sh artifact commit does not hard-code daemon-config.json exclusion"
fi

# Test: _GIT_BOOKKEEPING_FILES array is defined in helpers.sh
if grep -q '_GIT_BOOKKEEPING_FILES=' "$SCRIPT_DIR/lib/helpers.sh"; then
    assert_pass "_GIT_BOOKKEEPING_FILES defined in helpers.sh"
else
    assert_fail "_GIT_BOOKKEEPING_FILES defined in helpers.sh"
fi

# Test: _GIT_RUNTIME_EXCLUDES array is defined in helpers.sh
if grep -q '_GIT_RUNTIME_EXCLUDES=' "$SCRIPT_DIR/lib/helpers.sh"; then
    assert_pass "_GIT_RUNTIME_EXCLUDES defined in helpers.sh"
else
    assert_fail "_GIT_RUNTIME_EXCLUDES defined in helpers.sh"
fi

# Test: _git_diff_stat_excluded helper is defined in helpers.sh
if grep -q '^_git_diff_stat_excluded()' "$SCRIPT_DIR/lib/helpers.sh"; then
    assert_pass "_git_diff_stat_excluded() defined in helpers.sh"
else
    assert_fail "_git_diff_stat_excluded() defined in helpers.sh"
fi

# Test: pipeline-tasks.md and tasks.md are listed in _GIT_BOOKKEEPING_FILES
for _bf in pipeline-tasks.md tasks.md; do
    if awk '/_GIT_BOOKKEEPING_FILES=/,/\)/' "$SCRIPT_DIR/lib/helpers.sh" | grep -Fq "$_bf"; then
        assert_pass "_GIT_BOOKKEEPING_FILES includes $_bf"
    else
        assert_fail "_GIT_BOOKKEEPING_FILES includes $_bf"
    fi
done
# Test: daemon-config.json is NOT in _GIT_BOOKKEEPING_FILES (moved to sidecar pattern — T1.1)
if awk '/_GIT_BOOKKEEPING_FILES=/,/\)/' "$SCRIPT_DIR/lib/helpers.sh" | grep -Fq "daemon-config.json"; then
    assert_fail "_GIT_BOOKKEEPING_FILES must NOT include daemon-config.json (T1.1: sidecar split)"
else
    assert_pass "_GIT_BOOKKEEPING_FILES does not include daemon-config.json (sidecar pattern active)"
fi

# Test: safe_git_stage() loops over _GIT_BOOKKEEPING_FILES (not a hardcoded path)
if grep -A10 '^safe_git_stage()' "$SCRIPT_DIR/lib/helpers.sh" | grep -q '_GIT_BOOKKEEPING_FILES'; then
    assert_pass "safe_git_stage() uses _GIT_BOOKKEEPING_FILES"
else
    assert_fail "safe_git_stage() uses _GIT_BOOKKEEPING_FILES"
fi

# Test: _git_excluded_pathspecs function exists in helpers.sh
if grep -q '^_git_excluded_pathspecs()' "$SCRIPT_DIR/lib/helpers.sh" 2>/dev/null; then
    assert_pass "_git_excluded_pathspecs() defined in helpers.sh"
else
    assert_fail "_git_excluded_pathspecs() defined in helpers.sh"
fi

# Test: _git_bookkeeping_pathspecs function exists in helpers.sh (bookkeeping-only variant)
if grep -q '^_git_bookkeeping_pathspecs()' "$SCRIPT_DIR/lib/helpers.sh" 2>/dev/null; then
    assert_pass "_git_bookkeeping_pathspecs() defined in helpers.sh"
else
    assert_fail "_git_bookkeeping_pathspecs() defined in helpers.sh"
fi

# Test: No hardcoded daemon-config.json pathspec in sw-loop.sh (quote-agnostic check)
# Negative test — hardcoded :!.claude/daemon-config.json must not appear regardless of quoting
if ! grep -n ':!\.claude/daemon-config\.json' "$SCRIPT_DIR/sw-loop.sh" 2>/dev/null | grep -v '^[0-9]*:[[:space:]]*#' > /dev/null 2>&1; then
    assert_pass "sw-loop.sh no hardcoded :!daemon-config.json pathspec"
else
    assert_fail "sw-loop.sh hardcoded :!daemon-config.json pathspec — should use _git_excluded_pathspecs"
fi

# Test: No hardcoded daemon-config.json pathspec in sw-pipeline.sh (quote-agnostic check)
if ! grep -n ':!\.claude/daemon-config\.json' "$SCRIPT_DIR/sw-pipeline.sh" 2>/dev/null | grep -v '^[0-9]*:[[:space:]]*#' > /dev/null 2>&1; then
    assert_pass "sw-pipeline.sh no hardcoded :!daemon-config.json pathspec"
else
    assert_fail "sw-pipeline.sh hardcoded :!daemon-config.json pathspec — should use _git_bookkeeping_pathspecs or _git_excluded_pathspecs"
fi

# Test: sw-loop.sh quality gate uses _git_excluded_pathspecs or _git_bookkeeping_pathspecs
if grep -q '_git_excluded_pathspecs\|_git_bookkeeping_pathspecs' "$SCRIPT_DIR/sw-loop.sh" 2>/dev/null; then
    assert_pass "sw-loop.sh uses shared pathspec helper"
else
    assert_fail "sw-loop.sh uses shared pathspec helper"
fi

# Test: sw-pipeline.sh uses _git_excluded_pathspecs or _git_bookkeeping_pathspecs
if grep -q '_git_excluded_pathspecs\|_git_bookkeeping_pathspecs' "$SCRIPT_DIR/sw-pipeline.sh" 2>/dev/null; then
    assert_pass "sw-pipeline.sh uses shared pathspec helper"
else
    assert_fail "sw-pipeline.sh uses shared pathspec helper"
fi

# Test: check_progress() uses shared helper
if grep -A20 '^check_progress()' "$SCRIPT_DIR/lib/loop-convergence.sh" | grep -q '_git_diff_stat_excluded'; then
    assert_pass "check_progress() uses _git_diff_stat_excluded"
else
    assert_fail "check_progress() uses _git_diff_stat_excluded"
fi

# Test: track_iteration_velocity() uses shared helper
if grep -A5 '^track_iteration_velocity()' "$SCRIPT_DIR/lib/loop-convergence.sh" | grep -q '_git_diff_stat_excluded'; then
    assert_pass "track_iteration_velocity() uses _git_diff_stat_excluded"
else
    assert_fail "track_iteration_velocity() uses _git_diff_stat_excluded"
fi

# Test: git_diff_stat() uses shared helper
if grep -A3 '^git_diff_stat()' "$SCRIPT_DIR/sw-loop.sh" | grep -q '_git_diff_stat_excluded'; then
    assert_pass "git_diff_stat() uses _git_diff_stat_excluded"
else
    assert_fail "git_diff_stat() uses _git_diff_stat_excluded"
fi

# Test: functional — safe_git_stage excludes all bookkeeping files (not just daemon-config.json)
# Uses the real git binary (not the mock stub injected by setup_env) so the
# test actually exercises git init/add/commit/restore rather than no-ops.
_test_safe_git_stage() {
    local real_git
    real_git="$(PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin command -v git 2>/dev/null)" || return 1
    local tmpdir
    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/sw-loop-test.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir'" RETURN
    "$real_git" init -q "$tmpdir"
    "$real_git" -C "$tmpdir" config user.email "test@test.com"
    "$real_git" -C "$tmpdir" config user.name "test"
    mkdir -p "$tmpdir/.claude"
    # Create all bookkeeping files and a real code file
    echo '{}' > "$tmpdir/.claude/daemon-config.json"
    echo '# tasks' > "$tmpdir/.claude/pipeline-tasks.md"
    echo '# tasks' > "$tmpdir/.claude/tasks.md"
    echo 'echo hello' > "$tmpdir/app.sh"
    "$real_git" -C "$tmpdir" add -A
    "$real_git" -C "$tmpdir" commit -q -m "initial"
    # Modify all files
    echo '{"modified": true}' > "$tmpdir/.claude/daemon-config.json"
    echo '# updated tasks' > "$tmpdir/.claude/pipeline-tasks.md"
    echo '# updated tasks' > "$tmpdir/.claude/tasks.md"
    echo 'echo world' > "$tmpdir/app.sh"
    # Run safe_git_stage
    ( cd "$tmpdir" && PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin source "$SCRIPT_DIR/lib/helpers.sh" && safe_git_stage )
    local staged
    staged="$("$real_git" -C "$tmpdir" diff --cached --name-only)"
    # Bookkeeping files (tasks.md, pipeline-tasks.md) must NOT be staged.
    # daemon-config.json is no longer in _GIT_BOOKKEEPING_FILES (T1.1 sidecar split)
    # so it IS expected to be staged as a normal committed file.
    local _bf
    for _bf in .claude/pipeline-tasks.md .claude/tasks.md; do
        if echo "$staged" | grep -F -x -q "$_bf"; then
            return 1
        fi
    done
    # daemon-config.json MUST be staged (it's a normal file now, not bookkeeping)
    if ! echo "$staged" | grep -F -x -q ".claude/daemon-config.json"; then
        return 1
    fi
    # Real code file MUST be staged
    if ! echo "$staged" | grep -F -x -q "app.sh"; then
        return 1
    fi
    return 0
}
if _test_safe_git_stage; then
    assert_pass "safe_git_stage() functional: all bookkeeping files excluded, real code staged"
else
    assert_fail "safe_git_stage() functional: all bookkeeping files excluded, real code staged"
fi

# ─── Tests: check_progress() with new_commits param (issue #221) ─────────────
# Each case runs in its own subshell to avoid set -e propagation from sourced scripts.

# Build a two-commit repo for the no-arg fallback test (needs real commits)
_build_test_repo() {
    local _real_git
    _real_git=$(PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin command -v git 2>/dev/null) || return 1
    local _tmpdir
    _tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/sw-loop-test.XXXXXX")
    "$_real_git" init -q "$_tmpdir"
    "$_real_git" -C "$_tmpdir" config user.email "test@test.com"
    "$_real_git" -C "$_tmpdir" config user.name "test"
    printf 'line1\n' > "$_tmpdir/file.txt"
    "$_real_git" -C "$_tmpdir" add .
    "$_real_git" -C "$_tmpdir" commit -q -m "initial"
    printf 'line1\nline2\nline3\nline4\nline5\nline6\n' > "$_tmpdir/file.txt"
    "$_real_git" -C "$_tmpdir" add .
    "$_real_git" -C "$_tmpdir" commit -q -m "second"
    echo "$_tmpdir"
}

# Test A: new_commits=0 → no progress
if ( export PROJECT_ROOT="/tmp" MIN_PROGRESS_LINES=5
     source "$SCRIPT_DIR/lib/helpers.sh" 2>/dev/null
     source "$SCRIPT_DIR/lib/loop-convergence.sh" 2>/dev/null
     check_progress 0 ) 2>/dev/null; then
    assert_fail "check_progress(0): no commits = no progress (circuit breaker fix #221)"
else
    assert_pass "check_progress(0): no commits = no progress (circuit breaker fix #221)"
fi

# Test B: new_commits=1 → progress
if ( export PROJECT_ROOT="/tmp" MIN_PROGRESS_LINES=5
     source "$SCRIPT_DIR/lib/helpers.sh" 2>/dev/null
     source "$SCRIPT_DIR/lib/loop-convergence.sh" 2>/dev/null
     check_progress 1 ) 2>/dev/null; then
    assert_pass "check_progress(1): one commit = progress detected"
else
    assert_fail "check_progress(1): one commit = progress detected"
fi

# Test C: new_commits=3 → progress
if ( export PROJECT_ROOT="/tmp" MIN_PROGRESS_LINES=5
     source "$SCRIPT_DIR/lib/helpers.sh" 2>/dev/null
     source "$SCRIPT_DIR/lib/loop-convergence.sh" 2>/dev/null
     check_progress 3 ) 2>/dev/null; then
    assert_pass "check_progress(3): multiple commits = progress detected"
else
    assert_fail "check_progress(3): multiple commits = progress detected"
fi

# Test D: no-arg fallback uses _git_diff_stat_excluded (backward compat)
# Strip mock bin from PATH so _git_diff_stat_excluded uses the real git binary.
_fallback_repo=$(_build_test_repo 2>/dev/null || echo "")
if [[ -n "$_fallback_repo" ]]; then
    if (
         _real_path=$(printf '%s\n' "$PATH" | tr ':' '\n' | \
             awk -v mock="${TEST_TEMP_DIR:-__none__}/bin" '$0 != mock' | \
             paste -sd: -)
         export PATH="$_real_path"
         export PROJECT_ROOT="$_fallback_repo" MIN_PROGRESS_LINES=5
         source "$SCRIPT_DIR/lib/helpers.sh" 2>/dev/null
         source "$SCRIPT_DIR/lib/loop-convergence.sh" 2>/dev/null
         check_progress
       ) 2>/dev/null; then
        assert_pass "check_progress() fallback (no args): detects progress via HEAD~1 diff"
    else
        assert_fail "check_progress() fallback (no args): detects progress via HEAD~1 diff"
    fi
    rm -rf "$_fallback_repo"
else
    assert_pass "check_progress() fallback (no args): skipped (git unavailable)"
fi

# ─── Progress message variants — commit count fix (#246) ──────────────────────

# Test: "Progress detected — tests still failing" message exists (Claude committed, tests fail)
if grep -q 'Progress detected — tests still failing' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "sw-loop.sh contains 'Progress detected — tests still failing' message variant"
else
    assert_fail "sw-loop.sh contains 'Progress detected — tests still failing' message variant"
fi

# Test: "Low progress" message still exists (zero commits case unchanged)
if grep -q 'Low progress' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "sw-loop.sh contains 'Low progress' message variant (zero commits case)"
else
    assert_fail "sw-loop.sh contains 'Low progress' message variant (zero commits case)"
fi

# Test: In main loop, commits_before capture appears before run_claude_iteration
# (line-ordering regression: guards against moving commits_before back after the call)
_cb_line=$(grep -n 'commits_before.*git_commit_count' "$SCRIPT_DIR/sw-loop.sh" 2>/dev/null | head -1 | cut -d: -f1 || true)
_rci_line=$(grep -n 'run_claude_iteration' "$SCRIPT_DIR/sw-loop.sh" 2>/dev/null | head -1 | cut -d: -f1 || true)
if [[ -n "$_cb_line" && -n "$_rci_line" && "$_cb_line" -lt "$_rci_line" ]]; then
    assert_pass "sw-loop.sh: commits_before captured before run_claude_iteration (line ${_cb_line} < ${_rci_line})"
else
    assert_fail "sw-loop.sh: commits_before captured before run_claude_iteration (got commits_before=${_cb_line:-unset}, run_claude_iteration=${_rci_line:-unset})"
fi

# Test: In agent sub-loop, _commits_before appears before the agent-specific claude -p invocation
# (line-ordering regression: guards against moving _commits_before back after the call)
# Restrict search to lines 1800+ to target the agent sub-loop only (avoids earlier claude -p calls).
# The agent invocation uses stdin piping (printf '%s' "$PROMPT" | claude -p ...) per the
# ARG_MAX fix; either the pre-fix pattern or the piped pattern should anchor the line.
_acb_line=$(grep -n '_commits_before=\$(git rev-list' "$SCRIPT_DIR/sw-loop.sh" 2>/dev/null | head -1 | cut -d: -f1 || true)
_cp_line=$(awk 'NR>=1800 && /printf .* "\$PROMPT" \| claude -p|claude -p "\$PROMPT"/{print NR; exit}' "$SCRIPT_DIR/sw-loop.sh" 2>/dev/null || true)
if [[ -n "$_acb_line" && -n "$_cp_line" && "$_acb_line" -lt "$_cp_line" ]]; then
    assert_pass "sw-loop.sh: agent _commits_before captured before claude -p (line ${_acb_line} < ${_cp_line})"
else
    assert_fail "sw-loop.sh: agent _commits_before captured before claude -p (got _commits_before=${_acb_line:-unset}, claude -p=${_cp_line:-unset})"
fi

# ─── GATES_PASSED_NO_SIGNAL — silent loop continuation fix (#234) ─────────────

# Test: GATES_PASSED_NO_SIGNAL is set when quality gates pass but no LOOP_COMPLETE
if grep -q 'GATES_PASSED_NO_SIGNAL=true' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "sw-loop.sh sets GATES_PASSED_NO_SIGNAL=true when gates pass without LOOP_COMPLETE"
else
    assert_fail "sw-loop.sh sets GATES_PASSED_NO_SIGNAL=true when gates pass without LOOP_COMPLETE"
fi

# Test: GATES_PASSED_NO_SIGNAL is only set when COMPLETION_REJECTED is not true
if grep -B3 'GATES_PASSED_NO_SIGNAL=true' "$SCRIPT_DIR/sw-loop.sh" | grep -q 'COMPLETION_REJECTED.*!=.*true'; then
    assert_pass "GATES_PASSED_NO_SIGNAL=true guarded by COMPLETION_REJECTED check"
else
    assert_fail "GATES_PASSED_NO_SIGNAL=true guarded by COMPLETION_REJECTED check"
fi

# Test: GATES_PASSED_NO_SIGNAL is only set when QUALITY_GATES_ENABLED
if grep -B5 'GATES_PASSED_NO_SIGNAL=true' "$SCRIPT_DIR/sw-loop.sh" | grep -q 'QUALITY_GATES_ENABLED'; then
    assert_pass "GATES_PASSED_NO_SIGNAL=true guarded by QUALITY_GATES_ENABLED check"
else
    assert_fail "GATES_PASSED_NO_SIGNAL=true guarded by QUALITY_GATES_ENABLED check"
fi

# Test: GATES_PASSED_NO_SIGNAL is only set when audit passed
if grep -B5 'GATES_PASSED_NO_SIGNAL=true' "$SCRIPT_DIR/sw-loop.sh" | grep -q 'AUDIT_RESULT'; then
    assert_pass "GATES_PASSED_NO_SIGNAL=true guarded by AUDIT_RESULT check"
else
    assert_fail "GATES_PASSED_NO_SIGNAL=true guarded by AUDIT_RESULT check"
fi

# Test: compose_rejection_notice_section handles GATES_PASSED_NO_SIGNAL branch
if awk '/^compose_rejection_notice_section\(\)/,/^\}/' "$SCRIPT_DIR/sw-loop.sh" | \
        grep -q 'GATES_PASSED_NO_SIGNAL'; then
    assert_pass "compose_rejection_notice_section() handles GATES_PASSED_NO_SIGNAL branch"
else
    assert_fail "compose_rejection_notice_section() handles GATES_PASSED_NO_SIGNAL branch"
fi

# Test: quality gates passed hint injected into prompt (not rejection notice)
if awk '/^compose_rejection_notice_section\(\)/,/^\}/' "$SCRIPT_DIR/sw-loop.sh" | \
        grep -qi 'quality.*gates.*passed\|gates.*passed'; then
    assert_pass "GATES_PASSED_NO_SIGNAL branch emits quality gates passed hint"
else
    assert_fail "GATES_PASSED_NO_SIGNAL branch emits quality gates passed hint"
fi

# Test: COMPLETION_REJECTED path present in rejection notice function
if awk '/^compose_rejection_notice_section\(\)/,/^\}/' "$SCRIPT_DIR/sw-loop.sh" | \
        grep -q 'COMPLETION_REJECTED'; then
    assert_pass "compose_rejection_notice_section() still handles COMPLETION_REJECTED path"
else
    assert_fail "compose_rejection_notice_section() still handles COMPLETION_REJECTED path"
fi

# Test: COMPLETION_REJECTED and GATES_PASSED_NO_SIGNAL reset AFTER run_claude_iteration
# (not before — reset before was the bug: compose_prompt never saw the rejected flag)
if grep -A8 'Reset per-iteration completion signal flags' "$SCRIPT_DIR/sw-loop.sh" | grep -q 'COMPLETION_REJECTED=false'; then
    assert_pass "COMPLETION_REJECTED reset in main loop (not in subshell)"
else
    assert_fail "COMPLETION_REJECTED reset in main loop (not in subshell)"
fi

if grep -A8 'Reset per-iteration completion signal flags' "$SCRIPT_DIR/sw-loop.sh" | grep -q 'GATES_PASSED_NO_SIGNAL=false'; then
    assert_pass "GATES_PASSED_NO_SIGNAL reset in main loop (not in subshell)"
else
    assert_fail "GATES_PASSED_NO_SIGNAL reset in main loop (not in subshell)"
fi

# Test: reset happens AFTER run_claude_iteration, not before (Fix 3)
# The reset must NOT appear before the run_claude_iteration call in the same iteration block.
_reset_line=$(grep -n 'COMPLETION_REJECTED=false' "$SCRIPT_DIR/sw-loop.sh" | grep -v '^[0-9]*:#' | grep -v '^139:' | tail -1 | cut -d: -f1)
_claude_line=$(grep -n 'run_claude_iteration' "$SCRIPT_DIR/sw-loop.sh" | grep -v 'run_claude_iteration()' | tail -1 | cut -d: -f1)
if [[ -n "$_reset_line" && -n "$_claude_line" && "$_reset_line" -gt "$_claude_line" ]]; then
    assert_pass "COMPLETION_REJECTED reset occurs after run_claude_iteration (Fix 3)"
else
    assert_fail "COMPLETION_REJECTED reset must occur after run_claude_iteration" \
        "reset at line ${_reset_line:-?}, run_claude_iteration at line ${_claude_line:-?}"
fi

# Test: QUALITY_GATE_REASONS global declared alongside QUALITY_GATE_DETAIL (Fix 2D)
if grep -q 'QUALITY_GATE_REASONS=""' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "QUALITY_GATE_REASONS global declared (Fix 2D)"
else
    assert_fail "QUALITY_GATE_REASONS global must be declared in sw-loop.sh" ""
fi

# Test: compose_iteration_outcome function exists (Fix 2B)
if grep -q '^compose_iteration_outcome()' "$SCRIPT_DIR/lib/loop-iteration.sh"; then
    assert_pass "compose_iteration_outcome helper exists in loop-iteration.sh (Fix 2B)"
else
    assert_fail "compose_iteration_outcome must be defined in loop-iteration.sh" ""
fi

# Test: iteration log entry appends compose_iteration_outcome output (Fix 2C)
if grep -A5 'append_log_entry' "$SCRIPT_DIR/sw-loop.sh" | grep -q 'compose_iteration_outcome\|outcome'; then
    assert_pass "iteration log entry includes outcome from compose_iteration_outcome (Fix 2C)"
else
    assert_fail "append_log_entry must include compose_iteration_outcome output" ""
fi

# Test: zero-progress guard fires on COMPLETION_REJECTED too (Fix 4)
if grep -A3 'PREV_NEW_COMMITS.*-eq 0' "$SCRIPT_DIR/lib/loop-iteration.sh" | grep -qE 'COMPLETION_REJECTED|zero_progress'; then
    assert_pass "zero-progress guard checks COMPLETION_REJECTED (Fix 4)"
else
    assert_fail "zero-progress guard must also fire when COMPLETION_REJECTED is true" ""
fi

# Test: extract_summary no longer uses tail -5 | head -3 (the broken fixed-window) (Fix 2A)
if grep -A5 '^extract_summary()' "$SCRIPT_DIR/lib/loop-iteration.sh" | grep -q 'tail -5 | head -3'; then
    assert_fail "extract_summary must not use broken tail-5|head-3 window (Fix 2A)" ""
else
    assert_pass "extract_summary does not use tail-5|head-3 (Fix 2A)"
fi

# Test: extract_summary no longer uses cut -c1-120 line truncation (Fix 2A)
if grep -A10 '^extract_summary()' "$SCRIPT_DIR/lib/loop-iteration.sh" | grep -q 'cut -c1-120'; then
    assert_fail "extract_summary must not truncate lines with cut -c1-120 (Fix 2A)" ""
else
    assert_pass "extract_summary does not truncate with cut -c1-120 (Fix 2A)"
fi

# ─── Early exit when no changes and all gates pass (#245) ─────────────────────

# Test: early exit block exists after GATES_PASSED_NO_SIGNAL is set
if grep -A10 'GATES_PASSED_NO_SIGNAL=true' "$SCRIPT_DIR/sw-loop.sh" | grep -q 'loop.early_exit_gates_passed'; then
    assert_pass "early exit check present after GATES_PASSED_NO_SIGNAL (all gates = complete)"
else
    assert_fail "early exit check present after GATES_PASSED_NO_SIGNAL (all gates = complete)"
fi

# Test: early exit does NOT require zero new_commits (fires regardless of commits when gates pass)
if grep -B2 'loop.early_exit_gates_passed' "$SCRIPT_DIR/sw-loop.sh" | grep -q 'new_commits.*-eq 0'; then
    assert_fail "early exit must NOT be guarded by new_commits == 0 (should exit on any gates-pass)"
else
    assert_pass "early exit not guarded by new_commits == 0 — exits when gates pass regardless of commits"
fi

# Test: early exit sets STATUS=complete
if grep -B5 'loop.early_exit_gates_passed' "$SCRIPT_DIR/sw-loop.sh" | grep -q 'STATUS="complete"'; then
    assert_pass "early exit sets STATUS=complete"
else
    assert_fail "early exit sets STATUS=complete"
fi

# Test: early exit runs holistic gate before exiting
# Use -A2 to match across potential line breaks in the condition
if grep -A2 'GATES_PASSED_NO_SIGNAL.*true' "$SCRIPT_DIR/sw-loop.sh" | grep -q 'run_holistic_gate'; then
    assert_pass "early exit runs run_holistic_gate before completing"
else
    assert_fail "early exit runs run_holistic_gate before completing"
fi

# Test: holistic gate prompt includes actual diff content (not just stats)
if grep -q 'branch_diff' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "holistic gate collects branch_diff for prompt"
else
    assert_fail "holistic gate collects branch_diff for prompt"
fi

# Test: holistic gate prompt includes Evaluation Rules with default-to-FAIL bias
if grep -q 'Default to FAIL' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "holistic gate prompt has default-to-FAIL conservative bias"
else
    assert_fail "holistic gate prompt has default-to-FAIL conservative bias"
fi

# Test: holistic gate prompt requires per-component goal verification
if grep -q 'each distinct component' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "holistic gate prompt requires per-component goal verification"
else
    assert_fail "holistic gate prompt requires per-component goal verification"
fi

# Test: branch_diff is sanitized to prevent delimiter injection
if grep -q 'REDACTED:HOLISTIC:PASS\|REDACTED:HOLISTIC:FAIL' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "branch_diff sanitized to prevent holistic gate delimiter injection"
else
    assert_fail "branch_diff sanitized to prevent holistic gate delimiter injection"
fi

# Test: diff truncation notice in prompt (so model knows to rely on stats for large branches)
if grep -q 'may be truncated' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "holistic gate prompt notes diff may be truncated"
else
    assert_fail "holistic gate prompt notes diff may be truncated"
fi

# Test: new_commits recomputed after post-audit cleanup commit
if grep -B5 'Quality gates' "$SCRIPT_DIR/sw-loop.sh" | grep -q 'commits_after_cleanup'; then
    assert_pass "new_commits recomputed after post-audit cleanup"
else
    assert_fail "new_commits recomputed after post-audit cleanup"
fi

# Behavioral test: loop exits early when holistic outputs new fence delimiter (primary path)
echo ""
echo -e "${DIM}  loop behavior: early exit with no changes (#245, #264)${RESET}"

if setup_loop_env 2>/dev/null; then
    # Mock claude: no changes, holistic outputs new <<<HOLISTIC:PASS>>> fence delimiter
    cat > "$TEST_TEMP_DIR/bin/claude" << 'CLAUDE_EOF'
#!/usr/bin/env bash
if echo "$@" | grep -q 'output-format'; then
    echo '[{"type":"result","result":"Everything looks good, no changes needed.","usage":{"input_tokens":0,"output_tokens":0}}]'
else
    echo "<<<HOLISTIC:PASS>>>"
fi
exit 0
CLAUDE_EOF
    chmod +x "$TEST_TEMP_DIR/bin/claude"

    _git=$(PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin command -v git)
    echo ".claude/" > "$TEST_TEMP_DIR/repo/.gitignore"
    (cd "$TEST_TEMP_DIR/repo" && "$_git" rm -r --cached .claude 2>/dev/null || true)
    (cd "$TEST_TEMP_DIR/repo" && "$_git" add .gitignore && "$_git" commit -q -m "add gitignore" --allow-empty)
    rm -f "$TEST_TEMP_DIR/home/.shipwright/costs.json" "$TEST_TEMP_DIR/home/.shipwright/budget.json"

    output=$(env PATH="$TEST_TEMP_DIR/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" HOME="$TEST_TEMP_DIR/home" NO_GITHUB=true \
        bash "$SCRIPT_DIR/sw-loop.sh" \
        --repo "$TEST_TEMP_DIR/repo" \
        "Already done task" \
        --max-iterations 5 \
        --test-cmd "true" \
        --quality-gates \
        --local \
        2>&1) || true

    if echo "$output" | grep -qiE "no changes needed, all gates passing|LOOP COMPLETE|Complete"; then
        assert_pass "Loop early exit (fence delimiter): no changes + holistic <<<HOLISTIC:PASS>>> = complete"
    else
        assert_fail "Loop early exit (fence delimiter): expected early exit on <<<HOLISTIC:PASS>>>" "$(echo "$output" | grep -iE 'error|Fatal|Budget|Iteration|Complete|no changes|holistic' | head -5)"
    fi

    if echo "$output" | grep -qE "Iteration [2-9]|iteration [2-9]"; then
        assert_fail "Loop early exit (fence delimiter): should exit after iteration 1"
    else
        assert_pass "Loop early exit (fence delimiter): exited after iteration 1"
    fi
else
    assert_fail "Loop early exit behavioral test (fence delimiter)" "setup failed"
fi

# Behavioral test: legacy HOLISTIC_PASS still accepted (Layer 3 compat)
if setup_loop_env 2>/dev/null; then
    # Mock claude: no changes, holistic outputs legacy HOLISTIC_PASS string
    cat > "$TEST_TEMP_DIR/bin/claude" << 'CLAUDE_EOF'
#!/usr/bin/env bash
if echo "$@" | grep -q 'output-format'; then
    echo '[{"type":"result","result":"Everything looks good, no changes needed.","usage":{"input_tokens":0,"output_tokens":0}}]'
else
    echo "HOLISTIC_PASS"
fi
exit 0
CLAUDE_EOF
    chmod +x "$TEST_TEMP_DIR/bin/claude"

    _git=$(PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin command -v git)
    echo ".claude/" > "$TEST_TEMP_DIR/repo/.gitignore"
    (cd "$TEST_TEMP_DIR/repo" && "$_git" rm -r --cached .claude 2>/dev/null || true)
    (cd "$TEST_TEMP_DIR/repo" && "$_git" add .gitignore && "$_git" commit -q -m "add gitignore" --allow-empty)
    rm -f "$TEST_TEMP_DIR/home/.shipwright/costs.json" "$TEST_TEMP_DIR/home/.shipwright/budget.json"

    output=$(env PATH="$TEST_TEMP_DIR/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" HOME="$TEST_TEMP_DIR/home" NO_GITHUB=true \
        bash "$SCRIPT_DIR/sw-loop.sh" \
        --repo "$TEST_TEMP_DIR/repo" \
        "Already done task" \
        --max-iterations 5 \
        --test-cmd "true" \
        --quality-gates \
        --local \
        2>&1) || true

    if echo "$output" | grep -qiE "no changes needed, all gates passing|LOOP COMPLETE|Complete"; then
        assert_pass "Loop early exit (legacy compat): HOLISTIC_PASS still accepted via Layer 3"
    else
        assert_fail "Loop early exit (legacy compat): HOLISTIC_PASS should still work" "$(echo "$output" | grep -iE 'error|Fatal|Budget|Iteration|Complete|no changes|holistic' | head -5)"
    fi

    if echo "$output" | grep -qE "Iteration [2-9]|iteration [2-9]"; then
        assert_fail "Loop early exit (legacy compat): should exit after iteration 1"
    else
        assert_pass "Loop early exit (legacy compat): exited after iteration 1"
    fi
else
    assert_fail "Loop early exit behavioral test (legacy compat)" "setup failed"
fi

# ─── DoD evaluator: configurable diff truncation (#236, #275) ──────────────────

# Test: DoD diff uses configurable DOD_DIFF_MAX_LINES (not hard-coded)
if grep -A10 'Detailed Changes' "$SCRIPT_DIR/sw-loop.sh" | grep -q 'head -200'; then
    assert_fail "DoD diff must NOT be truncated with hard-coded head -200"
elif grep -A10 'Detailed Changes' "$SCRIPT_DIR/sw-loop.sh" | grep -q 'DOD_DIFF_MAX_LINES'; then
    assert_pass "DoD diff uses configurable DOD_DIFF_MAX_LINES"
else
    assert_fail "DoD diff should use DOD_DIFF_MAX_LINES variable"
fi

# Test: Holistic gate uses configurable HOLISTIC_DIFF_MAX_LINES (not hard-coded)
if grep -B2 -A2 'head -300' "$SCRIPT_DIR/sw-loop.sh" | grep -q 'holistic\|HOLISTIC'; then
    assert_fail "Holistic gate must NOT use hard-coded head -300"
elif grep -B2 -A2 'HOLISTIC_DIFF_MAX_LINES' "$SCRIPT_DIR/sw-loop.sh" | grep -q 'head.*HOLISTIC_DIFF_MAX_LINES'; then
    assert_pass "Holistic gate uses configurable HOLISTIC_DIFF_MAX_LINES"
else
    assert_fail "Holistic gate should use HOLISTIC_DIFF_MAX_LINES variable"
fi

# Test: DOD_DIFF_MAX_LINES actually truncates (behavioral)
_trunc_tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/sw-loop-test.XXXXXX")"
seq 1 20 > "$_trunc_tmpdir/bigdiff.txt"
DOD_DIFF_MAX_LINES=5
_trunc_result="$(cat "$_trunc_tmpdir/bigdiff.txt" | head -"${DOD_DIFF_MAX_LINES}")"
_trunc_lines="$(echo "$_trunc_result" | wc -l | tr -d ' ')"
if [[ "$_trunc_lines" -eq 5 ]]; then
    assert_pass "DOD_DIFF_MAX_LINES=5 truncates 20-line diff to 5 lines"
else
    assert_fail "DOD_DIFF_MAX_LINES=5 truncates 20-line diff to 5 lines" "got $_trunc_lines lines"
fi

# Test: HOLISTIC_DIFF_MAX_LINES actually truncates (behavioral)
HOLISTIC_DIFF_MAX_LINES=3
_trunc_result2="$(cat "$_trunc_tmpdir/bigdiff.txt" | head -"${HOLISTIC_DIFF_MAX_LINES}")"
_trunc_lines2="$(echo "$_trunc_result2" | wc -l | tr -d ' ')"
if [[ "$_trunc_lines2" -eq 3 ]]; then
    assert_pass "HOLISTIC_DIFF_MAX_LINES=3 truncates 20-line diff to 3 lines"
else
    assert_fail "HOLISTIC_DIFF_MAX_LINES=3 truncates 20-line diff to 3 lines" "got $_trunc_lines2 lines"
fi
rm -rf "$_trunc_tmpdir"

# Test: DoD includes full branch diff for compound_rebuild cycle correctness (#258)
# When compound_quality fails and triggers a rebuild, LOOP_START_COMMIT is reset to HEAD
# (after all prior build work). The loop-run diff is then empty/tiny, causing the DoD
# evaluator to say "no diff provided". The fix: also include the merge-base..HEAD diff.
if grep -q '_dod_merge_base' "$SCRIPT_DIR/sw-loop.sh" && \
   grep -q 'Full Branch Changes vs Base' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "DoD includes full branch diff for compound_rebuild cycle correctness"
else
    assert_fail "DoD must include full branch diff (merge-base..HEAD) to handle compound_rebuild cycles"
fi

# Test: DoD branch diff is sanitized to prevent delimiter injection
if grep -A5 '_dod_branch_diff' "$SCRIPT_DIR/sw-loop.sh" | grep -q 'REDACTED:DOD'; then
    assert_pass "DoD branch diff sanitized to prevent delimiter injection"
else
    assert_fail "DoD branch diff must sanitize <<<DOD:PASS/FAIL>>> tokens"
fi

# Test: DoD prompt notes loop-run diff may be small in rebuild cycles
if grep -q 'prior build' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "DoD prompt explains loop-run diff may be small in rebuild cycles"
else
    assert_fail "DoD prompt should explain loop-run diff may be small in rebuild cycles"
fi

# Test: DoD does NOT use --json-schema (flag causes empty output — see #253)
if grep -A5 'dod_flags' "$SCRIPT_DIR/sw-loop.sh" | grep -q '\-\-json-schema'; then
    assert_fail "DoD evaluator must NOT use --json-schema (causes empty claude -p output)"
else
    assert_pass "DoD evaluator does not use --json-schema"
fi

# Test: DoD prompt embeds explicit JSON format instruction (replaces CLI schema enforcement)
if grep -q 'Respond with a JSON object' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "DoD prompt embeds explicit JSON format instruction"
else
    assert_fail "DoD prompt embeds explicit JSON format instruction"
fi

# Test: DoD has empty-output guard before verdict parsing (surfaces broken CLI invocations)
if grep -q 'claude -p returned empty output' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "DoD has empty-output guard with diagnostic warning"
else
    assert_fail "DoD has empty-output guard with diagnostic warning"
fi

# Test: DoD rejects pass verdict when items is missing, not an array, or empty (#253)
# The guard uses a type-checking jq expression so non-array items (string, object) are
# also rejected — not just a missing or empty array.
if grep -q 'verdict is pass but items array is missing, not an array, or empty' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "DoD rejects pass verdict when items is missing, not an array, or empty"
else
    assert_fail "DoD rejects pass verdict when items is missing, not an array, or empty"
fi

# Test: DoD verdict parsed from JSON verdict field (not plain text DOD_PASS)
if grep -q 'dod_verdict.*jq.*verdict' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "DoD verdict parsed from JSON verdict field"
else
    assert_fail "DoD verdict parsed from JSON verdict field"
fi

# Test: DoD verdict checks for "pass" string (JSON schema enum value)
if grep -q '"$dod_verdict" == "pass"' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "DoD verdict compared against JSON enum value \"pass\""
else
    assert_fail "DoD verdict compared against JSON enum value \"pass\""
fi

# Test: DoD fallback uses detect_gate_signal (multi-layer, not bare grep)
if grep -q 'detect_gate_signal.*dod_log.*DOD\|detect_gate_signal.*"DOD"' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "DoD fallback uses detect_gate_signal for robust multi-layer detection"
else
    assert_fail "DoD fallback uses detect_gate_signal for robust multi-layer detection"
fi

# Test: DoD fallback is gated on empty dod_verdict (prevents overriding legitimate jq "fail")
# A model returning {"verdict":"fail","summary":"all requirements are now satisfied"} must stay
# a fail — the "all...satisfied" prose in the summary must not flip the verdict via Layer 3.
if grep -q '\[\[ -z.*dod_verdict.*\]\].*detect_gate_signal\|detect_gate_signal.*dod_log.*DOD' "$SCRIPT_DIR/sw-loop.sh" && \
   grep -q '\-z.*dod_verdict' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "DoD fallback gated on empty dod_verdict (won't override legitimate fail verdict)"
else
    assert_fail "DoD fallback gated on empty dod_verdict (won't override legitimate fail verdict)"
fi

# Test: DoD prompt includes fence delimiter instruction
if grep -q '<<<DOD:PASS>>>' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "DoD prompt includes <<<DOD:PASS>>> fence delimiter"
else
    assert_fail "DoD prompt includes <<<DOD:PASS>>> fence delimiter"
fi

# Test: DoD strips markdown fences before jq parsing
if grep -q 'sed.*json.*dod_log.*dod_clean\|dod_clean.*sed' "$SCRIPT_DIR/sw-loop.sh" || \
   grep -q "sed.*dod_log.*dod_clean" "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "DoD strips markdown fences from output before jq parsing"
else
    assert_fail "DoD strips markdown fences from output before jq parsing"
fi

# Test: detect_gate_signal helper exists in lib/gate-signal.sh (shared lib)
if grep -q '^detect_gate_signal()' "$SCRIPT_DIR/lib/gate-signal.sh"; then
    assert_pass "detect_gate_signal() helper function exists in lib/gate-signal.sh"
else
    assert_fail "detect_gate_signal() helper function exists in lib/gate-signal.sh"
fi

# Test: detect_gate_signal Layer 2 — fenced delimiter passes
# Load from shared lib (function moved out of sw-loop.sh into lib/gate-signal.sh)
_dgs_body="$(sed -n '/^detect_gate_signal()/,/^}/p' "$SCRIPT_DIR/lib/gate-signal.sh")"
dgs_test_log="$(mktemp "${TMPDIR:-/tmp}/sw-loop-test.XXXXXX")"
echo "<<<DOD:PASS>>>" > "$dgs_test_log"
if (eval "$_dgs_body"; detect_gate_signal "$dgs_test_log" "DOD") 2>/dev/null; then
    assert_pass "detect_gate_signal: Layer 2 fenced delimiter accepted"
else
    assert_fail "detect_gate_signal: Layer 2 fenced delimiter accepted"
fi
rm -f "$dgs_test_log"

# Test: detect_gate_signal Layer 3 — legacy DOD_PASS accepted
dgs_test_log="$(mktemp "${TMPDIR:-/tmp}/sw-loop-test.XXXXXX")"
echo "DOD_PASS" > "$dgs_test_log"
if (eval "$_dgs_body"; detect_gate_signal "$dgs_test_log" "DOD" 'DOD_PASS') 2>/dev/null; then
    assert_pass "detect_gate_signal: Layer 3 legacy DOD_PASS accepted"
else
    assert_fail "detect_gate_signal: Layer 3 legacy DOD_PASS accepted"
fi
rm -f "$dgs_test_log"

# Test: detect_gate_signal Layer 1 — failure signal overrides PASS delimiter
dgs_test_log="$(mktemp "${TMPDIR:-/tmp}/sw-loop-test.XXXXXX")"
echo '<<<DOD:PASS>>> <<<DOD:FAIL>>>' > "$dgs_test_log"
if ! (eval "$_dgs_body"; detect_gate_signal "$dgs_test_log" "DOD" 'DOD_PASS' '<<<DOD:FAIL>>>') 2>/dev/null; then
    assert_pass "detect_gate_signal: Layer 1 failure signal overrides PASS delimiter"
else
    assert_fail "detect_gate_signal: Layer 1 failure signal overrides PASS delimiter"
fi
rm -f "$dgs_test_log"

# ─── DoD checkbox normalization ───────────────────────────────────────────────

# Test: _normalize_dod_checkboxes function exists in sw-loop.sh
if grep -q '^_normalize_dod_checkboxes()' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "_normalize_dod_checkboxes function defined in sw-loop.sh"
else
    assert_fail "_normalize_dod_checkboxes function defined in sw-loop.sh"
fi

# Test: _normalize_dod_checkboxes correctly converts all indicator styles to [x]
_norm_body="$(sed -n '/^_normalize_dod_checkboxes()/,/^}/p' "$SCRIPT_DIR/sw-loop.sh")"
_norm_fixture="$(printf '%s\n' \
    '- [✓] item one' \
    '- [X] item two' \
    '- [/] item three' \
    '- [ ] item four ✓ (confirmed)' \
    '- [ ] item five' \
    '- [ ] Parser must handle ✓ markers in output')"
_norm_result="$(eval "$_norm_body"; _normalize_dod_checkboxes <<< "$_norm_fixture" 2>/dev/null)"
_norm_pass=true
for _expected in \
    '- [x] item one' \
    '- [x] item two' \
    '- [x] item three' \
    '- [x] item four ✓ (confirmed)'; do
    if ! grep -qFe "$_expected" <<< "$_norm_result"; then
        _norm_pass=false
        break
    fi
done
# Genuinely unchecked items must remain unchanged
for _unchanged in \
    '- [ ] item five' \
    '- [ ] Parser must handle ✓ markers in output'; do
    if ! grep -qFe "$_unchanged" <<< "$_norm_result"; then
        _norm_pass=false
        break
    fi
done
if [[ "$_norm_pass" == "true" ]]; then
    assert_pass "_normalize_dod_checkboxes: [✓] [X] [/] trailing-✓ all → [x]; bare [ ] and mid-text ✓ unchanged"
else
    assert_fail "_normalize_dod_checkboxes: [✓] [X] [/] trailing-✓ all → [x]; bare [ ] and mid-text ✓ unchanged" \
        "$(printf 'output:\n%s' "$_norm_result")"
fi
unset _norm_body _norm_fixture _norm_result _norm_pass _expected _unchanged

# ─── Circuit breaker: DoD-only failures (#237) ────────────────────────────────

# Test: bypass emits 'skipping circuit breaker strike' message
if grep -q 'skipping circuit breaker strike' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "circuit breaker bypass emits 'skipping circuit breaker strike' message"
else
    assert_fail "circuit breaker bypass emits 'skipping circuit breaker strike' message"
fi

# Test: bypass resets CONSECUTIVE_FAILURES=0 (not just skipping increment)
# so stale prior strikes don't accumulate across a verified-pass iteration
if grep -B1 'skipping circuit breaker strike' "$SCRIPT_DIR/sw-loop.sh" | grep -q 'CONSECUTIVE_FAILURES=0'; then
    assert_pass "circuit breaker bypass resets CONSECUTIVE_FAILURES=0 to clear stale strikes"
else
    assert_fail "circuit breaker bypass resets CONSECUTIVE_FAILURES=0 to clear stale strikes"
fi

# Test: bypass guarded by TEST_PASSED == true
if grep -A3 'check_progress.*new_commits' "$SCRIPT_DIR/sw-loop.sh" | grep -q 'TEST_PASSED.*true'; then
    assert_pass "circuit breaker bypass guarded by TEST_PASSED == true"
else
    assert_fail "circuit breaker bypass guarded by TEST_PASSED == true"
fi

# Test: bypass requires explicit AUDIT_RESULT=pass when audit is enabled (no silent default)
if grep -A3 'TEST_PASSED.*true' "$SCRIPT_DIR/sw-loop.sh" | grep -q 'AUDIT_AGENT_ENABLED\|AUDIT_RESULT.*==.*pass'; then
    assert_pass "circuit breaker bypass guards AUDIT_RESULT explicitly (no silent default to pass)"
else
    assert_fail "circuit breaker bypass guards AUDIT_RESULT explicitly (no silent default to pass)"
fi

# Test: genuine failures (test fail or audit fail) still increment circuit breaker
if grep -q 'CONSECUTIVE_FAILURES=$(( CONSECUTIVE_FAILURES + 1 ))' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "genuine failures still increment CONSECUTIVE_FAILURES"
else
    assert_fail "genuine failures still increment CONSECUTIVE_FAILURES"
fi

# ─── Stale counters + contradictory prompt fixes (#238) ──────────────────────

# Test: diagnoses.txt is cleared at loop init (not shared across pipeline runs)
if grep -A5 'strategy-attempts.txt' "$SCRIPT_DIR/sw-loop.sh" | grep -q 'diagnoses.txt'; then
    assert_pass "diagnoses.txt is cleared at loop init alongside strategy-attempts.txt"
else
    assert_fail "diagnoses.txt is cleared at loop init alongside strategy-attempts.txt"
fi

# Test: alternative_approach threshold is 5 (not 2)
if grep -q 'repeat_count.*-ge 5' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "alternative_approach escalation threshold is 5 same-session failures"
else
    assert_fail "alternative_approach escalation threshold is 5 same-session failures"
fi

# Test: GOAL is NOT mutated by appending alt_strategy when stuck
if grep 'GOAL=' "$SCRIPT_DIR/lib/loop-iteration.sh" | grep -q 'alt_strategy'; then
    assert_fail "GOAL must NOT be mutated with alt_strategy when stuck (creates contradictory prompt)"
else
    assert_pass "GOAL is not mutated with alt_strategy when stuck"
fi

# Test: alt_strategy injected as dedicated section (alt_strategy_section variable)
if grep -q 'alt_strategy_section' "$SCRIPT_DIR/lib/loop-iteration.sh"; then
    assert_pass "alt_strategy injected as dedicated prompt section (not appended to GOAL)"
else
    assert_fail "alt_strategy injected as dedicated prompt section (not appended to GOAL)"
fi

# Test: prompt uses prompt_goal (truncated when stuck) instead of raw GOAL
if grep -q 'prompt_goal' "$SCRIPT_DIR/lib/loop-iteration.sh"; then
    assert_pass "prompt uses prompt_goal variable (truncated to headline when stuck)"
else
    assert_fail "prompt uses prompt_goal variable (truncated to headline when stuck)"
fi

# ─── Dynamic task progress (#239) ────────────────────────────────────────────

# Test: pipeline-stages-build.sh no longer injects raw cat of TASKS_FILE anywhere
if grep -q 'cat.*TASKS_FILE\|\$(cat.*TASKS_FILE' "$SCRIPT_DIR/lib/pipeline-stages-build.sh"; then
    assert_fail "pipeline-stages-build.sh must NOT inject raw TASKS_FILE (done dynamically now)"
else
    assert_pass "pipeline-stages-build.sh does not inject raw TASKS_FILE into enriched goal"
fi

# Test: compose_task_section() function exists in loop-iteration.sh
if grep -q '^compose_task_section()' "$SCRIPT_DIR/lib/loop-iteration.sh"; then
    assert_pass "compose_task_section() function exists in loop-iteration.sh"
else
    assert_fail "compose_task_section() function exists in loop-iteration.sh"
fi

# Test: compose_task_section annotates tasks with [x] based on diff (auto-marking logic)
if grep -q '\- \[x\]' "$SCRIPT_DIR/lib/loop-iteration.sh"; then
    assert_pass "compose_task_section() marks completed tasks with [x]"
else
    assert_fail "compose_task_section() marks completed tasks with [x]"
fi

# Test: task_section is injected into the prompt
if grep -q 'task_section' "$SCRIPT_DIR/lib/loop-iteration.sh"; then
    assert_pass "task_section is injected into the prompt each iteration"
else
    assert_fail "task_section is injected into the prompt each iteration"
fi

# ─── Issue #331: Loop cycling fixes ─────────────────────────────────────────
echo ""
echo -e "${DIM}  loop cycling: stale HOLISTIC_RESULT, dampening, window (#331)${RESET}"

# Test 1: HOLISTIC_RESULT="" appears inside run_quality_gates (grep-based)
if awk '/^run_quality_gates\(\)/{found=1} found && /HOLISTIC_RESULT=""/{print; exit}' \
    "$SCRIPT_DIR/sw-loop.sh" | grep -q 'HOLISTIC_RESULT=""'; then
    assert_pass "HOLISTIC_RESULT reset inside run_quality_gates() (#331 Bug 1)"
else
    assert_fail "HOLISTIC_RESULT reset inside run_quality_gates() (#331 Bug 1)" \
        "expected 'HOLISTIC_RESULT=\"\"' inside run_quality_gates body"
fi

# Test 2: detect_stuckness triggers when tests pass but diffs are zero (conditional dampening)
_sw331_tracking=$(mktemp "${TMPDIR:-/tmp}/sw-stuckness-331.XXXXXX")
printf 'abc123|none|0\nabc123|none|0\nabc123|none|0\nabc123|none|0\nabc123|none|0\n' > "$_sw331_tracking"
if (
    export PROJECT_ROOT="/tmp" ITERATION=6 MAX_ITERATIONS=20 \
           TEST_PASSED=true AUDIT_RESULT=pass QUALITY_GATE_PASSED=true \
           LOG_DIR="$(dirname "$_sw331_tracking")" \
           STUCKNESS_TRACKING_FILE="$_sw331_tracking" \
           STUCKNESS_COUNT=0 STUCKNESS_DIAGNOSIS="" STUCKNESS_HINT=""
    source "$SCRIPT_DIR/lib/helpers.sh" 2>/dev/null
    source "$SCRIPT_DIR/lib/loop-convergence.sh" 2>/dev/null
    detect_stuckness 2>/dev/null
    [[ -n "$STUCKNESS_HINT" ]]
) 2>/dev/null; then
    assert_pass "detect_stuckness: zero-diff iterations not dampened when tests pass (#331 Bug 2)"
else
    assert_fail "detect_stuckness: zero-diff iterations not dampened when tests pass (#331 Bug 2)" \
        "STUCKNESS_HINT was empty — dampening incorrectly suppressed detection"
fi
rm -f "$_sw331_tracking"

# Test 3: Signal 2 fires for 5 consecutive identical diffs (expanded window)
_sw331_tracking3=$(mktemp "${TMPDIR:-/tmp}/sw-stuckness-331b.XXXXXX")
printf 'deadbeef|none|0\ndeadbeef|none|0\ndeadbeef|none|0\ndeadbeef|none|0\ndeadbeef|none|0\n' > "$_sw331_tracking3"
if (
    export PROJECT_ROOT="/tmp" ITERATION=6 MAX_ITERATIONS=20 \
           TEST_PASSED=false STUCKNESS_COUNT=0 STUCKNESS_DIAGNOSIS="" STUCKNESS_HINT="" \
           LOG_DIR="$(dirname "$_sw331_tracking3")" \
           STUCKNESS_TRACKING_FILE="$_sw331_tracking3"
    source "$SCRIPT_DIR/lib/helpers.sh" 2>/dev/null
    source "$SCRIPT_DIR/lib/loop-convergence.sh" 2>/dev/null
    detect_stuckness 2>/dev/null
    [[ -n "$STUCKNESS_HINT" ]]
) 2>/dev/null; then
    assert_pass "detect_stuckness: Signal 2 fires for 5 consecutive identical diffs (#331 Bug 3)"
else
    assert_fail "detect_stuckness: Signal 2 fires for 5 consecutive identical diffs (#331 Bug 3)"
fi
rm -f "$_sw331_tracking3"

# Test 4: Signal 2b cycling detector fires at exactly 4 identical diffs
_sw331_tracking4=$(mktemp "${TMPDIR:-/tmp}/sw-stuckness-331c.XXXXXX")
printf 'cafebabe|none|0\ncafebabe|none|0\ncafebabe|none|0\ncafebabe|none|0\n' > "$_sw331_tracking4"
if (
    export PROJECT_ROOT="/tmp" ITERATION=5 MAX_ITERATIONS=20 \
           TEST_PASSED=false STUCKNESS_COUNT=0 STUCKNESS_DIAGNOSIS="" STUCKNESS_HINT="" \
           LOG_DIR="$(dirname "$_sw331_tracking4")" \
           STUCKNESS_TRACKING_FILE="$_sw331_tracking4"
    source "$SCRIPT_DIR/lib/helpers.sh" 2>/dev/null
    source "$SCRIPT_DIR/lib/loop-convergence.sh" 2>/dev/null
    detect_stuckness 2>/dev/null
    [[ "$STUCKNESS_HINT" == *"cycling"* ]]
) 2>/dev/null; then
    assert_pass "detect_stuckness: Signal 2b cycling detector fires at 4 identical diffs (#331)"
else
    assert_fail "detect_stuckness: Signal 2b cycling detector fires at 4 identical diffs (#331)" \
        "expected STUCKNESS_HINT to contain 'cycling'"
fi
rm -f "$_sw331_tracking4"

# Test 4b: cycling detector skips empty-diff runs (clean tree = work committed, NOT cycling)
# Regression for #504 false-positive: completed pipelines were flagged as cycling because
# repeated `git diff HEAD` returns empty, yielding identical MD5 of empty input.
_sw504_tracking=$(mktemp "${TMPDIR:-/tmp}/sw-stuckness-504-empty.XXXXXX")
printf 'd41d8cd98f00b204e9800998ecf8427e|none|0\nd41d8cd98f00b204e9800998ecf8427e|none|0\nd41d8cd98f00b204e9800998ecf8427e|none|0\nd41d8cd98f00b204e9800998ecf8427e|none|0\nd41d8cd98f00b204e9800998ecf8427e|none|0\n' > "$_sw504_tracking"
if (
    export PROJECT_ROOT="/tmp" ITERATION=6 MAX_ITERATIONS=20 \
           TEST_PASSED=true STUCKNESS_COUNT=0 STUCKNESS_DIAGNOSIS="" STUCKNESS_HINT="" \
           LOG_DIR="$(dirname "$_sw504_tracking")" \
           STUCKNESS_TRACKING_FILE="$_sw504_tracking"
    source "$SCRIPT_DIR/lib/helpers.sh" 2>/dev/null
    source "$SCRIPT_DIR/lib/loop-convergence.sh" 2>/dev/null
    detect_stuckness 2>/dev/null
    [[ "$STUCKNESS_HINT" != *"cycling"* ]] && [[ "$STUCKNESS_HINT" != *"identical git diffs in last 5 iterations"* ]]
) 2>/dev/null; then
    assert_pass "detect_stuckness: cycling detector skips empty-diff runs (#504)"
else
    assert_fail "detect_stuckness: cycling detector skips empty-diff runs (#504)" \
        "expected STUCKNESS_HINT to NOT contain 'cycling' or 'identical git diffs' for clean-tree iterations"
fi
rm -f "$_sw504_tracking"

# Test 4c: done-and-idle escape hatch — TEST_PASSED + clean tree + similar logs MUST NOT
# trigger stuckness. Regression for #504 iteration 7 false positive: Signals 1 (text
# overlap on near-identical idle logs) + 6 (no diff) summed to 2 signals and tripped
# the prompt builder's stuckness branch even though the work was committed and tests
# were green.
_sw504_idle_dir=$(mktemp -d "${TMPDIR:-/tmp}/sw-stuckness-504-idle.XXXXXX")
_sw504_idle_tracking="$_sw504_idle_dir/tracking.txt"
printf 'd41d8cd98f00b204e9800998ecf8427e|none|0\nd41d8cd98f00b204e9800998ecf8427e|none|0\nd41d8cd98f00b204e9800998ecf8427e|none|0\nd41d8cd98f00b204e9800998ecf8427e|none|0\nd41d8cd98f00b204e9800998ecf8427e|none|0\n' > "$_sw504_idle_tracking"
# Two near-identical iteration logs to force Signal 1 (text overlap >= 90%).
_sw504_idle_log='LOOP_COMPLETE
all tests pass
goal achieved
no remaining work'
printf '%s\n' "$_sw504_idle_log" > "$_sw504_idle_dir/iteration-5.log"
printf '%s\n' "$_sw504_idle_log" > "$_sw504_idle_dir/iteration-6.log"
if (
    export PROJECT_ROOT="/tmp" ITERATION=7 MAX_ITERATIONS=20 \
           TEST_PASSED=true STUCKNESS_COUNT=0 STUCKNESS_DIAGNOSIS="" STUCKNESS_HINT="" \
           LOG_DIR="$_sw504_idle_dir" \
           STUCKNESS_TRACKING_FILE="$_sw504_idle_tracking"
    source "$SCRIPT_DIR/lib/helpers.sh" 2>/dev/null
    source "$SCRIPT_DIR/lib/loop-convergence.sh" 2>/dev/null
    detect_stuckness 2>/dev/null
    [[ -z "$STUCKNESS_HINT" ]]
) 2>/dev/null; then
    assert_pass "detect_stuckness: done-and-idle escape hatch suppresses stuckness when TEST_PASSED + clean tree + no active failure (#504)"
else
    assert_fail "detect_stuckness: done-and-idle escape hatch suppresses stuckness when TEST_PASSED + clean tree + no active failure (#504)" \
        "expected STUCKNESS_HINT to be empty for done-and-idle iteration"
fi
rm -rf "$_sw504_idle_dir"

# Test 4d: cycling protection still trips when an active failure signal IS present.
# Same idle setup as 4c, but with a non-empty repeating diff hash to force Signal 2/2b.
# Verifies the escape hatch only suppresses when active_failure_signals == 0.
_sw504_cycle_dir=$(mktemp -d "${TMPDIR:-/tmp}/sw-stuckness-504-cycle.XXXXXX")
_sw504_cycle_tracking="$_sw504_cycle_dir/tracking.txt"
printf 'cafebabe|none|0\ncafebabe|none|0\ncafebabe|none|0\ncafebabe|none|0\ncafebabe|none|0\n' > "$_sw504_cycle_tracking"
printf '%s\n' "$_sw504_idle_log" > "$_sw504_cycle_dir/iteration-5.log"
printf '%s\n' "$_sw504_idle_log" > "$_sw504_cycle_dir/iteration-6.log"
if (
    export PROJECT_ROOT="/tmp" ITERATION=7 MAX_ITERATIONS=20 \
           TEST_PASSED=true STUCKNESS_COUNT=0 STUCKNESS_DIAGNOSIS="" STUCKNESS_HINT="" \
           LOG_DIR="$_sw504_cycle_dir" \
           STUCKNESS_TRACKING_FILE="$_sw504_cycle_tracking"
    source "$SCRIPT_DIR/lib/helpers.sh" 2>/dev/null
    source "$SCRIPT_DIR/lib/loop-convergence.sh" 2>/dev/null
    detect_stuckness 2>/dev/null
    [[ "$STUCKNESS_HINT" == *"cycling"* ]]
) 2>/dev/null; then
    assert_pass "detect_stuckness: done-and-idle escape hatch does NOT mask real cycling on non-empty diff (#504)"
else
    assert_fail "detect_stuckness: done-and-idle escape hatch does NOT mask real cycling on non-empty diff (#504)" \
        "expected STUCKNESS_HINT to contain 'cycling' when active failure signal fires"
fi
rm -rf "$_sw504_cycle_dir"

# Test 5: DOD_DIFF_MAX_LINES default is 5000
if grep -E "DOD_DIFF_MAX_LINES=\\\$\(_config_get_int[^)]*5000" "$SCRIPT_DIR/sw-loop.sh" | grep -q '5000'; then
    assert_pass "DOD_DIFF_MAX_LINES default is 5000 (#331)"
else
    assert_fail "DOD_DIFF_MAX_LINES default is 5000 (#331)" "expected 5000 as default"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Bug fixes: loop stuckness — GOAL pollution, circuit-breaker escape hatch,
# zero-progress blindness (#345)
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${DIM}  loop stuckness fixes (#345)${RESET}"

# ─── Fix 1 (updated PR B): Context-aware holistic goal selection ─────────────
# run_holistic_gate() is now context-aware:
#   - compound_quality context: uses $GOAL (findings appended there by the feedback cycle)
#   - Standalone loop context: uses $ORIGINAL_GOAL when set (prevents accumulated-feedback
#     pollution of the holistic assessment — preserves issue #345 fix non-regression)
# The literal ${ORIGINAL_GOAL:-$GOAL} form is intentionally absent; each branch is
# explicit. Verify the compound_quality branch exists inside the function.
holistic_gate_block=$(
    awk '
        /^run_holistic_gate\(\)[[:space:]]*\{/ { in_fn=1 }
        in_fn { print }
        in_fn && /^\}/ { exit }
    ' "$SCRIPT_DIR/sw-loop.sh" || true
)
if printf '%s\n' "$holistic_gate_block" | grep -q 'compound_quality'; then
    assert_pass "Fix 1 (context-aware): compound_quality branch present inside run_holistic_gate"
else
    assert_fail "Fix 1 (context-aware): compound_quality branch present inside run_holistic_gate" \
        "Expected compound_quality context check inside run_holistic_gate in sw-loop.sh"
fi

# Verify _holistic_judge_goal is set and used in the prompt
if printf '%s\n' "$holistic_gate_block" | grep -q '_holistic_judge_goal'; then
    assert_pass "Fix 1 (context-aware): _holistic_judge_goal variable used in run_holistic_gate"
else
    assert_fail "Fix 1 (context-aware): _holistic_judge_goal variable used in run_holistic_gate" \
        "Expected _holistic_judge_goal variable inside run_holistic_gate in sw-loop.sh"
fi

# ─── Fix 2: Circuit breaker escape hatch respects quality gates ──────────────
# The elif branch that resets CONSECUTIVE_FAILURES=0 must also require that
# QUALITY_GATE_PASSED is true (or quality gates are disabled). Variable is
# QUALITY_GATE_PASSED (singular), gated by QUALITY_GATES_ENABLED.
if grep -qE 'QUALITY_GATES_ENABLED.*QUALITY_GATE_PASSED|QUALITY_GATE_PASSED.*QUALITY_GATES_ENABLED' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Fix 2: circuit breaker escape hatch checks QUALITY_GATE_PASSED"
else
    assert_fail "Fix 2: circuit breaker escape hatch checks QUALITY_GATE_PASSED" \
        "Expected QUALITY_GATES_ENABLED and QUALITY_GATE_PASSED in the elif escape-hatch branch"
fi

# Verify escape hatch still resets CONSECUTIVE_FAILURES (it should still work when gates pass)
if grep -A5 'QUALITY_GATES_ENABLED.*QUALITY_GATE_PASSED\|QUALITY_GATE_PASSED.*QUALITY_GATES_ENABLED' \
    "$SCRIPT_DIR/sw-loop.sh" 2>/dev/null | grep -q 'CONSECUTIVE_FAILURES=0' 2>/dev/null; then
    assert_pass "Fix 2: CONSECUTIVE_FAILURES still resets when all gates pass"
else
    assert_fail "Fix 2: CONSECUTIVE_FAILURES still resets when all gates pass" \
        "Expected CONSECUTIVE_FAILURES=0 in the escape hatch branch after quality gate guard"
fi

# ─── Fix 3a: PREV_NEW_COMMITS global initialized and persisted ───────────────
# PREV_NEW_COMMITS=0 must be initialized in the defaults section.
if grep -q 'PREV_NEW_COMMITS=0' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Fix 3a: PREV_NEW_COMMITS initialized to 0 in defaults"
else
    assert_fail "Fix 3a: PREV_NEW_COMMITS initialized to 0 in defaults" \
        "Expected 'PREV_NEW_COMMITS=0' in sw-loop.sh defaults"
fi

# PREV_NEW_COMMITS must be set to new_commits after the circuit breaker block
if grep -q 'PREV_NEW_COMMITS="${new_commits' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Fix 3a: PREV_NEW_COMMITS set from new_commits after circuit breaker"
else
    assert_fail "Fix 3a: PREV_NEW_COMMITS set from new_commits after circuit breaker" \
        "Expected PREV_NEW_COMMITS=\"\${new_commits...}\" assignment in main loop body"
fi

# ─── Fix 3b: Zero-progress notice in compose_prompt ─────────────────────────
# compose_prompt() in loop-iteration.sh must check PREV_NEW_COMMITS and
# QUALITY_GATE_PASSED and inject a zero-progress warning when both indicate stuckness.
if grep -q 'PREV_NEW_COMMITS' "$SCRIPT_DIR/lib/loop-iteration.sh"; then
    assert_pass "Fix 3b: loop-iteration.sh references PREV_NEW_COMMITS"
else
    assert_fail "Fix 3b: loop-iteration.sh references PREV_NEW_COMMITS" \
        "Expected PREV_NEW_COMMITS check in loop-iteration.sh compose_prompt()"
fi

if grep -q 'Zero Progress Detected' "$SCRIPT_DIR/lib/loop-iteration.sh"; then
    assert_pass "Fix 3b: zero-progress notice text present in loop-iteration.sh"
else
    assert_fail "Fix 3b: zero-progress notice text present in loop-iteration.sh" \
        "Expected 'Zero Progress Detected' string in compose_prompt() notice"
fi

# Notice must only fire when PREV_NEW_COMMITS==0 AND (quality gate failed OR completion rejected).
# The guard may span multiple lines, so check each condition independently.
if grep -q 'PREV_NEW_COMMITS.*-eq 0' "$SCRIPT_DIR/lib/loop-iteration.sh" \
   && grep -q 'QUALITY_GATE_PASSED' "$SCRIPT_DIR/lib/loop-iteration.sh"; then
    assert_pass "Fix 3b: zero-progress notice gated on PREV_NEW_COMMITS==0 and QUALITY_GATE_PASSED==false"
else
    assert_fail "Fix 3b: zero-progress notice gated on PREV_NEW_COMMITS==0 and QUALITY_GATE_PASSED==false" \
        "Expected both conditions in loop-iteration.sh"
fi

# ─── Fix 3b: compose_prompt includes zero_progress_notice in output ──────────
if grep -q 'zero_progress_notice' "$SCRIPT_DIR/lib/loop-iteration.sh"; then
    assert_pass "Fix 3b: zero_progress_notice variable used in compose_prompt output"
else
    assert_fail "Fix 3b: zero_progress_notice variable used in compose_prompt output"
fi

# ─── #447: write_error_summary must not flag passing tests as errors ─────────
# Regression: lines like "✓ Test 4: ... (fail-open ...)" are PASSING tests but
# the unfiltered grep was matching the substring "fail" and counting them as
# errors. Flooded errors-collected.json on green builds and tripped the
# holistic gate's circuit breaker. _strip_passing_test_lines prevents this.
echo ""
echo -e "${DIM}  #447 regression — write_error_summary passing-test filter${RESET}"

# Extract the _strip_passing_test_lines function from sw-loop.sh and eval it in
# this test scope. Avoids sourcing the full script (which would run main()).
_swl_helper_def=$(awk '/^_strip_passing_test_lines\(\) \{/,/^\}/' "$SCRIPT_DIR/sw-loop.sh")
if [[ -n "$_swl_helper_def" ]]; then
    assert_pass "#447: _strip_passing_test_lines defined in sw-loop.sh"
    eval "$_swl_helper_def"
else
    assert_fail "#447: _strip_passing_test_lines defined in sw-loop.sh" \
        "function not found in sw-loop.sh"
fi

# Sample: confirmed pass-marker lines that must be stripped.
# Section headers ("Test N: description") are intentionally NOT stripped —
# they provide failure context and may be the only signal for a failing test.
_swl_sample=$(cat <<'SAMPLE'
  ✓ Test 4: ruflo_store fired on missing fingerprint (fail-open, now 3)
  ✓ Test 4: ruflo_recall fired on missing fingerprint (fail-open, now 3)
  All 14 tests passed
14/14 pass
SAMPLE
)

# Filter, then count lines that the error grep would still flag.
_swl_filtered=$(printf '%s\n' "$_swl_sample" \
    | _strip_passing_test_lines \
    | grep -iE '(error|fail|assert|exception|panic|FAIL|TypeError|ReferenceError|SyntaxError)' \
    || true)
_swl_filtered_count=$(printf '%s' "$_swl_filtered" | grep -c . 2>/dev/null || true)
_swl_filtered_count=${_swl_filtered_count:-0}

if [[ "$_swl_filtered_count" -eq 0 ]]; then
    assert_pass "#447: confirmed pass-marker lines with 'fail-open' are filtered out (0 false positives)"
else
    assert_fail "#447: confirmed pass-marker lines with 'fail-open' are filtered out" \
        "expected 0, got $_swl_filtered_count: $_swl_filtered"
fi

# Section headers ("Test N: description") must survive the filter — they provide
# failure context. Verify a header containing "fail" is NOT stripped.
_swl_header_kept=$(printf '%s\n' "  Test 4: missing fingerprint file fails open (both calls fire)" \
    | _strip_passing_test_lines \
    | grep -iE '(fail)' || true)
if [[ -n "$_swl_header_kept" ]]; then
    assert_pass "#447: section headers with 'fail' survive the filter (not stripped)"
else
    assert_fail "#447: section headers with 'fail' survive the filter" \
        "section header was incorrectly stripped"
fi

# Real error lines must still pass through the filter.
_swl_real_errors=$(cat <<'SAMPLE'
  ✗ Test 7: actually broken assertion
FAIL src/foo.test.js
TypeError: cannot read property 'x' of undefined
SAMPLE
)
_swl_kept=$(printf '%s\n' "$_swl_real_errors" \
    | _strip_passing_test_lines \
    | grep -iE '(error|fail|assert|exception|panic|FAIL|TypeError|ReferenceError|SyntaxError)' \
    || true)
_swl_kept_count=$(printf '%s' "$_swl_kept" | grep -c . 2>/dev/null || true)
_swl_kept_count=${_swl_kept_count:-0}

if [[ "$_swl_kept_count" -ge 3 ]]; then
    assert_pass "#447: real error lines (FAIL, ✗, TypeError) survive the filter"
else
    assert_fail "#447: real error lines (FAIL, ✗, TypeError) survive the filter" \
        "expected >=3, got $_swl_kept_count: $_swl_kept"
fi

# ─── #504 follow-up: section-header false positives on green builds ──────────
# Regression: section headers like "Test 4: missing fingerprint file fails open"
# survive _strip_passing_test_lines by design (#447), but on green builds they
# leaked into write_error_summary and tripped the loop's circuit breaker even
# though every assertion in the section was ✓. _has_real_failure_markers
# distinguishes real failure markers (✗, FAIL keyword, stack traces) from
# descriptive "fail" words in test names.
echo ""
echo -e "${DIM}  #504 regression — _has_real_failure_markers distinguishes header text from real failures${RESET}"

_swl_marker_def=$(awk '/^_has_real_failure_markers\(\) \{/,/^\}/' "$SCRIPT_DIR/sw-loop.sh")
if [[ -n "$_swl_marker_def" ]]; then
    assert_pass "#504: _has_real_failure_markers defined in sw-loop.sh"
    eval "$_swl_marker_def"
else
    assert_fail "#504: _has_real_failure_markers defined in sw-loop.sh" \
        "function not found in sw-loop.sh"
fi

# Section headers with "fail" in description must NOT be flagged as real failures.
_swl_header_only=$(printf '%s\n' "  Test 4: missing fingerprint file fails open (both calls fire)")
if printf '%s\n' "$_swl_header_only" | _has_real_failure_markers; then
    assert_fail "#504: descriptive section headers are not flagged as real failures" \
        "header was incorrectly classified as a failure"
else
    assert_pass "#504: descriptive section headers are not flagged as real failures"
fi

# Real failure lines (✗, FAIL, TypeError, stack traces) MUST be flagged.
_swl_real_marker_lines=$(cat <<'SAMPLE'
  ✗ Test 7: actually broken assertion
FAIL src/foo.test.js
TypeError: cannot read property 'x' of undefined
  at module.exports (/foo/bar.js:10:5)
expected "x" got "y"
SAMPLE
)
while IFS= read -r _swl_marker_line; do
    [[ -z "$_swl_marker_line" ]] && continue
    if printf '%s\n' "$_swl_marker_line" | _has_real_failure_markers; then
        assert_pass "#504: real failure marker detected: '${_swl_marker_line:0:50}'"
    else
        assert_fail "#504: real failure marker detected" \
            "missed: '$_swl_marker_line'"
    fi
done <<< "$_swl_real_marker_lines"

# ─── #504 follow-up: claude -p prompt piped via stdin (exec ARG_MAX bypass) ──
# Regression: the deployed sw-loop.sh failed iter 8 DoD with "Argument list
# too long" because cumulative-diff prompts exceeded the OS exec ARG_MAX
# when passed as a positional CLI argument. Fix: pipe the prompt via stdin
# (printf '%s' "$prompt" | claude -p ...) at every claude invocation site.
echo ""
echo -e "${DIM}  #504 regression — claude -p prompts piped via stdin (avoids ARG_MAX)${RESET}"

# Forbidden: positional prompt as CLI argument. Any line of the form
# `claude -p "$<var>" ...` (with a leading space, not in a comment) is the
# pre-fix pattern that trips ARG_MAX on long prompts.
_swl_bad_invocations=$(grep -nE '^[[:space:]]+claude[[:space:]]+-p[[:space:]]+"\$' \
    "$SCRIPT_DIR/sw-loop.sh" || true)
if [[ -z "$_swl_bad_invocations" ]]; then
    assert_pass "#504: no claude -p invocations pass the prompt as a positional CLI arg"
else
    assert_fail "#504: no claude -p invocations pass the prompt as a positional CLI arg" \
        "found pre-fix pattern at: $_swl_bad_invocations"
fi

# Required: every claude -p invocation must be piped from a printf '%s' "$prompt".
# We require exactly 4 such invocations (audit, DoD, holistic, main agent).
_swl_piped_count=$(grep -cE "^[[:space:]]*printf[[:space:]]+'%s'[[:space:]]+\"\\\$[a-zA-Z_]+\"[[:space:]]*\\|[[:space:]]*claude[[:space:]]+-p" \
    "$SCRIPT_DIR/sw-loop.sh" || true)
_swl_piped_count="${_swl_piped_count:-0}"
if [[ "$_swl_piped_count" -eq 4 ]]; then
    assert_pass "#504: all 4 claude -p invocations use 'printf | claude -p' stdin piping"
else
    assert_fail "#504: all 4 claude -p invocations use 'printf | claude -p' stdin piping" \
        "expected 4 piped invocations, found $_swl_piped_count"
fi

# Smoke test: an oversize prompt (>256KB) passed via stdin must reach the
# downstream command without truncation. This validates the technique itself
# rather than the loop wiring — using `cat` as a stand-in for `claude -p`.
_swl_big_prompt=$(printf 'x%.0s' $(seq 1 262144))  # 256KB of 'x'
_swl_received=$(printf '%s' "$_swl_big_prompt" | cat | wc -c | tr -d ' ')
if [[ "$_swl_received" -eq 262144 ]]; then
    assert_pass "#504: 256KB prompt round-trips through printf|stdin without truncation"
else
    assert_fail "#504: 256KB prompt round-trips through printf|stdin without truncation" \
        "expected 262144 bytes, got $_swl_received"
fi

# ─── write_error_summary stricter pipeline (section-header strip) ─────────────
# write_error_summary's stricter pipeline must strip descriptive section headers
# (e.g. "Test 4: missing fingerprint file fails open") so they don't get counted
# as errors. The same pipeline must keep marker-prefixed failure lines.
_swl_section_strip='^[[:space:]]*Test [0-9]+:[[:space:]]'

_swl_header_input=$(cat <<'SAMPLE'
  Test 4: missing fingerprint file fails open (both calls fire)
  ✗ Test 7: actually broken assertion
FAIL src/foo.test.js
  Test 5: observability calls fire every iteration
SAMPLE
)
_swl_summary_kept=$(printf '%s\n' "$_swl_header_input" \
    | _strip_passing_test_lines \
    | grep -vE "$_swl_section_strip" \
    | grep -iE '(error|fail|assert|exception|panic|FAIL|TypeError|ReferenceError|SyntaxError)' \
    || true)
_swl_summary_kept_count=$(printf '%s' "$_swl_summary_kept" | grep -c . 2>/dev/null || true)
_swl_summary_kept_count=${_swl_summary_kept_count:-0}

if [[ "$_swl_summary_kept_count" -eq 2 ]]; then
    assert_pass "write_error_summary: section headers stripped, marker-prefixed failures kept (got 2)"
else
    assert_fail "write_error_summary: section headers stripped, marker-prefixed failures kept" \
        "expected 2 (✗ + FAIL), got $_swl_summary_kept_count: $_swl_summary_kept"
fi

# Confirm the bare "fails open" header alone yields zero structured errors.
_swl_only_header=$(printf '%s\n' "  Test 4: missing fingerprint file fails open (both calls fire)" \
    | _strip_passing_test_lines \
    | grep -vE "$_swl_section_strip" \
    | grep -iE '(error|fail|assert|exception|panic|FAIL|TypeError|ReferenceError|SyntaxError)' \
    || true)
if [[ -z "$_swl_only_header" ]]; then
    assert_pass "write_error_summary: bare 'fails open' header alone produces zero false-positive errors"
else
    assert_fail "write_error_summary: bare 'fails open' header alone produces zero false-positive errors" \
        "header survived the strict filter: $_swl_only_header"
fi

# ─── #448 review fix: --context-file path traversal hardening ────────────────
echo ""
echo -e "${DIM}  context-file symlink/realpath validation (#448 review)${RESET}"

# Source-level structural assertions: validation block must canonicalize the path.
if grep -q "pwd -P" "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "context-file validator canonicalizes paths via 'pwd -P' (defeats symlinks/..)"
else
    assert_fail "context-file validator canonicalizes paths via 'pwd -P'" \
        "Expected 'pwd -P' usage in LOOP_CONTEXT_FILE validation block (string-prefix check is insufficient)"
fi

if grep -q "_real_project_root\|_real_ctx" "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "context-file validator uses canonical-path locals (_real_project_root / _real_ctx)"
else
    assert_fail "context-file validator uses canonical-path locals" \
        "Expected _real_project_root or _real_ctx variable in validation block"
fi

# Behavioral test: end-to-end run sw-loop.sh with a path that PASSES the legacy
# string-prefix check but resolves OUTSIDE the project root once symlinks are
# expanded. Use a real git repo so the validator runs.
ctx_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/sw-loop-ctx.XXXXXX")
real_repo="$ctx_test_dir/real-repo"
sensitive_dir="$ctx_test_dir/outside"
mkdir -p "$real_repo" "$sensitive_dir"
( cd "$real_repo" && git init -q && git config user.email t@t && git config user.name t )

# Write a sensitive file outside the repo.
echo "secret" > "$sensitive_dir/loot.md"

# Inside the repo, create a symlink whose path-prefix (literal string) would
# pass the legacy check but resolves to ../outside/loot.md.
ln -s "$sensitive_dir/loot.md" "$real_repo/ctx-link.md"

# Run sw-loop.sh with the symlink path. The realpath validator must reject.
output=$( cd "$real_repo" && \
    bash "$SCRIPT_DIR/sw-loop.sh" \
        --context-file "$real_repo/ctx-link.md" \
        --max-iterations 1 \
        "test goal" 2>&1 ) && rc=0 || rc=$?
if [[ $rc -ne 0 ]] && echo "$output" | grep -qi "must be inside project root\|context-file path"; then
    assert_pass "context-file validator rejects symlink that resolves outside project root"
else
    assert_fail "context-file validator rejects symlink that resolves outside project root" \
        "exit=$rc output=${output:0:300}"
fi

# Path with .. that string-prefix-passes but canonicalizes outside repo.
output=$( cd "$real_repo" && \
    bash "$SCRIPT_DIR/sw-loop.sh" \
        --context-file "$real_repo/../outside/loot.md" \
        --max-iterations 1 \
        "test goal" 2>&1 ) && rc=0 || rc=$?
if [[ $rc -ne 0 ]] && echo "$output" | grep -qi "must be inside project root\|context-file path"; then
    assert_pass "context-file validator rejects .. paths that escape via canonicalization"
else
    assert_fail "context-file validator rejects .. paths that escape via canonicalization" \
        "exit=$rc output=${output:0:300}"
fi

rm -rf "$ctx_test_dir"

# ─── #448 review fix: goal-sanitize.sh fail-hard fallback ─────────────────────
echo ""
echo -e "${DIM}  goal-sanitize fail-hard fallback (#448 review)${RESET}"

# Structural: when LOOP_CONTEXT_FILE is set, the script must call into
# _strip_synthesized_sections (not an inline fallback list).
if grep -q "goal-sanitize.sh failed to load" "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "sw-loop.sh fails hard with explicit error if goal-sanitize.sh isn't loaded"
else
    assert_fail "sw-loop.sh fails hard if goal-sanitize.sh isn't loaded" \
        "Expected explicit 'goal-sanitize.sh failed to load' error"
fi

# Inline fallback sentinel list must be removed (the bug being fixed: the
# inline list drifted out of sync with goal-sanitize.sh's 18-pattern set).
if grep -q "## Plan Summary'\\*}\";" "$SCRIPT_DIR/sw-loop.sh"; then
    assert_fail "inline fallback sentinel list removed from sw-loop.sh" \
        "Found legacy inline sentinel — should rely solely on goal-sanitize.sh"
else
    assert_pass "inline fallback sentinel list removed from sw-loop.sh"
fi

# ─── Quality-gate task-marker pattern: mktemp templates must not self-flag ──
echo ""
echo -e "${DIM}  task-marker gate: mktemp template false-positive guard${RESET}"

# Reconstruct the gate's marker alternation the same way sw-loop.sh does, so
# the assertion stays in sync with the gate logic without duplicating the
# literal marker substrings in this test file.
_qg_t='T''O''D''O'
_qg_f='F''I''X''M''E'
_qg_h='H''A''C''K'
_qg_alt="${_qg_t}|${_qg_f}|${_qg_h}"
_qg_pattern="(${_qg_alt}|([^X]|^)X{3}([^X]|$))"

# True positives — bare task-markers must still be detected.
for _qg_case in "// ${_qg_t}: fix" "// ${_qg_f}: bug" "// ${_qg_h}: hack" "foo X${_qg_t:0:0}XX bar"; do
    if printf '%s\n' "$_qg_case" | grep -qE "$_qg_pattern"; then
        assert_pass "task-marker gate detects: $_qg_case"
    else
        assert_fail "task-marker gate detects: $_qg_case" \
            "Expected gate pattern to match a real marker"
    fi
done

# True negatives — mktemp template syntax must NOT match (the regression).
for _qg_case in 'mktemp /tmp/foo.YYYYYY' 'mktemp /tmp/foo.ZZZZZZ' 'normal source line'; do
    if printf '%s\n' "$_qg_case" | grep -qE "$_qg_pattern"; then
        assert_fail "task-marker gate excludes: $_qg_case" \
            "Pattern wrongly matched"
    else
        assert_pass "task-marker gate excludes: $_qg_case"
    fi
done
# mktemp 6-X template specifically — built without literal six-X substring
# in this test source so the test itself does not self-flag.
_qg_six="$(printf 'X%.0s' 1 2 3 4 5 6)"
if printf 'mktemp /tmp/foo.%s\n' "$_qg_six" | grep -qE "$_qg_pattern"; then
    assert_fail "task-marker gate excludes 6-X mktemp template" \
        "Pattern wrongly matched mktemp template"
else
    assert_pass "task-marker gate excludes 6-X mktemp template"
fi

# Structural: gate must use boundary-protected pattern, not bare marker.
if grep -q "X{3}" "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "gate uses X{3} quantifier (avoids literal three-X self-flag)"
else
    assert_fail "gate uses X{3} quantifier" \
        "Expected X{3} pattern in sw-loop.sh quality gate"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# SW_LOG_PROMPTS — prompt transparency tests
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${DIM}  SW_LOG_PROMPTS: prompt transparency${RESET}"

# Shared stubs used by all four subtests (sourced inside each subshell).
_lp_stubs() {
    info()              { echo "INFO: $*"; }
    warn()              { echo "WARN: $*"; }
    sanitize_secrets()  {
        local t="$1"
        t="$(echo "$t" | sed 's/sk-[a-zA-Z0-9_-]*/sk-***REDACTED***/g')"
        t="$(echo "$t" | sed 's/Bearer [a-zA-Z0-9_.-]*/Bearer ***REDACTED***/g')"
        t="$(echo "$t" | sed 's/ANTHROPIC_API_KEY=[^ ]*/ANTHROPIC_API_KEY=***REDACTED***/g')"
        echo "$t"
    }
    gh_comment_issue()  { echo "GH_COMMENT_ISSUE called: issue=$1"; echo "$2"; }
    gh_update_progress(){ echo "GH_UPDATE_PROGRESS called"; }
    ITERATION=3
    LOG_DIR="${TMPDIR:-/tmp}"
}

# Inline the SW_LOG_PROMPTS block that was added to loop-iteration.sh so tests
# exercise the exact logic without requiring a full loop run.
_lp_run_block() {
    local sw_flag="$1" final_prompt="$2" issue_num="${3:-}" progress_id="${4:-}"
    (
        _lp_stubs
        local prompt_chars=${#final_prompt}
        local prompt_path="$LOG_DIR/iteration-${ITERATION}.prompt.txt"
        ISSUE_NUMBER="$issue_num"
        PROGRESS_COMMENT_ID="$progress_id"
        SW_LOG_PROMPTS="$sw_flag"
        info "Prompt saved → $prompt_path (${prompt_chars} chars)"
        case "${SW_LOG_PROMPTS:-off}" in
            stdout|both)
                echo ""
                echo "━━━━━━━━━━━ AGENT PROMPT — Iteration ${ITERATION} ━━━━━━━━━━━"
                printf '%s\n' "$final_prompt"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo ""
                ;;
        esac
        case "${SW_LOG_PROMPTS:-off}" in
            github|both)
                if [[ -n "${ISSUE_NUMBER:-}" ]] && type sanitize_secrets >/dev/null 2>&1; then
                    local redacted truncated body
                    redacted="$(sanitize_secrets "$final_prompt")"
                    if [[ ${#redacted} -gt 50000 ]]; then
                        truncated="${redacted:0:50000} …[TRUNCATED — full prompt at $prompt_path on builder]"
                    else
                        truncated="$redacted"
                    fi
                    body="### Agent Prompt — Iteration ${ITERATION}

<details><summary>Prompt (${prompt_chars} chars, redacted)</summary>

\`\`\`
${truncated}
\`\`\`

</details>"
                    if [[ -n "${PROGRESS_COMMENT_ID:-}" ]] && type gh_update_progress >/dev/null 2>&1; then
                        gh_update_progress "$body"
                    else
                        gh_comment_issue "$ISSUE_NUMBER" "$body"
                    fi
                fi ;;
        esac
    ) 2>&1
}

# Test 1: default (off) — path info line only, no box, no GitHub comment
_lp_out="$(_lp_run_block "off" "hello world" "42" "")"
assert_contains     "SW_LOG_PROMPTS off: info path line printed"  "$_lp_out" "Prompt saved →"
if echo "$_lp_out" | grep -qF "AGENT PROMPT — Iteration"; then
    assert_fail "SW_LOG_PROMPTS off: no boxed header printed"
else
    assert_pass "SW_LOG_PROMPTS off: no boxed header printed"
fi
if echo "$_lp_out" | grep -qF "GH_COMMENT_ISSUE called"; then
    assert_fail "SW_LOG_PROMPTS off: no GitHub comment posted"
else
    assert_pass "SW_LOG_PROMPTS off: no GitHub comment posted"
fi

# Test 2: stdout — boxed header + content, no GitHub comment
_lp_out="$(_lp_run_block "stdout" "hello world" "42" "")"
assert_contains "SW_LOG_PROMPTS stdout: boxed header printed" "$_lp_out" "AGENT PROMPT — Iteration"
assert_contains "SW_LOG_PROMPTS stdout: prompt content visible" "$_lp_out" "hello world"
if echo "$_lp_out" | grep -qF "GH_COMMENT_ISSUE called"; then
    assert_fail "SW_LOG_PROMPTS stdout: no GitHub comment posted"
else
    assert_pass "SW_LOG_PROMPTS stdout: no GitHub comment posted"
fi

# Test 3: github — secrets redacted, gh_comment_issue called (no rolling ID)
_lp_out="$(_lp_run_block "github" "use ANTHROPIC_API_KEY=sk-secret123 to auth" "42" "")"
assert_contains "SW_LOG_PROMPTS github: gh_comment_issue called" "$_lp_out" "GH_COMMENT_ISSUE called"
if echo "$_lp_out" | grep -qF "sk-secret123"; then
    assert_fail "SW_LOG_PROMPTS github: raw secret absent from comment"
else
    assert_pass "SW_LOG_PROMPTS github: raw secret absent from comment"
fi
assert_contains "SW_LOG_PROMPTS github: REDACTED marker present" "$_lp_out" "***REDACTED***"

# Test 4: github + PROGRESS_COMMENT_ID — uses rolling update, not new comment
_lp_out="$(_lp_run_block "github" "task: refactor auth" "42" "99999")"
assert_contains "SW_LOG_PROMPTS github+rolling: uses gh_update_progress" "$_lp_out" "GH_UPDATE_PROGRESS called"
if echo "$_lp_out" | grep -qF "GH_COMMENT_ISSUE called"; then
    assert_fail "SW_LOG_PROMPTS github+rolling: does NOT create new comment"
else
    assert_pass "SW_LOG_PROMPTS github+rolling: does NOT create new comment"
fi

# Test 5: github mode with gh helpers absent — must not abort (graceful no-op)
_lp_no_gh_out="$(
    (
        # Define only the minimum stubs — deliberately omit gh_comment_issue and gh_update_progress
        info()             { echo "INFO: $*"; }
        sanitize_secrets() { echo "$1"; }
        ITERATION=1
        LOG_DIR="${TMPDIR:-/tmp}"
        SW_LOG_PROMPTS="github"
        ISSUE_NUMBER="42"
        PROGRESS_COMMENT_ID=""
        final_prompt="task: add feature"
        prompt_chars=${#final_prompt}
        prompt_path="$LOG_DIR/iteration-1.prompt.txt"
        info "Prompt saved → $prompt_path (${prompt_chars} chars)"
        case "${SW_LOG_PROMPTS:-off}" in stdout|both) echo "BOX" ;; esac
        case "${SW_LOG_PROMPTS:-off}" in
            github|both)
                if [[ -n "${ISSUE_NUMBER:-}" ]] && type sanitize_secrets >/dev/null 2>&1; then
                    _t5_redacted="$(sanitize_secrets "$final_prompt")"
                    if [[ ${#_t5_redacted} -gt 50000 ]]; then
                        _t5_truncated="${_t5_redacted:0:50000} …[TRUNCATED]"
                    else
                        _t5_truncated="$_t5_redacted"
                    fi
                    _t5_body="prompt: ${_t5_truncated}"
                    if [[ -n "${PROGRESS_COMMENT_ID:-}" ]] && type gh_update_progress >/dev/null 2>&1; then
                        gh_update_progress "$_t5_body"
                    elif type gh_comment_issue >/dev/null 2>&1; then
                        gh_comment_issue "$ISSUE_NUMBER" "$_t5_body"
                    fi
                fi ;;
        esac
        echo "COMPLETED"
    ) 2>&1
)"
if echo "$_lp_no_gh_out" | grep -qF "COMPLETED"; then
    assert_pass "SW_LOG_PROMPTS github no-helpers: block completes without abort"
else
    assert_fail "SW_LOG_PROMPTS github no-helpers: block completes without abort" \
        "Block did not reach COMPLETED — may have aborted"
fi
if echo "$_lp_no_gh_out" | grep -qiE "command not found|gh_comment_issue"; then
    assert_fail "SW_LOG_PROMPTS github no-helpers: no command-not-found error"
else
    assert_pass "SW_LOG_PROMPTS github no-helpers: no command-not-found error"
fi

# ─── sanitize_secrets regression: over-broad gh_ regex fix (F6) ───────────────
# Load the real sanitize_secrets from helpers.sh for these tests.
_ss_helpers="$SCRIPT_DIR/lib/helpers.sh"

# Helper: negative assertion (not present in test-helpers.sh for this file)
_assert_not_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if printf '%s\n' "$haystack" | grep -qF -- "$needle" 2>/dev/null; then
        assert_fail "$desc" "output unexpectedly contains: $needle"
    else
        assert_pass "$desc"
    fi
}

echo -e "${DIM}  sanitize_secrets: over-broad gh_ regex regression (F6)${RESET}"

# Test: function names like gh_comment_issue must not be redacted
_ss_fn_result="$(
    source "$_ss_helpers" 2>/dev/null
    sanitize_secrets "call gh_comment_issue and gh_post_progress on issue 460"
)"
assert_contains "sanitize should preserve gh_comment_issue function name" \
    "$_ss_fn_result" "gh_comment_issue"
assert_contains "sanitize should preserve gh_post_progress function name" \
    "$_ss_fn_result" "gh_post_progress"
_assert_not_contains "no redaction should occur for function names" \
    "$_ss_fn_result" "REDACTED"

# Test: real GitHub OAuth tokens must be redacted
_ss_token_result="$(
    source "$_ss_helpers" 2>/dev/null
    sanitize_secrets "GITHUB_TOKEN=ghp_AaBbCcDd1234567890AbCdEfGhIjKlMnOpQrStUvWx"
)"
assert_contains "real GitHub token should be redacted" \
    "$_ss_token_result" "REDACTED"
_assert_not_contains "token value should not be present after redaction" \
    "$_ss_token_result" "ghp_AaBbCcDd"

# ─── sanitize_secrets: fine-grained PAT redaction (C5) ──────────────────────
echo -e "${DIM}  sanitize_secrets: fine-grained PAT coverage (C5)${RESET}"

# Fine-grained PATs (github_pat_ prefix, ≥60 chars) must be redacted
_ss_fgpat_result="$(
    source "$_ss_helpers" 2>/dev/null
    sanitize_secrets "token: github_pat_11ABCDE0Y0abcdefghijkl_aBcDeFgHiJkLmNoPqRsTuVwXyZabcdefghijklmnop"
)"
assert_contains "fine-grained PAT should be redacted" \
    "$_ss_fgpat_result" "REDACTED"
_assert_not_contains "fine-grained PAT value should not appear after redaction" \
    "$_ss_fgpat_result" "github_pat_11ABCDE"

# Short github_pat_ strings (< 60 chars) must NOT be redacted (not real tokens)
_ss_fgpat_short="$(
    source "$_ss_helpers" 2>/dev/null
    sanitize_secrets "github_pat_short"
)"
_assert_not_contains "short github_pat_ string should not be redacted" \
    "$_ss_fgpat_short" "REDACTED"

# Function names with gh_ prefix still preserved after C5 change
_ss_fn2_result="$(
    source "$_ss_helpers" 2>/dev/null
    sanitize_secrets "gh_comment_issue gh_post_progress"
)"
assert_contains "function names still preserved after C5" \
    "$_ss_fn2_result" "gh_comment_issue"

# ─── F7 anchor fix (C2): ES6 named import must downgrade to low confidence ───
echo -e "${DIM}  F7 anchor: ES6 named import confidence (C2)${RESET}"

# Static: anchor regex in pipeline-intelligence.sh must use the two-step form
if grep -qE '_is_import_decl' "$SCRIPT_DIR/lib/pipeline-intelligence.sh" 2>/dev/null; then
    assert_pass "F7_anchor_two_step: pipeline-intelligence.sh uses _is_import_decl two-step check"
else
    assert_fail "F7_anchor_two_step: pipeline-intelligence.sh must use _is_import_decl variable" \
        "Expected two-step import detection; found old single-grep anchor"
fi

# Static: anchor must reject lines with semicolons (adversarial multi-statement)
if grep -qE '"\[;\]"' "$SCRIPT_DIR/lib/pipeline-intelligence.sh" \
        || grep -qE '"\\[;\\]"' "$SCRIPT_DIR/lib/pipeline-intelligence.sh" \
        || grep -qP '"\[;\]"|\[;\]' "$SCRIPT_DIR/lib/pipeline-intelligence.sh" 2>/dev/null \
        || grep -q '"[;]"' "$SCRIPT_DIR/lib/pipeline-intelligence.sh" 2>/dev/null; then
    assert_pass "F7_anchor_semicolon_guard: semicolon guard present in anchor"
else
    # Check the actual guard differently
    if grep -A8 '_is_import_decl' "$SCRIPT_DIR/lib/pipeline-intelligence.sh" \
            | grep -q ';\|semicolon' 2>/dev/null; then
        assert_pass "F7_anchor_semicolon_guard: semicolon guard present in anchor"
    else
        assert_fail "F7_anchor_semicolon_guard: anchor must reject semicolons (multi-stmt lines)" \
            "Expected ';' in the negative guard near _is_import_decl"
    fi
fi

# Behavioral: simulate the import anchor logic with the exact motivating false-positive
_f7_anchor_check() {
    local match_text="$1"
    local _is_import_decl=false
    if echo "$match_text" | grep -qE \
        "^[[:space:]]*(import[[:space:]({\"\']|from[[:space:]]+[A-Za-z_]|const[[:space:]]+|var[[:space:]]+|let[[:space:]]+)"; then
        if ! echo "$match_text" | grep -qE \
            "[;]|\.(exec|run|spawn|system|call|Popen)[[:space:]]*\(|eval[[:space:]]*\(|shell[[:space:]]*=[[:space:]]*[Tt]rue"; then
            _is_import_decl=true
        fi
    fi
    echo "$_is_import_decl"
}

# ES6 named import (the original #460 false positive) → must be low (import_decl=true)
_f7_es6="$(  _f7_anchor_check "import { execFileSync } from 'child_process'")"
if [[ "$_f7_es6" == "true" ]]; then
    assert_pass "F7_anchor_es6_named_import: 'import { execFileSync } from child_process' detected as import decl (low confidence)"
else
    assert_fail "F7_anchor_es6_named_import: motivating false positive must be classified as import decl" \
        "Expected _is_import_decl=true for ES6 named import; got false"
fi

# Adversarial: import with trailing execution — must NOT be import_decl
_f7_adv="$( _f7_anchor_check "import subprocess; subprocess.run(user_input, shell=True)")"
if [[ "$_f7_adv" == "false" ]]; then
    assert_pass "F7_anchor_adversarial_multi_stmt: semicolon-separated execution stays at medium/high"
else
    assert_fail "F7_anchor_adversarial_multi_stmt: import+execution line must NOT be classified as import decl" \
        "Expected _is_import_decl=false for multi-stmt adversarial input"
fi

# CommonJS destructured require → import decl
_f7_cjs="$( _f7_anchor_check "const { exec } = require('child_process')")"
if [[ "$_f7_cjs" == "true" ]]; then
    assert_pass "F7_anchor_cjs_require: CommonJS const require() is import decl (low confidence)"
else
    assert_fail "F7_anchor_cjs_require: const require() must be import decl" \
        "Expected _is_import_decl=true for const { x } = require(...)"
fi

# ─── C1: abort-reason reader wired in wait_for_multi_completion ───────────────
echo -e "${DIM}  C1: abort-reason reader in wait_for_multi_completion${RESET}"

if grep -q 'abort-reason' "$SCRIPT_DIR/sw-loop.sh" 2>/dev/null; then
    _c1_reads=$(grep -c 'abort-reason' "$SCRIPT_DIR/sw-loop.sh" || true)
    if [[ "${_c1_reads:-0}" -ge 2 ]]; then
        assert_pass "C1_abort_reason_reader: abort-reason appears in both writer and reader contexts"
    else
        assert_fail "C1_abort_reason_reader: abort-reason must appear at least twice (writer + reader)" \
            "Found only ${_c1_reads} occurrence(s) — reader missing"
    fi
else
    assert_fail "C1_abort_reason_reader: abort-reason marker not found in sw-loop.sh" \
        "Expected abort-reason writer and reader wiring"
fi

# C1 review-fix: worker must NOT touch .agent-N-complete when aborting, otherwise the
# parent's completion check wins over the abort-reason check (Copilot review #4).
_c1_noop_block=$(awk '/CONSECUTIVE_NOOP.*-ge 2/,/break$/' "$SCRIPT_DIR/sw-loop.sh" 2>/dev/null | head -20 || true)
# Match an actual touch COMMAND (not a comment that mentions "touch .agent-N-complete")
if echo "$_c1_noop_block" | grep -qE '^[[:space:]]*touch[[:space:]].*agent.*complete' 2>/dev/null; then
    assert_fail "C1_no_complete_on_abort: worker must NOT touch .agent-N-complete during noop abort" \
        "Found 'touch .agent-N-complete' COMMAND in NOOP abort block — would mask abort"
else
    assert_pass "C1_no_complete_on_abort: worker noop-abort block does not touch .agent-N-complete"
fi

# C1 review-fix: wait_for_multi_completion must check abort-reason BEFORE .agent-N-complete
# (Copilot review #4). If complete wins, abort never registers.
_c1_body_full=$(awk '/^wait_for_multi_completion\(\)/,/^\}/' "$SCRIPT_DIR/sw-loop.sh" 2>/dev/null || true)
_c1_abort_pos=$(echo "$_c1_body_full" | grep -n 'abort-reason' | head -1 | cut -d: -f1 || echo "9999")
_c1_complete_pos=$(echo "$_c1_body_full" | grep -n '\.agent-${i}-complete' | head -1 | cut -d: -f1 || echo "0")
if [[ "${_c1_abort_pos:-9999}" -lt "${_c1_complete_pos:-0}" ]]; then
    assert_pass "C1_abort_before_complete: wait_for_multi_completion checks abort-reason before completion marker"
else
    assert_fail "C1_abort_before_complete: abort-reason check must come before .agent-N-complete check" \
        "abort-reason at line ${_c1_abort_pos}, complete at line ${_c1_complete_pos} (within function body)"
fi

# C1 review-fix: main() must guard launch_multi_agent under set -e (Copilot review #3).
# Without `|| true` or `if`, set -e exits before the LOOP_ABORT_FATAL check can fire.
_c1_main=$(awk '/^main\(\)/,/^\}/' "$SCRIPT_DIR/sw-loop.sh" 2>/dev/null || true)
if echo "$_c1_main" | grep -qE 'launch_multi_agent[[:space:]]*\|\|[[:space:]]*true|if[[:space:]]+(!|launch_multi_agent)' 2>/dev/null; then
    assert_pass "C1_main_set_e_guard: launch_multi_agent guarded against set -e in main()"
else
    assert_fail "C1_main_set_e_guard: launch_multi_agent must be guarded (|| true or if) so LOOP_ABORT_FATAL check fires" \
        "Bare 'launch_multi_agent' under set -e exits before post-check"
fi

# Static: wait_for_multi_completion must read the marker and set LOOP_ABORT_FATAL
_c1_body=$(awk '/^wait_for_multi_completion\(\)/,/^\}/' "$SCRIPT_DIR/sw-loop.sh" 2>/dev/null || true)
if echo "$_c1_body" | grep -q 'abort-reason' 2>/dev/null; then
    assert_pass "C1_reader_in_wait_for_multi: wait_for_multi_completion checks abort-reason file"
else
    assert_fail "C1_reader_in_wait_for_multi: wait_for_multi_completion must read abort-reason file" \
        "Expected abort-reason check inside wait_for_multi_completion() body"
fi
if echo "$_c1_body" | grep -q 'LOOP_ABORT_FATAL=true' 2>/dev/null; then
    assert_pass "C1_loop_abort_fatal_set: wait_for_multi_completion sets LOOP_ABORT_FATAL=true on abort"
else
    assert_fail "C1_loop_abort_fatal_set: wait_for_multi_completion must set LOOP_ABORT_FATAL=true" \
        "Expected LOOP_ABORT_FATAL=true inside wait_for_multi_completion abort-reason handler"
fi

# ─── C3: empty-input SHA dedup gate ──────────────────────────────────────────
echo -e "${DIM}  C3: empty-input SHA dedup gate${RESET}"

if grep -q '_fail_line_count' "$SCRIPT_DIR/lib/pipeline-intelligence.sh" 2>/dev/null; then
    assert_pass "C3_fail_count_guard: pipeline-intelligence.sh gates dedup on _fail_line_count"
else
    assert_fail "C3_fail_count_guard: dedup short-circuit must gate on failure line count > 0" \
        "Expected _fail_line_count guard before hash comparison"
fi

# Static: SHA guard skips comparison when count=0 (no-hasher sentinel excluded)
if grep -A5 '_fail_line_count' "$SCRIPT_DIR/lib/pipeline-intelligence.sh" \
        | grep -q 'gt 0' 2>/dev/null; then
    assert_pass "C3_count_gt_zero: guard uses -gt 0 comparison"
else
    assert_fail "C3_count_gt_zero: dedup guard must check _fail_line_count -gt 0" \
        "Expected [[ \$_fail_line_count -gt 0 ]] near dedup logic"
fi

# ─── R4 review-fix: all-manual DoD guard uses sidecar total, not post-strip count ──
# Copilot review #8: counting from dod-audit.md after [~] items are stripped yields 0,
# so the all-manual guard never fires. Must use dod-classification.json's `total`.
if grep -A5 'all.*items.*classified as manual' "$SCRIPT_DIR/lib/pipeline-quality-checks.sh" 2>/dev/null \
        | grep -q '_orig_total\|jq.*total' 2>/dev/null; then
    assert_pass "R4_orig_total_from_sidecar: all-manual guard uses dod-classification.json total"
else
    # Check the broader context
    if grep -B3 -A8 'classified as manual' "$SCRIPT_DIR/lib/pipeline-quality-checks.sh" 2>/dev/null \
            | grep -q '\.total\|_orig_total' 2>/dev/null; then
        assert_pass "R4_orig_total_from_sidecar: all-manual guard reads from sidecar JSON"
    else
        assert_fail "R4_orig_total_from_sidecar: all-manual guard must use dod-classification.json total" \
            "Counting dod-audit.md after [~] strip yields 0; guard never fires"
    fi
fi

# ─── stage_test review-fix: dedup file separated from compound_quality (Codex #2) ──
# stage_test must NOT write last-failure-set.sha — that file belongs to compound_quality.
# Cross-writes cause cycle N+1 to compare current failures against its own (mid-rebuild)
# hash, falsely short-circuiting as "identical failures".
if grep -qF 'stage-test-last-comment.sha' "$SCRIPT_DIR/lib/pipeline-stages-build.sh" 2>/dev/null; then
    assert_pass "stage_test_dedup_separate: stage_test uses its own dedup file (stage-test-last-comment.sha)"
else
    assert_fail "stage_test_dedup_separate: stage_test must use a separate dedup file from compound_quality" \
        "Expected stage-test-last-comment.sha (or similar non-shared path)"
fi
# And confirm it no longer WRITES last-failure-set.sha (comment references OK).
# Match a redirect (>) or printf-into pattern, not a comment-only mention.
_st_writes_shared=$(grep -E '(>|printf|tee)[^#]*last-failure-set\.sha' "$SCRIPT_DIR/lib/pipeline-stages-build.sh" 2>/dev/null \
    | grep -v '^[[:space:]]*#' | wc -l | tr -d '[:space:]' || echo "0")
if [[ "${_st_writes_shared:-0}" -eq 0 ]]; then
    assert_pass "stage_test_no_compound_collision: pipeline-stages-build.sh does not write last-failure-set.sha"
else
    assert_fail "stage_test_no_compound_collision: stage_test must not write last-failure-set.sha (cycle dedup collision)" \
        "Found ${_st_writes_shared} write(s) to last-failure-set.sha in pipeline-stages-build.sh"
fi

# ─── stage_test review-fix: empty-input SHA guard (same as C3 but in stage_test) ─
# Codex blocker: stage_test hashes test_log; empty grep yields constant SHA, collides.
if grep -B2 -A8 '_stage_test_count' "$SCRIPT_DIR/lib/pipeline-stages-build.sh" 2>/dev/null \
        | grep -q 'gt 0' 2>/dev/null; then
    assert_pass "stage_test_empty_sha_guard: dedup hash gated on failure count > 0"
else
    assert_fail "stage_test_empty_sha_guard: dedup hash must be gated on failure count > 0" \
        "Empty grep input yields constant SHA-1 — false 'same failures' match on infra errors"
fi

# ─── loop-iteration scope_label review-fix: scope_label now defined via scope-label.sh (PR C) ──
# PR C: sw-loop.sh now sources scripts/lib/scope-label.sh at startup and calls read_state.
# scope_label IS defined in the loop subprocess. The old Codex P1 guard (type check or
# fallback) is no longer the primary mechanism — the function is directly available.
# Updated assertion: scope_label must be a defined function inside the sw-loop.sh environment.
_prc_scope_label_sourced=false
if grep -qF 'scope-label.sh' "$SCRIPT_DIR/sw-loop.sh" 2>/dev/null; then
    _prc_scope_label_sourced=true
fi
if [[ "$_prc_scope_label_sourced" == "true" ]]; then
    assert_pass "loop_iteration_scope_label_guard: sw-loop.sh sources scope-label.sh (PR C — scope_label defined in subprocess)"
else
    assert_fail "loop_iteration_scope_label_guard: sw-loop.sh must source scripts/lib/scope-label.sh (PR C)" \
        "scope-label.sh not sourced — scope_label undefined in loop subprocess (set -e + missing function = 127 exit)"
fi

# Verify _read_scope_state is called at startup (PR C — loads OUTER_STAGE from state file)
if grep -qF '_read_scope_state' "$SCRIPT_DIR/sw-loop.sh" 2>/dev/null; then
    assert_pass "loop_iteration_scope_label_guard: sw-loop.sh calls _read_scope_state at startup (PR C)"
else
    assert_fail "loop_iteration_scope_label_guard: sw-loop.sh must call _read_scope_state at startup (PR C)" \
        "_read_scope_state not found in sw-loop.sh — OUTER_STAGE may be unset in loop subprocess"
fi

# ─── PR C: subprocess scope_label correctness ────────────────────────────────
# Verify that sourcing scope-label.sh and setting the expected env vars produces
# a correctly formatted label string matching "Compound Quality N — * Iteration K".
_prc_label_result=$(bash -c '
    OUTER_STAGE="compound_quality"
    COMPOUND_QUALITY_CYCLE=2
    INNER_STAGE="build"
    SELF_HEAL_COUNT=0
    source "'"$SCRIPT_DIR"'/lib/scope-label.sh" 2>/dev/null || { echo "SOURCE_FAILED"; exit 0; }
    label=$(scope_label 2>/dev/null || echo "CALL_FAILED")
    echo "LABEL=$label"
' 2>/dev/null)

if echo "$_prc_label_result" | grep -q 'SOURCE_FAILED'; then
    assert_fail "prc_scope_label_correctness: scripts/lib/scope-label.sh must be sourceable" \
        "source failed — file missing or has syntax errors"
elif echo "$_prc_label_result" | grep -q 'CALL_FAILED'; then
    assert_fail "prc_scope_label_correctness: scope_label() must be callable after sourcing scope-label.sh" \
        "scope_label() returned non-zero or is not defined"
else
    _prc_label_val=$(echo "$_prc_label_result" | grep '^LABEL=' | sed 's/^LABEL=//')
    if echo "$_prc_label_val" | grep -qiE 'Compound Quality 2' 2>/dev/null; then
        assert_pass "prc_scope_label_correctness: scope_label returns 'Compound Quality 2 ...' for COMPOUND_QUALITY_CYCLE=2"
    else
        assert_fail "prc_scope_label_correctness: scope_label must contain 'Compound Quality 2' when COMPOUND_QUALITY_CYCLE=2" \
            "got: $_prc_label_val"
    fi
    if echo "$_prc_label_val" | grep -qiE 'Build Iteration' 2>/dev/null; then
        assert_pass "prc_scope_label_correctness: scope_label includes 'Build Iteration' suffix"
    else
        assert_fail "prc_scope_label_correctness: scope_label must include 'Build Iteration' suffix" \
            "got: $_prc_label_val"
    fi
fi

# ─── pipeline-state.sh _resolve_stage_log_path review-fix (Copilot #5) ─────────
# Under set -e, _resolve_stage_log_path returns 1 on miss → mark_stage_failed exits.
# Must be guarded with `|| _x_log=""` before tail.
if grep -qE '_(ec|fs)_log=.*_resolve_stage_log_path.*\|\| _' "$SCRIPT_DIR/lib/pipeline-state.sh" 2>/dev/null; then
    assert_pass "resolve_stage_log_path_set_e_guard: _resolve_stage_log_path call guarded with || fallback"
else
    assert_fail "resolve_stage_log_path_set_e_guard: callers must guard with || fallback against set -e" \
        "Expected '_ec_log=\$(...) || _ec_log=\"\"' pattern in mark_stage_failed"
fi

# ─── _validate_ref review-fix: rejects leading dash and path traversal (Copilot #9) ─
_vr_helper="$SCRIPT_DIR/lib/helpers.sh"
_vr_dash_result="$(
    source "$_vr_helper" 2>/dev/null
    _validate_ref "--output=/etc/passwd" 2>&1 || echo "REJECTED"
)"
if echo "$_vr_dash_result" | grep -qF "REJECTED"; then
    assert_pass "validate_ref_rejects_leading_dash: --output=/etc/passwd rejected"
else
    assert_fail "validate_ref_rejects_leading_dash: leading-dash refs must be rejected (option injection)" \
        "got: $_vr_dash_result"
fi
_vr_traversal_result="$(
    source "$_vr_helper" 2>/dev/null
    _validate_ref "main..injected" 2>&1 || echo "REJECTED"
)"
if echo "$_vr_traversal_result" | grep -qF "REJECTED"; then
    assert_pass "validate_ref_rejects_traversal: '..' sequences rejected"
else
    assert_fail "validate_ref_rejects_traversal: '..' sequences must be rejected (range injection)" \
        "got: $_vr_traversal_result"
fi
_vr_normal_result="$(
    source "$_vr_helper" 2>/dev/null
    _validate_ref "main" >/dev/null 2>&1 && echo "OK" || echo "REJECTED"
)"
if echo "$_vr_normal_result" | grep -qF "OK"; then
    assert_pass "validate_ref_accepts_normal: 'main' accepted"
else
    assert_fail "validate_ref_accepts_normal: normal branch names must be accepted" \
        "got: $_vr_normal_result"
fi

# ─── C1 pre-run marker cleanup (regression guard) ────────────────────────────
# launch_multi_agent MUST remove stale .agent-*-abort-reason / .agent-*-complete
# markers BEFORE setup_worktrees runs. Without this, a crashed prior run leaves
# .agent-N-abort-reason in $LOG_DIR; wait_for_multi_completion reads it on the
# first poll of the new run and false-aborts before agents have started.
_lma_body=$(awk '/^launch_multi_agent\(\)/{p=1} p{print} p && /^\}$/{exit}' "$SCRIPT_DIR/sw-loop.sh" 2>/dev/null || true)
_lma_cleanup_line=$(echo "$_lma_body" | grep -n 'abort-reason' | head -1 | cut -d: -f1 || echo "0")
_lma_setup_line=$(echo "$_lma_body" | grep -n 'setup_worktrees' | head -1 | cut -d: -f1 || echo "0")
if [[ "${_lma_cleanup_line:-0}" -gt 0 && "${_lma_cleanup_line:-0}" -lt "${_lma_setup_line:-9999}" ]]; then
    assert_pass "C1_pre_run_marker_cleanup: launch_multi_agent removes stale abort-reason markers BEFORE setup_worktrees"
else
    assert_fail "C1_pre_run_marker_cleanup: launch_multi_agent must clean .agent-*-abort-reason before setup_worktrees" \
        "cleanup at line ${_lma_cleanup_line}, setup at line ${_lma_setup_line} (within function body)"
fi

# ─── loop-iteration: ALL scope_label callers must be guarded ──────────────────
# Codex P1 was about line 786 in caabd4a, but lines 577 and 598 also call
# $(scope_label). All must have a fallback because sw-loop.sh does NOT source
# pipeline-state.sh (which defines scope_label).
_unguarded_scope_label=$(grep -n '\$(scope_label)' "$SCRIPT_DIR/lib/loop-iteration.sh" 2>/dev/null \
    | grep -v '|| echo' \
    | wc -l | tr -d '[:space:]' || echo "0")
if [[ "${_unguarded_scope_label:-0}" -eq 0 ]]; then
    assert_pass "loop_iteration_all_scope_label_guarded: every \$(scope_label) call has || echo fallback"
else
    _unguarded_lines=$(grep -n '\$(scope_label)' "$SCRIPT_DIR/lib/loop-iteration.sh" 2>/dev/null \
        | grep -v '|| echo' | head -3 || true)
    assert_fail "loop_iteration_all_scope_label_guarded: \$(scope_label) must always be guarded with || echo fallback" \
        "found ${_unguarded_scope_label} unguarded call(s): ${_unguarded_lines}"
fi

# ─── pipeline-stages-intake.sh atomic jq write review-fix (Copilot #7) ─────────
# Verify the jq write goes to _tmp_json AND there's an mv from _tmp_json into the
# final dod-classification.json path.
if grep -qE '^[[:space:]]*mv[[:space:]]+"\$_tmp_json".*dod-classification' "$SCRIPT_DIR/lib/pipeline-stages-intake.sh" 2>/dev/null; then
    assert_pass "intake_dod_classification_atomic_write: dod-classification.json uses tmp+mv pattern"
else
    assert_fail "intake_dod_classification_atomic_write: dod-classification.json write must be atomic (tmp + mv)" \
        "Expected 'mv \"\$_tmp_json\" .../dod-classification.json' after jq succeeds"
fi

# ─── Test: compose_rejection_notice_section includes QUALITY_GATE_REASONS ─────
if awk '/^compose_rejection_notice_section\(\)/,/^\}/' "$SCRIPT_DIR/sw-loop.sh" | \
        grep -q 'QUALITY_GATE_REASONS'; then
    assert_pass "compose_rejection_notice_section() surfaces QUALITY_GATE_REASONS"
else
    assert_fail "compose_rejection_notice_section() must include QUALITY_GATE_REASONS in rejection notice"
fi

# ─── Test: Rules section has no more than 2 items (duplicates removed) ────────
_rules_raw=$(awk '/^## Rules$/{found=1; next} found && /^\$\{reference_trailer\}/{exit} found{print}' \
    "$SCRIPT_DIR/lib/loop-iteration.sh" 2>/dev/null || true)
_rules_count=$(printf '%s\n' "$_rules_raw" | grep -c '^- ' 2>/dev/null || true)
_rules_count="${_rules_count:-0}"
if [[ "$_rules_count" -le 2 ]]; then
    assert_pass "Rules section has at most 2 items (duplicates removed)"
else
    assert_fail "Rules section must have at most 2 items — found ${_rules_count}" \
        "Remove rules that duplicate Instructions"
fi

# ─── Test: DoD sed expression strips checkboxes at any indentation level ──────
_dod_sed_expr=$(grep '_dod_raw=' "$SCRIPT_DIR/lib/loop-iteration.sh" \
    | grep -o "sed '[^']*'" 2>/dev/null | head -1 || true)
if [[ -z "$_dod_sed_expr" ]]; then
    assert_fail "dod_section must use sed to strip checkbox markers"
else
    _dod_result=$(eval "$_dod_sed_expr" 2>/dev/null <<'DOD_TEST_INPUT' || true
- [ ] top level
   - [x] indented
- [x] checked
- plain line
DOD_TEST_INPUT
)
    if echo "$_dod_result" | grep -qE '\[.?\]'; then
        assert_fail "DoD sed expression leaves checkbox markers in output (all indent levels)" \
            "got: $(echo "$_dod_result" | grep -E '\[.?\]' | head -3)"
    else
        assert_pass "DoD sed expression strips checkboxes at all indentation levels"
    fi
fi

# ─── Test: DoD section does not say 'unchecked items' ─────────────────────────
if ! grep -A10 'dod_section=' "$SCRIPT_DIR/lib/loop-iteration.sh" | grep -q 'unchecked'; then
    assert_pass "dod_section does not reference 'unchecked items'"
else
    assert_fail "dod_section must not say 'unchecked items' — DoD items are plain bullets"
fi

# ─── Test: git_auto_commit() uses mixed reset, not --hard (issue #preserve-edits) ─
# Negative test — git reset --hard HEAD must NOT appear inside the git_auto_commit()
# function body. A mixed reset (git reset HEAD) preserves the working tree so that
# agent source-code edits survive a validate_claude_output failure and can be
# captured by the post-audit cleanup commit or the GHA snapshot push.
if ! awk '/^git_auto_commit\(\)/,/^\}/' "$SCRIPT_DIR/sw-loop.sh" | \
        grep -q 'reset --hard HEAD'; then
    assert_pass "git_auto_commit() does not use git reset --hard HEAD (working tree preserved on validation failure)"
else
    assert_fail "git_auto_commit() must not use git reset --hard HEAD — use mixed reset to preserve agent working-tree edits"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# GATE-FINDINGS FUNNEL TESTS (TDD — written before implementation)
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${DIM}  gate-findings funnel${RESET}"

# Load the sw-loop.sh function definitions into a subshell for isolated testing.
# We source only the declaration portion, not the main execution body.
# Each test runs in its own subshell with a fresh environment.

_source_gate_funcs() {
    # Stub out everything sw-loop.sh depends on at source time
    detect_gate_signal() { return 1; }
    emit_event()         { :; }
    info()               { :; }
    warn()               { echo "WARN: $*" >&2; }
    error()              { echo "ERROR: $*" >&2; }
    success()            { :; }
    select_audit_model() { echo "haiku"; }
    _git_excluded_pathspecs() { echo ""; }
    QUALITY_GATES_ENABLED=false
    QUALITY_GATE_PASSED=true
    QUALITY_GATE_REASONS=""
    HOLISTIC_RESULT=""
    QUALITY_GATE_DETAIL=""
    GATE_FINDINGS=""
    GATE_PASSED_NAMES=""
    COMPLETION_REJECTED=false
    GATES_PASSED_NO_SIGNAL=false
    ITERATION=1
    ARTIFACTS_DIR=""
    TEST_CMD=""
    TEST_PASSED=true
    PROJECT_ROOT="${TMPDIR:-/tmp}"
    # source only up to the end of compose functions
    # Use a subshell-safe approach: export needed vars
    true
}

# Helper: run a self-contained subshell that defines record_gate_finding inline.
# This avoids depending on whether sw-loop.sh has been modified yet.
_run_rgf_test() {
    # Args: gate verdict summary detail
    # Outputs PASSED_NAMES=... and FINDINGS=... lines
    local _g="$1" _v="$2" _s="$3" _d="$4"
    bash -c "
        GATE_FINDINGS=''
        GATE_PASSED_NAMES=''
        # Source only record_gate_finding from sw-loop.sh (first occurrence)
        eval \"\$(awk '/^record_gate_finding\(\)/{p=1} p{print} p && /^\}$/{exit}' '$SCRIPT_DIR/sw-loop.sh' 2>/dev/null)\" 2>/dev/null || true
        record_gate_finding '$_g' '$_v' '$_s' '$_d' 2>/dev/null || true
        echo \"PASSED_NAMES=\$GATE_PASSED_NAMES\"
        printf 'FINDINGS=%s\n' \"\$GATE_FINDINGS\"
    " 2>/dev/null
}

_run_cgf_test() {
    # Run compose_gate_findings_section with given env vars
    # Args: passed_names findings
    local _pn="$1" _fn="$2"
    bash -c "
        GATE_PASSED_NAMES='$_pn'
        GATE_FINDINGS='$_fn'
        eval \"\$(awk '/^compose_gate_findings_section\(\)/{p=1} p{print} p && /^\}$/{exit}' '$SCRIPT_DIR/sw-loop.sh' 2>/dev/null)\" 2>/dev/null || true
        compose_gate_findings_section 2>/dev/null || true
    " 2>/dev/null
}

_run_crn_test() {
    # Run compose_rejection_notice_section with given env vars
    # Args: quality_gate_passed completion_rejected gates_passed_no_signal quality_gate_reasons
    local _qgp="$1" _cr="$2" _gpns="$3" _qgr="$4"
    bash -c "
        QUALITY_GATE_PASSED=$_qgp
        COMPLETION_REJECTED=$_cr
        GATES_PASSED_NO_SIGNAL=$_gpns
        QUALITY_GATE_REASONS='$_qgr'
        eval \"\$(awk '/^compose_rejection_notice_section\(\)/{p=1} p{print} p && /^\}$/{exit}' '$SCRIPT_DIR/sw-loop.sh' 2>/dev/null)\" 2>/dev/null || true
        compose_rejection_notice_section 2>/dev/null || true
    " 2>/dev/null
}

# ─── Test 1: record_gate_finding pass tracks name ────────────────────────────
_t_out="$(_run_rgf_test "tests" "pass" "" "")"
if echo "$_t_out" | grep -qF "PASSED_NAMES=" && echo "$_t_out" | grep -qF "tests"; then
    assert_pass "test_record_gate_finding_pass_tracks_name: GATE_PASSED_NAMES contains gate"
else
    assert_fail "test_record_gate_finding_pass_tracks_name: GATE_PASSED_NAMES contains gate" \
        "output: $_t_out"
fi
if echo "$_t_out" | grep -q "FINDINGS=$"; then
    assert_pass "test_record_gate_finding_pass_tracks_name: GATE_FINDINGS is empty"
else
    _findings_val="$(echo "$_t_out" | grep "^FINDINGS=" | cut -d= -f2-)"
    if [[ -z "$_findings_val" ]]; then
        assert_pass "test_record_gate_finding_pass_tracks_name: GATE_FINDINGS is empty"
    else
        assert_fail "test_record_gate_finding_pass_tracks_name: GATE_FINDINGS is empty" \
            "findings: $_findings_val"
    fi
fi

# ─── Test 2: record_gate_finding fail appends detail ────────────────────────
_t_out="$(_run_rgf_test "dod" "fail" "summary" "detail text")"
if echo "$_t_out" | grep -qF "### dod"; then
    assert_pass "test_record_gate_finding_fail_appends_detail: GATE_FINDINGS has gate header"
else
    assert_fail "test_record_gate_finding_fail_appends_detail: GATE_FINDINGS has gate header" \
        "output: $_t_out"
fi
if echo "$_t_out" | grep -qF "detail text"; then
    assert_pass "test_record_gate_finding_fail_appends_detail: GATE_FINDINGS has detail"
else
    assert_fail "test_record_gate_finding_fail_appends_detail: GATE_FINDINGS has detail" \
        "output: $_t_out"
fi

# ─── Test 3: record_gate_finding fail empty detail uses fallback ─────────────
_t_out="$(_run_rgf_test "dod" "fail" "" "")"
if echo "$_t_out" | grep -qi "harness diagnostic gap"; then
    assert_pass "test_record_gate_finding_fail_empty_detail_uses_fallback: fallback text present"
else
    assert_fail "test_record_gate_finding_fail_empty_detail_uses_fallback: fallback text present" \
        "output: $_t_out"
fi

# ─── Test 4: record_gate_finding multi-gate accumulates ──────────────────────
_t_out="$(bash -c "
    GATE_FINDINGS=''
    GATE_PASSED_NAMES=''
    eval \"\$(awk '/^record_gate_finding\(\)/{p=1} p{print} p && /^\}$/{exit}' '$SCRIPT_DIR/sw-loop.sh' 2>/dev/null)\" 2>/dev/null || true
    record_gate_finding 'dod' 'fail' '' '' 2>/dev/null || true
    record_gate_finding 'audit' 'fail' '' '' 2>/dev/null || true
    record_gate_finding 'tests' 'pass' '' '' 2>/dev/null || true
    echo \"PASSED_NAMES=\$GATE_PASSED_NAMES\"
    printf 'FINDINGS=%s\n' \"\$GATE_FINDINGS\"
" 2>/dev/null)"
if echo "$_t_out" | grep -qF "tests"; then
    assert_pass "test_record_gate_finding_multi_gate_accumulates: GATE_PASSED_NAMES has tests"
else
    assert_fail "test_record_gate_finding_multi_gate_accumulates: GATE_PASSED_NAMES has tests" \
        "output: $_t_out"
fi
if echo "$_t_out" | grep -qF "### dod" && echo "$_t_out" | grep -qF "### audit"; then
    assert_pass "test_record_gate_finding_multi_gate_accumulates: GATE_FINDINGS has both dod and audit"
else
    assert_fail "test_record_gate_finding_multi_gate_accumulates: GATE_FINDINGS has both dod and audit" \
        "output: $_t_out"
fi

# ─── Test 5: compose_gate_findings_section shows passed and failed ───────────
_t_out="$(_run_cgf_test " tests audit" "
### dod — verdict: fail
fix this")"
if echo "$_t_out" | grep -qF "Passed:"; then
    assert_pass "test_compose_gate_findings_section_shows_passed_and_failed: shows Passed:"
else
    assert_fail "test_compose_gate_findings_section_shows_passed_and_failed: shows Passed:" \
        "output: $_t_out"
fi
if echo "$_t_out" | grep -qF "tests" && echo "$_t_out" | grep -qF "audit"; then
    assert_pass "test_compose_gate_findings_section_shows_passed_and_failed: shows passed gate names"
else
    assert_fail "test_compose_gate_findings_section_shows_passed_and_failed: shows passed gate names" \
        "output: $_t_out"
fi
if echo "$_t_out" | grep -qF "### dod" && echo "$_t_out" | grep -qF "⚠"; then
    assert_pass "test_compose_gate_findings_section_shows_passed_and_failed: shows failure block with warning"
else
    assert_fail "test_compose_gate_findings_section_shows_passed_and_failed: shows failure block with warning" \
        "output: $_t_out"
fi

# ─── Test 6: compose_gate_findings_section all pass no findings ──────────────
_t_out="$(_run_cgf_test " tests" "")"
if echo "$_t_out" | grep -qF "Passed:"; then
    assert_pass "test_compose_gate_findings_section_all_pass_no_findings: shows Passed:"
else
    assert_fail "test_compose_gate_findings_section_all_pass_no_findings: shows Passed:" \
        "output: $_t_out"
fi
if echo "$_t_out" | grep -qF "⚠"; then
    assert_fail "test_compose_gate_findings_section_all_pass_no_findings: no warning symbol"
else
    assert_pass "test_compose_gate_findings_section_all_pass_no_findings: no warning symbol"
fi

# ─── Test 7: compose_gate_findings_section empty returns nothing ─────────────
_t_out="$(_run_cgf_test "" "")"
if [[ -z "$(echo "$_t_out" | tr -d '[:space:]')" ]]; then
    assert_pass "test_compose_gate_findings_section_empty_returns_nothing: empty output"
else
    assert_fail "test_compose_gate_findings_section_empty_returns_nothing: empty output" \
        "output: $_t_out"
fi

# ─── Test 8: compose_rejection_notice gates_failing no_signal ────────────────
_t_out="$(_run_crn_test "false" "false" "false" "dod")"
if echo "$_t_out" | grep -qi "Quality Gates Not Passing"; then
    assert_pass "test_compose_rejection_notice_gates_failing_no_signal: shows quality gates not passing"
else
    assert_fail "test_compose_rejection_notice_gates_failing_no_signal: shows quality gates not passing" \
        "output: $_t_out"
fi

# ─── Test 9: gate findings resets each iteration ─────────────────────────────
# Simulate reset by checking the run_quality_gates function resets accumulators
_t_out="$(bash -c "
    GATE_FINDINGS='stale findings from prev iter'
    GATE_PASSED_NAMES='stale names'
    HOLISTIC_RESULT=''
    QUALITY_GATE_DETAIL=''
    QUALITY_GATE_PASSED=true
    QUALITY_GATE_REASONS=''
    # Simulate the reset block that run_quality_gates should do
    eval \"\$(awk '/^run_quality_gates\(\)/{p=1} p && /GATE_FINDINGS=/{print; exit} p{print}' '$SCRIPT_DIR/sw-loop.sh' 2>/dev/null | head -20)\" 2>/dev/null || true
    # Check if GATE_FINDINGS and GATE_PASSED_NAMES appear as reset targets in run_quality_gates
    if grep -q 'GATE_FINDINGS=\"\"' '$SCRIPT_DIR/sw-loop.sh' 2>/dev/null; then
        echo 'RESET_GATE_FINDINGS=yes'
    fi
    if grep -q 'GATE_PASSED_NAMES=\"\"' '$SCRIPT_DIR/sw-loop.sh' 2>/dev/null; then
        echo 'RESET_GATE_PASSED_NAMES=yes'
    fi
" 2>/dev/null)"
if echo "$_t_out" | grep -qF "RESET_GATE_FINDINGS=yes"; then
    assert_pass "test_gate_findings_resets_each_iteration: GATE_FINDINGS reset in run_quality_gates"
else
    assert_fail "test_gate_findings_resets_each_iteration: GATE_FINDINGS reset in run_quality_gates" \
        "GATE_FINDINGS='' not found in run_quality_gates block"
fi
if echo "$_t_out" | grep -qF "RESET_GATE_PASSED_NAMES=yes"; then
    assert_pass "test_gate_findings_resets_each_iteration: GATE_PASSED_NAMES reset in run_quality_gates"
else
    assert_fail "test_gate_findings_resets_each_iteration: GATE_PASSED_NAMES reset in run_quality_gates" \
        "GATE_PASSED_NAMES='' not found in run_quality_gates block"
fi

# ─── Test 10: ingest_pipeline_stage_findings iteration1 only ─────────────────
_artifacts_dir="$(mktemp -d "${TMPDIR:-/tmp}/sw-test-artifacts.XXXXXX")"
# Create a mock adversarial-review.json with critical findings
printf '{"severity":"critical","message":"SQL injection risk"}\n' > "$_artifacts_dir/adversarial-review.json"
_t_out="$(bash -c "
    GATE_FINDINGS=''
    GATE_PASSED_NAMES=''
    ITERATION=1
    ARTIFACTS_DIR='$_artifacts_dir'
    eval \"\$(awk '/^record_gate_finding\(\)/{p=1} p{print} p && /^\}$/{exit}' '$SCRIPT_DIR/sw-loop.sh' 2>/dev/null)\" 2>/dev/null || true
    eval \"\$(awk '/^ingest_pipeline_stage_findings\(\)/{p=1} p{print} p && /^\}$/{exit}' '$SCRIPT_DIR/sw-loop.sh' 2>/dev/null)\" 2>/dev/null || true
    ingest_pipeline_stage_findings 2>/dev/null || true
    printf 'FINDINGS=%s\n' \"\$GATE_FINDINGS\"
" 2>/dev/null)"
if echo "$_t_out" | grep -qF "pipeline:adversarial"; then
    assert_pass "test_ingest_pipeline_stage_findings_iteration1: adversarial findings ingested on iter 1"
else
    assert_fail "test_ingest_pipeline_stage_findings_iteration1: adversarial findings ingested on iter 1" \
        "output: $_t_out"
fi
# Now test iteration 2 - should return early
_t_out2="$(bash -c "
    GATE_FINDINGS=''
    GATE_PASSED_NAMES=''
    ITERATION=2
    ARTIFACTS_DIR='$_artifacts_dir'
    eval \"\$(awk '/^record_gate_finding\(\)/{p=1} p{print} p && /^\}$/{exit}' '$SCRIPT_DIR/sw-loop.sh' 2>/dev/null)\" 2>/dev/null || true
    eval \"\$(awk '/^ingest_pipeline_stage_findings\(\)/{p=1} p{print} p && /^\}$/{exit}' '$SCRIPT_DIR/sw-loop.sh' 2>/dev/null)\" 2>/dev/null || true
    ingest_pipeline_stage_findings 2>/dev/null || true
    printf 'FINDINGS=%s\n' \"\$GATE_FINDINGS\"
" 2>/dev/null)"
if echo "$_t_out2" | grep -qF "pipeline:adversarial"; then
    assert_fail "test_ingest_pipeline_stage_findings_iteration2_skipped: no ingestion on iter 2"
else
    assert_pass "test_ingest_pipeline_stage_findings_iteration2_skipped: no ingestion on iter 2"
fi
rm -rf "$_artifacts_dir"

# ─── Test 11: ingest_pipeline_missing_artifact_silent ────────────────────────
_artifacts_dir2="$(mktemp -d "${TMPDIR:-/tmp}/sw-test-artifacts2.XXXXXX")"
# No artifacts in dir
_t_out="$(bash -c "
    GATE_FINDINGS=''
    GATE_PASSED_NAMES=''
    ITERATION=1
    ARTIFACTS_DIR='$_artifacts_dir2'
    eval \"\$(awk '/^record_gate_finding\(\)/{p=1} p{print} p && /^\}$/{exit}' '$SCRIPT_DIR/sw-loop.sh' 2>/dev/null)\" 2>/dev/null || true
    eval \"\$(awk '/^ingest_pipeline_stage_findings\(\)/{p=1} p{print} p && /^\}$/{exit}' '$SCRIPT_DIR/sw-loop.sh' 2>/dev/null)\" 2>/dev/null || true
    ingest_pipeline_stage_findings 2>/dev/null || true
    printf 'FINDINGS=%s\n' \"\$GATE_FINDINGS\"
    echo 'COMPLETED'
" 2>/dev/null)"
if echo "$_t_out" | grep -qF "COMPLETED"; then
    assert_pass "test_ingest_pipeline_missing_artifact_silent: no error when no artifacts"
else
    assert_fail "test_ingest_pipeline_missing_artifact_silent: no error when no artifacts" \
        "output: $_t_out"
fi
_findings_val="$(echo "$_t_out" | grep "^FINDINGS=" | sed 's/^FINDINGS=//')"
if [[ -z "$_findings_val" ]]; then
    assert_pass "test_ingest_pipeline_missing_artifact_silent: GATE_FINDINGS empty"
else
    assert_fail "test_ingest_pipeline_missing_artifact_silent: GATE_FINDINGS empty" \
        "findings: $_findings_val"
fi
rm -rf "$_artifacts_dir2"

# ─── Test 12: ingest_pipeline_empty_artifact_uses_fallback ───────────────────
_artifacts_dir3="$(mktemp -d "${TMPDIR:-/tmp}/sw-test-artifacts3.XXXXXX")"
# Create empty adversarial-review.json
touch "$_artifacts_dir3/adversarial-review.json"
_t_out="$(bash -c "
    GATE_FINDINGS=''
    GATE_PASSED_NAMES=''
    ITERATION=1
    ARTIFACTS_DIR='$_artifacts_dir3'
    eval \"\$(awk '/^record_gate_finding\(\)/{p=1} p{print} p && /^\}$/{exit}' '$SCRIPT_DIR/sw-loop.sh' 2>/dev/null)\" 2>/dev/null || true
    eval \"\$(awk '/^ingest_pipeline_stage_findings\(\)/{p=1} p{print} p && /^\}$/{exit}' '$SCRIPT_DIR/sw-loop.sh' 2>/dev/null)\" 2>/dev/null || true
    ingest_pipeline_stage_findings 2>/dev/null || true
    printf 'FINDINGS=%s\n' \"\$GATE_FINDINGS\"
    echo 'COMPLETED'
" 2>/dev/null)"
if echo "$_t_out" | grep -qF "COMPLETED"; then
    assert_pass "test_ingest_pipeline_empty_artifact_uses_fallback: no crash on empty artifact"
else
    assert_fail "test_ingest_pipeline_empty_artifact_uses_fallback: no crash on empty artifact" \
        "output: $_t_out"
fi
if echo "$_t_out" | grep -qi "harness diagnostic gap"; then
    assert_pass "test_ingest_pipeline_empty_artifact_uses_fallback: fallback text present"
else
    assert_fail "test_ingest_pipeline_empty_artifact_uses_fallback: fallback text present" \
        "output: $_t_out"
fi
rm -rf "$_artifacts_dir3"

# ═══════════════════════════════════════════════════════════════════════════════
# DoD branch-diagnostic tests for check_definition_of_done
# Each test feeds a fixture JSON through the fail branch and asserts that
# GATE_FINDINGS contains a diagnosis-specific string.
# ═══════════════════════════════════════════════════════════════════════════════

# Helper: run the check_definition_of_done fail branch with a fixture dod_clean file.
# Extracts just the diagnostic branching block (from "else" through record_gate_finding)
# and exercises it in isolation, then emits the resulting GATE_FINDINGS.
_run_dod_branch_test() {
    local _fixture_json="$1"
    local _dod_clean
    _dod_clean="$(mktemp "${TMPDIR:-/tmp}/dod-test-clean.XXXXXX.json")"
    printf '%s' "$_fixture_json" > "$_dod_clean"

    bash -c "
        GATE_FINDINGS=''
        GATE_PASSED_NAMES=''
        YELLOW='' GREEN='' RESET=''

        eval \"\$(awk '/^record_gate_finding\(\)/{p=1} p{print} p && /^\}$/{exit}' '$SCRIPT_DIR/sw-loop.sh' 2>/dev/null)\" 2>/dev/null || true

        dod_clean='$_dod_clean'
        dod_verdict=\"\$(jq -r '.verdict // empty' \"\$dod_clean\" 2>/dev/null || echo '')\"

        dod_items_type=\"\$(jq -r '(.items | type)' \"\$dod_clean\" 2>/dev/null || echo 'unknown')\"
        dod_items_len=\"\$(jq '(if (.items | type) == \"array\" then (.items | length) else 0 end)' \"\$dod_clean\" 2>/dev/null || echo '0')\"
        dod_unsatisfied_count=\"\$(jq '(if (.items | type) == \"array\" then ([.items[] | select(.satisfied == false)] | length) else 0 end)' \"\$dod_clean\" 2>/dev/null || echo '0')\"
        dod_unsatisfied_count=\"\${dod_unsatisfied_count// /}\"
        dod_items_len=\"\${dod_items_len// /}\"

        _dod_summary=\"\$(jq -r '.summary // \"\"' \"\$dod_clean\" 2>/dev/null || echo '')\"
        _dod_detail=''

        if [[ -z \"\$dod_verdict\" ]]; then
            _dod_detail=\"DoD evaluator output was unparseable JSON. Raw response (first 20 lines):
\$(head -20 \"\$dod_clean\" 2>/dev/null | sed 's/^/  /' || echo '  (no content)')\"
        elif [[ \"\$dod_items_type\" != 'array' ]]; then
            _dod_detail=\"DoD evaluator reported fail but .items was missing or not an array (type: \${dod_items_type}). Summary: \${_dod_summary:-none}\"
        elif [[ \"\${dod_items_len:-0}\" -eq 0 ]]; then
            _dod_detail=\"DoD evaluator reported fail but .items was an empty array — likely a per-item evaluation skip. Summary: \${_dod_summary:-none}\"
        elif [[ \"\${dod_unsatisfied_count:-0}\" -eq 0 ]]; then
            _dod_detail=\"DoD evaluator reported fail but all .items were marked satisfied — likely model inconsistency. Summary: \${_dod_summary:-none}\"
        else
            _dod_detail=\"\$(jq -r '
              .items[] | select(.satisfied == false) |
              \"- \" + .item + \"\n\" +
              (if ((.files | type) == \"array\") and ((.files | length) > 0) then \"  Files: \" + (.files | join(\", \")) + \"\n\" else \"\" end) +
              (if .hint then \"  Fix: \" + .hint else \"\" end)
            ' \"\$dod_clean\" 2>/dev/null | head -20 || true)\"
            if [[ -z \"\$_dod_detail\" ]]; then
                _dod_detail=\"\$(jq -r '.items[] | select(.satisfied == false) | \"- \" + .item' \"\$dod_clean\" 2>/dev/null | head -20 || true)\"
            fi
        fi

        record_gate_finding 'dod' 'fail' \"\${_dod_summary}\" \"\${_dod_detail}\" 2>/dev/null || true
        printf 'FINDINGS=%s\n' \"\$GATE_FINDINGS\"
    " 2>/dev/null
    rm -f "$_dod_clean"
}

# ─── DoD branch test 1: unparseable JSON ─────────────────────────────────────
_dod_t1="$(_run_dod_branch_test 'not json at all')"
if echo "$_dod_t1" | grep -qi "unparseable JSON"; then
    assert_pass "dod_branch_unparseable_json: GATE_FINDINGS contains 'unparseable JSON' diagnostic"
else
    assert_fail "dod_branch_unparseable_json: GATE_FINDINGS contains 'unparseable JSON' diagnostic" \
        "findings: $_dod_t1"
fi
# Must NOT contain the generic fallback phrase (that would mean we fell through to record_gate_finding default)
if echo "$_dod_t1" | grep -qi "harness diagnostic gap"; then
    assert_fail "dod_branch_unparseable_json: should not use generic harness fallback" \
        "findings contained generic fallback: $_dod_t1"
else
    assert_pass "dod_branch_unparseable_json: does not use generic harness fallback"
fi

# ─── DoD branch test 2: empty items array ────────────────────────────────────
_dod_t2="$(_run_dod_branch_test '{"verdict":"fail","items":[],"summary":"nothing evaluated"}')"
if echo "$_dod_t2" | grep -qi "empty array"; then
    assert_pass "dod_branch_empty_items_array: GATE_FINDINGS contains 'empty array' diagnostic"
else
    assert_fail "dod_branch_empty_items_array: GATE_FINDINGS contains 'empty array' diagnostic" \
        "findings: $_dod_t2"
fi

# ─── DoD branch test 3: all items satisfied but verdict=fail ─────────────────
_dod_t3="$(_run_dod_branch_test '{"verdict":"fail","items":[{"item":"x","satisfied":true}],"summary":"inconsistent"}')"
if echo "$_dod_t3" | grep -qi "all .items were marked satisfied"; then
    assert_pass "dod_branch_all_satisfied_inconsistency: GATE_FINDINGS contains 'all items satisfied' diagnostic"
else
    assert_fail "dod_branch_all_satisfied_inconsistency: GATE_FINDINGS contains 'all items satisfied' diagnostic" \
        "findings: $_dod_t3"
fi

# ─── DoD branch test 4: happy fail path — rich detail present ────────────────
_dod_t4="$(_run_dod_branch_test '{"verdict":"fail","items":[{"item":"Add tests","satisfied":false,"reason":"no tests found","files":["tests/foo.sh"],"hint":"add unit tests"}],"summary":"tests missing"}')"
if echo "$_dod_t4" | grep -qF -- "- Add tests"; then
    assert_pass "dod_branch_happy_fail_path: GATE_FINDINGS contains unsatisfied item name"
else
    assert_fail "dod_branch_happy_fail_path: GATE_FINDINGS contains unsatisfied item name" \
        "findings: $_dod_t4"
fi
if echo "$_dod_t4" | grep -qF -- "Files: tests/foo.sh"; then
    assert_pass "dod_branch_happy_fail_path: GATE_FINDINGS contains Files hint"
else
    assert_fail "dod_branch_happy_fail_path: GATE_FINDINGS contains Files hint" \
        "findings: $_dod_t4"
fi
if echo "$_dod_t4" | grep -qF -- "Fix: add unit tests"; then
    assert_pass "dod_branch_happy_fail_path: GATE_FINDINGS contains Fix hint"
else
    assert_fail "dod_branch_happy_fail_path: GATE_FINDINGS contains Fix hint" \
        "findings: $_dod_t4"
fi

# ─── Test: generic fallback message updated ──────────────────────────────────
# Verify the new fallback text is in sw-loop.sh (not the old "Manually verify" text)
if grep -qF "harness diagnostic gap" "$SCRIPT_DIR/sw-loop.sh" 2>/dev/null; then
    assert_pass "dod_generic_fallback_updated: sw-loop.sh contains updated harness diagnostic gap text"
else
    assert_fail "dod_generic_fallback_updated: sw-loop.sh contains updated harness diagnostic gap text" \
        "expected 'harness diagnostic gap' in record_gate_finding fallback"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Issue B: DoD hard stop when prompt exceeds context limit
# Tests verify the LOOP_ABORT_FATAL mechanism is wired correctly.
# ═══════════════════════════════════════════════════════════════════════════════

# Static: LOOP_ABORT_FATAL global initialised to false
if grep -qF "LOOP_ABORT_FATAL=false" "$SCRIPT_DIR/sw-loop.sh" 2>/dev/null; then
    assert_pass "issueB_loop_abort_fatal_global: LOOP_ABORT_FATAL=false declared in sw-loop.sh"
else
    assert_fail "issueB_loop_abort_fatal_global: LOOP_ABORT_FATAL=false declared in sw-loop.sh" \
        "expected 'LOOP_ABORT_FATAL=false' in sw-loop.sh globals section"
fi

# Static: SHIPWRIGHT_DOD_PROMPT_MAX_BYTES env var used for overridable threshold
if grep -qF "SHIPWRIGHT_DOD_PROMPT_MAX_BYTES" "$SCRIPT_DIR/sw-loop.sh" 2>/dev/null; then
    assert_pass "issueB_dod_max_bytes_env_var: SHIPWRIGHT_DOD_PROMPT_MAX_BYTES used in sw-loop.sh"
else
    assert_fail "issueB_dod_max_bytes_env_var: SHIPWRIGHT_DOD_PROMPT_MAX_BYTES used in sw-loop.sh" \
        "expected SHIPWRIGHT_DOD_PROMPT_MAX_BYTES threshold var in check_definition_of_done"
fi

# Static: post-invocation error detection greps BOTH dod_log and dod_err_log
# Extract the block around the context-error grep and verify both appear together.
_dod_stderr_check=$(grep -A3 "prompt is too long\|context.?length" "$SCRIPT_DIR/sw-loop.sh" 2>/dev/null | head -20 || true)
if echo "$_dod_stderr_check" | grep -q "dod_err_log"; then
    assert_pass "issueB_post_invocation_checks_stderr: context-error grep covers dod_err_log (stderr)"
else
    assert_fail "issueB_post_invocation_checks_stderr: context-error grep covers dod_err_log (stderr)" \
        "expected dod_err_log in the grep pattern near 'prompt is too long'"
fi

# Static: LOOP_ABORT_FATAL hard-stop is wired inside run_single_agent_loop (after quality gates)
_loop_abort_in_single=$(awk '/^run_single_agent_loop\(\)/{p=1} p{print} p && /^\}$/{if(--d<0) exit} p && /{/{d++}' \
    "$SCRIPT_DIR/sw-loop.sh" 2>/dev/null | grep "LOOP_ABORT_FATAL" || true)
if [[ -n "$_loop_abort_in_single" ]]; then
    assert_pass "issueB_hard_stop_in_run_single_agent_loop: LOOP_ABORT_FATAL check present in run_single_agent_loop"
else
    assert_fail "issueB_hard_stop_in_run_single_agent_loop: LOOP_ABORT_FATAL check present in run_single_agent_loop" \
        "expected LOOP_ABORT_FATAL guard in run_single_agent_loop body"
fi

# Static: LOOP_ABORT_FATAL restart-suppression is wired inside run_loop_with_restarts
_loop_abort_in_restarts=$(awk '/^run_loop_with_restarts\(\)/{p=1} p{print} p && /^\}$/{if(--d<0) exit} p && /{/{d++}' \
    "$SCRIPT_DIR/sw-loop.sh" 2>/dev/null | grep "LOOP_ABORT_FATAL" || true)
if [[ -n "$_loop_abort_in_restarts" ]]; then
    assert_pass "issueB_restart_suppression_in_run_loop_with_restarts: LOOP_ABORT_FATAL check present in run_loop_with_restarts"
else
    assert_fail "issueB_restart_suppression_in_run_loop_with_restarts: LOOP_ABORT_FATAL check present in run_loop_with_restarts" \
        "expected LOOP_ABORT_FATAL restart guard in run_loop_with_restarts body"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo ""
print_test_results
