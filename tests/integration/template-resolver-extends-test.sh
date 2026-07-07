#!/usr/bin/env bash
# Tests: core/pipeline/template-resolver.sh + template.sh — extends + load_template wiring
# ADR-016 (full-replace overlay), issue #653
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "template-resolver + load_template — extends wiring (ADR-016)"
setup_test_env "template-resolver-extends"

# #1270: this test pins the resolver's returned paths. Defensively scrub any
# ambient ZBUILD_TEMPLATES_DIR so a leaked value can never redirect the resolver
# read-root and break the path assertions. (The #1268 engine seam that honored
# this var was reverted in #1270; this unset guards against reintroduction.)
unset ZBUILD_TEMPLATES_DIR

# Source both libraries; resolver root points at our fake repo tree.
source "$REPO_ROOT/core/pipeline/template.sh"
source "$REPO_ROOT/core/pipeline/template-resolver.sh"
_TEMPLATE_RESOLVER_ROOT="$TEST_TEMP_DIR/repo"

# ─── Fixtures ────────────────────────────────────────────────────────────────

mkdir -p "$TEST_TEMP_DIR/repo/config/templates"
mkdir -p "$TEST_TEMP_DIR/repo/.zbuild/templates"

# Shipped base template with intake + plan
cat > "$TEST_TEMP_DIR/repo/config/templates/standard.yaml" <<'EOF'
id: standard
name: Standard Pipeline
defaults:
  strategy: fanout

stages:
  - id: intake
    roles: [intake]
  - id: plan
    roles: [planner]

stage_definitions:
  intake:
    roles: [intake]
  plan:
    roles: [planner]
EOF

# Helper: reset _TPL_* state between sub-tests
_reset_tpl() {
    _TPL_STAGES=()
    _TPL_CYCLES=()
    _TPL_DISPATCH_UNITS=()
    _TPL_DEFAULT_STRATEGY="fanout"
}

# ─── Test (a): per-repo standard.yaml with valid extends: and custom stages: ──
# _TPL_STAGES must reflect overlay (build,test), NOT base (intake,plan).

cat > "$TEST_TEMP_DIR/repo/.zbuild/templates/standard.yaml" <<'EOF'
extends: standard

stages:
  - id: build
    roles: [builder]
  - id: test
    roles: [tester]

stage_definitions:
  build:
    roles: [builder]
  test:
    roles: [tester]
EOF

_reset_tpl
set +e
merged="$(resolve_template_file "standard" "$TEST_TEMP_DIR/repo" 2>/dev/null)"
rc=$?; set -e
assert_eq "valid extends: resolver exit 0" "0" "$rc"

set +e; load_template "$merged" >/dev/null 2>&1; lrc=$?; set -e
assert_eq "valid extends: load_template exit 0" "0" "$lrc"

stages_joined="${_TPL_STAGES[*]:-}"
assert_contains "overlay stages present (build)" "$stages_joined" "build"
assert_contains "overlay stages present (test)" "$stages_joined" "test"
set +e; grep -q "intake" <<< "$stages_joined"; base_present=$?; set -e
assert_eq "base-only stage 'intake' absent (full-replace)" "1" "$base_present"
set +e; grep -q "plan" <<< "$stages_joined"; plan_present=$?; set -e
assert_eq "base-only stage 'plan' absent (full-replace)" "1" "$plan_present"

# ─── Test (b): per-repo file missing extends: → load refuses with rc≠0 ─────

cat > "$TEST_TEMP_DIR/repo/.zbuild/templates/standard.yaml" <<'EOF'
stages:
  - id: build
    roles: [builder]
EOF

_reset_tpl
set +e
merged="$(resolve_template_file "standard" "$TEST_TEMP_DIR/repo" 2>&1)"
rc=$?; set -e
assert_pass "missing extends: resolver rc≠0" "[[ $rc -ne 0 ]]"

# ─── Test (c): per-repo file extends: nonexistent → refuses with rc≠0 ───────

cat > "$TEST_TEMP_DIR/repo/.zbuild/templates/standard.yaml" <<'EOF'
extends: does-not-exist

stages:
  - id: build
    roles: [builder]
EOF

_reset_tpl
set +e
out="$(resolve_template_file "standard" "$TEST_TEMP_DIR/repo" 2>&1)"
rc=$?; set -e
assert_pass "bad extends: resolver rc≠0" "[[ $rc -ne 0 ]]"
assert_contains "bad extends: error names missing id" "$out" "does-not-exist"

# ─── Test (d): no .zbuild/templates/ dir → load_template receives shipped path ──
# Regression guard: existing shipped-only load path must be unaffected.

rm -rf "$TEST_TEMP_DIR/repo/.zbuild"

_reset_tpl
set +e
shipped="$(resolve_template_file "standard" "$TEST_TEMP_DIR/repo" 2>/dev/null)"
rc=$?; set -e
assert_eq "no per-repo dir: resolver exit 0" "0" "$rc"
assert_eq "no per-repo dir: returns shipped path" \
    "$TEST_TEMP_DIR/repo/config/templates/standard.yaml" "$shipped"

set +e; load_template "$shipped" >/dev/null 2>&1; lrc=$?; set -e
assert_eq "shipped path: load_template exit 0" "0" "$lrc"

stages_joined="${_TPL_STAGES[*]:-}"
assert_contains "shipped path: base stage 'intake' present" "$stages_joined" "intake"
assert_contains "shipped path: base stage 'plan' present" "$stages_joined" "plan"

print_test_results
