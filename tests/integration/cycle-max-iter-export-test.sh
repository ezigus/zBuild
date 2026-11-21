#!/usr/bin/env bash
# tests/integration/cycle-max-iter-export-test.sh — a loop's member knows its
# loop's last round (#2574 review; ADR-072 §5, amended 2026-11-20).
#
# Why: a part a stage handed to another stage does not wait on the loop's last
# round, so a member must know that round. The cycle exports, beside
# ZBUILD_CYCLE_ITER, ZBUILD_CYCLE_MAX_ITER: the maximum of the loop the member
# runs in.
#
# X1 [change] a member of an inner loop sees the inner loop's maximum
# X2 [change] a member of the outer loop, dispatched after the inner loop has
#             returned, sees the outer loop's maximum
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "a loop's member knows its loop's last round (#2574)"
setup_test_env "cycle-max-iter-export"
# shellcheck source=../lib/nested-loop-rounds-fixture.sh
source "$REPO_ROOT/tests/lib/nested-loop-rounds-fixture.sh"

# Two levels: the outer loop has 4 rounds, the inner loop 2.
cat > "$TPL" <<'EOF'
id: max-iter
name: Max iter export
defaults:
  strategy: fanout

flow:
  - outer_loop

outer_loop:
  type: cycle
  flow:
    - design_loop
    - impact
  exit_when:
    stage: impact
    field: verdict
    op: eq
    value: pass
  max_iterations: 4
  on_max: halt

design_loop:
  type: cycle
  flow:
    - design
  exit_when:
    stage: design
    field: verdict
    op: eq
    value: pass
  max_iterations: 2
  on_max: halt

design:
  roles: [designer]
impact:
  roles: [impact]
EOF
# The stub records what each member sees; every member passes.
# shellcheck disable=SC2329  # called by the orchestrator
cycle_dispatch_stage() {
    printf '%s|max=%s\n' "$1" "${ZBUILD_CYCLE_MAX_ITER:-unset}" >> "$LOG"
    _CYCLE_DISPATCH_VERDICT="pass"; _CYCLE_DISPATCH_STATUS="complete"; _CYCLE_DISPATCH_REPORT="{}"
    _CYCLE_DISPATCH_DISPOSITION=""; _CYCLE_DISPATCH_REASON=""
    return 0
}

print_test_section "X1/X2: each member sees its own loop's maximum"
_run; rc=$?
assert_eq "[X1/X2] setup: the run converges" "0" "$rc"
assert_contains "[X1] design, inside the inner loop, sees its maximum" "$(cat "$LOG")" "design|max=2"
assert_contains "[X2] impact, after the inner loop returned, sees the outer loop's" "$(cat "$LOG")" "impact|max=4"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
