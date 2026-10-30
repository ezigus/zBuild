#!/usr/bin/env bash
# Tests: ADR-027 recursive-flow loader — new-shape template parsing (Wave 17-B, #703)
#
# Asserts the new top-level `flow:` + stage-section shape loads correctly:
#   - reserved metadata (id, name, defaults) extracted
#   - top-level flow list captured
#   - leaf stage sections parsed into _TPL_STAGE_* per-id vars
#   - cycle stage section parsed into _TPL_CYCLE_* + _TPL_STAGE_TYPE_<id>=cycle
#   - exit_when / abort_when (optional) parsed
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

# T8: (retired) cycle `feedback:` wires — load_template refuses them
# (ADR-055 §4, amended 2026-10-12; core-pipeline-template-cycles-test.sh T3).

# T9: per-stage attrs parsed for cycle members (build/test/test_assessment).
assert_eq "T9: build roles" "builder" "${_TPL_STAGE_ROLES_build:-}"
assert_eq "T9: test roles" "tester" "${_TPL_STAGE_ROLES_test:-}"
assert_eq "T9: build router.timeout_s=900" "900" \
    "${_TPL_STAGE_ROUTER_TIMEOUT_build:-}"

# T10: per-stage io for leaf stage.
assert_eq "T10: intake io dests" "file,stdout" \
    "${_TPL_STAGE_IO_DESTS_intake:-}"

# T11 (Copilot P2): inline-list `flow: [a, b]` form is detected as new shape
# and parses correctly (mirrors what the cycle `flow:` already supports).
INLINE_TPL="$TEST_TEMP_DIR/inline-flow.yaml"
cat > "$INLINE_TPL" <<'EOF'
id: inline
flow: [intake, plan, review]

intake:
  roles: [intake]

plan:
  roles: [planner]

review:
  roles: [reviewer]
EOF
_TPL_STAGES=()
_TPL_CYCLES=()
set +e
load_template "$INLINE_TPL"; rc=$?
set -e
assert_eq "T11: inline flow form loads rc=0" "0" "$rc"
assert_eq "T11: stages from inline flow" "intake plan review" "${_TPL_STAGES[*]}"

# ── [#1760/SPEC-1] abort_when.op outside the eight-op set refused at load ──────
# load_template must return non-zero and emit an error naming the loop ID,
# the field, the bad op, and the valid set. Tests FAIL before #1760 (no
# abort_when op validation in _tpl_validate_cycles).

BAD_AW_OP_TPL="$TEST_TEMP_DIR/bad-abort-op.yaml"
cat > "$BAD_AW_OP_TPL" <<'EOF'
id: bad-abort-op
name: Bad abort_when op test
defaults:
  strategy: fanout

flow:
  - the_cycle

the_cycle:
  type: cycle
  flow:
    - review
  exit_when:
    stage: review
    field: verdict
    op: eq
    value: pass
  abort_when:
    stage: review
    field: verdict
    op: contains_all
    value: block
  max_iterations: 2
  on_max: continue

review:
  roles: [reviewer]
EOF

_TPL_STAGES=(); _TPL_CYCLES=()
set +e
bad_aw_err=$(load_template "$BAD_AW_OP_TPL" 2>&1); bad_aw_rc=$?
set -e
assert_eq "[#1760/SPEC-1] abort_when bad op refused (rc!=0)" "1" "$bad_aw_rc"
assert_contains "[#1760/SPEC-1] error names the loop" "$bad_aw_err" "the_cycle"
assert_contains "[#1760/SPEC-1] error names the field" "$bad_aw_err" "verdict"
assert_contains "[#1760/SPEC-1] error names the bad op" "$bad_aw_err" "contains_all"
# The valid set must appear (at minimum 'eq' and at least one other new op)
if grep -qE 'eq.*neq|neq.*eq' <<< "$bad_aw_err" 2>/dev/null || \
   grep -qE 'eq|neq|gt|gte|lt|lte|contains|matches' <<< "$bad_aw_err" 2>/dev/null; then
    assert_pass "[#1760/SPEC-1] error names the valid op set"
else
    assert_fail "[#1760/SPEC-1] error names the valid op set" \
        "expected valid set mention in: $bad_aw_err"
fi

# ── [#1760/SPEC-2] single-condition until.op outside eight-op set refused ──────
# The single-condition exit_when op must also be validated at load time.
# Tests FAIL before #1760 (single-condition until.op has no validation).

