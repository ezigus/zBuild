#!/usr/bin/env bash
# Integration: pipeline test stage fresh-shell — _TPL_* env leak regression
# (Wave 15-I / #683).
#
# Reproduces — without needing a full pipeline dogfood — the failure mode
# Wave 15-I diagnosed: core/pipeline/template.sh::load_template EXPORTS
# _TPL_STAGE_*_<safe_id> env vars (router timeouts, io destinations, ...).
# Pre-Wave 15-I those env vars survived `npm test` fork boundary and
# contaminated integration tests, because _zbuild_make_fresh_shell only
# scrubbed ZBUILD_*. Two tests caught the leak:
#
#   1. tests/integration/test-plugin-fresh-shell-test.sh — leaked
#      _TPL_STAGE_IO_DESTS_test=file,stdout caused stage_io_begin to emit
#      a banner to the test's mock fd 3 sentinel.
#   2. tests/integration/core-router-route-test.sh Tr-5 — leaked
#      _TPL_STAGE_ROUTER_TIMEOUT_plan=300 caused _route_resolve_timeout to
#      return 300 instead of expected 450 (env value).
#
# This test exports both leaked vars to mimic the parent-runner env, then
# runs each affected test through the _zbuild_make_fresh_shell boundary
# (which is what the test plugin does before eval'ing npm test) and
# asserts both tests still pass. The Wave 15-I fix adds _TPL_* to the
# scrub regex; without that fix, this test fails.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "integration: pipeline test stage _TPL_* leak (Wave 15-I / #683)"

setup_test_env "pipeline-test-stage-fresh-shell"

# ── Helper: invoke a downstream test through _zbuild_make_fresh_shell ──────
# Mimics the test plugin's _test_run_inner inner subshell:
#   - parent exports leaked _TPL_* vars (runner's template state)
#   - subshell sources env-scrub.sh and calls _zbuild_make_fresh_shell
#   - subshell then execs the downstream test (post-scrub env)
# Returns the downstream test's exit rc plus its captured tail output.
_run_under_fresh_shell() {
    local test_path="$1"
    local out_file="$2"
    (
        # Leaked runner state — both vars discovered during Wave 15-I dogfood.
        export _TPL_STAGE_IO_DESTS_test="file,stdout"
        export _TPL_STAGE_ROUTER_TIMEOUT_plan=300
        # Some additional plausible leaks to harden the regression net.
        export _TPL_STAGE_ROLES_build="builder"
        export _TPL_STAGE_STRATEGY_test="fanout"
        # shellcheck source=../../scripts/lib/env-scrub.sh
        source "$REPO_ROOT/scripts/lib/env-scrub.sh"
        _zbuild_make_fresh_shell
        # After scrub, _TPL_* must be gone for the downstream test to pass.
        bash "$test_path"
    ) >"$out_file" 2>&1
}

print_test_section "1. test-plugin-fresh-shell-test passes under leaked _TPL_*"

T1_OUT="$TEST_TEMP_DIR/t1.out"
T1_RC=0
_run_under_fresh_shell "$REPO_ROOT/tests/integration/test-plugin-fresh-shell-test.sh" "$T1_OUT" || T1_RC=$?
if [[ "$T1_RC" -eq 0 ]]; then
    assert_pass "test-plugin-fresh-shell-test exits 0 under leaked _TPL_*"
else
    echo "── test-plugin-fresh-shell-test tail ──"
    tail -30 "$T1_OUT"
    echo "── end tail ──"
    assert_fail "test-plugin-fresh-shell-test exited rc=$T1_RC (expected 0)"
fi

print_test_section "2. core-router-route-test (Tr-5) passes under leaked _TPL_*"

T2_OUT="$TEST_TEMP_DIR/t2.out"
T2_RC=0
_run_under_fresh_shell "$REPO_ROOT/tests/integration/core-router-route-test.sh" "$T2_OUT" || T2_RC=$?
if [[ "$T2_RC" -eq 0 ]]; then
    assert_pass "core-router-route-test exits 0 under leaked _TPL_*"
else
    echo "── core-router-route-test tail (Tr-5 region) ──"
    grep -E "Tr-[0-9]|tests failed|tests passed" "$T2_OUT" | tail -20
    echo "── end tail ──"
    assert_fail "core-router-route-test exited rc=$T2_RC (expected 0)"
fi

print_test_section "3. _zbuild_make_fresh_shell scrubs _TPL_* (post-condition)"

scrub_out="$(
    export _TPL_STAGE_IO_DESTS_test="file,stdout"
    export _TPL_STAGE_ROUTER_TIMEOUT_plan=300
    # shellcheck source=../../scripts/lib/env-scrub.sh
    source "$REPO_ROOT/scripts/lib/env-scrub.sh"
    _zbuild_make_fresh_shell 2>/dev/null
    env | grep -E '^_TPL_' || echo "CLEAN"
)"
assert_eq "no _TPL_* env vars remain after scrub" "CLEAN" "$scrub_out"

print_test_results
exit $((FAIL > 0))
