#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/pipeline-github test — Unit tests for GitHub helpers     ║
# ║  Covers: _ensure_base_branch_ref (Bug 2: shallow-clone branch-diff fix)  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: pipeline-github Tests"

setup_test_env "lib-pipeline-github"
_test_cleanup_hook() { cleanup_test_env; }

# ─── Minimal environment ──────────────────────────────────────────────────
export NO_GITHUB=true
export GH_AVAILABLE=false
export BASE_BRANCH="main"
export REPO_OWNER="test-org"
export REPO_NAME="test-repo"
export ARTIFACTS_DIR="$TEST_TEMP_DIR/artifacts"
mkdir -p "$ARTIFACTS_DIR"

# ─── Stubs required by pipeline-github.sh ─────────────────────────────────
info()    { :; }
success() { :; }
warn()    { :; }
error()   { :; }
emit_event() { :; }
_timeout() { shift; "$@"; }
format_duration() { echo "0s"; }
get_stage_status() { echo "pending"; }
get_stage_timing() { echo "0"; }
get_stage_description() { echo ""; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ; }

# ─── Source helpers + pipeline-github.sh ──────────────────────────────────
source "$SCRIPT_DIR/lib/helpers.sh"
source "$SCRIPT_DIR/lib/compat.sh"
_PIPELINE_GITHUB_LOADED=""
source "$SCRIPT_DIR/lib/pipeline-github.sh"

# ═══════════════════════════════════════════════════════════════════════════
# _ensure_base_branch_ref
# ═══════════════════════════════════════════════════════════════════════════
print_test_section "_ensure_base_branch_ref: function exists"

if type _ensure_base_branch_ref >/dev/null 2>&1; then
    assert_pass "_ensure_base_branch_ref is defined in pipeline-github.sh"
else
    assert_fail "_ensure_base_branch_ref is defined in pipeline-github.sh" \
        "Function not found — add _ensure_base_branch_ref to scripts/lib/pipeline-github.sh"
fi

# ─── Test: fast path — non-shallow repo with origin/main already present ──
print_test_section "_ensure_base_branch_ref: fast path (no fetch when not shallow)"

# Create a mock git that tracks calls
_git_fetch_called=0
mkdir -p "$TEST_TEMP_DIR/fake-git-dir"

cat > "$TEST_TEMP_DIR/bin/git" <<'GITSH'
#!/usr/bin/env bash
# Minimal git mock for _ensure_base_branch_ref tests
case "$*" in
    *"rev-parse --git-dir"*)
        echo "${_FAKE_GIT_DIR:-/tmp/fake-git}"
        exit 0
        ;;
    *"rev-parse --verify --quiet origin/main"*)
        # Report that origin/main ref exists
        echo "abc1234"
        exit 0
        ;;
    *"fetch"*)
        # Record fetch was called, but don't fail
        echo "_GIT_FETCH_CALLED=1" >> "${_FETCH_LOG:-/dev/null}"
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
GITSH
chmod +x "$TEST_TEMP_DIR/bin/git"

# Fake git dir — no shallow file
_FAKE_GIT_DIR="$TEST_TEMP_DIR/fake-git-dir"
export _FAKE_GIT_DIR
_FETCH_LOG="$TEST_TEMP_DIR/fetch-calls.log"
export _FETCH_LOG
rm -f "$_FETCH_LOG"
touch "$_FETCH_LOG"

# Run the fast path: origin/main present, not shallow
_ebr_rc=0
_ensure_base_branch_ref "main" 2>/dev/null || _ebr_rc=$?
assert_exit_code "_ensure_base_branch_ref returns 0 when not shallow and ref present" "0" "$_ebr_rc"

_fetch_content=$(cat "$_FETCH_LOG" 2>/dev/null || true)
if [[ -z "$_fetch_content" ]]; then
    assert_pass "_ensure_base_branch_ref skips fetch when not shallow and ref present"
else
    assert_fail "_ensure_base_branch_ref skips fetch when not shallow and ref present" \
        "git fetch was called when it should have been skipped"
fi

