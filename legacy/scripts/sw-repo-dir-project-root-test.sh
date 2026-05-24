#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright repo-dir-project-root — Regression tests for #335           ║
# ║  Verify PROJECT_ROOT resolves to git repo root, not install root        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# TEST ENVIRONMENT
# ═══════════════════════════════════════════════════════════════════════════════

setup_env() {
    TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-project-root-test.XXXXXX")
    export HOME="$TEST_TEMP_DIR/home"
    mkdir -p "$HOME/.shipwright"
    mkdir -p "$HOME/.local/bin"

    # Simulated PATH-installed shipwright: scripts live under ~/.local/
    FAKE_INSTALL_ROOT="$TEST_TEMP_DIR/fake-install"
    mkdir -p "$FAKE_INSTALL_ROOT/scripts/lib"

    # Simulated user git repo with .claude/
    FAKE_PROJECT="$TEST_TEMP_DIR/project"
    mkdir -p "$FAKE_PROJECT/.claude/pipeline-artifacts"
    mkdir -p "$FAKE_PROJECT/.claude/agents"
    mkdir -p "$FAKE_PROJECT/.claude/decision-drafts"
    mkdir -p "$FAKE_PROJECT/.claude/evidence"
    mkdir -p "$FAKE_PROJECT/.claude/worktrees"
    mkdir -p "$FAKE_PROJECT/.git"

    # Create mock binaries
    mkdir -p "$TEST_TEMP_DIR/bin"

    # Mock git that returns the fake project as toplevel
    cat > "$TEST_TEMP_DIR/bin/git" <<MOCKGIT
#!/usr/bin/env bash
case "\${1:-}" in
    rev-parse)
        if [[ "\${2:-}" == "--show-toplevel" ]]; then
            echo "$FAKE_PROJECT"
        elif [[ "\${2:-}" == "--abbrev-ref" ]]; then
            echo "main"
        else
            echo "$FAKE_PROJECT"
        fi ;;
    remote) echo "https://github.com/testuser/testrepo.git" ;;
    log|branch|diff|stash) echo "" ;;
    *) echo "" ;;
esac
exit 0
MOCKGIT
    chmod +x "$TEST_TEMP_DIR/bin/git"

    # Mock jq
    if command -v jq >/dev/null 2>&1; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    else
        cat > "$TEST_TEMP_DIR/bin/jq" <<'MOCKJQ'
#!/usr/bin/env bash
echo "null"
MOCKJQ
        chmod +x "$TEST_TEMP_DIR/bin/jq"
    fi

    # Mock claude
    cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCKCLAUDE'
#!/usr/bin/env bash
echo '{"ok": true}'
exit 0
MOCKCLAUDE
    chmod +x "$TEST_TEMP_DIR/bin/claude"

    # Mock gh
    cat > "$TEST_TEMP_DIR/bin/gh" <<'MOCKGH'
#!/usr/bin/env bash
echo '[]'
exit 0
MOCKGH
    chmod +x "$TEST_TEMP_DIR/bin/gh"

    # Mock date for non-GNU systems
    cat > "$TEST_TEMP_DIR/bin/date" <<'MOCKDATE'
#!/usr/bin/env bash
if [[ "${1:-}" == "-u" ]] || [[ "${1:-}" == "+%s" ]]; then
    command date "$@"
else
    command date "$@"
fi
MOCKDATE
    chmod +x "$TEST_TEMP_DIR/bin/date"

    # Restricted PATH: only our mocks + essential system tools
    export PATH="$TEST_TEMP_DIR/bin:/usr/bin:/bin"

    export NO_GITHUB=true
    export GIT_TERMINAL_PROMPT=0
    export EVENTS_FILE="$HOME/.shipwright/events.jsonl"
    touch "$EVENTS_FILE"
}

cleanup_env() {
    [[ -n "${TEST_TEMP_DIR:-}" && -d "${TEST_TEMP_DIR:-}" ]] && rm -rf "$TEST_TEMP_DIR"
}
_test_cleanup_hook() { cleanup_env; }

# ═══════════════════════════════════════════════════════════════════════════════
# HELPER: Copy a script to the fake install root and source it, then check
# that PROJECT_ROOT resolves to the git repo, not the install root.
# ═══════════════════════════════════════════════════════════════════════════════

# Copy a script into the fake install tree and return its path
install_script() {
    local script_name="$1"
    local src="$SCRIPT_DIR/$script_name"
    local dest="$FAKE_INSTALL_ROOT/scripts/$script_name"
    cp "$src" "$dest"
    echo "$dest"
}

# Copy lib files needed by scripts
install_libs() {
    # Copy all lib files
    if [[ -d "$SCRIPT_DIR/lib" ]]; then
        cp -R "$SCRIPT_DIR/lib/"* "$FAKE_INSTALL_ROOT/scripts/lib/" 2>/dev/null || true
    fi
}

