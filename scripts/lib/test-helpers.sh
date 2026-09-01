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
# A test executed from WITHIN another test run — e.g. the ablation negctl/
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

# The vision admission gate (ADR-049 / #1360) enforces a conforming vision doc by
# default. Fixture-based tests spin up temp repos with no vision doc and are not
# testing vision, so they must opt out — same hermeticity precedent as
# ZBUILD_CONTRACT_VALIDATOR. Tests that DO exercise the gate set the mode inline
# per-case, which overrides this default. Real (non-test) runs never source this
# file, so dogfood-on-zbuild still enforces against the real docs/VISION.md.
export ZBUILD_VISION_GATE="${ZBUILD_VISION_GATE:-off}"

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
# Sandbox ZBUILD_STATE_DIR and ZBUILD_ARTIFACT_DIR so stage-io writes during
# tests never escape to the outer pipeline's state directory (#1713).
# `+set` records SET-ness separately from the value: `${VAR:-}` collapses "unset"
# and "set but empty" into the same "", and cleanup would then unset a variable
# the caller had deliberately exported as empty. `${VAR-}` (no colon) keeps an
# empty value as empty.
ORIG_STATE_DIR_SET="${ZBUILD_STATE_DIR+set}"
ORIG_STATE_DIR="${ZBUILD_STATE_DIR-}"
ORIG_ARTIFACT_DIR_SET="${ZBUILD_ARTIFACT_DIR+set}"
ORIG_ARTIFACT_DIR="${ZBUILD_ARTIFACT_DIR-}"
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
# _HARNESS_SIGNAL: set by dedicated INT/TERM wrappers before calling cleanup,
# so _test_harness_cleanup can re-raise and exit 128+signal instead of
# returning into the interrupted test body (which would produce bogus failures).
# _HARNESS_CLEANED_UP: idempotency guard — prevents double cleanup when both
# a signal handler and the EXIT trap would otherwise call the body.
_HARNESS_SIGNAL=""
_HARNESS_CLEANED_UP=0

_test_harness_cleanup() {
    [[ "${_HARNESS_CLEANED_UP:-0}" == "1" ]] && return 0
    _HARNESS_CLEANED_UP=1
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
    # Signal-triggered teardown: clear both the signal trap and EXIT so the
    # re-raised signal exits with 128+N (143/130) without running EXIT again.
    if [[ -n "${_HARNESS_SIGNAL:-}" ]]; then
        trap - "${_HARNESS_SIGNAL}" EXIT
        kill -"${_HARNESS_SIGNAL}" $$
    fi
}

# Thin wrappers installed for TERM and INT: record the in-flight signal name
# then call the shared cleanup body. The cleanup body re-raises at the tail
# so the process exits 128+signal instead of returning into the test body.
_harness_signal_handler() {
    local _sig="$1"
    _HARNESS_SIGNAL="$_sig"
    _test_harness_cleanup
}

# Wave 19-L: initialize the tracking array (declared here so setup_test_env
# can += without `unbound variable` under set -u).
_TRACKED_TEST_TEMP_DIRS=()
trap '_test_harness_cleanup' EXIT
trap '_harness_signal_handler INT'  INT
trap '_harness_signal_handler TERM' TERM

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

    # ORIG_HOME/ORIG_PATH/ORIG_STATE_DIR already saved at source time.
    export HOME="$TEST_TEMP_DIR/home"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    # Unset ZBUILD_STATE_DIR and ZBUILD_ARTIFACT_DIR so any ambient pipeline
    # values do not leak into this test process (#1713). stage-io falls back to
    # ${HOME}/.zbuild/state (sandboxed above) when both are unset, landing all
    # writes in the sandbox. We unset rather than redirect to avoid perturbing
    # plan_context_recover_sidecar_reasoning (which uses these vars when set)
    # and other callers that manage their own artifact paths after setup.
    mkdir -p "$TEST_TEMP_DIR/home/.zbuild/state"
    unset ZBUILD_STATE_DIR
    unset ZBUILD_ARTIFACT_DIR
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

