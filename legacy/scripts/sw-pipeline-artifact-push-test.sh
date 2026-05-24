#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-pipeline artifact push test — PAT push (loop + final artifact save)  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_LOOP_SCRIPT="$SCRIPT_DIR/sw-loop.sh"
REAL_PIPELINE_SCRIPT="$SCRIPT_DIR/sw-pipeline.sh"

# Normalize TMPDIR: macOS sets TMPDIR with a trailing slash; Linux may leave it unset.
# Provide a /tmp default first (safe under set -u), then strip any trailing slash.
_SW_TMPBASE="${TMPDIR:-/tmp}"
_SW_TMPBASE="${_SW_TMPBASE%/}"

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
RESET='\033[0m'

# ─── Counters ─────────────────────────────────────────────────────────────────
PASS=0
FAIL=0
FAILURES=""

run_test() {
    local name="$1"
    local fn="$2"
    echo -ne "  ${CYAN}▸${RESET} ${name}... "
    local rc=0
    "$fn" || rc=$?
    if [[ "$rc" -eq 0 ]]; then
        PASS=$((PASS + 1))
        echo -e "${GREEN}PASS${RESET}"
    else
        FAIL=$((FAIL + 1))
        FAILURES="${FAILURES}${name}\n"
        echo -e "${RED}FAIL${RESET}"
    fi
}

# ─── Helpers ──────────────────────────────────────────────────────────────────

assert_zero() {
    local rc="$1" label="${2:-expected exit 0}"
    if [[ "$rc" -ne 0 ]]; then
        echo -e "\n    ${RED}✗${RESET} $label (got $rc)" >&2
        return 1
    fi
}

assert_nonzero() {
    local rc="$1" label="${2:-expected non-zero exit}"
    if [[ "$rc" -eq 0 ]]; then
        echo -e "\n    ${RED}✗${RESET} $label (got 0)" >&2
        return 1
    fi
}

assert_grep() {
    local pattern="$1" file="$2" label="${3:-pattern match}"
    if ! grep -q "$pattern" "$file" 2>/dev/null; then
        echo -e "\n    ${RED}✗${RESET} $label: pattern '$pattern' not found in $file" >&2
        return 1
    fi
}

assert_grep_E() {
    local pattern="$1" file="$2" label="${3:-regex match}"
    if ! grep -qE "$pattern" "$file" 2>/dev/null; then
        echo -e "\n    ${RED}✗${RESET} $label: pattern '$pattern' not found in $file" >&2
        return 1
    fi
}

assert_file_empty() {
    local file="$1" label="${2:-file empty}"
    if [[ -s "$file" ]]; then
        echo -e "\n    ${RED}✗${RESET} $label: file is not empty" >&2
        cat "$file" >&2
        return 1
    fi
}

assert_remote_branch_exists() {
    local bare_repo="$1" branch="$2" label="${3:-branch on remote}"
    # Use git -C to query the bare repo directly — avoids path-encoding issues with
    # git ls-remote when the path contains double slashes (macOS TMPDIR trailing slash).
    if ! git -C "$bare_repo" rev-parse --verify "refs/heads/$branch" >/dev/null 2>&1; then
        echo -e "\n    ${RED}✗${RESET} $label: branch '$branch' not found on remote $bare_repo" >&2
        return 1
    fi
}

