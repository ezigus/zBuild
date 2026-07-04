#!/usr/bin/env bash
# Tests: scripts/lib/router-rc-classify.sh — rc → verdict + reason mapping (#782).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/router-rc-classify.sh
source "$REPO_ROOT/scripts/lib/router-rc-classify.sh"

print_test_header "router-rc-classify — rc → verdict + reason (#782)"

# T1: rc=0 → empty verdict + empty reason (caller treats as success).
v=""; r=""
_router_rc_classify 0 v r
assert_eq "T1: rc=0 verdict empty" "" "$v"
assert_eq "T1: rc=0 reason empty" "" "$r"

# T2: rc=124 (gtimeout) → verdict=error reason=router_timeout.
v=""; r=""
_router_rc_classify 124 v r
assert_eq "T2: rc=124 verdict=error" "error" "$v"
assert_eq "T2: rc=124 reason=router_timeout" "router_timeout" "$r"

# T3: rc=137 (SIGKILL by OOM) → verdict=error reason=router_oom_kill.
v=""; r=""
_router_rc_classify 137 v r
assert_eq "T3: rc=137 verdict=error" "error" "$v"
assert_eq "T3: rc=137 reason=router_oom_kill" "router_oom_kill" "$r"

# T4: other rc>0 (e.g. 1 = generic claude error) → verdict=fail.
v=""; r=""
_router_rc_classify 1 v r
assert_eq "T4: rc=1 verdict=fail" "fail" "$v"
assert_eq "T4: rc=1 reason=router_rc_nonzero" "router_rc_nonzero" "$r"

v=""; r=""
_router_rc_classify 2 v r
assert_eq "T4: rc=2 verdict=fail" "fail" "$v"

# T5: idempotent — repeat calls with same rc produce same result.
_router_rc_classify 124 v r
_router_rc_classify 124 v r
assert_eq "T5: idempotent rc=124" "error" "$v"

# T6: works under `set -euo pipefail` (no rc-leakage trips set -e).
set +e
_router_rc_classify 124 v r
rc=$?
set -e
assert_eq "T6: helper returns rc=0 under set -e" "0" "$rc"

# ── #1237: rate-limit detection + distinct classification ────────────────────
# The claude CLI can return a rate/session-limit envelope with a MISLEADING
# subtype:"success" while carrying is_error:true + api_error_status:429 and
# process rc=1. Detection MUST recognize this so the operator sees an honest
# "rate-limited — resets X" message instead of an opaque router_rc_nonzero.

# T7: api_error_status:429 (+ subtype:success, rc=1) → detected as rate-limit.
rl_429='{"type":"result","subtype":"success","is_error":true,"api_error_status":429,"duration_ms":503,"result":"You'"'"'ve hit your session limit · resets 10:30am (America/New_York)","output_tokens":0}'
set +e; _router_is_rate_limit "$rl_429"; rc=$?; set -e
assert_eq "T7: api_error_status:429 detected as rate-limit" "0" "$rc"

# T8: is_error:true + 'session limit' result text (no api_error_status) → detected.
rl_text='{"type":"result","subtype":"success","is_error":true,"result":"You have hit your session limit","output_tokens":0}'
set +e; _router_is_rate_limit "$rl_text"; rc=$?; set -e
assert_eq "T8: is_error:true + session-limit text detected as rate-limit" "0" "$rc"

# T8b: api_error_status:529 (overloaded) → detected.
rl_529='{"is_error":true,"api_error_status":529,"result":"Overloaded"}'
set +e; _router_is_rate_limit "$rl_529"; rc=$?; set -e
assert_eq "T8b: api_error_status:529 detected as rate-limit" "0" "$rc"

# T9: a GENUINE non-limit rc=1 error (no 429/limit text) → NOT a rate-limit.
not_rl='{"type":"result","subtype":"error","is_error":true,"result":"Tool execution failed: file not found"}'
set +e; _router_is_rate_limit "$not_rl"; rc=$?; set -e
assert_eq "T9: genuine non-limit error NOT flagged as rate-limit" "1" "$rc"

# T9b: a clean success envelope → NOT a rate-limit.
set +e; _router_is_rate_limit '{"is_error":false,"result":"here is your answer"}'; rc=$?; set -e
assert_eq "T9b: success envelope NOT flagged as rate-limit" "1" "$rc"

# T10: human message surfaces the reset time, not an opaque rc.
msg="$(_router_rate_limit_message "$rl_429")"
assert_contains "T10: message says rate-limited" "$msg" "rate-limited"
assert_contains "T10: message surfaces reset time" "$msg" "resets 10:30am (America/New_York)"

# T11: classify with rate_limited=1 → verdict=fail reason=router_rate_limited
#      (distinct from router_rc_nonzero; verdict=fail keeps it recoverable/
#      non-blocking, NOT the ADR-021 infra `error` class that halts a cycle).
v=""; r=""
_router_rc_classify 1 v r 1
assert_eq "T11: rate_limited flag verdict=fail" "fail" "$v"
assert_eq "T11: rate_limited flag reason=router_rate_limited" "router_rate_limited" "$r"

# T12: classify rc=1 WITHOUT the flag still maps to router_rc_nonzero (no over-broadening).
v=""; r=""
_router_rc_classify 1 v r
assert_eq "T12: plain rc=1 reason still router_rc_nonzero" "router_rc_nonzero" "$r"
v=""; r=""
_router_rc_classify 1 v r 0
assert_eq "T12b: explicit flag=0 reason still router_rc_nonzero" "router_rc_nonzero" "$r"

print_test_results
exit $((FAIL > 0))
