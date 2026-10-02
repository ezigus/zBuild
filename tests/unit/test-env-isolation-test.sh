#!/usr/bin/env bash
# tests/unit/test-env-isolation-test.sh — every test runs in its own clean
# folders (#2252 F, fixes #1910).
#
# Why: the pipeline's test stage exports ZBUILD_STATE_ROOT (plus a cost ledger
# and a cache dir) for the suite it runs. setup_test_env cleared only
# ZBUILD_STATE_DIR and ZBUILD_ARTIFACT_DIR, so every test file in that suite
# shared one stage-io folder and one seq counter: #2032 run 36969130031 failed
# test-test.sh twice on another test's leftovers.
#
# I1 [change] every location the engine WRITES (state, artifacts, events,
#             caches, ledgers, pools, scratch, worktrees …) is cleared by
#             setup_test_env — set to a shared path beforehand, it does not
#             survive into the test
# I2 [change] every ZBUILD_* location variable the engine reads is classified:
#             cleared per test, or a code/config location tests may inherit —
#             a new one cannot leak in unclassified
# I3 [guard]  a code/config location (e.g. ZBUILD_PLUGINS_ROOT) is inherited
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "every test runs in its own clean folders (#2252 F, #1910)"

SHARED="/nonexistent/shared-by-every-test"
declare -a _written=() _inherited=()
read -r -a _written <<< "${_ZB_TEST_ISOLATED_VARS[*]:-}"
read -r -a _inherited <<< "${_ZB_TEST_INHERITED_VARS[*]:-}"

print_test_section "I1: written locations are cleared"
for v in ZBUILD_STATE_ROOT ZBUILD_COST_LEDGER ZBUILD_CACHE_DIR "${_written[@]}"; do
    export "$v=$SHARED"
done
export ZBUILD_PLUGINS_ROOT="$REPO_ROOT/plugins"
setup_test_env "test-env-isolation"
for v in ZBUILD_STATE_ROOT ZBUILD_COST_LEDGER ZBUILD_CACHE_DIR "${_written[@]}"; do
    if [[ "${!v:-}" == "$SHARED" ]]; then
        assert_fail "[I1] $v is cleared per test" "still $SHARED"
    else
        assert_pass "[I1] $v is cleared per test"
    fi
done

print_test_section "I2: every location variable is classified"
_all="$(grep -rhoE '\$\{?ZBUILD_[A-Z0-9_]+_(DIR|ROOT|LEDGER|JSONL|DB|MARKER|INPUTS|PATH|HOME|TMPDIR|FILE)\b' \
        "$REPO_ROOT/core" "$REPO_ROOT/scripts" "$REPO_ROOT/plugins" --include='*.sh' 2>/dev/null \
        | tr -d '${' | sort -u)"
assert_eq "[I2] the classification lists exist" "1" \
    "$(( ${#_written[@]} > 0 && ${#_inherited[@]} > 0 ))"
while IFS= read -r v; do
    [[ -n "$v" ]] || continue
    if [[ " ${_written[*]} ${_inherited[*]} " == *" $v "* ]]; then
        assert_pass "[I2] $v is classified"
    else
        assert_fail "[I2] $v is classified" "add it to _ZB_TEST_ISOLATED_VARS or _ZB_TEST_INHERITED_VARS (scripts/lib/test-helpers.sh)"
    fi
done <<< "$_all"

print_test_section "I3: code/config locations are inherited"
assert_eq "[I3] ZBUILD_PLUGINS_ROOT survives setup_test_env" "$REPO_ROOT/plugins" "${ZBUILD_PLUGINS_ROOT:-}"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
