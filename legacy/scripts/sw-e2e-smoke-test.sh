#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright e2e smoke test — Pipeline orchestration without API keys    ║
# ║  Mock binaries · No Claude/GitHub calls · Runs on every PR             ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

# Error trap for CI debugging — shows which line fails
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REAL_PIPELINE_SCRIPT="$SCRIPT_DIR/sw-pipeline.sh"
REAL_DAEMON_SCRIPT="$SCRIPT_DIR/sw-daemon.sh"

# ─── Colors (matches shipwright theme) ──────────────────────────────────────
# shellcheck disable=SC2034

# ─── Counters ─────────────────────────────────────────────────────────────────

# ═══════════════════════════════════════════════════════════════════════════════
# MOCK ENVIRONMENT SETUP
# Creates the complete temp structure that the real pipeline needs:
#   $TEST_TEMP_DIR/
#   ├── scripts/sw-pipeline.sh   (copy of real)
#   ├── scripts/sw-loop.sh       (mock)
#   ├── templates/pipelines/      (copies of real templates)
#   ├── bin/claude|gh|sw           (mocks on PATH)
#   ├── remote.git/                (bare repo for git push)
#   └── project/                   (mock git repo — tests cd here)
# ═══════════════════════════════════════════════════════════════════════════════

setup_env() {
    TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-e2e-smoke.XXXXXX")

    # ── Copy real pipeline script ─────────────────────────────────────────
    mkdir -p "$TEST_TEMP_DIR/scripts"
    cp "$REAL_PIPELINE_SCRIPT" "$TEST_TEMP_DIR/scripts/sw-pipeline.sh"

    # ── Copy lib directory if present ─────────────────────────────────────
    if [[ -d "$SCRIPT_DIR/lib" ]]; then
        mkdir -p "$TEST_TEMP_DIR/scripts/lib"
        cp "$SCRIPT_DIR/lib"/*.sh "$TEST_TEMP_DIR/scripts/lib/" 2>/dev/null || true
    fi

    # ── Copy skills directory (required by skill-registry.sh) ────────────
    [[ -d "$SCRIPT_DIR/skills" ]] && cp -r "$SCRIPT_DIR/skills" "$TEST_TEMP_DIR/scripts/skills"

    # ── Copy intelligence/composer scripts (pipeline sources them) ────────
    for dep in sw-intelligence.sh sw-pipeline-composer.sh sw-pipeline-vitals.sh sw-context.sh sw-github-graphql.sh sw-github-checks.sh sw-github-deploy.sh; do
        [[ -f "$SCRIPT_DIR/$dep" ]] && cp "$SCRIPT_DIR/$dep" "$TEST_TEMP_DIR/scripts/$dep"
    done

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

    # ── Mock project git repo ─────────────────────────────────────────────
    create_mock_project

    # ── Bare repo for git push ────────────────────────────────────────────
    git init --quiet --bare "$TEST_TEMP_DIR/remote.git" 2>/dev/null

    # ── Wire up git remotes ───────────────────────────────────────────────
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

if echo "$prompt" | grep -qiE "implementation plan|task checklist|create a.*plan"; then
    cat <<'PLAN'
# Implementation Plan

## Files to Modify
- src/feature.js — New auth module

### Task Checklist
- [ ] Create auth module in src/feature.js
- [ ] Add token validation logic
- [ ] Write unit tests for auth

### Definition of Done
- [ ] All tests pass
- [ ] Code reviewed
PLAN
elif echo "$prompt" | grep -qiE "review|reviewer|diff"; then
    cat <<'REVIEW'
# Code Review

## Findings

- **[Warning]** src/feature.js:3 — Missing input validation
- **[Bug]** src/feature.js:1 — Function name could be more descriptive

## Summary
2 issues found: 0 critical, 1 bug, 1 warning.
REVIEW
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
        exit 0
        ;;
    issue)
        case "$2" in
            view)
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
    cat > "$TEST_TEMP_DIR/bin/sw" <<MOCK_SW
#!/usr/bin/env bash
# Mock sw CLI — handles loop subcommand
case "\$1" in
    loop)
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
# Mock ruflo — all subcommands succeed instantly so e2e tests
# never call the real ruflo binary (which may hang without MCP).
exit 0
RUFLO_EOF
    chmod +x "$TEST_TEMP_DIR/bin/ruflo"
}

create_mock_project() {
    mkdir -p "$TEST_TEMP_DIR/project/src" "$TEST_TEMP_DIR/project/tests"

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
}

cleanup_env() {
    if [[ -n "$TEST_TEMP_DIR" && -d "$TEST_TEMP_DIR" ]]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
}
_test_cleanup_hook() { cleanup_env; }

# ═══════════════════════════════════════════════════════════════════════════════
# PIPELINE INVOCATION HELPER
# Every test calls this to invoke the REAL pipeline as a subprocess.
# ═══════════════════════════════════════════════════════════════════════════════

PIPELINE_OUTPUT=""
PIPELINE_EXIT=0

invoke_pipeline() {
    local subcommand="$1"
    shift
    PIPELINE_OUTPUT=""
    PIPELINE_EXIT=0

    # Isolate the admission-gate state from the host so dry-run tests are not
    # blocked by a real pipeline (e.g. the loop harness) holding a host-level
    # lock in ~/.shipwright/active-pipelines/. Each invocation gets a fresh
    # empty dir; the dedicated admission-gate tests below override this with
    # their own _invoke_pipeline_with_admission_env helper.
    # SHIPWRIGHT_MIN_FREE_GB=0 disables the memory threshold for general tests
    # so they are not affected by the host's actual available RAM.
    local _admit_dir="$TEST_TEMP_DIR/admit-default"
    mkdir -p "$_admit_dir"
    rm -f "$_admit_dir"/*.json 2>/dev/null || true

    PIPELINE_OUTPUT=$(
        cd "$TEST_TEMP_DIR/project"
        PATH="$TEST_TEMP_DIR/bin:$PATH" \
        SHIPWRIGHT_ACTIVE_PIPELINES_DIR="$_admit_dir" \
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
    echo -e "    ${DIM}Output (last 5 lines):${RESET}"
    echo "$PIPELINE_OUTPUT" | tail -5 | sed 's/^/      /'
    return 1
}

assert_exit_code_nonzero() {
    local label="${1:-exit code nonzero}"
    if [[ "$PIPELINE_EXIT" -ne 0 ]]; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Expected nonzero exit code, got 0 ($label)"
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

assert_dir_exists() {
    local dirpath="$1" label="${2:-dir exists}"
    local full_path="$TEST_TEMP_DIR/project/$dirpath"
    if [[ -d "$full_path" ]]; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Directory not found: $dirpath ($label)"
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

assert_no_feature_branches() {
    local label="${1:-no feature branches}"
    local branches
    branches=$(cd "$TEST_TEMP_DIR/project" && git branch --list | grep -v main || true)
    if [[ -z "$branches" ]]; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Feature branches found: $branches ($label)"
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
        FAILURES[${#FAILURES[@]}]="$test_name"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS — Each invokes the REAL pipeline. NO logic reimplementation.
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 1. Dry-run exits zero
# ──────────────────────────────────────────────────────────────────────────────
test_dryrun_exits_zero() {
    invoke_pipeline start --issue 42 --dry-run --skip-gates
    assert_exit_code 0 "dry-run should succeed"
}

# ──────────────────────────────────────────────────────────────────────────────
# 2. State file created after dry-run
# ──────────────────────────────────────────────────────────────────────────────
test_state_file_created() {
    invoke_pipeline start --issue 42 --dry-run --skip-gates
    assert_exit_code 0 "dry-run should succeed" &&
    assert_file_exists ".claude/pipeline-state.md" "state file created"
}

# ──────────────────────────────────────────────────────────────────────────────
# 3. State file has required fields
# ──────────────────────────────────────────────────────────────────────────────
test_state_has_required_fields() {
    invoke_pipeline start --issue 42 --dry-run --skip-gates
    assert_exit_code 0 "dry-run should succeed" &&
    assert_state_contains "status:" "state has status field" &&
    assert_state_contains "current_stage:" "state has current_stage field" &&
    assert_state_contains "pipeline:" "state has pipeline field"
}

# ──────────────────────────────────────────────────────────────────────────────
# 4. Fast template loads correctly
# ──────────────────────────────────────────────────────────────────────────────
test_fast_template_loads() {
    invoke_pipeline start --pipeline fast --dry-run --issue 42 --skip-gates
    assert_exit_code 0 "fast dry-run should succeed" &&
    assert_output_contains "fast" "output mentions fast template" &&
    # Verify the fast template disables plan
    local fast_tpl="$TEST_TEMP_DIR/templates/pipelines/fast.json"
    if [[ -f "$fast_tpl" ]]; then
        local plan_enabled
        plan_enabled=$(jq -r '.stages[] | select(.id == "plan") | .enabled' "$fast_tpl" 2>/dev/null || echo "unknown")
        if [[ "$plan_enabled" != "false" ]]; then
            echo -e "    ${RED}✗${RESET} Fast template plan should be disabled, got: $plan_enabled"
            return 1
        fi
        local max_iter
        max_iter=$(jq -r '.stages[] | select(.id == "build") | .config.max_iterations // 0' "$fast_tpl" 2>/dev/null || echo "0")
        if [[ "$max_iter" -ne 10 ]]; then
            echo -e "    ${RED}✗${RESET} Fast template max_iterations should be 10, got: $max_iter"
            return 1
        fi
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# 5. All templates parse as valid JSON
# ──────────────────────────────────────────────────────────────────────────────
test_all_templates_parse() {
    local template_dir="$TEST_TEMP_DIR/templates/pipelines"
    local all_ok=true
    local count=0
    for tpl in "$template_dir"/*.json; do
        [[ ! -f "$tpl" ]] && continue
        count=$((count + 1))
        if ! jq empty "$tpl" 2>/dev/null; then
            echo -e "    ${RED}✗${RESET} Invalid JSON: $(basename "$tpl")"
            all_ok=false
        fi
    done
    if [[ "$count" -eq 0 ]]; then
        echo -e "    ${RED}✗${RESET} No template files found"
        return 1
    fi
    $all_ok
}

# ──────────────────────────────────────────────────────────────────────────────
# 6. Stage ordering preserved in output
# ──────────────────────────────────────────────────────────────────────────────
test_stage_ordering_preserved() {
    invoke_pipeline start --issue 42 --dry-run --skip-gates
    assert_exit_code 0 "dry-run should succeed"

    # The pipeline output includes "Stages: intake plan build test ..." line
    # Verify intake appears before build in the output
    local stages_line
    stages_line=$(printf '%s\n' "$PIPELINE_OUTPUT" | grep -i "Stages:" | head -1 || true)
    if [[ -z "$stages_line" ]]; then
        echo -e "    ${RED}✗${RESET} No 'Stages:' line found in output"
        return 1
    fi

    # Extract stage names, verify intake comes before build
    local intake_pos build_pos
    intake_pos=$(echo "$stages_line" | grep -ob "intake" | head -1 | cut -d: -f1 || echo "")
    build_pos=$(echo "$stages_line" | grep -ob "build" | head -1 | cut -d: -f1 || echo "")

    if [[ -z "$intake_pos" || -z "$build_pos" ]]; then
        echo -e "    ${RED}✗${RESET} Could not find intake and build in stages line"
        echo -e "    ${DIM}$stages_line${RESET}"
        return 1
    fi

    if [[ "$intake_pos" -ge "$build_pos" ]]; then
        echo -e "    ${RED}✗${RESET} intake ($intake_pos) should appear before build ($build_pos)"
        return 1
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# 7. CI mode sets flags
# ──────────────────────────────────────────────────────────────────────────────
test_ci_mode_sets_flags() {
    invoke_pipeline start --ci --dry-run --issue 42
    assert_exit_code 0 "CI dry-run should succeed" &&
    # CI mode implies --skip-gates, so check for auto gates indication
    assert_output_contains "auto.*skip-gates|skip-gates|all auto" "CI mode sets skip-gates"
}

# ──────────────────────────────────────────────────────────────────────────────
# 8. Completed stages recognized
# ──────────────────────────────────────────────────────────────────────────────
test_completed_stages_parses() {
    invoke_pipeline start --completed-stages "intake,plan" --dry-run --issue 42 --skip-gates
    assert_exit_code 0 "completed-stages dry-run should succeed"
    # The pipeline should recognize completed stages — they get marked in state
    # or output references skipping them
}

# ──────────────────────────────────────────────────────────────────────────────
# 9. No branches after dry-run
# ──────────────────────────────────────────────────────────────────────────────
test_no_branches_after_dryrun() {
    invoke_pipeline start --issue 42 --dry-run --skip-gates
    assert_exit_code 0 "dry-run should succeed"

    # Dry run should not create feature branches — only main should exist
    # Note: initialize_state may create state file but dry run returns before
    # running stages. If the pipeline creates a branch during init, that's
    # acceptable. We check that no feature branches (feat/) are created.
    local branches
    branches=$(cd "$TEST_TEMP_DIR/project" && git branch --list | sed 's/^\* //' | tr -d ' ' || true)
    local has_feat=false
    while IFS= read -r b; do
        if echo "$b" | grep -qiE "^feat/"; then
            has_feat=true
        fi
    done <<< "$branches"
    if $has_feat; then
        echo -e "    ${RED}✗${RESET} Feature branches created during dry-run"
        echo -e "    ${DIM}$(cd "$TEST_TEMP_DIR/project" && git branch --list)${RESET}"
        return 1
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# 10. Artifact directory created
# ──────────────────────────────────────────────────────────────────────────────
test_artifact_dir_created() {
    invoke_pipeline start --issue 42 --dry-run --skip-gates
    assert_exit_code 0 "dry-run should succeed" &&
    assert_dir_exists ".claude" ".claude directory exists"
}

# ──────────────────────────────────────────────────────────────────────────────
# 11. Pipeline help text
# ──────────────────────────────────────────────────────────────────────────────
test_pipeline_help_text() {
    invoke_pipeline --help
    assert_exit_code 0 "help should succeed" &&
    assert_output_contains "USAGE|usage|pipeline" "help text present"
}

# ──────────────────────────────────────────────────────────────────────────────
# 12. Version consistency between pipeline and daemon
# ──────────────────────────────────────────────────────────────────────────────
test_version_consistency() {
    local pipeline_version daemon_version
    pipeline_version=$(grep '^VERSION=' "$REAL_PIPELINE_SCRIPT" | head -1 | sed 's/VERSION="//' | sed 's/"//')
    daemon_version=$(grep '^VERSION=' "$REAL_DAEMON_SCRIPT" | head -1 | sed 's/VERSION="//' | sed 's/"//')

    if [[ -z "$pipeline_version" ]]; then
        echo -e "    ${RED}✗${RESET} Could not read VERSION from pipeline script"
        return 1
    fi
    if [[ -z "$daemon_version" ]]; then
        echo -e "    ${RED}✗${RESET} Could not read VERSION from daemon script"
        return 1
    fi
    if [[ "$pipeline_version" != "$daemon_version" ]]; then
        echo -e "    ${RED}✗${RESET} Version mismatch: pipeline=$pipeline_version daemon=$daemon_version"
        return 1
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# 13. Goal flag accepted
# ──────────────────────────────────────────────────────────────────────────────
test_goal_flag_accepted() {
    invoke_pipeline start --goal "test goal for smoke" --dry-run --skip-gates
    assert_exit_code 0 "goal dry-run should succeed" &&
    assert_output_contains "test goal for smoke" "output contains the goal text"
}

# ──────────────────────────────────────────────────────────────────────────────
# 14. Invalid template errors
# ──────────────────────────────────────────────────────────────────────────────
test_invalid_template_errors() {
    invoke_pipeline start --pipeline nonexistent --issue 42 --dry-run --skip-gates
    assert_exit_code_nonzero "invalid template should fail" &&
    assert_output_contains "not found|error|invalid" "error message for invalid template"
}

# ──────────────────────────────────────────────────────────────────────────────
# 15. Issue number in state
# ──────────────────────────────────────────────────────────────────────────────
test_issue_number_in_state() {
    invoke_pipeline start --issue 42 --dry-run --skip-gates
    assert_exit_code 0 "dry-run should succeed" &&
    # Issue number should appear in output or state
    (
        if printf '%s\n' "$PIPELINE_OUTPUT" | grep -q "42" 2>/dev/null; then
            return 0
        fi
        if [[ -f "$TEST_TEMP_DIR/project/.claude/pipeline-state.md" ]] && grep -q "42" "$TEST_TEMP_DIR/project/.claude/pipeline-state.md"; then
            return 0
        fi
        echo -e "    ${RED}✗${RESET} Issue number 42 not found in output or state"
        return 1
    )
}

# 16. Headless mode auto-detection
# ──────────────────────────────────────────────────────────────────────────────
test_headless_auto_detection() {
    # Redirect stdin from /dev/null to simulate non-interactive (headless) mode.
    # Command substitution in invoke_pipeline only redirects stdout, not stdin,
    # so [[ ! -t 0 ]] would still see a terminal. We must explicitly disconnect stdin.
    PIPELINE_OUTPUT=""
    PIPELINE_EXIT=0
    local _admit_dir="$TEST_TEMP_DIR/admit-default"
    mkdir -p "$_admit_dir"
    rm -f "$_admit_dir"/*.json 2>/dev/null || true
    PIPELINE_OUTPUT=$(
        cd "$TEST_TEMP_DIR/project"
        PATH="$TEST_TEMP_DIR/bin:$PATH" \
        SHIPWRIGHT_ACTIVE_PIPELINES_DIR="$_admit_dir" \
        SHIPWRIGHT_MIN_FREE_GB=0 \
        NO_ARTIFACT_PUSH=true \
        bash "$TEST_TEMP_DIR/scripts/sw-pipeline.sh" start --issue 42 --dry-run < /dev/null 2>&1
    ) || PIPELINE_EXIT=$?
    assert_exit_code 0 "dry-run should succeed in headless mode" &&
    assert_output_contains "headless.*non-interactive|all auto" "Headless mode auto-detected"
}

# 17. --headless flag explicitly sets skip-gates
# ──────────────────────────────────────────────────────────────────────────────
test_headless_flag() {
    invoke_pipeline start --issue 42 --dry-run --headless
    assert_exit_code 0 "dry-run should succeed with --headless" &&
    assert_output_contains "headless|all auto" "Headless flag recognized"
}

# 18. Autonomous template has all auto gates
# ──────────────────────────────────────────────────────────────────────────────
test_autonomous_template_all_auto() {
    invoke_pipeline start --pipeline autonomous --issue 42 --dry-run --skip-gates
    assert_exit_code 0 "autonomous template loads" &&
    # Verify autonomous template has 0 approval gates (or all auto)
    assert_output_contains "all auto" "Autonomous template should show all auto gates"
}

# 19. Worktree cleanup preserves on failure (code path test)
# ──────────────────────────────────────────────────────────────────────────────
test_pipeline_exit_code_default() {
    # Verify PIPELINE_EXIT_CODE is initialized to 1 (assume failure)
    local has_default
    has_default=$(grep -c 'PIPELINE_EXIT_CODE=1' "$TEST_TEMP_DIR/scripts/sw-pipeline.sh" 2>/dev/null || echo "0")
    if [[ "$has_default" -gt 0 ]]; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} PIPELINE_EXIT_CODE=1 default not found"
    return 1
}

# ─── Admission gate E2E ─────────────────────────────────────────────────────
# These tests stand in for the "two real pipelines" manual procedure: they
# drive the real pipeline binary end-to-end with a planted lock representing
# a sibling pipeline still running, and assert refusal + diagnostics.

# Track sleep PIDs we plant so the harness can clean them up if a test aborts
ADMISSION_TEST_SLEEP_PIDS=()

_kill_admission_sleeps() {
    local pid
    for pid in "${ADMISSION_TEST_SLEEP_PIDS[@]:-}"; do
        [[ -z "$pid" ]] && continue
        kill "$pid" 2>/dev/null || true
    done
    ADMISSION_TEST_SLEEP_PIDS=()
}

# Override the harness cleanup hook to also reap any planted sleeps.
_test_cleanup_hook() { _kill_admission_sleeps; cleanup_env; }

_admission_setup_dir() {
    # Per-call active-pipelines dir, isolated from the host's real one.
    local dir="$TEST_TEMP_DIR/admission/$1"
    rm -rf "$dir" 2>/dev/null || true
    mkdir -p "$dir"
    echo "$dir"
}

_admission_plant_lock() {
    # Args: dir pid started_at
    local dir="$1" pid="$2" started_at="${3:-2026-04-26T00:00:00Z}"
    cat > "$dir/$pid.json" <<EOF
{"pid":$pid,"started_at":"$started_at","issue_or_goal":"sibling-pipeline","repo":"$TEST_TEMP_DIR/project","pipeline_template":"standard"}
EOF
}

_invoke_pipeline_with_admission_env() {
    # Like invoke_pipeline but lets us pass extra env (admission dir, thresholds)
    local active_dir="$1" min_gb="$2" max_active="$3"
    shift 3
    PIPELINE_OUTPUT=""
    PIPELINE_EXIT=0
    PIPELINE_OUTPUT=$(
        cd "$TEST_TEMP_DIR/project"
        PATH="$TEST_TEMP_DIR/bin:$PATH" \
        SHIPWRIGHT_ACTIVE_PIPELINES_DIR="$active_dir" \
        SHIPWRIGHT_MIN_FREE_GB="$min_gb" \
        SHIPWRIGHT_MAX_ACTIVE_PIPELINES="$max_active" \
        NO_ARTIFACT_PUSH=true \
        bash "$TEST_TEMP_DIR/scripts/sw-pipeline.sh" "$@" 2>&1
    ) || PIPELINE_EXIT=$?
}

# 20. Concurrent pipeline refused when a sibling lock is held by a live PID
# ──────────────────────────────────────────────────────────────────────────────
test_admission_refuses_concurrent_pipeline() {
    local active_dir
    active_dir=$(_admission_setup_dir concurrency)

    # Spawn a long-living process to stand in for "another pipeline running".
    # Using a real live PID exercises the live-PID branch of reap_stale_pipeline_locks.
    sleep 600 &
    local sibling_pid=$!
    ADMISSION_TEST_SLEEP_PIDS[${#ADMISSION_TEST_SLEEP_PIDS[@]}]="$sibling_pid"
    _admission_plant_lock "$active_dir" "$sibling_pid"

    _invoke_pipeline_with_admission_env "$active_dir" 0 1 \
        start --issue 99 --dry-run --skip-gates

    # Kill the sibling immediately so subsequent tests aren't blocked.
    kill "$sibling_pid" 2>/dev/null || true
    wait "$sibling_pid" 2>/dev/null || true

    if [[ "$PIPELINE_EXIT" -eq 0 ]]; then
        echo -e "    ${RED}✗${RESET} Pipeline should have refused but exited 0"
        echo "$PIPELINE_OUTPUT" | tail -8 | sed 's/^/      /'
        return 1
    fi
    if ! printf '%s\n' "$PIPELINE_OUTPUT" | grep -qE "Refusing to start.*active pipeline"; then
        echo -e "    ${RED}✗${RESET} Missing concurrency refusal diagnostic"
        echo "$PIPELINE_OUTPUT" | tail -8 | sed 's/^/      /'
        return 1
    fi
    if ! printf '%s\n' "$PIPELINE_OUTPUT" | grep -qE "pid=$sibling_pid"; then
        echo -e "    ${RED}✗${RESET} Diagnostic should name blocking pid=$sibling_pid"
        echo "$PIPELINE_OUTPUT" | tail -8 | sed 's/^/      /'
        return 1
    fi
    return 0
}

# 21. Stale lock from a dead PID is reaped — pipeline admitted on retry
# ──────────────────────────────────────────────────────────────────────────────
test_admission_reaps_stale_lock() {
    local active_dir
    active_dir=$(_admission_setup_dir stale)
    # 999999 is overwhelmingly likely to be a dead PID on any host.
    _admission_plant_lock "$active_dir" 999999

    _invoke_pipeline_with_admission_env "$active_dir" 0 1 \
        start --issue 99 --dry-run --skip-gates

    if [[ "$PIPELINE_EXIT" -ne 0 ]]; then
        echo -e "    ${RED}✗${RESET} Stale lock should have been reaped but pipeline failed (exit=$PIPELINE_EXIT)"
        echo "$PIPELINE_OUTPUT" | tail -8 | sed 's/^/      /'
        return 1
    fi
    if [[ -f "$active_dir/999999.json" ]]; then
        echo -e "    ${RED}✗${RESET} Stale lock file should have been removed"
        return 1
    fi
    return 0
}

# 22. Free-memory floor refusal: setting an unreachable threshold blocks start
# ──────────────────────────────────────────────────────────────────────────────
test_admission_refuses_low_memory() {
    local active_dir
    active_dir=$(_admission_setup_dir memory)
    # Cap so high no real host satisfies it — exercises the memory branch.
    _invoke_pipeline_with_admission_env "$active_dir" 999999 1 \
        start --issue 99 --dry-run --skip-gates

    if [[ "$PIPELINE_EXIT" -eq 0 ]]; then
        echo -e "    ${RED}✗${RESET} Pipeline should have refused on low memory but exited 0"
        return 1
    fi
    if ! printf '%s\n' "$PIPELINE_OUTPUT" | grep -qE "Refusing to start.*GB free memory"; then
        echo -e "    ${RED}✗${RESET} Missing memory refusal diagnostic"
        echo "$PIPELINE_OUTPUT" | tail -8 | sed 's/^/      /'
        return 1
    fi
    if ! printf '%s\n' "$PIPELINE_OUTPUT" | grep -qE "min=999999 GB"; then
        echo -e "    ${RED}✗${RESET} Diagnostic should name configured min threshold"
        return 1
    fi
    return 0
}

# 23. Lock is released on normal exit so the next pipeline is admitted
# ──────────────────────────────────────────────────────────────────────────────
test_admission_lock_released_after_run() {
    local active_dir
    active_dir=$(_admission_setup_dir release)
    _invoke_pipeline_with_admission_env "$active_dir" 0 1 \
        start --issue 99 --dry-run --skip-gates
    if [[ "$PIPELINE_EXIT" -ne 0 ]]; then
        echo -e "    ${RED}✗${RESET} First pipeline should succeed (exit=$PIPELINE_EXIT)"
        echo "$PIPELINE_OUTPUT" | tail -8 | sed 's/^/      /'
        return 1
    fi
    # After exit, the active-pipelines dir should be empty (lock released by trap).
    local remaining
    remaining=$(find "$active_dir" -maxdepth 1 -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$remaining" -ne 0 ]]; then
        echo -e "    ${RED}✗${RESET} Lock not released — $remaining file(s) remain in $active_dir"
        find "$active_dir" -maxdepth 1 -name '*.json' -type f -exec cat {} \; | sed 's/^/      /'
        return 1
    fi
    # Reset project state between invocations so the unrelated
    # "pipeline already in progress" guard (per-project state file) doesn't
    # interfere with what we're actually verifying — admission release.
    reset_test
    _invoke_pipeline_with_admission_env "$active_dir" 0 1 \
        start --issue 100 --dry-run --skip-gates
    if [[ "$PIPELINE_EXIT" -ne 0 ]]; then
        echo -e "    ${RED}✗${RESET} Follow-up pipeline should succeed after release (exit=$PIPELINE_EXIT)"
        echo "$PIPELINE_OUTPUT" | tail -8 | sed 's/^/      /'
        return 1
    fi
    return 0
}

# 24. Build-loop ceiling math respects target (worst case ≤50 invocations)
# ──────────────────────────────────────────────────────────────────────────────
# Validates that the build-loop iteration ceiling computes to ≤50:
#   worst_case = (MAX_ITERATIONS + MAX_EXTENSIONS * EXTENSION_SIZE) * (BUILD_TEST_RETRIES + 1)
# With current defaults: (20 + 1*3) * (1+1) = 46
test_build_loop_ceiling_respected() {
    local loop_sh="$REPO_DIR/scripts/sw-loop.sh"
    local defaults_json="$REPO_DIR/config/defaults.json"
    local max_iter ext_size max_ext build_retries

    # Match either bash parameter expansion form (`${VAR:-N}`) or a literal assignment (`=N`).
    # The previous regex `.*-([0-9]+).*` only worked by accident under greedy matching and
    # silently failed when the line was refactored to a literal — anchor explicitly instead.
    max_iter=$(grep -E '^MAX_ITERATIONS=' "$loop_sh" | head -1 \
        | sed -E -e 's/.*:-([0-9]+).*/\1/' -e 's/^MAX_ITERATIONS=([0-9]+).*/\1/')
    ext_size=$(grep -E '^EXTENSION_SIZE=' "$loop_sh" | head -1 | sed -E 's/^EXTENSION_SIZE=([0-9]+).*/\1/')
    max_ext=$(grep -E '^MAX_EXTENSIONS=' "$loop_sh" | head -1 | sed -E 's/^MAX_EXTENSIONS=([0-9]+).*/\1/')
    build_retries=$(jq -r '.pipeline.build_test_retries' "$defaults_json")

    # Validate extractions are pure integers (catches silent regex failure).
    local v
    for v in "$max_iter" "$ext_size" "$max_ext" "$build_retries"; do
        if ! [[ "$v" =~ ^[0-9]+$ ]]; then
            echo -e "    ${RED}✗${RESET} Could not extract ceiling knobs (max_iter='$max_iter' ext_size='$ext_size' max_ext='$max_ext' build_retries='$build_retries')"
            return 1
        fi
    done

    local per_cycle worst_case
    per_cycle=$(( max_iter + max_ext * ext_size ))
    worst_case=$(( per_cycle * (build_retries + 1) ))

    if [[ "$worst_case" -gt 50 ]]; then
        echo -e "    ${RED}✗${RESET} Worst case $worst_case > 50 (per_cycle=$per_cycle cycles=$((build_retries+1)))"
        return 1
    fi
    if [[ "$per_cycle" -gt 25 ]]; then
        echo -e "    ${RED}✗${RESET} Per-cycle ceiling $per_cycle > 25"
        return 1
    fi

    # Ceiling enforcement across all paths that set max_iterations.
    # Any literal `max_iterations=N` greater than MAX_ITERATIONS in sw-pm.sh / sw-triage.sh
    # would let a single pipeline silently exceed the ceiling.
    local script bad
    for script in sw-pm.sh sw-triage.sh sw-recruit.sh; do
        if [[ ! -f "$REPO_DIR/scripts/$script" ]]; then continue; fi
        # Match bash assignments only (avoid jq `.max_iterations: ...` etc.)
        bad=$(grep -oE 'max_iterations=[0-9]+' "$REPO_DIR/scripts/$script" \
            | awk -F= -v cap="$max_iter" '$2+0 > cap+0 {print}' || true)
        if [[ -n "$bad" ]]; then
            echo -e "    ${RED}✗${RESET} $script has max_iterations literal exceeding ceiling $max_iter: $bad"
            return 1
        fi
    done

    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

main() {
    local filter="${1:-}"

    echo ""
    echo -e "${PURPLE}${BOLD}╔═══════════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${PURPLE}${BOLD}║  shipwright e2e smoke test — Pipeline Orchestration (No API)     ║${RESET}"
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
    # Snapshot after setup_env so any Node processes it starts are included
    # in the baseline — measuring only processes added by the tests themselves.
    # Note: pgrep -c -f 'node ' counts all host Node processes; unrelated
    # processes starting/stopping during the run can skew the delta, so the
    # check is a best-effort heuristic rather than a precise assertion.
    local node_before
    node_before=$(pgrep -c -f 'node ' 2>/dev/null || echo "0")
    node_before=$(echo "$node_before" | tr -d '[:space:]')
    echo -e "${GREEN}✓${RESET} Environment ready: ${DIM}$TEST_TEMP_DIR${RESET}"
    echo ""

    # Define all tests
    local -a tests=(
        "test_dryrun_exits_zero:Dry-run exits zero"
        "test_state_file_created:State file created after dry-run"
        "test_state_has_required_fields:State file has required fields"
        "test_fast_template_loads:Fast template loads correctly"
        "test_all_templates_parse:All templates parse as valid JSON"
        "test_stage_ordering_preserved:Stage ordering preserved in output"
        "test_ci_mode_sets_flags:CI mode sets flags"
        "test_completed_stages_parses:Completed stages recognized"
        "test_no_branches_after_dryrun:No feature branches after dry-run"
        "test_artifact_dir_created:Artifact directory created"
        "test_pipeline_help_text:Pipeline help text"
        "test_version_consistency:Version consistency (pipeline vs daemon)"
        "test_goal_flag_accepted:Goal flag accepted"
        "test_invalid_template_errors:Invalid template errors correctly"
        "test_issue_number_in_state:Issue number in state"
        "test_headless_auto_detection:Headless auto-detection (non-interactive stdin)"
        "test_headless_flag:Headless flag sets skip-gates"
        "test_autonomous_template_all_auto:Autonomous template all-auto gates"
        "test_pipeline_exit_code_default:Pipeline exit code default is 1 (failure)"
        "test_admission_refuses_concurrent_pipeline:Admission gate refuses second concurrent pipeline"
        "test_admission_reaps_stale_lock:Admission gate reaps stale lock and admits"
        "test_admission_refuses_low_memory:Admission gate refuses on low free memory"
        "test_admission_lock_released_after_run:Admission lock released after pipeline exit"
        "test_build_loop_ceiling_respected:Build-loop iteration ceiling respects target (≤50 invocations)"
    )

    for entry in "${tests[@]}"; do
        local fn="${entry%%:*}"
        local desc="${entry#*:}"

        if [[ -n "$filter" && "$fn" != "$filter" ]]; then
            continue
        fi

        run_test "$desc" "$fn"
    done

    # ── Process-leak delta check ──────────────────────────────────────────
    local node_after node_delta
    node_after=$(pgrep -c -f 'node ' 2>/dev/null || echo "0")
    node_after=$(echo "$node_after" | tr -d '[:space:]')
    node_delta=$(( node_after - node_before ))
    if [[ "$node_delta" -gt 0 ]]; then
        echo -e "${RED}✗ Process leak detected: $node_delta extra Node process(es) after tests (before=$node_before after=$node_after)${RESET}"
        FAIL=$(( FAIL + 1 ))
        TOTAL=$(( TOTAL + 1 ))
        FAILURES+=("Process leak: $node_delta extra Node process(es)")
    else
        echo -e "${GREEN}✓${RESET} No Node process leak (before=$node_before after=$node_after delta=$node_delta)"
        PASS=$(( PASS + 1 ))
        TOTAL=$(( TOTAL + 1 ))
    fi

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

main "$@"
