#!/usr/bin/env bash
# Integration: the contract-lib snapshot TRACKS the run's tree (#1783, was #963).
#
# HISTORY — this file previously asserted the opposite. #963 shipped a once-guard
# and pinned it as "a mid-run working-tree edit does NOT change what the readers
# see", citing ADR-023 immutability. That conflated two different things:
#
#   * ADR-023 says the ENGINE must be stable and must not be the tree under test.
#     That still holds — the installed engine tree is never written to, and the
#     snapshot lives in the run's state dir.
#   * The once-guard additionally froze the snapshot against the RUN'S OWN
#     changes, which is the entire scenario the seam exists for. A run whose
#     change edits a contract-reader lib was still graded by the pre-change copy,
#     so its verdict could not move no matter what the builder wrote.
#
# The correct property is the inverse: the snapshot follows the tree as build
# changes it, so a gate reads the code under test. Exercises the real runner
# helper at the subprocess boundary.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "contract-lib snapshot tracks the run's tree (#1783)"
setup_test_env "self-host-snapshot-tracks-tree"
export NO_COLOR=1

# Source the runner for function access (it self-guards main() under `[[ src == $0 ]]`).
# shellcheck source=../../core/pipeline/runner.sh
source "$REPO_ROOT/core/pipeline/runner.sh"

# Fake target working-tree lib dir with original markers.
WT_LIB="$TEST_TEMP_DIR/wt/scripts/lib"
mkdir -p "$WT_LIB"
for f in acceptance-block.sh acceptance-coverage.sh acceptance-negctl.sh \
         acceptance-reachability.sh merge-base.sh; do
    printf '# ORIGINAL %s\n' "$f" > "$WT_LIB/$f"
done

SNAP="$TEST_TEMP_DIR/state/contract-lib-snapshot"

# ── 1. The snapshot captures the tree it is pointed at ────────────────────────
print_test_section "1. snapshot captures the run's tree"
_runner_snapshot_contract_libs "$WT_LIB" "$SNAP"
assert_eq "[SPEC-4] snapshot captures acceptance-block.sh" \
    "# ORIGINAL acceptance-block.sh" "$(cat "$SNAP/acceptance-block.sh" 2>/dev/null)"
assert_eq "[SPEC-4] snapshot captures the merge-base.sh dependency" \
    "# ORIGINAL merge-base.sh" "$(cat "$SNAP/merge-base.sh" 2>/dev/null)"

# ── 2. A later edit to the tree IS picked up ──────────────────────────────────
# This is the behaviour the seam exists to provide: build commits a change to a
# contract-reader lib, and the gate that runs afterwards must read that change.
print_test_section "2. a change to the tree reaches the readers"
printf '# MUTATED mid-run grammar change\n' > "$WT_LIB/acceptance-block.sh"
_runner_snapshot_contract_libs "$WT_LIB" "$SNAP"
assert_eq "[SPEC-4] a refreshed snapshot reflects the tree, not the first copy" \
    "# MUTATED mid-run grammar change" "$(cat "$SNAP/acceptance-block.sh" 2>/dev/null)"

# Unrelated libs are still present after a refresh — the refresh is a re-copy of
# the whole set, not a partial update that could leave a torn root behind.
assert_eq "[SPEC-4] unrelated libs survive the refresh" \
    "# ORIGINAL merge-base.sh" "$(cat "$SNAP/merge-base.sh" 2>/dev/null)"

# ── 3. ADR-023 still holds: the source tree is never written to ───────────────
print_test_section "3. the engine tree stays immutable"
assert_eq "[SPEC-4] snapshotting does not write back into the source tree" \
    "# MUTATED mid-run grammar change" "$(cat "$WT_LIB/acceptance-block.sh" 2>/dev/null)"
assert_file_not_exists "[SPEC-4] no snapshot artifacts leak into the source tree" \
    "$WT_LIB/contract-lib-snapshot"

cleanup_test_env
print_test_results
