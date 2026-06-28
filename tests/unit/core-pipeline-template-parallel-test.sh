#!/usr/bin/env bash
# Tests: core/pipeline/template.sh — `type: parallel` group parser (ADR-039, #1130)
# Template-layer parsing/validation only (no execution). Mirrors the cycle tests
# in core-pipeline-template-cycles-test.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/pipeline/template — parallel group parser (ADR-039)"
setup_test_env "pipeline-template-parallel"

# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/template.sh"

# ── T1: basic parallel group loads + registers state ─────────────────────────
# New-shape (ADR-027) template: a `type: parallel` group sits in the top-level
# flow; its members are leaves declared as their own top-level sections.
BASIC_TPL="$TEST_TEMP_DIR/par-basic.yaml"
cat > "$BASIC_TPL" <<'EOF'
id: par-basic
defaults:
  strategy: fanout
flow:
  - intake
  - plan
  - lenses
  - review
intake:
  roles: [intake]
plan:
  roles: [planner]
lenses:
  type: parallel
  flow:
    - design
    - build
  max_parallel: 2
  on_member_error: collect
design:
  roles: [designer]
  router:
    timeout_s: 600
build:
  roles: [builder]
review:
  roles: [reviewer]
EOF
load_template "$BASIC_TPL"

assert_eq "basic: 1 parallel group declared" "1" "${#_TPL_PARALLEL_GROUPS[@]}"
assert_eq "basic: group id is 'lenses'" "lenses" "${_TPL_PARALLEL_GROUPS[0]}"
# _TPL_PARALLEL_* state (gid 'lenses' → safe 'lenses').
assert_eq "basic: flow members csv" "design,build" "${_TPL_PARALLEL_FLOW_lenses:-}"
assert_eq "basic: max_parallel" "2" "${_TPL_PARALLEL_MAX_lenses:-}"
assert_eq "basic: on_member_error" "collect" "${_TPL_PARALLEL_ON_ERR_lenses:-}"
assert_eq "basic: member_of design" "lenses" "${_TPL_PARALLEL_MEMBER_OF_design:-}"
assert_eq "basic: member_of build" "lenses" "${_TPL_PARALLEL_MEMBER_OF_build:-}"

# ── T2: members get per-stage attr vars (like leaves) ────────────────────────
assert_eq "attrs: design roles propagated" "designer" "${_TPL_STAGE_ROLES_design:-}"
assert_eq "attrs: build roles propagated" "builder" "${_TPL_STAGE_ROLES_build:-}"
assert_eq "attrs: design router.timeout_s propagated" "600" "${_TPL_STAGE_ROUTER_TIMEOUT_design:-}"

# ── T3: stage-type discriminator (group=parallel, members=leaf) ──────────────
assert_eq "type: group lenses is parallel" "parallel" "${_TPL_STAGE_TYPE_lenses:-}"
assert_eq "type: member design is leaf" "leaf" "${_TPL_STAGE_TYPE_design:-}"
assert_eq "type: member build is leaf" "leaf" "${_TPL_STAGE_TYPE_build:-}"

# ── T4: group folds to ONE parallel:<gid> dispatch unit ──────────────────────
# Expected: stage:intake stage:plan parallel:lenses stage:review (4 units).
assert_eq "dispatch: 4 units" "4" "${#_TPL_DISPATCH_UNITS[@]}"
expected_units="stage:intake stage:plan parallel:lenses stage:review"
assert_eq "dispatch: units match expected (group folds to parallel:lenses)" \
    "$expected_units" "${_TPL_DISPATCH_UNITS[*]}"

# ── T5: members appear in flat _TPL_STAGES[], group id does NOT ──────────────
flat_has_group=0
for s in "${_TPL_STAGES[@]}"; do
    [[ "$s" == "lenses" ]] && flat_has_group=1
done
assert_eq "namespace: group 'lenses' absent from flat _TPL_STAGES" "0" "$flat_has_group"
expected_flat="intake plan design build review"
assert_eq "namespace: _TPL_STAGES expansion includes parallel members in flow order" \
    "$expected_flat" "${_TPL_STAGES[*]}"

# ── T6: member ids are canonical-exempt (reversed canonical order loads) ──────
# build (canonical pos 4) declared BEFORE design (pos 2). Without the parallel
# member order-exemption this would trip the canonical-order validator.
REV_TPL="$TEST_TEMP_DIR/par-reversed.yaml"
cat > "$REV_TPL" <<'EOF'
id: par-reversed
defaults:
  strategy: fanout
flow:
  - intake
  - reversed
  - review
intake:
  roles: [intake]
reversed:
  type: parallel
  flow:
    - build
    - design
build:
  roles: [builder]
design:
  roles: [designer]
review:
  roles: [reviewer]
