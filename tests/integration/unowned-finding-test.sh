#!/usr/bin/env bash
# tests/integration/unowned-finding-test.sh — a finding nobody in a loop owns
# leaves that loop; a finding nobody at all owns stops the run (#2271).
#
# Why: the engine stops deciding who owns a finding; it only counts the answers
# stages give (Eric, 2026-10-04). If every build-side stage answers `nothing to
# do` to the same finding, the build loop ends early and the outer loop starts
# again at design, carrying every finding — no rule names design. If design also
# answers `nothing to do`, nobody owns it: the run stops with a report rather
# than circling. One `done` from anyone keeps a finding where it is.
#
# U1 [change] every build-side stage disclaims a finding → the build loop ends
#             early (does not use its remaining rounds) and the outer loop
#             starts again at design
# U2 [guard]  one build-side stage answers `done` → no early exit; the build
#             loop keeps its rounds
# U3 [change] design and impact (every answering stage before the build loop)
#             also disclaim it → the run stops; the report names the finding,
#             the stage that opened it, and every answer with its why
# U4 [change] design answers `done` → the run carries on: the build loop runs
#             again, starting at round 1
# U5 [change] design disclaims it but a later outer-loop stage before the build
#             loop (impact) answers `done` → the run carries on: one `done`
#             from anyone keeps a finding (review #2291)
# U6 [change] an early hand-back is recorded as such in the loop's state, not
#             as rounds exhausted
# U7 [change] an answer left over from an earlier run or round never counts:
#             a stage that answers nothing this round does not disclaim
#             (review #2291 round 2)
# U8 [guard]  with no stage before the yielding loop, nothing can disclaim: no
#             stop, and the yielded finding stays recorded
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "a finding nobody owns leaves the loop, then stops the run (#2271)"
setup_test_env "unowned-finding"

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

print_test_section "U1: every build-side stage disclaims the finding"
TA="nothing to do" BUILD="nothing to do" DESIGN="done" _run
assert_eq "[U1] the build loop ends early: it never reaches round 3" "0" "$(_count acc 3)"
assert_eq "[U1] the outer loop starts again at design" "2" "$(_count design 1)"

print_test_section "U2: one build-side stage did work on it"
TA="done" BUILD="nothing to do" DESIGN="done" _run
assert_eq "[U2] no early exit: the build loop keeps its rounds" "2" "$(_count acc 3)"

print_test_section "U3: design disclaims it too"
TA="nothing to do" BUILD="nothing to do" DESIGN="nothing to do" IMPACT="nothing to do" _run; rc=$?
if [[ "$rc" -ne 0 ]]; then
    assert_pass "[U3] the run stops (rc=$rc)"
else
    assert_fail "[U3] the run stops" "rc=0"
fi
assert_eq "[U3] the build loop does not run again after design disclaims it" "1" "$(_count test_author 1)"
_rep="$(cat "$ZBUILD_STATE_DIR/artifacts/unowned-findings.md" 2>/dev/null)"
assert_contains "[U3] the report names the finding" "$_rep" "acc finding 1"
assert_contains "[U3] ...and the stage that opened it" "$_rep" "opened by acc"
assert_contains "[U3] ...and its text" "$_rep" "is not the file that calls the new code"
assert_contains "[U3] ...and design's answer and why" "$_rep" "design: nothing to do — the wiring choice is right as written"
assert_contains "[U3] ...and build's answer" "$_rep" "build: nothing to do"
assert_contains "[U3] ...and impact's answer" "$_rep" "impact: nothing to do"

print_test_section "U4: design does the work"
TA="nothing to do" BUILD="nothing to do" DESIGN="done" _run
assert_eq "[U4] the build loop runs again, from round 1" "2" "$(_count test_author 1)"

print_test_section "U5: a later outer-loop stage does the work"
TA="nothing to do" BUILD="nothing to do" DESIGN="nothing to do" IMPACT="done" _run; rc=$?
assert_eq "[U5] no report — impact did work on it" "absent" \
    "$( [[ -s "$ZBUILD_STATE_DIR/artifacts/unowned-findings.md" ]] && echo present || echo absent )"
assert_eq "[U5] the build loop runs again, from round 1" "2" "$(_count test_author 1)"

print_test_section "U6: the early hand-back is recorded as such"
TA="nothing to do" BUILD="nothing to do" DESIGN="done" _run
assert_eq "[U6] the build loop's state says it ended on an unowned finding" "unowned_finding" \
    "$(jq -r '.cycle_iterations.build_loop.status // empty' "$ZBUILD_STATE_DIR/pipeline-state.json" 2>/dev/null)"

print_test_section "U7: a leftover answer does not count"
# _run clears the answers directory, then this case leaves design's answer from
# an earlier run in place; design answers nothing this time.
_run_with_stale() {
    : > "$LOG"; : > "$ZBUILD_EVENTS_JSONL"; rm -rf "$FA" "$ZBUILD_STATE_DIR/artifacts/unowned-findings.md"
    _ans design "nothing to do" "left over from an earlier run"
    local sf="$ZBUILD_STATE_DIR/pipeline-state.json"
    rm -f "$sf" "$sf.bak" "$sf.lock"
    jq -n '{schema_version:1, stage_statuses:{}, updated_at:"seed"}' > "$sf"
    _TPL_STAGES=(); _TPL_CYCLES=()
    load_template "$TPL" >/dev/null 2>&1 || return 99
    cycle_orchestrator_run outer_loop "$ZBUILD_STATE_DIR" "$sf" >/dev/null 2>&1
}
TA="nothing to do" BUILD="nothing to do" DESIGN="" IMPACT="nothing to do" _run_with_stale
assert_eq "[U7] no report — design said nothing this time" "absent" \
    "$( [[ -s "$ZBUILD_STATE_DIR/artifacts/unowned-findings.md" ]] && echo present || echo absent )"

print_test_section "U8: nothing ran before the yielding loop"
mkdir -p "$FA"; printf '{"loop":"build_loop","refs":["acc finding 1"],"answers":[]}\n' > "$ZBUILD_STATE_DIR/unowned-yield.json"
_unowned_halt_check "$ZBUILD_STATE_DIR"; _rc8=$?
assert_eq "[U8] no stop when no stage could have answered" "1" "$_rc8"
assert_eq "[U8] the yielded finding stays recorded" "present" \
    "$( [[ -s "$ZBUILD_STATE_DIR/unowned-yield.json" ]] && echo present || echo absent )"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
