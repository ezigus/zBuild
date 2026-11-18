#!/usr/bin/env bash
# plugins/tool/test/lib/suite.sh — starting the suite and the processes it leaves (moved from plugin.sh, #2565:
# plugin.sh under 500 lines).
#
# Sourced by plugin.sh after its bootstrap. Sourced library: no set -euo.

[[ -n "${_ZBUILD_TEST_SUITE_LOADED:-}" ]] && return 0
_ZBUILD_TEST_SUITE_LOADED=1

# ─── _test_spawn_suite ───────────────────────────────────────────────────────
# Runs one suite command in the staging dir and prints its combined output;
# returns the command's rc. Called inside a $( ) by _test_run_inner — once for
# the (targeted or full) command, and once more for the full suite when a
# targeted subset passed (#2144). The body is the fresh-user-shell spawn
# unchanged from before the split.
# Usage: _test_spawn_suite <tmp> <cmd> <timing_log> <results_json> <pid_file> <pgid_file>
_test_spawn_suite() {
    local tmp="$1" cmd="$2" _zbt_timing_log="$3" _zbt_results_json="$4"
    local _pid_file="$5" _pgid_file="$6"
    # ADR-024 / #671 (Wave 13-B): the test subprocess is a fresh-user-shell
    # class spawn — it must look exactly like the user running `npm test`
    # from their own login shell with no zBuild runner in the process tree.
    # _zbuild_make_fresh_shell scrubs the entire ZBUILD_* namespace and
    # closes fd 3 (the ADR-015 stage-io channel). This supersedes Wave 11A
    # (#645)'s narrow `unset ZBUILD_STAGE_IO_FD && exec 3>&-` — the wider
    # scrub also covers ZBUILD_RUN_ID + ZBUILD_EVENTS_JSONL, which Wave 13
    # dogfood discovered were triggering router C6 precondition refusals
    # when the test subprocess recursed back into the router.
    (
        # Copilot P1 on #673: guard cd BEFORE the helper, because the
        # helper disables errexit (fresh-user-shell posture). A failed
        # cd here would otherwise silently run the test command against
        # the runner's cwd instead of the rsync'd staging dir.
        cd "$tmp" || exit 99
        _zbuild_make_fresh_shell
        # #1058 Phase A: re-supply the timing-file path AFTER the fresh-shell
        # scrub cleared the ZBUILD_* namespace, so run-tests.sh (which honors
        # ZBUILD_TEST_TIMING_FILE) writes its instrumentation. Export (not a
        # command prefix) so it reaches the suite regardless of how
        # actual_test_cmd is shaped (npm test → run-tests.sh, or a direct call).
        export ZBUILD_TEST_TIMING_FILE="$_zbt_timing_log"
        # #2170: `--tier all` runs its tiers concurrently (#997), each at the
        # full worker count (#2158) — on the 4-CPU runner that is ~12 heavy
        # processes for 4 cores next to the engine itself: 25-minute suites,
        # seconds-long unit files taking 200–470 s, timing tests failing.
        # Ordinary CI runs one tier per machine; ask run-tests.sh for the same.
        export ZBUILD_TIER_CONCURRENCY=0
        # #1127: fence the whole zBuild state tree for the suite. The suite is a
        # fresh-user shell (scrub above clears ZBUILD_* / preserves HOME per
        # ADR-024), so any nested `runner.sh` it spawns would otherwise re-root
        # to the REAL $HOME/.zbuild/state and clobber the parent run's shared
        # artifacts (latest symlink + --no-resume global event clear). Rooting
        # the nested tree under the RETURN-trap-cleaned $tmp fences state,
        # events, runs/<id>/, latest and the global-clear inside a throwaway
        # dir. A recursively-nested test stage re-scrubs + re-exports its own.
        export ZBUILD_STATE_ROOT="$tmp/.zbuild-nested-state"
        export ZBUILD_COST_LEDGER="$tmp/.zbuild-nested-state/cost-ledger.jsonl"
        export ZBUILD_CACHE_DIR="$tmp/.zbuild-nested-state/cache"
        # #2367: the fence is not the repository's work — kept out of `git
        # status`, so a nested run's dirty-tree check does not refuse it.
        [[ -d "$tmp/.git/info" ]] && printf '/.zbuild-nested-state/\n' >> "$tmp/.git/info/exclude"
        # #1208: re-supply the repo-declarable count-contract vars AFTER the
        # fresh-shell scrub so a repo's test wrapper (e.g. an xcodebuild/
        # xcresulttool shim) can honor them — write its {passed,failed,total}
        # JSON to $ZBUILD_TEST_RESULTS_JSON (use an absolute path so it resolves
        # both inside the rsync'd staging dir and at parse time). _COUNT_CMD is
        # evaluated later at parse time (outside this fresh shell) and needs no
        # re-export here. Absent when the repo declares no contract.
        [[ -n "$_zbt_results_json" ]] && export ZBUILD_TEST_RESULTS_JSON="$_zbt_results_json"
        # #1829 (ADR-054 §7): record a PID the RETURN trap can kill on an
        # interrupted return path. This is the setup window only — once the
        # suite is spawned the record moves to the child, below.
        printf '%s' "$BASHPID" > "$_pid_file" 2>/dev/null || true
        # #1748: `set -m` makes a backgrounded job a process-group leader, so
        # the suite and every worker it forks share one group teardown can
        # signal — instead of a single PID whose children outlive it.
        #
        # Job control rather than the router's `setsid` prefix, for two reasons.
        # setsid is absent on stock macOS (util-linux is keg-only), which is the
        # platform the orphaned trees in #1748 were observed on; and setsid must
        # exec, so the command would have to become `bash -c "$cmd"` and lose
        # the eval's access to functions the caller defined — which is exactly
        # what test-plugin-stage-io-banner-visible-test.sh (#645) asserts. The
        # router keeps the prefix because it execs a binary and has no eval to
        # preserve; both callers still share one resolve and one kill.
        #
        # Backgrounded rather than foreground because the PGID must be recorded
        # while the child is alive — the RETURN trap fires on paths that never
        # reach the `wait`. fds are inherited, so output still streams into the
        # enclosing $( ) exactly as the plain eval did.
        set -m
        # #2108: `set -m` removed the implicit </dev/null bash gives `&` jobs.
        eval "$cmd" </dev/null 2>&1 &
        _zbt_pg_child=$!
        # Re-point .pid at the suite itself. `set -m` put it in its own group,
        # so a TERM to this subshell — its parent — does NOT cascade; the PID
        # fallback would kill the shell layer and leave the workers running,
        # which is the exact bug this issue exists to end. The subshell needs no
        # external kill: it is parked at `wait` and returns when the child dies.
        printf '%s' "$_zbt_pg_child" > "$_pid_file" 2>/dev/null || true
        # Only record a PGID we could prove distinct from the runner's own. An
        # absent file is the honest signal for "PID kill only"; an empty one
        # would read as evidence the group was captured.
        _zbt_pg_id="$(zbuild_pg_resolve "$_zbt_pg_child")"
        [[ -n "$_zbt_pg_id" ]] && \
            printf '%s' "$_zbt_pg_id" > "$_pgid_file" 2>/dev/null || true
        # #2024: ALSO register it with the engine. `set -m` above made this
        # suite a group leader, and until now that group was known only to this
        # plugin — which is why its private cleanup hook was the one mechanism
        # in the tree that ever killed a stage's children. Registering it is
        # what lets teardown free the suite, and what makes retiring that hook
        # a removal of duplication rather than of the only thing that works.
        zbuild_pg_register "$_zbt_pg_id" "test" 2>/dev/null || true
        wait "$_zbt_pg_child"
        exit $?
    )

}

