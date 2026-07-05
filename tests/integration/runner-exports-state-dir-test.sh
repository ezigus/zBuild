#!/usr/bin/env bash
# Tests: core/pipeline/runner.sh exports ZBUILD_STATE_DIR so child plugins
# (including the route_to_model_loop branch-state injection from #617) can
# read $ZBUILD_STATE_DIR/intake-baseline-ref.txt. (#618)
#
# Before #618 the runner exported ZBUILD_RUN_ID / ZBUILD_ISSUE / ZBUILD_GOAL
# but NOT ZBUILD_STATE_DIR — so child plugins saw an unset var, the route
# loop silently skipped the "## BRANCH STATE since intake" block, and
# dogfood iter prompts never carried branch-cumulative context.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER="$REPO_ROOT/core/pipeline/runner.sh"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "runner: exports ZBUILD_STATE_DIR to child plugins (#618)"
setup_test_env "runner-618-export-state-dir"
# Wave 12-E (#664): default is enforce. This test uses synthetic stub
# plugins without honest inputs/outputs blocks; opt out of contract
# validation since the assertions target runner mechanics, not contracts.
export ZBUILD_CONTRACT_VALIDATOR=warn

# ─── Shared env: point all subsystems at the test temp dir ──────────────────
PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
STATE_DIR="$TEST_TEMP_DIR/state"
EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
ENV_CAPTURE="$TEST_TEMP_DIR/env-capture.txt"

export ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT"
export ZBUILD_STATE_DIR="$STATE_DIR"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$EVENTS_JSONL"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
# Force-disable cycle dispatch — this test asserts linear-stage env propagation.
export ZBUILD_CYCLES_ENABLED=0
mkdir -p "$STATE_DIR" "$TEST_TEMP_DIR/events"

# ─── Stub plugins ────────────────────────────────────────────────────────────
# All stages succeed; the BUILD stub captures its env to a file so we can
# assert ZBUILD_STATE_DIR was exported by the runner.
_make_capture_plugin() {
    local id="$1" kind="${2:-agent}"
    local dir="$PLUGINS_ROOT/$kind/$id"
    mkdir -p "$dir"
    local fn; fn="${id//-/_}_run"
    cat > "$dir/manifest.yaml" <<EOF
id: $id
name: Capture $id
kind: $kind
version: 0.0.1
hooks:
  run: $fn
requires:
  core:
    - redaction
EOF
    cat > "$dir/plugin.sh" <<EOF
${fn}() {
    env | grep '^ZBUILD_' > "$ENV_CAPTURE" 2>/dev/null || true
    return 0
}
EOF
}

# #1097 (PC4): the env-export behavior under test is NOT stage-count
# dependent, so we drive the runner with a MINIMAL two-leaf template
# (intake → build) instead of the full ~14-stage standard roster — the prior
# register_standard_pipeline_stubs path ran every standard stage just to reach
# the build env-capture, dominating the ~21s runtime. We install the fixture
# into config/templates/ for the duration of the test (same mechanism as
# pipeline-preflight-missing-stage-test.sh) and invoke with --template below.
MINIMAL_TEMPLATE_SRC="$REPO_ROOT/tests/fixtures/templates/runner-state-dir-minimal.yaml"
MINIMAL_TEMPLATE_INSTALLED="$REPO_ROOT/config/templates/runner-state-dir-minimal.yaml"
cp "$MINIMAL_TEMPLATE_SRC" "$MINIMAL_TEMPLATE_INSTALLED"
# Removes the installed fixture even on Ctrl-C / signal exit. Temp-dir cleanup
# is handled by the explicit cleanup_test_env at the end + the harness master
# trap, so this hook is scoped to the fixture file only.
_test_cleanup_hook() {
    rm -f "$MINIMAL_TEMPLATE_INSTALLED" 2>/dev/null || true
}

