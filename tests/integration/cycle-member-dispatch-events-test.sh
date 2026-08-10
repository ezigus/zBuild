#!/usr/bin/env bash
# Integration: Wave 19-D-1 (#731) — cycle.member.dispatch.{start,complete}
# instrumentation events.
#
# Without these events, dogfood 20260605140602-80831's "outer never dispatched
# review" forensics required code-reading. With them, the events.jsonl shows
# exactly which members the orchestrator's for-loop touched and which it
# skipped — the next dogfood's truth surface.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "cycle.member.dispatch.{start,complete} instrumentation (Wave 19-D-1 #731)"
setup_test_env "cycle-member-dispatch-events"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ZBUILD_STATE_DIR"

# shellcheck source=../../core/pipeline/cycle-orchestrator.sh
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"

STATE_FILE="$ZBUILD_STATE_DIR/pipeline-state.json"
: > "$ZBUILD_EVENTS_JSONL"
rm -f "$STATE_FILE" "${STATE_FILE}.bak" "${STATE_FILE}.lock"
jq -n '{schema_version:1, stage_statuses:{}, updated_at:"seed"}' > "$STATE_FILE"

# ── Section 1: leaf-only cycle — 2 leaves, both dispatched ──────────────────
print_test_section "1. leaf-only cycle: 2 members, 2 start + 2 complete events"

TPL1="$TEST_TEMP_DIR/leaf-cycle.yaml"
cat > "$TPL1" <<'EOF'
id: leaf_only
name: Leaf-Only Cycle
defaults:
  strategy: fanout

flow:
  - the_cycle

the_cycle:
  type: cycle
  flow:
    - build
    - review
  exit_when:
    stage: review
    field: verdict
    op: eq
    value: approve
  max_iterations: 2
  on_max: continue

build:
  roles: [builder]

review:
  roles: [reviewer]
EOF

cycle_dispatch_stage() {
    local stage="$1"
    case "$stage" in
        build)
            _CYCLE_DISPATCH_VERDICT="pass"
            _CYCLE_DISPATCH_VERDICT_RAW="pass"
            ;;
        review)
            _CYCLE_DISPATCH_VERDICT="pass"
            _CYCLE_DISPATCH_VERDICT_RAW="approve"
            ;;
        *)
            _CYCLE_DISPATCH_VERDICT="pass"
            _CYCLE_DISPATCH_VERDICT_RAW="pass"
            ;;
    esac
    _CYCLE_DISPATCH_STATUS="complete"
    return 0
}

# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
_TPL_STAGES=(); _TPL_CYCLES=()
load_template "$TPL1" || assert_fail "template load"

set +e; cycle_orchestrator_run "the_cycle" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc=$?; set -e
assert_eq "cycle converges rc=0 on iter 1" "0" "$rc"

