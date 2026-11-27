#!/usr/bin/env bash
# tests/integration/cycle-member-requires-test.sh — a loop member runs only when
# the earlier members it requires passed in this round (#2640, ADR-068 §3).
#
# Why: on #2534 run 45997137687 test-author wrote nothing in rounds 1 and 2; build
# ran anyway, added 180 lines with no new test, and the suite passed on the tests
# that were already there. `requires:` (#2611) was refused inside a loop.
#
# [#2640/SPEC-1] a loop member's requires: names earlier members of its loop;
#                `all` is every one before it; any other name refuses the template
# [#2640/SPEC-1] an unmet one ends the round: the member and the rest do not
#                run, the engine says why, and the next round starts at the top
# [#2640/SPEC-1] a loop out of rounds with the member never run ends saying so
# [#2640/SPEC-1] the status comment's row for it says why it did not run
# [#2640/SPEC-1] simple.yaml gives build requires: [test-author]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "a loop member requires earlier members to have passed this round (#2640)"
setup_test_env "cycle-member-requires"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ZBUILD_STATE_DIR"
# shellcheck source=../../core/pipeline/cycle-orchestrator.sh
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
# shellcheck source=../../scripts/lib/run-status-comment.sh
source "$REPO_ROOT/scripts/lib/run-status-comment.sh"
# shellcheck source=../../scripts/lib/run-open-items.sh
source "$REPO_ROOT/scripts/lib/run-open-items.sh"

# _tpl <build's requires line> [check's requires line] — a loop of design,
# writer, build and check, where build (and check) may require earlier members.
TPL="$TEST_TEMP_DIR/loop.yaml"
_tpl() {
    cat > "$TPL" <<EOF
id: requires-in-loop
name: A loop member requires earlier members
defaults:
  strategy: fanout
flow:
  - intake
  - build_loop

build_loop:
  type: cycle
  flow:
    - design
    - writer
    - build
    - check
  exit_when:
    all:
      - { stage: design, field: verdict, op: eq, value: pass }
      - { stage: writer, field: verdict, op: eq, value: pass }
      - { stage: build, field: verdict, op: eq, value: pass }
      - { stage: check, field: verdict, op: eq, value: pass }
  stop_run_on_fail: [design]
  max_iterations: 3
  on_max: halt

intake:
  roles: [intake]
design:
  roles: [designer]
writer:
  roles: [test_author]
  blocking: false
build:
  roles: [builder]
  $1
check:
  roles: [checker]
  ${2:-}
EOF
}
_load() { _TPL_STAGES=(); _TPL_CYCLES=(); load_template "$TPL" 2>"$TEST_TEMP_DIR/load.err" >/dev/null; }

# ── what the template may say ────────────────────────────────────────────────
print_test_section "what a loop member may require"
_tpl "requires: [writer]"
_load; assert_eq "[#2640/SPEC-1] a member requiring an earlier member loads" "0" "$?"
assert_eq "[#2640/SPEC-1] ...and requires it" "writer" "$(template_stage_requires build)"
_tpl "requires: all"
_load; assert_eq "[#2640/SPEC-1] requires: all loads in a loop" "0" "$?"
assert_eq "[#2640/SPEC-1] ...as every member before it in its loop, but one marked not blocking" \
    "design" "$(template_stage_requires build)"
_tpl "requires: [check]"
_load; assert_eq "[#2640/SPEC-1] a member requiring a later member refuses the template" "1" "$?"
assert_contains "[#2640/SPEC-1] ...saying which" "$(cat "$TEST_TEMP_DIR/load.err")" \
    "stage 'build' requires 'check', which is not a member its loop runs before it"
_tpl "requires: [intake]"
_load; assert_eq "[#2640/SPEC-1] a member requiring a stage outside its loop refuses the template" "1" "$?"

