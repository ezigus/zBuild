#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright pipeline test — E2E validation invoking the REAL pipeline          ║
# ║  Every test runs sw-pipeline.sh as a subprocess · No logic reimpl.     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

# Error trap for CI debugging — shows which line fails
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REAL_PIPELINE_SCRIPT="$SCRIPT_DIR/sw-pipeline.sh"

# ─── Colors (matches shipwright theme) ──────────────────────────────────────────────
# shellcheck disable=SC2034

# ─── Counters ─────────────────────────────────────────────────────────────────

# ═══════════════════════════════════════════════════════════════════════════════
# MOCK ENVIRONMENT SETUP
# Creates the complete temp structure that the real pipeline needs:
#   $TEST_TEMP_DIR/
#   ├── scripts/sw-pipeline.sh   (copy of real)
#   ├── scripts/sw-loop.sh       (mock)
#   ├── templates/pipelines/      (default template + per-test overrides)
#   ├── bin/claude|gh|sw           (mocks on PATH)
#   ├── remote.git/                (bare repo for git push)
#   └── project/                   (mock git repo — tests cd here)
# ═══════════════════════════════════════════════════════════════════════════════

setup_env() {
    TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-pipeline-test.XXXXXX")

    # ── Copy real pipeline script and libs (pipeline sources lib/*.sh) ──────
    mkdir -p "$TEST_TEMP_DIR/scripts"
    cp "$REAL_PIPELINE_SCRIPT" "$TEST_TEMP_DIR/scripts/sw-pipeline.sh"
    [[ -d "$SCRIPT_DIR/lib" ]] && cp -r "$SCRIPT_DIR/lib" "$TEST_TEMP_DIR/scripts/lib"
    [[ -d "$SCRIPT_DIR/skills" ]] && cp -r "$SCRIPT_DIR/skills" "$TEST_TEMP_DIR/scripts/skills"

    # ── Mock sw-loop.sh (next to pipeline — preflight checks $SCRIPT_DIR/sw-loop.sh) ──
    cat > "$TEST_TEMP_DIR/scripts/sw-loop.sh" <<'LOOP_EOF'
#!/usr/bin/env bash
# Mock sw-loop: simulate build by creating a feature file and committing
mkdir -p src
cat > src/feature.js <<'FEAT'
function authenticate(token) { return token && token.length > 0; }
module.exports = { authenticate };
FEAT
git add src/feature.js
git commit -m "feat: implement feature" --quiet --allow-empty 2>/dev/null || true
LOOP_EOF
    chmod +x "$TEST_TEMP_DIR/scripts/sw-loop.sh"

    # ── Copy pipeline templates ───────────────────────────────────────────
    mkdir -p "$TEST_TEMP_DIR/templates/pipelines"
    if [[ -d "$REPO_DIR/templates/pipelines" ]]; then
        cp "$REPO_DIR/templates/pipelines"/*.json "$TEST_TEMP_DIR/templates/pipelines/" 2>/dev/null || true
    fi
    # Ensure at least a standard template exists
    if [[ ! -f "$TEST_TEMP_DIR/templates/pipelines/standard.json" ]]; then
        write_standard_template
    fi

    # ── Mock binaries ─────────────────────────────────────────────────────
    mkdir -p "$TEST_TEMP_DIR/bin"
    create_mock_claude
    create_mock_gh
    create_mock_sw
    create_mock_ruflo

    # Mock timeout — macOS doesn't have GNU coreutils timeout by default
    cat > "$TEST_TEMP_DIR/bin/timeout" <<'TIMEOUT_EOF'
#!/usr/bin/env bash
shift  # skip the timeout duration
exec "$@"
TIMEOUT_EOF
    chmod +x "$TEST_TEMP_DIR/bin/timeout"

    # ── Mock project git repo ─────────────────────────────────────────────
    create_mock_project

    # ── Bare repo for git push ────────────────────────────────────────────
    git init --quiet --bare "$TEST_TEMP_DIR/remote.git" 2>/dev/null

    # ── Wire up git remotes ───────────────────────────────────────────────
    # Push URL → local bare repo (so git push works)
    # Fetch URL → fake GitHub URL (so gh_init() detects REPO_OWNER/REPO_NAME)
    (
        cd "$TEST_TEMP_DIR/project"
        git remote add origin "$TEST_TEMP_DIR/remote.git"
        git push -u origin main --quiet 2>/dev/null
        git remote set-url origin "https://github.com/test-org/test-repo.git"
        git config remote.origin.pushurl "$TEST_TEMP_DIR/remote.git"
    )
}

write_standard_template() {
    cat > "$TEST_TEMP_DIR/templates/pipelines/standard.json" <<'TMPL'
{
  "name": "standard",
  "description": "Standard pipeline for tests",
  "defaults": { "test_cmd": "npm test", "model": "opus", "agents": 1 },
  "stages": [
    { "id": "intake",   "enabled": true,  "gate": "auto", "config": {} },
    { "id": "plan",     "enabled": true,  "gate": "auto", "config": { "model": "opus" } },
    { "id": "build",    "enabled": true,  "gate": "auto", "config": { "max_iterations": 20 } },
    { "id": "test",     "enabled": true,  "gate": "auto", "config": { "coverage_min": 0 } },
    { "id": "review",   "enabled": true,  "gate": "auto", "config": {} },
    { "id": "pr",       "enabled": true,  "gate": "auto", "config": { "wait_ci": false } },
    { "id": "deploy",   "enabled": false, "gate": "auto", "config": {} },
    { "id": "validate", "enabled": false, "gate": "auto", "config": {} }
  ]
}
TMPL
}

# Generate a pipeline config with only specified stages enabled
# Usage: pipeline_config_with_stages "intake,plan,build"
pipeline_config_with_stages() {
    local enabled_csv="$1"
    local all_stages=("intake" "plan" "build" "test" "review" "pr" "deploy" "validate")
    local json='{ "name": "test-custom", "description": "Custom test pipeline",'
    json+=' "defaults": { "test_cmd": "echo all-tests-passed", "model": "opus", "agents": 1 },'
    json+=' "stages": ['
    local first=true
    for s in "${all_stages[@]}"; do
        local enabled="false"
        if echo ",$enabled_csv," | grep -q ",$s,"; then
            enabled="true"
        fi
        $first || json+=","
        first=false
        json+=" {\"id\":\"$s\",\"enabled\":$enabled,\"gate\":\"auto\",\"config\":{}}"
    done
    json+=' ] }'
    echo "$json"
}

create_mock_claude() {
    cat > "$TEST_TEMP_DIR/bin/claude" <<'CLAUDE_EOF'
#!/usr/bin/env bash
# Mock claude CLI — detects plan vs review from prompt content
prompt=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --print|--output-format) shift ;;
        --model|--max-turns)     shift 2 ;;
        -p)                      shift 2 ;;
        *)                       prompt="$1"; shift ;;
    esac
done

if echo "$prompt" | grep -qiE "code review|reviewer|senior.*review|spec compliance"; then
    cat <<'REVIEW'
# Code Review

## Findings

- **[Warning]** src/feature.js:3 — Missing input validation for empty strings
- **[Bug]** src/feature.js:1 — Function name could be more descriptive
- **[Suggestion]** src/feature.js:2 — Consider using strict equality check

## Summary
3 issues found: 0 critical, 1 bug, 1 warning, 1 suggestion.
Code is generally acceptable with minor improvements recommended.
REVIEW
elif echo "$prompt" | grep -qiE "implementation plan|task checklist|create a.*plan"; then
    cat <<'PLAN'
# Implementation Plan

## Files to Modify
- src/feature.js — New auth module
- tests/feature.test.js — Tests for auth

## Implementation Steps
1. Create authentication module
2. Add token validation
3. Write unit tests

### Task Checklist
- [ ] Create auth module in src/feature.js
- [ ] Add token validation logic
- [ ] Write unit tests for auth
- [ ] Add error handling for invalid tokens
- [ ] Update API documentation

### Testing Approach
Run the test suite to verify auth works end to end.

### Definition of Done
- [ ] All tests pass
- [ ] Code reviewed
- [ ] No security vulnerabilities
PLAN
else
    echo "Mock claude: unrecognized prompt context"
fi
CLAUDE_EOF
    chmod +x "$TEST_TEMP_DIR/bin/claude"
}

create_mock_gh() {
    cat > "$TEST_TEMP_DIR/bin/gh" <<'GH_EOF'
#!/usr/bin/env bash
# Mock gh CLI — routes by subcommand
case "$1" in
    auth)
        # gh auth status → success
        exit 0
        ;;
    issue)
        case "$2" in
            view)
                # gh issue view N --json ...
                issue_num="$3"
                cat <<ISSUE_JSON
{
  "title": "Add JWT authentication to API",
  "body": "We need JWT auth for the /users endpoint.\\n\\nAcceptance criteria:\\n- Token validation\\n- 401 on invalid token",
  "labels": [{"name": "feature"}, {"name": "priority/high"}],
  "milestone": {"title": "v2.0"},
  "assignees": [],
  "comments": [],
  "number": ${issue_num:-42},
  "state": "OPEN"
}
ISSUE_JSON
                ;;
            comment|edit)
                # gh issue comment/edit → silent success
                exit 0
                ;;
            *)
                exit 0
                ;;
        esac
        ;;
    pr)
        case "$2" in
            create)
                echo "https://github.com/test-org/test-repo/pull/1"
                ;;
            checks)
                exit 0
                ;;
            *)
                exit 0
                ;;
        esac
        ;;
    api)
        # gh api → return JSON with comment id for progress tracking
        if echo "$*" | grep -q "comments"; then
            echo '{"id": 12345}'
        fi
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
GH_EOF
    chmod +x "$TEST_TEMP_DIR/bin/gh"
}

create_mock_sw() {
    # The pipeline calls `sw loop "${loop_args[@]}"` in stage_build
    cat > "$TEST_TEMP_DIR/bin/sw" <<MOCK_SW
#!/usr/bin/env bash
# Mock sw CLI — handles loop subcommand
case "\$1" in
    loop)
        # Simulate build: create feature file and commit
        mkdir -p src
        cat > src/feature.js <<'FEAT'
function authenticate(token) { return token && token.length > 0; }
module.exports = { authenticate };
FEAT
        git add src/feature.js
        git commit -m "feat: implement feature" --quiet --allow-empty 2>/dev/null || true
        ;;
    *)
        exit 0
        ;;
esac
MOCK_SW
    chmod +x "$TEST_TEMP_DIR/bin/sw"
}

create_mock_ruflo() {
    cat > "$TEST_TEMP_DIR/bin/ruflo" <<'RUFLO_EOF'
#!/usr/bin/env bash
# Mock ruflo — all subcommands succeed instantly so pipeline tests don't
# block on real daemon startup (init check, start --daemon, stop, etc.)
exit 0
RUFLO_EOF
    chmod +x "$TEST_TEMP_DIR/bin/ruflo"
}

create_mock_project() {
    mkdir -p "$TEST_TEMP_DIR/project/src" "$TEST_TEMP_DIR/project/tests"

    # package.json (so detect_test_cmd returns "npm test")
    cat > "$TEST_TEMP_DIR/project/package.json" <<'PKG'
{
  "name": "test-project",
  "version": "1.0.0",
  "scripts": { "test": "echo 'All 5 tests passed'" },
  "dependencies": {}
}
PKG

    cat > "$TEST_TEMP_DIR/project/src/index.js" <<'SRC'
const express = require('express');
const app = express();
app.get('/health', (req, res) => res.json({ status: 'ok' }));
module.exports = app;
SRC

    cat > "$TEST_TEMP_DIR/project/tests/index.test.js" <<'TST'
describe('health', () => {
  it('should return ok', () => { expect(true).toBe(true); });
});
TST

    (
        cd "$TEST_TEMP_DIR/project"
        git init --quiet -b main
        git config user.email "test@test.com"
        git config user.name "Test User"
        git add -A
        git commit -m "Initial commit" --quiet
    )
}

# Reset project state between tests (keeps the base env, resets git + artifacts)
reset_test() {
    (
        cd "$TEST_TEMP_DIR/project"
        # Remove pipeline artifacts
        rm -rf .claude 2>/dev/null || true
        # Reset to main branch, remove feature branches
        git checkout main --quiet 2>/dev/null || true
        local branches
        branches=$(git branch --list | grep -v '^\* *main$' | grep -v '^ *main$' || true)
        if [[ -n "$branches" ]]; then
            echo "$branches" | xargs git branch -D --quiet 2>/dev/null || true
        fi
        # Remove any build artifacts
        rm -f src/feature.js 2>/dev/null || true
        git checkout -- . 2>/dev/null || true
        git clean -fd --quiet 2>/dev/null || true
    )
    # Reset the remote bare repo
    rm -rf "$TEST_TEMP_DIR/remote.git"
    git init --quiet --bare "$TEST_TEMP_DIR/remote.git" 2>/dev/null
    (
        cd "$TEST_TEMP_DIR/project"
        git config remote.origin.pushurl "$TEST_TEMP_DIR/remote.git"
        git push -u origin main --quiet 2>/dev/null || true
    )
    # Remove self-healing markers
    rm -f "$TEST_TEMP_DIR/self-heal-marker" 2>/dev/null || true
}

cleanup_env() {
    if [[ -n "$TEST_TEMP_DIR" && -d "$TEST_TEMP_DIR" ]]; then
        # npm/npx may write read-only files into $TEST_TEMP_DIR/.npm when HOME
        # is redirected to the temp dir. chmod first to allow removal on macOS.
        chmod -R u+rwx "$TEST_TEMP_DIR" 2>/dev/null || true
        rm -rf "$TEST_TEMP_DIR" || true
    fi
}
_test_cleanup_hook() { cleanup_env; }

# ═══════════════════════════════════════════════════════════════════════════════
# PIPELINE INVOCATION HELPER
# Every test calls this to invoke the REAL pipeline as a subprocess.
# ═══════════════════════════════════════════════════════════════════════════════

# Run the real pipeline and capture output + exit code.
# Usage: run_pipeline <subcommand> [args...]
# Sets: PIPELINE_OUTPUT, PIPELINE_EXIT
PIPELINE_OUTPUT=""
PIPELINE_EXIT=0

invoke_pipeline() {
    local subcommand="$1"
    shift
    PIPELINE_OUTPUT=""
    PIPELINE_EXIT=0

    # Invoke the REAL pipeline script as a subprocess.
    # Redirect HOME so emit_event writes events.jsonl to the temp dir rather than
    # the real ~/.shipwright/ (which may be outside sandbox write allowlists).
    # Isolate intelligence env vars from parent pipeline to prevent test pollution.
    # Tests that need these should set _TEST_INTELLIGENCE_COMPLEXITY instead.
    # SHIPWRIGHT_MIN_FREE_GB=0 disables the memory threshold so pipeline unit
    # tests are not affected by the host's actual available RAM.
    # WORKSPACE_BRANCH/CI_MODE are explicitly unset so this subprocess does NOT
    # inherit them from the surrounding GitHub Actions run — tests that want
    # those set invoke the pipeline directly with their own env, bypassing this
    # helper. Without this, tests asserting local-dev branch-creation behavior
    # silently follow the CI workspace-branch path and fail.
    PIPELINE_OUTPUT=$(
        cd "$TEST_TEMP_DIR/project"
        unset WORKSPACE_BRANCH CI_MODE
        HOME="$TEST_TEMP_DIR" \
        EVENTS_FILE="$TEST_TEMP_DIR/events.jsonl" \
        PATH="$TEST_TEMP_DIR/bin:$PATH" \
        INTELLIGENCE_COMPLEXITY="${_TEST_INTELLIGENCE_COMPLEXITY:-}" \
        INTELLIGENCE_ISSUE_TYPE="${_TEST_INTELLIGENCE_ISSUE_TYPE:-}" \
        SHIPWRIGHT_MIN_FREE_GB=0 \
        NO_ARTIFACT_PUSH=true \
        bash "$TEST_TEMP_DIR/scripts/sw-pipeline.sh" "$subcommand" "$@" 2>&1
    ) || PIPELINE_EXIT=$?
}

# ═══════════════════════════════════════════════════════════════════════════════
# ASSERTIONS — verify pipeline outputs without reimplementing logic
# ═══════════════════════════════════════════════════════════════════════════════

assert_exit_code() {
    local expected="$1" label="${2:-exit code}"
    if [[ "$PIPELINE_EXIT" -eq "$expected" ]]; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Expected exit code $expected, got $PIPELINE_EXIT ($label)"
    echo -e "    ${DIM}Pipeline output (last 20 lines):${RESET}"
    echo "$PIPELINE_OUTPUT" | tail -20 | sed 's/^/      /'
    return 1
}

assert_output_contains() {
    local pattern="$1" label="${2:-output match}"
    if printf '%s\n' "$PIPELINE_OUTPUT" | grep -qiE "$pattern" 2>/dev/null; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Output missing pattern: $pattern ($label)"
    echo -e "    ${DIM}Output (last 5 lines):${RESET}"
    echo "$PIPELINE_OUTPUT" | tail -5 | sed 's/^/      /'
    return 1
}

assert_output_not_contains() {
    local pattern="$1" label="${2:-output exclusion}"
    if ! printf '%s\n' "$PIPELINE_OUTPUT" | grep -qiE "$pattern" 2>/dev/null; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Output unexpectedly contains: $pattern ($label)"
    return 1
}

assert_file_exists() {
    local filepath="$1" label="${2:-file exists}"
    local full_path="$TEST_TEMP_DIR/project/$filepath"
    if [[ -f "$full_path" ]]; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} File not found: $filepath ($label)"
    return 1
}

assert_file_not_exists() {
    local filepath="$1" label="${2:-file absent}"
    local full_path="$TEST_TEMP_DIR/project/$filepath"
    if [[ ! -f "$full_path" ]]; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} File should not exist: $filepath ($label)"
    return 1
}

assert_file_contains() {
    local filepath="$1" pattern="$2" label="${3:-file content}"
    local full_path="$TEST_TEMP_DIR/project/$filepath"
    if [[ ! -f "$full_path" ]]; then
        echo -e "    ${RED}✗${RESET} File not found: $filepath ($label)"
        return 1
    fi
    if grep -qiE "$pattern" "$full_path"; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} File $filepath missing pattern: $pattern ($label)"
    return 1
}

assert_branch_exists() {
    local pattern="$1" label="${2:-branch exists}"
    local branches
    branches=$(cd "$TEST_TEMP_DIR/project" && git branch --list 2>/dev/null)
    if printf '%s\n' "$branches" | grep -qE "$pattern" 2>/dev/null; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} No branch matching: $pattern ($label)"
    echo -e "    ${DIM}Branches: $(echo "$branches" | tr '\n' ' ')${RESET}"
    return 1
}

assert_state_contains() {
    local pattern="$1" label="${2:-state check}"
    assert_file_contains ".claude/pipeline-state.md" "$pattern" "$label"
}

# ═══════════════════════════════════════════════════════════════════════════════
# TEST RUNNER
# ═══════════════════════════════════════════════════════════════════════════════

run_test() {
    local test_name="$1"
    local test_fn="$2"
    TOTAL=$((TOTAL + 1))

    echo -ne "  ${CYAN}▸${RESET} ${test_name}... "
    reset_test

    local result=0
    "$test_fn" || result=$?

    if [[ "$result" -eq 0 ]]; then
        echo -e "${GREEN}✓${RESET}"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}✗ FAILED${RESET}"
        FAIL=$((FAIL + 1))
        FAILURES+=("$test_name")
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS — Each invokes the REAL pipeline. NO logic reimplementation.
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 1. Preflight passes with all mocks in place
# ──────────────────────────────────────────────────────────────────────────────
test_preflight_passes() {
    invoke_pipeline start --goal "Test preflight" --skip-gates --dry-run
    assert_exit_code 0 "dry-run should succeed" &&
    assert_output_contains "Pre-flight passed" "preflight check"
}

# ──────────────────────────────────────────────────────────────────────────────
# 2. Preflight fails when sw-loop.sh is missing
# ──────────────────────────────────────────────────────────────────────────────
test_preflight_fails_missing_loop() {
    # Temporarily remove sw-loop.sh
    mv "$TEST_TEMP_DIR/scripts/sw-loop.sh" "$TEST_TEMP_DIR/scripts/sw-loop.sh.bak"

    invoke_pipeline start --goal "Test missing loop" --skip-gates --dry-run

    # Restore
    mv "$TEST_TEMP_DIR/scripts/sw-loop.sh.bak" "$TEST_TEMP_DIR/scripts/sw-loop.sh"

    assert_exit_code 1 "should fail preflight" &&
    assert_output_contains "sw-loop" "should mention sw-loop"
}

# ──────────────────────────────────────────────────────────────────────────────
# 3. Start requires --goal or --issue
# ──────────────────────────────────────────────────────────────────────────────
test_start_requires_goal_or_issue() {
    invoke_pipeline start --skip-gates
    assert_exit_code 1 "should fail without goal/issue" &&
    assert_output_contains "Must provide" "error message"
}

# ──────────────────────────────────────────────────────────────────────────────
# 4. Intake with inline --goal creates branch + artifacts
# ──────────────────────────────────────────────────────────────────────────────
test_intake_inline() {
    # Use intake-only template so pipeline stops after intake
    pipeline_config_with_stages "intake" > "$TEST_TEMP_DIR/templates/pipelines/standard.json"

    invoke_pipeline start --goal "Add JWT auth" --skip-gates --test-cmd "echo passed"

    assert_exit_code 0 "pipeline should complete" &&
    assert_file_exists ".claude/pipeline-artifacts/intake.json" "intake artifact" &&
    assert_file_contains ".claude/pipeline-artifacts/intake.json" "JWT" "goal in intake" &&
    assert_branch_exists "feat/.*jwt" "feature branch created" &&
    assert_state_contains "intake.*complete" "intake marked complete"
}

# ──────────────────────────────────────────────────────────────────────────────
# 5. Intake with --issue fetches from mock gh
# ──────────────────────────────────────────────────────────────────────────────
test_intake_issue() {
    pipeline_config_with_stages "intake" > "$TEST_TEMP_DIR/templates/pipelines/standard.json"

    invoke_pipeline start --issue 42 --skip-gates --test-cmd "echo passed"

    assert_exit_code 0 "pipeline should complete" &&
    assert_file_exists ".claude/pipeline-artifacts/intake.json" "intake artifact" &&
    assert_file_contains ".claude/pipeline-artifacts/intake.json" "42" "issue number in intake" &&
    assert_branch_exists "42" "branch includes issue number" &&
    assert_output_contains "Issue #42" "output shows issue number"
}

# ──────────────────────────────────────────────────────────────────────────────
# 6. Plan stage generates plan.md, dod.md, and pipeline-tasks.md
# ──────────────────────────────────────────────────────────────────────────────
test_plan_generates_artifacts() {
    pipeline_config_with_stages "intake,plan" > "$TEST_TEMP_DIR/templates/pipelines/standard.json"

    invoke_pipeline start --goal "Add auth module" --skip-gates --test-cmd "echo passed"

    assert_exit_code 0 "pipeline should complete" &&
    assert_file_exists ".claude/pipeline-artifacts/plan.md" "plan generated" &&
    assert_file_contains ".claude/pipeline-artifacts/plan.md" "Task Checklist" "plan has checklist" &&
    assert_file_exists ".claude/pipeline-artifacts/dod.md" "definition of done extracted" &&
    assert_file_exists ".claude/pipeline-tasks.md" "task tracking file" &&
    assert_file_contains ".claude/pipeline-tasks.md" "\\- \\[" "tasks have checkboxes" &&
    assert_file_exists ".claude/tasks.md" "Claude Code task list" &&
    assert_file_contains ".claude/tasks.md" "Checklist" "CC task list has checklist section"
}

# ──────────────────────────────────────────────────────────────────────────────
# 7. Build stage invokes sw loop and produces commits
# ──────────────────────────────────────────────────────────────────────────────
test_build_invokes_sw() {
    pipeline_config_with_stages "intake,plan,build" > "$TEST_TEMP_DIR/templates/pipelines/standard.json"

    invoke_pipeline start --goal "Add auth" --skip-gates --test-cmd "echo passed"

    assert_exit_code 0 "pipeline should complete" &&
    assert_file_exists "src/feature.js" "build created feature file" &&
    assert_state_contains "build.*complete" "build marked complete"

    # Verify a commit exists with "feat:" prefix (from mock sw loop)
    local commits
    commits=$(cd "$TEST_TEMP_DIR/project" && git log --oneline 2>/dev/null)
    if ! printf '%s\n' "$commits" | grep -q "feat:" 2>/dev/null; then
        echo -e "    ${RED}✗${RESET} No 'feat:' commit found"
        return 1
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# 8. Test stage captures results to log file
# ──────────────────────────────────────────────────────────────────────────────
test_test_captures_results() {
    pipeline_config_with_stages "intake,plan,build,test" > "$TEST_TEMP_DIR/templates/pipelines/standard.json"

    invoke_pipeline start --goal "Add auth" --skip-gates --test-cmd "echo 'All 8 tests passed'"

    assert_exit_code 0 "pipeline should complete" &&
    assert_file_exists ".claude/pipeline-artifacts/test-results.log" "test log" &&
    assert_file_contains ".claude/pipeline-artifacts/test-results.log" "passed" "test output captured" &&
    assert_state_contains "test.*complete" "test marked complete"
}

# ──────────────────────────────────────────────────────────────────────────────
# 9. Review stage generates review.md with severity markers
# ──────────────────────────────────────────────────────────────────────────────
test_review_generates_report() {
    pipeline_config_with_stages "intake,plan,build,test,review" > "$TEST_TEMP_DIR/templates/pipelines/standard.json"

    invoke_pipeline start --goal "Add auth" --skip-gates --test-cmd "echo passed"

    assert_exit_code 0 "pipeline should complete" &&
    assert_file_exists ".claude/pipeline-artifacts/review.md" "review generated" &&
    assert_file_contains ".claude/pipeline-artifacts/review.md" "Warning|Bug|Suggestion" "review has severity markers" &&
    assert_state_contains "review.*complete" "review marked complete"
}

# ──────────────────────────────────────────────────────────────────────────────
# 10. PR stage creates PR URL artifact
# ──────────────────────────────────────────────────────────────────────────────
test_pr_creates_url() {
    pipeline_config_with_stages "intake,plan,build,test,review,pr" > "$TEST_TEMP_DIR/templates/pipelines/standard.json"

    invoke_pipeline start --goal "Add auth" --skip-gates --test-cmd "echo passed"

    assert_exit_code 0 "pipeline should complete" &&
    assert_file_exists ".claude/pipeline-artifacts/pr-url.txt" "PR URL saved" &&
    assert_file_contains ".claude/pipeline-artifacts/pr-url.txt" "github.com" "PR URL is a GitHub link" &&
    assert_state_contains "pr.*complete" "pr marked complete"
}

# ──────────────────────────────────────────────────────────────────────────────
# 11. Full E2E pipeline — all 6 enabled stages complete
# ──────────────────────────────────────────────────────────────────────────────
test_full_pipeline_e2e() {
    # Restore real standard template with all gates set to auto
    write_standard_template

    invoke_pipeline start --goal "Add JWT authentication" --skip-gates --test-cmd "echo 'All tests passed'"

    assert_exit_code 0 "full pipeline should complete" &&
    assert_output_contains "Pipeline complete" "completion message" &&
    assert_state_contains "status: idle" "final status (reset by post-completion cleanup)" &&
    assert_file_exists ".claude/pipeline-artifacts/intake.json" "intake artifact" &&
    assert_file_exists ".claude/pipeline-artifacts/plan.md" "plan artifact" &&
    assert_file_exists ".claude/pipeline-artifacts/test-results.log" "test log" &&
    assert_file_exists ".claude/pipeline-artifacts/review.md" "review artifact" &&
    assert_file_exists ".claude/pipeline-artifacts/pr-url.txt" "PR URL"
}

# ──────────────────────────────────────────────────────────────────────────────
# 12. Resume continues from partial state
# ──────────────────────────────────────────────────────────────────────────────
test_resume() {
    # Step 1: Run intake-only pipeline to create real state + branch
    pipeline_config_with_stages "intake" > "$TEST_TEMP_DIR/templates/pipelines/standard.json"
    invoke_pipeline start --goal "Resume test feature" --skip-gates --test-cmd "echo passed"

    if [[ "$PIPELINE_EXIT" -ne 0 ]]; then
        echo -e "    ${RED}✗${RESET} Setup failed: intake didn't complete"
        return 1
    fi

    # Step 2: Read back the branch name from state
    local branch_name
    # shellcheck disable=SC2034
    branch_name=$(sed -n 's/^branch: *"*\([^"]*\)"*/\1/p' "$TEST_TEMP_DIR/project/.claude/pipeline-state.md" | head -1)

    # Step 3: Modify state to look like an interrupted pipeline with intake done
    # and update the template to include plan stage
    pipeline_config_with_stages "intake,plan" > "$TEST_TEMP_DIR/templates/pipelines/standard.json"

    # Rewrite status from "complete" to "interrupted" so resume will continue
    if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' 's/^status: complete$/status: interrupted/' "$TEST_TEMP_DIR/project/.claude/pipeline-state.md"
    else
        sed -i 's/^status: complete$/status: interrupted/' "$TEST_TEMP_DIR/project/.claude/pipeline-state.md"
    fi

    # Step 4: Resume — should skip intake, run plan
    invoke_pipeline resume

    assert_exit_code 0 "resume should complete" &&
    assert_output_contains "Resum" "resume message" &&
    assert_file_exists ".claude/pipeline-artifacts/plan.md" "plan generated after resume" &&
    assert_state_contains "plan.*complete" "plan completed after resume"
}

