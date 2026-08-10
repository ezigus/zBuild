#!/usr/bin/env bash
# Unit (#1759): After a nested orchestrator (cycle, parallel) calls
# `trap - INT TERM` to clear its own handler layer, _runner_rearm_traps()
# must restore _runner_signal_trap as the active INT/TERM handler.
#
# SPEC-1 (change): _runner_rearm_traps is defined as a top-level function in
#   runner.sh. At merge-base the helper does not exist at top level, so
#   `declare -f _runner_rearm_traps` returns non-zero and this test fails.
# SPEC-2 (change): after re-arm, the installed INT handler invokes
#   _zbuild_arm_abort_sentinel (the sentinel write that is the first action of
#   _runner_signal_trap). At merge-base _runner_rearm_traps doesn't exist so
#   the handler is at default disposition and the sentinel is never written.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "runner _runner_rearm_traps after nested trap clear (#1759)"
setup_test_env "runner-signal-rearm"

# Source runner.sh so _runner_rearm_traps is available if it is a top-level
# function (which this change makes it). At merge-base the function is absent.
# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/runner.sh"

# ─── SPEC-1: _runner_rearm_traps exists as a top-level function ──────────────

print_test_section "SPEC-1: _runner_rearm_traps is defined in runner.sh (top-level)"

assert_eq "[SPEC-1] _runner_rearm_traps is defined as a top-level function in runner.sh" \
    "ok" \
    "$(declare -f _runner_rearm_traps >/dev/null 2>&1 && echo ok || echo missing)"

# ─── SPEC-2: after re-arm, the installed handler calls _zbuild_arm_abort_sentinel

print_test_section "SPEC-2: handler installed by re-arm calls _zbuild_arm_abort_sentinel"

# HERMETICITY (#1713 family): this must NOT assert the OS-level trap
# disposition. `scripts/run-tests.sh` executes test files as BACKGROUND jobs,
# and a background job in a non-interactive shell inherits SIGINT/SIGTERM as
# IGNORED — bash then refuses to install a handler for them, so `trap ... INT`
# is a silent no-op and `trap -p INT` reports `trap -- '' SIGINT`. Measured:
#   foreground child -> trap -- 'f INT' SIGINT
#   background child -> trap -- ''      SIGINT
# The first cut asserted the read-back and so passed standalone and failed in
# the suite. Production runner.sh runs in the foreground, where the install
# works; the harness cannot reproduce that, so assert what the function DOES —
# shadow the `trap` builtin with a function (functions outrank builtins) and
# record the calls. Deterministic under any signal disposition.

spec2_calls="$(
    trap() { printf '%s\n' "trap|$*"; }
    _runner_rearm_traps
)"

if grep -q "^trap|_runner_signal_trap INT INT$" <<< "$spec2_calls"; then
    assert_pass "[SPEC-2] re-arm installs _runner_signal_trap on INT"
else
    assert_fail "[SPEC-2] re-arm installs _runner_signal_trap on INT" \
        "recorded calls: ${spec2_calls:-<none>}"
fi

if grep -q "^trap|_runner_signal_trap TERM TERM$" <<< "$spec2_calls"; then
    assert_pass "[SPEC-3] re-arm installs _runner_signal_trap on TERM"
else
    assert_fail "[SPEC-3] re-arm installs _runner_signal_trap on TERM" \
        "recorded calls: ${spec2_calls:-<none>}"
fi

# SPEC-4 (parity, not a source tautology): the handler _runner_rearm_traps
# installs must be byte-identical to the one main() installs at startup. If the
# two sites drift, re-arming would silently restore a DIFFERENT handler than the
# one the nested layer cleared — which is the class of bug #1759 exists to close.
# Both sides are derived from runner.sh at run time; nothing is hardcoded, so
# renaming the handler keeps this test honest instead of quietly passing.
#
# NB: the handler itself (_runner_signal_trap) is still nested inside main(), so
# it cannot be introspected after sourcing. Only _runner_rearm_traps was promoted
# to top level. That is why this asserts install-site parity rather than calling
# the handler and observing the ADR-025 sentinel write.
_runner_sh="$REPO_ROOT/core/pipeline/runner.sh"
# The startup installs: the FIRST pair of `trap '...' INT|TERM` lines in the file.
_startup_int="$(grep -m1 -oE "trap '[^']+' INT" "$_runner_sh" || true)"
_startup_term="$(grep -m1 -oE "trap '[^']+' TERM" "$_runner_sh" || true)"
# What the promoted helper installs, taken from the live function body.
_rearm_body="$(declare -f _runner_rearm_traps 2>/dev/null || true)"
_rearm_int="$(grep -m1 -oE "trap '[^']+' INT" <<< "$_rearm_body" || true)"
_rearm_term="$(grep -m1 -oE "trap '[^']+' TERM" <<< "$_rearm_body" || true)"

assert_eq "[SPEC-4] re-arm INT handler matches the startup install" \
    "${_startup_int:-<startup-not-found>}" "${_rearm_int:-<rearm-not-found>}"
assert_eq "[SPEC-5] re-arm TERM handler matches the startup install" \
    "${_startup_term:-<startup-not-found>}" "${_rearm_term:-<rearm-not-found>}"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
