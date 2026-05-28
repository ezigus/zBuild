#!/usr/bin/env bash
# Tests: core/pipeline/dispatch.sh — stage→plugin resolver (issue #365)
#
# dispatch.sh is safety-critical: it routes pipeline stages to plugin
# directories. A misroute = wrong plugin executes = downstream pipeline
# behaves unpredictably. The function under test is _find_plugin_for_stage;
# its invariants are documented inline below.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/pipeline/dispatch — stage→plugin resolver (#365)"
setup_test_env "pipeline-dispatch"

# Use shared factory from test-helpers.sh (Wave 4)
_make_plugin() { mock_plugin_factory "$@"; }

# ─── Shared env — point dispatch at the test temp dir ───────────────────────
export ZBUILD_PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$TEST_TEMP_DIR/events"

# Source the module under test. dispatch.sh self-sources registry.sh if
# yaml_get / discover_plugins aren't defined, so we test that path too by
# sourcing dispatch.sh WITHOUT pre-sourcing registry.sh.
# shellcheck source=../../core/pipeline/dispatch.sh
source "$REPO_ROOT/core/pipeline/dispatch.sh"

# ─── Test 1: function defined + self-sourcing of registry worked ─────────────
print_test_section "Section 1: load + self-source registry"

if declare -F _find_plugin_for_stage >/dev/null 2>&1; then
    assert_pass "_find_plugin_for_stage is defined after sourcing dispatch.sh"
else
    assert_fail "_find_plugin_for_stage is defined after sourcing dispatch.sh"
fi

if declare -F yaml_get >/dev/null 2>&1; then
    assert_pass "dispatch.sh self-sources yaml_get from registry.sh"
else
    assert_fail "dispatch.sh self-sources yaml_get from registry.sh"
fi

if declare -F discover_plugins >/dev/null 2>&1; then
    assert_pass "dispatch.sh self-sources discover_plugins from registry.sh"
else
    assert_fail "dispatch.sh self-sources discover_plugins from registry.sh"
fi

# ─── Test 2: happy path — stage maps to plugin directory ─────────────────────
print_test_section "Section 2: happy-path stage→plugin resolution"

_make_plugin "intake"   >/dev/null
_make_plugin "build"    >/dev/null
_make_plugin "test"     "tool" >/dev/null

set +e
result="$(_find_plugin_for_stage "intake")"
rc=$?
set -e
assert_eq "rc=0 when stage matches a plugin id" "0" "$rc"
assert_contains "returned dir contains plugin id 'intake'" "$result" "intake"

set +e
result="$(_find_plugin_for_stage "build")"
rc=$?
set -e
assert_eq "rc=0 for second plugin lookup" "0" "$rc"
assert_contains "returned dir contains plugin id 'build'" "$result" "build"

set +e
result="$(_find_plugin_for_stage "test")"
rc=$?
set -e
assert_eq "rc=0 for plugin under different kind dir (tool)" "0" "$rc"
assert_contains "returned dir is under tool/ for tool-kind plugin" "$result" "tool/test"

# ─── Test 3: not-found returns exit 1 with no stdout ─────────────────────────
print_test_section "Section 3: not-found returns rc=1"

set +e
result="$(_find_plugin_for_stage "nonexistent-stage" 2>/dev/null)"
rc=$?
set -e
assert_eq "rc=1 when no plugin matches stage" "1" "$rc"
assert_eq "no stdout when no plugin matches" "" "$result"

# ─── Test 4: explicit plugins_root arg overrides ZBUILD_PLUGINS_ROOT ─────────
print_test_section "Section 4: explicit plugins_root arg wins over env"

alt_root="$TEST_TEMP_DIR/alt-plugins"
mkdir -p "$alt_root/agent/special"
cat > "$alt_root/agent/special/manifest.yaml" <<EOF
id: special
name: Special
kind: agent
version: 0.0.1
hooks:
  run: special_run
requires:
  core:
    - redaction
EOF
cat > "$alt_root/agent/special/plugin.sh" <<'EOF'
special_run() { return 0; }
EOF

# 'special' does NOT exist under ZBUILD_PLUGINS_ROOT, only under alt_root.
set +e
result="$(_find_plugin_for_stage "special" "$alt_root")"
rc=$?
set -e
assert_eq "rc=0 when stage matches plugin in explicit plugins_root" "0" "$rc"
assert_contains "explicit plugins_root arg overrides env" "$result" "$alt_root"

# And conversely, looking up 'special' WITHOUT the arg should miss
# (it's not in ZBUILD_PLUGINS_ROOT).
set +e
result="$(_find_plugin_for_stage "special" 2>/dev/null)"
rc=$?
set -e
assert_eq "rc=1 when plugin only exists outside env plugins_root" "1" "$rc"

# ─── Test 5: empty plugins_root directory → rc=1 ─────────────────────────────
print_test_section "Section 5: empty / missing plugins_root"

empty_root="$TEST_TEMP_DIR/empty-plugins"
mkdir -p "$empty_root"

set +e
result="$(_find_plugin_for_stage "intake" "$empty_root" 2>/dev/null)"
rc=$?
set -e
assert_eq "rc=1 for empty plugins_root directory" "1" "$rc"

missing_root="$TEST_TEMP_DIR/does-not-exist"
set +e
result="$(_find_plugin_for_stage "intake" "$missing_root" 2>/dev/null)"
rc=$?
set -e
assert_eq "rc=1 for nonexistent plugins_root directory" "1" "$rc"

# ─── Test 6: invalid manifest is skipped (delegated to discover_plugins) ─────
print_test_section "Section 6: invalid manifest is skipped"

# Create a plugin with an INVALID manifest (missing required 'kind' field) and
# share the same id as the stage we'll query for. discover_plugins should drop
# it so _find_plugin_for_stage returns rc=1 even though id matches textually.
broken_dir="$TEST_TEMP_DIR/broken-plugins/agent/broken"
mkdir -p "$broken_dir"
cat > "$broken_dir/manifest.yaml" <<EOF
id: broken
name: Broken
# Note: missing required 'kind' field → validate_manifest fails
version: 0.0.1
hooks:
  run: broken_run
requires:
  core:
    - redaction
EOF
cat > "$broken_dir/plugin.sh" <<'EOF'
broken_run() { return 0; }
EOF

set +e
result="$(_find_plugin_for_stage "broken" "$TEST_TEMP_DIR/broken-plugins" 2>/dev/null)"
rc=$?
set -e
assert_eq "rc=1 when only candidate has invalid manifest (skipped by discover)" "1" "$rc"

# ─── Test 7: id match is exact (no substring/prefix collisions) ──────────────
print_test_section "Section 7: id matching is exact"

# Plugin id 'intake' already exists. Querying 'intak' or 'intakex' must miss.
set +e
result="$(_find_plugin_for_stage "intak" 2>/dev/null)"
rc=$?
set -e
assert_eq "rc=1 for prefix-only id 'intak' (not exact)" "1" "$rc"

set +e
result="$(_find_plugin_for_stage "intakex" 2>/dev/null)"
rc=$?
set -e
assert_eq "rc=1 for superstring id 'intakex' (not exact)" "1" "$rc"

# ─── Teardown ────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