EOF
set +e; err="$(load_template "$REV_TPL" 2>&1)"; rc=$?; set -e
assert_eq "exempt: reversed-canonical-order parallel members load (rc=0)" "0" "$rc"
load_template "$REV_TPL"
assert_eq "exempt: dispatch folds to parallel:reversed" \
    "stage:intake parallel:reversed stage:review" "${_TPL_DISPATCH_UNITS[*]}"
# on_member_error defaults to 'continue' when omitted; max_parallel empty (unbounded).
assert_eq "exempt: on_member_error defaults to continue" "continue" "${_TPL_PARALLEL_ON_ERR_reversed:-}"
assert_eq "exempt: max_parallel empty when omitted" "" "${_TPL_PARALLEL_MAX_reversed:-}"

# ── T7: empty member set → rc=1 ──────────────────────────────────────────────
EMPTY_TPL="$TEST_TEMP_DIR/par-empty.yaml"
cat > "$EMPTY_TPL" <<'EOF'
id: par-empty
defaults:
  strategy: fanout
flow:
  - intake
  - empties
intake:
  roles: [intake]
empties:
  type: parallel
  flow: []
EOF
set +e; err="$(load_template "$EMPTY_TPL" 2>&1)"; rc=$?; set -e
assert_eq "empty: load_template rc != 0" "1" "$rc"
assert_contains "empty: error mentions no members" "$err" "no members declared"

# ── T8: bad max_parallel (0) → rc=1 ──────────────────────────────────────────
BAD_MAX_TPL="$TEST_TEMP_DIR/par-bad-max.yaml"
cat > "$BAD_MAX_TPL" <<'EOF'
id: par-bad-max
defaults:
  strategy: fanout
flow:
  - intake
  - grp
intake:
  roles: [intake]
grp:
  type: parallel
  flow:
    - build
    - test
  max_parallel: 0
build:
  roles: [builder]
test:
  roles: [tester]
EOF
set +e; err="$(load_template "$BAD_MAX_TPL" 2>&1)"; rc=$?; set -e
assert_eq "bad-max: load_template rc != 0" "1" "$rc"
assert_contains "bad-max: error mentions max_parallel" "$err" "max_parallel"

# ── T9: bad on_member_error → rc=1 ───────────────────────────────────────────
BAD_ONERR_TPL="$TEST_TEMP_DIR/par-bad-onerr.yaml"
cat > "$BAD_ONERR_TPL" <<'EOF'
id: par-bad-onerr
defaults:
  strategy: fanout
flow:
  - intake
  - grp
intake:
  roles: [intake]
grp:
  type: parallel
  flow:
    - build
    - test
  on_member_error: explode
build:
  roles: [builder]
test:
  roles: [tester]
EOF
set +e; err="$(load_template "$BAD_ONERR_TPL" 2>&1)"; rc=$?; set -e
assert_eq "bad-onerr: load_template rc != 0" "1" "$rc"
assert_contains "bad-onerr: error mentions on_member_error" "$err" "on_member_error"

# ── T10: member shared with a cycle → rc=1 (disjointness) ────────────────────
CYC_OVERLAP_TPL="$TEST_TEMP_DIR/par-cycle-overlap.yaml"
cat > "$CYC_OVERLAP_TPL" <<'EOF'
id: par-cycle-overlap
defaults:
  strategy: fanout
flow:
  - intake
  - bt
  - grp
intake:
  roles: [intake]
bt:
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
grp:
  type: parallel
  flow:
    - test
    - review
build:
  roles: [builder]
test:
  roles: [tester]
review:
  roles: [reviewer]
EOF
set +e; err="$(load_template "$CYC_OVERLAP_TPL" 2>&1)"; rc=$?; set -e
assert_eq "cyc-overlap: load_template rc != 0" "1" "$rc"
assert_contains "cyc-overlap: error mentions disjoint from cycles" "$err" "disjoint from cycles"

# ── T11: two parallel groups sharing a member → rc=1 (overlap) ───────────────
GRP_OVERLAP_TPL="$TEST_TEMP_DIR/par-group-overlap.yaml"
cat > "$GRP_OVERLAP_TPL" <<'EOF'
id: par-group-overlap
defaults:
  strategy: fanout
flow:
  - intake
  - g1
  - g2
intake:
  roles: [intake]
g1:
  type: parallel
  flow:
    - design
    - build
g2:
  type: parallel
  flow:
    - build
    - test
design:
  roles: [designer]
build:
  roles: [builder]
test:
  roles: [tester]
EOF
set +e; err="$(load_template "$GRP_OVERLAP_TPL" 2>&1)"; rc=$?; set -e
assert_eq "grp-overlap: load_template rc != 0" "1" "$rc"
assert_contains "grp-overlap: error mentions another parallel group" "$err" "another parallel group"

print_test_results
