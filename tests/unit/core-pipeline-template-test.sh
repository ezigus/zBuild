#!/usr/bin/env bash
# Tests: core/pipeline/template.sh — template loading and stage resolution
# ADR-009 (platform-aware modularity)
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
assert_eq "standard template has 3 stages" "3" "$stage_count"

# ─── Test 3: stage order is preserved in _TPL_STAGES ─────────────────────────
assert_eq "_TPL_STAGES[0] is intake"        "intake"        "${_TPL_STAGES[0]}"
assert_eq "_TPL_STAGES[1] is security-lens" "security-lens" "${_TPL_STAGES[1]}"
assert_eq "_TPL_STAGES[2] is output"        "output"        "${_TPL_STAGES[2]}"

# ─── Test 4: _TPL_DEFAULT_STRATEGY is set correctly ──────────────────────────
assert_eq "_TPL_DEFAULT_STRATEGY=fanout" "fanout" "$_TPL_DEFAULT_STRATEGY"

# ─── Test 5: template_stage_roles returns correct role for intake ─────────────
roles_intake="$(template_stage_roles "intake")"
assert_eq "template_stage_roles intake returns intake" "intake" "$roles_intake"

# ─── Test 6: template_stage_roles returns correct role for security-lens ──────
roles_sl="$(template_stage_roles "security-lens")"
assert_eq "template_stage_roles security-lens returns security-auditor" "security-auditor" "$roles_sl"

# ─── Test 7: template_stage_roles returns correct role for output ─────────────
roles_output="$(template_stage_roles "output")"
assert_eq "template_stage_roles output returns output" "output" "$roles_output"

# ─── Test 8: template_stage_strategy returns default when no per-stage override
strat_intake="$(template_stage_strategy "intake")"
assert_eq "template_stage_strategy intake returns default fanout" "fanout" "$strat_intake"

strat_output="$(template_stage_strategy "output")"
assert_eq "template_stage_strategy output returns default fanout" "fanout" "$strat_output"

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
assert_eq "reloaded standard template still has 3 stages" "3" "$reload_count"
assert_eq "reloaded _TPL_DEFAULT_STRATEGY=fanout" "fanout" "$_TPL_DEFAULT_STRATEGY"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
