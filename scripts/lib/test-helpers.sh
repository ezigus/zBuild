#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  zBuild test-helpers — Shared test harness for all unit tests        ║
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

# ─── Re-entrancy guard (#971): refuse a test invoked inside another test run ──
# Every *-test.sh sources this file first, so this is the universal chokepoint.
# A test executed from WITHIN another test run — e.g. objective-ablation's negctl/
# reachability gates run `bash <changed-test>` directly — would re-enter the gate
# logic and fork-bomb the pipeline test stage (the recurring #929/#983/#971 class).
# The #983 guard in run-tests.sh only catches run-tests.sh-mediated nesting; the
# ablation's direct `bash` bypasses it. This guard catches BOTH paths.
# The sentinel has NO leading underscore so env-scrub's ^(ZBUILD_|_TPL_) clears it
# at every fresh-user-shell boundary (the pipeline test stage), avoiding a stale-
# value false refusal. Fixture-isolated nested runs set ZBUILD_TESTS_DIR and are
# exempt (mirrors the #983 guard's exemption). The guard fires ONLY when $0 is a
# `*-test.sh` being EXECUTED (`bash <test>.sh` — the ablation/fork-bomb path), not
# when a script merely sources this file for introspection (`bash -c "source …"`,
# where $0 is `bash`) — so test-helpers' own self-tests are unaffected.
if [[ -n "${ZBUILD_TEST_EXEC_ACTIVE:-}" && -z "${ZBUILD_TESTS_DIR:-}" && "${0##*/}" == *-test.sh ]]; then
    echo "test-helpers.sh: refusing nested test invocation (re-entrancy guard #971)" >&2
    exit 2
fi
export ZBUILD_TEST_EXEC_ACTIVE=1

# ─── Colors ──────────────────────────────────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
GREEN='\033[38;2;74;222;128m'
RED='\033[38;2;248;113;113m'
# shellcheck disable=SC2034
YELLOW='\033[38;2;250;204;21m'
# shellcheck disable=SC2034
PURPLE='\033[38;2;168;85;247m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Counters ────────────────────────────────────────────────────────────────
PASS=0
FAIL=0
TOTAL=0
SKIP=0
FAILURES=()

