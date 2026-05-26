#!/usr/bin/env bash
# Tests: core/pipeline/strategies/ — ZBUILD_PLATFORM env export (issue #307)
# ADR-009 §"ZBUILD_PLATFORM env contract" promises plugins receive
# ZBUILD_PLATFORM=<single-platform> per per-platform invocation. Verifies the
# work-unit baked by _strategy_make_work_unit exports both ZBUILD_PLATFORM
# (canonical, ADR-009) and ZBUILD_TARGET_PLATFORM (legacy alias, ADR-001).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "strategy work-unit ZBUILD_PLATFORM contract (#307, ADR-009)"

setup_test_env "strategy-platform-env"

# Set up env that common.sh expects.
export ZBUILD_ORCH_SCRATCH="$TEST_TEMP_DIR/orch"
mkdir -p "$ZBUILD_ORCH_SCRATCH"

# shellcheck source=../core/pipeline/strategies/common.sh
source "$REPO_ROOT/core/pipeline/strategies/common.sh"

# Build a minimal plugin fixture so the work-unit path validates.
PLUGIN_DIR="$TEST_TEMP_DIR/plugins/agent/echo-platform"
mkdir -p "$PLUGIN_DIR"
cat > "$PLUGIN_DIR/manifest.yaml" <<'EOF'
id: echo-platform
name: Echo Platform
kind: agent
version: 0.0.1
hooks:
  run: echo_platform_run
requires:
  core:
    - redaction
EOF
cat > "$PLUGIN_DIR/plugin.sh" <<EOF
echo_platform_run() {
    printf '%s\n' "ZBUILD_PLATFORM=\${ZBUILD_PLATFORM:-<unset>}" > "$TEST_TEMP_DIR/captured-env"
    printf '%s\n' "ZBUILD_TARGET_PLATFORM=\${ZBUILD_TARGET_PLATFORM:-<unset>}" >> "$TEST_TEMP_DIR/captured-env"
    return 0
}
EOF

STATE_DIR="$TEST_TEMP_DIR/state"
mkdir -p "$STATE_DIR"
STATE_FILE="$STATE_DIR/pipeline-state.json"
echo '{}' > "$STATE_FILE"

# ─── Test 1: work unit exports ZBUILD_PLATFORM (#307) ────────────────────────
WU="$(_strategy_make_work_unit "$PLUGIN_DIR" "intake" "$STATE_FILE" "ios")"
assert_file_exists "work unit created" "$WU"

if grep -q "^export ZBUILD_PLATFORM='ios'$" "$WU"; then
    assert_pass "work unit exports ZBUILD_PLATFORM='ios' (ADR-009 §6)"
else
    assert_fail "work unit exports ZBUILD_PLATFORM='ios' (ADR-009 §6)" "missing from $WU"
fi

if grep -q "^export ZBUILD_TARGET_PLATFORM='ios'$" "$WU"; then
    assert_pass "work unit exports ZBUILD_TARGET_PLATFORM='ios' (ADR-001 legacy alias)"
else
    assert_fail "work unit exports ZBUILD_TARGET_PLATFORM='ios'" "missing from $WU"
fi

# ─── Test 2: per-platform values differ in the baked work unit ──────────────
WU_NODE="$(_strategy_make_work_unit "$PLUGIN_DIR" "intake" "$STATE_FILE" "node")"
if grep -q "^export ZBUILD_PLATFORM='node'$" "$WU_NODE"; then
    assert_pass "second work unit bakes platform='node' (no cross-contamination)"
else
    assert_fail "second work unit bakes platform='node'" "missing from $WU_NODE"
fi

# Cleanup the work units we made
rm -f "$WU" "$WU_NODE"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
