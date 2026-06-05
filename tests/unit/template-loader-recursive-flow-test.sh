#!/usr/bin/env bash
# Tests: ADR-027 recursive-flow loader — new-shape template parsing (Wave 17-B, #703)
#
# Asserts the new top-level `flow:` + stage-section shape loads correctly:
#   - reserved metadata (id, name, defaults) extracted
#   - top-level flow list captured
#   - leaf stage sections parsed into _TPL_STAGE_* per-id vars
#   - cycle stage section parsed into _TPL_CYCLE_* + _TPL_STAGE_TYPE_<id>=cycle
#   - exit_when / abort_when (optional) / feedback parsed
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "template loader — ADR-027 recursive flow (Wave 17-B)"
setup_test_env "template-loader-recursive-flow"

# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"

NEW_TPL="$TEST_TEMP_DIR/new-shape.yaml"
cat > "$NEW_TPL" <<'EOF'
id: new-shape
name: New Shape Pipeline
extends: null
defaults:
  strategy: fanout

flow:
  - intake
  - plan
  - build_test_cycle
  - review

intake:
  gate: auto
  roles: [intake]
  io:
    destinations: [file, stdout]
    tail_lines: 200

plan:
  gate: auto
  roles: [planner]
  io:
    destinations: [file, stdout]
    tail_lines: 200
  router:
    timeout_s: 300
    max_turns: 25

build_test_cycle:
  type: cycle
  flow:
    - build
    - test
    - test_assessment
  exit_when:
    stage: test_assessment
    field: verdict
    op: eq
    value: pass
  max_iterations: 3
  on_max: continue
  feedback:
    - from:
        stage: test_assessment
        output: test_assessment_md
      to:
        stage: build
        input: prior_test_assessment
        required: false

build:
  gate: auto
  roles: [builder]
  io:
    destinations: [file, stdout]
    tail_lines: 200
  router:
    timeout_s: 900

test:
  gate: auto
  roles: [tester]
  io:
    destinations: [file, stdout]
    tail_lines: 200

test_assessment:
  gate: auto
  roles: [test_assessment]
  io:
    destinations: [file, stdout]
    tail_lines: 200
  router:
    timeout_s: 300
    max_turns: 25

review:
  gate: auto
  roles: [reviewer]
  io:
    destinations: [file, stdout]
    tail_lines: 200
  router:
    timeout_s: 300
    max_turns: 25
EOF

# Clear any module-level state from a previous test in the same shell.
_TPL_STAGES=()
_TPL_CYCLES=()
_TPL_DISPATCH_UNITS=()

# T1: load_template succeeds on new shape.
set +e
load_template "$NEW_TPL"; rc=$?
set -e
assert_eq "T1: load_template new shape rc=0" "0" "$rc"

# T2: top-level flow captured as _TPL_STAGES (flattened).
# Expected flat list: intake plan build test test_assessment review
joined="${_TPL_STAGES[*]}"
assert_eq "T2: _TPL_STAGES expanded flat from new flow" \
    "intake plan build test test_assessment review" "$joined"

# T3: defaults.strategy preserved.
assert_eq "T3: defaults.strategy=fanout" "fanout" "$_TPL_DEFAULT_STRATEGY"

# T4: cycle id captured.
assert_eq "T4: _TPL_CYCLES contains build_test_cycle" \
    "build_test_cycle" "${_TPL_CYCLES[*]}"

# T5: stage type discriminators set.
assert_eq "T5: build_test_cycle type=cycle" "cycle" \
    "${_TPL_STAGE_TYPE_build_test_cycle:-}"
assert_eq "T5: intake type=leaf" "leaf" "${_TPL_STAGE_TYPE_intake:-}"
assert_eq "T5: review type=leaf" "leaf" "${_TPL_STAGE_TYPE_review:-}"

# T6: cycle's exit_when fields exported in the same shape the orchestrator
# reads today (_TPL_CYCLE_UNTIL_* — back-compat with existing reader).
assert_eq "T6: until stage=test_assessment" "test_assessment" \
    "${_TPL_CYCLE_UNTIL_STAGE_build_test_cycle:-}"
assert_eq "T6: until field=verdict" "verdict" \
    "${_TPL_CYCLE_UNTIL_FIELD_build_test_cycle:-}"
assert_eq "T6: until op=eq" "eq" "${_TPL_CYCLE_UNTIL_OP_build_test_cycle:-}"
assert_eq "T6: until value=pass" "pass" \
    "${_TPL_CYCLE_UNTIL_VALUE_build_test_cycle:-}"

# T7: cycle's flow members captured.
assert_eq "T7: cycle stages csv" "build,test,test_assessment" \
    "${_TPL_CYCLE_STAGES_build_test_cycle:-}"

# T8: feedback record parsed.
fb="${_TPL_CYCLE_FEEDBACK_build_test_cycle:-}"
assert_contains "T8: feedback wires test_assessment_md -> prior_test_assessment" \
    "test_assessment:test_assessment_md|build:prior_test_assessment:false" "$fb"

# T9: per-stage attrs parsed for cycle members (build/test/test_assessment).
assert_eq "T9: build roles" "builder" "${_TPL_STAGE_ROLES_build:-}"
assert_eq "T9: test roles" "tester" "${_TPL_STAGE_ROLES_test:-}"
assert_eq "T9: build router.timeout_s=900" "900" \
    "${_TPL_STAGE_ROUTER_TIMEOUT_build:-}"

# T10: per-stage io for leaf stage.
assert_eq "T10: intake io dests" "file,stdout" \
    "${_TPL_STAGE_IO_DESTS_intake:-}"

print_test_results
