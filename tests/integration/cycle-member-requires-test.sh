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
# [#2640/SPEC-1] a loop inside the loop leaves the outer round's record as it was
# [#2640/SPEC-1] "this round": a pass in an earlier round does not count
# [#2640/SPEC-1] a member of a parallel group may not require anything
# [#2640/SPEC-2] a try the engine does not run again says so on its row, and a
#                try it runs again does not
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
cat > "$TPL" <<'EOF'
id: requires-in-group
name: A group member requires a stage
defaults:
  strategy: fanout
flow:
  - intake
  - both
both:
  type: parallel
  flow:
    - left
    - right
  max_parallel: 2
intake:
  roles: [intake]
left:
  roles: [left]
  requires: [intake]
right:
  roles: [right]
EOF
_load; assert_eq "[#2640/SPEC-1] a member of a parallel group requiring a stage refuses the template" "1" "$?"
assert_contains "[#2640/SPEC-1] ...saying it runs inside a group" "$(cat "$TEST_TEMP_DIR/load.err")" "runs inside a group"

# ── running the loop, through the real runner ────────────────────────────────
# The runner dispatches real stage plugins — stubs for every role (the simple
# roster) — so the orchestrator, the runner's dispatch and the status rows are
# all the engine's own. test-author fails in the rounds TA_FAILS names.
_ZB_REPO="$(zb_test_repo cycle-member-requires)"
_ZB_GOAL="$(zb_test_goal cycle-member-requires)"
PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
RSTATE="$TEST_TEMP_DIR/run-state"
EVENTS_JSONL="$TEST_TEMP_DIR/run-events/events.jsonl"
mkdir -p "$RSTATE" "$TEST_TEMP_DIR/run-events"
_run_env() {
    ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" ZBUILD_STATE_DIR="$RSTATE" \
    ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/run-events" ZBUILD_EVENTS_JSONL="$EVENTS_JSONL" \
    ZBUILD_CYCLES_ENABLED=1 ZBUILD_CONTRACT_VALIDATOR=warn \
    ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json" ZB_STUB_ROOT="$REPO_ROOT" "$@"
}
export ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT"
# shellcheck source=../lib/simple-run-stubs.sh
source "$REPO_ROOT/tests/lib/simple-run-stubs.sh"
simple_stubs_roster
mock_plugin_factory "test-author" agent 0 "" "test_author" >/dev/null
# A work output besides its result: a try that changes it changed something.
cat >> "$PLUGINS_ROOT/agent/test-author/manifest.yaml" <<'MF'
  - id: test_author_work
    path: ${artifact_dir}/test-author-work.txt
    type: text
    required: false
MF
cat > "$PLUGINS_ROOT/agent/test-author/plugin.sh" <<'PLUG'
test_author_run() {
    local art; art="$(dirname "$2")/artifacts"; mkdir -p "$art"
    source "$STAGE_RESULT_LIB"
    # TA_MOVES: the first try is cut off having changed something (its result
    # names its try), so the engine runs it again; the second passes.
    if [[ " ${TA_MOVES:-} " == *" ${ZBUILD_CYCLE_ITER:-0} "* && "${ZBUILD_STAGE_TRY:-1}" == 1 ]]; then
        printf 'try %s\n' "${ZBUILD_STAGE_TRY:-1}" > "$art/test-author-work.txt"
        stage_result_write "$art/test-author-result.json" timed_out "the author did not finish"
        return 1
    fi
    # TA_SAME: a try cut off that changed nothing, the same every time.
    if [[ " ${TA_SAME:-} " == *" ${ZBUILD_CYCLE_ITER:-0} "* ]]; then
        stage_result_write "$art/test-author-result.json" timed_out "the author did not finish"
        return 1
    fi
    if [[ " ${TA_FAILS:-} " == *" ${ZBUILD_CYCLE_ITER:-0} "* ]]; then
        stage_result_write "$art/test-author-result.json" fail "no tests written this round"
        return 1
    fi
    stage_result_write "$art/test-author-result.json" pass "tests written"
}
PLUG
mock_plugin_factory "build" agent 0 "" "builder" >/dev/null
cat > "$PLUGINS_ROOT/agent/build/plugin.sh" <<'PLUG'
build_run() {
    local art; art="$(dirname "$2")/artifacts"; mkdir -p "$art"
    source "$STAGE_RESULT_LIB"
    if [[ " ${BUILD_FAILS:-} " == *" ${ZBUILD_CYCLE_ITER:-0} "* ]]; then
        stage_result_write "$art/build-result.json" fail "the build did not pass"
        return 1
    fi
    stage_result_write "$art/build-result.json" pass "built"
}
PLUG
mkdir -p "$_ZB_REPO/.zbuild/templates"
cat > "$_ZB_REPO/.zbuild/templates/req-loop.yaml" <<'TPL'
id: req-loop
extends: simple
flow:
  - req_loop
