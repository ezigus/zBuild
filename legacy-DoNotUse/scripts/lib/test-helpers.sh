#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright test-helpers — Shared test harness for all unit tests        ║
# ║  Source this from any *-test.sh file to get assert_*, setup, teardown    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Usage:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/lib/test-helpers.sh"
#
# Provides:
#   Colors, counters, assert_pass/fail/eq/contains/contains_regex/gt/json_key
#   setup_test_env / cleanup_test_env  (temp dir, mock PATH, mock HOME)
#   print_test_header / print_test_results
#   Mock helpers: mock_binary, mock_jq, mock_git, mock_gh, mock_claude

[[ -n "${_TEST_HELPERS_LOADED:-}" ]] && return 0
_TEST_HELPERS_LOADED=1

# ─── Colors ──────────────────────────────────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
GREEN='\033[38;2;74;222;128m'
RED='\033[38;2;248;113;113m'
YELLOW='\033[38;2;250;204;21m'
PURPLE='\033[38;2;168;85;247m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Counters ────────────────────────────────────────────────────────────────
PASS=0
FAIL=0
TOTAL=0
FAILURES=()

# ─── Auto-initialize TEST_TEMP_DIR ──────────────────────────────────────────
# Many test files use TEST_TEMP_DIR in their setup_env() without calling
# setup_test_env(). Auto-create a temp dir so $TEST_TEMP_DIR is never empty.
# Save originals now so cleanup_test_env() can always restore them.
ORIG_HOME="${HOME}"
ORIG_PATH="${PATH}"
# Track the auto-created temp dir separately so cleanup always removes it,
# even if individual tests later reassign TEST_TEMP_DIR in their own setup_env.
AUTO_TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-test-auto.XXXXXX")
TEST_TEMP_DIR="$AUTO_TEST_TEMP_DIR"
mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
mkdir -p "$TEST_TEMP_DIR/bin"
mkdir -p "$TEST_TEMP_DIR/_tmp"
# Sandbox mktemp shim — macOS plain `mktemp`/`mktemp -d` (no template) ignores
# $TMPDIR and uses /var/folders which is write-blocked in the sandbox.
# Route templateless calls through a writable directory.
# Linux mktemp respects $TMPDIR natively so no shim is needed there; installing
# one would break test setup_env() loops that do `ln -sf "$(command -v mktemp)"`
# because command -v resolves to the shim itself (same-file ln error).
if [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
    printf '#!/usr/bin/env bash\n_s="%s"\nif [[ $# -eq 0 ]]; then exec /usr/bin/mktemp "$_s/tmp.XXXXXX"; fi\nif [[ $# -eq 1 && "$1" == "-d" ]]; then exec /usr/bin/mktemp -d "$_s/tmpd.XXXXXX"; fi\nexec /usr/bin/mktemp "$@"\n' \
        "$TEST_TEMP_DIR/_tmp" > "$TEST_TEMP_DIR/bin/mktemp"
    chmod +x "$TEST_TEMP_DIR/bin/mktemp"
fi
export PATH="$TEST_TEMP_DIR/bin:$PATH"
# ─── Child-process killer (used by master trap) ──────────────────────────────
_kill_test_children() {
    local pids
    pids=$(jobs -p 2>/dev/null) || true
    # shellcheck disable=SC2086  # word splitting intentional to pass multiple PIDs
    [[ -n "$pids" ]] && kill $pids 2>/dev/null || true
    pkill -P $$ 2>/dev/null || true
    wait 2>/dev/null || true
}

# ─── Script-level cleanup hook — override in each test script ────────────────
# Default is a no-op; scripts set: _test_cleanup_hook() { cleanup_env; }
_test_cleanup_hook() { :; }

# ─── Master trap — kills children, calls hook, removes auto temp dir ─────────
_test_harness_cleanup() {
    _kill_test_children
    _test_cleanup_hook
    if [[ -n "${AUTO_TEST_TEMP_DIR:-}" && -d "$AUTO_TEST_TEMP_DIR" ]]; then
        rm -rf "$AUTO_TEST_TEMP_DIR"
    fi
}
trap '_test_harness_cleanup' EXIT INT TERM

# ─── Assertions ──────────────────────────────────────────────────────────────

assert_pass() {
    local desc="$1"
    TOTAL=$((TOTAL + 1))
    PASS=$((PASS + 1))
    echo -e "  ${GREEN}✓${RESET} ${desc}"
}

assert_fail() {
    local desc="$1"
    local detail="${2:-}"
    TOTAL=$((TOTAL + 1))
    FAIL=$((FAIL + 1))
    FAILURES[${#FAILURES[@]}]="$desc"
    echo -e "  ${RED}✗${RESET} ${desc}"
    [[ -n "$detail" ]] && echo -e "    ${DIM}${detail}${RESET}"
}

assert_eq() {
    local desc="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "expected: $expected, got: $actual"
    fi
}

assert_contains() {
    local desc="$1"
    local haystack="$2"
    local needle="$3"
    if grep -qF -- "$needle" <<< "$haystack" 2>/dev/null; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "output missing: $needle"
    fi
}

assert_contains_regex() {
    local desc="$1"
    local haystack="$2"
    local pattern="$3"
    if grep -qE -- "$pattern" <<< "$haystack" 2>/dev/null; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "output missing pattern: $pattern"
    fi
}

assert_gt() {
    local desc="$1"
    local actual="$2"
    local threshold="$3"
    if [[ "$actual" -gt "$threshold" ]] 2>/dev/null; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "expected >$threshold, got: $actual"
    fi
}

assert_json_key() {
    local desc="$1"
    local json="$2"
    local key="$3"
    local expected="$4"
    local actual
    actual=$(echo "$json" | jq -r "$key" 2>/dev/null)
    if [[ "$actual" == "$expected" ]]; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "key $key: expected $expected, got: $actual"
    fi
}

assert_exit_code() {
    local desc="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        assert_pass "$desc (exit $actual)"
    else
        assert_fail "$desc" "expected exit code: $expected, got: $actual"
    fi
}

assert_file_exists() {
    local desc="$1"
    local filepath="$2"
    if [[ -f "$filepath" ]]; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "file not found: $filepath"
    fi
}

assert_file_not_exists() {
    local desc="$1"
    local filepath="$2"
    if [[ ! -f "$filepath" ]]; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "file should not exist: $filepath"
    fi
}

# ─── Test Environment ────────────────────────────────────────────────────────

setup_test_env() {
    local test_name="${1:-sw-test}"
    # Clean up auto-created temp dir and create a named one
    [[ -n "$TEST_TEMP_DIR" && -d "$TEST_TEMP_DIR" ]] && rm -rf "$TEST_TEMP_DIR"
    TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/${test_name}.XXXXXX")
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/bin"
    mkdir -p "$TEST_TEMP_DIR/project"
    mkdir -p "$TEST_TEMP_DIR/logs"

    # ORIG_HOME/ORIG_PATH already saved at source time
    export HOME="$TEST_TEMP_DIR/home"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export NO_GITHUB=true
    export GIT_TERMINAL_PROMPT=0

    # Prevent CI-environment leakage into the test subprocess.
    # GitHub Actions exports WORKSPACE_BRANCH and (in some workflows) CI_MODE; if
    # those leak into stage-level unit tests they silently divert intake into the
    # CI-workspace-branch path, breaking branch-creation assertions.
    unset WORKSPACE_BRANCH CI_MODE

    # Link real jq if available
    if command -v jq >/dev/null 2>&1; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi

    # Mock timeout — macOS doesn't have GNU coreutils timeout by default
    if ! command -v timeout >/dev/null 2>&1; then
        cat > "$TEST_TEMP_DIR/bin/timeout" <<'TIMEOUT_EOF'
#!/usr/bin/env bash
shift  # skip the timeout duration
exec "$@"
TIMEOUT_EOF
        chmod +x "$TEST_TEMP_DIR/bin/timeout"
    fi

    # Sandbox mktemp shim — macOS only (see auto-init comment above for rationale).
    mkdir -p "$TEST_TEMP_DIR/_tmp"
    if [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
        printf '#!/usr/bin/env bash\n_s="%s"\nif [[ $# -eq 0 ]]; then exec /usr/bin/mktemp "$_s/tmp.XXXXXX"; fi\nif [[ $# -eq 1 && "$1" == "-d" ]]; then exec /usr/bin/mktemp -d "$_s/tmpd.XXXXXX"; fi\nexec /usr/bin/mktemp "$@"\n' \
            "$TEST_TEMP_DIR/_tmp" > "$TEST_TEMP_DIR/bin/mktemp"
        chmod +x "$TEST_TEMP_DIR/bin/mktemp"
    fi
}

cleanup_test_env() {
    if [[ -n "$TEST_TEMP_DIR" && -d "$TEST_TEMP_DIR" ]]; then
        rm -rf "$TEST_TEMP_DIR" 2>/dev/null || true
    fi
    [[ -n "${ORIG_HOME:-}" ]] && export HOME="$ORIG_HOME" || true
    [[ -n "${ORIG_PATH:-}" ]] && export PATH="$ORIG_PATH" || true
}

# ─── Mock Helpers ────────────────────────────────────────────────────────────

mock_binary() {
    local name="$1"
    local script="${2:-exit 0}"
    cat > "$TEST_TEMP_DIR/bin/$name" <<MOCK
#!/usr/bin/env bash
$script
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/$name"
}

mock_git() {
    mock_binary "git" 'case "${1:-}" in
    rev-parse)
        if [[ "${2:-}" == "--show-toplevel" ]]; then echo "/tmp/mock-repo"
        elif [[ "${2:-}" == "--abbrev-ref" ]]; then echo "main"
        else echo "/tmp/mock-repo"
        fi ;;
    remote) echo "https://github.com/testuser/testrepo.git" ;;
    branch) echo "" ;;
    log) echo "" ;;
    *) echo "" ;;
esac
exit 0'
}

mock_gh() {
    mock_binary "gh" 'case "${1:-}" in
    api) echo "{}" ;;
    issue) echo "[]" ;;
    pr) echo "[]" ;;
    *) echo "" ;;
esac
exit 0'
}

mock_claude() {
    mock_binary "claude" 'echo "Mock claude response"
exit 0'
}

# ─── Output Helpers ──────────────────────────────────────────────────────────

print_test_header() {
    local title="$1"
    echo ""
    echo -e "${CYAN}${BOLD}  ${title}${RESET}"
    echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
    echo ""
}

print_test_section() {
    local title="$1"
    echo ""
    echo -e "  ${CYAN}${title}${RESET}"
}

print_test_results() {
    echo ""
    echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
    echo ""
    if [[ $FAIL -eq 0 ]]; then
        echo -e "  ${GREEN}${BOLD}All $TOTAL tests passed${RESET}"
    else
        echo -e "  ${RED}${BOLD}$FAIL of $TOTAL tests failed${RESET}"
        echo ""
        for f in "${FAILURES[@]}"; do
            echo -e "  ${RED}✗${RESET} $f"
        done
    fi
    echo ""
    exit "$FAIL"
}
