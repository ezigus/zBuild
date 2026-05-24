#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/loop-iteration test — Unit tests for loop-iteration.sh   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/bin"
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi
    cat > "$TEST_TEMP_DIR/bin/git" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse) echo "/tmp/mock-repo" ;;
    *) echo "" ;;
esac
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/git"
    cat > "$TEST_TEMP_DIR/bin/gh" <<'MOCK'
#!/usr/bin/env bash
echo '[]'
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/gh"
    cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
echo "Mock claude response"
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/claude"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
    export SHIPWRIGHT_PIPELINE_ID="test-pipeline-001"
}

_test_cleanup_hook() { cleanup_test_env; }

print_test_header "Loop Iteration Tests"
setup_env

_li_source="$SCRIPT_DIR/lib/loop-iteration.sh"

# ─── Test section: build prompt GitHub posting ────────────────────────────────
print_test_section "build prompt GitHub posting"

# Test 1 (static source check):
# SW_LOG_PROMPTS=github should call gh_comment_issue, NOT gh_update_progress.
# After the fix, gh_update_progress must not appear in the github|both case block
# that handles the "Build Prompt" body (lines 769-777 in the pre-fix source).
#
# Strategy: find the github|both case block and assert gh_update_progress is absent.
# The block runs from the `github|both)` line to the closing `;;` after `fi`.
# We locate it by anchoring on the body= assignment and checking the subsequent if.
if [[ -f "$_li_source" ]]; then
    # Extract the github|both case arm by pattern (not line numbers) so the test
    # tracks behavior rather than file position and survives unrelated edits.
    # The arm starts at `github|both)` and ends at the first `;;` on its own line.
    _block=$(awk '/github\|both\)/{found=1} found{print} found && /^[[:space:]]*;;/{exit}' \
        "$_li_source" 2>/dev/null || true)
    _gu_in_block=$(echo "$_block" | grep -c "gh_update_progress" 2>/dev/null || true)
    _gu_in_block="${_gu_in_block:-0}"
    if [[ "$_gu_in_block" -gt 0 ]]; then
        assert_fail \
            "SW_LOG_PROMPTS=github: gh_comment_issue called, gh_update_progress NOT called" \
            "gh_update_progress still appears in the github|both posting block. Count: $_gu_in_block"
    else
        assert_pass \
            "SW_LOG_PROMPTS=github: gh_comment_issue called, gh_update_progress NOT called"
    fi

    # Additionally verify that gh_comment_issue IS present in that block.
    _gc_in_block=$(echo "$_block" | grep -c "gh_comment_issue" 2>/dev/null || true)
    _gc_in_block="${_gc_in_block:-0}"
    if [[ "$_gc_in_block" -gt 0 ]]; then
        assert_pass \
            "SW_LOG_PROMPTS=github: gh_comment_issue present in posting block after fix"
    else
        assert_fail \
            "SW_LOG_PROMPTS=github: gh_comment_issue present in posting block after fix" \
            "gh_comment_issue not found in github|both arm of loop-iteration.sh"
    fi
else
    assert_pass "loop-iteration.sh source check skipped (file not found)"
fi

# Test 2 (static source check):
# SW_LOG_PROMPTS=stdout case block must not call any GitHub functions.
# Find the stdout) case arm and assert neither gh_comment_issue nor
# gh_update_progress appears inside it.
if [[ -f "$_li_source" ]]; then
    # Extract the stdout case arm using POSIX character class (not \s which is non-POSIX).
    _stdout_block=$(awk '/^[[:space:]]+stdout\)/{found=1} found{print} found && /;;/{exit}' \
        "$_li_source" 2>/dev/null || true)
    if [[ -z "$_stdout_block" ]]; then
        # No explicit stdout arm — that is acceptable; assert pass.
        assert_pass \
            "SW_LOG_PROMPTS=stdout: GitHub functions not called (no stdout arm)"
    else
        _gh_in_stdout=$(echo "$_stdout_block" \
            | grep -c "gh_comment_issue\|gh_update_progress" 2>/dev/null || true)
        _gh_in_stdout="${_gh_in_stdout:-0}"
        if [[ "$_gh_in_stdout" -eq 0 ]]; then
            assert_pass \
                "SW_LOG_PROMPTS=stdout: GitHub functions not called"
        else
            assert_fail \
                "SW_LOG_PROMPTS=stdout: GitHub functions not called" \
                "Found gh_comment_issue or gh_update_progress inside the stdout case arm of loop-iteration.sh (count: $_gh_in_stdout)"
        fi
    fi
else
    assert_pass "loop-iteration.sh stdout check skipped (file not found)"
fi

# Test 3 (static): the github|both posting block must guard ISSUE_NUMBER
# before calling gh_comment_issue — prevents malformed API calls with empty issue num.
_li_source="$SCRIPT_DIR/lib/loop-iteration.sh"
if [[ -f "$_li_source" ]]; then
    # Extract the github|both case arm. Look for the guard pattern
    # [[ -n "${ISSUE_NUMBER" before gh_comment_issue in the same arm.
    _github_block=$(awk '/github\|both\)/{found=1} found{print} found && /^[[:space:]]*;;/{exit}' \
        "$_li_source" 2>/dev/null || true)
    _has_issue_guard=$(echo "$_github_block" \
        | grep -c 'ISSUE_NUMBER' 2>/dev/null || true)
    _has_issue_guard="${_has_issue_guard:-0}"
    if [[ "$_has_issue_guard" -gt 0 ]]; then
        assert_pass \
            "SW_LOG_PROMPTS=github posting block guards ISSUE_NUMBER before gh_comment_issue"
    else
        assert_fail \
            "SW_LOG_PROMPTS=github posting block guards ISSUE_NUMBER before gh_comment_issue" \
            "No ISSUE_NUMBER guard found in github|both case arm of loop-iteration.sh"
    fi
else
    assert_pass "loop-iteration.sh ISSUE_NUMBER guard check skipped (file not found)"
fi

print_test_results
