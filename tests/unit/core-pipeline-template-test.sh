#!/usr/bin/env bash
# Tests: core/pipeline/template.sh — template loading and stage resolution
# ADR-009 (platform-aware modularity), ADR-013 (canonical stage sequence)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEMPLATE_SH="$REPO_ROOT/core/pipeline/template.sh"

# shellcheck source=../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/pipeline/template — template loading and stage resolution (ADR-009)"
setup_test_env "pipeline-template"

# ─── Fixtures ────────────────────────────────────────────────────────────────

STANDARD_TPL="$REPO_ROOT/config/templates/standard.yaml"

# A minimal custom template for per-stage strategy override testing
CUSTOM_TPL="$TEST_TEMP_DIR/custom.yaml"
cat > "$CUSTOM_TPL" <<'EOF'
id: custom
name: Custom Pipeline
extends: null
defaults:
  strategy: sequential

stages:
  - id: intake
    gate: auto
    roles: [intake]
    strategy: fanout
  - id: review
    gate: manual
    roles: [reviewer,auditor]
EOF

# A template with multi-line roles list (yaml_get_list style)
MULTILINE_TPL="$TEST_TEMP_DIR/multiline.yaml"
cat > "$MULTILINE_TPL" <<'EOF'
id: multiline
name: Multiline Pipeline
defaults:
  strategy: fanout

stages:
  - id: build
    gate: auto
    roles: [builder]
EOF

# A template with an unknown (non-canonical) stage id
UNKNOWN_STAGE_TPL="$TEST_TEMP_DIR/unknown-stage.yaml"
cat > "$UNKNOWN_STAGE_TPL" <<'EOF'
id: bad
name: Bad Pipeline
defaults:
  strategy: fanout

stages:
  - id: intake
    gate: auto
    roles: [intake]
  - id: frobulate
    gate: auto
    roles: [frobulator]
EOF

# A template with stages in wrong (non-canonical) order
WRONG_ORDER_TPL="$TEST_TEMP_DIR/wrong-order.yaml"
cat > "$WRONG_ORDER_TPL" <<'EOF'
id: wrong-order
name: Wrong Order Pipeline
defaults:
  strategy: fanout

stages:
  - id: review
    gate: auto
    roles: [reviewer]
  - id: intake
    gate: auto
    roles: [intake]
EOF

# A template with an empty stages list (valid — subtractive composition)
EMPTY_STAGES_TPL="$TEST_TEMP_DIR/empty-stages.yaml"
cat > "$EMPTY_STAGES_TPL" <<'EOF'
id: empty
name: Empty Stages Pipeline
defaults:
  strategy: fanout

stages: []
EOF

# A template with a valid canonical subset (not all 11 stages)
VALID_SUBSET_TPL="$TEST_TEMP_DIR/valid-subset.yaml"
cat > "$VALID_SUBSET_TPL" <<'EOF'
id: subset
name: Subset Pipeline
defaults:
  strategy: fanout

stages:
  - id: plan
    gate: auto
    roles: [planner]
  - id: build
    gate: auto
    roles: [builder]
  - id: test
    gate: auto
    roles: [tester]
EOF

# ─── Source template module ───────────────────────────────────────────────────
# Source in the current shell so state vars are accessible
# shellcheck disable=SC1090
source "$TEMPLATE_SH"

# ─── Test 1: load_template with missing file returns non-zero ─────────────────
set +e
load_template "$TEST_TEMP_DIR/does-not-exist.yaml" 2>/dev/null
rc=$?
set -e
assert_eq "load_template missing file returns non-zero" "1" "$rc"

# ─── Test 2: load_template populates _TPL_STAGES correctly (standard) ────────
load_template "$STANDARD_TPL"
stage_count="${#_TPL_STAGES[@]}"
assert_eq "standard template has 4 stages" "4" "$stage_count"

# ─── Test 3: stage order is preserved in _TPL_STAGES ─────────────────────────
assert_eq "_TPL_STAGES[0] is intake" "intake" "${_TPL_STAGES[0]}"
assert_eq "_TPL_STAGES[1] is plan"   "plan"   "${_TPL_STAGES[1]}"
assert_eq "_TPL_STAGES[2] is build"  "build"  "${_TPL_STAGES[2]}"
assert_eq "_TPL_STAGES[3] is review" "review" "${_TPL_STAGES[3]}"

# ─── Test 4: _TPL_DEFAULT_STRATEGY is set correctly ──────────────────────────
assert_eq "_TPL_DEFAULT_STRATEGY=fanout" "fanout" "$_TPL_DEFAULT_STRATEGY"

# ─── Test 5: template_stage_roles returns correct role for intake ─────────────
roles_intake="$(template_stage_roles "intake")"
assert_eq "template_stage_roles intake returns intake" "intake" "$roles_intake"

