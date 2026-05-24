#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright quality test — Validate ruthless quality validation engine   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/bin"
    mkdir -p "$TEST_TEMP_DIR/repo/.git"
    mkdir -p "$TEST_TEMP_DIR/repo/.claude/pipeline-artifacts"

    # Link real utilities
    for cmd in jq date wc cat grep sed awk sort mkdir rm mv cp mktemp basename dirname printf tr cut head tail tee touch find ls bc; do
        command -v "$cmd" &>/dev/null && ln -sf "$(command -v "$cmd")" "$TEST_TEMP_DIR/bin/$cmd"
    done

    # Mock git
    cat > "$TEST_TEMP_DIR/bin/git" <<'MOCKEOF'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse)
        if [[ "${2:-}" == "--show-toplevel" ]]; then echo "/tmp/mock-repo"
        elif [[ "${2:-}" == "--abbrev-ref" ]]; then echo "main"
        else echo "abc1234"; fi ;;
    remote) echo "git@github.com:test/repo.git" ;;
    log) echo "abc1234 Mock commit" ;;
    status) echo "" ;;
    diff) echo "" ;;
    *) echo "mock git: $*" ;;
esac
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/git"

    # Mock gh, claude, tmux
    for mock in gh claude tmux; do
        printf '#!/usr/bin/env bash\necho "mock %s: $*"\nexit 0\n' "$mock" > "$TEST_TEMP_DIR/bin/$mock"
        chmod +x "$TEST_TEMP_DIR/bin/$mock"
    done

    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
}

_test_cleanup_hook() { cleanup_test_env; }

assert_pass() {
    local desc="$1"
    echo -e "  ${GREEN}✓${RESET} ${desc}"
}