# ─── _test_runtime_dir <state_dir> ───────────────────────────────────────────
# Live-resource bookkeeping (child PIDs, staging paths) lives here, deliberately
# NOT under artifacts/: a PID and a mktemp path are machine-specific, so putting
# them in the artifact tree breaks the local-vs-CI parity contract and misfiles
# scratch state as a stage output (#1829).
_test_runtime_dir() {
    printf '%s' "${1%/}/runtime"
}

# ─── _test_kill_staging_pg <pid_file> <pgid_file> ───────────────────────────
# Best-effort teardown of the test subprocess tree (#1829, ADR-054 §7).
# A recorded PGID kills the whole group so forked workers are reaped too; with
# none, the single PID is all we can prove safe to signal. Both paths escalate
# TERM→grace→KILL through proc-group.sh — a suite that flushes coverage or
# writes partial results on SIGTERM needs that window whichever path kills it.
_test_kill_staging_pg() {
    local _pf="${1:-}" _gf="${2:-}"
    if [[ -f "$_gf" ]]; then
        local _pgid; _pgid="$(zbuild_pg_record_pgid "$_gf" 2>/dev/null || true)"
        if [[ -n "$_pgid" && "$_pgid" =~ ^[0-9]+$ ]]; then
            zbuild_pg_kill "$_pgid"
            return 0
        fi
    fi
    [[ -f "$_pf" ]] || return 0
    local _pid; _pid="$(cat "$_pf" 2>/dev/null || true)"
    zbuild_pid_kill "$_pid"
}
