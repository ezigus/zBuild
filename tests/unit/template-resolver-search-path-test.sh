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
# #1268: keep the shipped-dir redirect var out of the (a)-(d) baseline cases so
# they exercise the unset (byte-identical) path; the (e)/(f) sub-tests set it
# explicitly via a command prefix.
unset ZBUILD_TEMPLATES_DIR

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
# [SPEC-3] ZBUILD_TEMPLATES_DIR unset ⇒ shipped path is the resolver-root default
# (byte-identical to pre-#1268 behavior).
assert_eq "[SPEC-3] unset ZBUILD_TEMPLATES_DIR: returns resolver-root shipped path" \
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

# ─── Test (e) #1268: ZBUILD_TEMPLATES_DIR redirects the SHIPPED read root ─────
# A test seam so subprocess-invoking tests resolve fixtures from a temp dir
# instead of writing into the tracked config/templates/. Set ⇒ the resolver
# returns $ZBUILD_TEMPLATES_DIR/<id>.yaml for a shipped (no per-repo override)
# id. RED at merge-base (resolver ignored the var → returned the resolver-root
# path).
ALT_DIR="$TEST_TEMP_DIR/alt-templates"; mkdir -p "$ALT_DIR"
cat > "$ALT_DIR/shipped-only.yaml" <<'EOF'
id: shipped-only
stages:
  - id: intake
    roles: [intake]
EOF

set +e
result="$(ZBUILD_TEMPLATES_DIR="$ALT_DIR" resolve_template_file "shipped-only" "$TEST_TEMP_DIR/repo" 2>/dev/null)"
rc=$?
set -e
assert_eq "[SPEC-1] ZBUILD_TEMPLATES_DIR set (shipped): exit 0" "0" "$rc"
assert_eq "[SPEC-1] ZBUILD_TEMPLATES_DIR set: resolver returns \$ZBUILD_TEMPLATES_DIR/<id>.yaml" \
    "$ALT_DIR/shipped-only.yaml" "$result"

# ─── Test (f) #1268: ZBUILD_TEMPLATES_DIR also supplies the extends: base ─────
# A per-repo overlay whose base lives ONLY in $ZBUILD_TEMPLATES_DIR must merge
# cleanly. RED at merge-base (base sought under the hardcoded resolver-root
# config/templates → "base does not exist" → rc≠0).
cat > "$ALT_DIR/base-in-alt.yaml" <<'EOF'
id: base-in-alt
defaults:
  strategy: fanout

stages:
  - id: intake
    roles: [intake]

stage_definitions:
  intake:
    roles: [intake]
EOF
mkdir -p "$TEST_TEMP_DIR/repo/.zbuild/templates"
cat > "$TEST_TEMP_DIR/repo/.zbuild/templates/ext-alt.yaml" <<'EOF'
extends: base-in-alt

stages:
  - id: build
    roles: [builder]

stage_definitions:
  build:
    roles: [builder]
EOF

set +e
result="$(ZBUILD_TEMPLATES_DIR="$ALT_DIR" resolve_template_file "ext-alt" "$TEST_TEMP_DIR/repo" 2>/dev/null)"
rc=$?
set -e
assert_eq "[SPEC-2] ZBUILD_TEMPLATES_DIR set (extends base): exit 0" "0" "$rc"
assert_contains "[SPEC-2] merged file has base 'defaults:' from ZBUILD_TEMPLATES_DIR" \
    "$(cat "$result" 2>/dev/null)" "defaults:"
assert_contains "[SPEC-2] merged file has overlay stage 'build'" \
    "$(cat "$result" 2>/dev/null)" "build"

print_test_results