# ─── Reserved test identity (#1921 follow-up) ───────────────────────────────
# Tests used real issue numbers as identity fixtures — 25 of the 29 in use were
# live issues or PRs, and #42 is still OPEN. A run keyed to one of those writes
# fabricated prior work onto that issue's state branch; measured on this repo,
# zbuild/state/issue-999 held 68 commits of test payloads and issue-698 held 121.
# Now that CI chains and pushes (#1970, #2006), that reaches origin.
#
# 9_0000000+ is unreachable: this repo is ~2000 issues in. A stray
# zbuild/state/issue-9xxxxxxx ref is therefore unmistakably test residue, safe to
# reclaim, and can never be confused with someone's work.
# The floor of the reserved range. Read by lint-test-identity and the hygiene
# test; zb_test_issue composes its ids to always land at or above it.
ZB_TEST_ISSUE_FLOOR=90000000
export ZB_TEST_ISSUE_FLOOR

# Sequential within a test file: 90000001, 90000002, … Files repeat the same ids,
# which is safe because each runs in its own throwaway repo — and if one ever
# escapes, the number identifies it instantly.
# The counter lives in a FILE, not a shell variable: callers use $(zb_test_issue),
# which runs in a subshell, so an in-memory counter would never advance and every
# call would return the same id.
#
# The id is keyed on the PID so two test files running in PARALLEL never mint the
# same one. They otherwise all start at 90000001, and the teardown below deletes
# refs from the SHARED checkout — so one file's cleanup could delete a ref another
# file was still asserting on. The unit tier is parallel by default (#984), and
# more cores make that likelier, which is why it showed on Linux CI first.
#
# Shape: 9 + PID%1000 (3) + seq (4) — always 8 digits, always >= 90000000.
zb_test_issue() {
    local dir="${TEST_TEMP_DIR:-${TMPDIR:-/tmp}}"
    local f="$dir/.zb-test-issue-seq"
    local n=0
    [[ -r "$f" ]] && n="$(cat "$f" 2>/dev/null || printf '0')"
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    n=$(( n + 1 ))
    printf '%d' "$n" > "$f" 2>/dev/null || true
    local id
    id="$(printf '9%03d%04d' "$(( $$ % 1000 ))" "$n")"
    # Record it, so teardown removes exactly the refs THIS file minted rather
    # than every reserved ref it happens to find.
    printf '%s\n' "$id" >> "$dir/.zb-test-issue-minted" 2>/dev/null || true
    printf '%s' "$id"
}

# Goal fixtures get the same treatment: the marker makes zbuild/state/goal-<hash>
# traceable back to a test even though the hash itself is opaque.
zb_test_goal() {
    printf '[zb-test] %s' "${1:-fixture}"
}

# A throwaway repo WITH an origin. setup_git_temp_repo builds the working tree;
# this adds the bare remote a push needs. Promoted out of persist-stage-test.sh,
# where it lived as _mk_repo.
zb_test_repo() {
    local name="${1:-zbrepo}"
    local remote="$TEST_TEMP_DIR/$name-remote.git"
    local repo
    repo="$(setup_git_temp_repo "$name")" || return 1
    local real_git; real_git="$(command -v git 2>/dev/null || echo /usr/bin/git)"
    (
        "$real_git" init -q --bare "$remote"
        cd "$repo" || exit 1
        "$real_git" remote add origin "$remote"
        "$real_git" push -q -u origin main
    ) >/dev/null 2>&1 || return 1
    printf '%s\n' "$repo"
}

# Reserved-range state refs in a repo (default: the real checkout). Used by both
# the teardown below and the suite-wide hygiene guard.
zb_test_reserved_refs() {
    local repo="${1:-${REPO_ROOT:-$PWD}}"
    git -C "$repo" for-each-ref --format='%(refname)' \
        'refs/heads/zbuild/state/issue-9???????' 2>/dev/null || true
}

