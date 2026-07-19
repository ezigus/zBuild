#!/usr/bin/env bash
# tests/unit/core-pipeline-template-router-tier-test.sh — #1252
#
# S1: per-stage `router.tier` override, exposed via template_stage_router_tier.
# Unlike the timeout/max_turns/retries knobs, this one is read LAZILY from the
# loaded template source (_TPL_SOURCE_FILE) — the same style as
# template_stage_negctl_timeout — so it needs no parser-array / row-shape change.
# The accessor validates the value as a tier ORDINAL (^T[0-4]$, ADR-003) at read
# time and prints nothing when unset. It feeds resolve_tier BETWEEN the env
# override and the manifest config.tier_default (precedence proven separately in
# tests/unit/tier-resolve-test.sh and tests/integration/template-tier-override-test.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"

print_test_header "template: per-stage router.tier lazy accessor (#1252)"
setup_test_env "template-router-tier"

# ── S1a: new-shape template (top-level per-stage sections) parses router.tier ──
FIX1="$TEST_TEMP_DIR/newshape.yaml"
cat > "$FIX1" <<'EOF'
id: rt-new
name: RT new
defaults:
  strategy: fanout
stages:
  - id: plan
  - id: build
plan:
  gate: auto
  roles: [planner]
  router:
    timeout_s: 300
    tier: T3
build:
  gate: auto
  roles: [builder]
  router:
    timeout_s: 900
EOF
load_template "$FIX1"
assert_eq "[S1a] plan router.tier parsed via lazy accessor" \
    "T3" "$(template_stage_router_tier plan)"
assert_eq "[S1a] build router.tier unset → empty (resolver falls back to manifest)" \
    "" "$(template_stage_router_tier build)"

# ── S1b: inline `stages:` shape (router nested under a list item) ─────────────
FIX2="$TEST_TEMP_DIR/inline.yaml"
cat > "$FIX2" <<'EOF'
id: rt-inline
name: RT inline
defaults:
  strategy: fanout
stages:
  - id: impact
    gate: auto
    roles: [impact_analyzer]
    router:
      timeout_s: 180
      tier: T1
EOF
load_template "$FIX2"
assert_eq "[S1b] impact router.tier parsed (inline stages shape)" \
    "T1" "$(template_stage_router_tier impact)"

# ── S1c: range-reject an out-of-band ordinal (T9) at READ time (fail loud) ────
FIX3="$TEST_TEMP_DIR/bad.yaml"
cat > "$FIX3" <<'EOF'
id: rt-bad
name: RT bad
defaults:
  strategy: fanout
plan:
  gate: auto
  roles: [planner]
  router:
    tier: T9
EOF
load_template "$FIX3"
_rc=0; template_stage_router_tier plan >/dev/null 2>&1 || _rc=$?
assert_exit_code "[S1c] router.tier=T9 (out of T0-T4) → accessor fails loud" 1 "$_rc"

# ── S1d: a model NAME (not an ordinal) is rejected — ADR-003 models-as-data ────
FIX4="$TEST_TEMP_DIR/name.yaml"
cat > "$FIX4" <<'EOF'
id: rt-name
name: RT name
defaults:
  strategy: fanout
plan:
  gate: auto
  roles: [planner]
  router:
    tier: sonnet
EOF
load_template "$FIX4"
_rc=0; template_stage_router_tier plan >/dev/null 2>&1 || _rc=$?
assert_exit_code "[S1d] router.tier=sonnet (a model name) → accessor fails loud" 1 "$_rc"

# ── S1e: empty when the stage has no router.tier at all ───────────────────────
assert_eq "[S1e] stage with no router.tier → empty string" \
    "" "$(template_stage_router_tier build)"

# ── S1f: empty when no template is loaded (no _TPL_SOURCE_FILE) ───────────────
( unset _TPL_SOURCE_FILE
  assert_eq "[S1f] no loaded template → empty, no error" \
      "" "$(template_stage_router_tier plan)" )

