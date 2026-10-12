#!/usr/bin/env bash
# [#1801/SPEC-5] A retried stage and each map member each receive a fresh
# independent timer.
#
# The per-dispatch watchdog must be ARMED at the start of each individual
# dispatch — not once for the whole retry loop or map group. A stale timer
# that was started before the first attempt would expire during a later retry,
# cutting off work that began within its own budget.
#
# These tests verify the structural requirement: the timeout is resolved and
# armed inside the per-dispatch code path (lifecycle.sh / plugin_hook_call),
# not in a shared wrapper above it. They FAIL on pre-change code (where no
# watchdog exists in plugin_hook_call) and PASS after the change.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "[#1801/SPEC-5] retried stage and each map member get a fresh independent timer"

# ─── The watchdog lives inside plugin_hook_call, not in a caller ──────────────
print_test_section "[#1801/SPEC-5] timeout watchdog is inside plugin_hook_call (fresh per dispatch)"

_lc="$REPO_ROOT/core/plugin-registry/lifecycle.sh"
if [[ ! -f "$_lc" ]]; then
    assert_fail "[#1801/SPEC-5] lifecycle.sh exists" "not found: $_lc"
else
    # Extract plugin_hook_call's body.
    _phc_body=""
    _phc_body="$(awk '/^plugin_hook_call\(\) \{/{p=1} p{print} p && /^\}$/{exit}' "$_lc" 2>/dev/null || true)"

    if [[ -z "$_phc_body" ]]; then
        assert_fail "[#1801/SPEC-5] plugin_hook_call is defined in lifecycle.sh" \
            "function body not found"
    else
        assert_pass "[#1801/SPEC-5] plugin_hook_call is defined in lifecycle.sh"

        # The watchdog must be inside the function — a timer started here is
        # fresh for every call, whether that call is a retry or a map member.
        if grep -q 'zbuild_pg_kill\|zbuild_pid_kill' <<< "$_phc_body"; then
            assert_pass "[#1801/SPEC-5] watchdog (zbuild_pg_kill/zbuild_pid_kill) is inside plugin_hook_call → fresh per dispatch"
        else
            assert_fail "[#1801/SPEC-5] watchdog (zbuild_pg_kill/zbuild_pid_kill) is inside plugin_hook_call → fresh per dispatch" \
                "not found inside plugin_hook_call — the watchdog is either absent or in a caller above plugin_hook_call, which would share a timer across retries"
        fi

        # The watchdog must armed with a per-invocation sleep/timeout start,
        # not a pre-computed deadline passed in. Check for a sleep or background
        # timer process inside the function body.
        if grep -qE 'sleep|timeout' <<< "$_phc_body"; then
            assert_pass "[#1801/SPEC-5] plugin_hook_call starts a fresh timer per invocation"
        else
            assert_fail "[#1801/SPEC-5] plugin_hook_call starts a fresh timer per invocation" \
                "no sleep or timeout found inside plugin_hook_call — no per-invocation watchdog"
        fi
    fi
fi

# ─── map.sh dispatches through plugin_hook_call (same watchdog path) ──────────
print_test_section "[#1801/SPEC-5] map strategy dispatches through plugin_hook_call (each member gets a fresh timer)"

_map_sh="$REPO_ROOT/core/pipeline/strategies/map.sh"
if [[ ! -f "$_map_sh" ]]; then
    assert_fail "[#1801/SPEC-5] strategies/map.sh exists" "not found"
else
    if grep -q 'plugin_hook_call' "$_map_sh"; then
        assert_pass "[#1801/SPEC-5] map.sh calls plugin_hook_call (inheriting the per-dispatch watchdog)"
    else
        assert_fail "[#1801/SPEC-5] map.sh calls plugin_hook_call (inheriting the per-dispatch watchdog)" \
            "plugin_hook_call not found in map.sh — map members would bypass the watchdog"
    fi
fi

# ─── runner.sh retry loop calls plugin_hook_call (each retry gets a fresh timer) ─
print_test_section "[#1801/SPEC-5] runner.sh retry loop dispatches through plugin_hook_call"

_runner_sh="$REPO_ROOT/core/pipeline/runner.sh"
if [[ ! -f "$_runner_sh" ]]; then
    assert_fail "[#1801/SPEC-5] runner.sh exists" "not found"
else
    # cycle_dispatch_stage in runner.sh calls plugin_hook_call for the retry path.
    if grep -q 'plugin_hook_call' "$_runner_sh"; then
        assert_pass "[#1801/SPEC-5] runner.sh calls plugin_hook_call for stage dispatch (retries get a fresh timer)"
    else
        assert_fail "[#1801/SPEC-5] runner.sh calls plugin_hook_call for stage dispatch" \
            "plugin_hook_call not found in runner.sh"
    fi
fi

print_test_results
exit $((FAIL > 0))
