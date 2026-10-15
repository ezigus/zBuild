#!/usr/bin/env bash
# tests/integration/stop-round-on-fail-test.sh — a loop's template names the
# members whose failure ends the round (#2369, ADR-068).
#
# Why: design checks its own design.md and loops back to its model; when its
# rounds run out its outcome is fail. Build must not run on a design that failed
# its checks. Only an inner LOOP that ran out of rounds ended the outer round, so
# the template names a plain member whose failure does the same.
#
# R1 [change] a named member fails: the later members do not run, and the loop
#             goes round
# R2 [guard]  the same member fails but is not named: the later members run
# R3 [guard]  the named member passes: the later members run
# R4 [change] a name that is not a member of the loop is refused at load
#             (review on PR #2393: a typo would silently do nothing)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "a loop's template names the members whose failure ends the round (#2369)"
setup_test_env "stop-round-on-fail"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ZBUILD_STATE_DIR"
# shellcheck source=../../core/pipeline/cycle-orchestrator.sh
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"

_write_tpl() {   # _write_tpl <file> <stop_round_on_fail line or empty>
    cat > "$1" <<EOF
id: stop-round
name: Stop round on fail
defaults:
  strategy: fanout

flow:
  - outer_loop

outer_loop:
  type: cycle
  flow:
    - design
    - build_loop
  exit_when:
    all:
      - { stage: design, field: verdict, op: eq, value: pass }
      - { stage: build_loop, field: verdict, op: eq, value: pass }
  max_iterations: 2
  on_max: halt
$2

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
  max_iterations: 1
  on_max: continue

design:
  roles: [designer]
build:
  roles: [builder]
test:
  roles: [tester]
EOF
}
TPL_NAMED="$TEST_TEMP_DIR/named.yaml";   _write_tpl "$TPL_NAMED" "  stop_round_on_fail: [design]"
TPL_PLAIN="$TEST_TEMP_DIR/plain.yaml";   _write_tpl "$TPL_PLAIN" ""

LOG="$TEST_TEMP_DIR/dispatch.log"
# shellcheck disable=SC2329  # called by the orchestrator
cycle_dispatch_stage() {
    local stage="$1" iter="$2"
    printf '%s|iter=%s\n' "$stage" "$iter" >> "$LOG"
    _CYCLE_DISPATCH_VERDICT="pass"; _CYCLE_DISPATCH_STATUS="complete"; _CYCLE_DISPATCH_REPORT="{}"
    [[ "$stage" == design && "${DESIGN:-pass}" == fail ]] && _CYCLE_DISPATCH_VERDICT="fail"
    return 0
}

_run() {   # _run <template>
    : > "$LOG"; : > "$ZBUILD_EVENTS_JSONL"
    local sf="$ZBUILD_STATE_DIR/pipeline-state.json"
    rm -f "$sf" "$sf.bak" "$sf.lock"
    jq -n '{schema_version:1, stage_statuses:{}, updated_at:"seed"}' > "$sf"
    _TPL_STAGES=(); _TPL_CYCLES=()
    load_template "$1" >/dev/null 2>&1 || { echo "load_template failed" >&2; return 99; }
    cycle_orchestrator_run outer_loop "$ZBUILD_STATE_DIR" "$sf" >/dev/null 2>&1
}
_count() { grep -c "^$1|" "$LOG" || true; }

# ── R1 ───────────────────────────────────────────────────────────────────────
DESIGN=fail _run "$TPL_NAMED"
assert_eq "[R1] design runs in both outer rounds" "2" "$(_count design)"
assert_eq "[R1] build does not run on a design that failed" "0" "$(_count build)"
assert_contains "[R1] the round is said to end early, naming the member" \
    "$(grep 'cycle.round.ended_early' "$ZBUILD_EVENTS_JSONL" || true)" '"stage":"design"'

# ── R2 ───────────────────────────────────────────────────────────────────────
DESIGN=fail _run "$TPL_PLAIN"
assert_eq "[R2] not named: build still runs" "2" "$(_count build)"

# ── R3 ───────────────────────────────────────────────────────────────────────
DESIGN=pass _run "$TPL_NAMED"
assert_eq "[R3] design passes: build runs" "1" "$(_count build)"

# ── R4 ───────────────────────────────────────────────────────────────────────
TPL_TYPO="$TEST_TEMP_DIR/typo.yaml"; _write_tpl "$TPL_TYPO" "  stop_round_on_fail: [desgin]"
_TPL_STAGES=(); _TPL_CYCLES=()
if load_template "$TPL_TYPO" >/dev/null 2>"$TEST_TEMP_DIR/typo.err"; then
    assert_fail "[R4] a name that is not a member is refused" "the template loaded"
else
    assert_pass "[R4] a name that is not a member is refused"
fi
assert_contains "[R4] ...and the error names it" "$(cat "$TEST_TEMP_DIR/typo.err")" "desgin"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
