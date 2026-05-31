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
assert_eq "standard.yaml: 1 cycle declared (#511 F2)" "1" "${#_TPL_CYCLES[@]}"
assert_eq "standard.yaml: cycle id is build_test_cycle" "build_test_cycle" "${_TPL_CYCLES[0]}"
# stages = intake, plan, build, test, test_assessment, review (6 — #568).
# build+test+test_assessment absorbed into 1 cycle unit → 4 dispatch units total
# (stage:intake, stage:plan, cycle:build_test_cycle, stage:review).
assert_eq "standard.yaml: 4 dispatch units" "4" "${#_TPL_DISPATCH_UNITS[@]}"
has_cycle_unit=0
for u in "${_TPL_DISPATCH_UNITS[@]}"; do
    [[ "$u" == "cycle:build_test_cycle" ]] && has_cycle_unit=1
done
assert_eq "standard.yaml: declares cycle:build_test_cycle unit" "1" "$has_cycle_unit"

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

# T4: max_iterations out of range (11) → rc=1
BAD_MAX_TPL="$TEST_TEMP_DIR/bad-max.yaml"
cat > "$BAD_MAX_TPL" <<'EOF'
id: bad-max
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
    max_iterations: 11
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
  - id: build
    roles: [builder]
cycles:
  - id: just-build
    stages: [build]
    until: { stage: build, field: verdict, op: eq, value: pass }
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
  - id: build
    roles: [builder]
  - id: test
    roles: [tester]
cycles:
  - id: just-build
    stages: [build]
    until: { stage: test, field: verdict, op: eq, value: pass }
    max_iterations: 3
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
  - id: plan
    roles: [planner]
  - id: build
    roles: [builder]
  - id: test
    roles: [tester]
cycles:
  - id: skip-cycle
    stages: [plan, test]
    until: { stage: test, field: verdict, op: eq, value: pass }
    max_iterations: 2
EOF
set +e; err="$(load_template "$NON_CONTIG_TPL" 2>&1)"; rc=$?; set -e
assert_eq "non-contig: load_template rc != 0" "1" "$rc"
assert_contains "non-contig: error mentions contiguous" "$err" "contiguous"

# T8: overlapping cycles → rc=1
OVERLAP_TPL="$TEST_TEMP_DIR/overlap.yaml"
cat > "$OVERLAP_TPL" <<'EOF'
id: overlap
defaults: {strategy: fanout}
stages:
  - id: build
    roles: [builder]
  - id: test
    roles: [tester]
  - id: review
    roles: [reviewer]
cycles:
  - id: c1
    stages: [build, test]
    until: { stage: test, field: verdict, op: eq, value: pass }
    max_iterations: 2
  - id: c2
    stages: [test, review]
    until: { stage: review, field: verdict, op: eq, value: pass }
    max_iterations: 2
EOF
set +e; err="$(load_template "$OVERLAP_TPL" 2>&1)"; rc=$?; set -e
assert_eq "overlap: load_template rc != 0" "1" "$rc"

# T9: regression — load_template still succeeds and _TPL_STAGES intact when
# cycles: absent.
load_template "$REPO_ROOT/config/templates/standard.yaml"
assert_eq "regression: standard.yaml still has 6 stages (#568)" "6" "${#_TPL_STAGES[@]}"
# #511 F2: standard.yaml now declares one cycle (build_test_cycle).
assert_eq "regression: standard.yaml has one cycle (build_test_cycle)" "1" "${#_TPL_CYCLES[@]}"

print_test_results