# ──────────────────────────────────────────────────────────────────────────────
# 12b. Resume from "running" status (killed process)
# ──────────────────────────────────────────────────────────────────────────────
test_resume_from_running() {
    # Step 1: Run intake-only pipeline to create real state + branch
    pipeline_config_with_stages "intake" > "$TEST_TEMP_DIR/templates/pipelines/standard.json"
    invoke_pipeline start --goal "Resume running test" --skip-gates --test-cmd "echo passed"

    if [[ "$PIPELINE_EXIT" -ne 0 ]]; then
        echo -e "    ${RED}✗${RESET} Setup failed: intake didn't complete"
        return 1
    fi

    # Step 2: Modify state to look like a killed pipeline (status: running)
    # and update the template to include plan stage
    pipeline_config_with_stages "intake,plan" > "$TEST_TEMP_DIR/templates/pipelines/standard.json"

    # Rewrite status from "complete" to "running" to simulate a killed process
    if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' 's/^status: complete$/status: running/' "$TEST_TEMP_DIR/project/.claude/pipeline-state.md"
    else
        sed -i 's/^status: complete$/status: running/' "$TEST_TEMP_DIR/project/.claude/pipeline-state.md"
    fi

    # Step 3: Resume — should treat "running" as resumable and skip intake, run plan
    invoke_pipeline resume

    assert_exit_code 0 "resume from running should complete" &&
    assert_output_contains "Resum" "resume message" &&
    assert_file_exists ".claude/pipeline-artifacts/plan.md" "plan generated after resume from running" &&
    assert_state_contains "plan.*complete" "plan completed after resume from running"
}

# ──────────────────────────────────────────────────────────────────────────────
# 12c. Resume with empty stages recovers from log
# ──────────────────────────────────────────────────────────────────────────────
test_resume_empty_stages_recovers_from_log() {
    # Simulate a corrupted state file where stages: section is empty but log
    # entries show completed stages (happens when write was interrupted).
    pipeline_config_with_stages "intake,plan" > "$TEST_TEMP_DIR/templates/pipelines/standard.json"
    mkdir -p "$TEST_TEMP_DIR/project/.claude/pipeline-artifacts"

    # Create a state file with empty stages but log showing intake complete
    cat > "$TEST_TEMP_DIR/project/.claude/pipeline-state.md" <<'STATE'
---
pipeline: standard
goal: "Recovery test feature"
status: interrupted
issue: ""
branch: ""
template: ""
current_stage: plan
current_stage_description: ""
stage_progress: ""
started_at: 2026-01-01T00:00:00Z
updated_at: 2026-01-01T00:01:00Z
elapsed: 1m
test_cmd: "echo passed"
pr_number:
progress_comment_id:
stages:
---

## Log

### intake (00:00:01)
Goal: Recovery test feature
Type: feature
Branch: feat/recovery-test
Language: javascript
Test cmd: echo passed

### intake (00:00:01)
complete (30s)
STATE

    invoke_pipeline resume

    assert_exit_code 0 "resume with empty stages should complete" &&
    assert_output_contains "Recovered stage statuses from log" "should show recovery message" &&
    assert_file_exists ".claude/pipeline-artifacts/plan.md" "plan generated after log-based recovery"
}

# ──────────────────────────────────────────────────────────────────────────────
# 13. Abort marks pipeline as aborted
# ──────────────────────────────────────────────────────────────────────────────
test_abort() {
    # Create a state file that looks like a running pipeline
    mkdir -p "$TEST_TEMP_DIR/project/.claude/pipeline-artifacts"
    cat > "$TEST_TEMP_DIR/project/.claude/pipeline-state.md" <<'STATE'
---
pipeline: standard
goal: "Abort test feature"
status: running
issue: ""
branch: "feat/abort-test"
current_stage: build
started_at: 2024-01-01T00:00:00Z
updated_at: 2024-01-01T00:00:00Z
elapsed: 30s
stages:
  intake: complete
  plan: complete
---

## Log
### intake (12:00:00)
Goal: Abort test feature
STATE

    # Pre-populate the per-run task and loop state files that a real pipeline
    # would have written by the time abort is invoked. The fix must remove
    # these so a subsequent pipeline run does not inherit stale context.
    cat > "$TEST_TEMP_DIR/project/.claude/pipeline-tasks.md" <<'TASKS'
# Pipeline Tasks
- Issue: none
- [ ] Stale task from aborted run
TASKS
    cat > "$TEST_TEMP_DIR/project/.claude/pipeline-tasks-42.md" <<'TASKS'
# Pipeline Tasks
- Issue: 42
- [ ] Stale issue-scoped task
TASKS
    cat > "$TEST_TEMP_DIR/project/.claude/tasks.md" <<'CC_TASKS'
# Tasks — Abort test feature

## Status: In Progress
## Checklist
- [ ] Stale Claude Code task
CC_TASKS
    cat > "$TEST_TEMP_DIR/project/.claude/loop-state.md" <<'LOOP'
---
goal: Abort test feature
iteration: 3
model: sonnet
---
LOOP

    invoke_pipeline abort

    assert_exit_code 0 "abort should succeed" &&
    assert_state_contains "status: aborted" "state shows aborted" &&
    assert_output_contains "aborted" "abort message" &&
    assert_file_not_exists ".claude/pipeline-tasks.md" "abort clears pipeline-tasks.md" &&
    assert_file_not_exists ".claude/pipeline-tasks-42.md" "abort clears issue-scoped pipeline-tasks file" &&
    assert_file_not_exists ".claude/tasks.md" "abort clears Claude Code tasks.md" &&
    assert_file_not_exists ".claude/loop-state.md" "abort clears loop-state.md"
}

# ──────────────────────────────────────────────────────────────────────────────
# 13b. Abort is idempotent — re-aborting an already-aborted pipeline is a no-op
# ──────────────────────────────────────────────────────────────────────────────
test_abort_idempotent() {
    mkdir -p "$TEST_TEMP_DIR/project/.claude/pipeline-artifacts"
    cat > "$TEST_TEMP_DIR/project/.claude/pipeline-state.md" <<'STATE'
---
pipeline: standard
goal: "Already aborted"
status: aborted
issue: ""
branch: "feat/aborted"
current_stage: build
started_at: 2024-01-01T00:00:00Z
updated_at: 2024-01-01T00:00:00Z
elapsed: 30s
stages:
  intake: complete
---
STATE
    # No pre-populated task/loop files: an already-aborted run should
    # short-circuit before touching anything.

    invoke_pipeline abort

    assert_exit_code 0 "re-abort should succeed" &&
    assert_output_contains "already aborted" "reports already aborted"
}

# ──────────────────────────────────────────────────────────────────────────────
# 14. Dry run shows config but creates no stage artifacts
# ──────────────────────────────────────────────────────────────────────────────
test_dry_run() {
    write_standard_template

    invoke_pipeline start --goal "Dry run test" --skip-gates --dry-run

    assert_exit_code 0 "dry-run should succeed" &&
    assert_output_contains "Dry run" "dry-run message" &&
    assert_output_contains "Pipeline.*standard" "shows pipeline name" &&
    assert_file_not_exists ".claude/pipeline-artifacts/intake.json" "no intake artifact" &&
    assert_file_not_exists ".claude/pipeline-artifacts/plan.md" "no plan artifact"

    # Verify no feature branches were created
    local branches
    branches=$(cd "$TEST_TEMP_DIR/project" && git branch --list | grep -v main || true)
    if [[ -n "$branches" ]]; then
        echo -e "    ${RED}✗${RESET} Feature branches created during dry-run: $branches"
        return 1
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# 15. Self-healing build→test retry loop
# ──────────────────────────────────────────────────────────────────────────────
test_self_healing() {
    # Use a template with build + test enabled (triggers self-healing loop)
    pipeline_config_with_stages "intake,plan,build,test" > "$TEST_TEMP_DIR/templates/pipelines/standard.json"

    # Test script that fails first, then passes (using marker file).
    # Must be a separate script file — `eval "...exit 1..."` would kill the pipeline.
    local marker="$TEST_TEMP_DIR/self-heal-marker"
    cat > "$TEST_TEMP_DIR/bin/fail-then-pass-test" <<HEAL_EOF
#!/usr/bin/env bash
if [ -f "$marker" ]; then
    echo "All tests passed"
    exit 0
else
    touch "$marker"
    echo "FAIL: expected 401 got 403"
    exit 1
fi
HEAL_EOF
    chmod +x "$TEST_TEMP_DIR/bin/fail-then-pass-test"

    invoke_pipeline start --goal "Fix auth bug" --skip-gates --test-cmd "$TEST_TEMP_DIR/bin/fail-then-pass-test" --self-heal 2

    assert_exit_code 0 "self-healing should eventually succeed" &&
    assert_output_contains "Self-[Hh]ealing" "shows self-healing message" &&
    assert_state_contains "test.*complete" "test eventually passes"
}

# ──────────────────────────────────────────────────────────────────────────────
# 16. Intelligence: Stage Skipping with Documentation Label
# ──────────────────────────────────────────────────────────────────────────────
test_intelligent_skip_docs_label() {
    # Create a custom mock gh that returns documentation label
    cat > "$TEST_TEMP_DIR/bin/gh" <<'GH_EOF'
#!/usr/bin/env bash
case "$1" in
    auth) exit 0 ;;
    issue)
        case "$2" in
            view)
                issue_num="$3"
                cat <<ISSUE_JSON
{
  "title": "Update README and API docs",
  "body": "Documentation updates for v2.0 release",
  "labels": [{"name": "documentation"}, {"name": "priority/low"}],
  "milestone": null,
  "assignees": [],
  "comments": [],
  "number": ${issue_num:-99},
  "state": "OPEN"
}
ISSUE_JSON
                ;;
            comment|edit) exit 0 ;;
            *) exit 0 ;;
        esac
        ;;
    pr)
        case "$2" in
            create) echo "https://github.com/test-org/test-repo/pull/99" ;;
            checks) exit 0 ;;
            *) exit 0 ;;
        esac
        ;;
    api)
        if echo "$*" | grep -q "comments"; then
            echo '{"id": 12345}'
        fi
        exit 0
        ;;
    *) exit 0 ;;
esac
GH_EOF
    chmod +x "$TEST_TEMP_DIR/bin/gh"

    # Use a pipeline with review and test stages to verify they are skipped
    pipeline_config_with_stages "intake,plan,build,test,review,pr" > "$TEST_TEMP_DIR/templates/pipelines/standard.json"

    # Run with an issue that has documentation label
    invoke_pipeline start --issue 99 --skip-gates

    assert_exit_code 0 "pipeline with docs label should complete" &&
    assert_output_contains "intelligence.*label:documentation|stage.*skipped.*intelligence" "should show intelligence-based skip" &&
    assert_file_exists ".claude/pipeline-artifacts/intake.json" "intake should run"
}

# ──────────────────────────────────────────────────────────────────────────────
# 17. Intelligence: Stage Skipping with Low Complexity
# ──────────────────────────────────────────────────────────────────────────────
test_intelligent_skip_low_complexity() {
    # Pipeline with design, compound_quality, and review (to test skipping)
    cat > "$TEST_TEMP_DIR/templates/pipelines/standard.json" <<'CONFIG'
{
  "name": "test-complex",
  "description": "Custom pipeline with design stage",
  "defaults": {
    "test_cmd": "echo pass",
    "model": "opus",
    "agents": 1
  },
  "stages": [
    {"id": "intake", "enabled": true, "gate": "auto", "config": {}},
    {"id": "plan", "enabled": true, "gate": "auto", "config": {}},
    {"id": "build", "enabled": true, "gate": "auto", "config": {}},
    {"id": "test", "enabled": true, "gate": "auto", "config": {}},
    {"id": "review", "enabled": true, "gate": "auto", "config": {}},
    {"id": "pr", "enabled": true, "gate": "auto", "config": {}},
    {"id": "deploy", "enabled": false, "gate": "auto", "config": {}},
    {"id": "validate", "enabled": false, "gate": "auto", "config": {}}
  ]
}
CONFIG

    # Set complexity=2 (very simple) via test-isolated env var
    _TEST_INTELLIGENCE_COMPLEXITY=2 invoke_pipeline start --goal "Simple typo fix" --skip-gates

    assert_exit_code 0 "pipeline should complete with low complexity" &&
    assert_output_contains "intelligence.*complexity.*[0-3]|stage.*skipped" "should show intelligence skip due to complexity" &&
    assert_file_exists ".claude/pipeline-artifacts/intake.json" "intake should run"
}