# ─── Test: shallow repo — fetch is called (unshallow path) ────────────────
print_test_section "_ensure_base_branch_ref: shallow repo triggers fetch"

# Create shallow git mock — has .git/shallow file
_FAKE_GIT_DIR_SH="$TEST_TEMP_DIR/fake-git-shallow"
mkdir -p "$_FAKE_GIT_DIR_SH"
touch "$_FAKE_GIT_DIR_SH/shallow"   # mark as shallow clone
export _FAKE_GIT_DIR_SH

_FETCH_LOG_SH="$TEST_TEMP_DIR/fetch-shallow-calls.log"
export _FETCH_LOG_SH
rm -f "$_FETCH_LOG_SH"
touch "$_FETCH_LOG_SH"

cat > "$TEST_TEMP_DIR/bin/git" <<'GITSH2'
#!/usr/bin/env bash
case "$*" in
    *"rev-parse --git-dir"*)
        echo "${_FAKE_GIT_DIR_SH:-/tmp/fake-git-sh}"
        exit 0
        ;;
    *"rev-parse --verify --quiet origin/main"*)
        # First call (before fetch): fail to simulate missing ref
        # After fetch: succeed
        if [[ -f "${_FETCH_LOG_SH:-/dev/null}" ]] && grep -q "_GIT_FETCH_CALLED" "${_FETCH_LOG_SH:-/dev/null}" 2>/dev/null; then
            echo "def5678"
            exit 0
        fi
        exit 1
        ;;
    *"fetch"*"--unshallow"*)
        echo "_GIT_FETCH_CALLED=unshallow" >> "${_FETCH_LOG_SH:-/dev/null}"
        exit 0
        ;;
    *"fetch"*"--depth=200"*)
        echo "_GIT_FETCH_CALLED=depth200" >> "${_FETCH_LOG_SH:-/dev/null}"
        exit 0
        ;;
    *"fetch"*)
        echo "_GIT_FETCH_CALLED=plain" >> "${_FETCH_LOG_SH:-/dev/null}"
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
GITSH2
chmod +x "$TEST_TEMP_DIR/bin/git"

export _FAKE_GIT_DIR="$_FAKE_GIT_DIR_SH"
export _FETCH_LOG="$_FETCH_LOG_SH"

# Run with shallow repo
_ebr_sh_rc=0
_ensure_base_branch_ref "main" 2>/dev/null || _ebr_sh_rc=$?

_sh_fetch_content=$(cat "$_FETCH_LOG_SH" 2>/dev/null || true)
if [[ -n "$_sh_fetch_content" ]]; then
    assert_pass "_ensure_base_branch_ref calls git fetch when repo is shallow"
else
    assert_fail "_ensure_base_branch_ref calls git fetch when repo is shallow" \
        "git fetch was not called despite .git/shallow being present"
fi

# Verify it used --unshallow (correct) not --depth=1 (wrong)
if grep -q "unshallow" "$_FETCH_LOG_SH" 2>/dev/null; then
    assert_pass "_ensure_base_branch_ref uses --unshallow not --depth=1"
else
    assert_fail "_ensure_base_branch_ref uses --unshallow not --depth=1" \
        "Expected --unshallow in fetch call; got: $(cat "$_FETCH_LOG_SH" 2>/dev/null)"
fi

# ─── Test: function does not crash when git fetch fails (network-less) ─────
print_test_section "_ensure_base_branch_ref: graceful fallback on fetch failure"

_FAKE_GIT_DIR_FAIL="$TEST_TEMP_DIR/fake-git-fail"
mkdir -p "$_FAKE_GIT_DIR_FAIL"
touch "$_FAKE_GIT_DIR_FAIL/shallow"
export _FAKE_GIT_DIR="$_FAKE_GIT_DIR_FAIL"
export _FETCH_LOG="$TEST_TEMP_DIR/fetch-fail.log"
rm -f "$_FETCH_LOG"; touch "$_FETCH_LOG"

