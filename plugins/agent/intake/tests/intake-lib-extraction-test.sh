#!/usr/bin/env bash
# Tests: plugins/agent/intake — lib/ extraction (issue #1636)
#
# The refactor is pure movement: four function groups leave plugin.sh for
# plugins/agent/intake/lib/, and plugin.sh sources them. Nothing about the
# plugin's behaviour changes.
#
# This file exists so the two co-located suites (intake-test.sh,
# intake-branch-test.sh) stay UNEDITED — #1636 names them as the regression net
# for this change and asks that they not be touched in the same PR. Asserting
# the extraction from a separate file keeps that net honest: it passes or fails
# on its own merits, not because someone adjusted it to fit.
#
# SPEC-1: lib/sanitize.sh exists and defines the goal-sanitisation function
# SPEC-2: lib/issue-state.sh exists and defines the closed-issue gate
# SPEC-3: lib/branch-names.sh exists and defines both branch-name functions
# SPEC-4: lib/branch-ops.sh exists and defines the three branch-workflow functions
# SPEC-5: plugin.sh is under the 500-line ceiling (the point of the issue)
# SPEC-6: sourcing plugin.sh still exposes every extracted function, and branch
#         derivation is byte-identical — the movement preserved behaviour
set -uo pipefail
# Deliberately NOT `set -e`, matching intake-branch-test.sh in this directory.
# assert_fail's last statement is `[[ -n "$detail" ]] && echo …`, so it returns
# NON-ZERO whenever it is called without a detail argument. Under -e that aborts
# the file mid-run, before print_test_results — a failing test that exits 0 and
# reads as a pass. Verified: the statement after such an assert_fail never runs.
# The setup-failure case -e would have caught is handled explicitly below.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# Explicit source guard (PR #1646 review): without -e a failed source would let
# the file run on with every helper undefined, producing a cascade of
# "command not found" instead of naming the missing dependency. Fail loudly here.
for _dep in scripts/lib/helpers.sh scripts/lib/test-helpers.sh; do
    if [[ ! -f "$REPO_ROOT/$_dep" ]]; then
        printf 'intake-lib-extraction-test: required dependency missing: %s\n' \
            "$REPO_ROOT/$_dep" >&2
        exit 2
    fi
done
# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugin: intake — lib/ extraction (#1636)"
setup_test_env "intake-lib-extraction"

_INTAKE_DIR="$REPO_ROOT/plugins/agent/intake"
_LIB="$_INTAKE_DIR/lib"

# _defines <file> <function> — the file must DEFINE the function, not merely
# mention it. A grep for the bare name would also match a call site, which is
# exactly what a half-finished extraction leaves behind.
_defines() {
    grep -qE "^[[:space:]]*(function[[:space:]]+)?$2[[:space:]]*\(\)" "$1" 2>/dev/null
}

# ─── SPEC-1..4: each lib file exists AND owns its functions ──────────────────
if [[ -f "$_LIB/sanitize.sh" ]] && _defines "$_LIB/sanitize.sh" _intake_strip_synthesized; then
    assert_pass "[SPEC-1] lib/sanitize.sh defines _intake_strip_synthesized"
else
    assert_fail "[SPEC-1] lib/sanitize.sh must define _intake_strip_synthesized" \
        "exists=$([[ -f "$_LIB/sanitize.sh" ]] && echo yes || echo no)"
fi

if [[ -f "$_LIB/issue-state.sh" ]] && _defines "$_LIB/issue-state.sh" _intake_check_issue_state; then
    assert_pass "[SPEC-2] lib/issue-state.sh defines _intake_check_issue_state"
else
    assert_fail "[SPEC-2] lib/issue-state.sh must define _intake_check_issue_state" \
        "exists=$([[ -f "$_LIB/issue-state.sh" ]] && echo yes || echo no)"
fi

if [[ -f "$_LIB/branch-names.sh" ]] \
   && _defines "$_LIB/branch-names.sh" _intake_derive_branch_name \
   && _defines "$_LIB/branch-names.sh" _intake_validate_branch_name; then
    assert_pass "[SPEC-3] lib/branch-names.sh defines both branch-name functions"
else
    assert_fail "[SPEC-3] lib/branch-names.sh must define both branch-name functions" \
        "exists=$([[ -f "$_LIB/branch-names.sh" ]] && echo yes || echo no)"
fi

if [[ -f "$_LIB/branch-ops.sh" ]] \
   && _defines "$_LIB/branch-ops.sh" _intake_check_preflight \
   && _defines "$_LIB/branch-ops.sh" _intake_checkout_branch \
   && _defines "$_LIB/branch-ops.sh" _intake_create_workspace_branch; then
    assert_pass "[SPEC-4] lib/branch-ops.sh defines the three branch-workflow functions"
else
    assert_fail "[SPEC-4] lib/branch-ops.sh must define the three branch-workflow functions" \
        "exists=$([[ -f "$_LIB/branch-ops.sh" ]] && echo yes || echo no)"
fi

# ─── SPEC-5: the ceiling this issue exists to restore ────────────────────────
# CLAUDE.md: "Keep files under 500 lines unless there is a strong reason."
_plugin_lines="$(wc -l < "$_INTAKE_DIR/plugin.sh" | tr -d ' ')"
if [[ "$_plugin_lines" -lt 500 ]]; then
    assert_pass "[SPEC-5] plugin.sh is under the 500-line ceiling ($_plugin_lines lines)"
else
    assert_fail "[SPEC-5] plugin.sh must be under 500 lines" "got $_plugin_lines"
fi

# ─── SPEC-6: pure movement — every function still reachable, same output ─────
# Sourcing plugin.sh must transitively load the libs. A missing `source` line
# would leave a function undefined here while every file above still passed,
# which is the failure mode "the files exist" cannot see.
_probe="$(
    set +u
    source "$_INTAKE_DIR/plugin.sh" >/dev/null 2>&1
    _missing=""
    for _fn in _intake_strip_synthesized _intake_check_issue_state \
               _intake_derive_branch_name _intake_validate_branch_name \
               _intake_check_preflight _intake_checkout_branch \
               _intake_create_workspace_branch intake_run; do
        declare -F "$_fn" >/dev/null 2>&1 || _missing="$_missing $_fn"
    done
    printf '%s|%s' "${_missing# }" "$(_intake_derive_branch_name 1 'fix bug' 2>/dev/null)"
)"
_missing="${_probe%%|*}"
_derived="${_probe#*|}"

if [[ -z "$_missing" ]]; then
    assert_pass "[SPEC-6] sourcing plugin.sh exposes every extracted function"
else
    assert_fail "[SPEC-6] plugin.sh must still expose every extracted function" \
        "undefined:$_missing"
fi
assert_eq "[SPEC-6] branch derivation is unchanged by the extraction" \
    "zbuild/issue-1-fix-bug" "$_derived"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