always_run: []
req_loop:
  type: cycle
  description: Design, write the tests, then build
  flow:
    - design
    - test-author
    - build
  exit_when:
    all:
      - { stage: design, field: verdict, op: eq, value: pass }
      - { stage: test-author, field: verdict, op: eq, value: pass }
      - { stage: build, field: verdict, op: eq, value: pass }
  stop_run_on_fail: [design]
  max_iterations: 3
  on_max: halt
design:
  gate: auto
  roles: [designer]
test-author:
  gate: auto
  roles: [test_author]
  retry: 1
build:
  gate: auto
  roles: [builder]
  requires: [test-author]
TPL
( cd "$_ZB_REPO" && git add .zbuild && git commit -qm "req-loop template" ) >/dev/null 2>&1
export _ZB_TEMPLATE=req-loop
_go() { : > "$EVENTS_JSONL"; rm -rf "${RSTATE:?}"; mkdir -p "$RSTATE"; _run_env _run_pipeline; }
# _ran <member> <round> — dispatches of <member> in <round>, from the engine's events.
_ran() { jq -r --arg m "$1" --arg i "$2" 'select(.type == "cycle.member.dispatch.start" and .data.member == $m and .data.iter == $i) | 1' "$EVENTS_JSONL" 2>/dev/null | grep -c . || true; }
_count() { jq -r --arg m "$1" 'select(.type == "cycle.member.dispatch.start" and .data.member == $m) | 1' "$EVENTS_JSONL" 2>/dev/null | grep -c . || true; }

print_test_section "a member whose requirement did not pass this round"
TA_FAILS="1" _go
assert_eq "[#2640/SPEC-1] build does not run in the round test-author failed" "0" "$(_ran build 1)"
assert_eq "[#2640/SPEC-1] the next round starts at the top: design runs again" "1" "$(_ran design 2)"
assert_eq "[#2640/SPEC-1] ...and build runs in it, once test-author passed" "1" "$(_ran build 2)"
assert_eq "[#2640/SPEC-1] the run goes on and passes" "0" "$_RUNNER_RC"
_nr="$(grep '"cycle.member.not_run"' "$EVENTS_JSONL" || true)"
assert_contains "[#2640/SPEC-1] the engine says which member did not run" "$_nr" '"stage":"build"'
assert_contains "[#2640/SPEC-1] ...and which requirement did not pass" "$_nr" '"requires":"test-author"'

print_test_section "the status comment's row"
_rows="$(rsc_rows_json "$EVENTS_JSONL")"
_row="$(jq -c '[.order[] as $k | .rows[$k] | select(.kind == "not_run")] | first // empty' <<< "$_rows")"
_line="$(rsc_render_row "$RSTATE" "${_row:-{\}}")"
assert_contains "[#2640/SPEC-1] the row names the member" "$_line" " build**"
assert_contains "[#2640/SPEC-1] ...and why it did not run" "$_line" "not run — test-author did not pass"

print_test_section "this round, not an earlier one"
# test-author passes in round 1 and build fails there, so round 2 runs; then
# test-author fails in round 2. Its round-1 pass does not count for round 2.
BUILD_FAILS="1" TA_FAILS="2" _go
assert_eq "[#2640/SPEC-1] build runs in round 1, after test-author passed" "1" "$(_ran build 1)"
assert_eq "[#2640/SPEC-1] ...and not in round 2, where test-author did not pass" "0" "$(_ran build 2)"