# ── running the loop ─────────────────────────────────────────────────────────
LOG="$TEST_TEMP_DIR/dispatch.log"
# WRITER: one word a round — pass or fail.
# shellcheck disable=SC2329  # called by the orchestrator
cycle_dispatch_stage() {
    local stage="$1" iter="$2" w
    printf '%s|iter=%s\n' "$stage" "$iter" >> "$LOG"
    _CYCLE_DISPATCH_VERDICT="pass"; _CYCLE_DISPATCH_STATUS="complete"; _CYCLE_DISPATCH_REPORT="{}"
    [[ "$stage" == writer ]] || return 0
    w="$(cut -d, -f"$iter" <<< "$WRITER")"
    [[ "$w" == fail ]] && { _CYCLE_DISPATCH_VERDICT="fail"; return 1; }
    return 0
}
_run() {
    : > "$LOG"; : > "$ZBUILD_EVENTS_JSONL"
    local sf="$ZBUILD_STATE_DIR/pipeline-state.json"
    rm -f "$sf" "$sf.bak" "$sf.lock"
    jq -n '{schema_version:1, stage_statuses:{}, updated_at:"seed"}' > "$sf"
    _load || { echo "load_template failed" >&2; return 99; }
    _CYCLE_LAST_TERMINATED_REASON=""
    cycle_orchestrator_run build_loop "$ZBUILD_STATE_DIR" "$sf" >/dev/null 2>&1
    RUN_RC=$?
}
_count() { grep -c "^$1|" "$LOG" || true; }
_ran() { grep -c "^$1|iter=$2$" "$LOG" || true; }

print_test_section "a member whose requirement did not pass this round"
_tpl "requires: [writer]"
WRITER=fail,pass _run
assert_eq "[#2640/SPEC-1] build does not run in the round the writer failed" "0" "$(_ran build 1)"
assert_eq "[#2640/SPEC-1] ...nor does anything after it" "0" "$(_ran check 1)"
assert_eq "[#2640/SPEC-1] the next round starts at the top: design runs again" "2" "$(_count design)"
assert_eq "[#2640/SPEC-1] ...and build runs in it, once the writer passed" "1" "$(_ran build 2)"
assert_eq "[#2640/SPEC-1] the run goes on and converges" "0" "$RUN_RC"
_nr="$(grep '"cycle.member.not_run"' "$ZBUILD_EVENTS_JSONL" || true)"
assert_contains "[#2640/SPEC-1] the engine says which member did not run" "$_nr" '"stage":"build"'
assert_contains "[#2640/SPEC-1] ...and which requirement did not pass" "$_nr" '"requires":"writer"'

print_test_section "the status comment's row"
_rows="$(rsc_rows_json "$ZBUILD_EVENTS_JSONL")"
_row="$(jq -c '[.order[] as $k | .rows[$k] | select(.kind == "not_run")] | first // empty' <<< "$_rows")"
_line="$(rsc_render_row "$ZBUILD_STATE_DIR" "${_row:-{\}}")"
assert_contains "[#2640/SPEC-1] the row names the member" "$_line" " build**"
assert_contains "[#2640/SPEC-1] ...and why it did not run" "$_line" "not run — writer did not pass"

print_test_section "a requirement that never passes"
WRITER=fail,fail,fail _run
assert_eq "[#2640/SPEC-1] the loop runs its 3 rounds" "3" "$(_count design)"
assert_eq "[#2640/SPEC-1] ...build never runs" "0" "$(_count build)"
assert_eq "[#2640/SPEC-1] ...and the run ends failed" "1" "$RUN_RC"
assert_eq "[#2640/SPEC-1] ...saying build never ran because the writer did not pass" \
    "not_run:build:writer" "$_CYCLE_LAST_TERMINATED_REASON"
assert_eq "[#2640/SPEC-1] ...in words" "ran out of rounds: build never ran — writer did not pass" \
    "$(run_end_words "not_run:build:writer")"

print_test_section "a requirement that passes"
WRITER=pass _run
assert_eq "[#2640/SPEC-1] build runs in round 1" "1" "$(_ran build 1)"
assert_eq "[#2640/SPEC-1] ...and no member is said not to have run" "0" \
    "$(grep -c '"cycle.member.not_run"' "$ZBUILD_EVENTS_JSONL" || true)"

print_test_section "zBuild's templates"
# simple.yaml's build loop has test-author; deployed.yaml's has none (design,
# build, test), so its build requires nothing and the template still loads.
_TPL_STAGES=(); _TPL_CYCLES=()
load_template "$REPO_ROOT/config/templates/simple.yaml" >/dev/null 2>&1
assert_eq "[#2640/SPEC-1] simple.yaml: build requires test-author" "test-author" "$(template_stage_requires build)"
_TPL_STAGES=(); _TPL_CYCLES=()
load_template "$REPO_ROOT/config/templates/deployed.yaml" >/dev/null 2>&1
assert_eq "[#2640/SPEC-1] deployed.yaml loads" "0" "$?"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
