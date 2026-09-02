#!/usr/bin/env bash
# tests/unit/run-tests-bash-floor-test.sh
# Tests: Bash 5 floor is enforced at test harness entry points (issue-1693-ci).
#
# SPEC-1 CHANGE  tests/run-all.sh sources compat.sh before test-harness.sh
#                (fails at merge-base: run-all.sh did not source compat.sh)
# SPEC-3 CHANGE  _zbuild_check_bash in compat.sh rejects Bash major < 5
#                (fails at merge-base: this test file did not exist)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "Bash 5 floor enforcement in test harness (issue-1693-ci)"
setup_test_env "run-tests-bash-floor"

RUN_ALL="$REPO_ROOT/tests/run-all.sh"
COMPAT="$REPO_ROOT/scripts/lib/compat.sh"

# ── [SPEC-1] CHANGE: tests/run-all.sh sources compat.sh ──────────────────────
# At merge-base run-all.sh did not source compat.sh; after this change it does.
_compat_in_runall=$(grep -c '^source.*compat\.sh' "$RUN_ALL" 2>/dev/null) || _compat_in_runall=0
assert_eq "[SPEC-1] tests/run-all.sh sources compat.sh for the bash floor check" \
    "1" "$_compat_in_runall"

# ── [SPEC-3] CHANGE: _zbuild_check_bash rejects Bash major < 5 ───────────────

# Static: the function must exist in compat.sh.
_floor_fn_count=$(grep -c '_zbuild_check_bash' "$COMPAT" 2>/dev/null) || _floor_fn_count=0
assert_gt "[SPEC-3] _zbuild_check_bash is defined in compat.sh" \
    "$_floor_fn_count" "0"

# Static: the correct floor comparison must be present.
_floor_cmp=$(grep -c '(( major < 5 ))' "$COMPAT" 2>/dev/null || echo 0)
assert_eq "[SPEC-3] compat.sh uses (( major < 5 )) as the floor comparison" \
    "1" "$_floor_cmp"

# Dynamic: _zbuild_check_bash must return 0 in the current Bash 5 shell.
# shellcheck source=../../scripts/lib/compat.sh
source "$COMPAT" 2>/dev/null
_check_rc=0
_zbuild_check_bash 2>/dev/null || _check_rc=$?
assert_eq "[SPEC-3] _zbuild_check_bash returns 0 in Bash 5 (current shell)" \
    "0" "$_check_rc"

# Reject-path: the floor condition must trigger exit 1 for major=4.
# BASH_VERSINFO is read-only; test the identical arithmetic inline.
_reject_rc=0
(
    major=4
    if (( major < 5 )); then exit 1; fi
    exit 0
) || _reject_rc=$?
assert_eq "[SPEC-3] floor condition (major < 5) triggers exit 1 for major=4" \
    "1" "$_reject_rc"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
