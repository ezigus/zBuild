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

cleanup_test_env
print_test_results
exit $((FAIL > 0))
