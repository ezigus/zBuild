#!/usr/bin/env bash
# Tests: plugins/tool/test stage-io banner — golden snapshots (#497).
#
# Pins ZBUILD_STAGE_IO_NOW_MS_OVERRIDE (fixes HH:MM:SS UTC and banner-heading
# time) and ZBUILD_TERM_WIDTH_OVERRIDE (fixes dash-padding) so the banner
# stream is byte-stable. tmp paths in the input section (printed as the
# %q-encoded test_cmd → file path) are sanitized to <TMP_CMD> before diff.
# Duration line in the banner heading is rendered from --duration-ms we
# pass through; we don't have control over the wall delta so we sanitize
# the duration field in the banner heading too.
#
# Three goldens: pass / fail / error (apply-fail). The #485 no-op case and
# the "error: <first line>" branch are exercised by the in-plugin unit tests
# (plugins/tool/test/tests/test-test.sh tests 9a, 9, 11).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
source "$REPO_ROOT/scripts/lib/golden.sh"

print_test_header "test-stage banner — deterministic goldens (#497)"
setup_test_env "test-stage-banner-golden"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR/artifacts/stage-io"

ARTIFACT_DIR="$TEST_TEMP_DIR/artifacts"
mkdir -p "$ARTIFACT_DIR"
export ZBUILD_ARTIFACT_DIR="$ARTIFACT_DIR"

# Minimal git repo for `git apply` context.
mkdir -p "$TEST_TEMP_DIR/repo"
git -C "$TEST_TEMP_DIR/repo" init -q
git -C "$TEST_TEMP_DIR/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
export ZBUILD_REPO_ROOT="$TEST_TEMP_DIR/repo"

# Empty diff.patch (apply --check --allow-empty accepts it).
GOOD_PATCH="$ARTIFACT_DIR/diff.patch"
: > "$GOOD_PATCH"

# Mock git: always-pass apply (default). The error-case driver swaps in a
# failing version per test before invoking.
cat > "$TEST_TEMP_DIR/bin/git" <<'GITEOF'
#!/usr/bin/env bash
args=("$@")
[[ "${args[0]:-}" == "-C" ]] && args=("${args[@]:2}")
case "${args[0]:-}" in
    apply) exit 0 ;;
    *) exec "$(PATH=/usr/bin:/usr/local/bin:/opt/homebrew/bin command -v git)" "$@" ;;
esac
GITEOF
chmod +x "$TEST_TEMP_DIR/bin/git"

# Sanitizer: strip / pin volatile fields so byte-comparison is stable.
#   - HH:MM:SS UTC stamps on banner heading (we DO pin via override, but the
#     `── … ──── HH:MM:SS UTC ──` padding length depends on the prefix's
#     visible length which is byte-stable).
#   - tmp paths in input + cwd metadata → <TMP_CMD>
#   - duration on the heading → <DUR>
_sanitize() {
    local s="$1"
    # Replace any /tmp/... or /var/folders/... or $TMPDIR-style path with <TMP>.
    # The %q-encoded test_cmd will contain the mock script's absolute path.
    # ADR-058 §3 points TMPDIR at ${state_dir}/scratch/<stage>/ for the span of a
    # dispatch, so under a live run the harness root matches neither shape below.
    # Normalising TEST_TEMP_DIR itself is location-independent; the two path-shape
    # rules stay as a fallback for anything mktemp'd outside the harness root.
    if [[ -n "${TEST_TEMP_DIR:-}" ]]; then
        s="${s//"$TEST_TEMP_DIR"/@@TMPROOT@@}"
    fi
    s="$(printf '%s' "$s" | sed -E \
        -e 's|@@TMPROOT@@[^ ]*|<TMP>|g' \
        -e 's|/var/folders/[^ ]+|<TMP>|g' \
        -e 's|/tmp/[^ ]+|<TMP>|g')"
    # Heading duration (always at the same column, format "N.Ns").
    # Match the segment "output OK <dur>" or "output FAIL <dur>" exactly.
    s="$(printf '%s' "$s" | sed -E \
        -e 's/(output (OK|FAIL)) [0-9]+\.[0-9]s/\1 <DUR>/g')"
    printf '%s' "$s"
}

