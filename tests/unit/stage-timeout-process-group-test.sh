#!/usr/bin/env bash
# [#1801/SPEC-2] Killing a hung run hook stops the entire process group — a
# child ignoring TERM leaves no process alive after TERM + 10 s grace.
#
# The per-dispatch watchdog must:
#   1. Run the hook subshell under set -m (job-control mode) so the subshell
#      becomes a process-group leader.
#   2. Kill via zbuild_pg_kill, which sends TERM to the whole group and then
#      KILL after a grace period.
#   3. The grace period must be at least 10 s (so a hook that traps TERM has
#      enough time to flush, but a child ignoring TERM is killed).
#
# These tests use source-level checks — the behavioral guarantee (no process
# survives) is enforced by SPEC-6b in the integration test. These FAIL on
# pre-change code (where lifecycle.sh has no watchdog at all) and PASS after.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "[#1801/SPEC-2] hung run hook kills entire process group (TERM + 10 s grace + KILL)"

_lc="$REPO_ROOT/core/plugin-registry/lifecycle.sh"

# ─── [#1801/SPEC-2] plugin_hook_call arms the hook under set -m ──────────────
print_test_section "[#1801/SPEC-2] plugin_hook_call runs the hook under set -m (creates a process group)"

_phc_body=""
if [[ -f "$_lc" ]]; then
    _phc_body="$(awk '/^plugin_hook_call\(\) \{/{p=1} p{print} p && /^\}$/{exit}' "$_lc" 2>/dev/null || true)"
fi

if [[ -z "$_phc_body" ]]; then
    assert_fail "[#1801/SPEC-2] plugin_hook_call is defined in lifecycle.sh" "not found"
else
    # set -m inside the function creates a new process group for the backgrounded subshell
    if grep -q 'set -m' <<< "$_phc_body"; then
        assert_pass "[#1801/SPEC-2] plugin_hook_call uses set -m to give the hook its own process group"
    else
        assert_fail "[#1801/SPEC-2] plugin_hook_call uses set -m to give the hook its own process group" \
            "'set -m' not found in plugin_hook_call — the hook's group cannot be signalled"
    fi
fi

# ─── [#1801/SPEC-2] the kill goes through zbuild_pg_kill (group-scope) ────────
print_test_section "[#1801/SPEC-2] the timeout kill uses zbuild_pg_kill (group scope, not single-PID)"

if [[ -n "$_phc_body" ]]; then
    if grep -q 'zbuild_pg_kill' <<< "$_phc_body"; then
        assert_pass "[#1801/SPEC-2] plugin_hook_call uses zbuild_pg_kill (sends signal to whole group)"
    else
        assert_fail "[#1801/SPEC-2] plugin_hook_call uses zbuild_pg_kill (sends signal to whole group)" \
            "zbuild_pg_kill not found — a single-PID kill cannot reach descendants that ignore TERM"
    fi
fi

# ─── [#1801/SPEC-2] zbuild_pg_kill uses TERM + grace + KILL ──────────────────
print_test_section "[#1801/SPEC-2] zbuild_pg_kill uses TERM then KILL after grace (proc-group.sh)"

_pg="$REPO_ROOT/scripts/lib/proc-group.sh"
if [[ ! -f "$_pg" ]]; then
    assert_fail "[#1801/SPEC-2] scripts/lib/proc-group.sh exists" "not found"
else
    # zbuild_pg_kill must delegate to _zbuild_pg_term_then_kill, which does
    # TERM → poll → KILL.
    if grep -q '_zbuild_pg_term_then_kill' "$_pg"; then
        assert_pass "[#1801/SPEC-2] zbuild_pg_kill uses TERM+grace+KILL sequence (_zbuild_pg_term_then_kill)"
    else
        assert_fail "[#1801/SPEC-2] zbuild_pg_kill uses TERM+grace+KILL sequence (_zbuild_pg_term_then_kill)" \
            "_zbuild_pg_term_then_kill not found in proc-group.sh"
    fi
fi

# ─── [#1801/SPEC-2] the grace is at least 10 s ───────────────────────────────
print_test_section "[#1801/SPEC-2] the watchdog grace period is at least 10 s"

# The design specifies TERM + 10 s grace + KILL. Verify that the watchdog in
# lifecycle.sh passes a grace of >= 10 to zbuild_pg_kill or that the default
# grace in _zbuild_pg_grace is sufficiently large.
# Check that the value 10 (or larger) appears in the context of zbuild_pg_kill
# invocations in lifecycle.sh.
if [[ -n "$_phc_body" ]]; then
    # Look for zbuild_pg_kill called with a numeric grace >= 10.
    # Accept the pattern: zbuild_pg_kill "$var" 10 or zbuild_pg_kill "$pid" "$grace"
    # where the literal in the source is >= 10.
    _grace_ok=0
    if grep -qE 'zbuild_pg_kill.*[[:space:]][0-9]+' <<< "$_phc_body"; then
        # Extract all numeric values following zbuild_pg_kill
        while IFS= read -r _val; do
            [[ "$_val" =~ ^[0-9]+$ ]] && [[ "$_val" -ge 10 ]] && { _grace_ok=1; break; }
        done < <(grep -oE 'zbuild_pg_kill[^)]*' <<< "$_phc_body" | grep -oE '[0-9]+' || true)
    fi
    # Also accept if the grace is passed via a variable (the design uses a configurable grace)
    if grep -qE 'zbuild_pg_kill[^)]*\$\{?[A-Za-z_]' <<< "$_phc_body"; then
        _grace_ok=1
    fi

    if [[ "$_grace_ok" -eq 1 ]]; then
        assert_pass "[#1801/SPEC-2] watchdog grace period is >= 10 s (or variable-derived)"
    else
        assert_fail "[#1801/SPEC-2] watchdog grace period is >= 10 s (or variable-derived)" \
            "no zbuild_pg_kill call with grace >= 10 found in plugin_hook_call"
    fi
fi

# ─── [#1801/SPEC-2] plugin_hook_call has a TERM trap exiting 143 ──────────────
# SPEC-2: "plugin_hook_call's run-hook branch has a TERM trap (inserted between
# lifecycle.sh lines 516 and 521) that kills the inner hook group and watchdog and
# exits with status 143 when plugin_hook_call is externally TERMed, so the hook's
# children are not orphaned"
print_test_section "[#1801/SPEC-2] plugin_hook_call run-hook branch has a TERM trap exiting 143"

if [[ -n "$_phc_body" ]]; then
    # The trap must exist and handle SIGTERM — old code had no trap at all.
    if grep -q 'trap.*TERM' <<< "$_phc_body"; then
        assert_pass "[#1801/SPEC-2] plugin_hook_call run-hook branch has a TERM trap"
    else
        assert_fail "[#1801/SPEC-2] plugin_hook_call run-hook branch has a TERM trap" \
            "no 'trap ... TERM' found in plugin_hook_call — hook children not protected when externally TERMed"
    fi

    # The TERM trap must exit with status 143 (128 + SIGTERM=15) so the caller
    # can distinguish "externally killed" from a normal non-zero hook exit.
    if grep -q 'exit 143' <<< "$_phc_body"; then
        assert_pass "[#1801/SPEC-2] TERM trap exits with status 143"
    else
        assert_fail "[#1801/SPEC-2] TERM trap exits with status 143" \
            "'exit 143' not found in plugin_hook_call — the TERM trap must exit 143 (128+SIGTERM)"
    fi
fi

print_test_results
exit $((FAIL > 0))
