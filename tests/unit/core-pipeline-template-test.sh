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
# #485: standard.yaml now includes a test stage between build and review.
load_template "$STANDARD_TPL"
stage_count="${#_TPL_STAGES[@]}"
assert_eq "standard template has 5 stages" "5" "$stage_count"

# ─── Test 3: stage order is preserved in _TPL_STAGES ─────────────────────────
assert_eq "_TPL_STAGES[0] is intake" "intake" "${_TPL_STAGES[0]}"
assert_eq "_TPL_STAGES[1] is plan"   "plan"   "${_TPL_STAGES[1]}"
assert_eq "_TPL_STAGES[2] is build"  "build"  "${_TPL_STAGES[2]}"
assert_eq "_TPL_STAGES[3] is test"   "test"   "${_TPL_STAGES[3]}"
assert_eq "_TPL_STAGES[4] is review" "review" "${_TPL_STAGES[4]}"

# ─── Test 3b: #485 — test stage roles include tester ──────────────────────────
roles_test="$(template_stage_roles "test")"
assert_eq "template_stage_roles test returns tester" "tester" "$roles_test"

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
assert_eq "reloaded standard template still has 5 stages" "5" "$reload_count"
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

# ─── ADR-015 v1 (#438): io.destinations field ─────────────────────────────────

# Tnew1: inline io.destinations: [file] → template_stage_io_dests returns "file"
IO_INLINE_TPL="$TEST_TEMP_DIR/io-inline.yaml"
cat > "$IO_INLINE_TPL" <<'EOF'
id: io-inline
name: IO Inline
defaults:
  strategy: fanout

stages:
  - id: plan
    gate: auto
    roles: [planner]
    io:
      destinations: [file]
EOF
load_template "$IO_INLINE_TPL"
io_dests_inline="$(template_stage_io_dests "plan")"
assert_eq "Tnew1 inline io.destinations=[file] → file" "file" "$io_dests_inline"

# Tnew2: multi-line io.destinations list → file\nstdout
IO_MULTI_TPL="$TEST_TEMP_DIR/io-multi.yaml"
cat > "$IO_MULTI_TPL" <<'EOF'
id: io-multi
name: IO Multi
defaults:
  strategy: fanout

stages:
  - id: plan
    gate: auto
    roles: [planner]
    io:
      destinations:
        - file
        - stdout
EOF
load_template "$IO_MULTI_TPL"
io_dests_multi="$(template_stage_io_dests "plan")"
io_dests_multi_count="$(printf '%s\n' "$io_dests_multi" | wc -l | tr -d ' ')"
assert_eq "Tnew2 multi-line io.destinations has 2 entries" "2" "$io_dests_multi_count"
assert_contains "Tnew2 multi-line io.destinations contains file" "$io_dests_multi" "file"
assert_contains "Tnew2 multi-line io.destinations contains stdout" "$io_dests_multi" "stdout"

# Tnew3: unknown io.destinations token → load_template rc=1
IO_BAD_TPL="$TEST_TEMP_DIR/io-bad.yaml"
cat > "$IO_BAD_TPL" <<'EOF'
id: io-bad
name: IO Bad
defaults:
  strategy: fanout

stages:
  - id: plan
    gate: auto
    roles: [planner]
    io:
      destinations: [pigeon]
EOF
set +e
err_io_bad="$(load_template "$IO_BAD_TPL" 2>&1)"
rc_io_bad=$?
set -e
assert_eq "Tnew3 unknown io.destinations token → rc=1" "1" "$rc_io_bad"
assert_contains "Tnew3 error mentions bad token 'pigeon'" "$err_io_bad" "pigeon"
assert_contains "Tnew3 error mentions 'unknown'" "$err_io_bad" "unknown"

# Tnew4: stage without io: → template_stage_io_dests returns empty
# Use VALID_SUBSET_TPL (no io: block on any stage) since standard.yaml now ships
# with io.destinations populated (ADR-015 v3, #440).
load_template "$VALID_SUBSET_TPL"
io_dests_none="$(template_stage_io_dests "plan")"
assert_eq "Tnew4 stage without io: returns empty" "" "$io_dests_none"

# Tnew5: regression — io: block doesn't break roles/strategy parsing
IO_MIXED_TPL="$TEST_TEMP_DIR/io-mixed.yaml"
cat > "$IO_MIXED_TPL" <<'EOF'
id: io-mixed
name: IO Mixed
defaults:
  strategy: fanout

