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

# T1: standard.yaml — #511 F2 wires the build/test cycle. Dispatch units now
# contain exactly ONE cycle:build_test_cycle entry between stage:plan and
# stage:review. Pre-F2 expectation (zero cycles) is obsoleted by #511.
load_template "$REPO_ROOT/config/templates/standard.yaml"
# Wave 18-B (#707): standard.yaml now declares 2 cycles — the inner
# build_test_cycle (#511 F2) and the outer review_cycle (ADR-026).
assert_eq "standard.yaml: 2 cycles declared (#511 F2 + #707 ADR-026)" \
    "2" "${#_TPL_CYCLES[@]}"
assert_eq "standard.yaml: cycle id is build_test_cycle" "build_test_cycle" "${_TPL_CYCLES[0]}"
# stages = intake, plan, build, test, test_assessment, review (6 — #568).
# Wave 18-B (#707): build_test_cycle is now wrapped inside the outer
# review_cycle (ADR-026), so review_cycle is the OUTERMOST cycle and absorbs
# ALL of build/test/test_assessment/review under a single dispatch unit →
# 3 dispatch units total (stage:intake, stage:plan, cycle:review_cycle).
assert_eq "standard.yaml: 3 dispatch units" "3" "${#_TPL_DISPATCH_UNITS[@]}"
has_cycle_unit=0
for u in "${_TPL_DISPATCH_UNITS[@]}"; do
    # Wave 18-B (#707): the outermost cycle (review_cycle) is what surfaces
    # in dispatch; build_test_cycle is recursed into via cycle-as-member
    # dispatch (_TPL_STAGE_TYPE_<id>=cycle, Wave 17-B).
    [[ "$u" == "cycle:review_cycle" ]] && has_cycle_unit=1
done
assert_eq "standard.yaml: declares cycle:review_cycle dispatch unit (#707 outermost)" \
    "1" "$has_cycle_unit"

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

# T9: regression — load_template still succeeds and _TPL_STAGES intact when
# cycles: absent.
load_template "$REPO_ROOT/config/templates/standard.yaml"
assert_eq "regression: standard.yaml still has 6 stages (#568)" "6" "${#_TPL_STAGES[@]}"
# #511 F2: standard.yaml now declares one cycle (build_test_cycle).
# Wave 18-B (#707): standard.yaml now declares 2 cycles after ADR-026
# (inner build_test_cycle + outer review_cycle).
assert_eq "regression: standard.yaml has 2 cycles (build_test_cycle + review_cycle)" \
    "2" "${#_TPL_CYCLES[@]}"

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
# build_test_cycle is NOT a canonical stage but appears in _TPL_CYCLES[]; the
# flat _TPL_STAGES[] still contains only canonical members.
load_template "$REPO_ROOT/config/templates/standard.yaml"
has_cycle_id=0
for cid in "${_TPL_CYCLES[@]}"; do
    [[ "$cid" == "build_test_cycle" ]] && has_cycle_id=1
done
assert_eq "v2/namespace: build_test_cycle present in _TPL_CYCLES" "1" "$has_cycle_id"
flat_has_cycle_name=0
for s in "${_TPL_STAGES[@]}"; do
    [[ "$s" == "build_test_cycle" ]] && flat_has_cycle_name=1
done
assert_eq "v2/namespace: build_test_cycle absent from flat _TPL_STAGES" "0" "$flat_has_cycle_name"

# T12: _TPL_STAGES[] flat list includes cycle members in order.
load_template "$REPO_ROOT/config/templates/standard.yaml"
expected_flat="intake plan build test test_assessment review"
actual_flat="${_TPL_STAGES[*]}"
assert_eq "v2/flat: _TPL_STAGES expansion preserves canonical order" "$expected_flat" "$actual_flat"

# T13: Wave 18-B (#707) — review_cycle is now the OUTERMOST cycle and
# absorbs build_test_cycle + review under one dispatch unit.
expected_units="stage:intake stage:plan cycle:review_cycle"
actual_units="${_TPL_DISPATCH_UNITS[*]}"
assert_eq "v2/dispatch: units match expected (#707 outermost-cycle folding)" \
    "$expected_units" "$actual_units"

# T14: stage_definitions attr propagation — build's router.timeout_s=900
# comes from standard.yaml's stage_definitions.build.router.timeout_s.
assert_eq "v2/attrs: stage_definitions.build.router.timeout_s reaches _TPL_STAGE_ROUTER_TIMEOUT_build" "900" "${_TPL_STAGE_ROUTER_TIMEOUT_build:-}"
# test_assessment roles = [test_assessment]
assert_eq "v2/attrs: stage_definitions.test_assessment.roles propagated" "test_assessment" "${_TPL_STAGE_ROLES_test_assessment:-}"

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
