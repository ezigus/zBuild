#!/usr/bin/env bash
# Tests: loop conditions use ADR-027 §5's eight ops — the review findings on
# #1760's run (ADR-027 §5, amended).
#
#   P1 [change]: `ne` reaching evaluation is refused, never evaluated as `neq`
#                (R3, R4) — in exit_when, until and abort_when
#   P2 [change]: a malformed `matches` pattern is refused at load; one that
#                reaches evaluation is an error, never a silent no-match (R2)
#   P3 [change]: a declared until or abort_when with no op is refused at load
#   P4 [change]: a number op whose value is not a number is refused at load (R2)
#   P5 [change]: an abort_when that cannot be evaluated stops the loop (the
#                safety switch fails closed) and says why
#   P6 [change]: _cycle_load_template keeps its own checks — stages, max
#                iterations, and each exit_when condition's field, op and stage
#   P7 [change]: an until condition's error says until, not exit_when
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "cycle — the eight condition ops, checked (#1760 review)"
setup_test_env "cycle-predicate-ops"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"

# shellcheck source=../../core/pipeline/cycle-orchestrator.sh
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"

# _tpl <file> <loop-body> — a template whose loop `c` holds a and b.
_tpl() {
    cat > "$1" <<EOF
id: t
name: T
flow:
  - c
c:
  type: cycle
  flow:
    - a
    - b
$2
  max_iterations: 2
a:
  roles: [builder]
b:
  roles: [tester]
EOF
}
_load() {   # _load <loop-body> — rc of load_template; its error text in $_ERR
    _TPL_STAGES=(); _TPL_CYCLES=(); _TPL_PARALLEL_GROUPS=(); _TPL_MAP_GROUPS=()
    _tpl "$TEST_TEMP_DIR/t.yaml" "$1"
    _ERR="$(load_template "$TEST_TEMP_DIR/t.yaml" 2>&1 >/dev/null)"; local rc=$?
    load_template "$TEST_TEMP_DIR/t.yaml" >/dev/null 2>&1
    return $rc
}
_rc() { "$@" >/dev/null 2>&1; printf '%s' "$?"; }
PASSB='{"a":{"verdict":"pass","status":"complete"},"b":{"verdict":"fail","status":"complete"}}'

# ─── P1 ──────────────────────────────────────────────────────────────────────
_CYCLE_TRAP_ITER=1
assert_eq "P1: exit_when: ne does not evaluate" "1" "$(_rc _cycle_eval_one_condition "$PASSB" b verdict ne pass)"
_CYCLE_EXIT_COMBINATOR=""; _CYCLE_UNTIL_STAGE=b _CYCLE_UNTIL_FIELD=verdict _CYCLE_UNTIL_OP=ne _CYCLE_UNTIL_VALUE=pass
assert_eq "P1: until: ne does not converge" "1" "$(_rc _cycle_check_until "$PASSB")"
assert_contains "P1: ...and is reported as unknown" "$(_cycle_check_until "$PASSB" 2>&1 >/dev/null)" "op 'ne' is not one of eq|neq|gt|gte|lt|lte|contains|matches"
_load "  exit_when:
    stage: b
    field: verdict
    op: eq
    value: pass
  abort_when:
    stage: b
    field: verdict
    op: ne
    value: pass"; _l=$?
assert_eq "P1: abort_when: ne is refused at load" "1" "$(( _l != 0 ))"

# ─── P2 ──────────────────────────────────────────────────────────────────────
_load "  exit_when:
    stage: b
    field: verdict
    op: matches
    value: '[unclosed'"; _l=$?
assert_eq "P2: a malformed matches pattern is refused at load" "1" "$(( _l != 0 ))"
assert_contains "P2: ...saying so" "$_ERR" "not a valid pattern"
: > "$ZBUILD_EVENTS_JSONL"
assert_eq "P2: one reaching evaluation does not match" "1" \
    "$(_rc _cycle_eval_one_condition "$PASSB" b verdict matches '[unclosed')"
assert_contains "P2: ...with an event saying why" "$(cat "$ZBUILD_EVENTS_JSONL")" "predicate_error"

