#!/usr/bin/env bash
# Tests: core/pipeline/template.sh — `cycles:` overlay parser (ADR-021, #512)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/pipeline/template — cycles overlay parser (ADR-021)"
setup_test_env "pipeline-template-cycles"

# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/template.sh"

FIXT="$REPO_ROOT/tests/fixtures/templates"

# T1: multi-cycle fixture (#979 — replaces the retired standard.yaml as the
# nested-multi-cycle parser probe). Declares 3 cycles (verify_cycle, outer_cycle,
# inner_cycle); outer_cycle's flow lists inner_cycle → the parser FOLDS the inner
# cycle into the outer's single dispatch unit. Dispatch units:
#   stage:intake, stage:plan, cycle:verify_cycle, cycle:outer_cycle, stage:pr (5).
load_template "$FIXT/multi-cycle.yaml"
assert_eq "multi-cycle: 3 cycles declared (verify + outer + inner-folded)" \
    "3" "${#_TPL_CYCLES[@]}"
assert_eq "multi-cycle: 5 dispatch units" "5" "${#_TPL_DISPATCH_UNITS[@]}"
has_cycle_unit=0
has_verify_cycle=0
has_plan_stage=0
has_pr_stage=0
for u in "${_TPL_DISPATCH_UNITS[@]}"; do
    [[ "$u" == "cycle:outer_cycle" ]] && has_cycle_unit=1
    [[ "$u" == "cycle:verify_cycle" ]] && has_verify_cycle=1
    [[ "$u" == "stage:plan" ]] && has_plan_stage=1
    [[ "$u" == "stage:pr" ]] && has_pr_stage=1
done
assert_eq "multi-cycle: declares cycle:outer_cycle dispatch unit (outermost)" \
    "1" "$has_cycle_unit"
assert_eq "multi-cycle: declares cycle:verify_cycle dispatch unit" \
    "1" "$has_verify_cycle"
assert_eq "multi-cycle: declares stage:plan dispatch unit (leaf)" \
    "1" "$has_plan_stage"
assert_eq "multi-cycle: declares stage:pr dispatch unit (leaf)" \
    "1" "$has_pr_stage"
# #845: the velocity-plateau early-exit wiring must survive the parse. This pins
# the inner_cycle's window=2 wiring so the feature can't silently regress to inert
# (window unset = disabled). window=2 (< max_iterations=3) makes a stuck cycle
# abandon early. See ADR-021 "Flat-velocity plateau termination" amendment.
assert_eq "multi-cycle: inner_cycle wires velocity_plateau.window=2 (#845)" \
    "2" "${_TPL_CYCLE_VELOCITY_PLATEAU_W_inner_cycle:-}"

# T2: cycle-converges-iter2 — one cycle declared, dispatch unit emitted once
load_template "$FIXT/cycle-converges-iter2.yaml"
assert_eq "cycle-converges-iter2: 1 cycle declared" "1" "${#_TPL_CYCLES[@]}"
assert_eq "cycle-converges-iter2: cycle id" "build-test" "${_TPL_CYCLES[0]}"
# 2 stages, both in cycle → 1 dispatch unit
assert_eq "cycle-converges-iter2: 1 dispatch unit (cycle:build-test)" "1" "${#_TPL_DISPATCH_UNITS[@]}"
assert_eq "cycle-converges-iter2: dispatch unit is cycle:build-test" "cycle:build-test" "${_TPL_DISPATCH_UNITS[0]}"
assert_eq "cycle-converges-iter2: max_iterations=5" "5" "${_TPL_CYCLE_MAX_build_test:-}"
assert_eq "cycle-converges-iter2: until.stage=test" "test" "${_TPL_CYCLE_UNTIL_STAGE_build_test:-}"
assert_eq "cycle-converges-iter2: until.field=verdict" "verdict" "${_TPL_CYCLE_UNTIL_FIELD_build_test:-}"
assert_eq "cycle-converges-iter2: until.op=eq" "eq" "${_TPL_CYCLE_UNTIL_OP_build_test:-}"
assert_eq "cycle-converges-iter2: until.value=pass" "pass" "${_TPL_CYCLE_UNTIL_VALUE_build_test:-}"

# T3: cycle-feedback — feedback records parsed (no schema validation here;
# orchestrator interprets later).
load_template "$FIXT/cycle-feedback.yaml"
fb="${_TPL_CYCLE_FEEDBACK_build_test:-}"
assert_contains "cycle-feedback: feedback record references test/primary.txt" "$fb" "test:primary.txt"
assert_contains "cycle-feedback: feedback record references build/prior_test_result" "$fb" "build:prior_test_result"

