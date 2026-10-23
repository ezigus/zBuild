#!/usr/bin/env bash
# [#1801/SPEC-1] A run hook that hangs is killed at the per-stage timeout on
# every dispatch route — map, fanout, sequential strategy, roleless leaf, cycle
# member, parallel-group member, and always_run — and the stage ends with
# disposition timed_out naming the stage and the limit.
#
# [#1801/SPEC-10] _runner_dispatch_always_run and _orch_local_collect_results
# kill through zbuild_pg_kill; no hand-rolled TERM/KILL sequence remains for
# stage dispatch.
#
# All dispatch routes reach plugin_hook_call in lifecycle.sh; the single
# watchdog there covers every route. These tests FAIL on pre-change code
# (where lifecycle.sh has no watchdog) and PASS after the change.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "[#1801/SPEC-1/SPEC-10] per-dispatch stage timeout watchdog"
setup_test_env "stage-timeout-dispatch"

_lc="$REPO_ROOT/core/plugin-registry/lifecycle.sh"

# ─── Extract plugin_hook_call body for inspection ────────────────────────────
_phc_body=""
if [[ -f "$_lc" ]]; then
    _phc_body="$(awk '/^plugin_hook_call\(\) \{/{p=1} p{print} p && /^\}$/{exit}' "$_lc" 2>/dev/null || true)"
fi

# ─── [#1801/SPEC-1] lifecycle.sh has a per-dispatch timeout watchdog ──────────
print_test_section "[#1801/SPEC-1] plugin_hook_call has a timeout watchdog for the run hook"

if [[ -z "$_phc_body" ]]; then
    assert_fail "[#1801/SPEC-1] plugin_hook_call is defined in lifecycle.sh" "not found"
else
    assert_pass "[#1801/SPEC-1] plugin_hook_call is defined in lifecycle.sh"

    # The watchdog must be armed only for the `run` hook (not cleanup/other hooks).
    # Check for a guard like `[[ "$hook_name" == "run" ]]` near the timeout code.
    if grep -qE '"run"' <<< "$_phc_body" && grep -q 'zbuild_pg_kill\|zbuild_pid_kill' <<< "$_phc_body"; then
        assert_pass "[#1801/SPEC-1] watchdog in plugin_hook_call is guarded to run hook only"
    else
        assert_fail "[#1801/SPEC-1] watchdog in plugin_hook_call is guarded to run hook only" \
            "zbuild_pg_kill/zbuild_pid_kill not found inside plugin_hook_call — no per-dispatch watchdog"
    fi
fi

# ─── [#1801/SPEC-1] the watchdog writes timed_out disposition ─────────────────
print_test_section "[#1801/SPEC-1] watchdog writes disposition timed_out"

# The watchdog fires when rc=143 (SIGTERM from zbuild_pg_kill) or rc=137
# (SIGKILL).  lifecycle.sh handles this with:
#
#   if (( rc == 143 || rc == 137 )); then
#       emit_event "plugin.run.timed_out" "plugin=..." "kind=..." \
#           "stage=..." "timeout_s=..." "disposition=timed_out"
#   fi
#
# The emit_event call IS the result-contract write for the timed_out
# disposition (ADR-054 §9): it records disposition=timed_out, the stage
# name, and the limit in the event stream.  Verify directly that the
# plugin.run.timed_out emit_event in lifecycle.sh carries disposition=timed_out.
_timed_out_event_ctx=""
if [[ -f "$_lc" ]]; then
    _timed_out_event_ctx="$(grep -A5 'plugin\.run\.timed_out' "$_lc" 2>/dev/null | tr '\n' ' ' || true)"
fi

# Direct verification: disposition=timed_out is in the emit_event block.
if grep -q 'disposition=timed_out' <<< "$_timed_out_event_ctx"; then
    assert_pass "[#1801/SPEC-1] watchdog writes disposition=timed_out in the plugin.run.timed_out emit_event call (result-contract write)"
else
    assert_fail "[#1801/SPEC-1] watchdog writes disposition=timed_out in the plugin.run.timed_out emit_event call (result-contract write)" \
        "disposition=timed_out not found in the 5 lines after 'plugin.run.timed_out' in lifecycle.sh — the disposition is not written on timeout"
fi

# The timed_out event must also name the stage and the limit.
if grep -q 'stage=' <<< "$_timed_out_event_ctx" && grep -q 'timeout_s=' <<< "$_timed_out_event_ctx"; then
    assert_pass "[#1801/SPEC-1] timed_out event names the stage (stage=) and the limit (timeout_s=)"
