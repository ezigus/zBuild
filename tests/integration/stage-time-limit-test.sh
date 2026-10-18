#!/usr/bin/env bash
# tests/integration/stage-time-limit-test.sh — the engine stops a stage that
# runs past its time limit (ADR-054, ADR-063).
#
# Why: the per-call limit (router.timeout_s) bounds one model call, but nothing
# bounded a stage: a stage that loops, or a script that hangs, ran forever. The
# engine cannot trust a stage to stop itself (Eric, 2026-10-15). Each stage in
# the template may set `timeout_s:`; the default is 15 minutes.
#
# S1 [change] a stage past its limit is stopped, with everything it started,
#             and its outcome is timed_out
# S2 [guard]  a stage inside its limit runs as before: no time-limit record
# S3 [change] the limit is the stage's `timeout_s:`, or 900 seconds when unset
# S4 [change] the shipped templates give the long stages room: build 3600,
#             test 2700, design 1500, test-author 3780 (#2372: the acceptance
#             check runs inside test; ADR-068 §10: design is one call and its
#             coverage call per run)
#             (simple.yaml; deployed.yaml has no test-author)
# S5 [change] the stage is told its whole-stage limit in its rules
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
# shellcheck source=../../scripts/lib/stage-prompt.sh
source "$REPO_ROOT/scripts/lib/stage-prompt.sh"
print_test_header "the engine stops a stage past its time limit"
setup_test_env "stage-time-limit"

export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR" ZBUILD_EVENTS_DB="/dev/null"

TPL="$TEST_TEMP_DIR/t.yaml"
cat > "$TPL" <<'YAML'
id: t
name: time limits
defaults:
  strategy: fanout
flow:
  - slow
  - quick
slow:
  roles: [sleeper]
  timeout_s: 2
quick:
  roles: [sleeper]
YAML
load_template "$TPL" >/dev/null 2>&1

P="$TEST_TEMP_DIR/plugins/agent/sleeper"; mkdir -p "$P"
cat > "$P/manifest.yaml" <<'MF'
id: sleeper
name: Sleeper
kind: agent
version: 0.0.1
hooks:
  run: sleeper_run
provides:
  role: sleeper
  result_contract: 3
outputs:
  - id: sleeper_result
    path: ${artifact_dir}/sleeper-result.json
    type: json
    required: true
    primary: true
MF
cat > "$P/plugin.sh" <<'PL'
sleeper_run() {
    local art; art="$(dirname "$2")/artifacts"; mkdir -p "$art"
    sleep "${SLEEP_FOR:-0}" &
    printf '%s' "$!" > "$art/child.pid"
    wait
    source "@RESULT_LIB@"
    stage_result_write "$art/sleeper-result.json" pass "slept"
}
PL
sed -i.bak "s|@RESULT_LIB@|$REPO_ROOT/scripts/lib/stage-result.sh|" "$P/plugin.sh"

S="$TEST_TEMP_DIR/state"; mkdir -p "$S/artifacts"
printf '{"schema_version":1}' > "$S/pipeline-state.json"
export ZBUILD_STATE_DIR="$S"

# ── S1 ───────────────────────────────────────────────────────────────────────
_t0=$SECONDS
SLEEP_FOR=60 plugin_hook_call "$P" run slow "$S/pipeline-state.json" >/dev/null 2>&1; _rc=$?
_took=$(( SECONDS - _t0 ))
assert_eq "[S1] the stage is stopped near its limit, not after 60s" "yes" "$([[ $_took -lt 15 ]] && echo yes || echo "no (${_took}s)")"
assert_eq "[S1] the dispatch does not report success" "yes" "$([[ $_rc -ne 0 ]] && echo yes || echo no)"
_child="$(cat "$S/artifacts/child.pid" 2>/dev/null)"
assert_eq "[S1] what the stage started is stopped too" "gone" \
    "$([[ -n "$_child" ]] && kill -0 "$_child" 2>/dev/null && echo alive || echo gone)"
assert_eq "[S1] its outcome is timed_out" "timed_out" \
    "$(runner_read_stage_disposition "$S" "$P/manifest.yaml" slow "$_rc" 2>/dev/null)"
assert_contains "[S1] the engine says so" "$(cat "$ZBUILD_EVENTS_JSONL")" '"stage.time_limit.reached"'

# ── S2 ───────────────────────────────────────────────────────────────────────
SLEEP_FOR=0 plugin_hook_call "$P" run quick "$S/pipeline-state.json" >/dev/null 2>&1; _rc=$?
assert_eq "[S2] a stage inside its limit succeeds" "0" "$_rc"
assert_eq "[S2] ...and its outcome is its own" "complete" \
    "$(runner_read_stage_disposition "$S" "$P/manifest.yaml" quick "$_rc" 2>/dev/null)"
SLEEP_FOR=0 plugin_hook_call "$P" run slow "$S/pipeline-state.json" >/dev/null 2>&1; _rc=$?
assert_eq "[S2] a stage that hit its limit before runs clean the next time" "complete" \
    "$(runner_read_stage_disposition "$S" "$P/manifest.yaml" slow "$_rc" 2>/dev/null)"

# ── S3 ───────────────────────────────────────────────────────────────────────
assert_eq "[S3] the limit is the stage's timeout_s" "2" "$(template_stage_time_limit slow)"
assert_eq "[S3] ...or 900 seconds when unset" "900" "$(template_stage_time_limit quick)"

# ── S4 ───────────────────────────────────────────────────────────────────────
for _t in simple deployed; do
    load_template "$REPO_ROOT/config/templates/$_t.yaml" >/dev/null 2>&1
    _pairs="build:3600 test:2700 design:1500"
    [[ "$_t" == simple ]] && _pairs+=" test-author:3780"
    for _pair in $_pairs; do
        assert_eq "[S4] $_t.yaml: ${_pair%%:*} has ${_pair#*:}s" "${_pair#*:}" "$(template_stage_time_limit "${_pair%%:*}")"
    done
done

# ── S5 ───────────────────────────────────────────────────────────────────────
load_template "$TPL" >/dev/null 2>&1
assert_contains "[S5] the stage is told its whole-stage limit" \
    "$(_stage_block_rules slow "$S" "$P/manifest.yaml")" "The whole stage has 2 seconds."
assert_contains "[S5] ...the default too" \
    "$(_stage_block_rules quick "$S" "$P/manifest.yaml")" "The whole stage has 900 seconds."

cleanup_test_env
print_test_results
exit $((FAIL > 0))