BAD_UNTIL_OP_TPL="$TEST_TEMP_DIR/bad-until-op.yaml"
cat > "$BAD_UNTIL_OP_TPL" <<'EOF'
id: bad-until-op
name: Bad single-condition exit_when op
defaults:
  strategy: fanout

flow:
  - the_cycle

the_cycle:
  type: cycle
  flow:
    - review
  exit_when:
    stage: review
    field: verdict
    op: in
    value: pass
  max_iterations: 2
  on_max: continue

review:
  roles: [reviewer]
EOF

_TPL_STAGES=(); _TPL_CYCLES=()
set +e
bad_until_err=$(load_template "$BAD_UNTIL_OP_TPL" 2>&1); bad_until_rc=$?
set -e
assert_eq "[#1760/SPEC-2] single-condition bad op refused (rc!=0)" "1" "$bad_until_rc"
assert_contains "[#1760/SPEC-2] error names the loop" "$bad_until_err" "the_cycle"
assert_contains "[#1760/SPEC-2] error names the bad op" "$bad_until_err" "in"

# ── [#1760/SPEC-3] multi-condition exit_when op outside eight-op set refused ──
# Each condition's op in a multi-condition exit_when must be validated.
# Old code validates only eq|ne|in; tests FAIL before #1760 (ne is rejected
# post-fix since it is not in the eight-op set).

BAD_MULTI_OP_TPL="$TEST_TEMP_DIR/bad-multi-op.yaml"
cat > "$BAD_MULTI_OP_TPL" <<'EOF'
id: bad-multi-op
name: Bad multi-condition exit_when op
defaults:
  strategy: fanout

flow:
  - the_cycle

the_cycle:
  type: cycle
  flow:
    - gate_a
  exit_when:
    all:
      - { stage: gate_a, field: verdict, op: ne, value: fail }
  max_iterations: 2
  on_max: continue

gate_a:
  roles: [checker]
EOF

_TPL_STAGES=(); _TPL_CYCLES=()
set +e
bad_multi_err=$(load_template "$BAD_MULTI_OP_TPL" 2>&1); bad_multi_rc=$?
set -e
assert_eq "[#1760/SPEC-3] multi-condition bad op refused (rc!=0)" "1" "$bad_multi_rc"
assert_contains "[#1760/SPEC-3] error names the loop" "$bad_multi_err" "the_cycle"
assert_contains "[#1760/SPEC-3] error names the bad op" "$bad_multi_err" "ne"

# ── [#1760/SPEC-9] ADR-027 has ## Enforced by section; removed from baseline ──
# Post-fix, ADR-027 gains its "## Enforced by" section naming the test files
# that enforce the eight-op set.  The baseline entry is removed at the same time.
# This test does not need to fail before the change (no-code SPEC).

ADR027="$REPO_ROOT/docs/adr/ADR-027-recursive-flow-template-format.md"
if grep -q '## Enforced by' "$ADR027" 2>/dev/null; then
    assert_pass "[#1760/SPEC-9] ADR-027 has ## Enforced by section"
else
    assert_fail "[#1760/SPEC-9] ADR-027 has ## Enforced by section" \
        "section missing from $ADR027"
fi

# Extract the ## Enforced by section content (from its heading to the next
# level-2 heading). Then verify each of the four test files that enforce
# the eight-op set are named inside it.
_spec9_section=$(awk '/^## Enforced by/{f=1;next} f && /^## /{exit} f{print}' "$ADR027" 2>/dev/null || true)
for _spec9_file in \
    "tests/unit/template-loader-recursive-flow-test.sh" \
    "tests/integration/cycle-abort-when-no-match-converges-test.sh" \
    "tests/integration/cycle-orchestrator-abort-when-test.sh" \
    "tests/unit/core-pipeline-cycle-events-test.sh"
do
    if grep -qF "$_spec9_file" <<< "$_spec9_section" 2>/dev/null; then
        assert_pass "[#1760/SPEC-9] ## Enforced by names $_spec9_file"
    else
        assert_fail "[#1760/SPEC-9] ## Enforced by names $_spec9_file" \
            "not found in Enforced by section of $ADR027"
    fi
done

BASELINE="$REPO_ROOT/config/adr-enforcement-baseline.txt"
if grep -qF 'ADR-027-recursive-flow-template-format.md' "$BASELINE" 2>/dev/null; then
    assert_fail "[#1760/SPEC-9] ADR-027 is removed from adr-enforcement-baseline.txt" \
        "entry still present in $BASELINE"
else
    assert_pass "[#1760/SPEC-9] ADR-027 is removed from adr-enforcement-baseline.txt"
fi

print_test_results