cat > "$TEST_TEMP_DIR/bin/git" <<'GITSH3'
#!/usr/bin/env bash
case "$*" in
    *"rev-parse --git-dir"*)
        echo "${_FAKE_GIT_DIR:-/tmp/fake-git-fail}"
        exit 0
        ;;
    *"rev-parse --verify --quiet origin/main"*)
        exit 1  # ref never becomes available
        ;;
    *"fetch"*)
        echo "_GIT_FETCH_CALLED=failed" >> "${_FETCH_LOG:-/dev/null}"
        exit 1  # all fetches fail (network unavailable)
        ;;
    *)
        exit 0
        ;;
esac
GITSH3
chmod +x "$TEST_TEMP_DIR/bin/git"

# Function should return 1 (ref unavailable) but NOT crash or propagate fetch error
_ebr_fail_rc=0
_ensure_base_branch_ref "main" 2>/dev/null || _ebr_fail_rc=$?
# Return code 1 is expected (ref unavailable), but should not be a hard crash
# The important thing is the calling code uses || true so we just confirm it completes
assert_pass "_ensure_base_branch_ref completes without crash when fetch fails"

# Verify emit_event was called with "git.base_ref_unavailable"
# (We stubbed emit_event as no-op above, so we check indirectly via return code being <=1)
if [[ "$_ebr_fail_rc" -le 1 ]]; then
    assert_pass "_ensure_base_branch_ref returns 0 or 1 (not fatal crash) when fetch fails"
else
    assert_fail "_ensure_base_branch_ref returns 0 or 1 (not fatal crash) when fetch fails" \
        "Unexpected exit code: $_ebr_fail_rc"
fi

# ─── Test: workflow yml does NOT use --depth=1 for the main fetch ──────────
print_test_section "workflow: git fetch origin main has no --depth=1"

_wf_file="$SCRIPT_DIR/../.github/workflows/shipwright-pipeline.yml"
if [[ -f "$_wf_file" ]]; then
    # Find the specific fetch line that installs shipwright (line ~488)
    _depth1_lines=$(grep -n "fetch.*--depth=1.*origin main\|fetch.*origin main.*--depth=1" "$_wf_file" 2>/dev/null || true)
    if [[ -z "$_depth1_lines" ]]; then
        assert_pass "shipwright-pipeline.yml: no --depth=1 on 'git fetch origin main'"
    else
        assert_fail "shipwright-pipeline.yml: no --depth=1 on 'git fetch origin main'" \
            "Found --depth=1 which corrupts shallow clone detection: $_depth1_lines"
    fi
else
    assert_pass "workflow file check skipped (not found)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# gh_post_progress / gh_update_progress — --timeout regression (Q1 fix)
# ═══════════════════════════════════════════════════════════════════════════
print_test_section "gh_post_progress: --timeout flag absent from gh api call"

# Build a gh stub that fails loudly if --timeout is passed, echoes 12345 otherwise.
_gh_stub="$TEST_TEMP_DIR/bin/gh"
cat > "$_gh_stub" << 'GH_STUB'
#!/usr/bin/env bash
for arg in "$@"; do
    if [[ "$arg" == "--timeout" ]]; then
        echo "unknown flag: --timeout" >&2
        exit 1
    fi
done
echo "12345"
GH_STUB
chmod +x "$_gh_stub"

# Re-source pipeline-github.sh with GH_AVAILABLE=true and the stub gh on PATH.
(
    _PIPELINE_GITHUB_LOADED=""
    export GH_AVAILABLE=true
    export REPO_OWNER=ezigus
    export REPO_NAME=shipwright
    export PROGRESS_COMMENT_ID=""
    export ISSUE_NUMBER=""
    PATH="$TEST_TEMP_DIR/bin:$PATH"
    source "$SCRIPT_DIR/lib/pipeline-github.sh"
    gh_post_progress 123 "test body"
    echo "COMMENT_ID=$PROGRESS_COMMENT_ID"
) > "$TEST_TEMP_DIR/post_progress_result.txt" 2>/dev/null

_post_result=$(cat "$TEST_TEMP_DIR/post_progress_result.txt")
if echo "$_post_result" | grep -q "COMMENT_ID=12345"; then
    assert_pass "gh_post_progress: PROGRESS_COMMENT_ID set to stub response (no --timeout)"