# T4: max_iterations out of range (11) → rc=1  (#585: v2 inline cycle syntax)
BAD_MAX_TPL="$TEST_TEMP_DIR/bad-max.yaml"
cat > "$BAD_MAX_TPL" <<'EOF'
id: bad-max
defaults: {strategy: fanout}
stages:
  - id: build-test
    type: cycle
    stages: [build, test]
    until: { stage: test, field: verdict, op: eq, value: pass }
    max_iterations: 11
stage_definitions:
  build:
    roles: [builder]
  test:
    roles: [tester]
EOF
set +e; err="$(load_template "$BAD_MAX_TPL" 2>&1)"; rc=$?; set -e
assert_eq "bad-max: load_template rc != 0" "1" "$rc"
assert_contains "bad-max: error mentions 1..10" "$err" "1..10"

# T5: missing max_iterations → rc=1
NO_MAX_TPL="$TEST_TEMP_DIR/no-max.yaml"
cat > "$NO_MAX_TPL" <<'EOF'
id: no-max
defaults: {strategy: fanout}
stages:
  - id: just-build
    type: cycle
    stages: [build]
    until: { stage: build, field: verdict, op: eq, value: pass }
stage_definitions:
  build:
    roles: [builder]
EOF
set +e; err="$(load_template "$NO_MAX_TPL" 2>&1)"; rc=$?; set -e
assert_eq "no-max: load_template rc != 0" "1" "$rc"
assert_contains "no-max: error mentions max_iterations" "$err" "max_iterations"

# T6: until.stage outside cycle → rc=1
BAD_UNTIL_TPL="$TEST_TEMP_DIR/bad-until.yaml"
cat > "$BAD_UNTIL_TPL" <<'EOF'
id: bad-until
defaults: {strategy: fanout}
stages:
  - id: just-build
    type: cycle
    stages: [build]
    until: { stage: test, field: verdict, op: eq, value: pass }
    max_iterations: 3
stage_definitions:
  build:
    roles: [builder]
  test:
    roles: [tester]
EOF
set +e; err="$(load_template "$BAD_UNTIL_TPL" 2>&1)"; rc=$?; set -e
assert_eq "bad-until: load_template rc != 0" "1" "$rc"
assert_contains "bad-until: error mentions until.stage" "$err" "until.stage"

# T7: non-contiguous subsequence → rc=1
NON_CONTIG_TPL="$TEST_TEMP_DIR/non-contig.yaml"
cat > "$NON_CONTIG_TPL" <<'EOF'
id: non-contig
defaults: {strategy: fanout}
stages:
  - id: skip-cycle
    type: cycle
    stages: [plan, test]
    until: { stage: test, field: verdict, op: eq, value: pass }
    max_iterations: 2
stage_definitions:
  plan:
    roles: [planner]
  build:
    roles: [builder]
  test:
    roles: [tester]
EOF
set +e; err="$(load_template "$NON_CONTIG_TPL" 2>&1)"; rc=$?; set -e
assert_eq "non-contig: load_template rc != 0" "1" "$rc"
# #585 v2: legacy "non-contiguous subsequence" rule no longer applies because
# v2 has no top-level flat stages list — cycle.stages IS the cycle. This
# fixture now fails earlier (inline-flow until: { … } isn't parsed → until.stage
# unset → "until.stage required"). The intent of T7 (reject a malformed cycle
# declaration) is preserved by the rc != 0 assertion above.
assert_contains "non-contig: error fires before/at validation" "$err" "until.stage"

# T8: overlapping cycles → rc=1 (#585: inline form makes structural overlap
# very tricky to express; emulate by repeating a member id across two cycles.)
OVERLAP_TPL="$TEST_TEMP_DIR/overlap.yaml"
cat > "$OVERLAP_TPL" <<'EOF'
id: overlap
defaults: {strategy: fanout}
stages:
  - id: c1
    type: cycle
    stages: [build, test]
    until: { stage: test, field: verdict, op: eq, value: pass }
    max_iterations: 2
  - id: c2
    type: cycle
    stages: [test, review]
    until: { stage: review, field: verdict, op: eq, value: pass }
    max_iterations: 2
stage_definitions:
  build:
    roles: [builder]
  test:
    roles: [tester]
  review:
    roles: [reviewer]
EOF
set +e; err="$(load_template "$OVERLAP_TPL" 2>&1)"; rc=$?; set -e
assert_eq "overlap: load_template rc != 0" "1" "$rc"

