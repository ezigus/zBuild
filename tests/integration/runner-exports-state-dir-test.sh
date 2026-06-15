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

# Plain pass-through stubs for the non-capturing stages.
_make_plugin() { mock_plugin_factory "$@"; }

_make_plugin "intake"          "agent" 0 >/dev/null
_make_plugin "plan"            "agent" 0 >/dev/null
# #842: standard template now includes impact inside design_impact_cycle.
_make_plugin "impact"          "agent" 0 >/dev/null
# #842: design is a cycle member of design_impact_cycle (before review_cycle).
_make_plugin "design"          "agent" 0 >/dev/null
_make_capture_plugin "build"   "agent"
_make_plugin "test"            "tool"  0 >/dev/null
_make_plugin "test_assessment" "agent" 0 >/dev/null
# #755: standard review_cycle.flow now includes 4 compound_quality stages
# between build_test_cycle and review.
_make_plugin "cq-preflight"    "agent" 0 >/dev/null
_make_plugin "cq-audit-plan"   "agent" 0 >/dev/null
_make_plugin "cq-cycle"        "agent" 0 >/dev/null
_make_plugin "cq-backtrack"    "agent" 0 >/dev/null
_make_plugin "review"          "agent" 0 >/dev/null

# ─── Run the runner end-to-end ──────────────────────────────────────────────
rm -f "$EVENTS_JSONL" "$STATE_DIR/pipeline-state.json" "$ENV_CAPTURE"
# Invoke with ZBUILD_STATE_DIR EXPLICITLY UNSET in the runner's env: this
# proves the runner itself exports the variable (vs the parent shell leaking
# it through). The runner will compute state_dir from $HOME/.zbuild/state.
mkdir -p "$TEST_TEMP_DIR/home/.zbuild"
set +e
env -u ZBUILD_STATE_DIR \
    ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" \
    ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events" \
    ZBUILD_EVENTS_JSONL="$EVENTS_JSONL" \
    ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db" \
    ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
    ZBUILD_CYCLES_ENABLED=0 \
    ZBUILD_RUN_ID="run-618" \
    HOME="$TEST_TEMP_DIR/home" \
    PATH="$PATH" \
    bash "$RUNNER" --issue 618 >/dev/null 2>&1
rc=$?
set -e
# #887: with ZBUILD_STATE_DIR unset, a fresh run roots state under
# $HOME/.zbuild/state/runs/<run_id>/ (per-run isolation). run_id is pinned above.
EXPECTED_STATE_DIR="$TEST_TEMP_DIR/home/.zbuild/state/runs/run-618"

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