stages:
  - id: plan
    gate: auto
    roles: [planner, designer]
    strategy: sequential
    io:
      destinations: [file]
  - id: build
    gate: auto
    roles: [builder]
EOF
load_template "$IO_MIXED_TPL"
assert_eq "Tnew5 regression: 2 stages" "2" "${#_TPL_STAGES[@]}"
roles_mixed_plan="$(template_stage_roles "plan")"
roles_mixed_plan_count="$(printf '%s\n' "$roles_mixed_plan" | wc -l | tr -d ' ')"
assert_eq "Tnew5 regression: plan has 2 roles" "2" "$roles_mixed_plan_count"
assert_contains "Tnew5 regression: plan roles include planner" "$roles_mixed_plan" "planner"
assert_contains "Tnew5 regression: plan roles include designer" "$roles_mixed_plan" "designer"
strat_mixed_plan="$(template_stage_strategy "plan")"
assert_eq "Tnew5 regression: plan strategy=sequential" "sequential" "$strat_mixed_plan"
roles_mixed_build="$(template_stage_roles "build")"
assert_eq "Tnew5 regression: build roles=builder" "builder" "$roles_mixed_build"
io_mixed_plan="$(template_stage_io_dests "plan")"
assert_eq "Tnew5 regression: plan io_dests=file" "file" "$io_mixed_plan"

# ═══════════════════════════════════════════════════════════════════════════
# ADR-015 v3 (#440): io.tail_lines + io.redact per-stage knobs
# ═══════════════════════════════════════════════════════════════════════════

# Tv3-1: inline io.tail_lines parses
IO_TAIL_INLINE_TPL="$TEST_TEMP_DIR/io-tail-inline.yaml"
cat > "$IO_TAIL_INLINE_TPL" <<'EOF'
id: io-tail-inline
name: IO Tail Inline
defaults:
  strategy: fanout

stages:
  - id: plan
    gate: auto
    roles: [planner]
    io:
      destinations: [file]
      tail_lines: 60
EOF
load_template "$IO_TAIL_INLINE_TPL"
assert_eq "Tv3-1 io.tail_lines parsed as 60" "60" "$(template_stage_io_tail_lines plan)"

# Tv3-2: io.tail_lines missing → empty (use subset template w/o io: block)
load_template "$VALID_SUBSET_TPL"
assert_eq "Tv3-2 io.tail_lines missing → empty" "" "$(template_stage_io_tail_lines plan)"

# Tv3-3: non-numeric tail_lines rejected
IO_TAIL_BAD_TPL="$TEST_TEMP_DIR/io-tail-bad.yaml"
cat > "$IO_TAIL_BAD_TPL" <<'EOF'
id: io-tail-bad
name: IO Tail Bad
defaults:
  strategy: fanout

stages:
  - id: plan
    gate: auto
    roles: [planner]
    io:
      destinations: [file]
      tail_lines: forty
EOF
set +e
err_tail_bad="$(load_template "$IO_TAIL_BAD_TPL" 2>&1)"
rc_tail_bad=$?
set -e
assert_eq "Tv3-3 non-numeric tail_lines rejected" "1" "$rc_tail_bad"
assert_contains "Tv3-3 error mentions tail_lines" "$err_tail_bad" "tail_lines"

# Tv3-4: tail_lines > 10000 rejected
IO_TAIL_HUGE_TPL="$TEST_TEMP_DIR/io-tail-huge.yaml"
cat > "$IO_TAIL_HUGE_TPL" <<'EOF'
id: io-tail-huge
name: IO Tail Huge
defaults:
  strategy: fanout

stages:
  - id: plan
    gate: auto
    roles: [planner]
    io:
      destinations: [file]
      tail_lines: 99999
EOF
set +e
err_tail_huge="$(load_template "$IO_TAIL_HUGE_TPL" 2>&1)"
rc_tail_huge=$?
set -e
assert_eq "Tv3-4 tail_lines > 10000 rejected" "1" "$rc_tail_huge"

# Tv3-5: tail_lines=0 rejected (must be ≥ 1)
IO_TAIL_ZERO_TPL="$TEST_TEMP_DIR/io-tail-zero.yaml"
cat > "$IO_TAIL_ZERO_TPL" <<'EOF'
id: io-tail-zero
name: IO Tail Zero
defaults:
  strategy: fanout

