#!/usr/bin/env bash
# Tests: scripts/lib/helpers.sh — LIGHT_BLUE color global (#499)
#
# Covers:
#   - LIGHT_BLUE populated to medium-weight RGB escape under FORCE_COLOR=1
#   - LIGHT_BLUE empty under NO_COLOR=1
#   - LIGHT_BLUE empty when stdout is non-tty + no FORCE_COLOR
#   - LIGHT_BLUE listed in the `export` line so subshells inherit it
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "scripts/lib/helpers.sh — LIGHT_BLUE global (#499)"

# ─── L1: LIGHT_BLUE non-empty under FORCE_COLOR=1 ───────────────────────────
# Run in a clean subshell so the load-guard doesn't fossilize a previous
# (uncolored) source from the test runner's process.
val_force="$(
    unset _ZBUILD_HELPERS_LOADED NO_COLOR
    export FORCE_COLOR=1
    # shellcheck source=../../scripts/lib/helpers.sh
    source "$REPO_ROOT/scripts/lib/helpers.sh"
    printf '%s' "${LIGHT_BLUE:-__UNSET__}"
)"
# Helpers stores the escape as a backslash-encoded literal (e.g. \033[...m),
# which echo -e / printf %b later expand to a real ESC. Compare the literal
# form so the test matches the source-of-truth representation.
assert_eq "L1 LIGHT_BLUE under FORCE_COLOR=1 is the medium-weight RGB escape" \
    '\033[38;2;100;200;255m' "$val_force"

# ─── L2: LIGHT_BLUE empty under NO_COLOR=1 ──────────────────────────────────
val_no="$(
    unset _ZBUILD_HELPERS_LOADED
    export NO_COLOR=1
    export FORCE_COLOR=1   # NO_COLOR wins
    # shellcheck source=../../scripts/lib/helpers.sh
    source "$REPO_ROOT/scripts/lib/helpers.sh"
    printf '[%s]' "${LIGHT_BLUE:-}"
)"
assert_eq "L2 LIGHT_BLUE under NO_COLOR=1 is empty" "[]" "$val_no"

# ─── L3: LIGHT_BLUE empty when stdout non-tty + no FORCE_COLOR ──────────────
# The subshell's stdout is captured by $() — definitively not a tty — and
# FORCE_COLOR is unset, so helpers must null all colors including LIGHT_BLUE.
val_nontty="$(
    unset _ZBUILD_HELPERS_LOADED NO_COLOR FORCE_COLOR
    # shellcheck source=../../scripts/lib/helpers.sh
    source "$REPO_ROOT/scripts/lib/helpers.sh"
    printf '[%s]' "${LIGHT_BLUE:-}"
)"
assert_eq "L3 LIGHT_BLUE empty when stdout non-tty and no FORCE_COLOR" "[]" "$val_nontty"

# ─── L4: LIGHT_BLUE appears in the `export` line ────────────────────────────
# Grep the file directly; the export list is the public surface for subshells.
if grep -Eq '^export[[:space:]]+.*\bLIGHT_BLUE\b' "$REPO_ROOT/scripts/lib/helpers.sh"; then
    assert_pass "L4 LIGHT_BLUE present in helpers.sh export line"
else
    assert_fail "L4 LIGHT_BLUE present in helpers.sh export line" \
        "no matching export line found"
fi

print_test_results
exit "$FAIL"
