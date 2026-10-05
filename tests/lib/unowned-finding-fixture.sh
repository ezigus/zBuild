#!/usr/bin/env bash
# tests/lib/unowned-finding-fixture.sh — #2310: the shared setup for the
# unowned-finding tests (#2271), split across two files so neither nears the
# per-file timeout under the parallel integration tier: the nested template,
# the stubbed dispatch, and the _ans/_run/_count helpers.
# Sourced by unowned-finding-test.sh and unowned-finding-stale-test.sh AFTER
# setup_test_env.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ZBUILD_STATE_DIR/artifacts"
# shellcheck source=../../core/pipeline/cycle-orchestrator.sh
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"

TPL="$TEST_TEMP_DIR/t.yaml"
cat > "$TPL" <<'EOF'
id: unowned
name: Unowned findings
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
  unowned: halt

design_loop:
  type: cycle
  flow:
    - design
  exit_when:
    stage: design
    field: verdict
    op: eq
    value: pass
  max_iterations: 2
  on_max: halt

build_loop:
  type: cycle
  flow:
    - test_author
    - build
    - acc
  exit_when:
    stage: acc
    field: verdict
    op: eq
    value: pass
  max_iterations: 3
  on_max: continue
  unowned: yield

design:
  roles: [designer]
impact:
  roles: [impact]
test_author:
  roles: [test_author]
build:
  roles: [builder]
acc:
  roles: [acceptance]
EOF

LOG="$TEST_TEMP_DIR/dispatch.log"
FA="$ZBUILD_STATE_DIR/finding-answers"
# Which members answer findings — in production, the stages that call a model.
# shellcheck disable=SC2329  # called by the orchestrator
_cycle_stage_answers_findings() { case "$1" in design|impact|test_author|build) return 0 ;; *) return 1 ;; esac; }
# shellcheck disable=SC2329  # called by the stub below
_ans() {   # _ans <stage> <answer> <why> — record this stage's answer to "acc finding 1"
    mkdir -p "$FA"
    jq -nc --arg a "$2" --arg w "$3" --arg b "$1" '{"acc finding 1": {answer:$a, why:$w, by:$b}}' > "$FA/$1.json"
}
# The stub. ACC always fails with one finding; TA/BUILD/DESIGN set each stage's
# answer to it (absent = no answer).
# shellcheck disable=SC2329
cycle_dispatch_stage() {
    local stage="$1" iter="$2"
    printf '%s|iter=%s\n' "$stage" "$iter" >> "$LOG"
    _CYCLE_DISPATCH_VERDICT="pass"; _CYCLE_DISPATCH_STATUS="complete"; _CYCLE_DISPATCH_REPORT="{}"
    case "$stage" in
        acc)
            _CYCLE_DISPATCH_VERDICT="fail"
            jq -n '{result_contract:2, verdict:"fail", disposition:"complete", reason:"one problem",
                    data:{findings:[{n:1, text:"config/event-schema.json is not the file that calls the new code"}]}}' \
                > "$ZBUILD_STATE_DIR/artifacts/acc-result.json" ;;
        test_author) [[ -n "${TA:-}" ]] && _ans test_author "$TA" "the test checks what the requirement says" ;;
        build)       [[ -n "${BUILD:-}" ]] && _ans build "$BUILD" "the code passes the tests it was given" ;;
        design)      [[ -n "${DESIGN:-}" ]] && _ans design "$DESIGN" "the wiring choice is right as written" ;;
        impact)      [[ -n "${IMPACT:-}" ]] && _ans impact "$IMPACT" "the plan now names the calling file" ;;
    esac
    return 0
}

_run() {
    : > "$LOG"; : > "$ZBUILD_EVENTS_JSONL"; rm -rf "$FA" "$ZBUILD_STATE_DIR/artifacts/unowned-findings.md"
    local sf="$ZBUILD_STATE_DIR/pipeline-state.json"
    rm -f "$sf" "$sf.bak" "$sf.lock"
    jq -n '{schema_version:1, stage_statuses:{}, updated_at:"seed"}' > "$sf"
    _TPL_STAGES=(); _TPL_CYCLES=()
    load_template "$TPL" >/dev/null 2>&1 || { echo "load_template failed" >&2; return 99; }
    cycle_orchestrator_run outer_loop "$ZBUILD_STATE_DIR" "$sf" >/dev/null 2>&1
}
_count() { grep -c "^$1|iter=$2\$" "$LOG" || true; }