assert_fail() {
    local desc="$1"
    local detail="${2:-}"
    FAILURES+=("$desc")
    echo -e "  ${RED}✗${RESET} ${desc}"
    [[ -n "$detail" ]] && echo -e "    ${DIM}${detail}${RESET}"
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    local _count
    _count=$(printf '%s\n' "$haystack" | grep -cF -- "$needle" 2>/dev/null) || true
    if [[ "${_count:-0}" -gt 0 ]]; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "output missing: $needle"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# Tests
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
print_test_header "shipwright quality test suite"
echo ""

setup_env

# ─── 1. Script safety ────────────────────────────────────────────────────────

echo -e "${BOLD}  Script Safety${RESET}"

# set -euo pipefail
if grep -q 'set -euo pipefail' "$SCRIPT_DIR/sw-quality.sh"; then
    assert_pass "set -euo pipefail present"
else
    assert_fail "set -euo pipefail present"
fi

# ERR trap
if grep -q "trap.*ERR" "$SCRIPT_DIR/sw-quality.sh"; then
    assert_pass "ERR trap present"
else
    assert_fail "ERR trap present"
fi

# Source guard
if grep -q 'if \[\[ "${BASH_SOURCE\[0\]}" == "$0" \]\]; then' "$SCRIPT_DIR/sw-quality.sh"; then
    assert_pass "Source guard uses if/then/fi pattern"
else
    assert_fail "Source guard uses if/then/fi pattern"
fi

echo ""

# ─── 2. VERSION ──────────────────────────────────────────────────────────────

echo -e "${BOLD}  Version${RESET}"

if grep -q '^VERSION=' "$SCRIPT_DIR/sw-quality.sh"; then
    assert_pass "VERSION variable defined at top"
else
    assert_fail "VERSION variable defined at top"
fi

# version subcommand
output=$(bash "$SCRIPT_DIR/sw-quality.sh" version 2>&1) || true
assert_contains "version subcommand outputs version" "$output" "shipwright-quality v"

echo ""

# ─── 3. Help ─────────────────────────────────────────────────────────────────

echo -e "${BOLD}  Help${RESET}"

output=$(bash "$SCRIPT_DIR/sw-quality.sh" help 2>&1) || true
assert_contains "help contains USAGE" "$output" "USAGE"
assert_contains "help contains validate subcommand" "$output" "validate"
assert_contains "help contains audit subcommand" "$output" "audit"
assert_contains "help contains completion subcommand" "$output" "completion"
assert_contains "help contains score subcommand" "$output" "score"
assert_contains "help contains gate subcommand" "$output" "gate"
assert_contains "help contains report subcommand" "$output" "report"

# --help flag
output=$(bash "$SCRIPT_DIR/sw-quality.sh" --help 2>&1) || true
assert_contains "--help flag works" "$output" "USAGE"

echo ""

# ─── 4. Unknown command ─────────────────────────────────────────────────────

echo -e "${BOLD}  Error Handling${RESET}"

if bash "$SCRIPT_DIR/sw-quality.sh" nonexistent_cmd 2>/dev/null; then
    assert_fail "unknown command exits non-zero"
else
    assert_pass "unknown command exits non-zero"
fi

output=$(bash "$SCRIPT_DIR/sw-quality.sh" nonexistent_cmd 2>&1) || true
assert_contains "unknown command shows error" "$output" "Unknown subcommand"

echo ""

# ─── 5. Validate subcommand ─────────────────────────────────────────────────

echo -e "${BOLD}  Validate Subcommand${RESET}"

output=$(cd "$TEST_TEMP_DIR/repo" && ARTIFACTS_DIR="$TEST_TEMP_DIR/repo/.claude/pipeline-artifacts" bash "$SCRIPT_DIR/sw-quality.sh" validate 2>&1) || true
assert_contains "validate outputs JSON with checks" "$output" "checks"
assert_contains "validate outputs score" "$output" "score"

echo ""

# ─── 6. Audit subcommand ────────────────────────────────────────────────────

echo -e "${BOLD}  Audit Subcommand${RESET}"

output=$(cd "$TEST_TEMP_DIR/repo" && bash "$SCRIPT_DIR/sw-quality.sh" audit 2>&1) || true
assert_contains "audit mentions security audit" "$output" "Security audit"
assert_contains "audit mentions correctness audit" "$output" "Correctness audit"
assert_contains "audit mentions architecture audit" "$output" "Architecture audit"

echo ""

# ─── 7. Completion subcommand ───────────────────────────────────────────────

echo -e "${BOLD}  Completion Subcommand${RESET}"

output=$(cd "$TEST_TEMP_DIR/repo" && ARTIFACTS_DIR="$TEST_TEMP_DIR/repo/.claude/pipeline-artifacts" bash "$SCRIPT_DIR/sw-quality.sh" completion 2>&1) || true
assert_contains "completion outputs recommendation" "$output" "recommendation"
assert_contains "completion outputs reasoning" "$output" "reasoning"

echo ""

# ─── 8. Score subcommand ────────────────────────────────────────────────────

echo -e "${BOLD}  Score Subcommand${RESET}"

output=$(cd "$TEST_TEMP_DIR/repo" && ARTIFACTS_DIR="$TEST_TEMP_DIR/repo/.claude/pipeline-artifacts" bash "$SCRIPT_DIR/sw-quality.sh" score 2>&1) || true
assert_contains "score outputs components" "$output" "components"
assert_contains "score outputs overall_score" "$output" "overall_score"

echo ""

# ─── 9. Events logging ─────────────────────────────────────────────────────

echo -e "${BOLD}  Events Logging${RESET}"

# Run validate and check events.jsonl
cd "$TEST_TEMP_DIR/repo" && ARTIFACTS_DIR="$TEST_TEMP_DIR/repo/.claude/pipeline-artifacts" bash "$SCRIPT_DIR/sw-quality.sh" validate >/dev/null 2>&1 || true
if [[ -f "$TEST_TEMP_DIR/home/.shipwright/events.jsonl" ]]; then
    assert_pass "events.jsonl created after validate"
    events_content=$(cat "$TEST_TEMP_DIR/home/.shipwright/events.jsonl")
    assert_contains "events contain quality.validate" "$events_content" "quality.validate"
else
    assert_fail "events.jsonl created after validate"
fi

echo ""

# ─── 10. _write_quality_feedback wiring: cascade findings reach quality-feedback.md ──
# Integration-level: seed compound-audit-findings.json with a critical entry,
# call _write_quality_feedback directly (sourced from pipeline-intelligence.sh),
# and assert the "## Blocking Issues" section contains the expected file:line.
# This catches wiring regressions that unit tests cannot catch.

echo -e "${BOLD}  compound-audit-findings.json → quality-feedback.md wiring${RESET}"

(
    set -euo pipefail

    _integ_dir="$(mktemp -d "${TMPDIR:-/tmp}/sw-qw-integ.XXXXXX")"
    _integ_feedback="$_integ_dir/quality-feedback.md"

    # Provide minimal stubs required by pipeline-intelligence.sh on source.
    ARTIFACTS_DIR="$_integ_dir"
    EVENTS_FILE="$_integ_dir/events.jsonl"
    STATE_FILE="$_integ_dir/state.json"
    BASE_BRANCH="main"
    ISSUE_NUMBER="0"
    ISSUE_LABELS=""
    INTELLIGENCE_COMPLEXITY="5"
    PIPELINE_CONFIG="$_integ_dir/pipeline-config.json"
    PIPELINE_NAME="standard"
    PROJECT_ROOT="$_integ_dir"
    IGNORE_BUDGET="true"
    OUTER_STAGE=""
    INNER_STAGE=""
    NO_GITHUB="true"
    SCRIPT_DIR="$SCRIPT_DIR"

    mkdir -p "$_integ_dir"
    echo '{"stages":[{"id":"compound_quality","config":{"audit_intensity":"auto"}}]}' \
        > "$_integ_dir/pipeline-config.json"

    now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
    now_epoch() { date +%s; }
    emit_event() { :; }
    daemon_log() { :; }
    info() { :; }
    success() { :; }
    warn() { :; }
    error() { :; } >&2
    rotate_jsonl() { :; }
    log_stage() { :; }
    write_state() { :; }
    set_outer_stage() { OUTER_STAGE="${1:-}"; INNER_STAGE=""; write_state; }
    clear_outer_stage() { OUTER_STAGE=""; INNER_STAGE=""; write_state; }

    # Clear guard so we can re-source even if the lib was loaded in parent shell.
    _PIPELINE_INTELLIGENCE_LOADED=""
    source "$SCRIPT_DIR/lib/pipeline-intelligence.sh"

    # Seed compound-audit-findings.json with a critical finding (no SHA stamp →
    # pipeline_artifact_is_current treats it as current via pass-through).
    cat > "$_integ_dir/compound-audit-findings.json" <<'EOINTEG'
[{"severity":"critical","file":"wiring/check.sh","line":"99","description":"wiring regression detected","suggestion":"add guard"}]
EOINTEG

    # Call _write_quality_feedback; it will call _extract_blocking_items internally.
    _write_quality_feedback "correctness" "$_integ_feedback"

    _feedback_content="$(cat "$_integ_feedback" 2>/dev/null || true)"
    rm -rf "$_integ_dir"

    # Signal result to parent shell via exit code + printed sentinel.
    if echo "$_feedback_content" | grep -qF "wiring/check.sh:99"; then
        echo "INTEG_WIRING_PASS"
    else
        echo "INTEG_WIRING_FAIL"
    fi
) > /tmp/sw_qw_integ_result.txt 2>/dev/null || true

_integ_result=$(cat /tmp/sw_qw_integ_result.txt 2>/dev/null || true)
rm -f /tmp/sw_qw_integ_result.txt

if [[ "$_integ_result" == "INTEG_WIRING_PASS" ]]; then
    assert_pass "compound-audit-findings.json: critical entry reaches ## Blocking Issues in quality-feedback.md"
else
    assert_fail "compound-audit-findings.json: critical entry reaches ## Blocking Issues in quality-feedback.md" \
        "expected wiring/check.sh:99 in Blocking Issues section"
fi

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# Results
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo ""
print_test_results
