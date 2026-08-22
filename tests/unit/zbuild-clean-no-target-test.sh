#!/usr/bin/env bash
# Tests: zbuild clean — no-target-argument refusal (#1831 §E5)
#
# SPEC-1: `zbuild clean` with no target argument exits rc=2 and prints a
#         usage/refusal message. This covers the acceptance criterion:
#         "zbuild clean with no target argument refuses rather than defaulting
#         to all runs."
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "zbuild clean: no-target-argument refusal (SPEC-1)"
setup_test_env "zbuild-clean-no-target"

ZBUILD_CLI="$REPO_ROOT/scripts/zbuild"

# ─── SPEC-1: no target → rc=2 + refusal message ──────────────────────────────
# CHANGE: at baseline the `clean` subcommand does not exist; `zbuild clean` exits
# rc=2 with "Unknown command: clean" AND dumps the general usage block. rc alone
# therefore cannot discriminate — nor can "--run-id", which that usage block
# already prints three times (this is what made SPEC-1 tautological at baseline).
# The load-bearing string is "a target is required", emitted only by the new
# refusal path in scripts/zbuild.
print_test_section "SPEC-1: zbuild clean with no target exits rc=2 with refusal"

_out=""
_rc=0
_out="$(bash "$ZBUILD_CLI" clean 2>&1)" || _rc=$?

assert_eq "[SPEC-1] zbuild clean (no args) exits rc=2" "2" "$_rc"

if grep -qF "a target is required" <<< "$_out"; then
    assert_pass "[SPEC-1] refusal names the required target (not the baseline usage dump)"
else
    assert_fail "[SPEC-1] refusal names the required target (not the baseline usage dump)" \
        "got: $_out"
fi

# ─── SPEC-1 variant: --dry-run alone (no --run-id) also refuses ──────────────
print_test_section "SPEC-1: zbuild clean --dry-run (no --run-id) also exits rc=2"

_out2=""
_rc2=0
_out2="$(bash "$ZBUILD_CLI" clean --dry-run 2>&1)" || _rc2=$?

assert_eq "[SPEC-1] zbuild clean --dry-run (no --run-id) exits rc=2" "2" "$_rc2"

if grep -qF "a target is required" <<< "$_out2"; then
    assert_pass "[SPEC-1] --dry-run without --run-id also produces the refusal"
else
    assert_fail "[SPEC-1] --dry-run without --run-id also produces the refusal" \
        "got: $_out2"
fi

# ─── SPEC-1 variant: --purge alone (no --run-id) also refuses ────────────────
print_test_section "SPEC-1: zbuild clean --purge (no --run-id) also exits rc=2"

_out3=""
_rc3=0
_out3="$(bash "$ZBUILD_CLI" clean --purge 2>&1)" || _rc3=$?

assert_eq "[SPEC-1] zbuild clean --purge (no --run-id) exits rc=2" "2" "$_rc3"

if grep -qF "a target is required" <<< "$_out3"; then
    assert_pass "[SPEC-1] --purge without --run-id also produces the refusal"
else
    assert_fail "[SPEC-1] --purge without --run-id also produces the refusal" \
        "got: $_out3"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
