#!/usr/bin/env bash
# Integration test (ADR-025 / Wave 15-B #684): the runner's SIGINT trap
# composes additively to:
#   1. arm the cross-subshell abort sentinel (Layer 2);
#   2. set _RUNNER_SIGINT_RECEIVED=1 (existing #612 behavior);
#   3. exit 130 (triggering _runner_abort_trap EXIT);
#   4. the EXIT trap emits `pipeline.aborted reason=sigint` AND disarms
#      the sentinel so the next zbuild invocation in the same state dir
#      does not see a stale signal.
#
# This test simulates the kernel-pgroup SIGINT path the way #612 already
# does: by having a mock plugin return rc=130 directly. The new
# assertions (vs #612's sigint-aborts-pipeline-test.sh) target Wave 15-B
# specifics: the sentinel file lifecycle and the runner's linear-loop
# pre-flight bail.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER="$REPO_ROOT/core/pipeline/runner.sh"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "full-pipeline SIGINT (ADR-025 sentinel + propagation, #684)"
setup_test_env "full-pipeline-sigint-w15b"
export ZBUILD_CONTRACT_VALIDATOR=warn
_test_cleanup_hook() {
    if [[ "${KEEP_TMP:-0}" == "1" ]]; then
        echo "KEEPTEMP=$TEST_TEMP_DIR" >&2
    else
        cleanup_test_env
    fi
}

PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
STATE_DIR="$TEST_TEMP_DIR/state"
EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT"
export ZBUILD_STATE_DIR="$STATE_DIR"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$EVENTS_JSONL"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_CYCLES_ENABLED=0
mkdir -p "$STATE_DIR" "$TEST_TEMP_DIR/events"

# Throwaway git repo so plugins that touch git don't fail on init.
REPO="$TEST_TEMP_DIR/work-repo"
mkdir -p "$REPO"
( cd "$REPO" \
    && git init -q \
    && git config user.email t@t \
    && git config user.name t \
    && echo seed > seed.txt \
    && git add seed.txt \
    && git commit -q -m seed ) >/dev/null
export ZBUILD_SCOPE_OVERRIDE=1
mkdir -p "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"

# #978: this SIGINT-propagation contract is roster-agnostic — it only needs a
# stage BEFORE build (intake), the build stage that returns rc=130, and a stage
# AFTER build (test) to prove the abort halts the linear loop before test runs.
# Drive a MINIMAL 3-leaf fixture (intake → build → test) instead of pinning to
# the standard roster (retired in #979). resume-minimal declares NO roles[], so
# the runner resolves each stage by ID and dispatches via plugin_hook_call,
# preserving the build stub's exact rc=130 (routing through the role/fanout path
# would collapse 130→1 — see the fixture header). #1270: install the fixture as a
# per-repo `.zbuild/templates/` overlay in a temp repo and run with CWD = that
# repo (the resolver reads the overlay from $PWD); nothing touches the tracked
# config/templates/ and the temp repo is reaped by the master trap.
OVERLAY_REPO="$(setup_git_temp_repo tpl-overlay-repo)"
install_template_overlay "$OVERLAY_REPO" resume-minimal
mock_plugin_factory "intake" "agent" 0 >/dev/null
mock_plugin_factory "build"  "agent" 0 >/dev/null
mock_plugin_factory "test"   "tool"  0 >/dev/null

# Override the build plugin to (a) arm the sentinel directly (simulating
# the runner's INT trap that fired in a sibling subshell), (b) return
# rc=130 so the rc-propagation path AND the sentinel pre-flight both
# have something to assert against.
cat > "$PLUGINS_ROOT/agent/build/plugin.sh" <<PLUG
build_run() {
    : > "${STATE_DIR}/.abort.signal"
    return 130
}
PLUG