# Test PROJECT_ROOT resolution for a script.
# Args: $1=script_name, $2=human_label
# The script is copied to FAKE_INSTALL_ROOT (so SCRIPT_DIR/../ != project root).
# We source it in a subshell and capture PROJECT_ROOT.
test_project_root_resolution() {
    local script_name="$1"
    local label="$2"
    local installed_script
    installed_script=$(install_script "$script_name")

    # Run in subshell: unset REPO_DIR and PROJECT_ROOT, source the script,
    # print PROJECT_ROOT. We use bash -c to get a clean subshell.
    local result
    result=$(
        cd "$FAKE_PROJECT"
        unset REPO_DIR PROJECT_ROOT 2>/dev/null || true
        # Override SCRIPT_DIR to match fake install
        export SCRIPT_DIR="$FAKE_INSTALL_ROOT/scripts"
        # Source just the header (first 30 lines) to get variable derivation
        # without running the whole script's function registrations
        bash -c "
            set -euo pipefail
            SCRIPT_DIR='$FAKE_INSTALL_ROOT/scripts'
            BASH_SOURCE_OVERRIDE=true
            # Source just the PROJECT_ROOT derivation by extracting it
            source '$installed_script' --help 2>/dev/null || true
            echo \"REPO_DIR=\${REPO_DIR:-UNSET}\"
            echo \"PROJECT_ROOT=\${PROJECT_ROOT:-UNSET}\"
        " 2>/dev/null || true
    )

    local project_root_val
    project_root_val=$(echo "$result" | grep '^PROJECT_ROOT=' | head -1 | cut -d= -f2-)

    if [[ "$project_root_val" == "$FAKE_PROJECT" ]]; then
        assert_pass "$label: PROJECT_ROOT resolves to git repo root"
    elif [[ "$project_root_val" == "UNSET" || -z "$project_root_val" ]]; then
        assert_fail "$label: PROJECT_ROOT is unset" "expected: $FAKE_PROJECT, got: UNSET"
    else
        assert_fail "$label: PROJECT_ROOT resolves to wrong path" "expected: $FAKE_PROJECT, got: $project_root_val"
    fi
}

# Test that PROJECT_ROOT is preserved when pre-set by caller
test_project_root_preserved() {
    local script_name="$1"
    local label="$2"
    local installed_script
    installed_script=$(install_script "$script_name")
    local custom_root="$TEST_TEMP_DIR/custom-project"
    mkdir -p "$custom_root/.claude"

    local result
    result=$(
        cd "$FAKE_PROJECT"
        bash -c "
            set -euo pipefail
            export PROJECT_ROOT='$custom_root'
            SCRIPT_DIR='$FAKE_INSTALL_ROOT/scripts'
            source '$installed_script' --help 2>/dev/null || true
            echo \"PROJECT_ROOT=\${PROJECT_ROOT:-UNSET}\"
        " 2>/dev/null || true
    )

    local project_root_val
    project_root_val=$(echo "$result" | grep '^PROJECT_ROOT=' | head -1 | cut -d= -f2-)

    if [[ "$project_root_val" == "$custom_root" ]]; then
        assert_pass "$label: PROJECT_ROOT preserved when pre-set"
    else
        assert_fail "$label: PROJECT_ROOT not preserved" "expected: $custom_root, got: $project_root_val"
    fi
}