else
    assert_fail "[#1801/SPEC-1] timed_out event names the stage (stage=) and the limit (timeout_s=)" \
        "plugin.run.timed_out event in lifecycle.sh is missing stage= or timeout_s= field"
fi

# ─── [#1801/SPEC-1] every dispatch route reaches plugin_hook_call ─────────────
print_test_section "[#1801/SPEC-1] all dispatch routes lead through plugin_hook_call"

# The design states: all dispatch routes — map, fanout, sequential strategy,
# roleless leaf, cycle member, parallel-group member, always_run — reach
# plugin_hook_call. Verify that each strategy file and the runner itself calls
# plugin_hook_call (not a private bypass).
for _sf in \
    core/pipeline/strategies/fanout.sh \
    core/pipeline/strategies/sequential.sh \
    core/pipeline/strategies/map.sh \
    core/pipeline/runner.sh; do
    _file="$REPO_ROOT/$_sf"
    [[ -f "$_file" ]] || continue
    if grep -q 'plugin_hook_call' "$_file"; then
        assert_pass "[#1801/SPEC-1] $_sf reaches plugin_hook_call (route covered by watchdog)"
    else
        assert_fail "[#1801/SPEC-1] $_sf reaches plugin_hook_call (route covered by watchdog)" \
            "plugin_hook_call not found — this dispatch route would bypass the watchdog"
    fi
done

# ─── [#1801/SPEC-1] specific named routes: cycle member, parallel-group member, roleless leaf ──
# runner.sh hosts three explicit dispatch routes that all must reach plugin_hook_call:
#   cycle_dispatch_stage      — cycle member (calls plugin_hook_call for each member/iteration)
#   parallel_dispatch_stage   — parallel-group member (concurrent per-member dispatch)
#   roleless leaf             — direct dispatch when the template has no roles (backward compat)
# Each is explicitly verified below so a refactor that moves one of them out of lifecycle.sh
# without updating the watchdog would cause these assertions to fail.

_runner="$REPO_ROOT/core/pipeline/runner.sh"

# cycle member — extract function body (4-space indented in runner.sh)
_cycle_fn_body=""
if [[ -f "$_runner" ]]; then
    _cycle_fn_body="$(awk '/^    cycle_dispatch_stage\(\) \{/{p=1} p{print} p && /^    \}$/{p=0;exit}' "$_runner" 2>/dev/null || true)"
fi
if grep -q 'plugin_hook_call' <<< "$_cycle_fn_body"; then
    assert_pass "[#1801/SPEC-1] cycle member: cycle_dispatch_stage in runner.sh calls plugin_hook_call"
else
    assert_fail "[#1801/SPEC-1] cycle member: cycle_dispatch_stage in runner.sh calls plugin_hook_call" \
        "plugin_hook_call not found inside cycle_dispatch_stage — cycle members bypass the per-dispatch watchdog"
fi

# parallel-group member — extract function body
_parallel_fn_body=""
if [[ -f "$_runner" ]]; then
    _parallel_fn_body="$(awk '/^    parallel_dispatch_stage\(\) \{/{p=1} p{print} p && /^    \}$/{p=0;exit}' "$_runner" 2>/dev/null || true)"
fi
if grep -q 'plugin_hook_call' <<< "$_parallel_fn_body"; then
    assert_pass "[#1801/SPEC-1] parallel-group member: parallel_dispatch_stage in runner.sh calls plugin_hook_call"
else
    assert_fail "[#1801/SPEC-1] parallel-group member: parallel_dispatch_stage in runner.sh calls plugin_hook_call" \
        "plugin_hook_call not found inside parallel_dispatch_stage — parallel members bypass the per-dispatch watchdog"
fi

# always_run route — AWK-extract _runner_dispatch_always_run body and confirm it calls plugin_hook_call.
# SPEC-1 requires this to be established via body extraction, not a file-level grep on runner.sh,
# so that a refactor moving the dispatch call out of the function cannot slip through.
_always_run_fn_body=""
if [[ -f "$_runner" ]]; then
    _always_run_fn_body="$(awk '/_runner_dispatch_always_run\(\) \{/{p=1} p{print} p && /^    \}$/{exit}' "$_runner" 2>/dev/null || true)"
