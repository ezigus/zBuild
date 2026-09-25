#!/usr/bin/env bash
# Tests (#2187): one place turns a model-call failure into the disposition word
# that names its cause (ADR-054 §6a), so no stage keeps its own copy.
#
# SPEC-1 [change]: router_reason_disposition maps each router/loop reason to its
#   cause word — timeout → timed_out, turn/iteration budget → out_of_turns, rate
#   limit → rate_limited, a kill or signal → interrupted, any other failed model
#   call → unavailable; no failure → nothing.
# SPEC-2 [change]: a call that failed because it hit its turn budget classifies as
#   router_out_of_turns, not the generic router_rc_nonzero.
# SPEC-3 [guard] : a rate limit still outranks every other reason.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/router-rc-classify.sh
source "$REPO_ROOT/scripts/lib/router-rc-classify.sh"

print_test_header "router failure → the cause word, in one place (#2187)"
setup_test_env "router-reason-disposition"
_test_cleanup_hook() { cleanup_test_env; }

print_test_section "SPEC-1: each reason maps to its cause word"
while read -r _r _want; do
    [[ -n "$_r" ]] || continue
    assert_eq "[SPEC-1] $_r → $_want" "$_want" "$(router_reason_disposition "$_r" 2>/dev/null || echo MISSING)"
done <<'TABLE'
router_timeout timed_out
router_out_of_turns out_of_turns
max_iterations out_of_turns
router_rate_limited rate_limited
router_oom_kill interrupted
signal interrupted
router_rc_nonzero unavailable
error unavailable
router_config_error misconfigured
no_progress unusable
TABLE
assert_eq "[SPEC-1] no failure → no word" "" "$(router_reason_disposition "" 2>/dev/null)"

print_test_section "SPEC-2: a turn-budget hit is named, not generic"
_v="" _r=""
_ROUTE_LAST_BUDGET_EXHAUSTED=1 _router_rc_classify 1 _v _r
assert_eq "[SPEC-2] rc=1 after a turn-budget hit → router_out_of_turns" "router_out_of_turns" "$_r"
_v="" _r=""
_ROUTE_LAST_BUDGET_EXHAUSTED=0 _router_rc_classify 1 _v _r
assert_eq "[SPEC-2] rc=1 otherwise → router_rc_nonzero" "router_rc_nonzero" "$_r"

_v="" _r=""
_ROUTE_LAST_BUDGET_EXHAUSTED=0 _router_rc_classify 2 _v _r
assert_eq "[SPEC-2] rc=2 (the router's own setup checks) → router_config_error" "router_config_error" "$_r"

print_test_section "SPEC-3: a rate limit outranks a turn-budget hit"
_v="" _r=""
_ROUTE_LAST_BUDGET_EXHAUSTED=1 _router_rc_classify 1 _v _r 1
assert_eq "[SPEC-3] rate limit wins" "router_rate_limited" "$_r"

print_test_results
exit $((FAIL > 0))