print_test_section "a try the engine does not run again"
# test-author is cut off in round 1 and its try changed nothing: the engine does
# not run it again, and its row says so (#2640/SPEC-2), from the engine's own events.
TA_SAME="1" _go
_ta_rows="$(rsc_rows_json "$EVENTS_JSONL")"
_ta_row="$(jq -c '[.order[] as $k | .rows[$k] | select(.stage == "test-author" and (.kind // "") != "not_run")] | first // empty' <<< "$_ta_rows")"
assert_contains "[#2640/SPEC-2] the try's row says it was not run again, and why" \
    "$(rsc_render_row "$RSTATE" "${_ta_row:-{\}}")" "not run again: the try changed nothing"
TA_MOVES="1" _go
assert_eq "[#2640/SPEC-2] a cut-off try that changed something is run again" "1" \
    "$(jq -r 'select(.type == "stage.retry" and .data.stage == "test-author") | 1' "$EVENTS_JSONL" 2>/dev/null | grep -c . || true)"
assert_eq "[#2640/SPEC-2] ...and no refusal is said for it" "" \
    "$(jq -r 'select(.type == "stage.retry.refused") | .type' "$EVENTS_JSONL" 2>/dev/null)"
_tm_row="$(jq -c '[.order[] as $k | .rows[$k] | select(.stage == "test-author")] | first // empty' <<< "$(rsc_rows_json "$EVENTS_JSONL")")"
_tm_line="$(rsc_render_row "$RSTATE" "${_tm_row:-{\}}")"
assert_eq "[#2640/SPEC-2] ...nor on its row" "no" "$([[ "$_tm_line" == *"not run again"* ]] && echo yes || echo no)"

print_test_section "a requirement that never passes"
TA_FAILS="1 2 3" _go
assert_eq "[#2640/SPEC-1] the loop runs its 3 rounds" "3" "$(_count design)"
assert_eq "[#2640/SPEC-1] ...build never runs" "0" "$(_count build)"
assert_eq "[#2640/SPEC-1] ...and the run ends failed" "1" "$([[ $_RUNNER_RC -ne 0 ]] && echo 1 || echo 0)"
assert_contains "[#2640/SPEC-1] ...saying build never ran because test-author did not pass" \
    "$(jq -r 'select(.type == "cycle.complete") | .data.reason' "$EVENTS_JSONL" 2>/dev/null)" "not_run:build:test-author"
assert_eq "[#2640/SPEC-1] ...in words" "ran out of rounds: build never ran — test-author did not pass" \
    "$(run_end_words "not_run:build:test-author")"

print_test_section "a requirement that passes"
TA_FAILS="" _go
assert_eq "[#2640/SPEC-1] build runs in round 1" "1" "$(_ran build 1)"
assert_eq "[#2640/SPEC-1] ...and no member is said not to have run" "0" \
    "$(grep -c '"cycle.member.not_run"' "$EVENTS_JSONL" || true)"

print_test_section "a loop inside the loop"
# The outer round's members that passed are kept while a loop inside it runs:
# build requires design, which ran before the inner loop (bash review on #2640).
cat > "$_ZB_REPO/.zbuild/templates/req-nested.yaml" <<'TPL'
id: req-nested
extends: simple
flow:
  - outer_loop
always_run: []
outer_loop:
  type: cycle
  description: Design, an inner loop, then build
  flow:
    - design
    - inner_loop
    - build
  exit_when:
    all:
      - { stage: design, field: verdict, op: eq, value: pass }
      - { stage: inner_loop, field: verdict, op: eq, value: pass }
      - { stage: build, field: verdict, op: eq, value: pass }
  stop_run_on_fail: [design]
  max_iterations: 1
  on_max: halt
inner_loop:
  type: cycle
  description: Write the tests
  flow:
    - test-author
  exit_when:
    all:
      - { stage: test-author, field: verdict, op: eq, value: pass }
  max_iterations: 1
  on_max: halt
design:
  gate: auto
  roles: [designer]
test-author:
  gate: auto
  roles: [test_author]
build:
  gate: auto
  roles: [builder]
  requires: [design]
TPL
( cd "$_ZB_REPO" && git add .zbuild && git commit -qm "req-nested template" ) >/dev/null 2>&1
_ZB_TEMPLATE=req-nested TA_FAILS="" _go
assert_eq "[#2640/SPEC-1] a member after an inner loop that requires one before it runs" "1" "$(_ran build 1)"
assert_eq "[#2640/SPEC-1] ...and no member is said not to have run" "0" \
    "$(grep -c '"cycle.member.not_run"' "$EVENTS_JSONL" || true)"

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
