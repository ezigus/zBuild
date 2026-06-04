#!/usr/bin/env bash
# Integration test: cycle orchestrator emits the correct vertical spacing
# between member stages within an iter and between iters (#682, Wave 15-D).
#
# Expected layout (>=2 iters):
#   ─── iter 1/M ───   ← preceded by 1 blank (divider already emits \n)
#     <blank>
#     [member 1 banner]
#     <blank>
#     [member 2 banner]
#     <blank>
#     [member 3 banner]
#   ↳ iter 1 complete
#
#   <blank>           ← extra blank emitted by orchestrator BEFORE iter 2
#   ─── iter 2/M ───
#     ...
#
# This test captures stderr (where dividers + spacing go) and counts the blank
# lines between specific anchor lines.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "cycle orchestrator inter-stage / inter-iter spacing (#682)"
setup_test_env "cycle-iter-spacing"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ZBUILD_STATE_DIR"

# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"
# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/template.sh"

STATE_FILE="$ZBUILD_STATE_DIR/pipeline-state.json"

# Stand-in iter-begin hook that emits a simple divider line so the spacing
# test can anchor on "iter N/M". The production divider is rendered by the
# runner; we just need a stable anchor line here.
cycle_iter_begin_hook() {
    local cycle_id="$1" iter="$2" max="$3"
    printf '\n─── iter %s/%s ───\n' "$iter" "$max" >&2
}
cycle_iter_complete_hook() {
    local cycle_id="$1" iter="$2" verdict="$3"
    printf '↳ iter %s complete: verdict=%s\n' "$iter" "$verdict" >&2
}

cycle_dispatch_stage() {
    local stage="$1" iter="$2"
    # Emit one anchor line per stage member so we can grep the order.
    printf '[MEMBER iter=%s stage=%s]\n' "$iter" "$stage" >&2
    if [[ "$stage" == "test_assessment" && "$iter" -ge 2 ]]; then
        _CYCLE_DISPATCH_VERDICT="pass"; _CYCLE_DISPATCH_STATUS="complete"
    else
        _CYCLE_DISPATCH_VERDICT="fail"; _CYCLE_DISPATCH_STATUS="failed"
    fi
    return 0
}

TPL="$TEST_TEMP_DIR/spacing-cycle.yaml"
cat >"$TPL" <<'YAML'
id: spacing-cycle
name: Spacing cycle
defaults:
  strategy: fanout
stages:
  - id: build-test
    type: cycle
    stages: [build, test, test_assessment]
    until:
      stage: test_assessment
      field: verdict
      op: eq
      value: pass
    max_iterations: 5
    on_max: continue
stage_definitions:
  build:
    roles: [builder]
  test:
    roles: [tester]
  test_assessment:
    roles: [assessor]
YAML

jq -n '{schema_version:1, stage_statuses:{}, updated_at:"seed"}' > "$STATE_FILE"
load_template "$TPL"

CAP="$TEST_TEMP_DIR/stderr.cap"
set +e
( cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE" ) 2>"$CAP"
rc=$?
set -e
assert_eq "orchestrator converged" "0" "$rc"

# Count blank lines BEFORE iter 2 anchor (between iter 1 trailer and iter 2 divider).
# Pattern: find the line range from first iter trailer (↳ iter 1 complete) up to
# the iter 2 divider line ("iter 2/"), then count truly-blank lines in that gap.
gap_before_iter2_blanks=0
if grep -q 'iter 2/' "$CAP"; then
    # Lines from after "↳ iter 1 complete" up to and excluding "iter 2/" line.
    awk '
        /↳ iter 1 complete/ { found=1; next }
        found && /iter 2\// { exit }
        found && /^$/ { c++ }
        END { print c+0 }
    ' "$CAP" > "$TEST_TEMP_DIR/blanks_gap.txt"
    gap_before_iter2_blanks="$(cat "$TEST_TEMP_DIR/blanks_gap.txt")"
fi
# Expected: 1 blank from divider's leading \n + 1 extra emitted by orchestrator
# pre-iter (for iter>=2) = 2 blank lines.
if [[ "$gap_before_iter2_blanks" -ge 2 ]]; then
    assert_pass "≥2 blank lines between iter 1 trailer and iter 2 divider (got $gap_before_iter2_blanks)"
else
    assert_fail "≥2 blank lines between iter 1 trailer and iter 2 divider" "got $gap_before_iter2_blanks"
fi

# Count blank lines between two consecutive [MEMBER] anchors within iter 1.
# Expect at least 1 (orchestrator emits one blank before each member banner).
gap_between_members_blanks="$(
    awk '
        /\[MEMBER iter=1 stage=build\]/  { in_gap=1; next }
        /\[MEMBER iter=1 stage=test\]/   { exit }
        in_gap && /^$/ { c++ }
        END { print c+0 }
    ' "$CAP"
)"
if [[ "$gap_between_members_blanks" -ge 1 ]]; then
    assert_pass "≥1 blank line between member stages within iter (got $gap_between_members_blanks)"
else
    assert_fail "≥1 blank line between member stages within iter" "got $gap_between_members_blanks"
fi

# Negative: gap between members must be STRICTLY LESS than gap between iters,
# so the operator sees inter-iter > inter-stage visually.
if [[ "$gap_before_iter2_blanks" -gt "$gap_between_members_blanks" ]]; then
    assert_pass "inter-iter gap > inter-stage gap (visual hierarchy)"
else
    assert_fail "inter-iter gap > inter-stage gap" \
        "iter=$gap_before_iter2_blanks member=$gap_between_members_blanks"
fi

print_test_results
cleanup_test_env
