#!/usr/bin/env bash
# Tests (#898): the orchestrator scratch dir and pool dirs are namespaced per
# run_id so concurrent runs never share them — the orchestrator analog of
# #887/#889 (which isolated ~/.zbuild/state to runs/<run_id>/). Explicit
# overrides (ZBUILD_ORCH_SCRATCH / ZBUILD_POOL_ROOT) still win.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "orch scratch + pool dirs per-run isolation (#898)"
setup_test_env "orch-run-id-isolation-898"

# shellcheck disable=SC1091
source "$REPO_ROOT/core/orch/contract.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/core/pipeline/strategies/common.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/plugins/tool/orch-bash-parallel/plugin.sh"

# ─── Scratch dir ─────────────────────────────────────────────────────────────
# #1240: scrub ambient ZBUILD_STATE_ROOT so the default-path assertions below
# ("/.zbuild/state/runs/...") resolve against $HOME/.zbuild/state. Nested inside
# the pipeline test stage the #1127 sandbox exports ZBUILD_STATE_ROOT=<tmp>/
# .zbuild-nested-state, which _strategy_orch_scratch_dir honors — diverting the
# scratch path away from the asserted default and breaking S1/S2.
unset ZBUILD_STATE_ROOT
unset ZBUILD_ORCH_SCRATCH
export ZBUILD_RUN_ID="run-AAA"
s_a="$(_strategy_orch_scratch_dir)"
assert_contains "S1 default scratch is per-run (runs/run-AAA/orch)" \
    "$s_a" "/.zbuild/state/runs/run-AAA/orch"

export ZBUILD_RUN_ID="run-BBB"
s_b="$(_strategy_orch_scratch_dir)"
assert_contains "S2 different run_id → distinct scratch" \
    "$s_b" "/.zbuild/state/runs/run-BBB/orch"
if [[ "$s_a" != "$s_b" ]]; then
    assert_pass "S2 scratch dirs differ per run"
else
    assert_fail "S2 scratch dirs differ per run" "both=$s_a"
fi

export ZBUILD_ORCH_SCRATCH="/tmp/explicit-scratch-898"
assert_eq "S3 explicit ZBUILD_ORCH_SCRATCH overrides" \
    "/tmp/explicit-scratch-898" "$(_strategy_orch_scratch_dir)"
unset ZBUILD_ORCH_SCRATCH

# ─── Pool dirs ───────────────────────────────────────────────────────────────
unset ZBUILD_POOL_ROOT
export ZBUILD_RUN_ID="run-AAA"
p_a="$(_orch_par_pool_dir poolX)"
assert_contains "P1 default pool dir is per-run (zbuild-runs/run-AAA)" \
    "$p_a" "zbuild-runs/run-AAA/zbuild-pool-poolX"

export ZBUILD_RUN_ID="run-BBB"
p_b="$(_orch_par_pool_dir poolX)"
if [[ "$p_a" != "$p_b" ]]; then
    assert_pass "P2 same pool_id, different run → distinct pool dir"
else
    assert_fail "P2 same pool_id, different run → distinct pool dir" "both=$p_a"
fi

export ZBUILD_POOL_ROOT="/tmp/mypools-898"
assert_eq "P3 ZBUILD_POOL_ROOT overrides" \
    "/tmp/mypools-898/zbuild-pool-poolX" "$(_orch_par_pool_dir poolX)"

# ─── Sequential backend uses the same per-run namespacing (#898) ─────────────
unset ZBUILD_POOL_ROOT
# shellcheck disable=SC1091
source "$REPO_ROOT/plugins/tool/orch-sequential/plugin.sh"
export ZBUILD_RUN_ID="run-AAA"
sp_a="$(_orch_seq_pool_dir poolX)"
assert_contains "P4 sequential pool dir is per-run (zbuild-runs/run-AAA)" \
    "$sp_a" "zbuild-runs/run-AAA/zbuild-pool-poolX"
export ZBUILD_POOL_ROOT="/tmp/seqpools-898"
assert_eq "P5 sequential ZBUILD_POOL_ROOT overrides" \
    "/tmp/seqpools-898/zbuild-pool-poolX" "$(_orch_seq_pool_dir poolX)"
unset ZBUILD_POOL_ROOT

cleanup_test_env
print_test_results
exit $((FAIL > 0))
