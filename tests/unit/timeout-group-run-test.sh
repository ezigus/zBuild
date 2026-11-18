#!/usr/bin/env bash
# tests/unit/timeout-group-run-test.sh — a command run under a timeout leaves
# nothing behind, whatever the `timeout` binary does (#2563, ADR-062).
#
# Why: Ubuntu 26.04's Rust coreutils `timeout -k` KILLs only its direct child.
# The test runner, the acceptance check and build's summary run test files that
# way and relied on GNU `timeout` signalling the whole group; a test whose child
# ignores TERM outlived its timeout.
#
# G1 [change] zb_timeout_run under a child-only `timeout`: a grandchild that
#             ignores TERM is gone when it returns
# G2 [guard]  it returns the command's own status, and a timed-out run is
#             non-zero
# G3 [change] no engine site runs a command under the timeout prefix itself —
#             each goes through zb_timeout_run (the model call and the gh call
#             are listed: they kill their own groups, or start none)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "a command run under a timeout leaves nothing behind (#2563)"
setup_test_env "timeout-group-run"

_STUB_BIN="$TEST_TEMP_DIR/stub-timeout-bin"; mkdir -p "$_STUB_BIN"
ln -sf "$REPO_ROOT/tests/lib/timeout-child-only-stub.sh" "$_STUB_BIN/timeout"
ln -sf "$REPO_ROOT/tests/lib/timeout-child-only-stub.sh" "$_STUB_BIN/gtimeout"
export PATH="$_STUB_BIN:$PATH"
# shellcheck source=../../scripts/lib/timeout-cmd.sh
source "$REPO_ROOT/scripts/lib/timeout-cmd.sh"

print_test_section "G1/G2"
GC="$TEST_TEMP_DIR/gc.pid"
_acceptance_timeout_prefix 1 1
rc=0
zb_timeout_run _ACCEPTANCE_TOUT bash -c "trap '' TERM; bash -c 'trap \"\" TERM; printf \"%s\\n\" \"\$\$\" > \"$GC\"; exec sleep 600' & wait" </dev/null >/dev/null 2>&1 || rc=$?
_gc="$(cat "$GC" 2>/dev/null || true)"
assert_eq "[G1] the grandchild wrote its pid" "yes" "$([[ "$_gc" =~ ^[0-9]+$ ]] && echo yes || echo no)"
if [[ "$_gc" =~ ^[0-9]+$ ]] && kill -0 "$_gc" 2>/dev/null; then
    assert_fail "[G1] a grandchild that ignores TERM is gone when it returns" "PID $_gc is alive"
    kill -KILL "$_gc" 2>/dev/null || true
else
    assert_pass "[G1] a grandchild that ignores TERM is gone when it returns"
fi
assert_eq "[G2] a timed-out run is non-zero" "yes" "$([[ $rc -ne 0 ]] && echo yes || echo no)"
_acceptance_timeout_prefix 30 1
rc=0; zb_timeout_run _ACCEPTANCE_TOUT bash -c 'exit 7' || rc=$?
assert_eq "[G2] the command's own status comes back" "7" "$rc"

print_test_section "G3: one way to run under the timeout"
# A command position that expands the prefix array: "${X[@]}" bash|… or
# ${X[@]+"${X[@]}"} bash … — anything but building the array.
_hits="$(cd "$REPO_ROOT" && git grep -nE '("\$\{_[a-z_]*tout\[@\]\}"|\$\{_ACCEPTANCE_TOUT\[@\]\+"\$\{_ACCEPTANCE_TOUT\[@\]\}"\}) +(bash|exec|"\$)' \
    -- scripts core plugins ':!scripts/lib/timeout-cmd.sh' ':!core/router/route.sh' ':!scripts/lib/gh-automation.sh' 2>/dev/null || true)"
assert_eq "[G3] no site runs a command under the timeout prefix itself" "" "$_hits"
_arr="$(cd "$REPO_ROOT" && git grep -nE 'runner=\("\$\{_ACCEPTANCE_TOUT\[@\]\}"' -- scripts core plugins 2>/dev/null || true)"
assert_eq "[G3] ...nor builds it into a runner it calls" "" "$_arr"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