# ─── P3 ──────────────────────────────────────────────────────────────────────
_load "  exit_when:
    stage: b
    field: verdict
    value: pass"; _l=$?
assert_eq "P3: an until with no op is refused at load" "1" "$(( _l != 0 ))"
assert_contains "P3: ...naming the field and the missing op" "$_ERR" "has no op"
_load "  exit_when:
    stage: b
    field: verdict
    op: eq
    value: pass
  abort_when:
    stage: b
    field: verdict
    value: fail"; _l=$?
assert_eq "P3: an abort_when with no op is refused at load" "1" "$(( _l != 0 ))"
assert_contains "P3: ...naming abort_when" "$_ERR" "abort_when"

# ─── P4 ──────────────────────────────────────────────────────────────────────
_load "  exit_when:
    stage: b
    field: verdict
    op: gt
    value: lots"; _l=$?
assert_eq "P4: a number op with a value that is not a number is refused at load" "1" "$(( _l != 0 ))"
assert_contains "P4: ...saying the value must be a number" "$_ERR" "must be a whole number"

# ─── P5 ──────────────────────────────────────────────────────────────────────
_load "  exit_when:
    stage: b
    field: verdict
    op: eq
    value: pass
  abort_when:
    stage: b
    field: verdict
    op: gt
    value: 3"; _l=$?
assert_eq "P5: a numeric abort_when loads" "0" "$_l"
_CYCLE_TRAP_CYCLE_ID=c; : > "$ZBUILD_EVENTS_JSONL"
assert_eq "P5: an abort_when on a word that is not a number stops the loop" "0" "$(_rc _cycle_check_abort_when "$PASSB")"
assert_contains "P5: ...with an event saying why" "$(cat "$ZBUILD_EVENTS_JSONL")" "predicate_error"

# ─── P6 ──────────────────────────────────────────────────────────────────────
_load "  exit_when:
    all:
      - { stage: a, field: verdict, op: eq, value: pass }
      - { stage: b, field: verdict, op: eq, value: pass }"
_CYCLE_TRAP_CYCLE_ID=c
assert_eq "P6: a loaded loop passes its own checks" "0" "$(_rc _cycle_load_template c)"
_TPL_CYCLE_EXIT_2_OP_c=ne
assert_eq "P6: an exit_when condition with a bad op is refused" "1" "$(_rc _cycle_load_template c)"
_TPL_CYCLE_EXIT_2_OP_c=eq; _TPL_CYCLE_EXIT_2_FIELD_c=score
assert_eq "P6: ...with a bad field" "1" "$(_rc _cycle_load_template c)"
_TPL_CYCLE_EXIT_2_FIELD_c=verdict; _TPL_CYCLE_EXIT_2_STAGE_c=elsewhere
assert_eq "P6: ...naming a stage outside the loop" "1" "$(_rc _cycle_load_template c)"
_TPL_CYCLE_EXIT_2_STAGE_c=b; _sv="$_TPL_CYCLE_STAGES_c"; _TPL_CYCLE_STAGES_c=""
assert_eq "P6: a loop with no stages is refused" "1" "$(_rc _cycle_load_template c)"
_TPL_CYCLE_STAGES_c="$_sv"; _TPL_CYCLE_MAX_c=""
assert_eq "P6: a loop with no max_iterations is refused" "1" "$(_rc _cycle_load_template c)"
_TPL_CYCLE_MAX_c=2

# ─── P7 ──────────────────────────────────────────────────────────────────────
_CYCLE_EXIT_COMBINATOR=""; _CYCLE_UNTIL_STAGE=b _CYCLE_UNTIL_FIELD=verdict _CYCLE_UNTIL_OP=bogus _CYCLE_UNTIL_VALUE=pass
_e="$(_cycle_check_until "$PASSB" 2>&1 >/dev/null)"
assert_contains "P7: an until error says until" "$_e" "cycle until"
assert_eq "P7: ...not exit_when" "0" "$(grep -c 'cycle exit_when' <<< "$_e" || true)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
