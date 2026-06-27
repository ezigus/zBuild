#!/usr/bin/env bash
# Tests: plugins/tool/objective-gate stage-io banner (issue #1115, ADR-015).
#
# objective_gate_run historically ran the suite + lint as `bash -c "$cmd"
# >/dev/null 2>&1`, bypassing the ADR-015 stage-io chokepoint — so the most
# expensive command in the pipeline (~13 min) ran with NO operator banner.
# These cases assert that the suite run (and the lint run) now emit a matching
# `objective-gate [command] ... input` / `... output` banner pair, that the
# verdict + a short summary reach the OUTPUT banner, and that the additive
# observability did NOT weaken the hard gate (suite failure still rc=1).
#
# The banner fd (ZBUILD_STAGE_IO_FD=3) must be open at stage-io.sh source time
# (the module's source-time fd validation refuses a closed fd), so each case is
# driven through a fresh subprocess whose fd 3 is redirected to a per-case file.
# template_stage_io_dests is overridden AFTER plugin.sh sources so the
# objective-gate stage reports destinations even without a loaded template.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "objective-gate stage-io banner — command-kind capture (#1115)"
setup_test_env "objective-gate-stage-io-banner"

_test_cleanup_hook() { cleanup_test_env; }

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

# Drive objective_gate_run in a subprocess with the banner fd (3) redirected to
# <banner_out>. Sets ZBUILD_TEST_CMD/ZBUILD_LINT_CMD from args; coverage/diff are
# stubbed (true) so the ablation gates skip. Echoes nothing; writes the banner.
# Usage: _run_case <label> <test_cmd> <lint_cmd> <banner_out>; sets _case_rc.
_run_case() {
    local label="$1" test_cmd="$2" lint_cmd="$3" banner_out="$4"
    : > "$banner_out"
    local case_state_dir="$TEST_TEMP_DIR/state-${label}"
    mkdir -p "$case_state_dir/artifacts" "$case_state_dir/state/artifacts/stage-io"
    local state_file="$case_state_dir/state.json"
    printf '{"issue":"1115"}\n' > "$state_file"

    # The suite/lint commands may contain single quotes, so they are NOT embedded
    # in the driver heredoc (that would break shell quoting). They are passed
    # through the environment of the `bash "$driver"` invocation below.
    local driver="$TEST_TEMP_DIR/driver-${label}.sh"
    cat > "$driver" <<EOF
set -uo pipefail
export ZBUILD_STAGE_IO_FD=3
export ZBUILD_TERM_WIDTH_OVERRIDE=100
export NO_COLOR=1
export ZBUILD_EVENTS_DIR="$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_JSONL"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DB"
export ZBUILD_EVENT_SCHEMA="$ZBUILD_EVENT_SCHEMA"
export ZBUILD_STATE_DIR="$case_state_dir/state"
export ZBUILD_COVERAGE_CMD=true
export ZBUILD_DIFF_CMD=true
export PATH="$PATH"
source "$REPO_ROOT/plugins/tool/objective-gate/plugin.sh"
# Force io: destinations for objective-gate without loading a template, so the
# banner actually renders to fd 3. Defined AFTER the source so it wins at runtime.
template_stage_io_dests() {
    case "\$1" in objective-gate) printf 'file\nstdout\n' ;; *) return 0 ;; esac
}
template_stage_io_tail_lines() { printf '50'; }
template_stage_io_redact() { printf ''; }
objective_gate_run "objective-gate" "$state_file"
EOF
    set +e
    ZBUILD_TEST_CMD="$test_cmd" ZBUILD_LINT_CMD="$lint_cmd" \
        bash "$driver" 3>"$banner_out" 2>/dev/null
    _case_rc=$?
    set -e
}

# ─── SPEC-1: passing suite emits a matched input/output banner pair ──────────
# CHANGE: at merge-base the suite ran `>/dev/null 2>&1` → no banner at all.
BANNER_PASS="$TEST_TEMP_DIR/banner-pass.txt"
_run_case pass "printf '%s\\n' 'unit: 12/12 passed'" "true" "$BANNER_PASS"
_banner_pass="$(cat "$BANNER_PASS")"

assert_eq "[SPEC-1] gate rc=0 when suite + lint pass" "0" "$_case_rc"
assert_contains "[SPEC-1] suite INPUT banner emitted for objective-gate" \
    "$_banner_pass" "objective-gate [command] seq=1 input"
assert_contains "[SPEC-1] suite OUTPUT banner emitted for objective-gate" \
    "$_banner_pass" "objective-gate [command] seq=1 output"

# ─── SPEC-2: OUTPUT banner carries the verdict + the suite summary line ──────
assert_contains "[SPEC-2] suite OUTPUT banner shows verdict=pass" \
    "$_banner_pass" "verdict=pass"
assert_contains "[SPEC-2] suite OUTPUT banner lifts the suite summary line" \
    "$_banner_pass" "unit: 12/12 passed"

# ─── SPEC-3: the lint run emits its OWN banner pair (distinct seq) ───────────
# CHANGE: lint also ran `>/dev/null 2>&1` at merge-base. Now both commands are
# captured; the lint pair reserves seq=2 (suite's seq=1 finalized to disk).
assert_contains "[SPEC-3] lint INPUT banner emitted (second command, seq=2)" \
    "$_banner_pass" "objective-gate [command] seq=2 input"
assert_contains "[SPEC-3] lint OUTPUT banner emitted (second command, seq=2)" \
    "$_banner_pass" "objective-gate [command] seq=2 output"

# ─── SPEC-4: hard gate intact — suite failure still rc=1 AND banners emit ────
# GUARD: the banner is additive observability only; it must not weaken the gate.
BANNER_FAIL="$TEST_TEMP_DIR/banner-fail.txt"
_run_case fail "printf '%s\\n' 'unit: 9/12 FAILED'; exit 1" "true" "$BANNER_FAIL"
_banner_fail="$(cat "$BANNER_FAIL")"

assert_eq "[SPEC-4] gate still hard-blocks (rc=1) on suite failure" "1" "$_case_rc"
assert_contains "[SPEC-4] suite INPUT banner still emitted on failure" \
    "$_banner_fail" "objective-gate [command] seq=1 input"
assert_contains "[SPEC-4] suite OUTPUT banner shows verdict=fail on failure" \
    "$_banner_fail" "verdict=fail"

# ─── Results ─────────────────────────────────────────────────────────────────
print_test_results
exit $((FAIL > 0))