# Source pipeline_final_artifact_push from sw-pipeline.sh into the current shell.
# Extracts just the function definition by line range to avoid executing any
# top-level sw-pipeline.sh code that would reset SCRIPT_DIR etc.
_source_pipeline_fn() {
    warn() { echo "[WARN] $*" >&2 || true; }
    emit_event() { echo "[EVENT] $*" >&2 || true; }
    safe_git_stage() { git add -A 2>/dev/null || true; }
    _timeout() { local _t="$1"; shift; "$@"; }

    # Extract the push guard helper and the main function.
    local _fn_text _fn_tmp
    _fn_text=$(
        sed -n '/^_assert_push_target_matches_active_issue()/,/^}$/p' "$REAL_PIPELINE_SCRIPT" 2>/dev/null
        sed -n '/^pipeline_final_artifact_push()/,/^}$/p' "$REAL_PIPELINE_SCRIPT" 2>/dev/null
    ) || true
    _fn_tmp=$(mktemp "$_SW_TMPBASE/sw-fn-source.XXXXXX")
    echo "$_fn_text" > "$_fn_tmp"

    # shellcheck disable=SC1090
    set +euo pipefail
    # shellcheck disable=SC1090
    source "$_fn_tmp" 2>/dev/null || true
    set -euo pipefail
    rm -f "$_fn_tmp"
}

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 1 — Loop worker PAT pattern: static grep on sw-loop.sh source
# ═══════════════════════════════════════════════════════════════════════════════

test_loop_worker_uses_pat_pattern() {
    # Extract the WORKEREOF heredoc region
    local heredoc
    heredoc=$(sed -n '/<<.WORKEREOF./,/^WORKEREOF$/p' "$REAL_LOOP_SCRIPT" 2>/dev/null)
    local tmpf
    tmpf=$(mktemp)
    echo "$heredoc" > "$tmpf"

    assert_grep "GITHUBTOKEN" "$tmpf" "GITHUBTOKEN referenced in worker heredoc" &&
    assert_grep "x-access-token" "$tmpf" "x-access-token PAT URL in worker heredoc" &&
    assert_grep 'https://github\.com' "$tmpf" "PAT scrub URL in worker heredoc"

    local rc=$?
    rm -f "$tmpf"
    return "$rc"
}

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 2 — pipeline_final_artifact_push skips when ISSUE_NUMBER is unset
# ═══════════════════════════════════════════════════════════════════════════════

test_final_artifact_push_skips_when_no_issue() {
    local T
    T=$(mktemp -d "$_SW_TMPBASE/sw-artifact-test.XXXXXX")

    # Mock git that logs all calls
    local git_log="$T/git.log"
    mkdir -p "$T/bin"
    cat > "$T/bin/git" <<MOCKGIT
#!/usr/bin/env bash
echo "git \$*" >> "$git_log"
exit 0
MOCKGIT
    chmod +x "$T/bin/git"

    # Source function in a subshell so env is isolated
    local rc=0
    rc=$(
        PATH="$T/bin:$PATH"
        HOME="$T"
        ISSUE_NUMBER=""
        ARTIFACTS_DIR="$T/artifacts"
        STATE_DIR="$T"
        GITHUB_RUN_ID=""
        GITHUBTOKEN=""
        _source_pipeline_fn
        pipeline_final_artifact_push 5 >/dev/null 2>&1
        echo $?
    )

    local result=0
    assert_zero "$rc" "should return 0 when ISSUE_NUMBER is empty" &&
    assert_file_empty "$git_log" "no git commands should run when ISSUE_NUMBER is empty" || result=1
    rm -rf "$T"
    return "$result"
}

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 3 — pipeline_final_artifact_push pushes to shipwright/issue-N branch
# ═══════════════════════════════════════════════════════════════════════════════

