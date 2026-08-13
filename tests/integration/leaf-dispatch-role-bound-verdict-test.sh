#!/usr/bin/env bash
# Integration: a role-bound leaf stage reports its REAL verdict (#1770).
#
# The unit test beside this one (leaf-dispatch-verdict-resolution-parity-test.sh)
# proves the two resolvers behave differently and greps runner.sh for the fixed
# call. Neither drives the leaf loop, so both survive a revert of the behaviour:
# the resolver assertions still hold, and a grep is a claim about source text,
# not about what a run emits. #1770 is precisely a defect where the source looked
# fine and the emitted verdict was wrong, so it has to be pinned where the
# verdict is actually produced.
#
# This runs the real runner over a one-stage template whose flow name differs
# from the plugin id and is bound by role, then reads the emitted event.
#
# SPEC-4 [change]: stage.complete for a role-bound leaf carries the plugin's real
#   verdict. At the merge-base the leaf loop resolves id-only, finds nothing,
#   and runner_read_stage_verdict returns "unknown" on the empty manifest.
# SPEC-5 [change]: the same verdict is persisted to .stage_verdicts, which is
#   what gates, resume and dashboards actually read.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "leaf dispatch — a role-bound stage reports its real verdict (#1770)"
setup_test_env "leaf-role-verdict"

RUNNER="$REPO_ROOT/core/pipeline/runner.sh"
PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
STATE_DIR="$TEST_TEMP_DIR/state"
EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"

export ZBUILD_CONTRACT_VALIDATOR=warn
export ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT"
export ZBUILD_STATE_DIR="$STATE_DIR"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$EVENTS_JSONL"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_CYCLES_ENABLED=0
mkdir -p "$STATE_DIR" "$TEST_TEMP_DIR/events"

# ─── The divergence under test ──────────────────────────────────────────────
# Stage name in the flow: `role-bound-leaf`. Plugin id: `rbl-provider`. They do
# not match, so an id-only lookup finds nothing; only the role binding resolves.
STAGE_NAME="role-bound-leaf"
PLUGIN_ID="rbl-provider"
ROLE="rbl_role"

_dir="$PLUGINS_ROOT/tool/$PLUGIN_ID"
mkdir -p "$_dir"
cat > "$_dir/manifest.yaml" <<EOF
id: $PLUGIN_ID
name: $PLUGIN_ID
kind: tool
version: 0.0.1
hooks:
  run: rbl_provider_run
requires:
  core: [event-bus]
provides:
  role: $ROLE
inputs: []
outputs:
  - id: rbl_out
    path: \${artifact_dir}/rbl-result.json
    type: json
    required: true
    primary: true
EOF
cat > "$_dir/plugin.sh" <<'EOF'
rbl_provider_run() {
    local state_file="$2"
    local state_dir; state_dir="$(dirname "$state_file")"
    mkdir -p "$state_dir/artifacts"
    printf '%s' '{"verdict":"pass"}' > "$state_dir/artifacts/rbl-result.json"
    return 0
}
EOF

OVERLAY_REPO="$(setup_git_temp_repo rbl-overlay-repo)"
install_template_overlay "$OVERLAY_REPO" leaf-role-bound

rm -f "$EVENTS_JSONL" "$STATE_DIR/pipeline-state.json"
set +e
( cd "$OVERLAY_REPO" && bash "$RUNNER" --issue 1770 --template leaf-role-bound ) \
    >"$TEST_TEMP_DIR/runner.out" 2>"$TEST_TEMP_DIR/runner.err"
_run_rc=$?
set -e

# The stage itself must have run — otherwise the verdict assertions below would
# be vacuous, passing for the wrong reason on a fixture that never dispatched.
if grep -q '"stage.complete"' "$EVENTS_JSONL" 2>/dev/null; then
    assert_pass "[SPEC-4] the fixture stage dispatched (stage.complete emitted)"
else
    assert_fail "[SPEC-4] the fixture stage dispatched (stage.complete emitted)" \
        "rc=$_run_rc; stderr: $(tail -3 "$TEST_TEMP_DIR/runner.err" 2>/dev/null)"
    cleanup_test_env; print_test_results; exit 1
fi

# ─── SPEC-4: the emitted verdict is real, not "unknown" ─────────────────────
_verdict="$(grep '"stage.complete"' "$EVENTS_JSONL" \
    | grep "\"$STAGE_NAME\"" \
    | sed -n 's/.*"verdict"[": ]*"\([a-z_]*\)".*/\1/p' | tail -1)"
assert_eq "[SPEC-4] stage.complete carries the plugin's real verdict" "pass" "${_verdict:-<none>}"

# ─── SPEC-5: and it is what gets persisted ──────────────────────────────────
# The event is the signal; .stage_verdicts is what gates, resume and dashboards
# read. #1770's symptom was `unknown` reaching both.
_persisted="$(jq -r --arg s "$STAGE_NAME" '.stage_verdicts[$s] // "<none>"' \
    "$STATE_DIR/pipeline-state.json" 2>/dev/null || echo "<none>")"
assert_eq "[SPEC-5] .stage_verdicts records the real verdict" "pass" "$_persisted"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
