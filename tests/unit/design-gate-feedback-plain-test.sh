#!/usr/bin/env bash
# tests/unit/design-gate-feedback-plain-test.sh — the design check tells design
# what to change in plain sentences; its codes stay in the machine-read JSON (#2269).
#
# Why: design-gate-feedback.md is what design reads on its next round. It listed
# codes — "WIRING_MISSING (design.md acceptance block has no WIRING: section)",
# "UNCLASSIFIED SPEC-2 (SPEC lacks a [change]|[guard] classifier)" — the check's
# names, not what to do.
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
setup_test_env "design-gate-feedback-plain"
export ZBUILD_EVENTS_DB="/dev/null"
# shellcheck source=../../scripts/lib/acceptance-block.sh
source "$REPO_ROOT/scripts/lib/acceptance-block.sh"
# shellcheck source=../../plugins/tool/design-gate/plugin.sh
source "$REPO_ROOT/plugins/tool/design-gate/plugin.sh"

ROOT="$TEST_TEMP_DIR/repo"; mkdir -p "$ROOT/tests"; export ZBUILD_REPO_ROOT="$ROOT"
_n=0
_gate() {   # _gate <design.md> → $FB (feedback text), $VIOL (JSON violations)
    _n=$((_n + 1)); local d="$TEST_TEMP_DIR/s$_n"; mkdir -p "$d/artifacts"
    printf '%s' "$1" > "$d/artifacts/design.md"; printf '{"schema_version":1}' > "$d/pipeline-state.json"
    design_gate_run "design-gate" "$d/pipeline-state.json" >/dev/null 2>&1 || true
    FB="$(cat "$d/artifacts/design-gate-feedback.md" 2>/dev/null)"
    VIOL="$(jq -r '.violations[]?' "$d/artifacts/design-gate-result.json" 2>/dev/null)"
}

_gate $'# Design\n\nNo blocks at all.\n'
_fb1="$FB"; _v1="$VIOL"
_gate $'# Design\n\n```scope\nlib/a.sh\n```\n\n```acceptance\nSPEC-1[change]: a\nSPEC-2: b\nTESTFILES:\n```\n'
_fb2="$FB"; _v2="$VIOL"
_gate $'# Design\n\n```scope\nlib/a.sh\n```\n\n```acceptance\nSPEC-1[guard]: a\nWIRING: lib/gone.sh\nTESTFILES:\nSPEC-1: tests/a-test.sh\n```\n'
_fb3="$FB"; _v3="$VIOL"
_all_fb="$_fb1"$'\n'"$_fb2"$'\n'"$_fb3"

for _c in SCOPE_MISSING ACCEPTANCE_MISSING UNCLASSIFIED MISSING_TESTFILE_FOR_SPEC WIRING_MISSING GUARD_REGRESSED merge-base classifier; do
    if grep -qF -- "$_c" <<< "$_all_fb"; then
        assert_fail "[D1] the feedback does not say '$_c'" "found in design-gate-feedback.md"
    else
        assert_pass "[D1] the feedback does not say '$_c'"
    fi
done

assert_contains "[D2] a missing scope block is said plainly" "$_fb1" "has no scope block"
assert_contains "[D2] an untagged requirement is said plainly" "$_fb2" "SPEC-2 has no tag"
assert_contains "[D2] a [change] with no test file is said plainly" "$_fb2" "SPEC-1 has no test file listed"
assert_contains "[D2] a missing WIRING line asks the question" "$_fb2" "which existing file calls the new code"
assert_contains "[D2] a WIRING file that does not exist is said plainly" "$_fb3" "lib/gone.sh does not exist"

assert_contains "[D3] the JSON still carries SCOPE_MISSING" "$_v1" "SCOPE_MISSING"
assert_contains "[D3] the JSON still carries UNCLASSIFIED" "$_v2" "UNCLASSIFIED SPEC-2"
assert_contains "[D3] the JSON still carries WIRING_MISSING" "$_v3" "WIRING_MISSING lib/gone.sh"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
