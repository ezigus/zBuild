#!/usr/bin/env bash
# tests/integration/retry-mark-boundary-test.sh — the engine's retry mark stays
# inside the engine (ADR-024, amended 2026-11-06, #2476).
#
# Why: plugin_hook_call marked a retried stage with `local -x _ZB_LC_RETRYING=1`.
# The export reached every program the stage started, the test stage's suite
# among them, so inside the suite no retry ever happened: stage-retry-test.sh and
# write-boundary-revert-test.sh failed in every pipeline test stage of #1805 run
# 42127743259, though both pass on their own, and the shape floor could never
# clear.
#
# B1 [change] a program a dispatched stage starts does not see the retry mark
# B2 [change] a retry test run from inside a dispatched stage, through the fresh
#             shell the test stage uses, passes: the real dispatch environment
# B3 [guard]  a stage dispatched from inside a stage still runs once (the mark
#             still reaches the stage's own shell)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
# shellcheck source=../../core/pipeline/verdict.sh
source "$REPO_ROOT/core/pipeline/verdict.sh"
print_test_header "the retry mark never reaches a program a stage starts (#2476)"
setup_test_env "retry-mark-boundary"

export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR"
unset ZBUILD_CYCLE_ITER

TPL="$TEST_TEMP_DIR/t.yaml"
cat > "$TPL" <<'YAML'
id: t
name: retry mark
defaults:
  strategy: fanout
flow:
  - probe
probe:
  roles: [probe]
YAML
load_template "$TPL" >/dev/null 2>&1

# A stage that starts a program, as the test stage starts the suite, and, when
# INNER is set, dispatches another stage from inside itself.
P="$TEST_TEMP_DIR/plugins/agent/probe"; mkdir -p "$P"
cat > "$P/manifest.yaml" <<'MF'
id: probe
name: Probe
kind: agent
version: 0.0.1
hooks:
  run: probe_run
provides:
  role: probe
  result_contract: 3
outputs:
  - id: probe_result
    path: ${artifact_dir}/probe-result.json
    type: json
    required: true
    primary: true
MF
cat > "$P/plugin.sh" <<PL
probe_run() {
    local art; art="\$(dirname "\$2")/artifacts"; mkdir -p "\$art"
    local n=0; [[ -f "\$art/runs.\$1" ]] && n="\$(cat "\$art/runs.\$1")"
    printf '%s' "\$(( n + 1 ))" > "\$art/runs.\$1"
    bash -c 'printf "%s" "\${_ZB_LC_RETRYING-unset}"' > "\$art/child-mark.\$1"
    if [[ -n "\${SUITE:-}" ]]; then
        ( source "$REPO_ROOT/scripts/lib/env-scrub.sh"; _zbuild_make_fresh_shell
          bash "\$SUITE" ) > "\$art/suite.log" 2>&1
        printf '%s' "\$?" > "\$art/suite.rc"
    fi
    [[ -n "\${INNER:-}" && "\$1" != inner ]] && \\
        INNER= OUTCOME=timed_out plugin_hook_call "$P" run inner "\$2" >/dev/null 2>&1
    source "$REPO_ROOT/scripts/lib/stage-result.sh"
    stage_result_write "\$art/probe-result.json" "\${OUTCOME:-pass}" "run \$(( n + 1 ))"
    return 0
}
PL

S="$TEST_TEMP_DIR/state"; mkdir -p "$S/artifacts"
printf '{"schema_version":1}' > "$S/pipeline-state.json"
export ZBUILD_STATE_DIR="$S"
_fresh() { rm -rf "$S/artifacts" "$S/runtime"; mkdir -p "$S/artifacts"; }

# ── B1 ───────────────────────────────────────────────────────────────────────
_fresh; plugin_hook_call "$P" run probe "$S/pipeline-state.json" >/dev/null 2>&1
assert_eq "[B1] a program the stage starts does not see the retry mark" \
    "unset" "$(cat "$S/artifacts/child-mark.probe" 2>/dev/null || echo missing)"

# ── B2 ───────────────────────────────────────────────────────────────────────
_fresh; SUITE="$REPO_ROOT/tests/integration/write-boundary-revert-test.sh" \
    plugin_hook_call "$P" run probe "$S/pipeline-state.json" >/dev/null 2>&1
_b2_rc="$(cat "$S/artifacts/suite.rc" 2>/dev/null || echo missing)"
if [[ "$_b2_rc" == "0" ]]; then
    assert_pass "[B2] a retry test run from inside a dispatched stage passes"
else
    assert_fail "[B2] a retry test run from inside a dispatched stage passes" \
        "rc=$_b2_rc; $(/usr/bin/grep -a '✗' "$S/artifacts/suite.log" 2>/dev/null | tail -3)"
fi

# ── B3 ───────────────────────────────────────────────────────────────────────
_fresh; INNER=1 plugin_hook_call "$P" run probe "$S/pipeline-state.json" >/dev/null 2>&1
assert_eq "[B3] a stage dispatched from inside a stage runs once" \
    "1" "$(cat "$S/artifacts/runs.inner" 2>/dev/null || echo 0)"

print_test_results
exit $((FAIL > 0))
