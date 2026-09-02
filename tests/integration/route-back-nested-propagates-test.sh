#!/usr/bin/env bash
# [N1/N3/N4] Integration (#1225, ADR-045): route_back declared on a NESTED cycle
# propagates rc=11 through the enclosing cycle's main loop out to the runner,
# which performs the bounded dispatch-unit rewind — NO rc=4 (config_invalid)
# collapse. Drives the REAL runner + REAL cycle_orchestrator_run over a nested
# template (outer cycle whose member `inner` is itself a cycle that route_backs
# to the earlier top-level `plan` leaf). Leaf plugin invocation + verdict readback
# are stubbed so the inner cycle's `test` verdict is scripted deterministically.
#
#   N1: one route_back fires, plan replays, the pipeline converges (complete).
#   N3: the INNER cycle's declared `max` is honored (edge keyed on the owning
#       cycle, not the outer top-level unit) — global budget deliberately huge.
#   N4: the run-wide global budget still caps total passes even when the inner
#       edge `max` is huge.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "route_back NESTED-cycle propagation (#1225 / ADR-045)"
setup_test_env "route-back-nested-propagates"

# #1921 follow-up: the runner resolves repo_root from CWD, so an in-process
# `main` snapshots into whatever repository the test stands in. These files used
# REAL issue numbers from the working checkout, adding commits to real issues'
# state branches (measured: 3 per run onto issue-698). Reserved id + throwaway
# repo; the cd below is what actually contains it.
_ZB_ISSUE="$(zb_test_issue)"
_ZB_REPO="$(zb_test_repo rb-nested)"

# Emit a nested-cycle template: top-level [plan, outer]; outer is a cycle whose
# only member is the cycle `inner`; inner routes back to `plan`. $1 = inner max.
_write_nested_tpl() {
    local _f="$1" _inner_max="$2"
    cat > "$_f" <<EOF
id: nested-rb-prop
defaults:
  strategy: fanout
flow:
  - plan
  - outer
plan:
  roles: [planner]
outer:
  type: cycle
  flow:
    - inner
  exit_when:
    stage: inner
    field: verdict
    op: eq
    value: pass
  max_iterations: 2
  on_max: continue
inner:
  type: cycle
  flow:
    - build
    - test
  exit_when:
    stage: test
    field: verdict
    op: eq
    value: pass
  route_back:
    to: plan
    when:
      stage: test
      field: verdict
      op: eq
      value: retry
    max: ${_inner_max}
  max_iterations: 2
  on_max: continue
build:
  roles: [builder]
test:
  roles: [tester]
EOF
}

# Run the real pipeline over $tpl with $budget as the global route_back budget.
# $test_script controls the `test` leaf raw verdict:
#   converge  → first 2 test dispatches "retry", then "pass" (route_back once, converge)
#   always    → every test dispatch "retry" (route_back until budget/edge cap)
_run() {
    local _tpl="$1" _budget="$2" _mode="$3" _out="$4"
    local _tmp; _tmp="$(mktemp -d "$TEST_TEMP_DIR/nrb-XXXXXX")"
    (
        set +e
        export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
        export ZBUILD_EVENTS_DIR="$_out/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
        export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
        export ZBUILD_STATE_DIR="$_out/state"; mkdir -p "$ZBUILD_STATE_DIR"
        export ZBUILD_STATE_FILE="$ZBUILD_STATE_DIR/pipeline-state.json"
        export ZBUILD_CYCLES_ENABLED=1
        export ZBUILD_CONTRACT_VALIDATOR=warn
        export ZBUILD_PLUGINS_ROOT="$REPO_ROOT/plugins"
        export ZBUILD_ROUTE_BACK_BUDGET="$_budget"
        export _NRB_TEST_CALLS="$_tmp/test-calls"; : > "$_NRB_TEST_CALLS"
        export _NRB_MODE="$_mode"
        # shellcheck disable=SC1091
        cd "$_ZB_REPO" || exit 1
        source "$REPO_ROOT/core/pipeline/runner.sh" 2>/dev/null

        # Point template resolution at our custom nested fixture.
        resolve_template_file() { echo "$_tpl"; }
        # Stub plugin resolution + invocation so leaves "run" without real plugins.
        resolve_stage_plugin() { echo "$REPO_ROOT/plugins/agent/build"; }
        _find_plugin_for_stage() { echo "$REPO_ROOT/plugins/agent/build"; }
        plugin_hook_call() { return 0; }
        runner_read_stage_reason() { echo ""; }
        # Classified verdict channel — keep it benign.
        runner_read_stage_verdict() { echo "pass"; }
        # RAW verdict channel — the orchestrator's exit_when/route_back predicates
        # read this. Only `test` is scripted; everything else passes.
        runner_read_stage_verdict_raw() {
            local _stage="$3"
            if [[ "$_stage" == "test" ]]; then
                local _n=0; [[ -f "$_NRB_TEST_CALLS" ]] && _n="$(wc -l < "$_NRB_TEST_CALLS" | tr -d ' ')"
                echo "x" >> "$_NRB_TEST_CALLS"
                if [[ "$_NRB_MODE" == "converge" && "$_n" -ge 2 ]]; then
                    echo "pass"; return 0
                fi
                echo "retry"; return 0
            fi
            echo "pass"
        }

        main --issue "$_ZB_ISSUE" --template nested-rb-prop >/dev/null 2>&1
    )
}

