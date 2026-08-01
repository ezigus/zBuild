#!/usr/bin/env bash
# Tests: _reachability_is_timeout_rc rc=137 classification (#1660).
# [SPEC-3] rc=137 (SIGKILL) is classified as an infrastructure timeout in the
# reachability gate, matching the negctl gate behaviour added in the same change.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/acceptance-reachability.sh
source "$REPO_ROOT/scripts/lib/acceptance-reachability.sh"

print_test_header "acceptance reachability — rc=137 timeout classification (#1660)"
setup_test_env "acceptance-reachability-kill"

# ── REACH-KILL-1: [SPEC-3] rc=137 (SIGKILL) classified as infra timeout ───────
# Before this change, _reachability_is_timeout_rc did not recognise rc=137. A
# process killed by SIGKILL (-k kill-after or OOM) would not be flagged as a
# timeout, leaving the flip-detection verdict wrong.
set +e; _reachability_is_timeout_rc 137; _rc_137=$?; set -e
assert_eq "[SPEC-3] _reachability_is_timeout_rc 137 → true (SIGKILL = infra timeout)" \
    "0" "$_rc_137"

# Guard: existing timeout codes must still be recognised (invariant).
set +e; _reachability_is_timeout_rc 124; _rc_124=$?; set -e
assert_eq "REACH-GUARD: _reachability_is_timeout_rc 124 → true" "0" "$_rc_124"
set +e; _reachability_is_timeout_rc 143; _rc_143=$?; set -e
assert_eq "REACH-GUARD: _reachability_is_timeout_rc 143 → true" "0" "$_rc_143"
set +e; _reachability_is_timeout_rc 1; _rc_1=$?; set -e
assert_eq "REACH-GUARD: _reachability_is_timeout_rc 1 → false" "1" "$_rc_1"

cleanup_test_env
print_test_results