# intake is the only non-capture stage in the minimal roster; build is then
# overridden with the env-capture plugin (the test's assertion mechanism).
mock_plugin_factory "intake" "agent" 0 "" "" >/dev/null
_make_capture_plugin "build"   "agent"

# ─── Run the runner end-to-end ──────────────────────────────────────────────
rm -f "$EVENTS_JSONL" "$STATE_DIR/pipeline-state.json" "$ENV_CAPTURE"
# Invoke with ZBUILD_STATE_DIR EXPLICITLY UNSET in the runner's env: this
# proves the runner itself exports the variable (vs the parent shell leaking
# it through). The runner will compute state_dir from $HOME/.zbuild/state.
mkdir -p "$TEST_TEMP_DIR/home/.zbuild"
ZBUILD_RUN_ID="run-618-$$"
set +e
# #1240: also scrub ZBUILD_STATE_ROOT. This is a DEFAULT-STATE test — it pins
# HOME and expects state under $HOME/.zbuild/state/runs/<id>/. When run nested
# inside the pipeline test stage, the #1127 sandbox fences state via an ambient
# ZBUILD_STATE_ROOT=<tmp>/.zbuild-nested-state; if it leaks in, the runner
# (correctly) re-roots there instead of HOME and the assertion breaks. Unset it
# so the default-state baseline is deterministic regardless of caller env.
env -u ZBUILD_STATE_DIR -u ZBUILD_STATE_ROOT \
    ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" \
    ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events" \
    ZBUILD_EVENTS_JSONL="$EVENTS_JSONL" \
    ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db" \
    ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
    ZBUILD_CYCLES_ENABLED=0 \
    ZBUILD_RUN_ID="$ZBUILD_RUN_ID" \
    HOME="$TEST_TEMP_DIR/home" \
    PATH="$PATH" \
    bash "$RUNNER" --issue 618 --template runner-state-dir-minimal >/dev/null 2>&1
rc=$?
set -e
# #887: with ZBUILD_STATE_DIR unset, a fresh run roots state under
# $HOME/.zbuild/state/runs/<run_id>/ (per-run isolation). run_id derived from $$, not hardcoded.
EXPECTED_STATE_DIR="$TEST_TEMP_DIR/home/.zbuild/state/runs/$ZBUILD_RUN_ID"

assert_eq "runner exits 0" "0" "$rc"
assert_file_exists "build stub captured its env" "$ENV_CAPTURE"

captured="$(cat "$ENV_CAPTURE" 2>/dev/null || echo)"

# Headline assertion: ZBUILD_STATE_DIR present in the child env.
if [[ "$captured" == *"ZBUILD_STATE_DIR="* ]]; then
    assert_pass "child plugin env contains ZBUILD_STATE_DIR"
else
    assert_fail "child plugin env contains ZBUILD_STATE_DIR" \
        "captured env: $(printf '%s' "$captured" | tr '\n' '|' | head -c 400)"
fi

# Value should match the state dir the runner computed (default $HOME/.zbuild/state).
expected_line="ZBUILD_STATE_DIR=$EXPECTED_STATE_DIR"
if [[ "$captured" == *"$expected_line"* ]]; then
    assert_pass "ZBUILD_STATE_DIR value matches runner's state_dir"
else
    assert_fail "ZBUILD_STATE_DIR value matches runner's state_dir" \
        "expected substring: $expected_line; got: $(printf '%s' "$captured" | tr '\n' '|' | head -c 400)"
fi

# Sanity: the pre-existing exports are still there (regression guard).
for var in ZBUILD_RUN_ID ZBUILD_ISSUE ZBUILD_GOAL; do
    if [[ "$captured" == *"$var="* ]]; then
        assert_pass "child plugin env still contains $var (regression)"
    else
        assert_fail "child plugin env still contains $var (regression)" \
            "missing from captured env"
    fi
done

cleanup_test_env
print_test_results
exit $((FAIL > 0))