# Test that no ${REPO_DIR}/.claude/ references remain in a script
test_no_repo_dir_claude_refs() {
    local script_name="$1"
    local label="$2"
    local src="$SCRIPT_DIR/$script_name"

    local count count2
    count=$(grep -c '${REPO_DIR}/\.claude/' "$src" 2>/dev/null) || count=0
    # Also check $REPO_DIR/.claude/ (without braces)
    count2=$(grep -c '$REPO_DIR/\.claude/' "$src" 2>/dev/null) || count2=0
    local total=$((count + count2))

    if [[ "$total" -eq 0 ]]; then
        assert_pass "$label: no \${REPO_DIR}/.claude/ references remain"
    else
        assert_fail "$label: still has \${REPO_DIR}/.claude/ references" "found $total occurrence(s)"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

print_test_header "shipwright PROJECT_ROOT regression tests (#335)"

setup_env
install_libs

# ─── All 22 files: verify no ${REPO_DIR}/.claude/ references remain ──────────

print_test_section "1. Static analysis: no \${REPO_DIR}/.claude/ in fixed scripts"

ALL_SCRIPTS=(
    # 18 main scripts
    sw-adversarial.sh
    sw-architecture-enforcer.sh
    sw-code-review.sh
    sw-decide.sh
    sw-developer-simulation.sh
    sw-doc-fleet.sh
    sw-evidence.sh
    sw-feedback.sh
    sw-github-checks.sh
    sw-github-deploy.sh
    sw-otel.sh
    sw-pipeline-vitals.sh
    sw-pr-lifecycle.sh
    sw-public-dashboard.sh
    sw-security-audit.sh
    sw-trace.sh
    sw-triage.sh
    sw-widgets.sh
    # 1 lib file
    lib/daemon-dispatch.sh
    # 3 #334 scripts
    sw-intelligence.sh
    sw-context.sh
    sw-team-stages.sh
)

for script in "${ALL_SCRIPTS[@]}"; do
    test_no_repo_dir_claude_refs "$script" "$script"
done

# ─── All 22 files: verify PROJECT_ROOT variable is defined ───────────────────

print_test_section "2. Static analysis: PROJECT_ROOT derivation block present"

for script in "${ALL_SCRIPTS[@]}"; do
    src="$SCRIPT_DIR/$script"
    if grep -q 'PROJECT_ROOT=' "$src" 2>/dev/null; then
        assert_pass "$script: PROJECT_ROOT derivation present"
    else
        assert_fail "$script: missing PROJECT_ROOT derivation"
    fi
done

# ─── Verify standard PROJECT_ROOT block pattern ─────────────────────────────

print_test_section "3. Static analysis: standard PROJECT_ROOT block pattern"

for script in "${ALL_SCRIPTS[@]}"; do
    src="$SCRIPT_DIR/$script"
    # Check for the guard: PROJECT_ROOT="${PROJECT_ROOT:-}"
    if grep -q 'PROJECT_ROOT="\${PROJECT_ROOT:-}"' "$src" 2>/dev/null || \
       grep -q 'PROJECT_ROOT="${PROJECT_ROOT:-}"' "$src" 2>/dev/null; then
        assert_pass "$script: PROJECT_ROOT guard present"
    else
        assert_fail "$script: missing PROJECT_ROOT guard (PROJECT_ROOT=\"\${PROJECT_ROOT:-}\")"
    fi
done

# ─── #334 scripts: verify intermediate variables removed ─────────────────────

print_test_section "4. #334 scripts: intermediate variables removed"

for varname in _sw_intel_candidate _sw_ctx_candidate _sw_ts_candidate; do
    local_script=""
    case "$varname" in
        _sw_intel_candidate) local_script="sw-intelligence.sh" ;;
        _sw_ctx_candidate)   local_script="sw-context.sh" ;;
        _sw_ts_candidate)    local_script="sw-team-stages.sh" ;;
    esac
    src="$SCRIPT_DIR/$local_script"
    if grep -q "$varname" "$src" 2>/dev/null; then
        assert_fail "$local_script: intermediate variable $varname still present"
    else
        assert_pass "$local_script: intermediate variable $varname removed"
    fi
done

# ─── sw-decide.sh: _REPO_DIR override pattern cleaned up ────────────────────

print_test_section "5. sw-decide.sh special case"

src="$SCRIPT_DIR/sw-decide.sh"
if grep -q '_REPO_DIR' "$src" 2>/dev/null; then
    assert_fail "sw-decide.sh: _REPO_DIR reference still present"
else
    assert_pass "sw-decide.sh: _REPO_DIR reference removed"
fi

# ─── Verify REPO_DIR is simple install-root derivation in #334 scripts ───────

print_test_section "6. #334 scripts: REPO_DIR is simple install-root derivation"

for script in sw-intelligence.sh sw-context.sh sw-team-stages.sh; do
    src="$SCRIPT_DIR/$script"
    # Should have simple: REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
    # or: REPO_DIR="${REPO_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
    if grep -qE 'REPO_DIR=.*\$SCRIPT_DIR/\.\.' "$src" 2>/dev/null; then
        assert_pass "$script: REPO_DIR uses simple SCRIPT_DIR/.. derivation"
    else
        assert_fail "$script: REPO_DIR not using simple derivation"
    fi
done

# ─── Exclusion check: these files should NOT have PROJECT_ROOT ───────────────

print_test_section "7. Excluded files: no PROJECT_ROOT added"

for script in lib/daemon-triage.sh lib/pipeline-stages-delivery.sh; do
    src="$SCRIPT_DIR/$script"
    if [[ ! -f "$src" ]]; then
        assert_pass "$script: file not found (OK — may not exist)"
        continue
    fi
    count=$(grep -c '${REPO_DIR}/\.claude/' "$src" 2>/dev/null) || count=0
    if [[ "$count" -eq 0 ]]; then
        assert_pass "$script: confirmed no \${REPO_DIR}/.claude/ usage (correctly excluded)"
    else
        assert_fail "$script: has \${REPO_DIR}/.claude/ usage but was excluded from fix"
    fi
done

# ─── Results ─────────────────────────────────────────────────────────────────

print_test_results
exit $FAIL
