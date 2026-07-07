#!/usr/bin/env bash
# Tests: core/pipeline/template-resolver.sh — per-repo search path and extends validation
# ADR-016 (full-replace overlay), issue #653
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESOLVER_SH="$REPO_ROOT/core/pipeline/template-resolver.sh"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/pipeline/template-resolver — search path and extends validation (ADR-016)"
setup_test_env "template-resolver-search-path"

# Source under test (after setup_test_env so TEST_TEMP_DIR is set)
source "$RESOLVER_SH"
# Override resolver root to point at our fake shipped templates
_TEMPLATE_RESOLVER_ROOT="$TEST_TEMP_DIR/repo"

# ─── Fixtures ────────────────────────────────────────────────────────────────

mkdir -p "$TEST_TEMP_DIR/repo/config/templates"
mkdir -p "$TEST_TEMP_DIR/repo/.zbuild/templates"

# Minimal shipped base template (old-shape: stages: + stage_definitions:)
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

# ─── Test (a): no .zbuild/templates/ directory → returns shipped path unchanged ──

rmdir "$TEST_TEMP_DIR/repo/.zbuild/templates" 2>/dev/null || true
rmdir "$TEST_TEMP_DIR/repo/.zbuild" 2>/dev/null || true

set +e
result="$(resolve_template_file "standard" "$TEST_TEMP_DIR/repo" 2>/dev/null)"
rc=$?
set -e

assert_eq "no per-repo dir: exit 0" "0" "$rc"
assert_eq "no per-repo dir: returns shipped path" \
    "$TEST_TEMP_DIR/repo/config/templates/standard.yaml" "$result"

# Restore .zbuild/templates dir for subsequent tests
mkdir -p "$TEST_TEMP_DIR/repo/.zbuild/templates"

# ─── Test (b): per-repo file with valid extends: → temp-merged path with both content ──

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

set +e
result="$(resolve_template_file "standard" "$TEST_TEMP_DIR/repo" 2>/dev/null)"
rc=$?
set -e

assert_eq "valid extends: exit 0" "0" "$rc"

# Merged file must exist and contain both base top-level keys and overlay stages
assert_pass "merged file exists" "[[ -f '$result' ]]"
assert_contains "merged file has base 'defaults:'" "$(cat "$result")" "defaults:"
assert_contains "merged file has overlay 'stages:'" "$(cat "$result")" "stages:"
assert_contains "merged file has overlay stage 'build'" "$(cat "$result")" "build"
assert_contains "merged file has overlay stage 'test'" "$(cat "$result")" "test"
# Base stages should NOT appear (full-replace)
set +e; grep -q "plan" "$result"; base_present=$?; set -e
assert_eq "merged file does not contain base-only stage 'plan'" "1" "$base_present"

# ─── Test (c): per-repo file missing extends: key → rc≠0, message contains 'extends' ──

cat > "$TEST_TEMP_DIR/repo/.zbuild/templates/standard.yaml" <<'EOF'
stages:
  - id: build
    roles: [builder]
EOF

set +e
err_out="$(resolve_template_file "standard" "$TEST_TEMP_DIR/repo" 2>&1)"
rc=$?
set -e

assert_pass "missing extends: is non-zero" "[[ $rc -ne 0 ]]"
assert_contains "missing extends: error mentions 'extends'" "$err_out" "extends"

# ─── Test (d): per-repo file extends: pointing to non-existent shipped template → rc≠0 ──

cat > "$TEST_TEMP_DIR/repo/.zbuild/templates/standard.yaml" <<'EOF'
extends: nonexistent-base

stages:
  - id: build
    roles: [builder]
EOF

set +e
err_out="$(resolve_template_file "standard" "$TEST_TEMP_DIR/repo" 2>&1)"
rc=$?
set -e

assert_pass "bad extends id: is non-zero" "[[ $rc -ne 0 ]]"
assert_contains "bad extends id: error mentions bad id" "$err_out" "nonexistent-base"

print_test_results