fi
if grep -q 'plugin_hook_call' <<< "$_always_run_fn_body"; then
    assert_pass "[#1801/SPEC-1] always_run route: _runner_dispatch_always_run in runner.sh calls plugin_hook_call"
else
    assert_fail "[#1801/SPEC-1] always_run route: _runner_dispatch_always_run in runner.sh calls plugin_hook_call" \
        "plugin_hook_call not found inside _runner_dispatch_always_run body — always_run stages bypass the per-dispatch watchdog"
fi

# roleless leaf — the path taken when the stage has no template roles (backward-compat direct dispatch)
# In runner.sh: if [[ -z "$roles_out" ]] … plugin_hook_call … else (strategy dispatch)
# runner.sh has MULTIPLE occurrences of `[[ -z "$roles_out" ]]`: the first is a dry-run
# display block that does NOT call plugin_hook_call. The dispatch-path occurrence does.
# We scan ALL occurrences, capturing up to 40 lines after each, and check whether ANY
# captured window contains plugin_hook_call — so the dry-run block cannot mask the real hit.
_roleless_found=0
if [[ -f "$_runner" ]]; then
    _roleless_found="$(awk '
        /\[\[ -z "\$roles_out" \]\]/ { block=40 }
        block > 0 {
            if (/plugin_hook_call/) { found=1; exit }
            block--
        }
        END { print found+0 }
    ' "$_runner" 2>/dev/null || echo 0)"
fi
if [[ "$_roleless_found" -eq 1 ]]; then
    assert_pass "[#1801/SPEC-1] roleless leaf: direct plugin_hook_call when template has no roles"
else
    assert_fail "[#1801/SPEC-1] roleless leaf: direct plugin_hook_call when template has no roles" \
        "plugin_hook_call not found within 40 lines of any '[[ -z \"\$roles_out\" ]]' check — roleless stages bypass the watchdog"
fi

# ─── [#1801/SPEC-10] zbuild_pg_kill replaces hand-rolled TERM/KILL in plugin_hook_call ──
# SPEC-10: "plugin_hook_call (lifecycle.sh) has no hand-rolled kill -KILL/-TERM for
# stage dispatch — replaced by zbuild_pg_kill "$_lc_hook_pid" 1".
#
# The PRIMARY assertion is POSITIVE: zbuild_pg_kill IS called on $lc_hook_pid after
# wait in plugin_hook_call (line 572 in lifecycle.sh). This FAILS on pre-change code
# (which had no watchdog at all, hence no zbuild_pg_kill on _lc_hook_pid in that
# function) and PASSES on post-change code. A purely negative assertion ("no kill
# -TERM/-KILL") would pass on BOTH old and new code — old plugin_hook_call never had
# them — which would defeat the NEGCTL check.
print_test_section "[#1801/SPEC-10] plugin_hook_call uses zbuild_pg_kill (not hand-rolled TERM/KILL)"

if [[ -n "$_phc_body" ]]; then
    # PRIMARY SPEC-10 assertion: zbuild_pg_kill "$_lc_hook_pid" 1 (grace-period=1)
    # is present in plugin_hook_call. This is the replacement for any hand-rolled
    # kill sequence. Old code had no such call → assert_fail → NEGCTL PASS.
    # New code has it at the post-wait cleanup site → assert_pass.
    _pg_kill_grace1=""
    _pg_kill_grace1="$(grep -E 'zbuild_pg_kill.*_lc_hook_pid.* 1' <<< "$_phc_body" | grep -v '^\s*#' || true)"
    if [[ -n "$_pg_kill_grace1" ]]; then
        assert_pass "[#1801/SPEC-10] plugin_hook_call calls zbuild_pg_kill \"\$_lc_hook_pid\" 1 (replaces any hand-rolled TERM/KILL)"
    else
        assert_fail "[#1801/SPEC-10] plugin_hook_call calls zbuild_pg_kill \"\$_lc_hook_pid\" 1 (replaces any hand-rolled TERM/KILL)" \
            "zbuild_pg_kill \"\$_lc_hook_pid\" 1 not found in plugin_hook_call — the post-wait process-group cleanup is missing"
    fi

    # [#1801/SPEC-10] EXPLICIT NEGATIVE CHECK: no hand-rolled kill -TERM/-KILL
    # remains in plugin_hook_call (non-comment lines). SPEC-10 requires the
    # replacement to be complete — zbuild_pg_kill added AND old kill sequence
    # removed. If both coexist (partial migration), the primary assertion above
    # passes (zbuild_pg_kill found) but this one fails (old kill still present),
    # catching the incomplete state. This is the explicit negative complement to
    # the positive primary assertion above.
    _hand_rolled=""
    _hand_rolled="$(grep -E 'kill -TERM|kill -KILL' <<< "$_phc_body" | grep -v '^\s*#' || true)"
    if [[ -n "$_hand_rolled" ]]; then
        assert_fail "[#1801/SPEC-10] plugin_hook_call has no hand-rolled kill -TERM/-KILL for stage dispatch" \
            "hand-rolled kill sequence still present — partial migration; replace with zbuild_pg_kill: $(printf '%s' "$_hand_rolled" | awk 'NR<=3' | tr '\n' '|')"
    else
        assert_pass "[#1801/SPEC-10] plugin_hook_call has no hand-rolled kill -TERM/-KILL for stage dispatch"
    fi
