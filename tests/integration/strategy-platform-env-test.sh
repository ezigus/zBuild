#!/usr/bin/env bash
# Tests: core/pipeline/strategies/ — ZBUILD_PLATFORM env export (issue #307)
# ADR-009 §"ZBUILD_PLATFORM env contract" promises plugins receive
# ZBUILD_PLATFORM=<single-platform> per per-platform invocation. Verifies the
# work-unit baked by _strategy_make_work_unit exports both ZBUILD_PLATFORM
# (canonical, ADR-009) and ZBUILD_TARGET_PLATFORM (legacy alias, ADR-001).
# DSPLAT-1: sourcing helpers.sh must not overwrite a pre-set ZBUILD_PLATFORM.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"

print_test_header "strategy work-unit ZBUILD_PLATFORM contract (#307, ADR-009)"

setup_test_env "strategy-platform-env"

# ─── Test 1: work unit exports ZBUILD_PLATFORM (#307) ────────────────────────
print_test_section "work unit bakes ZBUILD_PLATFORM per platform (#307)"

# Given
export ZBUILD_ORCH_SCRATCH="$TEST_TEMP_DIR/orch"
mkdir -p "$ZBUILD_ORCH_SCRATCH"

# shellcheck source=../core/pipeline/strategies/common.sh
source "$REPO_ROOT/core/pipeline/strategies/common.sh"

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

# When: _strategy_make_work_unit is called with platform ios
WU="$(_strategy_make_work_unit "$PLUGIN_DIR" "intake" "$STATE_FILE" "ios")"

# Then: work unit exports ZBUILD_PLATFORM='ios' and ZBUILD_TARGET_PLATFORM='ios'
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

# Cleanup
rm -f "$WU"

# ─── Test 2: per-platform values differ in the baked work unit ──────────────
print_test_section "per-platform work units carry distinct ZBUILD_PLATFORM values"

# Given: same plugin and state as above

# When: _strategy_make_work_unit is called with platform node
WU_NODE="$(_strategy_make_work_unit "$PLUGIN_DIR" "intake" "$STATE_FILE" "node")"

# Then: second work unit bakes platform='node'
if grep -q "^export ZBUILD_PLATFORM='node'$" "$WU_NODE"; then
    assert_pass "second work unit bakes platform='node' (no cross-contamination)"
else
    assert_fail "second work unit bakes platform='node'" "missing from $WU_NODE"
fi

# Cleanup
rm -f "$WU_NODE"

# ─── [DSPLAT-1]: helpers.sh must not overwrite a pre-set ZBUILD_PLATFORM ──────
print_test_section "[DSPLAT-1] helpers.sh preserves a pre-set ZBUILD_PLATFORM"

# Given: a process has ZBUILD_PLATFORM=ios in its environment
# _ZBUILD_COMPAT_LOADED and _ZBUILD_HELPERS_LOADED are unset so compat.sh runs
# from scratch in the subprocess (the outer script sourced helpers.sh already;
# after the fix those guards may be exported — env -u keeps the test honest).

# When: scripts/lib/helpers.sh is sourced in that subprocess
_dsplat1_result="$(
    env -u _ZBUILD_COMPAT_LOADED -u _ZBUILD_HELPERS_LOADED \
        ZBUILD_PLATFORM=ios bash -c "
        set -e
        source '$REPO_ROOT/scripts/lib/helpers.sh'
        printf '%s\n' \"\$ZBUILD_PLATFORM\"
    "
)"

# Then: ZBUILD_PLATFORM is still ios
assert_eq "[DSPLAT-1] ZBUILD_PLATFORM=ios survives sourcing helpers.sh" \
    "ios" "$_dsplat1_result"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
