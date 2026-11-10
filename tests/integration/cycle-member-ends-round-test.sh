#!/usr/bin/env bash
# tests/integration/cycle-member-ends-round-test.sh — a stage can end its loop's
# round early, so the stage that can fix its finding runs next (#2474,
# ADR-068 §3 amended).
#
# Why: on #1805 run 42090130741 test-author found a SPEC no test can prove. Only
# design can fix it, and design is earlier in the same loop, but the finding
# halted the run (`misconfigured`) instead of sending the loop round.
#
# E1 [code]  a result that says ends_round is read as ending the round
# E2 [code]  the stage ends round 1: the later stages do not run, the event is
#            said, round 2 starts at the top, and the run goes on
# E3 [code]  it ends every round: the loop's round limit still ends the run
# E4 [guard] a blocking stage that fails without ends_round still ends the run
# E5 [guard] ends_round on a stage that passes changes nothing
# E6 [code]  the report is read as JSON, not as one way of writing it (review)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "a stage can end its loop's round early (ADR-068 §3)"
setup_test_env "cycle-member-ends-round"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ZBUILD_STATE_DIR"
# shellcheck source=../../core/pipeline/cycle-orchestrator.sh
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
# shellcheck source=../../core/pipeline/verdict.sh
source "$REPO_ROOT/core/pipeline/verdict.sh"
# shellcheck source=../../scripts/lib/stage-result.sh
source "$REPO_ROOT/scripts/lib/stage-result.sh"

# ── E1 ───────────────────────────────────────────────────────────────────────
# Given a result written by the stage's own writer, failing, with ends_round
R1="$TEST_TEMP_DIR/writer-result.json"
stage_result_write "$R1" fail "a SPEC no test can prove: design must rewrite it" '{"ends_round":true}'
# When the engine reads what the stage reported
REPORT="$(_verdict_report_from_file "$R1")"
# Then the report says the round ends
assert_eq "[E1] a result with ends_round is reported as ending the round" "true" \
    "$(jq -r '.ends_round // false' <<< "$REPORT")"
R0="$TEST_TEMP_DIR/plain-result.json"
stage_result_write "$R0" fail "an ordinary failure"
assert_eq "[E1] a result without it is not" "false" "$(jq -r '.ends_round // false' <<< "$(_verdict_report_from_file "$R0")")"

TPL="$TEST_TEMP_DIR/loop.yaml"
cat > "$TPL" <<'EOF'
id: ends-round
name: A stage ends the round
defaults:
  strategy: fanout

flow:
  - build_loop

build_loop:
  type: cycle
  flow:
    - design
    - writer
    - build
  exit_when:
    all:
      - { stage: design, field: verdict, op: eq, value: pass }
      - { stage: writer, field: verdict, op: eq, value: pass }
      - { stage: build, field: verdict, op: eq, value: pass }
  stop_run_on_fail: [design]
  max_iterations: 3
  on_max: halt

design:
  roles: [designer]
writer:
  roles: [test_author]
  blocking: true
build:
  roles: [builder]
EOF

LOG="$TEST_TEMP_DIR/dispatch.log"
# WRITER: one word a round — ends (fail, ends_round), fail (fail), pass, or
# ends_pass (pass, with ends_round).
# shellcheck disable=SC2329  # called by the orchestrator
cycle_dispatch_stage() {
    local stage="$1" iter="$2" w
    printf '%s|iter=%s\n' "$stage" "$iter" >> "$LOG"
    _CYCLE_DISPATCH_VERDICT="pass"; _CYCLE_DISPATCH_STATUS="complete"; _CYCLE_DISPATCH_REPORT="{}"
    [[ "$stage" == writer ]] || return 0
    w="$(cut -d, -f"$iter" <<< "$WRITER")"
    case "$w" in
        ends)      _CYCLE_DISPATCH_VERDICT="fail"; _CYCLE_DISPATCH_REPORT='{"ends_round":true}'; return 1 ;;
        fail)      _CYCLE_DISPATCH_VERDICT="fail"; return 1 ;;
        ends_pass) _CYCLE_DISPATCH_REPORT='{"ends_round":true}' ;;
        ends_spaced) _CYCLE_DISPATCH_VERDICT="fail"; _CYCLE_DISPATCH_REPORT=$'{\n  "ends_round": true\n}'; return 1 ;;
    esac
    return 0
}

_run() {
    : > "$LOG"; : > "$ZBUILD_EVENTS_JSONL"
    local sf="$ZBUILD_STATE_DIR/pipeline-state.json"
    rm -f "$sf" "$sf.bak" "$sf.lock"
    jq -n '{schema_version:1, stage_statuses:{}, updated_at:"seed"}' > "$sf"
    _TPL_STAGES=(); _TPL_CYCLES=()
    load_template "$TPL" >/dev/null 2>&1 || { echo "load_template failed" >&2; return 99; }
    cycle_orchestrator_run build_loop "$ZBUILD_STATE_DIR" "$sf" >/dev/null 2>&1
    RUN_RC=$?
}
_count() { grep -c "^$1|" "$LOG" || true; }

# ── E2 ───────────────────────────────────────────────────────────────────────
# Given a writer that ends round 1 and passes in round 2
# When the loop runs
WRITER=ends,pass _run
# Then build does not run in round 1, round 2 starts with design, and the run converges
assert_eq "[E2] build does not run in the round the writer ended" "0" "$(grep -c '^build|iter=1$' "$LOG" || true)"
assert_eq "[E2] round 2 starts at the top: design runs twice" "2" "$(_count design)"
assert_eq "[E2] ...and build runs in round 2" "1" "$(grep -c '^build|iter=2$' "$LOG" || true)"
assert_eq "[E2] the run goes on and converges" "0" "$RUN_RC"
assert_contains "[E2] the engine says the round was ended, and by whom" \
    "$(grep '"cycle.member.ends_round"' "$ZBUILD_EVENTS_JSONL" || true)" '"stage":"writer"'
assert_eq "[E2] no blocking failure is said" "0" "$(grep -c 'cycle.member.blocking_failure' "$ZBUILD_EVENTS_JSONL" || true)"

# ── E3 ───────────────────────────────────────────────────────────────────────
WRITER=ends,ends,ends _run
assert_eq "[E3] it ends every round: the loop runs its 3 rounds" "3" "$(_count design)"
assert_eq "[E3] ...build never runs" "0" "$(_count build)"
assert_eq "[E3] ...and the run ends failed" "1" "$RUN_RC"

# ── E4 ───────────────────────────────────────────────────────────────────────
WRITER=fail,pass _run
assert_eq "[E4] a blocking failure without ends_round still ends the run in round 1" "1" "$(_count design)"
assert_eq "[E4] ...failed" "1" "$RUN_RC"

# ── E5 ───────────────────────────────────────────────────────────────────────
WRITER=ends_pass _run
assert_eq "[E5] ends_round on a pass: build still runs in round 1" "1" "$(grep -c '^build|iter=1$' "$LOG" || true)"
assert_eq "[E5] ...and the run converges in one round" "1" "$(_count design)"

# ── E6 ───────────────────────────────────────────────────────────────────────
WRITER=ends_spaced,pass _run
assert_eq "[E6] a report written with spaces still ends the round" "2" "$(_count design)"
assert_eq "[E6] ...and the run converges" "0" "$RUN_RC"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