stages:
  - id: plan
    gate: auto
    roles: [planner]
    io:
      destinations: [file]
      tail_lines: 0
EOF
set +e
load_template "$IO_TAIL_ZERO_TPL" 2>/dev/null
rc_tail_zero=$?
set -e
assert_eq "Tv3-5 tail_lines=0 rejected" "1" "$rc_tail_zero"

# Tv3-6: redact true/false accepted
IO_REDACT_TF_TPL="$TEST_TEMP_DIR/io-redact-tf.yaml"
cat > "$IO_REDACT_TF_TPL" <<'EOF'
id: io-redact-tf
name: IO Redact TF
defaults:
  strategy: fanout

stages:
  - id: plan
    gate: auto
    roles: [planner]
    io:
      destinations: [file]
      redact: true
  - id: build
    gate: auto
    roles: [builder]
    io:
      destinations: [file]
      redact: false
EOF
load_template "$IO_REDACT_TF_TPL"
assert_eq "Tv3-6a plan redact=true" "true" "$(template_stage_io_redact plan)"
assert_eq "Tv3-6b build redact=false" "false" "$(template_stage_io_redact build)"

# Tv3-7: redact invalid value rejected
IO_REDACT_BAD_TPL="$TEST_TEMP_DIR/io-redact-bad.yaml"
cat > "$IO_REDACT_BAD_TPL" <<'EOF'
id: io-redact-bad
name: IO Redact Bad
defaults:
  strategy: fanout

stages:
  - id: plan
    gate: auto
    roles: [planner]
    io:
      destinations: [file]
      redact: maybe
EOF
set +e
err_redact_bad="$(load_template "$IO_REDACT_BAD_TPL" 2>&1)"
rc_redact_bad=$?
set -e
assert_eq "Tv3-7 redact invalid rejected" "1" "$rc_redact_bad"
assert_contains "Tv3-7 error mentions redact" "$err_redact_bad" "redact"

# Tv3-8: redact missing → empty
load_template "$VALID_SUBSET_TPL"
assert_eq "Tv3-8 redact missing → empty" "" "$(template_stage_io_redact plan)"

# Tv3-9: _TPL_STAGE_IO_* vars are exported (orch spawns plugins in subshells
# that must inherit destinations/tail_lines/redact via the environment;
# without export, capture_stage_io silently short-circuits in the plugin).
load_template "$STANDARD_TPL"
exported_dests="$(bash -c 'printenv _TPL_STAGE_IO_DESTS_plan')"
assert_eq "Tv3-9 _TPL_STAGE_IO_DESTS_plan exported across subshells" "file,stdout" "$exported_dests"
exported_roles="$(bash -c 'printenv _TPL_STAGE_ROLES_plan')"
assert_eq "Tv3-9 _TPL_STAGE_ROLES_plan exported across subshells" "planner" "$exported_roles"

# ─── ADR-017 (#455): per-stage router.timeout_s ──────────────────────────────

# Tv3-10: router.timeout_s on build stage → accessor returns "900"
ROUTER_TIMEOUT_TPL="$TEST_TEMP_DIR/router-timeout.yaml"
cat > "$ROUTER_TIMEOUT_TPL" <<'EOF'
id: router-timeout
name: Router Timeout
defaults:
  strategy: fanout

stages:
  - id: plan
    gate: auto
    roles: [planner]
    io:
      destinations: [file]
    router:
      timeout_s: 300
  - id: build
    gate: auto
    roles: [builder]
    io:
      destinations: [file]
    router:
      timeout_s: 900
EOF
load_template "$ROUTER_TIMEOUT_TPL"
assert_eq "Tv3-10 build router.timeout_s=900" "900" "$(template_stage_router_timeout build)"
assert_eq "Tv3-10 plan router.timeout_s=300" "300" "$(template_stage_router_timeout plan)"

# Tv3-11: no router block → accessor returns empty
load_template "$VALID_SUBSET_TPL"
assert_eq "Tv3-11 router.timeout_s missing → empty" "" "$(template_stage_router_timeout build)"

