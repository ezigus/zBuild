#!/usr/bin/env bash
# tests/unit/core-pipeline-template-router-retries-test.sh — #1230
#
# S8: per-stage `router.retries` knob parses at every site (inline `stages:` AND
# `stage_definitions:` shapes), is exposed via template_stage_router_retries, and
# is validated as an integer in 0..10. Mirrors router.timeout_s / router.max_turns
# / router.max_iterations (ADR-017/ADR-018 → ADR-029 amendment).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"

print_test_header "template: per-stage router.retries knob (#1230 S8)"
setup_test_env "template-router-retries"

# ── S8a: inline `stages:` shape parses retries + accessor returns it ─────────
FIX1="$TEST_TEMP_DIR/inline.yaml"
cat > "$FIX1" <<'EOF'
id: rr-inline
name: RR inline
defaults:
  strategy: fanout
stages:
  - id: impact
    gate: auto
    roles: [impact_analyzer]
    router:
      timeout_s: 180
      max_turns: 45
      retries: 1
  - id: build
    gate: auto
    roles: [builder]
EOF
( load_template "$FIX1" ) # sanity: loads cleanly
load_template "$FIX1"
assert_eq "[S8a] impact router.retries parsed (inline stages)" \
    "1" "$(template_stage_router_retries impact)"
assert_eq "[S8a] build router.retries unset → empty (default handled by resolver)" \
    "" "$(template_stage_router_retries build)"

# ── S6/S8b: cycle-member stage (stage_definitions shape) resolves retries ────
FIX2="$TEST_TEMP_DIR/cycle.yaml"
cat > "$FIX2" <<'EOF'
id: rr-cycle
name: RR cycle
defaults:
  strategy: fanout
stages:
  - id: design_impact_cycle
    type: cycle
    stages: [design, impact]
    until:
      stage: impact
      field: verdict
      op: eq
      value: complete
    max_iterations: 3
stage_definitions:
  design:
    roles: [designer]
    router:
      timeout_s: 300
      max_turns: 25
  impact:
    roles: [impact_analyzer]
    router:
      timeout_s: 180
      max_turns: 45
      retries: 1
EOF
load_template "$FIX2"
assert_eq "[S6] cycle-member impact resolves router.retries via accessor" \
    "1" "$(template_stage_router_retries impact)"

# ── S8c: validation — retries must be integer 0..10 ──────────────────────────
_load_expect_fail() {
    local desc="$1" yaml="$2"
    local f="$TEST_TEMP_DIR/bad.yaml"
    printf '%s\n' "$yaml" > "$f"
    if ( load_template "$f" >/dev/null 2>&1 ); then
        assert_fail "$desc" "load_template accepted an out-of-range router.retries"
    else
        assert_pass "$desc"
    fi
}
_load_expect_fail "[S8c] router.retries=11 rejected (>10)" 'id: bad
name: bad
defaults:
  strategy: fanout
stages:
  - id: impact
    gate: auto
    roles: [impact_analyzer]
    router:
      retries: 11'
_load_expect_fail "[S8c] router.retries=-1 rejected (negative)" 'id: bad
name: bad
defaults:
  strategy: fanout
stages:
  - id: impact
    gate: auto
    roles: [impact_analyzer]
    router:
      retries: -1'
_load_expect_fail "[S8c] router.retries=abc rejected (non-integer)" 'id: bad
name: bad
defaults:
  strategy: fanout
stages:
  - id: impact
    gate: auto
    roles: [impact_analyzer]
    router:
      retries: abc'

# retries: 0 is the explicit opt-out and MUST be accepted.
FIX0="$TEST_TEMP_DIR/zero.yaml"
cat > "$FIX0" <<'EOF'
id: rr-zero
name: RR zero
defaults:
  strategy: fanout
stages:
  - id: impact
    gate: auto
    roles: [impact_analyzer]
    router:
      retries: 0
EOF
if ( load_template "$FIX0" >/dev/null 2>&1 ); then
    assert_pass "[S8c] router.retries=0 accepted (explicit opt-out)"
    load_template "$FIX0"
    assert_eq "[S8c] router.retries=0 round-trips" "0" "$(template_stage_router_retries impact)"
else
    assert_fail "[S8c] router.retries=0 accepted (explicit opt-out)" "load_template rejected retries:0"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