cleanup_test_env() {
    # Remove state refs THIS FILE minted and may have written into the real
    # checkout. Deliberately not "every reserved ref present": the unit tier runs
    # in parallel, so deleting another file's in-flight ref would fail its
    # assertions. Reserved-range by construction, so a real issue's branch is
    # never touched — not even one already contaminated.
    local _minted="${TEST_TEMP_DIR:-}/.zb-test-issue-minted"
    if [[ -n "${TEST_TEMP_DIR:-}" && -r "$_minted" ]]; then
        local _id
        while IFS= read -r _id; do
            [[ "$_id" =~ ^9[0-9]{7}$ ]] || continue
            git -C "${REPO_ROOT:-$PWD}" update-ref -d \
                "refs/heads/zbuild/state/issue-$_id" 2>/dev/null || true
        done < "$_minted"
    fi

    if [[ -n "$TEST_TEMP_DIR" && -d "$TEST_TEMP_DIR" ]]; then
        rm -rf "$TEST_TEMP_DIR" 2>/dev/null || true
    fi
    [[ -n "${ORIG_HOME:-}" ]] && export HOME="$ORIG_HOME" || true
    [[ -n "${ORIG_PATH:-}" ]] && export PATH="$ORIG_PATH" || true
    # Restore ZBUILD_STATE_DIR and ZBUILD_ARTIFACT_DIR to pre-setup values
    # (or unset them if they were not set before this test sourced the helpers).
    if [[ -n "${ORIG_STATE_DIR_SET:-}" ]]; then
        export ZBUILD_STATE_DIR="$ORIG_STATE_DIR"
    else
        unset ZBUILD_STATE_DIR
    fi
    if [[ -n "${ORIG_ARTIFACT_DIR_SET:-}" ]]; then
        export ZBUILD_ARTIFACT_DIR="$ORIG_ARTIFACT_DIR"
    else
        unset ZBUILD_ARTIFACT_DIR
    fi
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

# Install an envelope-aware ERROR mock claude binary on PATH ($TEST_TEMP_DIR/bin).
# Mirrors install_envelope_mock_claude but simulates a failed `claude` run that
# still prints a JSON result envelope to stdout and exits non-zero — the exact
# shape route.sh persists to its diagnostic sidecar
# (${ZBUILD_ARTIFACT_DIR:-…/artifacts}/stage-io/<stage>-sync-error.raw-claude-output.json).
#
# The default envelope simulates the #1052 dogfood failure: the planner burned
# all its turns exploring the repo and hit max_turns before emitting plan.json:
#   {"type":"result","subtype":"error_max_turns","is_error":true,
#    "num_turns":<N>,"result":"<partial reasoning text>",
#    "usage":{input_tokens:…,output_tokens:…}}
# then `exit 1`.
#
# Everything is tunable via env vars read AT MOCK-INVOCATION TIME (not install
# time), so a test can export a different value just before calling plan_run and
# the same installed binary honors it. This lets one installer cover three cases:
#   (a) max_turns exhaustion (defaults).
#   (b) a non-max_turns crash — set ZBUILD_MOCK_SUBTYPE to e.g. "error" and the
#       discriminator (subtype != error_max_turns) stays on the
#       claude_cli_failed path.
#   (c) a max_turns envelope whose .result IS a valid plan.json — set
#       ZBUILD_MOCK_RESULT to the plan JSON; recovery should salvage it.
#
# Env vars (all optional):
#   ZBUILD_MOCK_SUBTYPE    envelope .subtype     (default: error_max_turns)
#   ZBUILD_MOCK_NUM_TURNS  envelope .num_turns   (default: 25)
#   ZBUILD_MOCK_RESULT     envelope .result      (default: a partial-reasoning blurb)
#   ZBUILD_MOCK_RC         process exit code     (default: 1)
#   ZBUILD_MOCK_IS_ERROR   envelope .is_error    (default: true)
#
# Usage:
#   install_envelope_mock_claude_error                       # max_turns defaults
#   install_envelope_mock_claude_error --record-argv <path>  # also record argv
#   install_envelope_mock_claude_error --record-prompt <path> # also record -p prompt
#
# Flags may be combined. Mirrors install_envelope_mock_claude's recording hooks
# so resume/dogfood tests can assert the captured prompt across runs.
install_envelope_mock_claude_error() {
    local argv_record="" prompt_record=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --record-argv)   argv_record="$2"; shift 2 ;;
            --record-prompt) prompt_record="$2"; shift 2 ;;
            *)               shift ;;
        esac
    done
    mkdir -p "$TEST_TEMP_DIR/bin"
    local mock_bin="$TEST_TEMP_DIR/bin/claude"
    cat > "$mock_bin" <<MOCK
#!/usr/bin/env bash
# Auto-generated by install_envelope_mock_claude_error (#1052).
if [[ -n "${argv_record:-}" ]]; then
    printf '%s\n' "\$@" > "$argv_record"
fi
prompt_text=""
while [[ \$# -gt 0 ]]; do
    case "\$1" in
        -p) prompt_text="\${2:-}"; shift 2 ;;
        *)  shift ;;
    esac
done
if [[ -n "${prompt_record:-}" ]]; then
    printf '%s' "\$prompt_text" > "$prompt_record"