# Driver: run _test_run_inner with banner stream redirected to a per-case file.
_run_case() {
    local label="$1" patch="$2" out_json="$3" test_cmd="$4" banner_out="$5"
    : > "$banner_out"
    # Per-case state dir so the seq reservation (which counts prior on-disk
    # records under stage-io/) always returns 1 — keeps goldens uncluttered.
    local case_state="$TEST_TEMP_DIR/state-${label}"
    mkdir -p "$case_state/artifacts/stage-io"
    # Drive via a fresh subprocess so stage-io.sh's source-time fd validation
    # (refuses ZBUILD_STAGE_IO_FD pointing at a closed fd) sees fd 3 already
    # open. The parent process here doesn't own fd 3, so an in-shell subshell
    # would fail validation.
    local driver="$TEST_TEMP_DIR/driver-${label}.sh"
    cat > "$driver" <<EOF
set -uo pipefail
export ZBUILD_STAGE_IO_NOW_MS_OVERRIDE=12345000
export ZBUILD_TERM_WIDTH_OVERRIDE=100
export ZBUILD_STAGE_IO_FD=3
export ZBUILD_EVENTS_DIR="$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_JSONL"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DB"
export ZBUILD_EVENT_SCHEMA="$ZBUILD_EVENT_SCHEMA"
export ZBUILD_STATE_DIR="$case_state"
export ZBUILD_ARTIFACT_DIR="$ZBUILD_ARTIFACT_DIR"
export ZBUILD_REPO_ROOT="$ZBUILD_REPO_ROOT"
export PATH="$PATH"
source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/core/event-bus/event-bus.sh"
source "$REPO_ROOT/core/pipeline/template.sh"
template_stage_io_dests() {
    case "\$1" in test) printf 'file\nstdout\n' ;; *) return 0 ;; esac
}
template_stage_io_tail_lines() { printf '5'; }
template_stage_io_redact() { printf ''; }
source "$REPO_ROOT/core/output/stage-io.sh"
source "$REPO_ROOT/plugins/tool/test/plugin.sh"
hash -r
_test_run_inner "$patch" "$ZBUILD_REPO_ROOT" "$out_json" "$test_cmd"
EOF
    bash "$driver" 3>"$banner_out" 2>/dev/null
}

# Pinned-output mock test_cmd helpers.
mkdir -p "$TEST_TEMP_DIR/bin"
cat > "$TEST_TEMP_DIR/bin/mock-pass.sh" <<'MOCK'
#!/usr/bin/env bash
echo "Tests:       0 failed, 47 passed, 47 total"
exit 0
MOCK
cat > "$TEST_TEMP_DIR/bin/mock-fail.sh" <<'MOCK'
#!/usr/bin/env bash
echo "Tests:       3 failed, 44 passed, 47 total"
exit 1
MOCK
chmod +x "$TEST_TEMP_DIR/bin/mock-pass.sh" "$TEST_TEMP_DIR/bin/mock-fail.sh"

# ─── G1: pass golden ──────────────────────────────────────────────────────────
BANNER_P="$TEST_TEMP_DIR/banner-pass.txt"
_run_case pass "$GOOD_PATCH" "$ARTIFACT_DIR/r-pass.json" \
    "$TEST_TEMP_DIR/bin/mock-pass.sh" "$BANNER_P"
banner_pass="$(_sanitize "$(cat "$BANNER_P")")"
set +e
assert_golden "test-stage-banner-pass" "$banner_pass"
g1=$?
set -e
[[ $g1 -eq 0 ]] && assert_pass "G1: pass-case banner matches golden" \
    || assert_fail "G1: pass-case banner matches golden" "golden diff (rc=$g1)"

# ─── G2: fail golden ──────────────────────────────────────────────────────────
BANNER_F="$TEST_TEMP_DIR/banner-fail.txt"
_run_case fail "$GOOD_PATCH" "$ARTIFACT_DIR/r-fail.json" \
    "$TEST_TEMP_DIR/bin/mock-fail.sh" "$BANNER_F"
banner_fail="$(_sanitize "$(cat "$BANNER_F")")"
set +e
assert_golden "test-stage-banner-fail" "$banner_fail"
g2=$?
set -e
[[ $g2 -eq 0 ]] && assert_pass "G2: fail-case banner matches golden" \
    || assert_fail "G2: fail-case banner matches golden" "golden diff (rc=$g2)"

# ─── G3 removed (#602): apply-fail path no longer reachable. ─────────────────
# The test plugin no longer runs `git apply` — the build's WT edits arrive via
# rsync intact. There is no diff_apply_failed verdict surface to snapshot.

cleanup_test_env
print_test_results
exit $((FAIL > 0))
