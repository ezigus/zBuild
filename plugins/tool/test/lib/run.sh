#!/usr/bin/env bash
# plugins/tool/test/lib/run.sh — one test run: the suite, its checks, and the result (moved from plugin.sh, #2565:
# plugin.sh under 500 lines).
#
# Sourced by plugin.sh after its zbuild_plugin_bootstrap, which loads helpers.sh
# (zbuild_engine_tmpdir). Sourced library: no set -euo.

[[ -n "${_ZBUILD_TEST_RUN_LOADED:-}" ]] && return 0
_ZBUILD_TEST_RUN_LOADED=1

# ─── _test_run_inner ──────────────────────────────────────────────────────────
# Core logic: rsync repo HEAD to a temp dir, run tests, write artifact.
# Always returns 0 — verdict is in the JSON.
# The suite runs on the repo as it stands; it needs nothing from the stage that
# made the change. $1 is kept in the call shape and not read (#2364: the guard
# that refused to run without a diff.patch is gone — Wave 12-C (#662) had
# already stopped applying it).
# Usage: _test_run_inner <unused> <repo_root> <output_json> <test_cmd>
_test_run_inner() {
    local repo_root="$2"
    local output_json="$3"
    local test_cmd="$4"

    # ADR-034 / #846: read targeted-run control vars BEFORE mktemp / fresh-shell
    # so they're captured in the parent shell (not scrubbed by _zbuild_make_fresh_shell).
    local _zbtr_red_set="${ZBUILD_TEST_RED_SET:-}"
    local _zbtr_changed="${ZBUILD_TEST_CHANGED_FILES:-}"

    # #1058 Phase A: in-pipeline test-timing instrumentation. The artifact dir
    # is the dir of output_json. run-tests.sh appends `file <ms> <path>` and
    # `tier <ms> <name>` lines here when this var is set+non-empty. It must be
    # exported INSIDE the eval subshell (below), AFTER _zbuild_make_fresh_shell,
    # because that fresh shell scrubs the whole ZBUILD_* namespace — a plain
    # parent-level export would be wiped before the suite runs. Mirrors how
    # ZBUILD_TEST_RED_SET/CHANGED_FILES are re-supplied to the targeted-files
    # helper. The raw log is left as an
    # artifact; a `timing` summary is folded into test-results.json after the run.
    local _zbt_timing_log
    _zbt_timing_log="$(dirname "$output_json")/test-timing.log"
    # #2167: the log ACCUMULATES across runs — never rm'd. Each run's rows
    # are labelled with a `run <n> <mode>` line above them, so a later
    # targeted re-run adds its rows under the full run's and the suite's
    # numbers survive (the gate's measured bound reads the max per file; the
    # folded summary reads the last block only).

    # #1208: capture the repo-declared count-contract results path (if any) into
    # a non-ZBUILD_ local BEFORE the fresh-shell scrub clears the ZBUILD_*
    # namespace, so we can re-export it INSIDE the test subshell for a repo
    # wrapper to write to. Empty when the repo declares no contract.
    local _zbt_results_json="${ZBUILD_TEST_RESULTS_JSON:-}"

    local tmp
    tmp="$(mktemp -d "$(zbuild_engine_tmpdir)/zbuild-test-stage.XXXXXX")"
    # ADR-054 §7 (#1829): persist staging path + child PID so cleanup can find
    # them from a later stage (a different process). These live under
    # state_dir/runtime/, NOT artifacts/ — a PID and a mktemp path are live
    # process bookkeeping, not stage outputs, and their contents differ by
    # machine, which would break the local-vs-CI parity contract by construction.
    local _runtime_dir; _runtime_dir="$(_test_runtime_dir "$(dirname "$(dirname "$output_json")")")"
    mkdir -p "$_runtime_dir" 2>/dev/null || true
    local _staging_path_file="$_runtime_dir/test-staging-path"
    local _pid_file="$_runtime_dir/test-stage.pid"
    local _pgid_file="$_runtime_dir/test-stage.pgid"
    printf '%s' "$tmp" > "$_staging_path_file" 2>/dev/null || true
    # #1829: RETURN trap kills any lingering eval subshell PGID; does NOT
    # rm -rf the staging dir — that is test_cleanup(purge)'s responsibility.
    # shellcheck disable=SC2064
    trap "_test_kill_staging_pg '$_pid_file' '$_pgid_file'" RETURN
    local verdict="error"
    local exit_code=2
    local diff_applied=false
    local test_output=""

    # ── #497: open stage-io banner (input phase) ──────────────────────────────
    # Wraps git-apply + eval + verdict derivation; ADR-015 §v4 requires input
    # banner BEFORE the action and output banner AFTER. The input encodes
    # test_cmd via printf %q so _stage_io_render_command_argv can decode it
    # back into shell-readable form. Begin only fires past the missing-diff
    # guard (no test_cmd resolution attempted there). Every exit path below
    # MUST call _test_emit_io_end before _test_write_result so the pair closes.
    # Do NOT capture stage_io_begin via $(...) — the begin function's
    # associative-array side effects (pending input/kind/dests/start-ts) live
    # in the parent shell and are lost in a subshell, causing stage_io_end to
    # error out with "no matching stage_io_begin". Mirror the capture_stage_io
    # shim pattern: call directly, swallow the printed seq, then read it back
    # from _STAGE_IO_LAST_SEQ.
    local _test_seq=""
    local _test_t0_us="${EPOCHREALTIME/./}"
    local _test_input_argv
    _test_input_argv="$(printf '%q' "$test_cmd")"
    if stage_io_begin --stage test --kind command \
            --input "$_test_input_argv" \
            --metadata "cwd=$tmp" >/dev/null 2>&1; then
        _test_seq="$_STAGE_IO_LAST_SEQ"
    fi

    # ── Copy repo to tmpdir; tests run against committed HEAD ────────────────
    # Wave 12-C (#662) + ADR-020 amendment §A: after Wave 1 #608 the build
    # commits each iter to HEAD, so the actual work is already in the source
    # repo HEAD. rsync brings it to the tmpdir; `git checkout HEAD -- .` +
    # `clean -fdq` resets any stray working-tree state so tests run against
    # exactly the committed state.
    #
    # The historic `git apply --check diff.patch` + `git apply` block lived
    # here from Wave 1 #548 as scope-violation transport. Wave 12-B (#667)
    # made diff.patch the CUMULATIVE branch delta since intake baseline —
    # which describes work already committed to HEAD. Applying it would be a
    # dup-apply guaranteed to fail. Removed entirely; diff.patch is now
    # consumed only by review (LLM context) and operators (audit).
    if command -v rsync >/dev/null 2>&1; then
        rsync -a "$repo_root/" "$tmp/" 2>/dev/null || \
            cp -r "$repo_root/." "$tmp/"
    else
        cp -r "$repo_root/." "$tmp/"
    fi
    git -C "$tmp" checkout HEAD -- . >/dev/null 2>&1 || true
    git -C "$tmp" clean -fdq >/dev/null 2>&1 || true
    # Wave 12-C (#662): diff_applied is now deprecated — no apply step runs
    # in any path, so the field stays `false` for the whole run. The JSON slot
    # is preserved for schema_version 1 back-compat (consumers may still read
    # it; review's redaction/prompt path is tolerant either way).
    diff_applied=false

    # ── ADR-034 / #846: choose targeted or full-suite command ─────────────────
    # On iter 2+, if ZBUILD_TEST_RED_SET or ZBUILD_TEST_CHANGED_FILES is set,
    # attempt a targeted run first. A targeted PASS is confirmed by the full
    # suite below, in this same invocation (#2144).
    # _test_compute_target_files uses $tmp (the rsync'd copy) as repo_root so
    # relative paths are stable between iters. The targeted-run COMMAND is
    # repo-configurable (ZBUILD_TEST_CMD_TARGETED, a `{files}` template); it
    # defaults to the repo's `scripts/run-tests.sh --files {files}` subset mode
    # when present (it emits the recognised `unit: N/M passed` format). If neither
    # is available — or no target files were found — we fall back to the full
    # command and run_mode stays "full" (never a broken targeted run).
    local run_mode="full"
    local actual_test_cmd="$test_cmd"
    if [[ -n "$_zbtr_red_set" || -n "$_zbtr_changed" ]]; then
        local _target_files
        _target_files="$(ZBUILD_TEST_RED_SET="$_zbtr_red_set" \
                         ZBUILD_TEST_CHANGED_FILES="$_zbtr_changed" \
                         _test_compute_target_files "$tmp")"
        if [[ -n "$_target_files" ]]; then
            local _targeted_tmpl="${ZBUILD_TEST_CMD_TARGETED:-}"
            if [[ -z "$_targeted_tmpl" && -f "$tmp/scripts/run-tests.sh" ]]; then
                _targeted_tmpl='bash scripts/run-tests.sh --files {files}'
            fi
            local _targeted_cmd
            _targeted_cmd="$(_test_build_targeted_cmd "$_targeted_tmpl" "$_target_files")"
            if [[ -n "$_targeted_cmd" ]]; then
                actual_test_cmd="$_targeted_cmd"
                run_mode="targeted"
            fi
        fi
    fi

    # ── Run test command ───────────────────────────────────────────────────────
    # #600 + codex P2 on #604: DO NOT export ZBUILD_TEST_QUIET=1 here. Doing
    # so would quiet the captured raw_output that downstream consumers depend
    # on (test-results.json::.test_output, _test_emit_failures_summary, and
    # test_assessment's prompt all need per-assertion detail to diagnose
    # failures). ZBUILD_TEST_QUIET stays as a local-dev convenience env var.
    # Banner verbosity is instead controlled by stage_io's tail_lines knob
    # (set per-stage in the template).
    local test_rc=0
    local raw_output
    local _zbt_tl_before=0
    [[ -f "$_zbt_timing_log" ]] && _zbt_tl_before="$(wc -c < "$_zbt_timing_log" | tr -d ' ')"
    raw_output="$(_test_spawn_suite "$tmp" "$actual_test_cmd" "$_zbt_timing_log" \
        "$_zbt_results_json" "$_pid_file" "$_pgid_file")" || test_rc=$?
    _test_timing_mark_run "$_zbt_timing_log" "$run_mode" "$_zbt_tl_before"

    # ── #2144: a targeted PASS is confirmed here, not by the orchestrator ────
    # ADR-034's full-suite gate used to live in the cycle: it read run_mode out
    # of this artifact, held convergence for a whole extra iteration (test-author
    # + spec-correspondence + build ≈ 30–40 min of model calls) and, on run
    # 35412141973, held a cycle that has no test member at all. The stage now
    # runs the full suite itself when the subset passed; the full result is the
    # verdict and `run_mode: targeted+full` says both ran. A red subset is
    # reported as-is — fast feedback, nothing to confirm.
    local _targeted_json=""
    if [[ "$run_mode" == "targeted" ]]; then
        local _tv _tp _tf _ts _trec
        IFS='|' read -r _tv _tp _tf _ts _trec <<< "$(_test_parse_summary "$raw_output" "$test_rc")"
        if [[ "$_trec" == "1" && "$_tv" == "pass" && "$_tp" =~ ^[0-9]+$ && "$_tp" -gt 0 ]]; then
            _targeted_json="$(jq -cn --arg c "$actual_test_cmd" --arg v "$_tv" \
                --argjson p "$_tp" --argjson f "$(_test_sanitize_numeric "$_tf")" \
                '{test_cmd:$c, verdict:$v, passed:$p, failed:$f}' 2>/dev/null || true)"
            emit_event "test.targeted.confirming" "passed=${_tp}" 2>/dev/null || true
            # The full run is the authoritative one: its rows get their own
            # `run` label (#2167) — the subset's rows stay above, nothing is rm'd.
            _zbt_tl_before="$(wc -c 2>/dev/null < "$_zbt_timing_log" | tr -d ' ')"; [[ "$_zbt_tl_before" =~ ^[0-9]+$ ]] || _zbt_tl_before=0
            # The parser's pass is authoritative (#584), so the subset's rc no
            # longer matters; the full run's rc replaces it below.
            test_rc=0
            raw_output="$(_test_spawn_suite "$tmp" "$test_cmd" "$_zbt_timing_log" \
                "$_zbt_results_json" "$_pid_file" "$_pgid_file")" || test_rc=$?
            _test_timing_mark_run "$_zbt_timing_log" "full" "$_zbt_tl_before"
            actual_test_cmd="$test_cmd"
            run_mode="targeted+full"
        fi
    fi

    # Truncate output to 10 KB to keep artifact manageable. Wave 15-C (#681)
    # sanitizes first so the head-c budget carries signal, not framework
    # decoration (banner pairs, ANSI color codes, redaction-tag wrappers).
    test_output="$(_zbuild_sanitize_test_output <<< "$raw_output")"
    test_output="${test_output:0:10240}"

    exit_code="$test_rc"

    # ── #584: pattern-bank parse → verdict + counts + summary ────────────────
    # `passed`/`failed` may be the literal string "null" when no pattern
    # recognized the output (fail-safe). The JSON writer translates this to
    # JSON null via --argjson, but downstream callers that expect integers
    # (e.g. _test_emit_failures_summary) must guard with the
    # `recognized` flag before doing arithmetic.
    local passed=0 failed=0 _test_summary="" verdict_p="" recognized=0 reason=""
    local _parsed
    _parsed="$(_test_parse_summary "$raw_output" "$test_rc")"
    IFS='|' read -r verdict_p passed failed _test_summary recognized <<< "$_parsed"

    if [[ "$recognized" == "1" ]]; then
        verdict="$verdict_p"
        # ── #485 silent-failure guard ────────────────────────────────────────
        # A no-op run that was recognized as 0-passed / 0-failed and exited 0
        # is still a misconfigured test command. Keep the original fail-closed
        # semantics so the review stage rejects builds that were never tested.
        if [[ "$verdict" == "pass" && "$passed" -eq 0 && "$failed" -eq 0 ]]; then
            verdict="error"
            reason="silent_failure"
            if [[ -z "$test_output" ]]; then
                test_output="no-op test run: test_cmd exited 0 but produced no pass/fail counts (passed=0, failed=0)"
            fi
            _test_summary="no-op: 0 tests detected"
        fi
    else
        # Fail-safe: parser did not recognize this runner. Do NOT trust the
        # `pass` verdict implied by rc=0; mark verdict=error with a distinct
        # reason so consumers can distinguish from #485 silent failures and
        # from other error reasons.
        verdict="error"
        reason="summary_unavailable"
    fi

    _test_emit_io_end "$_test_seq" "$_test_t0_us" "$verdict" "$exit_code" \
        "$passed" "$failed" "$_test_summary"

    # ── ADR-055 §9: publish this stage's summary ────────────────────────────
    # Pre-verdict-write, post-verdict-derivation. Written unconditionally — a
    # summary states what the stage DID, so a passing run reports its counts
    # rather than leaving the reader to guess whether the stage ran at all.
    local _tfs_path
    _tfs_path="$(dirname "$output_json")/test-failures-summary.md"
    # failures-summary expects a numeric `failed_count`; translate null→0 here.
    local _failed_for_summary="$failed"
    [[ "$_failed_for_summary" == "null" ]] && _failed_for_summary=0
    # `passed` is forwarded verbatim, "null" included: #584 forbids fabricating
    # a count the parser never recognised, and the summary says so plainly.
    # What to fix, per failing file (lib/findings.sh): the reason, and the repo
    # files its output points at — the latter become `about`, which the engine
    # resolves to an owner (#2180). Computed on a non-pass only.
    local _findings_json="[]"
    [[ "$verdict" != "pass" ]] && _findings_json="$(_test_failure_findings "$raw_output" "$tmp")"
    _test_emit_failures_summary "$_tfs_path" "$verdict" "$_failed_for_summary" \
        "$exit_code" "$raw_output" "$passed" "$(_test_findings_markdown "$_findings_json")"

    # #2180: keep the suite's OWN output. The summary above is an ~80-line
    # extraction; everything else was dropped. When a file fails only inside
    # this nested stage — per-run-state-isolation T4 on every suite of #1841 run
    # 35720879137, including the first, before the builder changed anything —
    # the extraction names the file and nothing explains it, and the run is
    # over before anyone can look. This is diagnostic, not prompt context: it is
    # uploaded with the run, never injected (no `summary:` on the declaration).
    _test_write_output_log "$(dirname "$output_json")/test-output.log" "$raw_output"

    # #2183: and the failing files' own output on the error channel, so the
    # stages that read this stage's summary see WHY a file failed rather than
    # only that it did. #1841 run 35802918016: every downstream stage was told
    # "expected: 0, got: 1" while the nested runner's stderr — the thing that
    # said why — was written and dropped.
    if [[ "$verdict" != "pass" ]] && declare -F stage_errors_append >/dev/null 2>&1; then
        local _te_block
        _te_block="$(_test_extract_failing_blocks "$raw_output")"
        [[ -n "$_te_block" ]] && stage_errors_append "${ZBUILD_CURRENT_STAGE:-test}" "$_te_block"
    fi

    # ── ADR-034 / #846: write test-red-set.json from this run's failures ──────
    # Stores the repo-relative paths of files that failed so the next iter can
    # target them without re-running the full suite. Paths are made relative to
    # $tmp (the rsync'd repo copy) by stripping the leading "$tmp/" prefix.
    # Written as a JSON array ONLY when failures exist; absent when no failures
    # ("missing == empty": absent red-set means clean run or no prior run).
    local _red_set_path
    _red_set_path="$(dirname "$output_json")/test-red-set.json"
    # #1239: store DURABLE repo-relative paths so a valid hint survives across
    # iterations (each iter runs in a fresh temp dir). The shared reader (#2573)
    # writes them relative to $tmp whichever way the suite spelled the path —
    # the logical staging path, its macOS /private/var form, or a targeted
    # run's bare relative path.
    {
        local _rel_paths
        _rel_paths="$(_test_extract_failing_files "$raw_output" "$tmp")"
        if [[ -n "$_rel_paths" ]]; then
            printf '%s\n' "$_rel_paths" \
                | jq -Rn '[inputs | select(. != "")]' 2>/dev/null \
                | atomic_write "$_red_set_path" 2>/dev/null || true
        else
            # A clean run clears any STALE red-set so the next iter does not
            # target already-fixed files (missing == empty, honestly applied).
            rm -f "$_red_set_path" 2>/dev/null || true
        fi
    }

    # #1058 Phase A: parse the timing log into a compact `timing` object. Empty
    # when the log is absent/unparseable (the field is then omitted, never null).
    # The raw test-timing.log is left in the artifact dir as-is.
    local _timing_json=""
    _timing_json="$(_test_summarize_timing "$_zbt_timing_log")" || _timing_json=""

    # #1058 Phase B: only a FULL-suite run is an authoritative result for the
    # whole work-tree, so only then record the committed work-tree SHA so the
    # objective gate can safely reuse this result instead of re-running the suite
    # on the identical tree. Targeted/partial runs are NOT authoritative — leave
    # tree_sha empty so the gate fails closed (re-runs) for those. Empty on any
    # git failure → same fail-closed fallback.
    local _tree_sha=""
    if [[ "$run_mode" == "full" || "$run_mode" == "targeted+full" ]]; then
        _tree_sha="$(git -C "$repo_root" rev-parse 'HEAD^{tree}' 2>/dev/null || echo)"
    fi

    # ── ADR-040 / #1133: opt-in shared framework result ───────────────────────
    # When opted in, record lint + coverage + mutation alongside the suite
    # result so later read-out gates consume ONE result. lint/coverage run in
    # $tmp (the committed work-tree copy the suite ran against); mutation is
    # parsed from the suite output already captured (no extra run). Each block
    # is JSON or "" — empty (default) → omitted, keeping output byte-unchanged.
    local _fr_lint="" _fr_cov="" _fr_mut=""
    if _test_framework_enabled; then
        _fr_lint="$(cd "$tmp" 2>/dev/null && framework_run_lint)" || _fr_lint=""
        _fr_cov="$(cd "$tmp" 2>/dev/null && framework_run_coverage)" || _fr_cov=""
        _fr_mut="$(framework_parse_mutation "$raw_output")" || _fr_mut=""
    fi

    # Record the command that actually ran (targeted or full), not the base cmd.
    local _disposition
    _disposition="$(_test_disposition_from_rc "$exit_code" "$verdict")"
    _test_write_result "$output_json" \
        "$verdict" "$_disposition" "$exit_code" "$passed" "$failed" \
        "$test_output" "$diff_applied" "$actual_test_cmd" "$reason" "$run_mode" \
        "$_timing_json" "$_tree_sha" "$_fr_lint" "$_fr_cov" "$_fr_mut" "$_targeted_json" \
        "$_findings_json"

    # #628: $tmp cleanup handled by RETURN trap installed at top of function.
    emit_event "plugin.result" "plugin=test" "verdict=${verdict}" "exit_code=${exit_code}" \
        "run_mode=${run_mode}"
    return 0
}
