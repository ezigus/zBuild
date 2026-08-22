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

# ─── SPEC-1: no target → rc=2 + usage message ────────────────────────────────
# CHANGE: at baseline the `clean` subcommand does not exist; `zbuild clean` exits
# rc=2 with "Unknown command: clean". After this change it exits rc=2 with a
# dedicated refusal message (different string, same code).
print_test_section "SPEC-1: zbuild clean with no target exits rc=2 with refusal"

_out=""
_rc=0
_out="$(bash "$ZBUILD_CLI" clean 2>&1)" || _rc=$?

assert_eq "[SPEC-1] zbuild clean (no args) exits rc=2" "2" "$_rc"

if echo "$_out" | grep -q "target is required\|--run-id"; then
    assert_pass "[SPEC-1] refusal message mentions required target or --run-id flag"
else
    assert_fail "[SPEC-1] refusal message mentions required target or --run-id flag" \
        "got: $_out"
fi

# ─── SPEC-1 variant: --dry-run alone (no --run-id) also refuses ──────────────
print_test_section "SPEC-1: zbuild clean --dry-run (no --run-id) also exits rc=2"

_out2=""
_rc2=0
_out2="$(bash "$ZBUILD_CLI" clean --dry-run 2>&1)" || _rc2=$?

assert_eq "[SPEC-1] zbuild clean --dry-run (no --run-id) exits rc=2" "2" "$_rc2"

if echo "$_out2" | grep -q "target is required\|--run-id"; then
    assert_pass "[SPEC-1] --dry-run without --run-id also produces refusal message"
else
    assert_fail "[SPEC-1] --dry-run without --run-id also produces refusal message" \
        "got: $_out2"
fi

# ─── SPEC-1 variant: --purge alone (no --run-id) also refuses ────────────────
print_test_section "SPEC-1: zbuild clean --purge (no --run-id) also exits rc=2"

_out3=""
_rc3=0
_out3="$(bash "$ZBUILD_CLI" clean --purge 2>&1)" || _rc3=$?

assert_eq "[SPEC-1] zbuild clean --purge (no --run-id) exits rc=2" "2" "$_rc3"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