# ── N1: one route_back fires, plan replays once, pipeline converges ──────────
_tpl1="$TEST_TEMP_DIR/n1.yaml"; _write_nested_tpl "$_tpl1" 3
_out1="$TEST_TEMP_DIR/n1"; mkdir -p "$_out1"
_run "$_tpl1" 3 converge "$_out1"

_ev1="$_out1/events/events.jsonl"
_state1="$_out1/state/pipeline-state.json"

_rb1="$(grep -c '"type":"cycle.route_back"' "$_ev1" 2>/dev/null || true)"; [[ -z "$_rb1" ]] && _rb1=0
assert_eq "N1: cycle.route_back emitted exactly once (nested rc=11 reached the runner)" "1" "$_rb1"

_plan1="$(grep '"type":"stage.start"' "$_ev1" 2>/dev/null | grep -c '"stage":"plan"')"; [[ -z "$_plan1" ]] && _plan1=0
assert_eq "N1: plan leaf dispatched TWICE (initial + one nested-triggered replay)" "2" "$_plan1"

# NO rc=4 collapse — a config_invalid halt would surface as an aborted/failed end
# with reason config_invalid and NO route_back event. The route_back above proves
# propagation; assert the run reached a clean completion.
_status1="$(jq -r '.status' "$_state1" 2>/dev/null)"
assert_eq "N1: pipeline completes after the bounded nested rewind (no rc=4 collapse)" "complete" "$_status1"

# ── N3: inner cycle's declared max=1 is honored (global budget huge) ─────────
# With edge keyed on the OWNING (inner) cycle, max=1 caps at exactly ONE
# route_back even though the global budget (5) would allow far more. The bug
# (edge keyed on the outer top-level unit, which has no declared max → default 2)
# would fire TWICE.
_tpl3="$TEST_TEMP_DIR/n3.yaml"; _write_nested_tpl "$_tpl3" 1
_out3="$TEST_TEMP_DIR/n3"; mkdir -p "$_out3"
_run "$_tpl3" 5 always "$_out3"
_ev3="$_out3/events/events.jsonl"
_rb3="$(grep -c '"type":"cycle.route_back"' "$_ev3" 2>/dev/null || true)"; [[ -z "$_rb3" ]] && _rb3=0
assert_eq "N3: inner edge max=1 honored → exactly ONE route_back (global budget=5)" "1" "$_rb3"

# ── N4: global budget=3 caps total passes even with a huge inner edge max ────
# budget=3 → passes 1→2 (fire), 2→3 (fire), 3<3 false (stop) = exactly 2 fires,
# regardless of the inner edge max=10.
_tpl4="$TEST_TEMP_DIR/n4.yaml"; _write_nested_tpl "$_tpl4" 10
_out4="$TEST_TEMP_DIR/n4"; mkdir -p "$_out4"
_run "$_tpl4" 3 always "$_out4"
_ev4="$_out4/events/events.jsonl"
_rb4="$(grep -c '"type":"cycle.route_back"' "$_ev4" 2>/dev/null || true)"; [[ -z "$_rb4" ]] && _rb4=0
assert_eq "N4: global budget=3 caps nested route_back at exactly TWO passes (inner max=10)" "2" "$_rb4"

print_test_results