fi
# Tunable envelope fields — read at invocation time so a test can vary the
# shape per call without reinstalling the mock.
_subtype="\${ZBUILD_MOCK_SUBTYPE:-error_max_turns}"
_num_turns="\${ZBUILD_MOCK_NUM_TURNS:-25}"
_is_error="\${ZBUILD_MOCK_IS_ERROR:-true}"
_rc="\${ZBUILD_MOCK_RC:-1}"
_result="\${ZBUILD_MOCK_RESULT:-Explored core/ and plugins/ but ran out of turns before emitting a complete plan. Partial findings: the change touches the router and the plan plugin.}"
jq -n \\
    --arg st "\$_subtype" \\
    --argjson nt "\$_num_turns" \\
    --argjson ie "\$_is_error" \\
    --arg r "\$_result" \\
    '{type:"result",subtype:\$st,is_error:\$ie,num_turns:\$nt,result:\$r,usage:{input_tokens:0,output_tokens:0},tool_uses:[]}'
exit "\$_rc"
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
        # #1063 follow-up: record this file as skipped so run-tests.sh can report
        # skips distinctly. A skipped file exits 0 and would otherwise tally as a
        # PASS, hiding platform gating (e.g. #996's skip_on_platform macos shows up
        # as a confusing "172/172 passed" with no indication 8 tests were skipped).
        [[ -n "${ZBUILD_TEST_SKIP_LOG:-}" ]] \
            && printf '%s\n' "${0##*/}" >> "$ZBUILD_TEST_SKIP_LOG" 2>/dev/null || true
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

# ── Standard-pipeline roster: REMOVED (#979, EPIC #1277) ──────────────────────
# The _ZBUILD_STANDARD_ROSTER array + standard_stage_ids / standard_stage_count /
# register_standard_pipeline_stubs helpers were deleted when standard.yaml (the
# compound-quality lattice) was retired. They enumerated the now-deleted roster
# (test_assessment, cq-preflight/-audit-plan/-cycle/-backtrack, the old `review`
# stage) and had no remaining callers — the last one (runner-exports-state-dir-test)
# migrated to a minimal owned fixture in #1097. Tests that need a multi-stage stub
# set now build their own stubs inline or install a tests/fixtures/templates/*.yaml
# overlay (the #978/#1270 pattern).