# ─── Test 6: template_stage_roles returns correct role for plan ───────────────
roles_plan="$(template_stage_roles "plan")"
assert_eq "template_stage_roles plan returns planner" "planner" "$roles_plan"

# ─── Test 6b: template_stage_roles returns correct role for build ─────────────
roles_build="$(template_stage_roles "build")"
assert_eq "template_stage_roles build returns builder" "builder" "$roles_build"

# ─── Test 7: template_stage_roles returns correct role for review ─────────────
roles_review_std="$(template_stage_roles "review")"
assert_eq "template_stage_roles review returns reviewer" "reviewer" "$roles_review_std"

# ─── Test 8: template_stage_strategy returns default when no per-stage override
strat_intake="$(template_stage_strategy "intake")"
assert_eq "template_stage_strategy intake returns default fanout" "fanout" "$strat_intake"

strat_build="$(template_stage_strategy "build")"
assert_eq "template_stage_strategy build returns default fanout" "fanout" "$strat_build"

# ─── Test 9: custom template — load and verify stage count ───────────────────
load_template "$CUSTOM_TPL"
custom_stage_count="${#_TPL_STAGES[@]}"
assert_eq "custom template has 2 stages" "2" "$custom_stage_count"

# ─── Test 10: custom template — default strategy is sequential ───────────────
assert_eq "custom template _TPL_DEFAULT_STRATEGY=sequential" "sequential" "$_TPL_DEFAULT_STRATEGY"

# ─── Test 11: custom template — per-stage strategy override (intake → fanout) ─
strat_custom_intake="$(template_stage_strategy "intake")"
assert_eq "custom template intake strategy=fanout (per-stage override)" "fanout" "$strat_custom_intake"

# ─── Test 12: custom template — stage without override falls back to default ──
strat_review="$(template_stage_strategy "review")"
assert_eq "custom template review strategy=sequential (default fallback)" "sequential" "$strat_review"

# ─── Test 13: custom template — multi-role stage returns all roles ────────────
roles_review="$(template_stage_roles "review")"
roles_line_count="$(printf '%s\n' "$roles_review" | wc -l | tr -d ' ')"
assert_eq "review stage returns 2 roles (reviewer + auditor)" "2" "$roles_line_count"
assert_contains "review roles contains reviewer" "$roles_review" "reviewer"
assert_contains "review roles contains auditor"  "$roles_review" "auditor"

# ─── Test 14: reload standard template — state is fully reset ─────────────────
load_template "$STANDARD_TPL"
reload_count="${#_TPL_STAGES[@]}"
assert_eq "reloaded standard template still has 4 stages" "4" "$reload_count"
assert_eq "reloaded _TPL_DEFAULT_STRATEGY=fanout" "fanout" "$_TPL_DEFAULT_STRATEGY"

# ─── Test 15: unknown stage id → load_template returns non-zero ───────────────
set +e
load_template "$UNKNOWN_STAGE_TPL" 2>/dev/null
rc_unknown=$?
set -e
assert_eq "unknown stage id → load_template returns non-zero" "1" "$rc_unknown"

# ─── Test 16: unknown stage id → error message contains bad id ────────────────
set +e
err_unknown="$(load_template "$UNKNOWN_STAGE_TPL" 2>&1)"
set -e
assert_contains "unknown stage id error references bad id 'frobulate'" "$err_unknown" "frobulate"

# ─── Test 17: valid canonical subset → load_template succeeds ─────────────────
set +e
load_template "$VALID_SUBSET_TPL" 2>/dev/null
rc_subset=$?
set -e
assert_eq "valid canonical subset passes validation" "0" "$rc_subset"

# ─── Test 18: valid canonical subset → _TPL_STAGES has correct count ──────────
assert_eq "valid subset template has 3 stages" "3" "${#_TPL_STAGES[@]}"

# ─── Test 19: stages in wrong order → load_template returns non-zero ──────────
set +e
load_template "$WRONG_ORDER_TPL" 2>/dev/null
rc_order=$?
set -e
assert_eq "wrong stage order → load_template returns non-zero" "1" "$rc_order"

# ─── Test 20: stages in wrong order → error message mentions order ────────────
set +e
err_order="$(load_template "$WRONG_ORDER_TPL" 2>&1)"
set -e
assert_contains "wrong order error mentions 'order'" "$err_order" "order"

# ─── Test 21: empty stages list → load_template succeeds ──────────────────────
set +e
load_template "$EMPTY_STAGES_TPL" 2>/dev/null
rc_empty=$?
set -e
assert_eq "empty stages list passes validation" "0" "$rc_empty"

# ─── Test 22: empty stages list → _TPL_STAGES is empty ───────────────────────
assert_eq "empty stages template has 0 stages" "0" "${#_TPL_STAGES[@]}"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