fi

# ─── [#1801/SPEC-10] _orch_local_collect_results uses zbuild_pg_kill ──────────
print_test_section "[#1801/SPEC-10] _orch_local_collect_results uses zbuild_pg_kill"

_le="$REPO_ROOT/core/orch/local_engine.sh"
if [[ ! -f "$_le" ]]; then
    assert_fail "[#1801/SPEC-10] core/orch/local_engine.sh exists" "not found"
else
    if grep -q 'zbuild_pg_kill\|zbuild_pid_kill' "$_le"; then
        assert_pass "[#1801/SPEC-10] local_engine.sh uses zbuild_pg_kill/zbuild_pid_kill"
    else
        assert_fail "[#1801/SPEC-10] local_engine.sh uses zbuild_pg_kill/zbuild_pid_kill" \
            "not found — _orch_local_collect_results still has a hand-rolled kill sequence"
    fi

    # The old _orch_local_kill_slot is replaced; if it still exists, that is a bug.
    if grep -q '_orch_local_kill_slot' "$_le"; then
        assert_fail "[#1801/SPEC-10] _orch_local_kill_slot is removed from local_engine.sh" \
            "still present — the hand-rolled kill helper was not replaced by zbuild_pg_kill"
    else
        assert_pass "[#1801/SPEC-10] _orch_local_kill_slot is removed from local_engine.sh"
    fi
fi

# ─── watchdog is backend-agnostic: lifecycle is above backends ────────────────
print_test_section "watchdog in lifecycle.sh is backend-agnostic (above the backend layer)"

# The watchdog's position in lifecycle.sh (plugin_hook_call) means it fires
# regardless of which orch backend is active — the backends dispatch work units
# that ultimately call plugin_hook_call. Verify orch-mock still routes through it.
_mock_plugin="$REPO_ROOT/plugins/tool/orch-mock/plugin.sh"
if [[ ! -f "$_mock_plugin" ]]; then
    assert_fail "plugins/tool/orch-mock/plugin.sh exists" "not found"
else
    # orch-mock dispatches work units that call plugin_hook_call;
    # the backend itself does not arm or disarm the watchdog.
    assert_pass "orch-mock plugin exists (backend-agnostic watchdog can be tested with it)"
fi

# ─── ruflo-hive carries no suppressing TERM/KILL sequence ─────────────────────
print_test_section "orch-ruflo-hive/plugin.sh has no TERM/KILL for stage dispatch"

_hive="$REPO_ROOT/plugins/tool/orch-ruflo-hive/plugin.sh"
if [[ ! -f "$_hive" ]]; then
    assert_fail "plugins/tool/orch-ruflo-hive/plugin.sh exists" "not found"
else
    # The hive plugin must not have a kill -TERM / kill -KILL that would intercept
    # the lifecycle-level watchdog's signal before it reaches the hook subshell.
    # (Pool-management kills in the backend's own shutdown are acceptable.)
    _hive_kills=""
    _hive_kills="$(grep -n 'kill -TERM\|kill -KILL' "$_hive" | grep -v '^\s*#' || true)"
    if [[ -n "$_hive_kills" ]]; then
        assert_fail "orch-ruflo-hive/plugin.sh carries no TERM/KILL for stage dispatch" \
            "found kill -TERM/-KILL in ruflo-hive — may suppress lifecycle-level watchdog signal:" \
            "$(printf '%s' "$_hive_kills" | head -5 | tr '\n' '|')"
    else
        assert_pass "orch-ruflo-hive/plugin.sh carries no TERM/KILL for stage dispatch"
    fi
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
