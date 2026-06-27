#!/usr/bin/env bash
# Unit: scripts/lib/abort-propagation.sh — _zbuild_propagate_abort +
# _zbuild_check_abort + arm/disarm sentinel helpers (ADR-025, Wave 15-B #684).
#
# Asserts the two-layer contract from ADR-025:
#   Layer 1 (rc propagation): _zbuild_propagate_abort returns its argument
#     rc for abort rcs (130 today) and 0 for non-abort rcs. Stable
#     signature across SIGTERM widening (Wave 15-F #686).
#   Layer 2 (sentinel file): _zbuild_check_abort returns 130 when the
#     sentinel file ${ZBUILD_STATE_DIR}/.abort.signal exists, 0 otherwise.
#     arm/disarm round-trip leaves no stale file.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "unit: abort-propagation helpers (ADR-025 / #684)"

# shellcheck source=../../scripts/lib/abort-propagation.sh
source "$REPO_ROOT/scripts/lib/abort-propagation.sh"

print_test_section "1. _zbuild_propagate_abort: rc=130 propagates as 130"

_zbuild_propagate_abort 130
rc=$?
assert_eq "rc=130 → returns 130" "130" "$rc"

print_test_section "1b. _zbuild_propagate_abort: rc=143 propagates as 143 (Wave 15-F)"

# Wave 15-F (#686): SIGTERM parity — 143 = 128+SIGTERM is an abort rc.
_zbuild_propagate_abort 143
rc=$?
assert_eq "rc=143 → returns 143" "143" "$rc"

print_test_section "1c. _zbuild_propagate_abort: rc=9 propagates as 9 (#1024 llm_unavailable)"

# [SPEC-8] #1024: a sustained AI-CLI failure aborts with rc=9 (llm_unavailable).
# Load-bearing negative control — at merge-base rc=9 fell through to *)→0, so the
# fast-fail abort would have been silently swallowed instead of propagating.
_zbuild_propagate_abort 9
rc=$?
assert_eq "rc=9 → returns 9 (llm_unavailable abort)" "9" "$rc"

print_test_section "1d. _zbuild_propagate_abort: rc=10 propagates as 10 (#1052 scope_too_large)"

# #1052: the plan stage exhausting its turn budget aborts with rc=10
# (scope_too_large — SPLIT THE ISSUE). Distinct from rc=8 (blocking_member_failure,
# ADR-013) and rc=9 (llm_unavailable, #1024). Load-bearing negative control: at
# merge-base rc=10 fell through to *)→0, so the terminal scope-too-large abort
# would have been silently swallowed instead of propagating.
_zbuild_propagate_abort 10
rc=$?
assert_eq "rc=10 → returns 10 (scope_too_large abort)" "10" "$rc"

print_test_section "2. _zbuild_propagate_abort: rc=0 → 0"

_zbuild_propagate_abort 0
rc=$?
assert_eq "rc=0 → returns 0" "0" "$rc"

print_test_section "3. _zbuild_propagate_abort: rc=1 → 0 (not an abort)"

_zbuild_propagate_abort 1
rc=$?
assert_eq "rc=1 → returns 0 (non-abort failure)" "0" "$rc"

print_test_section "4. _zbuild_propagate_abort: rc=2 → 0 (not an abort)"

_zbuild_propagate_abort 2
rc=$?
assert_eq "rc=2 → returns 0 (non-abort failure)" "0" "$rc"

print_test_section "5. _zbuild_check_abort: sentinel absent → returns 0"

export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/abort-state"
mkdir -p "$ZBUILD_STATE_DIR"
rm -f "$ZBUILD_STATE_DIR/.abort.signal"

_zbuild_check_abort
rc=$?
assert_eq "sentinel absent → 0" "0" "$rc"

print_test_section "6. _zbuild_check_abort: sentinel present → returns 130"

: > "$ZBUILD_STATE_DIR/.abort.signal"
_zbuild_check_abort
rc=$?
assert_eq "sentinel present → 130" "130" "$rc"

print_test_section "7. arm/disarm sentinel round-trip cleans up"

rm -f "$ZBUILD_STATE_DIR/.abort.signal"

_zbuild_arm_abort_sentinel
arm_rc=$?
assert_eq "_zbuild_arm_abort_sentinel rc=0" "0" "$arm_rc"
assert_file_exists "sentinel exists after arm" "$ZBUILD_STATE_DIR/.abort.signal"

# After arm, check_abort must see it
_zbuild_check_abort
post_arm_rc=$?
assert_eq "after arm → check_abort returns 130" "130" "$post_arm_rc"

_zbuild_disarm_abort_sentinel
disarm_rc=$?
assert_eq "_zbuild_disarm_abort_sentinel rc=0" "0" "$disarm_rc"

if [[ -e "$ZBUILD_STATE_DIR/.abort.signal" ]]; then
    assert_fail "sentinel removed after disarm" "still exists after disarm"
else
    assert_pass "sentinel removed after disarm"
fi

# After disarm, check_abort must return 0
_zbuild_check_abort
post_disarm_rc=$?
assert_eq "after disarm → check_abort returns 0" "0" "$post_disarm_rc"

print_test_section "8. degrades to no-op when ZBUILD_STATE_DIR unset"

(
    unset ZBUILD_STATE_DIR
    _zbuild_check_abort
    rc=$?
    [[ "$rc" -eq 0 ]] || exit 1
    _zbuild_arm_abort_sentinel || exit 1
    _zbuild_disarm_abort_sentinel || exit 1
) && assert_pass "helpers no-op when ZBUILD_STATE_DIR unset" \
   || assert_fail "helpers no-op when ZBUILD_STATE_DIR unset" "non-zero rc"

print_test_section "9. source guard is idempotent"

# shellcheck source=../../scripts/lib/abort-propagation.sh
source "$REPO_ROOT/scripts/lib/abort-propagation.sh"
source "$REPO_ROOT/scripts/lib/abort-propagation.sh"
assert_pass "double-source is a no-op (source guard works)"

print_test_results
exit $((FAIL > 0))