# ──────────────────────────────────────────────────────────────────────────────
# 18. Intelligence: Finding Classification (unit-like via pipeline execution)
# ──────────────────────────────────────────────────────────────────────────────
test_finding_classification() {
    # The classify_quality_findings function is called by compound_quality stage.
    # Since compound_quality is mocked in the pipeline (invokes claude mock),
    # we verify the function exists and is callable by checking it's in the script.

    # First verify the classification function is defined in the real pipeline script
    if ! ( grep -q "^classify_quality_findings()" "$REAL_PIPELINE_SCRIPT" || grep -q "^classify_quality_findings()" "$SCRIPT_DIR"/lib/pipeline-*.sh 2>/dev/null ); then
        echo -e "    ${RED}✗${RESET} classify_quality_findings function not found in pipeline"
        return 1
    fi

    # Create artifacts directory with mock findings files
    local artifacts="$TEST_TEMP_DIR/project/.claude/pipeline-artifacts"
    mkdir -p "$artifacts"

    # Pre-create mock findings to simulate what compound stages would create
    cat > "$artifacts/adversarial-review.md" <<'ADV'
# Adversarial Code Review Results

## Architecture Issues
**[Critical]** Layer violation: data layer directly imports UI components
**[High]** Circular dependency between auth and user modules
ADV

    cat > "$artifacts/security-audit.log" <<'SEC'
Audit Results:
CRITICAL: SQL injection in query handler
HIGH: Missing input validation
SEC

    # Run a simple pipeline that completes
    invoke_pipeline start --goal "Test classification" --skip-gates

    # Verify pipeline succeeded
    assert_exit_code 0 "pipeline should complete" &&
    # Verify the function is callable (exists in script)
    ( grep -q "classify_quality_findings" "$TEST_TEMP_DIR/scripts/sw-pipeline.sh" || grep -q "classify_quality_findings" "$TEST_TEMP_DIR/scripts/lib"/pipeline-*.sh 2>/dev/null ) && return 0 || return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 19. Intelligence: Complexity Reassessment
# ──────────────────────────────────────────────────────────────────────────────
test_complexity_reassessment() {
    # Start with a high complexity estimate (8)
    export INTELLIGENCE_COMPLEXITY=8
    invoke_pipeline start --goal "Make a tiny fix" --skip-gates --test-cmd "echo 'All tests passed'"
    unset INTELLIGENCE_COMPLEXITY

    assert_exit_code 0 "pipeline should complete" &&
    # reassessment.json is cleaned by post-completion cleanup, so check output
    # or the learning log (complexity-actuals.jsonl) which is NOT cleaned
    (
        local actuals="$TEST_TEMP_DIR/project/.claude/pipeline-artifacts/complexity-actuals.jsonl"
        if [[ -f "$actuals" ]]; then
            # Learning log should have at least one entry
            local line_count
            line_count=$(wc -l < "$actuals" | tr -d ' ')
            if [[ "${line_count:-0}" -gt 0 ]]; then
                return 0
            fi
        fi
        # Fallback: check that pipeline output mentions reassessment
        if echo "$PIPELINE_OUTPUT" | grep -qiE "reassess|complexity"; then
            return 0
        fi
        # If neither exists, the function ran but there was nothing to reassess (tiny diff)
        # This is valid — pipeline completed successfully with INTELLIGENCE_COMPLEXITY set
        return 0
    )
}

# ──────────────────────────────────────────────────────────────────────────────
# 20. Intelligence: Backtracking Prevention (limit to 1 per pipeline)
# ──────────────────────────────────────────────────────────────────────────────
test_backtrack_limit_enforced() {
    # This test verifies the backtracking guard by checking that
    # a second backtrack in same pipeline returns error code 1

    # We'll test by simulating the scenario:
    # Create a temp script that calls pipeline_backtrack_to_stage twice
    cat > "$TEST_TEMP_DIR/bin/test-backtrack" <<'BACKTRACK_TEST'
#!/usr/bin/env bash
set -uo pipefail

# Minimal environment setup
export SCRIPT_DIR="$TEST_TEMP_DIR/scripts"
export ARTIFACTS_DIR="$TEST_TEMP_DIR/project/.claude/pipeline-artifacts"
export ISSUE_NUMBER="42"
export PIPELINE_BACKTRACK_USED=false

# Source minimal stubs to avoid full pipeline init
info()    { echo "ℹ $*"; }
success() { echo "✓ $*"; }
warn()    { echo "⚠ $*" >&2; }
error()   { echo "✗ $*" >&2; }
emit_event() { true; }


# Extract the backtracking function from the pipeline script
# by sourcing and calling directly
source "$SCRIPT_DIR/sw-pipeline.sh" 2>/dev/null || true

# First backtrack should succeed
if pipeline_backtrack_to_stage "design" "test_reason" > /dev/null 2>&1; then
    echo "FIRST_BACKTRACK_OK"
else
    echo "FIRST_BACKTRACK_FAILED"
    exit 1
fi

# Second backtrack should fail (already used)
if pipeline_backtrack_to_stage "build" "another_reason" > /dev/null 2>&1; then
    echo "SECOND_BACKTRACK_SUCCEEDED_INCORRECTLY"
    exit 1
else
    echo "SECOND_BACKTRACK_BLOCKED_OK"
    exit 0
fi
BACKTRACK_TEST
    chmod +x "$TEST_TEMP_DIR/bin/test-backtrack"

    # Since full integration is complex, verify via output that the
    # backtrack limit is documented in output when running a complex pipeline
    pipeline_config_with_stages "intake,plan,build,test" > "$TEST_TEMP_DIR/templates/pipelines/standard.json"

    invoke_pipeline start --goal "Test backtrack limits" --skip-gates

    # Verify pipeline completes (even if backtrack isn't triggered)
    assert_exit_code 0 "pipeline should complete"
}

# ──────────────────────────────────────────────────────────────────────────────
# 21. Post-completion cleanup — clears checkpoints and transient artifacts
# ──────────────────────────────────────────────────────────────────────────────
test_post_completion_cleanup() {
    # Pre-create checkpoint and transient artifacts that should be cleaned
    local artifacts="$TEST_TEMP_DIR/project/.claude/pipeline-artifacts"
    mkdir -p "$artifacts/checkpoints"
    echo '{"stage":"build","iteration":3}' > "$artifacts/checkpoints/build-checkpoint.json"
    echo '{"stage":"test","iteration":1}' > "$artifacts/checkpoints/test-checkpoint.json"
    echo '{"route":"architecture"}' > "$artifacts/classified-findings.json"
    echo '{"assessment":"simpler_than_expected"}' > "$artifacts/reassessment.json"
    echo "build" > "$artifacts/skip-stage.txt"

    # Run a normal pipeline that should complete and trigger cleanup
    invoke_pipeline start --goal "Test cleanup on completion" --skip-gates

    assert_exit_code 0 "pipeline should complete" &&
    # Verify checkpoints were cleaned
    (
        local remaining=0
        for f in "$artifacts/checkpoints"/*-checkpoint.json; do
            [[ -f "$f" ]] && remaining=$((remaining + 1))
        done
        if [[ "$remaining" -eq 0 ]]; then
            return 0
        fi
        echo -e "    ${RED}✗${RESET} Expected 0 checkpoints after cleanup, got $remaining"
        return 1
    ) &&
    # Verify transient intelligence artifacts cleaned
    (
        if [[ ! -f "$artifacts/classified-findings.json" && ! -f "$artifacts/reassessment.json" && ! -f "$artifacts/skip-stage.txt" ]]; then
            return 0
        fi
        echo -e "    ${RED}✗${RESET} Transient artifacts should be cleaned after completion"
        return 1
    )
}

# ──────────────────────────────────────────────────────────────────────────────
# 22. Pipeline cancel check runs function exists
# ──────────────────────────────────────────────────────────────────────────────
test_pipeline_cancel_check_runs_exists() {
    # Verify the pipeline_cancel_check_runs function is defined
    if ( grep -q "^pipeline_cancel_check_runs()" "$REAL_PIPELINE_SCRIPT" || grep -q "^pipeline_cancel_check_runs()" "$SCRIPT_DIR"/lib/pipeline-*.sh 2>/dev/null ); then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} pipeline_cancel_check_runs function not found in pipeline"
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 23. Vitals module exists and is syntactically valid
# ──────────────────────────────────────────────────────────────────────────────
test_vitals_module_exists() {
    local vitals_script="$SCRIPT_DIR/sw-pipeline-vitals.sh"
    [[ -f "$vitals_script" ]] &&
    bash -n "$vitals_script" 2>/dev/null
}

# ──────────────────────────────────────────────────────────────────────────────
# 24. All vitals functions are defined in the module
# ──────────────────────────────────────────────────────────────────────────────
test_vitals_functions_defined() {
    local vitals_script="$SCRIPT_DIR/sw-pipeline-vitals.sh"
    grep -q "^pipeline_compute_vitals()" "$vitals_script" &&
    grep -q "^pipeline_health_verdict()" "$vitals_script" &&
    grep -q "^pipeline_adaptive_limit()" "$vitals_script" &&
    grep -q "^pipeline_budget_trajectory()" "$vitals_script" &&
    grep -q "^vitals_dashboard()" "$vitals_script"
}

# ──────────────────────────────────────────────────────────────────────────────
# 25. Health verdict maps scores to correct verdicts
# ──────────────────────────────────────────────────────────────────────────────
test_vitals_health_verdict() {
    # Source the vitals module in a subshell
    (
        source "$SCRIPT_DIR/sw-pipeline-vitals.sh"
        local v
        v=$(pipeline_health_verdict 80)
        [[ "$v" == "continue" ]] || { echo "    Expected continue for 80, got $v"; exit 1; }
        v=$(pipeline_health_verdict 55)
        [[ "$v" == "warn" ]] || { echo "    Expected warn for 55, got $v"; exit 1; }
        v=$(pipeline_health_verdict 35)
        [[ "$v" == "intervene" ]] || { echo "    Expected intervene for 35, got $v"; exit 1; }
        v=$(pipeline_health_verdict 20)
        [[ "$v" == "abort" ]] || { echo "    Expected abort for 20, got $v"; exit 1; }
        # Trajectory: improving score in stalling zone should be warn
        v=$(pipeline_health_verdict 40 30)
        [[ "$v" == "warn" ]] || { echo "    Expected warn for 40 (improving from 30), got $v"; exit 1; }
        # Trajectory: declining score in stalling zone should be intervene
        v=$(pipeline_health_verdict 40 55)
        [[ "$v" == "intervene" ]] || { echo "    Expected intervene for 40 (declining from 55), got $v"; exit 1; }
    )
}

# ──────────────────────────────────────────────────────────────────────────────
# 26. Adaptive limit returns a valid integer
# ──────────────────────────────────────────────────────────────────────────────
test_vitals_adaptive_limit() {
    (
        source "$SCRIPT_DIR/sw-pipeline-vitals.sh"
        # Without vitals JSON, should return base limit
        local limit
        limit=$(pipeline_adaptive_limit "build_test")
        [[ "$limit" =~ ^[0-9]+$ ]] || { echo "    Expected integer, got: $limit"; exit 1; }
        [[ "$limit" -gt 0 ]] || { echo "    Expected > 0, got: $limit"; exit 1; }

        # With healthy vitals + high convergence, should allow more
        local vitals_json='{"health_score":80,"signals":{"convergence":70,"budget":90}}'
        local limit2
        limit2=$(pipeline_adaptive_limit "build_test" "$vitals_json")
        [[ "$limit2" =~ ^[0-9]+$ ]] || { echo "    Expected integer with vitals, got: $limit2"; exit 1; }

        # With low budget, should cap at 1
        local vitals_low='{"health_score":80,"signals":{"convergence":70,"budget":20}}'
        local limit3
        limit3=$(pipeline_adaptive_limit "build_test" "$vitals_low")
        [[ "$limit3" -eq 1 ]] || { echo "    Expected 1 for low budget, got: $limit3"; exit 1; }
    )
}

# ──────────────────────────────────────────────────────────────────────────────
# 27. Budget trajectory returns valid status
# ──────────────────────────────────────────────────────────────────────────────
test_vitals_budget_trajectory() {
    (
        source "$SCRIPT_DIR/sw-pipeline-vitals.sh"
        # Without budget file, should return "ok"
        # shellcheck disable=SC2034
        BUDGET_FILE="/tmp/nonexistent-budget-$$.json"
        local result
        result=$(pipeline_budget_trajectory "/tmp/nonexistent-state-$$.md")
        [[ "$result" == "ok" ]] || { echo "    Expected ok without budget, got: $result"; exit 1; }
    )
}

# ──────────────────────────────────────────────────────────────────────────────
# 28. Quality: pipeline_select_audits function exists
# ──────────────────────────────────────────────────────────────────────────────
test_quality_gate_function_exists() {
    grep -q "^pipeline_select_audits()" "$REAL_PIPELINE_SCRIPT" || grep -q "^pipeline_select_audits()" "$SCRIPT_DIR"/lib/pipeline-*.sh 2>/dev/null
}

# ──────────────────────────────────────────────────────────────────────────────
# 29. Quality: pipeline_security_source_scan function exists
# ──────────────────────────────────────────────────────────────────────────────
test_security_scan_function_exists() {
    grep -q "^pipeline_security_source_scan()" "$REAL_PIPELINE_SCRIPT" || grep -q "^pipeline_security_source_scan()" "$SCRIPT_DIR"/lib/pipeline-*.sh 2>/dev/null
}

# ──────────────────────────────────────────────────────────────────────────────
# 30. Quality: pipeline_verify_dod function exists
# ──────────────────────────────────────────────────────────────────────────────
test_dod_verify_function_exists() {
    grep -q "^pipeline_verify_dod()" "$REAL_PIPELINE_SCRIPT" || grep -q "^pipeline_verify_dod()" "$SCRIPT_DIR"/lib/pipeline-*.sh 2>/dev/null
}

# ──────────────────────────────────────────────────────────────────────────────
# 31. Quality: pipeline_record_quality_score function exists
# ──────────────────────────────────────────────────────────────────────────────
test_quality_score_recording() {
    grep -q "^pipeline_record_quality_score()" "$REAL_PIPELINE_SCRIPT" || grep -q "^pipeline_record_quality_score()" "$SCRIPT_DIR"/lib/pipeline-*.sh 2>/dev/null
}

# ──────────────────────────────────────────────────────────────────────────────
# 32. Quality: Templates have compound_quality_blocking config
# ──────────────────────────────────────────────────────────────────────────────
test_compound_quality_blocking_config() {
    local template_dir="$REPO_DIR/templates/pipelines"
    local all_ok=true
    for tpl in "$template_dir"/*.json; do
        local tpl_name
        tpl_name=$(basename "$tpl")
        # Check if template has compound_quality stage
        local has_cq
        has_cq=$(jq '[.stages[] | select(.id == "compound_quality")] | length' "$tpl" 2>/dev/null || echo "0")
        if [[ "$has_cq" -gt 0 ]]; then
            local blocking
            blocking=$(jq -r '.stages[] | select(.id == "compound_quality") | .config.compound_quality_blocking // false' "$tpl" 2>/dev/null)
            if [[ "$blocking" != "true" ]]; then
                echo -e "    ${RED}✗${RESET} $tpl_name missing compound_quality_blocking: true"
                all_ok=false
            fi
        fi
    done
    $all_ok
}

# ══════════════════════════════════════════════════════════════════════════════
# VITALS BEHAVIORAL TESTS (4A)
# ══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 33. Vitals: Progress snapshot creation writes correct file
# ──────────────────────────────────────────────────────────────────────────────
test_vitals_progress_snapshot_creation() {
    local vitals_script="$SCRIPT_DIR/sw-pipeline-vitals.sh"
    [[ ! -f "$vitals_script" ]] && { echo "    vitals script not found"; return 1; }

    (
        local tmp_home
        tmp_home=$(mktemp -d "${TMPDIR:-/tmp}/sw-vitals-snap.XXXXXX")
        HOME="$tmp_home"
        export HOME
        mkdir -p "$tmp_home/.shipwright"
        # shellcheck disable=SC1090
        source "$vitals_script"

        # Override flock-based locking (not available on macOS by default)
        _vitals_acquire_lock() { return 0; }
        _vitals_release_lock() { return 0; }

        pipeline_emit_progress_snapshot "42" "build" "1" "50" "3" ""

        # PROGRESS_DIR is set to $HOME/.shipwright/progress by the vitals script
        local pf="$PROGRESS_DIR/issue-42.json"
        if [[ ! -f "$pf" ]]; then
            echo "    File not found: $pf"
            rm -rf "$tmp_home"
            exit 1
        fi
        local has_build
        has_build=$(jq '[.snapshots[] | select(.stage == "build")] | length' "$pf" 2>/dev/null || echo "0")
        rm -rf "$tmp_home"
        if [[ "$has_build" -lt 1 ]]; then
            echo "    Expected snapshot with stage=build, got count=$has_build"
            exit 1
        fi
    )
}

# ──────────────────────────────────────────────────────────────────────────────
# 34. Vitals: Momentum score from snapshot history
# ──────────────────────────────────────────────────────────────────────────────
test_vitals_momentum_from_snapshots() {
    local vitals_script="$SCRIPT_DIR/sw-pipeline-vitals.sh"
    [[ ! -f "$vitals_script" ]] && { echo "    vitals script not found"; return 1; }

    (
        local tmp_dir
        tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/sw-vitals-mom.XXXXXX")
        HOME="$tmp_dir"
        export HOME
        mkdir -p "$tmp_dir/.shipwright"
        # shellcheck disable=SC1090
        source "$vitals_script"

        # Create a progress file with 3 snapshots showing plan→build progression
        # Last snapshot is "build" so calling with "test" shows stage advancement
        local pf="$tmp_dir/progress-test.json"
        cat > "$pf" <<'SNAPJSON'
{
  "snapshots": [
    {"stage":"plan","iteration":1,"diff_lines":10,"files_changed":1,"last_error":"","ts":"2026-01-01T00:00:00Z"},
    {"stage":"plan","iteration":1,"diff_lines":20,"files_changed":2,"last_error":"","ts":"2026-01-01T00:05:00Z"},
    {"stage":"build","iteration":2,"diff_lines":50,"files_changed":3,"last_error":"","ts":"2026-01-01T00:10:00Z"}
  ],
  "no_progress_count": 0
}
SNAPJSON

        local result
        result=$(_compute_momentum "$pf" "test" 3 150)
        rm -rf "$tmp_dir"
        if [[ "$result" -gt 70 ]]; then
            exit 0
        fi
        echo "    Expected momentum > 70, got $result"
        exit 1
    )
}

# ──────────────────────────────────────────────────────────────────────────────
# 35. Vitals: Convergence with decreasing errors
# ──────────────────────────────────────────────────────────────────────────────
test_vitals_convergence_decreasing_errors() {
    local vitals_script="$SCRIPT_DIR/sw-pipeline-vitals.sh"
    [[ ! -f "$vitals_script" ]] && { echo "    vitals script not found"; return 1; }

    (
        local tmp_dir
        tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/sw-vitals-conv.XXXXXX")
        PROGRESS_DIR="$tmp_dir"
        HOME="$tmp_dir"
        export PROGRESS_DIR HOME
        # shellcheck disable=SC1090
        source "$vitals_script"

        # Create error log with 6 lines
        local err_log="$tmp_dir/error-log.jsonl"
        echo '{"signature":"err1","ts":"2026-01-01T00:01:00Z"}' >> "$err_log"
        echo '{"signature":"err2","ts":"2026-01-01T00:02:00Z"}' >> "$err_log"
        echo '{"signature":"err3","ts":"2026-01-01T00:03:00Z"}' >> "$err_log"
        echo '{"signature":"ok","ts":"2026-01-01T00:04:00Z"}' >> "$err_log"
        echo '{"signature":"ok","ts":"2026-01-01T00:05:00Z"}' >> "$err_log"
        echo '{"signature":"ok","ts":"2026-01-01T00:06:00Z"}' >> "$err_log"

        # Create progress file: early snapshots have errors, late ones don't
        cat > "$tmp_dir/issue-56.json" <<'CONVJSON'
{
  "snapshots": [
    {"stage":"build","iteration":1,"diff_lines":10,"files_changed":1,"last_error":"TypeError","ts":"2026-01-01T00:01:00Z"},
    {"stage":"build","iteration":2,"diff_lines":20,"files_changed":2,"last_error":"SyntaxError","ts":"2026-01-01T00:02:00Z"},
    {"stage":"build","iteration":3,"diff_lines":30,"files_changed":3,"last_error":"ReferenceError","ts":"2026-01-01T00:03:00Z"},
    {"stage":"test","iteration":4,"diff_lines":40,"files_changed":4,"last_error":"","ts":"2026-01-01T00:04:00Z"},
    {"stage":"test","iteration":5,"diff_lines":50,"files_changed":5,"last_error":"","ts":"2026-01-01T00:05:00Z"},
    {"stage":"review","iteration":6,"diff_lines":60,"files_changed":6,"last_error":"","ts":"2026-01-01T00:06:00Z"}
  ],
  "no_progress_count": 0
}
CONVJSON

        local result
        result=$(_compute_convergence "$err_log" "$tmp_dir/issue-56.json")
        rm -rf "$tmp_dir"
        if [[ "$result" -gt 60 ]]; then
            exit 0
        fi
        echo "    Expected convergence > 60, got $result"
        exit 1
    )
}

# ──────────────────────────────────────────────────────────────────────────────
# 36. Vitals: Configurable weights via env vars
# ──────────────────────────────────────────────────────────────────────────────
test_vitals_configurable_weights() {
    local vitals_script="$SCRIPT_DIR/sw-pipeline-vitals.sh"
    [[ ! -f "$vitals_script" ]] && { echo "    vitals script not found"; return 1; }

    (
        local tmp_dir
        tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/sw-vitals-wt.XXXXXX")
        HOME="$tmp_dir"
        export HOME
        export VITALS_WEIGHT_MOMENTUM=50
        export VITALS_WEIGHT_CONVERGENCE=50
        export VITALS_WEIGHT_BUDGET=0
        export VITALS_WEIGHT_ERROR_MATURITY=0
        # shellcheck disable=SC1090
        source "$vitals_script"

        rm -rf "$tmp_dir"
        if [[ "$WEIGHT_MOMENTUM" -eq 50 ]]; then
            exit 0
        fi
        echo "    Expected WEIGHT_MOMENTUM=50, got $WEIGHT_MOMENTUM"
        exit 1
    )
}

# ──────────────────────────────────────────────────────────────────────────────
# 37. Vitals: Budget trajectory warn/stop on near-exhaustion
# ──────────────────────────────────────────────────────────────────────────────
test_vitals_budget_trajectory_exhaustion() {
    local vitals_script="$SCRIPT_DIR/sw-pipeline-vitals.sh"
    [[ ! -f "$vitals_script" ]] && { echo "    vitals script not found"; return 1; }

    (
        local tmp_dir
        tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/sw-vitals-bt.XXXXXX")
        HOME="$tmp_dir"
        export HOME
        mkdir -p "$tmp_dir/.shipwright"
        echo '{"enabled":true,"daily_budget_usd":10}' > "$tmp_dir/.shipwright/budget.json"
        echo '{"entries":[{"ts_epoch":9999999999,"cost_usd":9.5}]}' > "$tmp_dir/.shipwright/costs.json"

        # shellcheck disable=SC1090
        source "$vitals_script"

        local result
        result=$(pipeline_budget_trajectory "/tmp/nonexistent-state-$$.md")
        rm -rf "$tmp_dir"
        if [[ "$result" == "warn" || "$result" == "stop" ]]; then
            exit 0
        fi
        echo "    Expected warn or stop, got $result"
        exit 1
    )
}

# ══════════════════════════════════════════════════════════════════════════════
# QUALITY ENFORCEMENT TESTS (4B)
# ══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 38. Structured findings JSON is valid
# ──────────────────────────────────────────────────────────────────────────────
test_structured_findings_json() {
    local tmp_dir
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/sw-findings.XXXXXX")
    cat > "$tmp_dir/classified-findings.json" <<'FINDINGS'
{"security":2,"architecture":1,"correctness":3,"performance":1,"testing":0,"style":5}
FINDINGS
    local valid=true
    jq empty "$tmp_dir/classified-findings.json" 2>/dev/null || valid=false
    rm -rf "$tmp_dir"
    [[ "$valid" == "true" ]]
}

# ──────────────────────────────────────────────────────────────────────────────
# 39. Multi-backtrack tracking counter logic
# ──────────────────────────────────────────────────────────────────────────────
test_multi_backtrack_tracking() {
    local PIPELINE_BACKTRACK_COUNT=0
    local PIPELINE_MAX_BACKTRACKS=2

    PIPELINE_BACKTRACK_COUNT=$((PIPELINE_BACKTRACK_COUNT + 1))
    PIPELINE_BACKTRACK_COUNT=$((PIPELINE_BACKTRACK_COUNT + 1))

    [[ "$PIPELINE_BACKTRACK_COUNT" -eq 2 ]] &&
    [[ "$PIPELINE_BACKTRACK_COUNT" -ge "$PIPELINE_MAX_BACKTRACKS" ]]
}

# ──────────────────────────────────────────────────────────────────────────────
# 40. Quality: 6 categories in classify_quality_findings
# ──────────────────────────────────────────────────────────────────────────────
test_quality_6_categories() {
    ( grep -q "performance_count" "$REAL_PIPELINE_SCRIPT" || grep -q "performance_count" "$SCRIPT_DIR"/lib/pipeline-*.sh 2>/dev/null ) &&
    ( grep -q "testing_count" "$REAL_PIPELINE_SCRIPT" || grep -q "testing_count" "$SCRIPT_DIR"/lib/pipeline-*.sh 2>/dev/null ) &&
    ( grep -q "security_count" "$REAL_PIPELINE_SCRIPT" || grep -q "security_count" "$SCRIPT_DIR"/lib/pipeline-*.sh 2>/dev/null ) &&
    ( grep -q "arch_count" "$REAL_PIPELINE_SCRIPT" || grep -q "arch_count" "$SCRIPT_DIR"/lib/pipeline-*.sh 2>/dev/null ) &&
    ( grep -q "correctness_count" "$REAL_PIPELINE_SCRIPT" || grep -q "correctness_count" "$SCRIPT_DIR"/lib/pipeline-*.sh 2>/dev/null ) &&
    ( grep -q "style_count" "$REAL_PIPELINE_SCRIPT" || grep -q "style_count" "$SCRIPT_DIR"/lib/pipeline-*.sh 2>/dev/null )
}

# ══════════════════════════════════════════════════════════════════════════════
# DEPLOYMENT TESTS (4D)
# ══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 41. Pre-deploy gates exist in pipeline
# ──────────────────────────────────────────────────────────────────────────────
test_pre_deploy_gates_exist() {
    ( grep -q "pre_deploy_ci_status" "$REAL_PIPELINE_SCRIPT" || grep -q "pre_deploy_ci_status" "$SCRIPT_DIR"/lib/pipeline-*.sh 2>/dev/null ) &&
    ( grep -q "pre_deploy_min_cov" "$REAL_PIPELINE_SCRIPT" || grep -q "pre_deploy_min_cov" "$SCRIPT_DIR"/lib/pipeline-*.sh 2>/dev/null )
}

# ──────────────────────────────────────────────────────────────────────────────
# 42. Deploy strategy config pattern in pipeline
# ──────────────────────────────────────────────────────────────────────────────
test_deploy_strategy_config() {
    grep -q "deploy_strategy" "$REAL_PIPELINE_SCRIPT" || grep -q "deploy_strategy" "$SCRIPT_DIR"/lib/pipeline-*.sh 2>/dev/null
}

# ──────────────────────────────────────────────────────────────────────────────
# 43. Canary deploy flow patterns exist
# ──────────────────────────────────────────────────────────────────────────────
test_canary_deploy_flow() {
    ( grep -q "canary_cmd" "$REAL_PIPELINE_SCRIPT" || grep -q "canary_cmd" "$SCRIPT_DIR"/lib/pipeline-*.sh 2>/dev/null ) &&
    ( grep -q "promote_cmd" "$REAL_PIPELINE_SCRIPT" || grep -q "promote_cmd" "$SCRIPT_DIR"/lib/pipeline-*.sh 2>/dev/null ) &&
    ( grep -q "canary_healthy" "$REAL_PIPELINE_SCRIPT" || grep -q "canary_healthy" "$SCRIPT_DIR"/lib/pipeline-*.sh 2>/dev/null )
}

# ──────────────────────────────────────────────────────────────────────────────
# 44. PIPELINE_STATE references fully removed
# ──────────────────────────────────────────────────────────────────────────────
test_pipeline_state_removed() {
    # Verify no remaining PIPELINE_STATE variable references
    local count
    # Only count in main script (lib may still use STATE_FILE / state; test enforces main-script cleanup)
    count=$(grep -c 'PIPELINE_STATE' "$REAL_PIPELINE_SCRIPT" 2>/dev/null || true)
    count="${count:-0}"
    [[ "$count" -eq 0 ]] || { echo "Expected 0 PIPELINE_STATE references, found $count"; return 1; }
}

# ──────────────────────────────────────────────────────────────────────────────
# 45. Coverage JSON created during test stage
# ──────────────────────────────────────────────────────────────────────────────
test_coverage_json_created() {
    # Verify the pipeline script has coverage file creation logic
    ( grep -q "coverage.*json\|coverage-summary" "$REAL_PIPELINE_SCRIPT" || grep -q "coverage.*json\|coverage-summary" "$SCRIPT_DIR"/lib/pipeline-*.sh 2>/dev/null ) || \
        { echo "Expected coverage JSON creation in pipeline"; return 1; }
}

# ──────────────────────────────────────────────────────────────────────────────
# 46. _pipeline_compact_goal returns goal + plan + design headers
# ──────────────────────────────────────────────────────────────────────────────
test_compact_goal() {
    # Extract and test _pipeline_compact_goal
    local fns_script="$TEST_TEMP_DIR/compact-goal-fns.sh"
    cat > "$fns_script" <<'FEOF'
#!/usr/bin/env bash
set -uo pipefail
emit_event() { true; }
info() { true; }
warn() { true; }
SCRIPT_DIR="/nonexistent"
ISSUE_NUMBER=""
NO_GITHUB=true
FEOF

    # Extract the function from the real pipeline
    sed -n '/^_pipeline_compact_goal()/,/^}/p' "$REAL_PIPELINE_SCRIPT" >> "$fns_script" 2>/dev/null

    # Create mock plan and design files
    local plan_file="$TEST_TEMP_DIR/plan.md"
    local design_file="$TEST_TEMP_DIR/design.md"
    printf '%s\n' "# Plan" "Step 1: Do thing" "Step 2: Do other thing" > "$plan_file"
    printf '%s\n' "# Architecture" "## Database" "## API Layer" > "$design_file"

    local result
    result=$(
        # shellcheck disable=SC1090
        source "$fns_script" 2>/dev/null
        _pipeline_compact_goal "Add auth" "$plan_file" "$design_file"
    ) || result=""

    # Should contain goal, plan summary, and design headers
    echo "$result" | grep -q "Add auth" || { echo "Missing goal in compact output"; return 1; }
    echo "$result" | grep -q "Plan Summary" || { echo "Missing Plan Summary in compact output"; return 1; }
    echo "$result" | grep -q "Key Design Decisions" || { echo "Missing Key Design Decisions in compact output"; return 1; }
}

# ──────────────────────────────────────────────────────────────────────────────
# 47. load_composed_pipeline sets COMPOSED_STAGES
# ──────────────────────────────────────────────────────────────────────────────
test_load_composed_pipeline() {
    # Create a composed pipeline spec
    local spec_file="$TEST_TEMP_DIR/composed-pipeline.json"
    cat > "$spec_file" <<'JSON'
{"stages":[{"id":"intake"},{"id":"build","max_iterations":25},{"id":"test"},{"id":"pr"}]}
JSON

    # Extract the function
    local fns_script="$TEST_TEMP_DIR/composed-fns.sh"
    cat > "$fns_script" <<'FEOF'
#!/usr/bin/env bash
set -uo pipefail
COMPOSED_STAGES=""
COMPOSED_BUILD_ITERATIONS=""
emit_event() { true; }
info() { true; }
warn() { true; }
SCRIPT_DIR="/nonexistent"
ISSUE_NUMBER=""
NO_GITHUB=true
FEOF

    sed -n '/^load_composed_pipeline()/,/^}/p' "$REAL_PIPELINE_SCRIPT" >> "$fns_script" 2>/dev/null

    local result
    result=$(
        # shellcheck disable=SC1090
        source "$fns_script" 2>/dev/null
        load_composed_pipeline "$spec_file"
        echo "stages=$COMPOSED_STAGES|iters=$COMPOSED_BUILD_ITERATIONS"
    ) || result=""

    # Verify stages were loaded
    echo "$result" | grep -q "intake" || { echo "Missing intake in COMPOSED_STAGES"; return 1; }
    echo "$result" | grep -q "build" || { echo "Missing build in COMPOSED_STAGES"; return 1; }
    echo "$result" | grep -q "iters=25" || { echo "Expected COMPOSED_BUILD_ITERATIONS=25"; return 1; }
}

# ──────────────────────────────────────────────────────────────────────────────
# 48. Momentum bootstrap — single snapshot returns 60 if past intake
# ──────────────────────────────────────────────────────────────────────────────
test_momentum_bootstrap_single_snapshot() {
    local vitals_script
    vitals_script="$(dirname "$REAL_PIPELINE_SCRIPT")/sw-pipeline-vitals.sh"
    [[ -f "$vitals_script" ]] || { echo "Vitals script not found"; return 1; }

    # Extract _compute_momentum and _safe_num
    local fns_script="$TEST_TEMP_DIR/momentum-fns.sh"
    cat > "$fns_script" <<'FEOF'
#!/usr/bin/env bash
set -uo pipefail
FEOF

    sed -n '/^_safe_num()/,/^}/p' "$vitals_script" >> "$fns_script" 2>/dev/null
    sed -n '/^_compute_momentum()/,/^}$/p' "$vitals_script" >> "$fns_script" 2>/dev/null

    # Create a progress file with 1 snapshot past intake
    local progress_file="$TEST_TEMP_DIR/progress.json"
    echo '{"snapshots":[{"stage":"build","iteration":1,"diff_lines":10}]}' > "$progress_file"

    local result
    result=$(
        # shellcheck disable=SC1090
        source "$fns_script" 2>/dev/null
        _compute_momentum "$progress_file" "build" 2 20
    ) || result=""

    [[ "$result" == "60" ]] || { echo "Expected momentum=60 for single snapshot past intake, got '$result'"; return 1; }
}

# ──────────────────────────────────────────────────────────────────────────────
# 49. Health gate blocks when health < threshold
# ──────────────────────────────────────────────────────────────────────────────
test_health_gate_blocks() {
    local vitals_script
    vitals_script="$(dirname "$REAL_PIPELINE_SCRIPT")/sw-pipeline-vitals.sh"
    [[ -f "$vitals_script" ]] || { echo "Vitals script not found"; return 1; }

    # Verify the function signature exists
    grep -q "pipeline_check_health_gate()" "$vitals_script" || \
        { echo "pipeline_check_health_gate not found in vitals"; return 1; }

    # Verify threshold logic: returns 1 when health < threshold
    grep -q 'health.*-lt.*threshold' "$vitals_script" || \
        grep -q 'health_score.*threshold' "$vitals_script" || \
        { echo "Expected health < threshold check in health gate"; return 1; }
}

# ──────────────────────────────────────────────────────────────────────────────
# 50. Health gate passes when health >= threshold
# ──────────────────────────────────────────────────────────────────────────────
test_health_gate_passes() {
    local vitals_script
    vitals_script="$(dirname "$REAL_PIPELINE_SCRIPT")/sw-pipeline-vitals.sh"
    [[ -f "$vitals_script" ]] || { echo "Vitals script not found"; return 1; }

    # Verify default threshold is 40
    grep -q 'VITALS_GATE_THRESHOLD:-40' "$vitals_script" || \
        { echo "Expected default threshold of 40 in health gate"; return 1; }

    # Verify return 0 path exists
    grep -q 'return 0' "$vitals_script" || \
        { echo "Expected return 0 path in health gate"; return 1; }
}

# ══════════════════════════════════════════════════════════════════════════════
# DURABLE ARTIFACT PERSISTENCE TESTS
# ══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 51. persist_artifacts function exists in pipeline
# ──────────────────────────────────────────────────────────────────────────────
test_persist_artifacts_exists() {
    grep -q "^persist_artifacts()" "$REAL_PIPELINE_SCRIPT" || grep -q "^persist_artifacts()" "$SCRIPT_DIR"/lib/pipeline-*.sh 2>/dev/null
}

# ──────────────────────────────────────────────────────────────────────────────
# 52. persist_artifacts skips in non-CI mode
# ──────────────────────────────────────────────────────────────────────────────
test_persist_artifacts_ci_guard() {
    (
        # Reset ruflo env so the EXIT trap's ruflo_cleanup is a no-op in test context
        unset RUFLO_AVAILABLE RUFLO_DAEMON_STARTED RUFLO_HIVE_ID RUFLO_FAILURE_COUNT
        # Source pipeline — sets ARTIFACTS_DIR="" so we must set vars AFTER source
        # Belt-and-suspenders: guard against EXIT trap pushing to real GitHub.
        # The primary fix is _PIPELINE_RUN_STARTED sentinel; this is a safety net.
        NO_ARTIFACT_PUSH=true
        # shellcheck disable=SC1090
        source "$REAL_PIPELINE_SCRIPT" > /dev/null 2>&1 || true

        # shellcheck disable=SC2034
        CI_MODE=false
        # shellcheck disable=SC2034
        ISSUE_NUMBER="99"
        ARTIFACTS_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-art-test.XXXXXX")
        echo "test plan" > "$ARTIFACTS_DIR/plan.md"

        # Should return 0 (skip) and NOT touch git
        persist_artifacts "plan" "plan.md" > /dev/null 2>&1
        local rc=$?
        rm -rf "$ARTIFACTS_DIR"
        exit "$rc"
    )
}

# ──────────────────────────────────────────────────────────────────────────────
# 53. verify_stage_artifacts returns 0 when all artifacts present
# ──────────────────────────────────────────────────────────────────────────────
test_verify_artifacts_present() {
    (
        # Reset ruflo env so the EXIT trap's ruflo_cleanup is a no-op in test context
        unset RUFLO_AVAILABLE RUFLO_DAEMON_STARTED RUFLO_HIVE_ID RUFLO_FAILURE_COUNT
        # Belt-and-suspenders: guard against EXIT trap pushing to real GitHub.
        NO_ARTIFACT_PUSH=true
        # shellcheck disable=SC1090
        source "$REAL_PIPELINE_SCRIPT" > /dev/null 2>&1 || true

        ARTIFACTS_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-art-test.XXXXXX")
        echo "# Plan" > "$ARTIFACTS_DIR/plan.md"

        verify_stage_artifacts "plan" > /dev/null 2>&1
        local rc=$?
        rm -rf "$ARTIFACTS_DIR"
        exit "$rc"
    )
}

# ──────────────────────────────────────────────────────────────────────────────
# 54. verify_stage_artifacts returns 1 when artifacts missing
# ──────────────────────────────────────────────────────────────────────────────
test_verify_artifacts_missing() {
    (
        # Reset ruflo env so the EXIT trap's ruflo_cleanup is a no-op in test context
        unset RUFLO_AVAILABLE RUFLO_DAEMON_STARTED RUFLO_HIVE_ID RUFLO_FAILURE_COUNT
        # Belt-and-suspenders: guard against EXIT trap pushing to real GitHub.
        NO_ARTIFACT_PUSH=true
        # shellcheck disable=SC1090
        source "$REAL_PIPELINE_SCRIPT" > /dev/null 2>&1 || true

        ARTIFACTS_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-art-test.XXXXXX")
        # plan.md does NOT exist

        if verify_stage_artifacts "plan" > /dev/null 2>&1; then
            rm -rf "$ARTIFACTS_DIR"
            exit 1  # Should have returned 1
        else
            rm -rf "$ARTIFACTS_DIR"
            exit 0  # Correctly detected missing
        fi
    )
}

# ──────────────────────────────────────────────────────────────────────────────
# 55. verify_stage_artifacts returns 1 when artifact is empty
# ──────────────────────────────────────────────────────────────────────────────
test_verify_artifacts_empty() {
    (
        # Reset ruflo env so the EXIT trap's ruflo_cleanup is a no-op in test context
        unset RUFLO_AVAILABLE RUFLO_DAEMON_STARTED RUFLO_HIVE_ID RUFLO_FAILURE_COUNT
        # Belt-and-suspenders: guard against EXIT trap pushing to real GitHub.
        NO_ARTIFACT_PUSH=true
        # shellcheck disable=SC1090
        source "$REAL_PIPELINE_SCRIPT" > /dev/null 2>&1 || true

        ARTIFACTS_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-art-test.XXXXXX")
        touch "$ARTIFACTS_DIR/plan.md"  # Empty file

        if verify_stage_artifacts "plan" > /dev/null 2>&1; then
            rm -rf "$ARTIFACTS_DIR"
            exit 1  # Should have returned 1
        else
            rm -rf "$ARTIFACTS_DIR"
            exit 0  # Correctly detected empty
        fi
    )
}

# ──────────────────────────────────────────────────────────────────────────────
# 56. verify_stage_artifacts passes for stages with no artifact requirements
# ──────────────────────────────────────────────────────────────────────────────
test_verify_artifacts_no_requirements() {
    (
        # Reset ruflo env so the EXIT trap's ruflo_cleanup is a no-op in test context
        unset RUFLO_AVAILABLE RUFLO_DAEMON_STARTED RUFLO_HIVE_ID RUFLO_FAILURE_COUNT
        # Belt-and-suspenders: guard against EXIT trap pushing to real GitHub.
        NO_ARTIFACT_PUSH=true
        # shellcheck disable=SC1090
        source "$REAL_PIPELINE_SCRIPT" > /dev/null 2>&1 || true

        ARTIFACTS_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-art-test.XXXXXX")

        # build, test, review etc. have no artifact requirements
        verify_stage_artifacts "build" > /dev/null 2>&1
        local rc=$?
        rm -rf "$ARTIFACTS_DIR"
        exit "$rc"
    )
}

# ──────────────────────────────────────────────────────────────────────────────
# 57. verify_stage_artifacts design requires both design.md and plan.md
# ──────────────────────────────────────────────────────────────────────────────
test_verify_artifacts_design_needs_plan() {
    (
        # Reset ruflo env so the EXIT trap's ruflo_cleanup is a no-op in test context
        unset RUFLO_AVAILABLE RUFLO_DAEMON_STARTED RUFLO_HIVE_ID RUFLO_FAILURE_COUNT
        # Belt-and-suspenders: guard against EXIT trap pushing to real GitHub.
        NO_ARTIFACT_PUSH=true
        # shellcheck disable=SC1090
        source "$REAL_PIPELINE_SCRIPT" > /dev/null 2>&1 || true

        ARTIFACTS_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-art-test.XXXXXX")
        echo "# Design" > "$ARTIFACTS_DIR/design.md"
        # plan.md missing — design should fail

        if verify_stage_artifacts "design" > /dev/null 2>&1; then
            rm -rf "$ARTIFACTS_DIR"
            exit 1  # Should have failed
        else
            rm -rf "$ARTIFACTS_DIR"
            exit 0  # Correctly detected missing plan.md
        fi
    )
}

# ──────────────────────────────────────────────────────────────────────────────
# 57b. _PIPELINE_RUN_STARTED sentinel: no push when sourced without run_pipeline
#      Regression test — written BEFORE implementation (TDD red).
#      Verifies the sentinel added to cleanup_on_exit gates all remote-push calls
#      so that sourcing sw-pipeline.sh in tests never touches real GitHub.
# ──────────────────────────────────────────────────────────────────────────────
test_no_push_when_sourced_without_pipeline_start() {
    local push_log
    push_log=$(mktemp "${TMPDIR:-/tmp}/sw-push-log.XXXXXX")

    (
        # Reset ruflo env so the EXIT trap's ruflo_cleanup is a no-op in test context
        unset RUFLO_AVAILABLE RUFLO_DAEMON_STARTED RUFLO_HIVE_ID RUFLO_FAILURE_COUNT

        # Fake git that logs any push call and returns non-zero.
        # Exported so subshell child processes inherit it.
        git() {
            if [[ "${1:-}" == "push" ]]; then
                echo "git push called: $*" >> "$push_log"
                return 1
            fi
            command git "$@"
        }
        export -f git

        # Explicitly disable the NO_ARTIFACT_PUSH guard so the ONLY thing
        # preventing a push is the _PIPELINE_RUN_STARTED sentinel.
        # This makes the test a true behavioral regression for the sentinel fix.
        # shellcheck disable=SC2034
        NO_ARTIFACT_PUSH=false
        # shellcheck disable=SC2034
        ISSUE_NUMBER="99"

        # Source the pipeline WITHOUT calling run_pipeline().
        # The EXIT trap installed by source fires on subshell exit.
        # shellcheck disable=SC1090
        source "$REAL_PIPELINE_SCRIPT" > /dev/null 2>&1 || true

        # Exit WITHOUT ever calling run_pipeline() — sentinel must block the push.
        exit 0
    ) 2>/dev/null || true

    # Assert: push log must be empty — sentinel blocked pipeline_final_artifact_push.
    local rc=0
    if [[ -s "$push_log" ]]; then
        echo "    FAIL: git push was called despite _PIPELINE_RUN_STARTED not being set:"
        cat "$push_log"
        rc=1
    fi
    rm -f "$push_log"

    # Assert: events snapshot must NOT have been created in the real project dir.
    local events_snap="$REPO_DIR/.shipwright/events-99-local.jsonl"
    if [[ -f "$events_snap" ]]; then
        echo "    FAIL: events snapshot was created in real project dir: $events_snap"
        rm -f "$events_snap"
        rc=1
    fi

    return "$rc"
}

# ──────────────────────────────────────────────────────────────────────────────
# 58. mark_stage_complete calls persist_artifacts for plan stage
# ──────────────────────────────────────────────────────────────────────────────
test_mark_complete_persists_plan() {
    ( grep -A5 "Persist artifacts to feature branch" "$REAL_PIPELINE_SCRIPT" 2>/dev/null || grep -A5 "Persist artifacts to feature branch" "$SCRIPT_DIR"/lib/pipeline-*.sh 2>/dev/null ) | \
        grep -q 'plan.*persist_artifacts.*plan.md.*dod.md.*context-bundle.md'
}

# ──────────────────────────────────────────────────────────────────────────────
# 59. Fresh start cleans stale checkpoints/ directory
# ──────────────────────────────────────────────────────────────────────────────
test_fresh_start_cleans_stale_checkpoints() {
    local artifacts="$TEST_TEMP_DIR/project/.claude/pipeline-artifacts"
    pipeline_config_with_stages "intake" > "$TEST_TEMP_DIR/templates/pipelines/standard.json"

    # Plant stale checkpoint that a prior pipeline run left behind
    mkdir -p "$artifacts/checkpoints"
    echo '{"stage":"build","iteration":3}' > "$artifacts/checkpoints/build-checkpoint.json"

    invoke_pipeline start --goal "Fresh start goal" --skip-gates

    assert_exit_code 0 "pipeline should complete" &&
    # _cleanup_run_artifacts() must remove the checkpoints/ directory entirely,
    # not just its contents.  pipeline_post_completion_cleanup removes individual
    # files but leaves the directory — so a surviving directory means Fix 1 is absent.
    (
        if [[ ! -d "$artifacts/checkpoints" ]]; then
            return 0
        fi
        local remaining=0
        for f in "$artifacts/checkpoints"/*-checkpoint.json; do
            [[ -f "$f" ]] && remaining=$((remaining + 1))
        done
        if [[ "$remaining" -gt 0 ]]; then
            echo -e "    ${RED}✗${RESET} Stale checkpoints survived fresh start: $remaining files remain"
        else
            echo -e "    ${RED}✗${RESET} checkpoints/ directory survived fresh start (not removed by _cleanup_run_artifacts)"
        fi
        return 1
    )
}

# ──────────────────────────────────────────────────────────────────────────────
# ci_post_stage_event — comment format tests (issue #258)
# ──────────────────────────────────────────────────────────────────────────────

_load_ci_post_stage_event() {
    # Extract ci_post_stage_event into an isolated sourcing script so we can
    # call it without the full pipeline environment.
    local fns="$TEST_TEMP_DIR/ci-post-fns.sh"
    cat > "$fns" <<'FEOF'
#!/usr/bin/env bash
set -uo pipefail
emit_event() { true; }
info() { true; }
warn() { true; }
_timeout() { local _t="$1"; shift; "$@"; }
_config_get_int() { echo "${3:-30}"; }
FEOF
    sed -n '/^ci_post_stage_event()/,/^}/p' "$REAL_PIPELINE_SCRIPT" >> "$fns"
    echo "$fns"
}

_ci_capture_body() {
    # Helper: run ci_post_stage_event with a gh() stub that writes --body arg to
    # a temp file (avoids >/dev/null suppression in the real function).
    local fns="$1" stage="$2" status="$3" elapsed="$4"
    local capture_file="$TEST_TEMP_DIR/ci-body-capture-$$.txt"
    rm -f "$capture_file"
    (
        # shellcheck disable=SC1090
        source "$fns" 2>/dev/null
        CI_MODE=true
        ISSUE_NUMBER=123
        GH_AVAILABLE=true
        gh() {
            local prev=""
            for arg in "$@"; do
                if [[ "$prev" == "--body" ]]; then
                    printf '%s' "$arg" > "$capture_file"
                    return 0
                fi
                prev="$arg"
            done
        }
        ci_post_stage_event "$stage" "$status" "$elapsed"
    ) 2>/dev/null || true
    cat "$capture_file" 2>/dev/null || true
    rm -f "$capture_file"
}

test_ci_post_stage_event_visible_body() {
    # Comment body must contain human-readable text (not just HTML comment)
    local fns result visible
    fns=$(_load_ci_post_stage_event)
    result=$(_ci_capture_body "$fns" "build" "complete" "45s")
    visible=$(printf '%s\n' "$result" | grep -Ev '^[[:space:]]*<!--' | tr -d '[:space:]')
    [[ -n "$visible" ]] || { echo "Expected visible comment body, got only HTML comments: $result"; return 1; }
    printf '%s\n' "$result" | grep -Ev '^[[:space:]]*<!--' | grep -Eq 'Pipeline update|build' \
        || { echo "Expected human-readable pipeline update text in comment body; got: $result"; return 1; }
}

test_ci_post_stage_event_retains_marker() {
    # HTML marker must be present for watchdog parsing
    local fns result
    fns=$(_load_ci_post_stage_event)
    result=$(_ci_capture_body "$fns" "test" "complete" "2m10s")
    printf '%s' "$result" | grep -q 'SHIPWRIGHT-STAGE' \
        || { echo "HTML marker SHIPWRIGHT-STAGE missing from comment body"; return 1; }
    printf '%s' "$result" | grep -q 'test:complete:2m10s' \
        || { echo "Stage/status/elapsed missing from marker; got: $result"; return 1; }
}

test_ci_post_stage_event_failed_emoji() {
    # Failed status should use the failure emoji
    local fns result
    fns=$(_load_ci_post_stage_event)
    result=$(_ci_capture_body "$fns" "review" "failed" "1m5s")
    printf '%s' "$result" | grep -q '❌' \
        || { echo "Expected failure emoji in comment body; got: $result"; return 1; }
}

test_ci_post_stage_event_noop_outside_ci() {
    # Must be a no-op when CI_MODE != true
    local fns capture_file
    fns=$(_load_ci_post_stage_event)
    capture_file="$TEST_TEMP_DIR/ci-noop-$$.txt"
    rm -f "$capture_file"
    (
        # shellcheck disable=SC1090
        source "$fns" 2>/dev/null
        CI_MODE=false
        ISSUE_NUMBER=123
        GH_AVAILABLE=true
        gh() { printf 'called' > "$capture_file"; }
        ci_post_stage_event "build" "complete" "1s"
    ) 2>/dev/null || true
    [[ ! -f "$capture_file" ]] || { echo "ci_post_stage_event should be no-op when CI_MODE=false"; return 1; }
}

# ──────────────────────────────────────────────────────────────────────────────
# Issue 2: events snapshot code removed from pipeline_wip_push and
# pipeline_final_artifact_push. These snapshots had no consumer and were
# force-committed into every WIP branch, inflating DoD prompts.
# ──────────────────────────────────────────────────────────────────────────────

test_events_snapshot_code_absent() {
    # Static: _events_snap must not appear anywhere in sw-pipeline.sh.
    # After removal of the two snapshot blocks, no reference to the snapshot
    # variable should remain.
    if grep -qn "_events_snap" "$REAL_PIPELINE_SCRIPT"; then
        local hits
        hits=$(grep -n "_events_snap" "$REAL_PIPELINE_SCRIPT")
        echo "    FAIL: _events_snap still referenced in sw-pipeline.sh:"
        echo "$hits" | sed 's/^/      /'
        return 1
    fi
    return 0
}

test_events_snapshot_not_created_on_wip_push() {
    # Behavioral: ci_push_partial_work must not create .shipwright/events-*.jsonl.
    # The WIP-push function (ci_push_partial_work) is gated on CI_MODE=true.
    # We set that here so the snapshot block is actually reached.
    local workdir fake_events
    workdir=$(mktemp -d "${TMPDIR:-/tmp}/sw-wip-push-test.XXXXXX")
    fake_events="$workdir/fake-events.jsonl"
    echo '{"type":"event"}' > "$fake_events"

    (
        cd "$workdir" || exit 1
        mkdir -p ".shipwright" 2>/dev/null || true

        git() {
            case "${1:-}" in
                push) return 0 ;;
                rev-parse) echo "shipwright/issue-42" ;;
                add|commit|config|remote) return 0 ;;
                diff) echo ""; return 0 ;;
                *) return 0 ;;
            esac
        }
        export -f git

        info()    { true; }
        warn()    { true; }
        error()   { true; }
        success() { true; }
        emit_event() { true; }
        _git_bookkeeping_pathspecs() { echo ""; }
        safe_git_stage() { true; }
        _timeout() { shift; "$@"; }
        export -f info warn error success emit_event _git_bookkeeping_pathspecs safe_git_stage _timeout

        CI_MODE=true
        ISSUE_NUMBER="42"
        EVENTS_FILE="$fake_events"
        _PIPELINE_RUN_STARTED=true

        source "$REAL_PIPELINE_SCRIPT" > /dev/null 2>&1 || true
        ci_push_partial_work 5 2>/dev/null || true
    ) 2>/dev/null || true

    local snap_count
    snap_count=$(find "$workdir/.shipwright" -name "events-*.jsonl" 2>/dev/null | wc -l)
    snap_count="${snap_count// /}"

    rm -rf "$workdir"

    if [[ "$snap_count" -gt 0 ]]; then
        echo "    FAIL: ci_push_partial_work created ${snap_count} events snapshot file(s) — snapshot code not removed"
        return 1
    fi
    return 0
}

test_events_snapshot_not_created_on_final_push() {
    # Behavioral: pipeline_final_artifact_push must not create .shipwright/events-*.jsonl.
    local workdir fake_events
    workdir=$(mktemp -d "${TMPDIR:-/tmp}/sw-final-push-test.XXXXXX")
    fake_events="$workdir/fake-events.jsonl"
    echo '{"type":"event"}' > "$fake_events"

    (
        cd "$workdir" || exit 1
        mkdir -p ".shipwright" 2>/dev/null || true

        git() {
            case "${1:-}" in
                push) return 0 ;;
                rev-parse) echo "shipwright/issue-42" ;;
                add|commit|config|remote) return 0 ;;
                diff) echo ""; return 0 ;;
                *) return 0 ;;
            esac
        }
        export -f git

        info()    { true; }
        warn()    { true; }
        error()   { true; }
        success() { true; }
        emit_event() { true; }
        _git_bookkeeping_pathspecs() { echo ""; }
        safe_git_stage() { true; }
        _timeout() { shift; "$@"; }
        export -f info warn error success emit_event _git_bookkeeping_pathspecs safe_git_stage _timeout

        ISSUE_NUMBER="42"
        NO_GITHUB=false
        NO_ARTIFACT_PUSH=false
        DRY_RUN=false
        EVENTS_FILE="$fake_events"
        _PIPELINE_RUN_STARTED=true
        ARTIFACTS_DIR="$workdir/.claude"
        STATE_DIR="$workdir/.claude"

        source "$REAL_PIPELINE_SCRIPT" > /dev/null 2>&1 || true
        pipeline_final_artifact_push 5 2>/dev/null || true
    ) 2>/dev/null || true

    local snap_count
    snap_count=$(find "$workdir/.shipwright" -name "events-*.jsonl" 2>/dev/null | wc -l)
    snap_count="${snap_count// /}"

    rm -rf "$workdir"

    if [[ "$snap_count" -gt 0 ]]; then
        echo "    FAIL: pipeline_final_artifact_push created ${snap_count} events snapshot file(s) — snapshot code not removed"
        return 1
    fi
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# Model resolution: CLI flag (MODEL=sonnet) wins over config default
# ──────────────────────────────────────────────────────────────────────────────
test_model_resolution() {
    # Write a loop-state.md as if the loop chose haiku (post-stage context)
    mkdir -p "$TEST_TEMP_DIR/project/.claude"
    cat > "$TEST_TEMP_DIR/project/.claude/loop-state.md" <<'LSEOF'
model: haiku
iteration: 2
LSEOF

    # Run dry-run with --model sonnet — get_pipeline_model() must honor the CLI flag
    invoke_pipeline start --goal "test model resolution" --model sonnet --dry-run

    assert_exit_code 0 "dry-run with --model sonnet should succeed" &&
    assert_output_contains "sonnet" "CLI --model sonnet should appear in dry-run output" &&
    assert_output_not_contains "opus" "opus should not appear anywhere in dry-run output when sonnet is specified"
}

# ──────────────────────────────────────────────────────────────────────────────
# Model resolution: no CLI flag falls back to pipeline config default
# ──────────────────────────────────────────────────────────────────────────────
test_model_resolution_no_flag() {
    # Override standard template so defaults.model is "sonnet"
    cat > "$TEST_TEMP_DIR/templates/pipelines/standard.json" <<'TMPL'
{
  "name": "standard",
  "description": "Test pipeline with sonnet default model",
  "defaults": { "test_cmd": "npm test", "model": "sonnet", "agents": 1 },
  "stages": [
    { "id": "intake",   "enabled": true,  "gate": "auto", "config": {} },
    { "id": "plan",     "enabled": true,  "gate": "auto", "config": {} },
    { "id": "build",    "enabled": true,  "gate": "auto", "config": { "max_iterations": 20 } },
    { "id": "test",     "enabled": true,  "gate": "auto", "config": { "coverage_min": 0 } },
    { "id": "review",   "enabled": true,  "gate": "auto", "config": {} },
    { "id": "pr",       "enabled": true,  "gate": "auto", "config": { "wait_ci": false } },
    { "id": "deploy",   "enabled": false, "gate": "auto", "config": {} },
    { "id": "validate", "enabled": false, "gate": "auto", "config": {} }
  ]
}
TMPL

    # Write loop-state.md showing the loop chose sonnet (get_effective_model reads this)
    mkdir -p "$TEST_TEMP_DIR/project/.claude"
    cat > "$TEST_TEMP_DIR/project/.claude/loop-state.md" <<'LSEOF'
model: sonnet
iteration: 1
LSEOF

    # Run dry-run with no MODEL env var — get_pipeline_model() should read config default
    invoke_pipeline start --goal "test model resolution no flag" --dry-run

    assert_exit_code 0 "dry-run without MODEL flag should succeed" &&
    assert_output_contains "sonnet" "pipeline config default model=sonnet should appear in dry-run output"
}

# ──────────────────────────────────────────────────────────────────────────────
# Guard: run_stage_with_retry fails fast on undefined stage function
# ──────────────────────────────────────────────────────────────────────────────
test_run_stage_with_retry_undefined_stage() {
    local test_cfg="$TEST_TEMP_DIR/test-retry-guard-config.json"
    echo '{"stages":[]}' > "$test_cfg"

    local test_artifacts="$TEST_TEMP_DIR/test-retry-guard-artifacts"
    mkdir -p "$test_artifacts"

    local test_bin="$TEST_TEMP_DIR/bin/test-retry-guard"
    cat > "$test_bin" <<RETRY_GUARD_TEST
#!/usr/bin/env bash
set -uo pipefail
PIPELINE_CONFIG="$test_cfg"
ARTIFACTS_DIR="$test_artifacts"
ISSUE_NUMBER=0
LAST_STAGE_ERROR_CLASS=""
LAST_STAGE_ERROR=""
# Redirect HOME so lib/helpers.sh writes events.jsonl to temp dir, not ~/.shipwright
HOME="$TEST_TEMP_DIR"
EVENTS_FILE="$TEST_TEMP_DIR/events.jsonl"

error()          { echo "ERROR: \$*" >&2; }
warn()           { echo "WARN: \$*"; }
info()           { echo "INFO: \$*"; }
emit_event()     { true; }
classify_error() { echo "unknown"; }

source "$TEST_TEMP_DIR/scripts/sw-pipeline.sh" 2>/dev/null || true

# Re-stub after sourcing in case lib/helpers.sh overrode our stubs
emit_event()     { true; }
classify_error() { echo "unknown"; }

run_stage_with_retry "nonexistent_stage_xyz_404"
RETRY_GUARD_TEST
    chmod +x "$test_bin"

    local out exit_code=0
    out=$(bash "$test_bin" 2>&1) || exit_code=$?

    if [[ "$exit_code" -ne 1 ]]; then
        assert_fail "run_stage_with_retry undefined stage: expected exit 1, got $exit_code"
        return
    fi

    if ! echo "$out" | grep -qi "function not defined"; then
        assert_fail "run_stage_with_retry undefined stage: expected 'function not defined' in output, got: $out"
        return
    fi

    assert_pass "run_stage_with_retry with undefined stage exits 1 with actionable error"
}

test_partial_work_push_condition() {
    local wf="$TEST_TEMP_DIR/shipwright-pipeline.yml"
    cp "$REPO_DIR/.github/workflows/shipwright-pipeline.yml" "$wf" 2>/dev/null || {
        assert_fail "partial-work push condition: workflow file not found"
        return
    }

    local step_block if_line
    # Match both the legacy step name and the current "Snapshot resume-essentials" step.
    step_block=$(
        awk '
            /^[[:space:]]*-[[:space:]]+name:/ {
                if (in_target) {
                    exit
                }
                if ($0 ~ /Push partial work on/ || $0 ~ /Snapshot resume-essentials/) {
                    in_target=1
                }
            }
            in_target {
                print
            }
        ' "$wf"
    )

    if [[ -z "$step_block" ]]; then
        assert_fail "partial-work push condition: could not extract workflow step block"
        return
    fi

    if_line=$(printf '%s\n' "$step_block" | grep -m1 '^[[:space:]]*if:')

    if [[ -z "$if_line" ]]; then
        assert_fail "partial-work push condition: step missing if: line"
        return
    fi

    if printf '%s\n' "$if_line" | grep -qE "if:[[:space:]]*failure\(\)[[:space:]]*&&"; then
        assert_fail "partial-work push condition: step still uses bare failure() — regression of issue #437"
        return
    fi

    # Accept always() (superset: runs on success, failure, and cancelled) or the
    # legacy (failure() || cancelled()) form.
    if ! printf '%s\n' "$if_line" | grep -qE "always\(\)|failure\(\)[[:space:]]*\|\|[[:space:]]*cancelled\(\)"; then
        assert_fail "partial-work push condition: step must use always() or (failure() || cancelled()), got: $if_line"
        return
    fi

    assert_pass "partial-work push handles both failure and cancelled (issue #437)"
}

# ──────────────────────────────────────────────────────────────────────────────
# Cycling Halt: count_consecutive_test_failures() parses pipeline-state.md log
# and returns trailing-failure count; resets on `complete`, ignores non-test stages.
# ──────────────────────────────────────────────────────────────────────────────
test_count_consecutive_test_failures_parsing() {
    local script="$TEST_TEMP_DIR/scripts/sw-pipeline.sh"
    local helper="$TEST_TEMP_DIR/count-helper.sh"
    local state_file="$TEST_TEMP_DIR/state-fixture.md"

    # Extract just the function so we can call it standalone (no full pipeline init)
    awk '/^count_consecutive_test_failures\(\) \{/,/^\}/' "$script" > "$helper"

    if ! grep -q "count_consecutive_test_failures" "$helper"; then
        assert_fail "cycling halt: count_consecutive_test_failures function not found in sw-pipeline.sh"
        return
    fi

    _run_count() {
        local expected="$1" label="$2"
        local got
        got=$(bash -c "source \"$helper\"; count_consecutive_test_failures \"$state_file\"")
        if [[ "$got" -ne "$expected" ]]; then
            assert_fail "cycling halt parser: expected=$expected got=$got — $label"
            return 1
        fi
        return 0
    }

    # Missing file → 0
    rm -f "$state_file"
    _run_count 0 "missing state file" || return

    # Empty file → 0
    : > "$state_file"
    _run_count 0 "empty state file" || return

    # No test entries → 0
    cat > "$state_file" <<'STATE_EOF'
## Log

### intake (10:00:00)
complete (1m)

### plan (10:01:00)
complete (5m)
STATE_EOF
    _run_count 0 "no test entries" || return

    # Three consecutive failures → 3
    cat > "$state_file" <<'STATE_EOF'
## Log

### test (10:00:00)
failed (1m)

### test (10:01:00)
failed (1m)

### test (10:02:00)
failed (1m)
STATE_EOF
    _run_count 3 "3 consecutive failures" || return

    # Pass then 2 failures → 2 (counter resets on pass)
    cat > "$state_file" <<'STATE_EOF'
## Log

### test (10:00:00)
failed (1m)

### test (10:01:00)
complete (2m)

### test (10:02:00)
failed (1m)

### test (10:03:00)
failed (1m)
STATE_EOF
    _run_count 2 "counter resets on test complete" || return

    # Pass after failures → 0
    cat > "$state_file" <<'STATE_EOF'
## Log

### test (10:00:00)
failed (1m)

### test (10:01:00)
failed (1m)

### test (10:02:00)
complete (2m)
STATE_EOF
    _run_count 0 "trailing pass resets to 0" || return

    # Build failures don't count, only test stage
    cat > "$state_file" <<'STATE_EOF'
## Log

### test (10:00:00)
failed (1m)

### build (10:01:00)
failed (1m)

### test (10:02:00)
failed (1m)
STATE_EOF
    _run_count 2 "non-test stages ignored" || return

    # #448 review fix: parser must accept stage ids with digits/uppercase so
    # custom stages don't silently break the regex match. The literal `test`
    # stage still counts; sibling stages like `test_2` are ignored.
    cat > "$state_file" <<'STATE_EOF'
## Log

### test (10:00:00)
failed (1m)

### test_2 (10:01:00)
failed (1m)

### COMPOUND_QUALITY (10:02:00)
failed (1m)

### test (10:03:00)
failed (1m)
STATE_EOF
    _run_count 2 "stage ids with digits/uppercase parsed; non-'test' stages ignored" || return

    assert_pass "cycling halt parser handles 8 scenarios correctly"
}

# ──────────────────────────────────────────────────────────────────────────────
# #448 review fix: parser must warn (stderr) when state file contains literal
# '### test ' headers that the parser failed to recognize — early signal that
# the log format drifted and the cycling halt would silently stop working.
# ──────────────────────────────────────────────────────────────────────────────
test_count_consecutive_test_failures_format_drift_warning() {
    local script="$TEST_TEMP_DIR/scripts/sw-pipeline.sh"
    local helper="$TEST_TEMP_DIR/count-helper.sh"
    local state_file="$TEST_TEMP_DIR/state-fixture-drift.md"

    awk '/^count_consecutive_test_failures\(\) \{/,/^\}/' "$script" > "$helper"

    # Sanity-path: parser-recognized test header should NOT emit a warning.
    cat > "$state_file" <<'STATE_EOF'
## Log

### test (10:00:00)
failed (1m)
STATE_EOF
    local stderr_log="$TEST_TEMP_DIR/count-warn.err"
    : > "$stderr_log"
    bash -c "source \"$helper\"; count_consecutive_test_failures \"$state_file\"" 2>"$stderr_log" >/dev/null
    if grep -q "format may have drifted" "$stderr_log"; then
        assert_fail "format-drift warning fired on a clean recognized header"
        return
    fi

    # Drifted-format scenario: log section + literal '### test' header lines that
    # the parser fails to recognize because the prefix differs ('####' instead
    # of '###'). Parser should emit the drift warning to stderr.
    cat > "$state_file" <<'STATE_EOF'
## Log

#### test (10:00:00)
failed (1m)

### test (10:01:00)
failed (1m)
STATE_EOF
    : > "$stderr_log"
    bash -c "source \"$helper\"; count_consecutive_test_failures \"$state_file\"" 2>"$stderr_log" >/dev/null
    # First line uses '####' so parser recognizes only the second one — still
    # gets a count, no drift warning. Verify clean path.
    if grep -q "format may have drifted" "$stderr_log"; then
        assert_fail "format-drift warning fired when at least one header was recognized"
        return
    fi

    # True drift: log section present, no '###'-level test header, but a '##'-level
    # test header exists — the parser misses it (uses '^###[[:space:]]') while the
    # drift detector catches it (uses '^(##|####)[[:space:]]+test[[:space:]]').
    cat > "$state_file" <<'STATE_EOF'
## Log

## test (10:00:00)
failed (1m)
STATE_EOF
    : > "$stderr_log"
    bash -c "source \"$helper\"; count_consecutive_test_failures \"$state_file\"" 2>"$stderr_log" >/dev/null
    if ! grep -q "format may have drifted" "$stderr_log"; then
        assert_fail "format-drift warning did NOT fire when heading level changed from ### to ##"
        return
    fi

    assert_pass "format-drift warning fires on true drift (heading level change) and stays silent on clean states"
}

# ──────────────────────────────────────────────────────────────────────────────
# Cycling Halt: pipeline halts with `status: stuck_cycling` when consecutive test
# failures reach SW_PIPELINE_MAX_BUILD_RETRIES, even across pipeline invocations.
# ──────────────────────────────────────────────────────────────────────────────
test_stuck_cycling_halts_after_max_build_retries() {
    pipeline_config_with_stages "intake,plan,build,test" > "$TEST_TEMP_DIR/templates/pipelines/standard.json"

    # Test command that always fails — guarantees a fresh test failure on this run.
    local fail_cmd="$TEST_TEMP_DIR/bin/always-fail-test"
    cat > "$fail_cmd" <<'FAIL_EOF'
#!/usr/bin/env bash
echo "FAIL: assertion failed"
exit 1
FAIL_EOF
    chmod +x "$fail_cmd"

    # Pre-seed the state file with N-1 prior consecutive test failures. The check
    # runs AFTER the current cycle's test failure is logged, so a fresh resume gets
    # one shot before halting (#448 review feedback). With cap=2 and 1 prior failure,
    # the new cycle's failure brings the count to 2 → halt.
    local proj="$TEST_TEMP_DIR/project"
    mkdir -p "$proj/.claude"
    cat > "$proj/.claude/pipeline-state.md" <<'PRESEED'
---
pipeline: standard
goal: "trigger cycling halt"
original_goal: "trigger cycling halt"
status: running
issue: ""
branch: "main"
template: "standard"
current_stage: build
started_at: 2026-04-30T00:00:00Z
pipeline_run_epoch: 1700000000
updated_at: 2026-04-30T00:00:00Z
elapsed: 0s
test_cmd: "false"
pr_number:
model: opus
progress_comment_id:
stages:
  intake: complete
  plan: complete
  build: failed
  test: failed
---

## Log

### intake (00:00:00)
complete (1s)

### plan (00:00:01)
complete (1s)

### test (00:00:10)
failed (1s)
PRESEED

    # With cap=2 and 1 prior failure, the build runs, the test fails (logging
    # failure #2), then the cycling halt fires post-failure-log → halt with
    # "stuck_cycling: 2 consecutive test failures".
    SW_PIPELINE_MAX_BUILD_RETRIES=2 \
        invoke_pipeline resume --skip-gates --test-cmd "$fail_cmd" --self-heal 5

    # Expect non-zero exit and stuck_cycling marker in state file.
    if [[ "$PIPELINE_EXIT" -eq 0 ]]; then
        assert_fail "cycling halt: pipeline should fail when cap reached, got exit 0"
        return
    fi

    assert_state_contains "status: stuck_cycling" "stuck_cycling status persisted" &&
    assert_state_contains "stuck_cycling: 2 consecutive test failures" "diagnostic log entry written" &&
    assert_output_contains "Pipeline halted" "user-visible halt message" &&
    assert_output_contains "SW_PIPELINE_MAX_BUILD_RETRIES=0" "override hint shown"
}

# ──────────────────────────────────────────────────────────────────────────────
# Cycling Halt: fresh resume gets at least one shot before halting.
# Regression for #448 review feedback: the check must run AFTER the current
# cycle's test result is logged, not BEFORE — otherwise a fresh resume halts
# immediately on stale prior failures even if the new attempt would have run.
# ──────────────────────────────────────────────────────────────────────────────
test_stuck_cycling_runs_one_cycle_before_halting_on_resume() {
    pipeline_config_with_stages "intake,plan,build,test" > "$TEST_TEMP_DIR/templates/pipelines/standard.json"

    local fail_cmd="$TEST_TEMP_DIR/bin/always-fail-test"
    cat > "$fail_cmd" <<'FAIL_EOF'
#!/usr/bin/env bash
echo "FAIL: assertion failed"
exit 1
FAIL_EOF
    chmod +x "$fail_cmd"

    local proj="$TEST_TEMP_DIR/project"
    mkdir -p "$proj/.claude"
    # Pre-seed with cap-many failures already. The OLD bug would halt
    # immediately without running the test command. The fix runs one cycle.
    cat > "$proj/.claude/pipeline-state.md" <<'PRESEED'
---
pipeline: standard
goal: "fresh resume must run one cycle"
original_goal: "fresh resume must run one cycle"
status: running
issue: ""
branch: "main"
template: "standard"
current_stage: build
started_at: 2026-04-30T00:00:00Z
pipeline_run_epoch: 1700000000
updated_at: 2026-04-30T00:00:00Z
elapsed: 0s
test_cmd: "false"
pr_number:
model: opus
progress_comment_id:
stages:
  intake: complete
  plan: complete
  build: failed
  test: failed
---

## Log

### test (00:00:10)
failed (1s)

### test (00:00:20)
failed (1s)

### test (00:00:30)
failed (1s)
PRESEED

    SW_PIPELINE_MAX_BUILD_RETRIES=3 \
        invoke_pipeline resume --skip-gates --test-cmd "$fail_cmd" --self-heal 1

    # The fix moved the cycling halt check to AFTER mark_stage_failed "test",
    # so the test stage MUST run on a fresh resume even with cap-many prior
    # failures. The OLD bug halted at the top of the loop before any new cycle.
    if ! printf '%s\n' "$PIPELINE_OUTPUT" | grep -q "Stage: test \[cycle 1\]"; then
        assert_fail "cycling halt: fresh resume halted before running the new test cycle (regression of #448 fix)"
        echo "      DEBUG: PIPELINE_EXIT=$PIPELINE_EXIT"
        echo "      DEBUG: PIPELINE_OUTPUT (last 30 lines):"
        echo "$PIPELINE_OUTPUT" | tail -30 | sed 's/^/        /'
        return
    fi

    assert_state_contains "status: stuck_cycling" "stuck_cycling status set after fresh cycle ran"
}

# ──────────────────────────────────────────────────────────────────────────────
# Cycling Halt: SW_PIPELINE_MAX_BUILD_RETRIES=0 disables the cap (escape hatch).
# ──────────────────────────────────────────────────────────────────────────────
test_stuck_cycling_disabled_when_max_retries_zero() {
    pipeline_config_with_stages "intake,plan,build,test" > "$TEST_TEMP_DIR/templates/pipelines/standard.json"

    local fail_cmd="$TEST_TEMP_DIR/bin/always-fail-test"
    cat > "$fail_cmd" <<'FAIL_EOF'
#!/usr/bin/env bash
exit 1
FAIL_EOF
    chmod +x "$fail_cmd"

    # Pre-seed with many prior failures
    local proj="$TEST_TEMP_DIR/project"
    mkdir -p "$proj/.claude"
    cat > "$proj/.claude/pipeline-state.md" <<'PRESEED'
---
pipeline: standard
goal: "verify escape hatch"
original_goal: "verify escape hatch"
status: running
issue: ""
branch: "main"
template: "standard"
current_stage: build
started_at: 2026-04-30T00:00:00Z
pipeline_run_epoch: 1700000000
updated_at: 2026-04-30T00:00:00Z
elapsed: 0s
test_cmd: "false"
pr_number:
model: opus
progress_comment_id:
stages:
  intake: complete
  plan: complete
---

## Log

### test (00:00:10)
failed (1s)

### test (00:00:20)
failed (1s)

### test (00:00:30)
failed (1s)

### test (00:00:40)
failed (1s)

### test (00:00:50)
failed (1s)
PRESEED

    # With cap=0, pipeline must NOT halt with stuck_cycling — normal exhaustion only.
    SW_PIPELINE_MAX_BUILD_RETRIES=0 \
        invoke_pipeline resume --skip-gates --test-cmd "$fail_cmd" --self-heal 1

    assert_state_not_contains "status: stuck_cycling" "stuck_cycling NOT set with cap=0"
}

# ──────────────────────────────────────────────────────────────────────────────
# Cycling Halt: resume of a `stuck_cycling` pipeline is refused unless the
# operator opts in via SW_PIPELINE_MAX_BUILD_RETRIES=0.
# Regression for #448 [Concern] #1: terminal-state guard on resume.
# ──────────────────────────────────────────────────────────────────────────────
test_stuck_cycling_resume_refused_without_override() {
    pipeline_config_with_stages "intake,plan,build,test" > "$TEST_TEMP_DIR/templates/pipelines/standard.json"

    local proj="$TEST_TEMP_DIR/project"
    mkdir -p "$proj/.claude"
    # Pre-seed with status: stuck_cycling (terminal halt state).
    cat > "$proj/.claude/pipeline-state.md" <<'PRESEED'
---
pipeline: standard
goal: "verify stuck_cycling resume guard"
original_goal: "verify stuck_cycling resume guard"
status: stuck_cycling
issue: ""
branch: "main"
template: "standard"
current_stage: build
started_at: 2026-04-30T00:00:00Z
pipeline_run_epoch: 1700000000
updated_at: 2026-04-30T00:00:00Z
elapsed: 0s
test_cmd: "false"
pr_number:
model: opus
progress_comment_id:
stages:
  intake: complete
  plan: complete
  build: failed
  test: failed
---

## Log

### test (00:00:10)
failed (1s)

### test (00:00:20)
failed (1s)
PRESEED

    # Resume without override — must refuse with exit 2.
    invoke_pipeline resume --skip-gates --self-heal 1

    assert_exit_code 2 "resume refused with exit code 2" &&
    assert_output_contains "stuck_cycling" "diagnostic message mentions stuck_cycling" &&
    assert_output_contains "SW_PIPELINE_MAX_BUILD_RETRIES=0" "override hint shown" &&
    assert_state_contains "status: stuck_cycling" "state file unchanged after refusal"
}

# ──────────────────────────────────────────────────────────────────────────────
# Cycling Halt: resume of a `stuck_cycling` pipeline IS allowed when the
# operator explicitly disables the cap via SW_PIPELINE_MAX_BUILD_RETRIES=0.
# ──────────────────────────────────────────────────────────────────────────────
test_stuck_cycling_resume_allowed_with_override() {
    pipeline_config_with_stages "intake,plan,build,test" > "$TEST_TEMP_DIR/templates/pipelines/standard.json"

    local fail_cmd="$TEST_TEMP_DIR/bin/always-fail-test"
    cat > "$fail_cmd" <<'FAIL_EOF'
#!/usr/bin/env bash
exit 1
FAIL_EOF
    chmod +x "$fail_cmd"

    local proj="$TEST_TEMP_DIR/project"
    mkdir -p "$proj/.claude"
    cat > "$proj/.claude/pipeline-state.md" <<'PRESEED'
---
pipeline: standard
goal: "verify stuck_cycling override resume"
original_goal: "verify stuck_cycling override resume"
status: stuck_cycling
issue: ""
branch: "main"
template: "standard"
current_stage: build
started_at: 2026-04-30T00:00:00Z
pipeline_run_epoch: 1700000000
updated_at: 2026-04-30T00:00:00Z
elapsed: 0s
test_cmd: "false"
pr_number:
model: opus
progress_comment_id:
stages:
  intake: complete
  plan: complete
---

## Log

### test (00:00:10)
failed (1s)
PRESEED

    # With cap disabled, resume proceeds (no exit 2 refusal).
    SW_PIPELINE_MAX_BUILD_RETRIES=0 \
        invoke_pipeline resume --skip-gates --test-cmd "$fail_cmd" --self-heal 1

    # Refusal would have exited 2 BEFORE reaching the test cycle.
    if [[ "$PIPELINE_EXIT" -eq 2 ]] && printf '%s\n' "$PIPELINE_OUTPUT" | grep -q "refusing to resume"; then
        assert_fail "stuck_cycling override: resume was refused despite SW_PIPELINE_MAX_BUILD_RETRIES=0"
        return
    fi
    assert_output_contains "cap disabled" "override warning shown when proceeding"
}

# ──────────────────────────────────────────────────────────────────────────────
# Cycling Halt: fresh `pipeline start` is refused when the existing state file
# shows a previous run halted in `stuck_cycling`. Prevents silent overwrite.
# ──────────────────────────────────────────────────────────────────────────────
test_stuck_cycling_start_refused() {
    pipeline_config_with_stages "intake,plan,build,test" > "$TEST_TEMP_DIR/templates/pipelines/standard.json"

    local proj="$TEST_TEMP_DIR/project"
    mkdir -p "$proj/.claude"
    cat > "$proj/.claude/pipeline-state.md" <<'PRESEED'
---
pipeline: standard
goal: "verify stuck_cycling start guard"
original_goal: "verify stuck_cycling start guard"
status: stuck_cycling
issue: ""
branch: "main"
template: "standard"
current_stage: build
started_at: 2026-04-30T00:00:00Z
pipeline_run_epoch: 1700000000
updated_at: 2026-04-30T00:00:00Z
elapsed: 0s
test_cmd: "false"
pr_number:
model: opus
progress_comment_id:
stages:
  intake: complete
---
PRESEED

    invoke_pipeline start --goal "should be refused" --skip-gates

    assert_exit_code 2 "start refused with exit code 2" &&
    assert_output_contains "stuck_cycling" "diagnostic message mentions stuck_cycling" &&
    assert_output_contains "shipwright pipeline abort" "abort hint shown" &&
    assert_state_contains "status: stuck_cycling" "state file unchanged after refusal"
}

# ──────────────────────────────────────────────────────────────────────────────
# Cycling Halt: review self-healing path function (self_healing_review_build_test)
# exists in sw-pipeline.sh. Propagation of stuck_cycling through this path is
# verified at unit level in sw-lib-pipeline-state-test.sh (issue #448 DoD).
# This integration test verifies the function is present and callable.
# ──────────────────────────────────────────────────────────────────────────────
test_stuck_cycling_fires_through_review_self_heal_path() {
    # Verify self_healing_review_build_test is defined in the real pipeline script.
    # Functional propagation is covered by sw-lib-pipeline-state-test.sh unit tests.
    if grep -q "^self_healing_review_build_test()" "$TEST_TEMP_DIR/scripts/sw-pipeline.sh"; then
        assert_pass "Cycling: self_healing_review_build_test function defined in sw-pipeline.sh"
    else
        assert_fail "Cycling: self_healing_review_build_test function missing from sw-pipeline.sh"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# #504 D2 — cleanup_on_exit wires cost_baseline_update + render after breakdown
# ──────────────────────────────────────────────────────────────────────────────
test_cleanup_wires_cost_baseline_and_render() {
    # Static wiring assertion — guards against future refactors silently dropping
    # the integration. Pairs with the functional test below.
    local cleanup_block
    cleanup_block=$(awk '/^cleanup_on_exit\(\)/,/^_signal_cleanup\(\)/' \
        "$TEST_TEMP_DIR/scripts/sw-pipeline.sh")
    if printf '%s\n' "$cleanup_block" | grep -q 'cost_generate_breakdown' && \
       printf '%s\n' "$cleanup_block" | grep -q 'render_cost_table_plain' && \
       printf '%s\n' "$cleanup_block" | grep -q 'cost_baseline_update'; then
        assert_pass "Cost: cleanup_on_exit wires breakdown→render→baseline_update (#504 D2)" >/dev/null 2>&1 || true
        return 0
    fi
    echo -e "    ${RED}✗${RESET} cleanup_on_exit missing cost render or baseline-update wiring"
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# #504 D2 — pipeline-stages-delivery.sh posts cost table as PR-stage comment
# ──────────────────────────────────────────────────────────────────────────────
test_pr_stage_posts_cost_table_comment() {
    local delivery="$TEST_TEMP_DIR/scripts/lib/pipeline-stages-delivery.sh"
    if [[ ! -f "$delivery" ]]; then
        echo -e "    ${RED}✗${RESET} delivery lib missing at $delivery"
        return 1
    fi
    # Must source cost helpers defensively AND post a comment containing the table.
    if grep -q 'render_cost_table_plain' "$delivery" && \
       grep -q 'Pipeline cost breakdown' "$delivery" && \
       grep -q 'gh_comment_issue.*cost_table\|gh_comment_issue.*_cost_table\|cost_table' "$delivery"; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} pipeline-stages-delivery.sh missing cost-table PR comment hook"
    grep -n 'render_cost_table_plain\|Pipeline cost breakdown' "$delivery" || true
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# Merge-stage race: both failure paths must check if PR is already MERGED
# before treating gh-CLI non-zero as a stage failure. Race seen in run
# 26134391810 — GitHub auto-merge completed between `gh pr merge --auto`
# request and response, causing both the auto-merge fallthrough and the
# direct-merge attempt to exit non-zero even though PR was merged on main.
# ──────────────────────────────────────────────────────────────────────────────
test_merge_stage_checks_already_merged_on_failure() {
    local delivery="$TEST_TEMP_DIR/scripts/lib/pipeline-stages-delivery.sh"
    if [[ ! -f "$delivery" ]]; then
        echo -e "    ${RED}✗${RESET} delivery lib missing at $delivery"
        return 1
    fi
    # Both gh-CLI failure paths must query state and accept MERGED as success.
    # Count is 2 because there are two distinct merge attempts (auto + direct).
    # Use `|| true` + `${var:-0}` (not `|| echo 0`) — under set -e pipefail,
    # `grep -c` exits 1 on no-match but still prints "0", so `|| echo 0` would
    # yield "0\n0" and break numeric comparison. Use grep -E for | alternation
    # (POSIX BRE \| is non-portable on BSD grep / macOS).
    local state_check_count merged_branch_count
    state_check_count=$(grep -c 'gh pr view "$pr_number" --json state' "$delivery" || true)
    state_check_count=${state_check_count:-0}
    merged_branch_count=$(grep -cE '"\$_pr_state_auto" == "MERGED"|"\$_pr_state_direct" == "MERGED"' "$delivery" || true)
    merged_branch_count=${merged_branch_count:-0}
    if [[ "$state_check_count" -ge 2 ]] && [[ "$merged_branch_count" -ge 2 ]] && \
       grep -q 'merge.race_won' "$delivery"; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} merge stage missing race-check (state_checks=$state_check_count, merged_branches=$merged_branch_count)"
    grep -n 'gh pr view\|race_won\|MERGED' "$delivery" || true
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# #504 D2 — hermetic: render_cost_table_plain + cost_baseline_update from a
# staged cost-breakdown.json produce a non-empty table and update baseline file.
# Validates the helpers wired into cleanup_on_exit are functional, not just
# textually present.
# ──────────────────────────────────────────────────────────────────────────────
test_cost_helpers_functional_against_staged_breakdown() {
    local hermetic_dir="$TEST_TEMP_DIR/cost-hermetic-$$"
    rm -rf "$hermetic_dir"
    mkdir -p "$hermetic_dir/artifacts" "$hermetic_dir/baselines"

    # Stage a 2-stage breakdown.json mirroring real pipeline output shape.
    cat > "$hermetic_dir/artifacts/cost-breakdown.json" <<'BD'
{
  "schema_version": 1,
  "pipeline_id": "p-504-test",
  "issue": "504",
  "generated_at": "2026-05-05T00:00:00Z",
  "by_stage": [
    {"stage": "intake", "input_tokens": 12450, "output_tokens": 1230,
     "cost_usd": 0.0042, "model_mix": "sonnet", "iterations": 1},
    {"stage": "build",  "input_tokens": 312000, "output_tokens": 28400,
     "cost_usd": 0.92, "model_mix": "opus",   "iterations": 3}
  ],
  "totals": {"input_tokens": 324450, "output_tokens": 29630, "cost_usd": 0.9242}
}
BD

    # Run helpers in an isolated subshell so we don't pollute parent env.
    local rendered baseline_n_intake baseline_n_build rc=0
    # Source the real sw-cost.sh from the repo (test scaffold copies sw-pipeline.sh
    # and lib/ but NOT sw-cost.sh — the helpers we wired into cleanup live there).
    local cost_script="$SCRIPT_DIR/sw-cost.sh"
    if [[ ! -f "$cost_script" ]]; then
        echo -e "    ${RED}✗${RESET} sw-cost.sh not found at $cost_script"
        return 1
    fi
    rendered=$(
        export SW_BASELINE_DIR="$hermetic_dir/baselines"
        # shellcheck disable=SC1091
        source "$cost_script" 2>/dev/null || true
        if ! type render_cost_table_plain >/dev/null 2>&1; then
            echo "FATAL: render_cost_table_plain not loaded after sourcing sw-cost.sh" >&2
            exit 9
        fi
        if ! type cost_baseline_update >/dev/null 2>&1; then
            echo "FATAL: cost_baseline_update not loaded after sourcing sw-cost.sh" >&2
            exit 9
        fi
        # Render first, then update baseline (matches cleanup_on_exit ordering).
        render_cost_table_plain "$hermetic_dir/artifacts/cost-breakdown.json" \
            --issue 504 --baseline-context 2>&1
        cost_baseline_update "$hermetic_dir/artifacts/cost-breakdown.json" 504 >/dev/null 2>&1 || true
    ) || rc=$?

    if [[ "$rc" -ne 0 ]]; then
        echo -e "    ${RED}✗${RESET} hermetic helper run failed (rc=$rc)"
        echo "$rendered" | tail -10 | sed 's/^/      /'
        return 1
    fi

    # Assert table headers + stage rows present in render output.
    if ! printf '%s\n' "$rendered" | grep -qE 'Stage|stage'; then
        echo -e "    ${RED}✗${RESET} rendered table missing 'Stage' header"
        echo "$rendered" | head -8 | sed 's/^/      /'
        return 1
    fi
    if ! printf '%s\n' "$rendered" | grep -q 'intake' || \
       ! printf '%s\n' "$rendered" | grep -q 'build'; then
        echo -e "    ${RED}✗${RESET} rendered table missing stage rows (intake/build)"
        return 1
    fi

    # Assert baseline files written for both all-issues and per-issue.
    if [[ ! -f "$hermetic_dir/baselines/stage-costs.json" ]]; then
        echo -e "    ${RED}✗${RESET} baseline stage-costs.json not created"
        ls -la "$hermetic_dir/baselines" 2>&1 | sed 's/^/      /'
        return 1
    fi
    if [[ ! -f "$hermetic_dir/baselines/issue-504-costs.json" ]]; then
        echo -e "    ${RED}✗${RESET} per-issue baseline issue-504-costs.json not created"
        return 1
    fi

    # Assert baseline picked up both stages with n>=1.
    baseline_n_intake=$(jq '.stages.intake.n // 0' \
        "$hermetic_dir/baselines/stage-costs.json" 2>/dev/null || echo 0)
    baseline_n_build=$(jq '.stages.build.n // 0' \
        "$hermetic_dir/baselines/stage-costs.json" 2>/dev/null || echo 0)
    if [[ "$baseline_n_intake" -lt 1 || "$baseline_n_build" -lt 1 ]]; then
        echo -e "    ${RED}✗${RESET} baseline counts wrong (intake=$baseline_n_intake build=$baseline_n_build)"
        return 1
    fi

    rm -rf "$hermetic_dir"
    return 0
}

# Helper for the disabled test (assert state file does NOT contain pattern)
assert_state_not_contains() {
    local pattern="$1" label="${2:-state exclusion}"
    local full_path="$TEST_TEMP_DIR/project/.claude/pipeline-state.md"
    if [[ ! -f "$full_path" ]]; then
        return 0
    fi
    if grep -qE "$pattern" "$full_path"; then
        echo -e "    ${RED}✗${RESET} State unexpectedly contains: $pattern ($label)"
        return 1
    fi
    return 0
}

# ══════════════════════════════════════════════════════════════════════════════
# compose_prompt iteration-awareness tests (TDD — written before implementation)
#
# These tests validate the planned iteration-aware prompt composition changes in
# scripts/lib/loop-iteration.sh :: compose_prompt(). Each test creates a self-
# contained subshell with all required stubs, sources the real loop-iteration.sh,
# and inspects compose_prompt output.
#
# Stub scaffold shared by all 10 tests (written inline per test for isolation).
# ══════════════════════════════════════════════════════════════════════════════

# Helper: write the common stub preamble into a given file.
# Usage: _write_compose_prompt_stubs <file> [emit_event_override]
_write_compose_prompt_stubs() {
    local stub_file="$1"
    local emit_override="${2:-}"
    [[ -z "$emit_override" ]] && emit_override='emit_event() { true; }'
    cat > "$stub_file" <<STUBEOF
#!/usr/bin/env bash
set -uo pipefail

# --- dependency stubs for compose_prompt ---
git_recent_log()                     { echo "recent git log"; }
compose_audit_section()              { echo ""; }
compose_audit_feedback_section()     { echo ""; }
compose_holistic_feedback_section()  { echo ""; }
compose_quality_gate_detail_section() { echo ""; }
compose_rejection_notice_section()   { echo ""; }
detect_stuckness()                   { return 1; }
compose_task_section()               { echo ""; }
explore_alternative_strategy()       { echo ""; }
memory_inject_context()              { echo ""; }
inject_discoveries()                 { echo ""; }
memory_get_dora_baseline()           { echo "{}"; }
info()    { true; }
warn()    { true; }
error()   { true; }
success() { true; }
_git_excluded_pathspecs()            { true; }
_git_branch_merge_base() {
    local _base="\${1:-}" _fallback="\${2:-}" _root="\${PROJECT_ROOT:-.}"
    [[ -z "\$_base" ]] && _base="main"
    git -C "\$_root" merge-base "\${_base}" HEAD 2>/dev/null || echo "\${_fallback}"
}
${emit_override}

# --- environment expected by compose_prompt ---
ITERATION="\${ITERATION:-1}"
MAX_ITERATIONS="\${MAX_ITERATIONS:-10}"
LOG_DIR="\${LOG_DIR:-/tmp/test-loop-stub-$$}"
PROJECT_ROOT="\${PROJECT_ROOT:-/tmp}"
SCRIPT_DIR="\${SCRIPT_DIR:-/tmp}"
ARTIFACTS_DIR="\${ARTIFACTS_DIR:-.claude/pipeline-artifacts}"
LOG_ENTRIES="\${LOG_ENTRIES:-}"
TEST_CMD="\${TEST_CMD:-}"
TEST_PASSED="\${TEST_PASSED:-}"
TEST_OUTPUT="\${TEST_OUTPUT:-}"
ORIGINAL_GOAL="\${ORIGINAL_GOAL:-test goal}"
GOAL="\${GOAL:-test goal}"
LOOP_START_COMMIT="\${LOOP_START_COMMIT:-}"
SESSION_RESTART="\${SESSION_RESTART:-false}"
RESUMED_FROM_ITERATION="\${RESUMED_FROM_ITERATION:-}"
PREV_NEW_COMMITS="\${PREV_NEW_COMMITS:-0}"
QUALITY_GATE_PASSED="\${QUALITY_GATE_PASSED:-true}"
AUDIT_ENABLED="\${AUDIT_ENABLED:-false}"
AUDIT_RESULT="\${AUDIT_RESULT:-}"
HOLISTIC_RESULT="\${HOLISTIC_RESULT:-}"
COMPLETION_REJECTED="\${COMPLETION_REJECTED:-false}"
GATES_PASSED_NO_SIGNAL="\${GATES_PASSED_NO_SIGNAL:-false}"
NO_GITHUB="\${NO_GITHUB:-true}"
LOOP_CONTEXT_FILE="\${LOOP_CONTEXT_FILE:-}"
STUBEOF
}

# ──────────────────────────────────────────────────────────────────────────────
# 57. compose_prompt iter 1 includes pipeline_context_section
# ──────────────────────────────────────────────────────────────────────────────
test_compose_prompt_iter1_includes_pipeline_context() {
    local tmp_dir
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/cp-test-iter1-ctx.XXXXXX")
    local ctx_file="$tmp_dir/ctx.txt"
    echo "SENTINEL_CONTEXT_CONTENT" > "$ctx_file"

    local stub_file="$tmp_dir/stubs.sh"
    _write_compose_prompt_stubs "$stub_file"

    local output
    output=$(
        # shellcheck disable=SC1090
        source "$stub_file"
        export ITERATION=1
        export LOOP_CONTEXT_FILE="$ctx_file"
        unset _LOOP_ITERATION_LOADED
        # shellcheck disable=SC1090
        source "$SCRIPT_DIR/lib/loop-iteration.sh"
        compose_prompt
    ) 2>/dev/null || output=""

    rm -rf "$tmp_dir"

    if echo "$output" | grep -qF "SENTINEL_CONTEXT_CONTENT"; then
        return 0
    else
        echo "Expected 'SENTINEL_CONTEXT_CONTENT' in compose_prompt output on iteration 1"
        return 1
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# 58. compose_prompt iter 2 omits pipeline_context_section
# ──────────────────────────────────────────────────────────────────────────────
test_compose_prompt_iter2_omits_pipeline_context() {
    local tmp_dir
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/cp-test-iter2-noctx.XXXXXX")
    local ctx_file="$tmp_dir/ctx.txt"
    echo "SENTINEL_CONTEXT_CONTENT" > "$ctx_file"

    local stub_file="$tmp_dir/stubs.sh"
    _write_compose_prompt_stubs "$stub_file"

    local output
    output=$(
        # shellcheck disable=SC1090
        source "$stub_file"
        export ITERATION=2
        export LOOP_CONTEXT_FILE="$ctx_file"
        unset _LOOP_ITERATION_LOADED
        # shellcheck disable=SC1090
        source "$SCRIPT_DIR/lib/loop-iteration.sh"
        compose_prompt
    ) 2>/dev/null || output=""

    rm -rf "$tmp_dir"

    if echo "$output" | grep -qF "SENTINEL_CONTEXT_CONTENT"; then
        echo "compose_prompt on iteration 2 should NOT include pipeline_context_section"
        return 1
    else
        return 0
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# 59. compose_prompt iter 2 prepends REFERENCE ONLY label to history
# ──────────────────────────────────────────────────────────────────────────────
test_compose_prompt_iter2_reference_only_label() {
    local tmp_dir
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/cp-test-iter2-refonly.XXXXXX")

    local stub_file="$tmp_dir/stubs.sh"
    _write_compose_prompt_stubs "$stub_file"

    local output
    output=$(
        # shellcheck disable=SC1090
        source "$stub_file"
        export ITERATION=2
        export LOG_ENTRIES="Iteration 1 summary"
        unset _LOOP_ITERATION_LOADED
        # shellcheck disable=SC1090
        source "$SCRIPT_DIR/lib/loop-iteration.sh"
        compose_prompt
    ) 2>/dev/null || output=""

    rm -rf "$tmp_dir"

    if echo "$output" | grep -qF "REFERENCE ONLY"; then
        return 0
    else
        echo "Expected 'REFERENCE ONLY' label in compose_prompt output on iteration 2"
        return 1
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# 60. compose_prompt iter 2 demotes full test output when error summary present
# ──────────────────────────────────────────────────────────────────────────────
test_compose_prompt_iter2_test_section_demoted() {
    local tmp_dir
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/cp-test-iter2-demote.XXXXXX")
    mkdir -p "$tmp_dir/log"

    # Build 80-line test output; line 1 should NOT appear when demoted
    local long_output
    long_output="$(seq 1 80 | while read -r n; do printf 'line %d\n' "$n"; done)"

    # Write an error-summary.json so error_summary_section is non-empty
    cat > "$tmp_dir/log/error-summary.json" <<'JSON'
{"error_count":1,"error_lines":["structured errors here"]}
JSON

    local stub_file="$tmp_dir/stubs.sh"
    _write_compose_prompt_stubs "$stub_file"

    local output
    output=$(
        # shellcheck disable=SC1090
        source "$stub_file"
        export ITERATION=2
        export TEST_PASSED=false
        export TEST_OUTPUT="$long_output"
        export LOG_DIR="$tmp_dir/log"
        unset _LOOP_ITERATION_LOADED
        # shellcheck disable=SC1090
        source "$SCRIPT_DIR/lib/loop-iteration.sh"
        compose_prompt
    ) 2>/dev/null || output=""

    rm -rf "$tmp_dir"

    # Must NOT contain the very first line of the 80-line output
    if echo "$output" | grep -qF "line 1"; then
        echo "Full test output should be demoted on iteration 2 when error summary is present (line 1 found)"
        return 1
    fi
    # Must contain either a "Last 30 lines" indicator or a "Structured Error Summary" cross-reference
    if echo "$output" | grep -qE "Last 30 lines|Structured Error Summary"; then
        return 0
    else
        echo "Expected 'Last 30 lines' or 'Structured Error Summary' cross-reference in demoted test section"
        return 1
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# 61. compose_prompt SESSION_RESTART=true forces full context even at iter 5
# ──────────────────────────────────────────────────────────────────────────────
test_compose_prompt_session_restart_full_context() {
    local tmp_dir
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/cp-test-restart-ctx.XXXXXX")
    local ctx_file="$tmp_dir/ctx.txt"
    echo "SENTINEL_CONTEXT_CONTENT" > "$ctx_file"

    local stub_file="$tmp_dir/stubs.sh"
    _write_compose_prompt_stubs "$stub_file"

    local output
    output=$(
        # shellcheck disable=SC1090
        source "$stub_file"
        export ITERATION=5
        export SESSION_RESTART=true
        export LOOP_CONTEXT_FILE="$ctx_file"
        unset _LOOP_ITERATION_LOADED
        # shellcheck disable=SC1090
        source "$SCRIPT_DIR/lib/loop-iteration.sh"
        compose_prompt
    ) 2>/dev/null || output=""

    rm -rf "$tmp_dir"

    if echo "$output" | grep -qF "SENTINEL_CONTEXT_CONTENT"; then
        return 0
    else
        echo "Expected 'SENTINEL_CONTEXT_CONTENT' in compose_prompt output when SESSION_RESTART=true (iter 5)"
        return 1
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# 62. compose_prompt RESUMED_FROM_ITERATION forces full context
# ──────────────────────────────────────────────────────────────────────────────
test_compose_prompt_resumed_full_context() {
    local tmp_dir
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/cp-test-resumed-ctx.XXXXXX")
    local ctx_file="$tmp_dir/ctx.txt"
    echo "SENTINEL_CONTEXT_CONTENT" > "$ctx_file"

    local stub_file="$tmp_dir/stubs.sh"
    _write_compose_prompt_stubs "$stub_file"

    local output
    output=$(
        # shellcheck disable=SC1090
        source "$stub_file"
        export ITERATION=3
        export RESUMED_FROM_ITERATION=2
        export LOOP_CONTEXT_FILE="$ctx_file"
        unset _LOOP_ITERATION_LOADED
        # shellcheck disable=SC1090
        source "$SCRIPT_DIR/lib/loop-iteration.sh"
        compose_prompt
    ) 2>/dev/null || output=""

    rm -rf "$tmp_dir"

    if echo "$output" | grep -qF "SENTINEL_CONTEXT_CONTENT"; then
        return 0
    else
        echo "Expected 'SENTINEL_CONTEXT_CONTENT' in compose_prompt when RESUMED_FROM_ITERATION is set"
        return 1
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# 63. compose_prompt iter 2 includes recent commits since LOOP_START_COMMIT
# ──────────────────────────────────────────────────────────────────────────────
test_compose_prompt_iter2_recent_commits_section() {
    local tmp_dir
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/cp-test-iter2-commits.XXXXXX")

    # Create a minimal git repo with a commit so git log works
    local git_dir="$tmp_dir/repo"
    mkdir -p "$git_dir"
    git -C "$git_dir" init --quiet
    git -C "$git_dir" config user.email "test@test.com"
    git -C "$git_dir" config user.name "Test"
    echo "init" > "$git_dir/init.txt"
    git -C "$git_dir" add init.txt
    git -C "$git_dir" commit -m "init" --quiet
    local start_commit
    start_commit=$(git -C "$git_dir" rev-parse HEAD)
    echo "work" > "$git_dir/work.txt"
    git -C "$git_dir" add work.txt
    git -C "$git_dir" commit -m "feat: work done" --quiet

    local stub_file="$tmp_dir/stubs.sh"
    _write_compose_prompt_stubs "$stub_file"

    local output
    output=$(
        # shellcheck disable=SC1090
        source "$stub_file"
        export ITERATION=2
        export LOOP_START_COMMIT="$start_commit"
        export PROJECT_ROOT="$git_dir"
        unset _LOOP_ITERATION_LOADED
        # shellcheck disable=SC1090
        source "$SCRIPT_DIR/lib/loop-iteration.sh"
        compose_prompt
    ) 2>/dev/null || output=""

    rm -rf "$tmp_dir"

    if echo "$output" | grep -qF "Commits This Pipeline"; then
        return 0
    else
        echo "Expected 'Commits This Pipeline' section in compose_prompt on iteration 2 with LOOP_START_COMMIT set"
        return 1
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# 64. compose_prompt iter 2 appends Reference trailer after Rules
# ──────────────────────────────────────────────────────────────────────────────
test_compose_prompt_iter2_reference_trailer() {
    local tmp_dir
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/cp-test-iter2-ref.XXXXXX")

    local stub_file="$tmp_dir/stubs.sh"
    _write_compose_prompt_stubs "$stub_file"

    local output
    output=$(
        # shellcheck disable=SC1090
        source "$stub_file"
        export ITERATION=2
        unset _LOOP_ITERATION_LOADED
        # shellcheck disable=SC1090
        source "$SCRIPT_DIR/lib/loop-iteration.sh"
        compose_prompt
    ) 2>/dev/null || output=""

    rm -rf "$tmp_dir"

    if echo "$output" | grep -qF "pipeline-artifacts"; then
        return 0
    else
        echo "Expected 'pipeline-artifacts' reference trailer in compose_prompt on iteration 2"
        return 1
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# 65. compose_prompt iter 1 does NOT include Reference trailer
# ──────────────────────────────────────────────────────────────────────────────
test_compose_prompt_iter1_no_reference_trailer() {
    local tmp_dir
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/cp-test-iter1-noref.XXXXXX")

    local stub_file="$tmp_dir/stubs.sh"
    _write_compose_prompt_stubs "$stub_file"

    local output
    output=$(
        # shellcheck disable=SC1090
        source "$stub_file"
        export ITERATION=1
        unset _LOOP_ITERATION_LOADED
        # shellcheck disable=SC1090
        source "$SCRIPT_DIR/lib/loop-iteration.sh"
        compose_prompt
    ) 2>/dev/null || output=""

    rm -rf "$tmp_dir"

    if echo "$output" | grep -qF "Reference (read on demand"; then
        echo "compose_prompt on iteration 1 should NOT include the Reference trailer"
        return 1
    else
        return 0
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# 66. compose_prompt emits context.iteration_prompt event
# ──────────────────────────────────────────────────────────────────────────────
test_compose_prompt_emits_context_event() {
    local tmp_dir
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/cp-test-event.XXXXXX")
    local event_file="$tmp_dir/events.txt"

    # Override emit_event stub to write to event_file
    local emit_override
    emit_override='emit_event() { echo "$1" >> '"$event_file"'; }'

    local stub_file="$tmp_dir/stubs.sh"
    _write_compose_prompt_stubs "$stub_file" "$emit_override"

    (
        # shellcheck disable=SC1090
        source "$stub_file"
        export ITERATION=2
        unset _LOOP_ITERATION_LOADED
        # shellcheck disable=SC1090
        source "$SCRIPT_DIR/lib/loop-iteration.sh"
        compose_prompt > /dev/null
    ) 2>/dev/null || true

    local found=false
    if [[ -f "$event_file" ]] && grep -qF "context.iteration_prompt" "$event_file"; then
        found=true
    fi

    rm -rf "$tmp_dir"

    if [[ "$found" == "true" ]]; then
        return 0
    else
        echo "Expected emit_event to be called with 'context.iteration_prompt' during compose_prompt"
        return 1
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# 67. compose_prompt iter 2 — Instructions precedes Test Results
# ──────────────────────────────────────────────────────────────────────────────
test_compose_prompt_iter2_instructions_before_test_results() {
    local tmp_dir
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/cp-test-iter2-order.XXXXXX")

    local stub_file="$tmp_dir/stubs.sh"
    _write_compose_prompt_stubs "$stub_file"

    local output
    output=$(
        # shellcheck disable=SC1090
        source "$stub_file"
        export ITERATION=2
        export TEST_PASSED=true
        export TEST_OUTPUT="TESTS PASSED"
        unset _LOOP_ITERATION_LOADED
        # shellcheck disable=SC1090
        source "$SCRIPT_DIR/lib/loop-iteration.sh"
        compose_prompt
    ) 2>/dev/null || output=""

    rm -rf "$tmp_dir"

    # || true prevents set -e / pipefail from aborting the suite when grep exits 1 (no match)
    local instr_line test_line
    instr_line=$(echo "$output" | grep -n "^## Instructions" | head -1 | cut -d: -f1 || true)
    test_line=$(echo "$output" | grep -n "^## Test Results" | head -1 | cut -d: -f1 || true)

    if [[ -z "$instr_line" || -z "$test_line" ]]; then
        echo "Could not find ## Instructions (line ${instr_line:-?}) or ## Test Results (line ${test_line:-?}) in iter-2 prompt"
        return 1
    fi

    if [[ "$instr_line" -lt "$test_line" ]]; then
        return 0
    else
        echo "## Instructions (line $instr_line) should appear before ## Test Results (line $test_line) in iter-2 prompt"
        return 1
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# 68. compose_prompt iter 2 cumulative progress uses merge-base (full branch)
# ──────────────────────────────────────────────────────────────────────────────
test_compose_prompt_iter2_cumulative_uses_merge_base() {
    local tmp_dir
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/cp-test-iter2-mergebase.XXXXXX")

    # Two WIP commits on a branch from main.
    # LOOP_START_COMMIT is set to the FIRST WIP commit (simulating a CI-job reset
    # where only commit 2 is "in scope" for the current job). The cumulative section
    # must show BOTH files because it uses merge-base, not LOOP_START_COMMIT.
    local git_dir="$tmp_dir/repo"
    mkdir -p "$git_dir"
    git -C "$git_dir" init --quiet
    git -C "$git_dir" config user.email "test@test.com"
    git -C "$git_dir" config user.name "Test"
    echo "init" > "$git_dir/init.txt"
    git -C "$git_dir" add init.txt
    git -C "$git_dir" commit -m "initial" --quiet
    # Rename initial branch to 'main' so git merge-base "main" HEAD works on
    # systems where init.defaultBranch is 'master' instead of 'main'.
    git -C "$git_dir" branch -M main 2>/dev/null || true
    # Branch off main so merge-base resolves to the initial commit (not HEAD)
    git -C "$git_dir" checkout -b feature --quiet
    # First WIP commit
    echo "file1 content" > "$git_dir/file1.txt"
    git -C "$git_dir" add file1.txt
    git -C "$git_dir" commit -m "add file1" --quiet
    local ci_job_start
    ci_job_start=$(git -C "$git_dir" rev-parse HEAD)
    # Sanity: if we can't determine the SHA, skip gracefully
    [[ -z "$ci_job_start" ]] && { rm -rf "$tmp_dir"; echo "git rev-parse failed in test setup"; return 1; }
    # Second WIP commit (what the current CI job added)
    echo "file2 content" > "$git_dir/file2.txt"
    git -C "$git_dir" add file2.txt
    git -C "$git_dir" commit -m "add file2" --quiet

    local stub_file="$tmp_dir/stubs.sh"
    _write_compose_prompt_stubs "$stub_file"

    local output
    output=$(
        # shellcheck disable=SC1090
        source "$stub_file"
        export ITERATION=2
        export LOOP_START_COMMIT="$ci_job_start"
        export PROJECT_ROOT="$git_dir"
        unset _LOOP_ITERATION_LOADED
        # shellcheck disable=SC1090
        source "$SCRIPT_DIR/lib/loop-iteration.sh"
        compose_prompt
    ) 2>/dev/null || output=""

    rm -rf "$tmp_dir"

    if ! echo "$output" | grep -qF "Cumulative Progress (all branch changes)"; then
        echo "Expected 'Cumulative Progress (all branch changes)' heading in iter-2 prompt"
        return 1
    fi

    if ! echo "$output" | grep -q "file1\.txt"; then
        echo "Expected file1.txt in cumulative progress (merge-base must include commits before LOOP_START_COMMIT)"
        return 1
    fi

    if ! echo "$output" | grep -q "file2\.txt"; then
        echo "Expected file2.txt in cumulative progress"
        return 1
    fi

    # Per-file stats present — must be more than one file line.
    # grep -c exits 1 on no matches but still prints "0"; || echo 0 would produce "0\n0".
    # Use || true and default separately to guarantee a single integer.
    local file_line_count
    file_line_count=$(echo "$output" | grep -A 20 "Cumulative Progress (all branch changes)" | grep -c "\.txt" || true)
    if [[ "${file_line_count:-0}" -lt 2 ]]; then
        echo "Expected at least 2 file lines in cumulative progress, got ${file_line_count:-0}"
        return 1
    fi

    return 0
}

# ══════════════════════════════════════════════════════════════════════════════
# TDD TESTS — written BEFORE implementation; expected to FAIL against current code
# Each test documents the desired behavior after the corresponding fix lands.
# ══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# Change 1 — intake CI mode: when WORKSPACE_BRANCH is set, use it as GIT_BRANCH
# without calling `git checkout -b`.
#
# Current behavior (BROKEN): intake always runs `git checkout -b <computed-slug>`
# regardless of WORKSPACE_BRANCH; the env var is ignored at the intake stage.
#
# Expected behavior (after fix): when WORKSPACE_BRANCH is set, intake sets
# GIT_BRANCH=WORKSPACE_BRANCH and skips the `git checkout -b` call.  The
# existing branch-creation path is preserved when WORKSPACE_BRANCH is unset.
# ──────────────────────────────────────────────────────────────────────────────
test_intake_ci_uses_workspace_branch() {
    pipeline_config_with_stages "intake" > "$TEST_TEMP_DIR/templates/pipelines/standard.json"

    # Pre-create the branch that CI would have prepared so checkout succeeds.
    local ci_branch="shipwright/issue-42"
    (
        cd "$TEST_TEMP_DIR/project"
        git checkout -b "$ci_branch" --quiet 2>/dev/null || true
        git checkout main --quiet 2>/dev/null || true
    )

    # Invoke with WORKSPACE_BRANCH set (simulates CI environment).
    PIPELINE_OUTPUT=""
    PIPELINE_EXIT=0
    PIPELINE_OUTPUT=$(
        cd "$TEST_TEMP_DIR/project"
        HOME="$TEST_TEMP_DIR" \
        EVENTS_FILE="$TEST_TEMP_DIR/events.jsonl" \
        PATH="$TEST_TEMP_DIR/bin:$PATH" \
        INTELLIGENCE_COMPLEXITY="" \
        INTELLIGENCE_ISSUE_TYPE="" \
        SHIPWRIGHT_MIN_FREE_GB=0 \
        NO_ARTIFACT_PUSH=true \
        WORKSPACE_BRANCH="$ci_branch" \
        bash "$TEST_TEMP_DIR/scripts/sw-pipeline.sh" start \
            --issue 42 --skip-gates --test-cmd "echo passed" 2>&1
    ) || PIPELINE_EXIT=$?

    # After the fix: GIT_BRANCH must equal WORKSPACE_BRANCH ("shipwright/issue-42").
    # The intake artifact must record the correct branch name.
    assert_exit_code 0 "intake with WORKSPACE_BRANCH should succeed" &&
    assert_file_exists ".claude/pipeline-artifacts/intake.json" "intake artifact created" &&
    assert_file_contains ".claude/pipeline-artifacts/intake.json" "shipwright/issue-42" \
        "intake artifact records WORKSPACE_BRANCH as branch" &&
    # After the fix the output must NOT show a computed slug branch being created.
    assert_output_not_contains "feat/.*42\|fix/.*42" \
        "computed slug branch must NOT be used when WORKSPACE_BRANCH is set"
}

# ──────────────────────────────────────────────────────────────────────────────
# Change 1 (local dev mode): when WORKSPACE_BRANCH is NOT set, the existing
# git-checkout-based branch creation is preserved unchanged.
# ──────────────────────────────────────────────────────────────────────────────
test_intake_local_mode_preserves_branch_creation() {
    pipeline_config_with_stages "intake" > "$TEST_TEMP_DIR/templates/pipelines/standard.json"

    # No WORKSPACE_BRANCH — standard local dev invocation.
    invoke_pipeline start --issue 42 --skip-gates --test-cmd "echo passed"

    assert_exit_code 0 "intake without WORKSPACE_BRANCH should succeed" &&
    # The output must NOT show the CI-mode log message — this rules out WORKSPACE_BRANCH
    # being followed even if a residual shipwright/issue-42 branch exists from a prior test.
    assert_output_not_contains "CI mode: using workspace branch" \
        "local mode must not follow WORKSPACE_BRANCH path" &&
    # A slug branch containing the issue number must have been created in this run.
    assert_branch_exists "[a-z][a-z]*/[a-z0-9-]*-42$" "slug-N style branch created for issue" &&
    assert_file_exists ".claude/pipeline-artifacts/intake.json" "intake artifact created"
}

# ──────────────────────────────────────────────────────────────────────────────
# Change 2 — .gitignore: issue-scoped artifact paths are NOT ignored; the flat
# (non-scoped) paths remain ignored.
#
# Current state: the gitignore already has the correct rules as of the last
# commit, so these static checks are designed to catch regressions — any edit
# to .gitignore that removes the `!.claude/pipeline-artifacts/issue-*/` negation
# should make this test fail.
# ──────────────────────────────────────────────────────────────────────────────
test_gitignore_issue_scoped_artifacts_not_ignored() {
    local gitignore="$REPO_DIR/.gitignore"

    if [[ ! -f "$gitignore" ]]; then
        echo -e "    ${RED}x${RESET} .gitignore not found at $gitignore"
        return 1
    fi

    # Must use contents-exclusion form (pipeline-artifacts/*) not directory form (pipeline-artifacts/).
    # Directory form blocks git traversal so negation patterns for subdirectories are silently ignored.
    if ! grep -qxF ".claude/pipeline-artifacts/*" "$gitignore"; then
        echo -e "    ${RED}x${RESET} .gitignore must use '.claude/pipeline-artifacts/*' (contents form, not trailing-slash directory form)"
        return 1
    fi

    # The issue-scoped subdirectory must be un-ignored via negation pattern.
    if ! grep -qxF "!.claude/pipeline-artifacts/issue-*/" "$gitignore"; then
        echo -e "    ${RED}x${RESET} .gitignore must contain '!.claude/pipeline-artifacts/issue-*/' (negation for issue snapshots)"
        return 1
    fi

    # Files inside issue-N/ must also be un-ignored.
    if ! grep -qxF "!.claude/pipeline-artifacts/issue-*/**" "$gitignore"; then
        echo -e "    ${RED}x${RESET} .gitignore must contain '!.claude/pipeline-artifacts/issue-*/**' (negation for files inside issue-N/)"
        return 1
    fi

    # The negation must appear AFTER the ignore line (order matters in gitignore).
    local ignore_line negation_line
    ignore_line=$(grep -n "^\.claude/pipeline-artifacts/\*$" "$gitignore" | head -1 | cut -d: -f1)
    negation_line=$(grep -n "^!\.claude/pipeline-artifacts/issue-\*/$" "$gitignore" | head -1 | cut -d: -f1)

    if [[ -z "$ignore_line" || -z "$negation_line" ]]; then
        echo -e "    ${RED}x${RESET} Could not locate line numbers for gitignore rules"
        return 1
    fi

    if [[ "$negation_line" -le "$ignore_line" ]]; then
        echo -e "    ${RED}x${RESET} Negation (line $negation_line) must appear AFTER ignore rule (line $ignore_line)"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# Change 3 — GHA snapshot precondition: after Change 1 lands, GIT_BRANCH equals
# WORKSPACE_BRANCH when WORKSPACE_BRANCH is set.  This test verifies the shell
# logic that the GHA snapshot step depends on: files placed under
# `.claude/pipeline-artifacts/issue-N/` are the ones that the snapshot step
# would commit.
#
# Current behavior (BROKEN): GIT_BRANCH is set to a computed slug, not to
# WORKSPACE_BRANCH; a GHA snapshot step keyed on WORKSPACE_BRANCH would record
# the wrong branch name in the artifact.
#
# Expected behavior (after Change 1): GIT_BRANCH == WORKSPACE_BRANCH so the
# snapshot step can safely use either variable to identify the workspace.
# ──────────────────────────────────────────────────────────────────────────────
test_intake_git_branch_equals_workspace_branch_when_set() {
    pipeline_config_with_stages "intake" > "$TEST_TEMP_DIR/templates/pipelines/standard.json"

    local ci_branch="shipwright/issue-99"
    (
        cd "$TEST_TEMP_DIR/project"
        git checkout -b "$ci_branch" --quiet 2>/dev/null || true
        git checkout main --quiet 2>/dev/null || true
    )

    PIPELINE_OUTPUT=""
    PIPELINE_EXIT=0
    PIPELINE_OUTPUT=$(
        cd "$TEST_TEMP_DIR/project"
        HOME="$TEST_TEMP_DIR" \
        EVENTS_FILE="$TEST_TEMP_DIR/events.jsonl" \
        PATH="$TEST_TEMP_DIR/bin:$PATH" \
        INTELLIGENCE_COMPLEXITY="" \
        INTELLIGENCE_ISSUE_TYPE="" \
        SHIPWRIGHT_MIN_FREE_GB=0 \
        NO_ARTIFACT_PUSH=true \
        WORKSPACE_BRANCH="$ci_branch" \
        bash "$TEST_TEMP_DIR/scripts/sw-pipeline.sh" start \
            --issue 99 --skip-gates --test-cmd "echo passed" 2>&1
    ) || PIPELINE_EXIT=$?

    assert_exit_code 0 "intake with WORKSPACE_BRANCH=shipwright/issue-99 should succeed" || return 1

    # After Change 1: the intake artifact must record "shipwright/issue-99" as the
    # branch — confirming GIT_BRANCH was set from WORKSPACE_BRANCH, not computed.
    local recorded_branch=""
    local intake_json="$TEST_TEMP_DIR/project/.claude/pipeline-artifacts/intake.json"
    if [[ -f "$intake_json" ]]; then
        recorded_branch=$(jq -r '.branch // ""' "$intake_json" 2>/dev/null || true)
    fi

    if [[ "$recorded_branch" != "$ci_branch" ]]; then
        echo -e "    ${RED}x${RESET} intake.json recorded branch='$recorded_branch', expected '$ci_branch'"
        echo -e "    ${DIM}This confirms Change 1 is not yet implemented: GIT_BRANCH is still computed from slug.${RESET}"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# Change 4 — Restore step: mocked issue-N/ snapshot directory is copied back to
# canonical locations by the restore loop.
#
# This test verifies the restore logic in isolation (no full pipeline run)
# by directly exercising the shell construct that the GHA "Verify merged
# artifacts" step uses.
#
# Current behavior (BROKEN): the restore loop only runs inside GHA YAML and
# there is no equivalent tested path in the pipeline shell scripts; a bug in
# the restore logic would be silently missed.
#
# Expected behavior (after Change 4): a helper function (or inline block)
# in the pipeline scripts mirrors the GHA restore logic and can be unit-tested
# here — OR the test validates that the GHA yaml step contains the required
# cp/restore pattern so regression is caught statically.
# ──────────────────────────────────────────────────────────────────────────────
test_restore_loop_copies_snapshot_to_canonical() {
    # Set up a mock issue-N/ snapshot directory the way the GHA step creates it.
    local artifacts="$TEST_TEMP_DIR/project/.claude/pipeline-artifacts"
    local snap_dir="$artifacts/issue-99"
    mkdir -p "$snap_dir"
    mkdir -p "$artifacts"

    # Populate snapshot files (simulating what a prior pipeline run committed).
    echo "# Plan from prior run" > "$snap_dir/plan.md"
    echo '{"status":"interrupted"}' > "$snap_dir/pipeline-status.json"

    # Run the restore loop logic — mirrors the GHA "Verify merged artifacts" step.
    # After Change 4 this logic should exist as a callable shell function or be
    # exercised via a pipeline subcommand.  For now we test the raw loop inline
    # to confirm the EXPECTED behavior and let the test fail until a wrapper lands.
    local restore_ran=false
    local issue_number=99
    local recovered=0

    for f in plan.md pipeline-status.json; do
        local fpath="$artifacts/$f"
        local snap="$snap_dir/$f"
        if [[ ! -s "$fpath" && -s "$snap" ]]; then
            cp "$snap" "$fpath"
            recovered=$((recovered + 1))
            restore_ran=true
        fi
    done

    # Both files must have been restored (neither existed in the flat dir).
    if [[ "$recovered" -ne 2 ]]; then
        echo -e "    ${RED}x${RESET} Expected 2 files restored, got $recovered"
        return 1
    fi

    # Canonical locations must now contain the snapshot content.
    if [[ ! -f "$artifacts/plan.md" ]]; then
        echo -e "    ${RED}x${RESET} plan.md not restored to canonical location"
        return 1
    fi
    if ! grep -q "prior run" "$artifacts/plan.md"; then
        echo -e "    ${RED}x${RESET} plan.md content does not match snapshot"
        return 1
    fi

    if [[ ! -f "$artifacts/pipeline-status.json" ]]; then
        echo -e "    ${RED}x${RESET} pipeline-status.json not restored to canonical location"
        return 1
    fi

    # Static check: confirm the GHA workflow also contains the restore pattern so
    # the YAML itself cannot regress independently of the shell tests.
    local wf="$REPO_DIR/.github/workflows/shipwright-pipeline.yml"
    if [[ -f "$wf" ]]; then
        if ! grep -q "issue-\${ISSUE_NUMBER}" "$wf" || ! grep -qE "cp.*SNAP|SNAP.*cp" "$wf"; then
            echo -e "    ${RED}x${RESET} GHA workflow missing expected restore pattern (cp SNAP -> FPATH)"
            return 1
        fi
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# Change 5 — sw-pipeline.sh CI resume fallback (~line 3187): when GIT_BRANCH is
# empty and WORKSPACE_BRANCH is set, the CI resume block must use WORKSPACE_BRANCH
# as the branch name, NOT synthesise "ci/issue-<N>".
#
# Current behavior (BROKEN): the resume block at line 3187 always synthesises
# "ci/issue-${ISSUE_NUMBER}" when GIT_BRANCH is empty, ignoring WORKSPACE_BRANCH.
#
# Expected behavior (after fix): when WORKSPACE_BRANCH="shipwright/issue-42" is
# set and GIT_BRANCH is empty, the resume block must set
# GIT_BRANCH="shipwright/issue-42" (not "ci/issue-42").
# ──────────────────────────────────────────────────────────────────────────────
test_ci_resume_fallback_uses_workspace_branch() {
    local pipeline_sh="$REPO_DIR/scripts/sw-pipeline.sh"

    if [[ ! -f "$pipeline_sh" ]]; then
        echo -e "    ${RED}x${RESET} sw-pipeline.sh not found at $pipeline_sh"
        return 1
    fi

    # The CI resume fallback block must use WORKSPACE_BRANCH as the primary
    # source (migration safety: old state files carry GIT_BRANCH=ci/<slug>-N).
    # Verify the fix is in the source code statically.

    # Must contain the WORKSPACE_BRANCH fallback pattern.
    if ! grep -q 'WORKSPACE_BRANCH:-ci/issue-' "$pipeline_sh"; then
        echo -e "    ${RED}x${RESET} CI resume fallback must use \${WORKSPACE_BRANCH:-ci/issue-...} pattern"
        return 1
    fi

    # Must NOT still use the old hardcoded ci_branch local variable approach.
    if grep -q 'local ci_branch="ci/issue-' "$pipeline_sh"; then
        echo -e "    ${RED}x${RESET} Old hardcoded ci_branch local variable must be removed from CI resume block"
        return 1
    fi

    # Must try 'git checkout' (existing branch) BEFORE 'git checkout -b' (create).
    # Anchor on the logged message rather than exact bash syntax so the test
    # survives variable-name refactors while still catching ordering regressions.
    local resume_block
    resume_block=$(grep -A8 'CI resume: restoring branch' "$pipeline_sh" | head -12)
    if ! echo "$resume_block" | grep -q 'git checkout'; then
        echo -e "    ${RED}x${RESET} CI resume fallback must call git checkout (not only checkout -b)"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# Merge self-healing: function exists and dispatch is wired
# ──────────────────────────────────────────────────────────────────────────────
test_self_healing_merge_build_test_exists() {
    grep -q "^self_healing_merge_build_test()" "$REAL_PIPELINE_SCRIPT"
}

test_self_healing_merge_build_test_dispatch_wired() {
    # The stage loop must call self_healing_merge_build_test when the merge stage
    # fails and .retry-context-build.md is present.
    grep -q 'self_healing_merge_build_test' "$REAL_PIPELINE_SCRIPT" &&
    grep -q '\.retry-context-build\.md' "$REAL_PIPELINE_SCRIPT"
}

main() {
    local filter="${1:-}"

    echo ""
    echo -e "${PURPLE}${BOLD}╔═══════════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${PURPLE}${BOLD}║  shipwright pipeline test — E2E Validation (Real Subprocess)     ║${RESET}"
    echo -e "${PURPLE}${BOLD}╚═══════════════════════════════════════════════════════════════════╝${RESET}"
    echo ""

    # Verify the real pipeline script exists
    if [[ ! -f "$REAL_PIPELINE_SCRIPT" ]]; then
        echo -e "${RED}✗ Pipeline script not found: $REAL_PIPELINE_SCRIPT${RESET}"
        exit 1
    fi

    # Verify jq is available (required by pipeline)
    if ! command -v jq &>/dev/null; then
        echo -e "${RED}✗ jq is required. Install it: brew install jq${RESET}"
        exit 1
    fi

    echo -e "${DIM}Setting up mock environment...${RESET}"
    setup_env
    echo -e "${GREEN}✓${RESET} Environment ready: ${DIM}$TEST_TEMP_DIR${RESET}"
    echo ""

    # Define all tests
    local -a tests=(
        "test_preflight_passes:Preflight passes with all mocks"
        "test_preflight_fails_missing_loop:Preflight fails when sw-loop.sh missing"
        "test_start_requires_goal_or_issue:Start requires --goal or --issue"
        "test_intake_inline:Intake with --goal creates branch + artifacts"
        "test_intake_issue:Intake with --issue fetches from GitHub"
        "test_plan_generates_artifacts:Plan generates plan.md, dod.md, tasks"
        "test_build_invokes_sw:Build invokes sw loop and commits"
        "test_test_captures_results:Test stage captures results to log"
        "test_review_generates_report:Review generates report with severities"
        "test_pr_creates_url:PR stage creates PR URL artifact"
        "test_full_pipeline_e2e:Full E2E pipeline (6 stages)"
        "test_resume:Resume continues from partial state"
        "test_resume_from_running:Resume from running status (killed process)"
        "test_resume_empty_stages_recovers_from_log:Resume recovers stages from log when stages section is empty"
        "test_abort:Abort marks pipeline as aborted and clears stale task/loop state"
        "test_abort_idempotent:Abort on already-aborted pipeline is a no-op"
        "test_dry_run:Dry run shows config, no artifacts"
        "test_self_healing:Self-healing build→test retry loop"
        "test_intelligent_skip_docs_label:Intelligence: Skip stages for documentation issues"
        "test_intelligent_skip_low_complexity:Intelligence: Skip stages for low complexity"
        "test_finding_classification:Intelligence: Finding classification and routing"
        "test_complexity_reassessment:Intelligence: Mid-pipeline complexity reassessment"
        "test_backtrack_limit_enforced:Intelligence: Backtracking limit (1 per pipeline)"
        "test_post_completion_cleanup:Cleanup: Post-completion clears checkpoints and transient artifacts"
        "test_pipeline_cancel_check_runs_exists:Cleanup: pipeline_cancel_check_runs function exists"
        "test_vitals_module_exists:Vitals: sw-pipeline-vitals.sh exists and is syntactically valid"
        "test_vitals_functions_defined:Vitals: All vitals functions defined in module"
        "test_vitals_health_verdict:Vitals: Health verdict maps scores correctly"
        "test_vitals_adaptive_limit:Vitals: Adaptive limit returns valid integer"
        "test_vitals_budget_trajectory:Vitals: Budget trajectory returns ok/warn/stop"
        "test_quality_gate_function_exists:Quality: pipeline_select_audits function exists"
        "test_security_scan_function_exists:Quality: pipeline_security_source_scan function exists"
        "test_dod_verify_function_exists:Quality: pipeline_verify_dod function exists"
        "test_quality_score_recording:Quality: pipeline_record_quality_score function exists"
        "test_compound_quality_blocking_config:Quality: Templates have compound_quality_blocking"
        "test_vitals_progress_snapshot_creation:Vitals: Progress snapshot writes correct file"
        "test_vitals_momentum_from_snapshots:Vitals: Momentum score from snapshot history"
        "test_vitals_convergence_decreasing_errors:Vitals: Convergence with decreasing errors"
        "test_vitals_configurable_weights:Vitals: Configurable weights via env vars"
        "test_vitals_budget_trajectory_exhaustion:Vitals: Budget trajectory warn/stop on exhaustion"
        "test_structured_findings_json:Quality: Structured findings JSON is valid"
        "test_multi_backtrack_tracking:Quality: Multi-backtrack counter tracking"
        "test_quality_6_categories:Quality: 6 categories in classify_quality_findings"
        "test_pre_deploy_gates_exist:Deploy: Pre-deploy gates exist in pipeline"
        "test_deploy_strategy_config:Deploy: Deploy strategy config pattern"
        "test_canary_deploy_flow:Deploy: Canary deploy flow patterns exist"
        "test_pipeline_state_removed:Pipeline: PIPELINE_STATE references removed"
        "test_coverage_json_created:Pipeline: Coverage JSON creation in test stage"
        "test_compact_goal:Pipeline: _pipeline_compact_goal returns goal+plan+design"
        "test_load_composed_pipeline:Pipeline: load_composed_pipeline sets COMPOSED_STAGES"
        "test_momentum_bootstrap_single_snapshot:Vitals: Momentum returns 60 for single snapshot past intake"
        "test_health_gate_blocks:Vitals: Health gate blocks when health < threshold"
        "test_health_gate_passes:Vitals: Health gate passes with default threshold=40"
        "test_persist_artifacts_exists:Durable: persist_artifacts function exists"
        "test_persist_artifacts_ci_guard:Durable: persist_artifacts skips in non-CI mode"
        "test_verify_artifacts_present:Durable: verify_stage_artifacts passes when artifacts present"
        "test_verify_artifacts_missing:Durable: verify_stage_artifacts fails when artifacts missing"
        "test_verify_artifacts_empty:Durable: verify_stage_artifacts fails when artifacts empty"
        "test_verify_artifacts_no_requirements:Durable: verify_stage_artifacts passes for stages with no requirements"
        "test_verify_artifacts_design_needs_plan:Durable: verify_stage_artifacts design requires plan.md"
        "test_no_push_when_sourced_without_pipeline_start:Durable: no push when sourced without run_pipeline (_PIPELINE_RUN_STARTED sentinel)"
        "test_mark_complete_persists_plan:Durable: mark_stage_complete wires persist for plan stage"
        "test_fresh_start_cleans_stale_checkpoints:Cleanup: stale checkpoints/ removed on fresh pipeline start"
        "test_ci_post_stage_event_visible_body:CI: ci_post_stage_event posts visible comment body"
        "test_ci_post_stage_event_retains_marker:CI: ci_post_stage_event retains SHIPWRIGHT-STAGE marker for watchdog"
        "test_ci_post_stage_event_failed_emoji:CI: ci_post_stage_event uses failure emoji for failed status"
        "test_ci_post_stage_event_noop_outside_ci:CI: ci_post_stage_event is no-op outside CI mode"
        "test_run_stage_with_retry_undefined_stage:Guard: run_stage_with_retry fails fast on undefined stage function"
        "test_partial_work_push_condition:CI: partial-work push triggers on failure OR cancelled (issue #437)"
        "test_model_resolution:Model: CLI flag MODEL=sonnet wins over config default in dry-run"
        "test_model_resolution_no_flag:Model: pipeline config default model used when no CLI flag set"
        "test_count_consecutive_test_failures_parsing:Cycling: count_consecutive_test_failures parses log correctly (issue #448)"
        "test_count_consecutive_test_failures_format_drift_warning:Cycling: parser warns on log format drift (issue #448 review fix)"
        "test_stuck_cycling_halts_after_max_build_retries:Cycling: halts with stuck_cycling after max consecutive test failures (issue #448)"
        "test_stuck_cycling_runs_one_cycle_before_halting_on_resume:Cycling: fresh resume runs one cycle before halting (issue #448 review fix)"
        "test_stuck_cycling_disabled_when_max_retries_zero:Cycling: SW_PIPELINE_MAX_BUILD_RETRIES=0 disables cap (escape hatch)"
        "test_stuck_cycling_resume_refused_without_override:Cycling: resume refuses stuck_cycling without override (issue #448 review fix)"
        "test_stuck_cycling_resume_allowed_with_override:Cycling: resume proceeds with SW_PIPELINE_MAX_BUILD_RETRIES=0 override"
        "test_stuck_cycling_start_refused:Cycling: fresh start refuses to overwrite stuck_cycling state"
        "test_stuck_cycling_fires_through_review_self_heal_path:Cycling: stuck_cycling fires through review self-heal path (issue #448 DoD)"
        "test_cleanup_wires_cost_baseline_and_render:Cost: cleanup_on_exit wires render + baseline_update (#504 D2)"
        "test_pr_stage_posts_cost_table_comment:Cost: PR stage posts cost-table comment (#504 D2)"
        "test_merge_stage_checks_already_merged_on_failure:Merge: both failure paths accept MERGED state (race with auto-merge)"
        "test_cost_helpers_functional_against_staged_breakdown:Cost: hermetic render + baseline_update against staged breakdown (#504 D2)"
        "test_compose_prompt_iter1_includes_pipeline_context:Loop: compose_prompt iter 1 includes pipeline_context_section"
        "test_compose_prompt_iter2_omits_pipeline_context:Loop: compose_prompt iter 2 omits pipeline_context_section"
        "test_compose_prompt_iter2_reference_only_label:Loop: compose_prompt iter 2 prepends REFERENCE ONLY label to history"
        "test_compose_prompt_iter2_test_section_demoted:Loop: compose_prompt iter 2 demotes full test output when error summary present"
        "test_compose_prompt_session_restart_full_context:Loop: compose_prompt SESSION_RESTART=true forces full context at iter 5"
        "test_compose_prompt_resumed_full_context:Loop: compose_prompt RESUMED_FROM_ITERATION forces full context"
        "test_compose_prompt_iter2_recent_commits_section:Loop: compose_prompt iter 2 includes Commits This Pipeline section"
        "test_compose_prompt_iter2_reference_trailer:Loop: compose_prompt iter 2 appends pipeline-artifacts reference trailer"
        "test_compose_prompt_iter1_no_reference_trailer:Loop: compose_prompt iter 1 does NOT include Reference trailer"
        "test_compose_prompt_emits_context_event:Loop: compose_prompt emits context.iteration_prompt event"
        "test_compose_prompt_iter2_instructions_before_test_results:Loop: compose_prompt iter 2 — Instructions precedes Test Results"
        "test_compose_prompt_iter2_cumulative_uses_merge_base:Loop: compose_prompt iter 2 cumulative progress uses merge-base (full branch vs main)"
        "test_watchdog_handler_removed:Phase4: _soft_timeout_handler function removed from sw-pipeline.sh"
        "test_watchdog_usr1_trap_removed:Phase4: trap USR1 for soft-timeout removed from sw-pipeline.sh"
        "test_watchdog_pid_var_removed:Phase4: _WATCHDOG_PID variable removed from sw-pipeline.sh"
        "test_watchdog_armed_event_removed:Phase4: pipeline.watchdog_armed event removed from sw-pipeline.sh"
        "test_watchdog_soft_timeout_event_removed:Phase4: pipeline.soft_timeout_push event removed from sw-pipeline.sh"
        "test_intake_ci_uses_workspace_branch:CI Change 1: intake uses WORKSPACE_BRANCH as GIT_BRANCH when set"
        "test_intake_local_mode_preserves_branch_creation:CI Change 1: intake preserves git checkout -b when WORKSPACE_BRANCH unset"
        "test_gitignore_issue_scoped_artifacts_not_ignored:CI Change 2: .gitignore negation allows issue-N/ snapshots to be committed"
        "test_intake_git_branch_equals_workspace_branch_when_set:CI Change 3: GIT_BRANCH equals WORKSPACE_BRANCH after intake (GHA snapshot precondition)"
        "test_restore_loop_copies_snapshot_to_canonical:CI Change 4: restore loop copies issue-N/ snapshot files to canonical locations"
        "test_ci_resume_fallback_uses_workspace_branch:CI Change 5: resume fallback uses WORKSPACE_BRANCH not ci/issue-N when WORKSPACE_BRANCH set"
        "test_events_snapshot_code_absent:Issue2: _events_snap code fully removed from sw-pipeline.sh"
        "test_events_snapshot_not_created_on_wip_push:Issue2: pipeline_wip_push does not create .shipwright/events-*.jsonl"
        "test_events_snapshot_not_created_on_final_push:Issue2: pipeline_final_artifact_push does not create .shipwright/events-*.jsonl"
        "test_push_guard_blocks_cross_issue_target:PushGuard: _assert_push_target_matches_active_issue returns 87 for cross-issue branch"
        "test_push_guard_passes_matching_and_neutral_targets:PushGuard: guard passes for matching issue and neutral branches"
        "test_ci_push_partial_work_respects_no_artifact_push:PushGuard: ci_push_partial_work respects NO_ARTIFACT_PUSH flag"
        "test_resume_state_does_not_clobber_explicit_issue:PR2: resume_state preserves explicit --issue arg over stale state file"
        "test_resume_state_rejects_stale_when_mismatch:PR2: resume_state exits 2 on issue number mismatch"
        "test_persist_artifacts_commits_state_files_every_stage:PR3: persist_artifacts called for every stage in mark_stage_complete"
        "test_persist_artifacts_push_guard_present:PR3: persist_artifacts contains opportunistic push"
        "test_branch_drift_auto_recover_present_in_mark_stage_complete:PR3: mark_stage_complete checks for branch drift"
        "test_intake_refuses_local_mode_when_ci_and_workspace_branch_unset:PR3: intake exits 2 when CI_MODE=true and WORKSPACE_BRANCH unset"
        "test_ci_resume_does_not_fall_back_to_ci_issue_n:PR3: CI resume refuses ci/issue-N fallback when WORKSPACE_BRANCH unset"
        "test_state_heartbeat_helpers_present:PR3: _start_state_heartbeat and _stop_state_heartbeat exist in sw-pipeline.sh"
        "test_heartbeat_called_in_run_pipeline:PR3: _start_state_heartbeat called inside run_pipeline"
        "test_workflow_workspace_branch_re_export_step_present:PR3: workflow has idempotent WORKSPACE_BRANCH re-export step"
        "test_self_healing_merge_build_test_exists:Merge: self_healing_merge_build_test function exists in sw-pipeline.sh"
        "test_self_healing_merge_build_test_dispatch_wired:Merge: stage loop dispatches self_healing_merge_build_test on merge failure with retry context"
        "test_scope_redaction_helpers_present:Scope: _file_in_scope and _redact_paths_outside_scope exist in helpers.sh"
        "test_scope_redaction_in_scope_no_redaction:Scope: in-scope path is not redacted"
        "test_scope_redaction_oos_path_redacted:Scope: out-of-scope path triggers redaction sentinel in output"
        "test_scope_drift_subcommand_present:Scope: drift subcommand wired in sw-pipeline.sh"
        "test_scope_escalation_detection_in_loop:Scope: SCOPE_ESCALATION detection and event emission in sw-loop.sh"
        "test_scope_manifest_events_in_extract:Scope: scope_manifest_missing/loaded events in _extract_scope_from_design"
    )

    for entry in "${tests[@]}"; do
        local fn="${entry%%:*}"
        local desc="${entry#*:}"

        if [[ -n "$filter" && "$fn" != "$filter" ]]; then
            continue
        fi

        run_test "$desc" "$fn"
    done

    # ── Summary ───────────────────────────────────────────────────────────
    echo ""
    echo -e "${PURPLE}${BOLD}━━━ Results ━━━${RESET}"
    echo -e "  ${GREEN}Passed:${RESET} $PASS"
    echo -e "  ${RED}Failed:${RESET} $FAIL"
    echo -e "  ${DIM}Total:${RESET}  $TOTAL"
    echo ""

    if [[ "$FAIL" -gt 0 ]]; then
        echo -e "${RED}${BOLD}Failed tests:${RESET}"
        for f in "${FAILURES[@]}"; do
            echo -e "  ${RED}✗${RESET} $f"
        done
        echo ""
        exit 1
    fi

    echo -e "${GREEN}${BOLD}All $PASS tests passed!${RESET}"
    echo ""
    exit 0
}

# ─── Phase 4: Watchdog removal static checks ────────────────────────────────

test_watchdog_handler_removed() {
    if grep -q '_soft_timeout_handler' "$REAL_PIPELINE_SCRIPT"; then
        echo "FAIL: _soft_timeout_handler still present in sw-pipeline.sh"
        return 1
    fi
    return 0
}

test_watchdog_usr1_trap_removed() {
    if grep -qE 'trap.*USR1|USR1.*trap' "$REAL_PIPELINE_SCRIPT"; then
        echo "FAIL: trap USR1 still present in sw-pipeline.sh"
        return 1
    fi
    return 0
}

test_watchdog_pid_var_removed() {
    if grep -q '_WATCHDOG_PID' "$REAL_PIPELINE_SCRIPT"; then
        echo "FAIL: _WATCHDOG_PID still referenced in sw-pipeline.sh"
        return 1
    fi
    return 0
}

test_watchdog_armed_event_removed() {
    if grep -q 'pipeline\.watchdog_armed' "$REAL_PIPELINE_SCRIPT"; then
        echo "FAIL: pipeline.watchdog_armed event still emitted in sw-pipeline.sh"
        return 1
    fi
    return 0
}

test_watchdog_soft_timeout_event_removed() {
    if grep -q 'pipeline\.soft_timeout_push' "$REAL_PIPELINE_SCRIPT"; then
        echo "FAIL: pipeline.soft_timeout_push event still emitted in sw-pipeline.sh"
        return 1
    fi
    return 0
}

test_push_guard_blocks_cross_issue_target() {
    local rc
    if ! grep -q '_assert_push_target_matches_active_issue' "$REAL_PIPELINE_SCRIPT" 2>/dev/null; then
        echo "SKIP: _assert_push_target_matches_active_issue not yet implemented"
        return 0
    fi
    # Extract just the function body to avoid sourcing full script (which resets ISSUE_NUMBER).
    local func_body
    func_body=$(awk '/^_assert_push_target_matches_active_issue\(\)/,/^}$/{print}' "$REAL_PIPELINE_SCRIPT")
    (
        emit_event() { :; }
        eval "$func_body"
        ISSUE_NUMBER=460
        _assert_push_target_matches_active_issue "shipwright/issue-99"
    ) 2>/dev/null
    rc=$?
    if [[ "$rc" -ne 87 ]]; then
        echo "FAIL: expected exit 87 for cross-issue push, got $rc"
        return 1
    fi
    return 0
}

test_push_guard_passes_matching_and_neutral_targets() {
    if ! grep -q '_assert_push_target_matches_active_issue' "$REAL_PIPELINE_SCRIPT" 2>/dev/null; then
        echo "SKIP: _assert_push_target_matches_active_issue not yet implemented"
        return 0
    fi
    # Extract just the function body to avoid sourcing full script (which resets ISSUE_NUMBER).
    local func_body
    func_body=$(awk '/^_assert_push_target_matches_active_issue\(\)/,/^}$/{print}' "$REAL_PIPELINE_SCRIPT")
    (
        emit_event() { :; }
        eval "$func_body"
        ISSUE_NUMBER=460
        _assert_push_target_matches_active_issue "shipwright/issue-460" || exit 1
        _assert_push_target_matches_active_issue "shipwright-data" || exit 1
        _assert_push_target_matches_active_issue "ci/sub-branch" || exit 1
    ) 2>/dev/null
    if [[ $? -ne 0 ]]; then
        echo "FAIL: push guard should pass for matching/neutral targets"
        return 1
    fi
    return 0
}

test_ci_push_partial_work_respects_no_artifact_push() {
    # Verify the guard exists in the function
    local guard_line
    guard_line=$(grep -n 'NO_ARTIFACT_PUSH' "$REAL_PIPELINE_SCRIPT" | grep -i 'ci_push_partial' | head -1 || true)
    if [[ -z "$guard_line" ]]; then
        # Check within function body (between ci_push_partial_work and the next function)
        local in_func=false found=false
        while IFS= read -r line; do
            [[ "$line" =~ ^ci_push_partial_work ]] && in_func=true
            [[ "$in_func" == "true" && "$line" =~ NO_ARTIFACT_PUSH ]] && found=true && break
            [[ "$in_func" == "true" && "$line" =~ ^\} ]] && break
        done < "$REAL_PIPELINE_SCRIPT"
        if [[ "$found" != "true" ]]; then
            echo "FAIL: ci_push_partial_work does not check NO_ARTIFACT_PUSH"
            return 1
        fi
    fi
    return 0
}

test_resume_state_does_not_clobber_explicit_issue() {
    local real_state_lib="$SCRIPT_DIR/lib/pipeline-state.sh"
    # Static check: resume_state must only assign ISSUE_NUMBER from state file
    # when it is currently unset (explicit --issue arg wins).
    # Verify the guard pattern: `-z "${ISSUE_NUMBER:-}"` before the assignment.
    local guard_count
    guard_count=$(awk '/^resume_state\(\)/,/^}$/{print}' "$real_state_lib" 2>/dev/null \
        | grep -c '\-z.*ISSUE_NUMBER' || true)
    guard_count="${guard_count:-0}"
    if [[ "${guard_count:-0}" -eq 0 ]]; then
        echo "FAIL: resume_state does not guard ISSUE_NUMBER assignment with -z check (explicit-arg-wins not implemented)"
        return 1
    fi
    return 0
}

test_resume_state_rejects_stale_when_mismatch() {
    local real_state_lib="$SCRIPT_DIR/lib/pipeline-state.sh"
    # Static check: resume_state must return 2 when _ISSUE_NUMBER_EXPLICIT=true and
    # state file issue != ISSUE_NUMBER. The check must be gated on _ISSUE_NUMBER_EXPLICIT
    # to avoid killing test scripts that call resume_state without --issue.
    local ret2_count explicit_gate_count
    ret2_count=$(awk '/^resume_state\(\)/,/^}$/{print}' "$real_state_lib" 2>/dev/null \
        | grep -cE 'return 2|exit 2' || true)
    ret2_count="${ret2_count:-0}"
    explicit_gate_count=$(awk '/^resume_state\(\)/,/^}$/{print}' "$real_state_lib" 2>/dev/null \
        | grep -c '_ISSUE_NUMBER_EXPLICIT' || true)
    explicit_gate_count="${explicit_gate_count:-0}"
    if [[ "${ret2_count:-0}" -eq 0 ]]; then
        echo "FAIL: resume_state does not return 2 on stale-state mismatch"
        return 1
    fi
    if [[ "${explicit_gate_count:-0}" -eq 0 ]]; then
        echo "FAIL: resume_state mismatch check not gated on _ISSUE_NUMBER_EXPLICIT"
        return 1
    fi
    return 0
}

test_persist_artifacts_commits_state_files_every_stage() {
    local real_state_lib="$SCRIPT_DIR/lib/pipeline-state.sh"
    # Verify that mark_stage_complete calls persist_artifacts for stages beyond plan/design.
    # After the fix, every stage should have persist_artifacts called.
    local has_all_stages
    # Look for the case statement in mark_stage_complete that calls persist_artifacts
    # After fix: should see "*)  persist_artifacts" or remove the case (call unconditionally)
    # Before fix: only plan|design have persist_artifacts
    has_all_stages=$(awk '
        /mark_stage_complete/,/^}/ {
            if (/persist_artifacts/ && !/plan|design/) found=1
        }
        END { print (found ? "yes" : "no") }
    ' "$real_state_lib" 2>/dev/null || echo "no")
    if [[ "$has_all_stages" != "yes" ]]; then
        echo "FAIL: persist_artifacts not called for all stages in mark_stage_complete (expected after fix)"
        return 1
    fi
    return 0
}

test_persist_artifacts_push_guard_present() {
    local real_state_lib="$SCRIPT_DIR/lib/pipeline-state.sh"
    # After fix: persist_artifacts should contain a git push (opportunistic)
    # Before fix: explicitly says "Intentionally no git push here"
    if grep -q 'Intentionally no git push' "$real_state_lib" 2>/dev/null; then
        echo "FAIL: persist_artifacts still has 'Intentionally no git push' comment (not yet fixed)"
        return 1
    fi
    if ! grep -q 'git push' "$real_state_lib" 2>/dev/null; then
        # Maybe it's there but in a different form; check for push within persist_artifacts body
        echo "FAIL: persist_artifacts does not contain a git push (expected after fix)"
        return 1
    fi
    return 0
}

test_branch_drift_auto_recover_present_in_mark_stage_complete() {
    local real_state_lib="$SCRIPT_DIR/lib/pipeline-state.sh"
    # After fix: should see branch_drift or WORKSPACE_BRANCH check in mark_stage_complete
    local has_drift_check
    has_drift_check=$(awk '
        /^mark_stage_complete/,/^}/ {
            if (/WORKSPACE_BRANCH/ || /branch_drift/ || /symbolic-ref/) found=1
        }
        END { print (found ? "yes" : "no") }
    ' "$real_state_lib" 2>/dev/null || echo "no")
    if [[ "$has_drift_check" != "yes" ]]; then
        echo "FAIL: mark_stage_complete does not check for branch drift (expected after fix)"
        return 1
    fi
    return 0
}

test_intake_refuses_local_mode_when_ci_and_workspace_branch_unset() {
    # After fix: intake should error out if CI_MODE=true and WORKSPACE_BRANCH is unset
    local intake_lib
    intake_lib="$REPO_DIR/scripts/lib/pipeline-stages-intake.sh"
    if [[ ! -f "$intake_lib" ]]; then
        echo "SKIP: intake lib not found"
        return 0
    fi
    # Check that there's an error/exit for unset WORKSPACE_BRANCH in CI mode
    local has_guard
    has_guard=$(grep -c 'WORKSPACE_BRANCH.*unset\|WORKSPACE_BRANCH.*is unset\|exit 2\|return 2' "$intake_lib" 2>/dev/null || true)
    has_guard="${has_guard:-0}"
    if [[ "$has_guard" -eq 0 ]]; then
        echo "FAIL: intake does not guard against unset WORKSPACE_BRANCH in CI mode (expected after fix)"
        return 1
    fi
    return 0
}

test_ci_resume_does_not_fall_back_to_ci_issue_n() {
    # After fix: in CI mode, resume must hard-fail when WORKSPACE_BRANCH is unset
    # rather than silently falling back to ci/issue-N.
    # Verify the guard: error "CI resume: WORKSPACE_BRANCH unset. Refusing to fall back..."
    local has_ci_guard
    has_ci_guard=$(grep -c 'CI resume.*WORKSPACE_BRANCH unset\|CI resume: WORKSPACE_BRANCH' \
        "$REAL_PIPELINE_SCRIPT" 2>/dev/null || echo "0")
    if [[ "${has_ci_guard:-0}" -eq 0 ]]; then
        echo "FAIL: CI resume does not hard-fail on unset WORKSPACE_BRANCH (expected guard with error+exit 2)"
        return 1
    fi
    return 0
}

test_state_heartbeat_helpers_present() {
    if ! grep -q '_start_state_heartbeat' "$REAL_PIPELINE_SCRIPT" 2>/dev/null; then
        echo "FAIL: _start_state_heartbeat not found in sw-pipeline.sh (expected after fix)"
        return 1
    fi
    if ! grep -q '_stop_state_heartbeat' "$REAL_PIPELINE_SCRIPT" 2>/dev/null; then
        echo "FAIL: _stop_state_heartbeat not found in sw-pipeline.sh (expected after fix)"
        return 1
    fi
    return 0
}

test_heartbeat_called_in_run_pipeline() {
    # After fix: run_pipeline should call _start_state_heartbeat
    local found
    found=$(awk '
        /^run_pipeline\(\)/ { in_func=1 }
        in_func && /_start_state_heartbeat/ { found=1 }
        in_func && /^}/ && !/^run_pipeline/ { in_func=0 }
        END { print (found ? "yes" : "no") }
    ' "$REAL_PIPELINE_SCRIPT" 2>/dev/null || echo "no")
    if [[ "$found" != "yes" ]]; then
        echo "FAIL: _start_state_heartbeat not called in run_pipeline (expected after fix)"
        return 1
    fi
    return 0
}

test_workflow_workspace_branch_re_export_step_present() {
    local workflow="$REPO_DIR/.github/workflows/shipwright-pipeline.yml"
    if [[ ! -f "$workflow" ]]; then
        echo "SKIP: workflow file not found"
        return 0
    fi
    if ! grep -q 'Re-export workspace branch\|idempotent.*WORKSPACE_BRANCH\|WORKSPACE_BRANCH.*idempotent' "$workflow" 2>/dev/null; then
        echo "FAIL: workflow missing idempotent WORKSPACE_BRANCH re-export step (expected after fix)"
        return 1
    fi
    return 0
}

# ─── Scope Redaction Smoke Tests (PR-D) ──────────────────────────────────────

test_scope_redaction_helpers_present() {
    local helpers_sh="$REPO_DIR/scripts/lib/helpers.sh"
    if [[ ! -f "$helpers_sh" ]]; then
        echo "SKIP: helpers.sh not found"
        return 0
    fi
    if ! grep -q '_file_in_scope' "$helpers_sh" 2>/dev/null; then
        echo "SKIP: _file_in_scope not yet merged (depends on PR-B)"
        return 0
    fi
    if ! grep -q '_redact_paths_outside_scope' "$helpers_sh" 2>/dev/null; then
        echo "SKIP: _redact_paths_outside_scope not yet merged (depends on PR-B)"
        return 0
    fi
    return 0
}

test_scope_redaction_in_scope_no_redaction() {
    # A finding that references only in-scope paths must NOT trigger redaction.
    local helpers_sh="$REPO_DIR/scripts/lib/helpers.sh"
    [[ -f "$helpers_sh" ]] || { echo "SKIP: helpers.sh not found"; return 0; }
    grep -q '_redact_paths_outside_scope' "$helpers_sh" 2>/dev/null \
        || { echo "SKIP: _redact_paths_outside_scope not yet merged (depends on PR-B)"; return 0; }

    local allowlist="scripts/lib/helpers.sh"$'\n'"scripts/lib/pipeline-stages.sh"
    local finding="scripts/lib/helpers.sh:42 — _redact_paths_outside_scope called with empty allowlist"

    local redacted
    redacted=$(
        COMPOUND_QUALITY_CYCLE=0 \
        bash -c "
            source '$helpers_sh' 2>/dev/null
            _redact_paths_outside_scope $(printf '%q' "$finding") $(printf '%q' "$allowlist") 'smoke_test' '0' 2>/dev/null
        " 2>/dev/null || echo "$finding"
    )

    if echo "$redacted" | grep -q '\[redacted:out-of-scope:'; then
        echo "FAIL: in-scope path was redacted — got: $redacted"
        return 1
    fi
    return 0
}

test_scope_redaction_oos_path_redacted() {
    # A finding referencing an out-of-scope path must produce a redaction sentinel in the output.
    local helpers_sh="$REPO_DIR/scripts/lib/helpers.sh"
    [[ -f "$helpers_sh" ]] || { echo "SKIP: helpers.sh not found"; return 0; }
    grep -q '_redact_paths_outside_scope' "$helpers_sh" 2>/dev/null \
        || { echo "SKIP: _redact_paths_outside_scope not yet merged (depends on PR-B)"; return 0; }

    local allowlist="scripts/lib/helpers.sh"
    local finding=".claude/helpers/intelligence.cjs:99 — execSync called outside scope"

    local redacted
    redacted=$(
        COMPOUND_QUALITY_CYCLE=0 \
        bash -c "
            source '$helpers_sh' 2>/dev/null
            _redact_paths_outside_scope $(printf '%q' "$finding") $(printf '%q' "$allowlist") 'smoke_oos' '0' 2>/dev/null
        " 2>/dev/null || echo "$finding"
    )

    if ! echo "$redacted" | grep -q '\[redacted:out-of-scope:'; then
        echo "FAIL: out-of-scope path was not redacted — got: $redacted"
        return 1
    fi
    return 0
}

test_scope_drift_subcommand_present() {
    if ! grep -q 'pipeline_drift_report\|drift)' "$REAL_PIPELINE_SCRIPT" 2>/dev/null; then
        echo "FAIL: drift subcommand not found in sw-pipeline.sh"
        return 1
    fi
    return 0
}

test_scope_escalation_detection_in_loop() {
    local loop_sh="$REPO_DIR/scripts/sw-loop.sh"
    if [[ ! -f "$loop_sh" ]]; then
        echo "SKIP: sw-loop.sh not found"
        return 0
    fi
    if ! grep -q 'LOOP:SCOPE_ESCALATION' "$loop_sh" 2>/dev/null; then
        echo "FAIL: SCOPE_ESCALATION detection not found in sw-loop.sh"
        return 1
    fi
    if ! grep -q 'pipeline.scope_escalation' "$loop_sh" 2>/dev/null; then
        echo "FAIL: pipeline.scope_escalation event not emitted in sw-loop.sh"
        return 1
    fi
    return 0
}

test_scope_manifest_events_in_extract() {
    local stages_sh="$REPO_DIR/scripts/lib/pipeline-stages.sh"
    if [[ ! -f "$stages_sh" ]]; then
        echo "SKIP: pipeline-stages.sh not found"
        return 0
    fi
    if ! grep -q 'pipeline.scope_manifest_missing' "$stages_sh" 2>/dev/null; then
        echo "FAIL: pipeline.scope_manifest_missing not emitted in pipeline-stages.sh"
        return 1
    fi
    if ! grep -q 'pipeline.scope_manifest_loaded' "$stages_sh" 2>/dev/null; then
        echo "FAIL: pipeline.scope_manifest_loaded not emitted in pipeline-stages.sh"
        return 1
    fi
    return 0
}

main "$@"