# Probe: tag a sentinel-touched file so we can verify whether the runner
# EVER attempts the test stage after build returns 130. The legacy
# linear-loop already returned 130 on rc=130; our new pre-flight makes
# that bail BEFORE spawning test, which we can observe via stage events.
# Replace the test plugin to write a marker if it ever runs.
TEST_MARKER="$TEST_TEMP_DIR/test-stage-ran-marker"
cat > "$PLUGINS_ROOT/tool/test/plugin.sh" <<PLUG
test_run() {
    : > "${TEST_MARKER}"
    return 0
}
PLUG

start_ts=$(date +%s)
set +e
# #1270: CWD = overlay repo so the resolver finds the resume-minimal fixture.
( cd "$OVERLAY_REPO" && bash "$RUNNER" --template resume-minimal --goal "w15b sentinel + rc chain" ) \
    >"$TEST_TEMP_DIR/runner.stdout" 2>"$TEST_TEMP_DIR/runner.stderr"
runner_rc=$?
set -e
end_ts=$(date +%s)
elapsed=$(( end_ts - start_ts ))

# ─── Assertions ─────────────────────────────────────────────────────────────

print_test_section "T1: runner exits rc=130 distinctly (SIGINT chain)"
assert_eq "runner rc=130" "130" "$runner_rc"

print_test_section "T2: pipeline halts within 6s (no further iterations)"
# Budget matches the #612 sigint-aborts-pipeline-test baseline; with the
# fix the runner halts on the first stage rc=130 instead of iterating.
#
# Originally 4s; bumped to 6s on #727; bumped to 8s on #766 because:
#   1. date(1) granularity is 1s → boundary cases (4.5s wall) tip to 5s
#   2. Wave 19 (template-resolver, two-channel verdict, recursive seq-prefix)
#      added ~1s of runner startup overhead under GHA's slower runners
#   3. #754 added the design stage to standard.yaml — one extra plugin
#      lookup per pipeline-start adds ~0.5s on GHA's slower runners.
#   4. The test's intent is "halt FAST, not iterate" — 8s still proves
#      single-stage abort vs. multi-iter (which would be 30s+).
#   5. #1059: relaxed to a hang-backstop ≤60s — the single-stage-abort proof
#      is the TEST_MARKER-absence + single pipeline.aborted assertions, not the
#      tight wall-clock (which flaked on the macOS matrix).
if [[ "$elapsed" -le 60 ]]; then
    assert_pass "pipeline halted in ${elapsed}s"
else
    assert_fail "pipeline halted in ≤60s" "actual=${elapsed}s"
fi

print_test_section "T3: test stage never starts (build rc=130 halts linear loop)"
if [[ -e "$TEST_MARKER" ]]; then
    assert_fail "test stage did not run after build rc=130" \
        "marker file present at $TEST_MARKER"
else
    assert_pass "test stage did not run after build rc=130"
fi

print_test_section "T4: pipeline.aborted reason=sigint event emitted"
if grep -q '"type":"pipeline.aborted".*sigint' "$EVENTS_JSONL" 2>/dev/null; then
    assert_pass "pipeline.aborted reason=sigint emitted"
else
    assert_fail "pipeline.aborted reason=sigint emitted" \
        "events tail: $(tail -c 800 "$EVENTS_JSONL" 2>/dev/null)"
fi

print_test_section "T5: sentinel removed by EXIT trap (no stale .abort.signal)"
# _runner_abort_trap should disarm the sentinel after emitting the event.
if [[ -e "$STATE_DIR/.abort.signal" ]]; then
    assert_fail "sentinel removed by EXIT trap" \
        "stale file present: $STATE_DIR/.abort.signal"
else
    assert_pass "sentinel removed by EXIT trap"
fi

print_test_section "T6: pipeline-state status=interrupted"
state_file="$STATE_DIR/pipeline-state.json"
if [[ -f "$state_file" ]]; then
    status="$(jq -r '.status // "MISSING"' "$state_file" 2>/dev/null || echo MISSING)"
    assert_eq "status=interrupted" "interrupted" "$status"
else
    assert_fail "pipeline-state.json exists" "missing: $state_file"
fi

print_test_results
exit $((FAIL > 0))