test_final_artifact_push_pushes_to_wip_branch() {
    local T
    T=$(mktemp -d "$_SW_TMPBASE/sw-artifact-test.XXXXXX")

    # Set up bare remote
    local bare="$T/remote.git"
    git init --quiet --bare "$bare"

    # Set up working repo
    local repo="$T/repo"
    mkdir -p "$repo"
    (
        cd "$repo"
        git init -q -b main 2>/dev/null || git init -q
        git config user.email "test@test.com"
        git config user.name "Test"
        echo "init" > README.md
        git add README.md
        git commit -q -m "init"
        git remote add origin "$bare"
        git push -q origin "HEAD:refs/heads/main"
        # Create an unignored artifact file (pipeline-artifacts/issue-N/ is not gitignored)
        mkdir -p ".claude/pipeline-artifacts/issue-99"
        echo "status: complete" > ".claude/pipeline-artifacts/issue-99/pipeline-state.md"
    )

    # Run in subshell; capture stderr to a log file for diagnostics on failure
    local push_err="$T/push.err"
    local rc=0
    rc=$(
        set +euo pipefail
        cd "$repo"
        ISSUE_NUMBER="99"
        ARTIFACTS_DIR="$repo/.claude/pipeline-artifacts"
        STATE_DIR="$T"
        GITHUB_RUN_ID=""
        GITHUBTOKEN=""
        EVENTS_FILE="/dev/null"
        HOME="$T"
        GIT_TERMINAL_PROMPT=0
        export GIT_TERMINAL_PROMPT
        _source_pipeline_fn
        pipeline_final_artifact_push 15 >"$push_err" 2>&1
        echo $?
    )

    local result=0
    assert_zero "$rc" "pipeline_final_artifact_push should return 0" &&
    assert_remote_branch_exists "$bare" "shipwright/issue-99" "WIP branch pushed to remote" || result=1
    if [[ "$result" -ne 0 ]]; then
        echo -e "\n    ${RED}[debug] push_err contents:${RESET}" >&2
        cat "$push_err" >&2 2>/dev/null || true
        echo -e "    [debug] bare=$bare" >&2
        git -C "$repo" log --oneline 2>/dev/null | head -3 >&2 || true
        git -C "$bare" branch -a 2>/dev/null >&2 || true
    fi
    rm -rf "$T"
    return "$result"
}

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 4 — pipeline_final_artifact_push returns 0 even when push fails
# ═══════════════════════════════════════════════════════════════════════════════

test_final_artifact_push_returns_zero_on_push_failure() {
    local T
    T=$(mktemp -d "$_SW_TMPBASE/sw-artifact-test.XXXXXX")

    # Set up real git repo so git diff/add/commit work, but push fails
    local repo="$T/repo"
    mkdir -p "$repo"
    (
        cd "$repo"
        git init -q -b main 2>/dev/null || git init -q
        git config user.email "test@test.com"
        git config user.name "Test"
        echo "init" > README.md
        git add README.md
        git commit -q -m "init"
        # Add a fake remote that will cause push to fail
        git remote add origin "https://github.com/nonexistent/repo.git"
    )

    local rc=0
    rc=$(
        set +euo pipefail
        cd "$repo"
        ISSUE_NUMBER="88"
        ARTIFACTS_DIR="$T/artifacts"
        STATE_DIR="$T"
        GITHUB_RUN_ID=""
        GITHUBTOKEN=""
        EVENTS_FILE="/dev/null"
        HOME="$T"
        GIT_TERMINAL_PROMPT=0
        export GIT_TERMINAL_PROMPT
        _source_pipeline_fn
        # Override _timeout so push actually runs (and fails fast)
        _timeout() { local _t="$1"; shift; "$@" 2>/dev/null || true; }
        pipeline_final_artifact_push 3 >/dev/null 2>&1
        echo $?
    )

    local result=0
    assert_zero "$rc" "pipeline_final_artifact_push must return 0 even when push fails" || result=1
    rm -rf "$T"
    return "$result"
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  PAT push + final artifact push tests                            ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

run_test "Loop worker script contains PAT inject/scrub pattern" test_loop_worker_uses_pat_pattern
run_test "Final artifact push: skips when ISSUE_NUMBER is empty"  test_final_artifact_push_skips_when_no_issue
run_test "Final artifact push: creates WIP branch on remote"       test_final_artifact_push_pushes_to_wip_branch
run_test "Final artifact push: returns 0 on push failure"          test_final_artifact_push_returns_zero_on_push_failure

echo ""
echo "──────────────────────────────────────────────────────────────────"
TOTAL=$((PASS + FAIL))
echo "  Results: ${PASS}/${TOTAL} passed"
if [[ "$FAIL" -gt 0 ]]; then
    echo ""
    echo -e "  ${RED}Failed tests:${RESET}"
    echo -e "$FAILURES" | while IFS= read -r line; do
        [[ -n "$line" ]] && echo "    - $line"
    done
    echo ""
    exit 1
fi
echo ""
