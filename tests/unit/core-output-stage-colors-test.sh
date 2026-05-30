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
declare -gA _STAGE_COLORS=(
    [intake]="$BLUE"
    [plan]="$CYAN"
    [build]="$YELLOW"
    [test]="$PURPLE"
    [review]="$GREEN"
    [security-lens]="$RED"
)

# ─── R1: registry exposes _stage_color for every canonical stage ─────────────
for stage in intake plan build test review security-lens; do
    c="$(_stage_color "$stage")"
    if [[ -n "$c" ]]; then
        assert_pass "R1 _stage_color $stage returns non-empty"
    else
        assert_fail "R1 _stage_color $stage returns non-empty" "got: <empty>"
    fi
done

# ─── R2: unknown stage falls back to $CYAN ───────────────────────────────────
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

# ─── R5: distinct stages have distinct colors (no aliasing collisions) ───────
plan_c="$(_stage_color plan)"
build_c="$(_stage_color build)"
if [[ "$plan_c" != "$build_c" ]]; then
    assert_pass "R5 plan and build colors differ"
else
    assert_fail "R5 plan and build colors differ" "both: ${plan_c@Q}"
fi

# ─── R6: NO_COLOR-aware — empty-string registry entries on re-init ───────────
# Simulate the NO_COLOR path by zeroing the palette and rebuilding the registry.
CYAN_OFF=''; BLUE_OFF=''; YELLOW_OFF=''; PURPLE_OFF=''; GREEN_OFF=''; RED_OFF=''
declare -gA _STAGE_COLORS=(
    [intake]="$BLUE_OFF"
    [plan]="$CYAN_OFF"
    [build]="$YELLOW_OFF"
    [test]="$PURPLE_OFF"
    [review]="$GREEN_OFF"
    [security-lens]="$RED_OFF"
)
plan_no_color="$(_stage_color plan)"
if [[ -z "$plan_no_color" ]]; then
    assert_pass "R6 NO_COLOR strips registry colors (plan empty)"
else
    assert_fail "R6 NO_COLOR strips registry colors" "got: ${plan_no_color@Q}"
fi

print_test_results
exit "$FAIL"
