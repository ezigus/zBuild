#!/usr/bin/env bash
# Integration: self-host snapshot immutability (#963). The contract-lib snapshot
# is taken ONCE at run entry; a mid-run edit to the working-tree lib does NOT
# change what the readers see (ADR-023 immutability). Exercises the real runner
# helper (_runner_snapshot_contract_libs) at the subprocess boundary.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "self-host snapshot immutability (#963)"
setup_test_env "self-host-snapshot-immutable"
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

# ── 1. Snapshot at run entry captures the working tree verbatim ───────────────
print_test_section "1. run-entry snapshot captures the working-tree grammar"
_runner_snapshot_contract_libs "$WT_LIB" "$SNAP"
assert_eq "[SPEC-4] snapshot captures original acceptance-block.sh" \
    "# ORIGINAL acceptance-block.sh" "$(cat "$SNAP/acceptance-block.sh" 2>/dev/null)"
assert_eq "[SPEC-4] snapshot captures the merge-base.sh dependency" \
    "# ORIGINAL merge-base.sh" "$(cat "$SNAP/merge-base.sh" 2>/dev/null)"

# ── 2. A mid-run working-tree edit must NOT mutate the snapshot ────────────────
print_test_section "2. mid-run working-tree edit does not mutate the snapshot"
printf '# MUTATED mid-run grammar change\n' > "$WT_LIB/acceptance-block.sh"
# Re-invoking the routine (the once-guard) must NOT re-copy the mutated file.
_runner_snapshot_contract_libs "$WT_LIB" "$SNAP"
assert_eq "[SPEC-4] snapshot is immutable to mid-run working-tree edits" \
    "# ORIGINAL acceptance-block.sh" "$(cat "$SNAP/acceptance-block.sh" 2>/dev/null)"

cleanup_test_env
print_test_results
