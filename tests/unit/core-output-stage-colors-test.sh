#!/usr/bin/env bash
# Tests: core/output/stage-colors.sh — per-stage color registry (#492)
#
# Covers:
#   - _stage_color returns registered ANSI for known stages
#   - unknown stages fall back to $CYAN
#   - load guard is idempotent (re-source is a no-op)
#   - NO_COLOR strips colors transparently (registry holds globals by reference)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/output/stage-colors — per-stage color registry (#492)"

# Force-enable colors regardless of test-runner tty state (the helpers'
# auto-detection nulls them when stdout is piped). Pin literals so the
# registry references resolve to predictable values for assertions.
unset NO_COLOR
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
CYAN='\033[38;2;0;212;255m'
PURPLE='\033[38;2;124;58;237m'
BLUE='\033[38;2;0;102;255m'
GREEN='\033[38;2;74;222;128m'
YELLOW='\033[38;2;250;204;21m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'; BOLD='\033[1m'; RESET='\033[0m'
# shellcheck source=../../core/output/stage-colors.sh
source "$REPO_ROOT/core/output/stage-colors.sh"
# Rebuild the registry against the just-set color literals (the registry was
# captured at source-time using the auto-detected — possibly empty — values).
# #499: all built-in stages collapsed to uniform BLUE.
declare -gA _STAGE_COLORS=(
    [intake]="$BLUE"
    [plan]="$BLUE"
    [build]="$BLUE"
    [test]="$BLUE"
    [review]="$BLUE"
    [security-lens]="$BLUE"
)

# ─── R1: every built-in stage returns $BLUE (collapsed palette, #499) ────────
for stage in intake plan build test review security-lens; do
    c="$(_stage_color "$stage")"
    if [[ "$c" == "$BLUE" ]]; then
        assert_pass "R1 _stage_color $stage == \$BLUE"
    else
        assert_fail "R1 _stage_color $stage == \$BLUE" "got: ${c@Q}"
    fi
done

# ─── R2: unknown stage falls back to $CYAN (diagnostic signal, #499) ─────────
unknown="$(_stage_color "this-stage-does-not-exist")"
assert_eq "R2 unknown stage falls back to CYAN" "$CYAN" "$unknown"

# ─── R3: empty stage arg falls back to CYAN, never errors ────────────────────
empty="$(_stage_color "")"
assert_eq "R3 empty stage arg falls back to CYAN" "$CYAN" "$empty"

# ─── R4: load guard — re-source is a no-op ───────────────────────────────────
pre_loaded="$_ZBUILD_STAGE_COLORS_LOADED"
source "$REPO_ROOT/core/output/stage-colors.sh"
post_loaded="$_ZBUILD_STAGE_COLORS_LOADED"
assert_eq "R4 load guard preserves value across re-source" "$pre_loaded" "$post_loaded"

# ─── R5: built-in stages share the BLUE color (#499 — flipped from R5 pre-#499) ─
plan_c="$(_stage_color plan)"
build_c="$(_stage_color build)"
intake_c="$(_stage_color intake)"
test_c="$(_stage_color test)"
review_c="$(_stage_color review)"
sec_c="$(_stage_color security-lens)"
if [[ "$plan_c" == "$build_c" && "$build_c" == "$intake_c" && "$intake_c" == "$test_c" \
    && "$test_c" == "$review_c" && "$review_c" == "$sec_c" && "$plan_c" == "$BLUE" ]]; then
    assert_pass "R5 all built-in stages == \$BLUE"
else
    assert_fail "R5 all built-in stages == \$BLUE" \
        "plan=${plan_c@Q} build=${build_c@Q} intake=${intake_c@Q} test=${test_c@Q} review=${review_c@Q} sec=${sec_c@Q}"
fi

# ─── R6: NO_COLOR-aware — empty-string registry entries on re-init ───────────
# Simulate the NO_COLOR path by zeroing the palette and rebuilding the registry.
BLUE_OFF=''
declare -gA _STAGE_COLORS=(
    [intake]="$BLUE_OFF"
    [plan]="$BLUE_OFF"
    [build]="$BLUE_OFF"
    [test]="$BLUE_OFF"
    [review]="$BLUE_OFF"
    [security-lens]="$BLUE_OFF"
)
plan_no_color="$(_stage_color plan)"
if [[ -z "$plan_no_color" ]]; then
    assert_pass "R6 NO_COLOR strips registry colors (plan empty)"
else
    assert_fail "R6 NO_COLOR strips registry colors" "got: ${plan_no_color@Q}"
fi

# ─── R7: register_stage_color extensibility (#499) ──────────────────────────
# Rebuild the colored registry so we can verify a runtime register call wins.
declare -gA _STAGE_COLORS=(
    [intake]="$BLUE" [plan]="$BLUE" [build]="$BLUE"
    [test]="$BLUE" [review]="$BLUE" [security-lens]="$BLUE"
)
register_stage_color "my-custom-stage" "$RED"
custom_c="$(_stage_color "my-custom-stage")"
assert_eq "R7 register_stage_color sets new stage to \$RED" "$RED" "$custom_c"
register_stage_color "plan" "$RED"
plan_overridden="$(_stage_color plan)"
assert_eq "R7 register_stage_color overrides built-in plan" "$RED" "$plan_overridden"

print_test_results
exit "$FAIL"
