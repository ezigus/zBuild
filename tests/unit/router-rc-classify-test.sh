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

print_test_results
exit $((FAIL > 0))
