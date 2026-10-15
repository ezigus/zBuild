#!/usr/bin/env bash
# tests/unit/design-checks-plain-test.sh — design's checks tell its model what
# to change in plain sentences; the codes stay machine-read (#2269; #2369 moved
# the checks into design).
#
# Why: what the checks find is what design's model reads on its next round. It listed
# codes — "WIRING_MISSING (design.md acceptance block has no WIRING: section)",
# "UNCLASSIFIED SPEC-2 (SPEC lacks a classifier)" — the check's names, not what
# to do.
#
# D1 [change] the feedback file carries no violation code
# D2 [change] each finding says what to change, in plain words
# D3 [guard]  the result JSON still carries the codes (other code and tests read them)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "the design check's feedback is plain (#2269)"
setup_test_env "design-checks-plain"
# shellcheck source=../../scripts/lib/acceptance-block.sh
source "$REPO_ROOT/scripts/lib/acceptance-block.sh"
# shellcheck source=../../plugins/agent/design/lib/checks.sh
source "$REPO_ROOT/plugins/agent/design/lib/checks.sh"

ROOT="$TEST_TEMP_DIR/repo"; mkdir -p "$ROOT/tests"; export ZBUILD_REPO_ROOT="$ROOT"
_n=0
_gate() {   # _gate <design.md> → $FB (what the model is told), $VIOL (the codes)
    _n=$((_n + 1)); local d="$TEST_TEMP_DIR/s$_n" v; mkdir -p "$d"
    printf '%s' "$1" > "$d/design.md"
    _design_checks "$d/design.md" "$ROOT" ""
    FB="$(for v in "${_DESIGN_VIOLATIONS[@]}"; do _dck_plain "$v"; printf '\n'; done)"
    VIOL="$(printf '%s\n' "${_DESIGN_VIOLATIONS[@]}")"
}

_gate $'# Design\n\nNo blocks at all.\n'
_fb1="$FB"; _v1="$VIOL"
_gate $'# Design\n\n```scope\nlib/a.sh\n```\n\n```acceptance\nSPEC-1[code]: a\nSPEC-2: b\nTESTFILES:\n```\n'
_fb2="$FB"; _v2="$VIOL"
_gate $'# Design\n\n```scope\nlib/a.sh\n```\n\n```acceptance\nSPEC-1[done]: a evidence: lib/gone.sh:3\nWIRING: lib/gone.sh\nTESTFILES:\nSPEC-1: tests/a-test.sh\n```\n'
_fb3="$FB"; _v3="$VIOL"
_all_fb="$_fb1"$'\n'"$_fb2"$'\n'"$_fb3"

for _c in SCOPE_MISSING ACCEPTANCE_MISSING NO_STATUS UNKNOWN_STATUS DONE_NO_EVIDENCE DONE_BAD_EVIDENCE MISSING_TESTFILE_FOR_SPEC WIRING_MISSING merge-base classifier; do
    if grep -qF -- "$_c" <<< "$_all_fb"; then
        assert_fail "[D1] the feedback does not say '$_c'" "found in what the model is told"
    else
        assert_pass "[D1] the feedback does not say '$_c'"
    fi
done

assert_contains "[D2] a missing scope block is said plainly" "$_fb1" "has no scope block"
assert_contains "[D2] a requirement with no status is said plainly" "$_fb2" "SPEC-2 has no status"
assert_contains "[D2] a [code] requirement with no test file is said plainly" "$_fb2" "SPEC-1 has no test file listed"
assert_contains "[D2] a missing WIRING line asks the question" "$_fb2" "which existing file calls the new code"
assert_contains "[D2] a WIRING file that does not exist is said plainly" "$_fb3" "lib/gone.sh does not exist"
assert_contains "[D2] evidence that does not exist is said plainly (#2304)" "$_fb3" \
    "the evidence lib/gone.sh:3 for SPEC-1 does not point at the repository"

assert_contains "[D3] the codes still carry SCOPE_MISSING" "$_v1" "SCOPE_MISSING"
assert_contains "[D3] the codes still carry NO_STATUS" "$_v2" "NO_STATUS SPEC-2"
assert_contains "[D3] the codes still carry WIRING_MISSING" "$_v3" "WIRING_MISSING lib/gone.sh"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