# ── wait_for_event ────────────────────────────────────────────────────────────
# Bounded poll for a grep pattern to appear in an events/state file (#619's
# "wait-for-event-content" pattern; reused by #887/#1127/#1149). Replaces the
# anti-pattern of a fixed `sleep N` followed by a single-shot read of an
# event/state file — that races a slow CI box (the writer may not have flushed
# the line yet). This polls the file until the content appears, bounded by a
# generous timeout so a genuinely-never-emitted event still fails fast-enough
# instead of hanging.
#
# Usage: wait_for_event <file> <grep_pattern> [max_iters=600] [interval=0.1]
#   - <grep_pattern> is a basic-regex passed to `grep -q` (quote JSON fragments,
#     e.g. '"pipeline.start"').
#   - Default bound: 600 × 0.1s = 60s — generous enough for a loaded shared CI
#     runner, short enough to never wedge the suite.
# Returns 0 as soon as the pattern is present; 1 if the bound elapses first.
# Does NOT assert — callers decide whether a timeout is fatal so the failure
# message stays test-specific.
wait_for_event() {
    local file="$1" pattern="$2" max_iters="${3:-600}" interval="${4:-0.1}" i
    for (( i = 0; i < max_iters; i++ )); do
        if [[ -f "$file" ]] && grep -q "$pattern" "$file" 2>/dev/null; then
            return 0
        fi
        sleep "$interval"
    done
    return 1
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
    if found="$(jq -r --arg t "$event_type" 'select(.type == $t) | .type' "$events_file" 2>/dev/null)"; then
        found="${found%%$'\n'*}"
    else
        found=""
    fi
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

# ── install_template_overlay (#1270) ─────────────────────────────────────────
# Copy one or more template fixtures into a repo's per-repo override dir
# (<repo>/.zbuild/templates/<id>.yaml), the generic ADR-016 overlay seam. A test
# that then runs the engine with CWD = <repo> resolves the fixture WITHOUT any
# env var and WITHOUT writing into the tracked config/templates/ — the overlay
# lives entirely inside the test's temp repo (reaped by the master EXIT/INT/TERM
# trap). This replaces the #1268 ZBUILD_TEMPLATES_DIR seam (reverted in #1270):
# no ambient env, no global state; hermeticity comes from CWD isolation.
#
# Each fixture is a `.zbuild/templates/` overlay, so it MUST carry `extends: <id>`
# (ADR-016). The shipped base it extends (usually `simple`) is read from the
# engine tree unchanged — only the overlay id needs a fixture.
#
# Usage: install_template_overlay <repo> <id> [<id> ...]
install_template_overlay() {
    local _repo="$1"; shift
    # Fail fast on an empty repo arg (e.g. an unset OVERLAY_REPO): otherwise we'd
    # mkdir/cp into /.zbuild/templates and fail later with a confusing error.
    if [[ -z "$_repo" ]]; then
        echo "install_template_overlay: <repo> argument required (got empty)" >&2
        return 1
    fi
    mkdir -p "$_repo/.zbuild/templates"
    # Repo root derived from THIS helper's location (…/scripts/lib → repo root),
    # not the caller's cwd, so it resolves regardless of where the test runs.
    local _hdir _src_root
    _hdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _src_root="$(cd "$_hdir/../.." && pwd)"
    local _id _src
    for _id in "$@"; do
        _src="$_src_root/tests/fixtures/templates/${_id}.yaml"
        if [[ ! -f "$_src" ]]; then
            echo "install_template_overlay: fixture not found: $_src" >&2
            return 1
        fi
        cp "$_src" "$_repo/.zbuild/templates/${_id}.yaml"
    done
}

# install_template_overlay_committed <repo> <id> [<id> ...]
# Like install_template_overlay, but COMMITS the overlay into the repo's git
# HEAD. Needed when the runner (or a nested runner) rsyncs the repo and runs
# `git checkout HEAD -- . && git clean -fdq`, which would wipe an untracked
# overlay (state-root-isolation section F, SPEC-7).
install_template_overlay_committed() {
    local _repo="$1"
    install_template_overlay "$@" || return 1
    local real_git
    real_git="$(command -v git 2>/dev/null || true)"
    if [[ -z "$real_git" ]]; then
        for c in /usr/bin/git /usr/local/bin/git /opt/homebrew/bin/git; do
            [[ -x "$c" ]] && real_git="$c" && break
        done
    fi
    [[ -z "$real_git" ]] && { echo "install_template_overlay_committed: git not found" >&2; return 1; }
    "$real_git" -C "$_repo" add .zbuild/templates >/dev/null 2>&1 || return 1
    "$real_git" -C "$_repo" commit -q -m "add test template overlay" >/dev/null 2>&1 || return 1
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
    local sdir="\${ZBUILD_STATE_DIR:-\${ZBUILD_STATE_ROOT:-\$HOME/.zbuild/state}}"
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
if grep -q 'anthropic' <<< "$(printf '%s\n' "$@")"; then
  echo "[mock] ERROR: direct anthropic API call detected — must go through core/redaction" >&2
  exit 1
fi
exec /usr/bin/curl "$@"
MOCKEOF
  chmod +x "$mock_dir/curl"
  export PATH="$mock_dir:$PATH"
}

# ─── zb_expected_run_state_dir <repo_dir> <issue> <goal> <run_id> ────────────
# The state dir a run WILL use, derived from the SAME resolver the writer uses
# (#141, ADR-059 §1) rather than by hardcoding a layout shape.
#
# Six integration tests pinned `<state_root>/runs/<run_id>` as a literal. That
# made them assertions about the SHAPE of the layout rather than about the
# isolation property each was actually written to prove — so the #141 move broke
# all six at once while none of them was testing the thing that moved. Deriving
# the path keeps each test pinned to its own property and lets the layout change
# again without a six-file sweep.
#
# Honours the caller's HOME / ZBUILD_*_ROOT, and runs with cwd = <repo_dir>
# because the repo segment comes from that repo's git remote.
zb_expected_run_state_dir() {
    local repo="${1:-}" issue="${2:-}" goal="${3:-}" rid="${4:-}"
    local root; root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    (
        cd "$repo" 2>/dev/null || exit 1
        # shellcheck source=../../core/state/layout.sh
        source "$root/core/state/layout.sh" || exit 1
        # shellcheck source=./identity.sh
        source "$root/scripts/lib/identity.sh" || exit 1
        local key=""
        key="$(zbuild_run_key "$issue" "$goal" 2>/dev/null || true)"
        zbuild_layout_run_state_dir "$key" "$rid"
    )
}