start_count=$(jq -c 'select(.type=="cycle.member.dispatch.start" and .data.cycle_id=="the_cycle")' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "cycle.member.dispatch.start emitted 2 times (one per leaf member)" "2" "$start_count"

complete_count=$(jq -c 'select(.type=="cycle.member.dispatch.complete" and .data.cycle_id=="the_cycle")' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "cycle.member.dispatch.complete emitted 2 times" "2" "$complete_count"

first_member=$(jq -r 'select(.type=="cycle.member.dispatch.start") | .data.member' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)
assert_eq "first dispatched member = build" "build" "$first_member"

second_member=$(jq -r 'select(.type=="cycle.member.dispatch.start") | .data.member' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | sed -n '2p')
assert_eq "second dispatched member = review" "review" "$second_member"

build_kind=$(jq -r 'select(.type=="cycle.member.dispatch.start" and .data.member=="build") | .data.kind' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)
assert_eq "build member kind=leaf" "leaf" "$build_kind"

review_complete_verdict=$(jq -r 'select(.type=="cycle.member.dispatch.complete" and .data.member=="review") | .data.verdict' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)
assert_eq "review dispatch.complete verdict=approve (RAW)" "approve" "$review_complete_verdict"

review_complete_rc=$(jq -r 'select(.type=="cycle.member.dispatch.complete" and .data.member=="review") | .data.rc' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)
assert_eq "review dispatch.complete rc=0" "0" "$review_complete_rc"

build_position=$(jq -r 'select(.type=="cycle.member.dispatch.start" and .data.member=="build") | .data.position' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)
assert_eq "build dispatch.start position=1" "1" "$build_position"

review_position=$(jq -r 'select(.type=="cycle.member.dispatch.start" and .data.member=="review") | .data.position' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)
assert_eq "review dispatch.start position=2" "2" "$review_position"

# ── Section 2: 2-level cycle — nested-cycle and leaf members ────────────────
print_test_section "2. 2-level cycle: nested-cycle member kind=cycle"

: > "$ZBUILD_EVENTS_JSONL"
rm -f "$STATE_FILE" "${STATE_FILE}.bak" "${STATE_FILE}.lock"
jq -n '{schema_version:1, stage_statuses:{}, updated_at:"seed"}' > "$STATE_FILE"

TPL2="$TEST_TEMP_DIR/two-level.yaml"
cat > "$TPL2" <<'EOF'
id: two_level
name: Two-Level Nested Cycle
defaults:
  strategy: fanout

flow:
  - outer_cycle

outer_cycle:
  type: cycle
  flow:
    - inner_cycle
    - review
  exit_when:
    stage: review
    field: verdict
    op: eq
    value: approve
  max_iterations: 2
  on_max: continue

inner_cycle:
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

build:
  roles: [builder]

test:
  roles: [tester]

review:
  roles: [reviewer]
EOF

cycle_dispatch_stage() {
    local stage="$1"
    case "$stage" in
        build|test)
            _CYCLE_DISPATCH_VERDICT="pass"
            _CYCLE_DISPATCH_VERDICT_RAW="pass"
            ;;
        review)
            _CYCLE_DISPATCH_VERDICT="pass"
            _CYCLE_DISPATCH_VERDICT_RAW="approve"
            ;;
    esac
    _CYCLE_DISPATCH_STATUS="complete"
    return 0
}

_TPL_STAGES=(); _TPL_CYCLES=()
load_template "$TPL2" || assert_fail "2-level template load"

set +e; cycle_orchestrator_run "outer_cycle" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc=$?; set -e
assert_eq "outer cycle converges rc=0" "0" "$rc"

# Outer cycle's iter 1 dispatches 2 members: inner_cycle (kind=cycle) and review (kind=leaf).
outer_starts=$(jq -c 'select(.type=="cycle.member.dispatch.start" and .data.cycle_id=="outer_cycle")' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "outer cycle dispatched 2 members" "2" "$outer_starts"

inner_kind=$(jq -r 'select(.type=="cycle.member.dispatch.start" and .data.member=="inner_cycle") | .data.kind' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)
assert_eq "inner_cycle member kind=cycle" "cycle" "$inner_kind"

review_kind=$(jq -r 'select(.type=="cycle.member.dispatch.start" and .data.cycle_id=="outer_cycle" and .data.member=="review") | .data.kind' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)
assert_eq "review (outer's 2nd member) kind=leaf" "leaf" "$review_kind"

# Inner cycle ran on iter 1 → 1 inner pass (build + test both pass on first iter).
inner_starts=$(jq -c 'select(.type=="cycle.member.dispatch.start" and .data.cycle_id=="inner_cycle")' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "inner cycle dispatched 2 members (build, test)" "2" "$inner_starts"

# Critical: the nested-cycle member's dispatch.complete must record rc=0 from the inner converging.
inner_dispatch_complete_rc=$(jq -r 'select(.type=="cycle.member.dispatch.complete" and .data.member=="inner_cycle") | .data.rc' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)
assert_eq "inner_cycle dispatch.complete rc=0 (converged)" "0" "$inner_dispatch_complete_rc"

inner_dispatch_complete_verdict=$(jq -r 'select(.type=="cycle.member.dispatch.complete" and .data.member=="inner_cycle") | .data.verdict' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)
assert_eq "inner_cycle dispatch.complete verdict=pass" "pass" "$inner_dispatch_complete_verdict"

# ── Section 3: inner exhausts with FAILING tests → outer HALTS (#1208) ──────
print_test_section "3. inner exhausts with failing tests → outer halts (never advisory-rescued, #1208)"

: > "$ZBUILD_EVENTS_JSONL"
rm -f "$STATE_FILE" "${STATE_FILE}.bak" "${STATE_FILE}.lock"
jq -n '{schema_version:1, stage_statuses:{}, updated_at:"seed"}' > "$STATE_FILE"

# Inner ALWAYS returns test=fail → inner hits max_iterations=3 with FAILING tests.
# #1208 by-severity: exhaustion with failing tests → rc=8 (the single fatal
# condition — never ship failing/incomplete work). A nested rc=8 propagates to
# the outer as a blocking_member_failure (cycle-orchestrator.sh:1278), so the
# outer HALTS (rc=8) and does NOT dispatch the downstream review — a failing
# build/test cycle is NOT rescued by an advisory review gate. (Pre-#1208 the
# inner exhaustion returned rc=1 and the outer's review could approve a still-
# failing tree — exactly the #944 false-`complete` class this fixes.)
cycle_dispatch_stage() {
    local stage="$1"
    case "$stage" in
        build)
            _CYCLE_DISPATCH_VERDICT="pass"
            _CYCLE_DISPATCH_VERDICT_RAW="pass"
            ;;
        test)
            _CYCLE_DISPATCH_VERDICT="fail"
            _CYCLE_DISPATCH_VERDICT_RAW="fail"
            ;;
        review)
            _CYCLE_DISPATCH_VERDICT="pass"
            _CYCLE_DISPATCH_VERDICT_RAW="approve"
            ;;
    esac
    _CYCLE_DISPATCH_STATUS="complete"
    # #1822: every INNER leaf publishes a disposition, exactly as the runner's
    # real dispatch hook does. The outer's nested-cycle member must not inherit
    # it — see the assertion below.
    _CYCLE_DISPATCH_DISPOSITION="interrupted"
    return 0
}