# Tv3-12: invalid timeout_s "foo" → rc=1, error mentions stage 'build' and got: foo
ROUTER_BAD_TPL="$TEST_TEMP_DIR/router-bad.yaml"
cat > "$ROUTER_BAD_TPL" <<'EOF'
id: router-bad
name: Router Bad
defaults:
  strategy: fanout

stages:
  - id: build
    gate: auto
    roles: [builder]
    router:
      timeout_s: foo
EOF
set +e
err_router_bad="$(load_template "$ROUTER_BAD_TPL" 2>&1)"
rc_router_bad=$?
set -e
assert_eq "Tv3-12 invalid router.timeout_s rejected" "1" "$rc_router_bad"
assert_contains "Tv3-12 error mentions stage 'build'" "$err_router_bad" "router.timeout_s for stage 'build'"
assert_contains "Tv3-12 error mentions got: foo" "$err_router_bad" "got: foo"

# Tv3-13: out-of-range high (3601) → rc=1
ROUTER_HIGH_TPL="$TEST_TEMP_DIR/router-high.yaml"
cat > "$ROUTER_HIGH_TPL" <<'EOF'
id: router-high
name: Router High
defaults:
  strategy: fanout

stages:
  - id: build
    gate: auto
    roles: [builder]
    router:
      timeout_s: 3601
EOF
set +e
load_template "$ROUTER_HIGH_TPL" 2>/dev/null
rc_router_high=$?
set -e
assert_eq "Tv3-13 router.timeout_s=3601 rejected" "1" "$rc_router_high"

# Tv3-14: zero → rc=1
ROUTER_ZERO_TPL="$TEST_TEMP_DIR/router-zero.yaml"
cat > "$ROUTER_ZERO_TPL" <<'EOF'
id: router-zero
name: Router Zero
defaults:
  strategy: fanout

stages:
  - id: build
    gate: auto
    roles: [builder]
    router:
      timeout_s: 0
EOF
set +e
load_template "$ROUTER_ZERO_TPL" 2>/dev/null
rc_router_zero=$?
set -e
assert_eq "Tv3-14 router.timeout_s=0 rejected" "1" "$rc_router_zero"

# Tv3-15: boundary values 1 and 3600 accepted
ROUTER_BOUNDARY_TPL="$TEST_TEMP_DIR/router-boundary.yaml"
cat > "$ROUTER_BOUNDARY_TPL" <<'EOF'
id: router-boundary
name: Router Boundary
defaults:
  strategy: fanout

stages:
  - id: plan
    gate: auto
    roles: [planner]
    router:
      timeout_s: 1
  - id: build
    gate: auto
    roles: [builder]
    router:
      timeout_s: 3600
EOF
set +e
load_template "$ROUTER_BOUNDARY_TPL" 2>/dev/null
rc_router_boundary=$?
set -e
assert_eq "Tv3-15 boundary values accepted" "0" "$rc_router_boundary"
assert_eq "Tv3-15 plan timeout=1" "1" "$(template_stage_router_timeout plan)"
assert_eq "Tv3-15 build timeout=3600" "3600" "$(template_stage_router_timeout build)"

# Tv3-16: _TPL_STAGE_ROUTER_TIMEOUT_* vars are exported across subshells (#448
# regression lock — plugin subshells must inherit this).
load_template "$ROUTER_TIMEOUT_TPL"
exported_rtimeout="$(bash -c 'printenv _TPL_STAGE_ROUTER_TIMEOUT_build')"
assert_eq "Tv3-16 _TPL_STAGE_ROUTER_TIMEOUT_build exported across subshells" "900" "$exported_rtimeout"

# Tv3-17: future router siblings (tier_default, etc.) tolerated silently per ADR-017 §8
ROUTER_FUTURE_TPL="$TEST_TEMP_DIR/router-future.yaml"
cat > "$ROUTER_FUTURE_TPL" <<'EOF'
id: router-future
name: Router Future
defaults:
  strategy: fanout

stages:
  - id: build
    gate: auto
    roles: [builder]
    router:
      timeout_s: 600
      tier_default: T3
EOF
set +e
load_template "$ROUTER_FUTURE_TPL" 2>/dev/null
rc_router_future=$?
set -e
assert_eq "Tv3-17 future router siblings tolerated" "0" "$rc_router_future"
assert_eq "Tv3-17 timeout_s still parsed correctly" "600" "$(template_stage_router_timeout build)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
