#!/usr/bin/env bash
# Unit: scripts/lib/abort-propagation.sh — the ADR-025 abort-propagation
# contract, on declared channels (#1850, ADR-054 §4).
#
# An abort is RECORDED once, as a word — sigint | sigterm | cycle_abort |
# llm_unavailable | llm_rate_limited | scope_too_large — in the process
# (`_ZB_ABORT_REASON`) and in the sentinel file ${ZBUILD_STATE_DIR}/.abort.signal
# (which crosses subshells and env scrubs, ADR-024). Every helper returns 0 or 1;
# no rc carries the reason any more (it used to: 130, 143, 6, 9, 10).
#
#   A1 _zbuild_abort <word> records it, in-process and in the sentinel; returns 1
#   A2 the first recorded abort wins — a later one does not overwrite it
#   A3 _zbuild_abort_reason reads it back, from the sentinel when the process
#      has none (a sibling subshell recorded it)
#   A4 _zbuild_propagate_abort <rc> → 1 only when rc≠0 AND an abort is recorded
#   A5 _zbuild_check_abort → 1 when an abort is recorded, else 0
#   A6 arm/disarm: arming writes the word (default sigint); disarming clears
#      both channels
#   A7 every helper degrades to a no-op without ZBUILD_STATE_DIR
#   A8 no helper returns an rc outside {0,1}
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "unit: abort-propagation helpers — the abort is a word, rc is 0/1 (ADR-025, #1850)"

export ZBUILD_STATE_DIR
ZBUILD_STATE_DIR="$(mktemp -d)"
# shellcheck source=../../scripts/lib/abort-propagation.sh
source "$REPO_ROOT/scripts/lib/abort-propagation.sh"
_reset() { _zbuild_disarm_abort_sentinel; unset _ZB_ABORT_REASON; }
_rc() { local r=0; "$@" || r=$?; printf '%s' "$r"; }

print_test_section "A1–A3: record, first wins, read back"
_reset
assert_eq "[A1] _zbuild_abort returns 1" "1" "$(_rc _zbuild_abort sigterm)"
_zbuild_abort sigterm || true
assert_eq "[A1] ...records the word in the process" "sigterm" "${_ZB_ABORT_REASON:-}"
assert_eq "[A1] ...and in the sentinel" "sigterm" "$(cat "$ZBUILD_STATE_DIR/.abort.signal" 2>/dev/null)"
_zbuild_abort cycle_abort || true
assert_eq "[A2] a later abort does not overwrite the first" "sigterm" "$(_zbuild_abort_reason)"
assert_eq "[A3] read back from the sentinel in a fresh shell" "sigterm" \
    "$(bash -c 'source "$1"; _zbuild_abort_reason' _ "$REPO_ROOT/scripts/lib/abort-propagation.sh")"

print_test_section "A4/A5: propagate and check"
_reset
assert_eq "[A4] no abort recorded, rc 1 → 0 (an ordinary failure)" "0" "$(_rc _zbuild_propagate_abort 1)"
assert_eq "[A5] no abort recorded → check is 0" "0" "$(_rc _zbuild_check_abort)"
_zbuild_abort llm_unavailable || true
assert_eq "[A4] an abort recorded, rc 1 → 1 (propagate it)" "1" "$(_rc _zbuild_propagate_abort 1)"
assert_eq "[A4] an abort recorded, rc 0 → 0 (the child itself succeeded)" "0" "$(_rc _zbuild_propagate_abort 0)"
assert_eq "[A5] an abort recorded → check is 1" "1" "$(_rc _zbuild_check_abort)"

print_test_section "A6: arm and disarm"
_reset
_zbuild_arm_abort_sentinel
assert_eq "[A6] arming with no word records sigint" "sigint" "$(_zbuild_abort_reason)"
_zbuild_disarm_abort_sentinel
assert_eq "[A6] disarm clears the sentinel" "absent" "$([[ -e "$ZBUILD_STATE_DIR/.abort.signal" ]] && echo present || echo absent)"
assert_eq "[A6] ...and the in-process word" "" "$(_zbuild_abort_reason)"
_zbuild_arm_abort_sentinel sigterm
assert_eq "[A6] arming with a word records it" "sigterm" "$(_zbuild_abort_reason)"
_reset

print_test_section "A7: no ZBUILD_STATE_DIR"
_a7_cwd="$(mktemp -d)"
if (
    cd "$_a7_cwd" || exit 1
    unset ZBUILD_STATE_DIR _ZB_ABORT_REASON
    _zbuild_check_abort || exit 1
    _zbuild_arm_abort_sentinel || exit 1
    _zbuild_disarm_abort_sentinel || exit 1
    _zbuild_abort sigint && exit 1
    [[ "$(_zbuild_abort_reason)" == "sigint" ]] || exit 1
); then
    assert_pass "[A7] helpers work in-process with no state dir"
else
    assert_fail "[A7] helpers work in-process with no state dir" "a helper failed"
fi
assert_eq "[A7] ...and write no file" "" "$(ls -A "$_a7_cwd")"
rm -rf "$_a7_cwd"

print_test_section "A8: rc is 0 or 1"
_bad=""
for _w in sigint sigterm cycle_abort llm_unavailable llm_rate_limited scope_too_large; do
    _reset; r="$(_rc _zbuild_abort "$_w")"; [[ "$r" == 0 || "$r" == 1 ]] || _bad+="abort:$_w=$r "
    for _c in 0 1 2 6 9 10 130 143; do
        r="$(_rc _zbuild_propagate_abort "$_c")"; [[ "$r" == 0 || "$r" == 1 ]] || _bad+="propagate:$_c=$r "
    done
    r="$(_rc _zbuild_check_abort)"; [[ "$r" == 0 || "$r" == 1 ]] || _bad+="check=$r "
done
assert_eq "[A8] no helper returns an rc outside {0,1}" "" "$_bad"
_reset

print_test_section "A9: source guard is idempotent"
# shellcheck source=../../scripts/lib/abort-propagation.sh
source "$REPO_ROOT/scripts/lib/abort-propagation.sh"
assert_pass "[A9] double-source is a no-op"

rm -rf "$ZBUILD_STATE_DIR"
print_test_results