_TPL_STAGES=(); _TPL_CYCLES=()
load_template "$TPL2" || assert_fail "2-level template load (section 3)"

set +e; cycle_orchestrator_run "outer_cycle" "$ZBUILD_STATE_DIR" "$STATE_FILE"; rc=$?; set -e

# Instrumentation intact: the inner-cycle member's start+complete pair still fires.
inner_start=$(jq -c 'select(.type=="cycle.member.dispatch.start" and .data.cycle_id=="outer_cycle" and .data.member=="inner_cycle")' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "inner_cycle dispatch.start emitted (instrumentation intact)" "1" "$inner_start"

inner_member_complete_rc=$(jq -r 'select(.type=="cycle.member.dispatch.complete" and .data.member=="inner_cycle") | .data.rc' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)
assert_eq "inner_cycle dispatch.complete rc=8 (#1208: exhausted with failing tests)" "8" "$inner_member_complete_rc"

inner_member_complete_verdict=$(jq -r 'select(.type=="cycle.member.dispatch.complete" and .data.member=="inner_cycle") | .data.verdict' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)
assert_eq "inner_cycle dispatch.complete verdict=blocking_member_failure (propagated)" \
    "blocking_member_failure" "$inner_member_complete_verdict"

# #1822: the disposition channel is a global, and every inner leaf above set it
# to `interrupted`. A nested cycle is not a plugin and declares no disposition,
# so the outer's event for this member must be EMPTY — not the inner cycle's
# last leaf value. Same leak class Wave 19-C-2 (#726) fixed for the verdict
# channel; without the clear, a nested-cycle failure would be reported to an
# operator as retryable purely because its last inner member happened to be.
inner_member_complete_disp=$(jq -r 'select(.type=="cycle.member.dispatch.complete" and .data.member=="inner_cycle") | .data.disposition // ""' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)
assert_eq "inner_cycle dispatch.complete disposition is EMPTY (no inner-member leak)" \
    "" "$inner_member_complete_disp"
# And the inner cycle's OWN leaf members do carry theirs — proving the clear is
# scoped to the nested-cycle member, not a blanket suppression.
inner_leaf_disp=$(jq -r 'select(.type=="cycle.member.dispatch.complete" and .data.member=="build") | .data.disposition // ""' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)
assert_eq "an inner LEAF member still reports its own disposition" \
    "interrupted" "$inner_leaf_disp"

# The KEY #1208 ASSERTION: a failing inner cycle HALTS the outer — review is NOT
# reached (no advisory rescue of failing tests).
review_dispatched=$(jq -c 'select(.type=="cycle.member.dispatch.start" and .data.cycle_id=="outer_cycle" and .data.member=="review")' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "review NOT dispatched after a failing inner cycle (#1208 halt, no rescue)" "0" "$review_dispatched"

assert_eq "outer cycle halts rc=8 (blocking_member_failure propagated)" "8" "$rc"

print_test_results
cleanup_test_env
exit $((FAIL > 0))