# ─── Auto-initialize TEST_TEMP_DIR ──────────────────────────────────────────
# Many test files use TEST_TEMP_DIR in their setup_env() without calling
# setup_test_env(). Auto-create a temp dir so $TEST_TEMP_DIR is never empty.
# Save originals now so cleanup_test_env() can always restore them.
ORIG_HOME="${HOME}"
ORIG_PATH="${PATH}"
# Track the auto-created temp dir separately so cleanup always removes it,
# even if individual tests later reassign TEST_TEMP_DIR in their own setup_env.
AUTO_TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/zb-test-auto.XXXXXX")
TEST_TEMP_DIR="$AUTO_TEST_TEMP_DIR"
# Wave 19-L (#751 Copilot review): freeze the tmp-root at source time so
# the master trap's prefix guard stays valid even when tests re-export
# TMPDIR (e.g., to $TEST_TEMP_DIR/_tmp for sandbox mktemp shims).
_ZB_TEST_TMP_ROOT="${TMPDIR:-/tmp}"
_ZB_TEST_TMP_ROOT="${_ZB_TEST_TMP_ROOT%/}"
mkdir -p "$TEST_TEMP_DIR/home/.zbuild"
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
    # Wave 19-L (#749): rm each named TEST_TEMP_DIR setup_test_env created
    # so tests that forgot _test_cleanup_hook / cleanup_test_env stop
    # leaking. Path-prefix guard against accidental rm-rf-/: each tracked
    # path must live under the source-time tmp-root captured in
    # _ZB_TEST_TMP_ROOT. Using the CURRENT $TMPDIR would fail when tests
    # re-export TMPDIR (Copilot review #751); the source-time root is
    # stable for the process lifetime since AUTO_TEST_TEMP_DIR was created
    # there. (mktemp -d always returns an absolute path so the prefix
    # check is meaningful.)
    local _trk
    for _trk in "${_TRACKED_TEST_TEMP_DIRS[@]:-}"; do
        [[ -z "$_trk" ]] && continue
        [[ "$_trk" == "$_ZB_TEST_TMP_ROOT"/* ]] || continue
        [[ -d "$_trk" ]] && rm -rf "$_trk" 2>/dev/null || true
    done
}
# Wave 19-L: initialize the tracking array (declared here so setup_test_env
# can += without `unbound variable` under set -u).
_TRACKED_TEST_TEMP_DIRS=()
trap '_test_harness_cleanup' EXIT INT TERM

# ─── Assertions ──────────────────────────────────────────────────────────────

assert_pass() {
    local desc="$1"
    TOTAL=$((TOTAL + 1))
    PASS=$((PASS + 1))
    # #600: ZBUILD_TEST_QUIET=1 suppresses per-assertion echoes to keep the
    # pipeline test-stage banner compact. Counters still update; assert_fail
    # is intentionally NOT gated (failures always surface).
    [[ "${ZBUILD_TEST_QUIET:-0}" == "1" ]] && return 0
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
    local test_name="${1:-zb-test}"
    # Clean up auto-created temp dir and create a named one
    [[ -n "$TEST_TEMP_DIR" && -d "$TEST_TEMP_DIR" ]] && rm -rf "$TEST_TEMP_DIR"
    TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/${test_name}.XXXXXX")
    # Wave 19-L (#749): register the named TEST_TEMP_DIR for cleanup in the
    # master trap. Without this, tests that forget to set _test_cleanup_hook
    # or call cleanup_test_env leak the named dir. Audit (2026-06-08) found
    # 44 of 245 setup_test_env callsites had this gap → 1,261 leaked dirs.
    # The master trap (_test_harness_cleanup) reads _TRACKED_TEST_TEMP_DIRS
    # and rm -rf's each, in addition to AUTO_TEST_TEMP_DIR.
    _TRACKED_TEST_TEMP_DIRS+=("$TEST_TEMP_DIR")
    mkdir -p "$TEST_TEMP_DIR/home/.zbuild"
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

# Install an envelope-aware mock claude binary on PATH ($TEST_TEMP_DIR/bin).
# Branches on argv: when invoked with `--output-format json` (ADR-018 Pattern 1
# decision #8, #476), wraps the payload in a {type:result,result:...} envelope
# so the router's `.result` extraction finds it. Otherwise emits the payload
# as raw text (legacy/text-mode callers).
#
# Usage:
#   install_envelope_mock_claude <payload>                        # payload is inline text
#   install_envelope_mock_claude --file <payload_file>            # payload comes from a file at call time
#   install_envelope_mock_claude --record-argv <path> <payload>   # also record argv to <path>
#   install_envelope_mock_claude --record-prompt <path> <payload> # also record `-p <prompt>` to <path>
#
# Flags may be combined (e.g. --file + --record-argv).
install_envelope_mock_claude() {
    local payload="" payload_file="" argv_record="" prompt_record=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --file)          payload_file="$2"; shift 2 ;;
            --record-argv)   argv_record="$2"; shift 2 ;;
            --record-prompt) prompt_record="$2"; shift 2 ;;
            *)               payload="$1"; shift ;;
        esac
    done
    mkdir -p "$TEST_TEMP_DIR/bin"
    local mock_bin="$TEST_TEMP_DIR/bin/claude"
    cat > "$mock_bin" <<MOCK
#!/usr/bin/env bash
# Auto-generated by install_envelope_mock_claude (#476).
if [[ -n "${argv_record:-}" ]]; then
    printf '%s\n' "\$@" > "$argv_record"
fi
envelope_mode=0
prompt_text=""
while [[ \$# -gt 0 ]]; do
    case "\$1" in
        --output-format|json) envelope_mode=1; shift ;;
        -p) prompt_text="\${2:-}"; shift 2 ;;
        *)  shift ;;
    esac
done
if [[ -n "${prompt_record:-}" ]]; then
    printf '%s' "\$prompt_text" > "$prompt_record"
fi
if [[ -n "${payload_file:-}" ]]; then
    payload="\$(cat "$payload_file")"
else
    payload=$(printf '%q' "$payload")
fi
if [[ \$envelope_mode -eq 1 ]]; then
    jq -n --arg r "\$payload" '{type:"result",subtype:"success",result:\$r,usage:{input_tokens:0,output_tokens:0},tool_uses:[]}'
else
    printf '%s\n' "\$payload"
fi
exit 0
MOCK
    chmod +x "$mock_bin"
}

# ─── Platform Skip Guards ─────────────────────────────────────────────────────

# Fail loudly on an unknown platform argument. A typo (e.g. `lniux`) must NOT
# silently skip a test forever while still reporting success — that would let CI
# mask a test that never runs. Exits non-zero so the mistake surfaces.
_require_known_platform() {
    case "$1" in
        linux|macos) return 0 ;;
        *)
            echo -e "  ${RED}ERROR${RESET}: unknown platform '$1' (expected: linux|macos)" >&2
            exit 2
            ;;
    esac
}

skip_unless_platform() {
    local required="$1"
    _require_known_platform "$required"
    local current
    current="$(uname -s 2>/dev/null)"
    case "$current" in
        Darwin) current="macos" ;;
        Linux)  current="linux" ;;
    esac
    [[ "$current" == "$required" ]] && return 0
    SKIP=$((SKIP + 1))
    echo -e "  ${YELLOW}SKIP${RESET}: requires '$required', running on '$current'" >&2
    print_test_results
}

skip_on_platform() {
    local excluded="$1"
    _require_known_platform "$excluded"
    local current
    current="$(uname -s 2>/dev/null)"
    case "$current" in
        Darwin) current="macos" ;;
        Linux)  current="linux" ;;
    esac
    [[ "$current" != "$excluded" ]] && return 0
    SKIP=$((SKIP + 1))
    echo -e "  ${YELLOW}SKIP${RESET}: excluded on '$excluded'" >&2
    print_test_results
}

# Capability gate: SKIP cleanly when the platform is right but a required tool is
# absent or lacks a needed feature, so an unexercisable contract is an honest
# SKIP instead of a confusing failure. Args: a human-readable label, then a probe
# command (+args) run with output suppressed — e.g.
#   skip_unless_capable "setsid -w unavailable" setsid -w true
#   skip_unless_capable "flock unavailable" command -v flock
skip_unless_capable() {
    local label="$1"; shift
    "$@" >/dev/null 2>&1 && return 0
    SKIP=$((SKIP + 1))
    echo -e "  ${YELLOW}SKIP${RESET}: $label" >&2
    print_test_results
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
    if [[ "${SKIP:-0}" -gt 0 ]]; then
        echo ""
        echo -e "  ${YELLOW}${BOLD}SKIP${RESET}"
        echo ""
        exit 0
    fi
    # #600: in quiet mode, emit a single-line compact summary FIRST so the
    # pipeline operator can scan a 30-line test-stage banner instead of ~150.
    # The full multi-line block follows unchanged (no info loss for humans
    # reviewing failures).
    if [[ "${ZBUILD_TEST_QUIET:-0}" == "1" ]]; then
        if [[ $FAIL -eq 0 ]]; then
            echo -e "  ${GREEN}${BOLD}✓ ${PASS}/${TOTAL} passed${RESET}"
        else
            echo -e "  ${RED}${BOLD}✗ ${PASS}/${TOTAL} passed (${FAIL} FAILED)${RESET}"
        fi
    fi
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

# Mock route_to_model with parameterizable rc, stdout, and optional delay
# Usage: mock_route_to_model <rc> <stdout_content> [delay_seconds]
mock_route_to_model() {
  local rc="$1"
  local stdout_content="$2"
  local delay="${3:-0}"
  local mock_dir="${ZBUILD_TEST_TMP:-/tmp}/mocks/$$"
  mkdir -p "$mock_dir"
  # Write stdout content to a file so single-quotes in content don't break the script
  printf '%s' "$stdout_content" > "$mock_dir/claude-stdout"
  cat > "$mock_dir/claude" <<MOCKEOF
#!/usr/bin/env bash
[[ "$delay" -gt 0 ]] && sleep "$delay"
cat "$(printf '%s' "$mock_dir")/claude-stdout"
exit $rc
MOCKEOF
  chmod +x "$mock_dir/claude"
  export PATH="$mock_dir:$PATH"
  export ZBUILD_MOCK_CLAUDE_RC="$rc"
}

# ── mock_plugin_factory ───────────────────────────────────────────────────────
# Creates a minimal valid plugin directory under $TEST_TEMP_DIR/plugins/.
# Prints the directory path to stdout.
#
# Usage: mock_plugin_factory <id> [kind=agent] [exit_code=0] [platform=] [role=] [version=0.0.1]
mock_plugin_factory() {
    local id="$1" kind="${2:-agent}" exit_code="${3:-0}" platform="${4:-}" role="${5:-}" version="${6:-0.0.1}"
    local dir="$TEST_TEMP_DIR/plugins/$kind/$id"
    mkdir -p "$dir"
    local fn; fn="${id//-/_}_run"
    cat > "$dir/manifest.yaml" <<EOF
id: $id
name: Test $id
kind: $kind
version: $version
hooks:
  run: $fn
requires:
  core:
    - redaction
EOF
    [[ -n "$platform" ]] && printf 'platform: %s\n' "$platform" >> "$dir/manifest.yaml"
    if [[ -n "$role" ]]; then
        printf 'provides:\n  role: %s\n' "$role" >> "$dir/manifest.yaml"
    fi
    cat > "$dir/plugin.sh" <<EOF
${fn}() { return $exit_code; }
EOF
    printf '%s\n' "$dir"
}

# ── Standard-pipeline roster (single source of truth, issue #921) ─────────────
# Leaf stages in standard.yaml's resolved execution order. Format per element:
#   "<stage_id>:<kind>:<role>"
#     kind — agent|tool (plugin-directory convention; `test` is the only tool)
#     role — provides.role passed as mock_plugin_factory arg 5; empty = none
# This array is the ONE place the standard roster is declared for tests. The
# guard test tests/unit/standard-roster-single-source-test.sh fails loudly if
# this drifts from load_template(standard.yaml)'s _TPL_STAGES — so adding a
# stage to the template is a one-line change here, not an N-file edit.
_ZBUILD_STANDARD_ROSTER=(
    "intake:agent:"
    "plan:agent:"
    "design:agent:designer"
    "impact:agent:"
    "build:agent:"
    "test:tool:"
    "test_assessment:agent:"
    "acceptance-gate:agent:acceptance_gate"
    "cq-preflight:agent:"
    "cq-audit-plan:agent:"
    "cq-cycle:agent:"
    "cq-backtrack:agent:"
    "review:agent:"
    "pr:agent:pr_delivery"
)

# ── standard_stage_ids ────────────────────────────────────────────────────────
# Prints all standard leaf stage IDs, one per line, in execution order.
standard_stage_ids() {
    local entry
    for entry in "${_ZBUILD_STANDARD_ROSTER[@]}"; do
        printf '%s\n' "${entry%%:*}"
    done
}

# ── standard_stage_count ──────────────────────────────────────────────────────
# Prints the integer count of standard leaf stages.
standard_stage_count() {
    printf '%d\n' "${#_ZBUILD_STANDARD_ROSTER[@]}"
}

# ── register_standard_pipeline_stubs ─────────────────────────────────────────
# Registers a mock plugin dir for every standard leaf stage (via
# mock_plugin_factory), suppressing the factory's path echo. Replaces the
# hand-written vertical roster blocks scattered across integration tests.
#
# Per-stage exit-code override (optional): export ZBUILD_STUB_RC_<safe_id>=<N>
# before calling (safe_id = stage id with '-' → '_'), e.g.
#   export ZBUILD_STUB_RC_build=1
# For custom stage BODIES (hang loops, sentinels, env capture), call this
# helper first, then overwrite that one stage's plugin.sh afterward — the
# helper does not re-run, so post-call overwrites win.
register_standard_pipeline_stubs() {
    local entry stage_id rest kind role safe_id rc_var rc
    for entry in "${_ZBUILD_STANDARD_ROSTER[@]}"; do
        stage_id="${entry%%:*}"
        rest="${entry#*:}"
        kind="${rest%%:*}"
        role="${rest#*:}"
        safe_id="${stage_id//-/_}"
        rc_var="ZBUILD_STUB_RC_${safe_id}"
        rc="${!rc_var:-0}"
        mock_plugin_factory "$stage_id" "$kind" "$rc" "" "$role" >/dev/null
    done
}

# ── assert_event_emitted ──────────────────────────────────────────────────────
# Asserts that an event of the given type appears in the JSONL events log.
#
# Usage: assert_event_emitted <desc> <events_jsonl_path> <event_type>
assert_event_emitted() {
    local desc="$1" events_file="$2" event_type="$3"
    if [[ ! -f "$events_file" ]]; then
        assert_fail "$desc" "events file not found: $events_file"
        return
    fi
    local found
    found="$(jq -r --arg t "$event_type" 'select(.type == $t) | .type' "$events_file" 2>/dev/null | head -1 || true)"
    if [[ "$found" == "$event_type" ]]; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "event '$event_type' not found in $events_file"
    fi
}

# ─── setup_git_temp_repo ─────────────────────────────────────────────────────
# Creates a real, minimal git repo under $TEST_TEMP_DIR/<name> with one
# initial commit. Returns its absolute path on stdout. Used by integration
# tests that exercise real `git checkout`/`git symbolic-ref` against an
# isolated repo (issue #484).
#
# Usage:
#   repo="$(setup_git_temp_repo myrepo)"
#   (cd "$repo" && some_test)
setup_git_temp_repo() {
    local name="${1:-gitrepo}"
    local repo="$TEST_TEMP_DIR/$name"
    mkdir -p "$repo"
    (
        cd "$repo"
        # Use the real git binary (not whatever PATH shim may be present).
        local real_git
        real_git="$(command -v git 2>/dev/null || true)"
        # If a shim like the parity-fixture mock is on PATH, fall back to
        # well-known absolute locations.
        if [[ -z "$real_git" ]]; then
            for c in /usr/bin/git /usr/local/bin/git /opt/homebrew/bin/git; do
                [[ -x "$c" ]] && real_git="$c" && break
            done
        fi
        [[ -z "$real_git" ]] && return 1
        "$real_git" init -q -b main 2>/dev/null || "$real_git" init -q
        "$real_git" config user.email "test@zbuild.local"
        "$real_git" config user.name "zbuild-test"
        "$real_git" config commit.gpgsign false
        echo "seed" > seed.txt
        "$real_git" add seed.txt
        "$real_git" commit -q -m "seed"
        # Normalize default branch name to 'main' for predictable tests.
        local cur
        cur="$("$real_git" symbolic-ref --short HEAD 2>/dev/null || echo main)"
        if [[ "$cur" != "main" ]]; then
            "$real_git" branch -m "$cur" main 2>/dev/null || true
        fi
    ) >/dev/null 2>&1 || return 1
    printf '%s\n' "$repo"
}

# ── install_cycle_mock_stages (ADR-021, #512) ─────────────────────────────────
# Generate plugins for a cycle whose per-stage verdict depends on ZBUILD_CYCLE_ITER.
#
# Usage:
#   install_cycle_mock_stages <plugins_root> <cycle_id> <stage_id> <iter1:iter2:...>
#
# Each stage emits the verdict declared at index (iter-1). Trailing iters reuse
# the last declared verdict. The plugin also writes the primary artifact to
# state/artifacts/<stage>/primary.txt so feedback wiring has something to copy.
install_cycle_mock_stages() {
    # shellcheck disable=SC2034
    local plugins_root="$1" cycle_id="$2" stage_id="$3" verdicts="$4"
    local dir="$plugins_root/agent/$stage_id"
    mkdir -p "$dir"
    local fn="${stage_id//-/_}_run"
    cat > "$dir/manifest.yaml" <<EOF
id: $stage_id
name: Cycle Mock $stage_id
kind: agent
version: 0.0.1
hooks:
  run: $fn
provides:
  artifact_type: primary.txt
outputs:
  - path: $stage_id/primary.txt
requires:
  core:
    - redaction
EOF
    cat > "$dir/plugin.sh" <<PLUGIN
${fn}() {
    local stage_id="\$1" state_file="\$2"
    local iter="\${ZBUILD_CYCLE_ITER:-1}"
    local verdicts="$verdicts"
    local IFS_save="\$IFS"; IFS=':'
    # shellcheck disable=SC2206
    local -a vs=(\$verdicts)
    IFS="\$IFS_save"
    local idx=\$(( iter - 1 ))
    [[ \$idx -ge \${#vs[@]} ]] && idx=\$(( \${#vs[@]} - 1 ))
    local v="\${vs[\$idx]:-pass}"
    local sdir="\${ZBUILD_STATE_DIR:-\$HOME/.zbuild/state}"
    mkdir -p "\$sdir/artifacts/$stage_id"
    printf 'iter=%s verdict=%s\n' "\$iter" "\$v" > "\$sdir/artifacts/$stage_id/primary.txt"
    # Persist verdict where runner_read_stage_verdict can find it. The simplest
    # path: write to state via jq inline (we lack the verdict.sh API surface in
    # this stub). cycle_dispatch_stage reads _CYCLE_DISPATCH_VERDICT, so set it
    # via the state file mechanism the orchestrator scrapes.
    export _CYCLE_DISPATCH_VERDICT="\$v"
    export _CYCLE_DISPATCH_STATUS="complete"
    [[ "\$v" == "fail" ]] && return 1
    return 0
}
PLUGIN
    printf '%s\n' "$dir"
}

# Assert no direct anthropic API calls were made (chokepoint enforcement)
mock_anthropic_api() {
  local mock_dir="${ZBUILD_TEST_TMP:-/tmp}/mocks/$$"
  mkdir -p "$mock_dir"
  cat > "$mock_dir/curl" <<'MOCKEOF'
#!/usr/bin/env bash
if printf '%s\n' "$@" | grep -q 'anthropic'; then
  echo "[mock] ERROR: direct anthropic API call detected — must go through core/redaction" >&2
  exit 1
fi
exec /usr/bin/curl "$@"
MOCKEOF
  chmod +x "$mock_dir/curl"
  export PATH="$mock_dir:$PATH"
}