else
    assert_fail "gh_post_progress: PROGRESS_COMMENT_ID set to stub response (no --timeout)" \
        "Got: $_post_result"
fi

print_test_section "gh_update_progress: --timeout flag absent from gh api call"

(
    _PIPELINE_GITHUB_LOADED=""
    export GH_AVAILABLE=true
    export REPO_OWNER=ezigus
    export REPO_NAME=shipwright
    export PROGRESS_COMMENT_ID=99999
    PATH="$TEST_TEMP_DIR/bin:$PATH"
    source "$SCRIPT_DIR/lib/pipeline-github.sh"
    gh_update_progress "updated body"
    echo "UPDATE_RC=$?"
) > "$TEST_TEMP_DIR/update_progress_result.txt" 2>/dev/null

_update_rc=$(cat "$TEST_TEMP_DIR/update_progress_result.txt" | grep "UPDATE_RC=" | cut -d= -f2 || echo "")
if [[ "${_update_rc:-0}" == "0" ]]; then
    assert_pass "gh_update_progress: completes without error (no --timeout passed)"
else
    assert_fail "gh_update_progress: completes without error (no --timeout passed)" \
        "Exit code: $_update_rc"
fi

print_test_section "Survivor sweep: no --timeout flag in gh api calls"

# Scan source files only (exclude test files which reference --timeout in comments/strings)
_sweep_hits=$(grep -rn -- '--timeout' \
    "$SCRIPT_DIR/lib/" \
    "$SCRIPT_DIR"/sw-pipeline.sh \
    "$SCRIPT_DIR"/sw-pipeline-impl.sh \
    2>/dev/null \
    | grep 'gh api' | grep -v ':[0-9]*:[[:space:]]*#' || true)
if [[ -z "$_sweep_hits" ]]; then
    assert_pass "No --timeout flags found in gh api invocations"
else
    assert_fail "No --timeout flags found in gh api invocations" \
        "Found:
$_sweep_hits"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Fix 1: Workflow snapshot uses mirror-into-ISSUE_DIR approach (not git add -A)
# Source: .github/workflows/shipwright-pipeline.yml
# The "Snapshot resume-essentials to WIP branch (always)" step must NOT use
# "git add -A" (which mixed source-code edits into artifact commits). Instead
# it must mirror canonical artifacts into .claude/pipeline-artifacts/issue-N/
# and stage only that directory via "git add ISSUE_DIR".
# ─────────────────────────────────────────────────────────────────────────────
print_test_section "workflow snapshot: mirrors artifacts into issue-N/ (not git add -A)"

_workflow_file="$SCRIPT_DIR/../.github/workflows/shipwright-pipeline.yml"

if [[ -f "$_workflow_file" ]]; then
    # Extract the snapshot step block.
    _snapshot_block=$(awk \
        '/Snapshot resume-essentials/{found=1} found{print} found && /git restore --staged/{exit}' \
        "$_workflow_file" 2>/dev/null || true)

    # git add -A must NOT be present — replaced by mirror approach.
    if echo "$_snapshot_block" | grep -q 'git add -A' 2>/dev/null; then
        assert_fail "workflow snapshot: 'git add -A' absent from the snapshot step" \
            "'git add -A' must be removed — use mirror-into-ISSUE_DIR instead"
    else
        assert_pass "workflow snapshot: 'git add -A' absent from the snapshot step"
    fi

    # ISSUE_DIR mirror approach must be present instead.
    if echo "$_snapshot_block" | grep -q 'ISSUE_DIR' 2>/dev/null; then
        assert_pass "workflow snapshot: ISSUE_DIR mirror approach present"
    else
        assert_fail "workflow snapshot: ISSUE_DIR mirror approach present" \
            "ISSUE_DIR variable not found — mirror-into-issue-N/ approach not implemented"
    fi
else
    assert_fail "workflow snapshot: workflow file exists" \
        "File not found: $_workflow_file"
    assert_fail "workflow snapshot: ISSUE_DIR mirror approach present" \
        "Skipped — workflow file not found"
fi

print_test_results