# T9: regression — load_template still succeeds and _TPL_STAGES intact for the
# nested multi-cycle fixture (flat expansion = 8 canonical leaf stages).
load_template "$FIXT/multi-cycle.yaml"
assert_eq "regression: multi-cycle has 8 flat stages" "8" "${#_TPL_STAGES[@]}"
assert_eq "regression: multi-cycle has 3 cycles (verify + outer + inner)" \
    "3" "${#_TPL_CYCLES[@]}"

# ───────────────────────── #585: v2 inline cycle syntax ──────────────────────

# T10: legacy `cycles:` block now hard-fails with helpful migration message.
LEGACY_TPL="$TEST_TEMP_DIR/legacy-cycles.yaml"
cat > "$LEGACY_TPL" <<'EOF'
id: legacy
defaults: {strategy: fanout}
stages:
  - id: build
    roles: [builder]
  - id: test
    roles: [tester]
cycles:
  - id: build-test
    stages: [build, test]
    until: { stage: test, field: verdict, op: eq, value: pass }
    max_iterations: 3
EOF
set +e; err="$(load_template "$LEGACY_TPL" 2>&1)"; rc=$?; set -e
assert_eq "v2/legacy: load_template rc != 0" "1" "$rc"
assert_contains "v2/legacy: error mentions legacy cycles block" "$err" "legacy 'cycles:' block"
assert_contains "v2/legacy: error points to migrate-template-v2.sh" "$err" "migrate-template-v2.sh"

# T11: canonical-stages contract accepts cycle ids (separate namespace).
# inner_cycle is NOT a canonical stage but appears in _TPL_CYCLES[]; the
# flat _TPL_STAGES[] still contains only leaf members.
load_template "$FIXT/multi-cycle.yaml"
has_cycle_id=0
for cid in "${_TPL_CYCLES[@]}"; do
    [[ "$cid" == "inner_cycle" ]] && has_cycle_id=1
done
assert_eq "v2/namespace: inner_cycle present in _TPL_CYCLES" "1" "$has_cycle_id"
flat_has_cycle_name=0
for s in "${_TPL_STAGES[@]}"; do
    [[ "$s" == "inner_cycle" ]] && flat_has_cycle_name=1
done
assert_eq "v2/namespace: inner_cycle absent from flat _TPL_STAGES" "0" "$flat_has_cycle_name"

# T12: _TPL_STAGES[] flat list includes nested cycle members in declaration order.
load_template "$FIXT/multi-cycle.yaml"
expected_flat="intake plan design impact build test acceptance-gate pr"
actual_flat="${_TPL_STAGES[*]}"
assert_eq "v2/flat: _TPL_STAGES expansion preserves declaration order" "$expected_flat" "$actual_flat"

# T13: nested folding — outer_cycle is the OUTERMOST cycle and absorbs inner_cycle
# (+ acceptance-gate) under one dispatch unit.
expected_units="stage:intake stage:plan cycle:verify_cycle cycle:outer_cycle stage:pr"
actual_units="${_TPL_DISPATCH_UNITS[*]}"
assert_eq "v2/dispatch: units match expected (nested outer-cycle folding)" \
    "$expected_units" "$actual_units"

# T14: stage_definitions attr propagation — build's router.timeout_s=900
# comes from the fixture's build.router.timeout_s.
assert_eq "v2/attrs: build.router.timeout_s reaches _TPL_STAGE_ROUTER_TIMEOUT_build" "900" "${_TPL_STAGE_ROUTER_TIMEOUT_build:-}"
# design roles = [designer]
assert_eq "v2/attrs: design.roles propagated" "designer" "${_TPL_STAGE_ROLES_design:-}"

# T15: missing stage_definitions entry for a cycle member → rc=1
MISSING_DEF_TPL="$TEST_TEMP_DIR/missing-def.yaml"
cat > "$MISSING_DEF_TPL" <<'EOF'
id: missing-def
defaults: {strategy: fanout}
stages:
  - id: build-test
    type: cycle
    stages: [build, test]
    until: { stage: test, field: verdict, op: eq, value: pass }
    max_iterations: 2
stage_definitions:
  build:
    roles: [builder]
EOF
set +e; err="$(load_template "$MISSING_DEF_TPL" 2>&1)"; rc=$?; set -e
assert_eq "v2/missing-def: load_template rc != 0" "1" "$rc"
assert_contains "v2/missing-def: error names the missing stage" "$err" "stage_definitions.test"

print_test_results