# ── SPEC-1/SPEC-2: stage_definitions shape — router.tier lazy accessor ────────
FIX_SD="$TEST_TEMP_DIR/stagedefs-tier.yaml"
cat > "$FIX_SD" <<'EOF'
id: sd-tier
name: SD tier
defaults:
  strategy: fanout
stages:
  - id: build_design_cycle
    type: cycle
    stages: [build, design]
    max_iterations: 3
    on_max: continue
    until:
      stage: design
      field: verdict
      op: eq
      value: approved
stage_definitions:
  build:
    roles: [builder]
    router:
      timeout_s: 300
      max_turns: 10
      retries: 1
  design:
    roles: [designer]
    router:
      timeout_s: 600
      max_turns: 20
      retries: 2
      tier: T2
EOF
load_template "$FIX_SD"
assert_eq "[SPEC-1] stage_definitions: design router.tier resolves to T2" \
    "T2" "$(template_stage_router_tier design)"
assert_eq "[SPEC-2] stage_definitions: build router.tier unset → empty" \
    "" "$(template_stage_router_tier build)"

# ── SPEC-3: negctl_timeout reads from new-shape top-level section (guard) ─────
FIX_NEGCTL_NEW="$TEST_TEMP_DIR/negctl-new.yaml"
cat > "$FIX_NEGCTL_NEW" <<'EOF'
id: negctl-new
name: negctl new shape
defaults:
  strategy: fanout
stages:
  - id: plan
  - id: build
plan:
  gate: auto
  roles: [planner]
  negctl_timeout_s: 180
build:
  gate: auto
  roles: [builder]
EOF
load_template "$FIX_NEGCTL_NEW"
assert_eq "[SPEC-3] new-shape: negctl_timeout_s reads from top-level stage section" \
    "180" "$(template_stage_negctl_timeout plan)"

# ── SPEC-4/SPEC-5/SPEC-6: comprehensive stage_definitions fixture ─────────────
# Verifies negctl_timeout_s lazy accessor + router.tier lazy accessor + row-based
# knobs all resolve from stage_definitions in a single fixture.
FIX_FULL="$TEST_TEMP_DIR/stagedefs-full.yaml"
cat > "$FIX_FULL" <<'EOF'
id: sd-full
name: SD full knobs
defaults:
  strategy: fanout
stages:
  - id: build_review_cycle
    type: cycle
    stages: [build, review]
    max_iterations: 3
    on_max: continue
    until:
      stage: review
      field: verdict
      op: eq
      value: approved
stage_definitions:
  build:
    roles: [builder]
    router:
      timeout_s: 300
      max_turns: 10
      retries: 1
  review:
    roles: [reviewer]
    negctl_timeout_s: 120
    router:
      timeout_s: 600
      max_turns: 20
      retries: 2
      tier: T2
EOF
load_template "$FIX_FULL"
assert_eq "[SPEC-4] stage_definitions: negctl_timeout_s resolves for review stage" \
    "120" "$(template_stage_negctl_timeout review)"
assert_eq "[SPEC-5] stage_definitions: negctl_timeout_s returns empty when absent" \
    "" "$(template_stage_negctl_timeout build)"
# SPEC-6: comprehensive — tier lazy accessor + row-based knobs from same fixture.
# The last three assertions (timeout_s/max_turns/retries) exercise the
# pre-existing _tpl_parse_stage_definitions + cycle-member row-based path in
# load_template, not the new lazy readers — kept here as regression coverage
# proving both paths agree on the same stage_definitions fixture.
assert_eq "[SPEC-6a] stage_definitions: review router.tier via lazy accessor" \
    "T2" "$(template_stage_router_tier review)"
assert_eq "[SPEC-6b] stage_definitions: review router timeout_s via row-based accessor" \
    "600" "${_TPL_STAGE_ROUTER_TIMEOUT_review:-}"
assert_eq "[SPEC-6c] stage_definitions: review router max_turns via row-based accessor" \
    "20" "${_TPL_STAGE_ROUTER_MAX_TURNS_review:-}"
assert_eq "[SPEC-6d] stage_definitions: review router retries via row-based accessor" \
    "2" "${_TPL_STAGE_ROUTER_RETRIES_review:-}"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
