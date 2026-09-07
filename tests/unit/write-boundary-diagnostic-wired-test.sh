#!/usr/bin/env bash
# The write-boundary violation log must be wired everywhere a run can halt on it.
#
# write_boundary_violation_recorded names the offending path on three channels:
# stderr, the event stream, and ZBUILD_WRITE_BOUNDARY_LOG. The first two are
# routinely unavailable in practice — most test harnesses discard the runner's
# stderr, and a nested run's event stream dies with its throwaway state dir — so
# the append-only sink is the channel that survives.
#
# It was set in exactly ONE place: the integration job of test.yml. Issue #1839's
# pipeline halted on a write-boundary violation in the e2e tier, inside the
# dogfood workflow — neither of which set it. The run recorded that a violation
# happened and could not say which file caused it, and the disposition is
# `broken`: terminal, not retryable, so there is no second chance to observe it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "write-boundary diagnostic is wired wherever a run can halt on it"
setup_test_env "wb-diagnostic-wired"

_TEST_YML="$REPO_ROOT/.github/workflows/test.yml"
_PIPE_YML="$REPO_ROOT/.github/workflows/zbuild-pipeline.yml"

# ─── SPEC-1: the dogfood pipeline names a sink ──────────────────────────────
# This is the workflow that ran #1839. A violation here halts a real run.
_pipe_hits=$(grep -c 'ZBUILD_WRITE_BOUNDARY_LOG' "$_PIPE_YML" 2>/dev/null || true)
assert_gt "[SPEC-1] the dogfood pipeline workflow sets ZBUILD_WRITE_BOUNDARY_LOG" \
    "$_pipe_hits" "0"

# ─── SPEC-2: every suite job that can trip the boundary names a sink ────────
# The e2e tier runs nested pipelines (parity-local-vs-ci, plugin-event-balance),
# so it can trip the fence exactly as the integration tier can.
_e2e_block="$(awk '/^  e2e-mocked:/{f=1} f{print} f&&/^  [a-z]/&&!/^  e2e-mocked:/{if(++n>1)exit}' \
    "$_TEST_YML" 2>/dev/null || true)"
_e2e_hits=$(printf '%s\n' "$_e2e_block" | grep -c 'ZBUILD_WRITE_BOUNDARY_LOG' || true)
assert_gt "[SPEC-2] the e2e job sets ZBUILD_WRITE_BOUNDARY_LOG" "$_e2e_hits" "0"

# ─── SPEC-3: GUARD — the integration job keeps its sink ─────────────────────
# It is the one that already had it; a refactor must not trade one for another.
_int_hits=$(grep -c 'ZBUILD_WRITE_BOUNDARY_LOG' "$_TEST_YML" 2>/dev/null || true)
assert_gt "[SPEC-3] GUARD: test.yml still sets the sink in more than one job" \
    "$_int_hits" "1"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
