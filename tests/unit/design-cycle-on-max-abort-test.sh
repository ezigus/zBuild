#!/usr/bin/env bash
# design-cycle-on-max-abort-test.sh — a design its own gate rejected three
# times is not built (#2176).
#
# ADR-019 chose `on_max: continue` for design_verify_cycle: an imperfect design
# flows to build. #1841 (runs 35636825115, 35660759727): the gate failed on
# the last pass, the run proceeded, and the build cycle inherited RESOLVE
# findings it could not act on (the contract is not the builder's to change).
# The template now says `on_max: abort` — the runner already ends the run as
# failed for that value (cycle-on-max-continue-pipeline-status-test T2).
#
# SPEC-1[change]: simple.yaml's design_verify_cycle declares on_max: abort
# SPEC-2[guard]:  build_test_cycle keeps on_max: continue (its fall-through goes to review)
# SPEC-3[change]: ADR-019 records the reversal for design_verify_cycle
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "design cycle: no build from a design its gate rejected (#2176)"
setup_test_env "design-cycle-on-max-abort"
_on_max() { awk -v id="$1" '$0 ~ "^"id":" {f=1; next} /^[a-z_-]+:/ {f=0} f && /^[[:space:]]+on_max:/ {print $2}' "$REPO_ROOT/config/templates/simple.yaml"; }
assert_eq "[SPEC-1] design_verify_cycle on_max is abort" "abort" "$(_on_max design_verify_cycle)"
assert_eq "[SPEC-2] build_test_cycle on_max stays continue" "continue" "$(_on_max build_test_cycle)"
assert_contains "[SPEC-3] ADR-019 records the design-cycle reversal" \
    "$(cat "$REPO_ROOT"/docs/adr/ADR-019*.md)" "design_verify_cycle\` is \`max_iterations: 3, on_max: abort"
cleanup_test_env
print_test_results
exit $((FAIL > 0))
