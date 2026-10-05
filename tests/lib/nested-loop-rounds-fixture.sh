#!/usr/bin/env bash
# tests/lib/nested-loop-rounds-fixture.sh — #2310: the shared setup for the
# nested-loop-rounds tests (#2271, ADR-068), split across two files so neither
# nears the per-file timeout under the parallel integration tier: the nested
# template, the stubbed dispatch, and the _run/_count helpers.
# Sourced by nested-loop-rounds-test.sh and nested-loop-rounds-build-test.sh
# AFTER setup_test_env.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ZBUILD_STATE_DIR"
# shellcheck source=../../core/pipeline/cycle-orchestrator.sh
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"

TPL="$TEST_TEMP_DIR/nested.yaml"
cat > "$TPL" <<'EOF'
id: nested-rounds
name: Nested loop rounds
defaults:
  strategy: fanout

flow:
  - outer_loop

outer_loop:
  type: cycle
  flow:
    - design_loop
    - impact
    - build_loop
  exit_when:
    all:
      - { stage: design_loop, field: verdict, op: eq, value: pass }
      - { stage: build_loop, field: verdict, op: eq, value: pass }
  max_iterations: 2
  on_max: halt

design_loop:
  type: cycle
  flow:
    - design
    - design_gate
  exit_when:
    stage: design_gate
    field: verdict
    op: eq
    value: pass
  max_iterations: 2
  on_max: halt

build_loop:
  type: cycle
  flow:
    - build
    - test
  exit_when:
    stage: test
    field: verdict
    op: eq
    value: pass
  max_iterations: 3
  on_max: continue

design:
  roles: [designer]
design_gate:
  roles: [design_gate]
impact:
  roles: [impact]
build:
  roles: [builder]
test:
  roles: [tester]
EOF

LOG="$TEST_TEMP_DIR/dispatch.log"
OUTER_ROUND_FILE="$TEST_TEMP_DIR/outer-round"
# The stub: DESIGN_GATE=pass|fail|fail-first-round, TEST=pass|fail.
# shellcheck disable=SC2329  # called by the orchestrator
cycle_dispatch_stage() {
    local stage="$1" iter="$2"
    printf '%s|iter=%s\n' "$stage" "$iter" >> "$LOG"
    _CYCLE_DISPATCH_VERDICT="pass"; _CYCLE_DISPATCH_STATUS="complete"; _CYCLE_DISPATCH_REPORT="{}"
    case "$stage" in
        design)
            # Count outer rounds by design's own round-1 dispatches.
            [[ "$iter" == "1" ]] && printf 'x' >> "$OUTER_ROUND_FILE" ;;
        design_gate)
            case "${DESIGN_GATE:-pass}" in
                fail) _CYCLE_DISPATCH_VERDICT="fail" ;;
                fail-first-round)
                    [[ "$(wc -c < "$OUTER_ROUND_FILE" | tr -d ' ')" == "1" ]] && _CYCLE_DISPATCH_VERDICT="fail" ;;
            esac ;;
        build)
            [[ "${BUILD:-ok}" == "blocked" ]] && { _CYCLE_DISPATCH_VERDICT="fail"; _CYCLE_DISPATCH_VERDICT_RAW="error"; } ;;
        test)
            if [[ "${TEST:-pass}" == "fail" ]]; then
                _CYCLE_DISPATCH_VERDICT="fail"
                _CYCLE_DISPATCH_REPORT='{"tests":{"total":3,"failed":1}}'
            fi ;;
    esac
    return 0
}

_run() {   # _run → rc of the outer loop; the dispatch log is left in $LOG
    : > "$LOG"; : > "$OUTER_ROUND_FILE"; : > "$ZBUILD_EVENTS_JSONL"
    local sf="$ZBUILD_STATE_DIR/pipeline-state.json"
    rm -f "$sf" "$sf.bak" "$sf.lock"
    jq -n '{schema_version:1, stage_statuses:{}, updated_at:"seed"}' > "$sf"
    _TPL_STAGES=(); _TPL_CYCLES=()
    load_template "$TPL" >/dev/null 2>&1 || { echo "load_template failed" >&2; return 99; }
    cycle_orchestrator_run outer_loop "$ZBUILD_STATE_DIR" "$sf" >/dev/null 2>&1
}
_count() { grep -c "^$1|iter=$2\$" "$LOG" || true; }
