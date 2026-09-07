#!/usr/bin/env bash
# tests/unit/plugin-route-source-guard-test.sh — every route_to_model caller
# must source core/router/route.sh (#2063).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugin route source guard — route_to_model callers load route.sh (#2063)"
setup_test_env "plugin-route-source-guard"

GUARD="$REPO_ROOT/scripts/lib/lint-route-source.sh"
FIXTURES="$TEST_TEMP_DIR/plugins"
mkdir -p "$FIXTURES/agent/good" "$FIXTURES/agent/comment-only" "$FIXTURES/agent/bad"

printf '%s\n' \
    'source "$ROOT/core/router/route.sh"' \
    'route_to_model "T1" "prompt"' \
    > "$FIXTURES/agent/good/plugin.sh"
printf '%s\n' \
    '# route_to_model is intentionally mentioned only in a comment' \
    > "$FIXTURES/agent/comment-only/plugin.sh"
printf '%s\n' \
    'route_to_model "T1" "prompt"' \
    > "$FIXTURES/agent/bad/plugin.sh"

set +e
_fixture_out="$(bash "$GUARD" "$FIXTURES" 2>&1)"
_fixture_rc=$?
set -e
assert_eq "[SPEC-1] a caller without route.sh is rejected" "1" "$_fixture_rc"
assert_contains "[SPEC-1] the failure names the offending plugin" \
    "$_fixture_out" "agent/bad/plugin.sh"
if grep -qF "comment-only/plugin.sh" <<< "$_fixture_out"; then
    assert_fail "[SPEC-2] a comment-only mention is ignored" "unexpected violation"
else
    assert_pass "[SPEC-2] a comment-only mention is ignored"
fi
if grep -qF "good/plugin.sh" <<< "$_fixture_out"; then
    assert_fail "[SPEC-2] a sourced caller is accepted" "unexpected violation"
else
    assert_pass "[SPEC-2] a sourced caller is accepted"
fi

set +e
_tree_out="$(bash "$GUARD" "$REPO_ROOT/plugins" 2>&1)"
_tree_rc=$?
set -e
assert_eq "[SPEC-3] the shipped plugins tree satisfies the guard" "0" "$_tree_rc"
assert_eq "[SPEC-3] the shipped plugins tree emits no violations" "" "$_tree_out"

cleanup_test_env
print_test_results
