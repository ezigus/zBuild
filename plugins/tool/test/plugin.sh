#!/usr/bin/env bash
# plugins/tool/test/plugin.sh — Test Stage plugin (ADR-013, issue #342)
#
# Kind: tool  Tier: T0  (NO LLM calls — NEVER call route_to_model)
# Rsyncs the repo HEAD (which post-#608 contains the committed iter work)
# into a temp dir, runs the project test suite, and writes test-results.json.
# Always exits 0; verdict is encoded in the artifact.
# Wave 12-C (#662) removed the historic `git apply diff.patch` step — see
# ADR-020 amendment §A; diff.patch is now consumed only by review + audit.
#
# Hook prefix: test_  (plugin hooks use <plugin>_<verb> convention)
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_TEST_STAGE_LOADED:-}" ]] && return 0
_ZBUILD_TEST_STAGE_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
_ZBUILD_TEST_STAGE_DIR="$_ZBUILD_PLUGIN_DIR"
_ZBUILD_TEST_STAGE_ROOT="$_ZBUILD_PLUGIN_ROOT"

# ─── Dependencies ─────────────────────────────────────────────────────────────
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_ZBUILD_TEST_STAGE_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../../core/output/stage-io.sh
# #497: stage_io_begin/_end wrap the eval below to satisfy ADR-015 §v4
# input-before-action / output-after-action ordering contract.
source "$_ZBUILD_TEST_STAGE_ROOT/core/output/stage-io.sh"
# shellcheck source=./lib/parse.sh
# #584: pattern bank for known test runners + honest fail-safe.
source "$_ZBUILD_TEST_STAGE_DIR/lib/parse.sh"
# shellcheck source=../../../scripts/lib/env-scrub.sh
# ADR-024 / #671: fresh-user-shell helper for the eval subshell below.
source "$_ZBUILD_TEST_STAGE_ROOT/scripts/lib/env-scrub.sh"
# shellcheck source=../../../scripts/lib/test-output-sanitize.sh
# Wave 15-C / #681: strip stage-io banners + ANSI + redaction-tag wrappers
# before truncation so the 10KB head-c budget carries signal, not decoration.
source "$_ZBUILD_TEST_STAGE_ROOT/scripts/lib/test-output-sanitize.sh"

# ─── _test_compute_target_files (ADR-034 / #846) ─────────────────────────────
# Unions the prior-iter red-set (ZBUILD_TEST_RED_SET JSON array of relative
# paths) with any test files inside $repo_root/tests that grep-reference at
# least one basename from ZBUILD_TEST_CHANGED_FILES (comma-separated list).
# Deduplicates the result. Outputs one relative path per line (relative to
# repo_root). Empty when both inputs are absent/empty.
# Usage: _test_compute_target_files <repo_root>
_test_compute_target_files() {
    local repo_root="$1"
    local red_set_json="${ZBUILD_TEST_RED_SET:-}"
    local changed_files_csv="${ZBUILD_TEST_CHANGED_FILES:-}"

    local -a all_files=()

    # Add files from red-set JSON (array of repo-relative paths)
    if [[ -n "$red_set_json" && -f "$red_set_json" ]]; then
        local _rf
        while IFS= read -r _rf; do
            [[ -n "$_rf" ]] && all_files+=("$_rf")
        done < <(jq -r '.[]? // empty' "$red_set_json" 2>/dev/null || true)
    fi

    # Add test files that grep-reference any changed source file by basename
    if [[ -n "$changed_files_csv" ]]; then
        local _tests_dir="$repo_root/tests"
        local _IFS_save="$IFS"; IFS=','
        local -a _changed_arr=()
        read -ra _changed_arr <<< "$changed_files_csv"
        IFS="$_IFS_save"
        local _cf _bn _match
        for _cf in "${_changed_arr[@]}"; do
            # Trim whitespace
            _cf="${_cf## }"; _cf="${_cf%% }"
            [[ -z "$_cf" ]] && continue
            _bn="$(basename "$_cf")"
            [[ -z "$_bn" ]] && continue
            while IFS= read -r _match; do
                [[ -z "$_match" ]] && continue
                # Make relative to repo_root
                _match="${_match#$repo_root/}"
                all_files+=("$_match")
            done < <(grep -rl "$_bn" "$_tests_dir" 2>/dev/null || true)
        done
    fi

    # Deduplicate and emit sorted list (skip blanks)
    if [[ ${#all_files[@]} -gt 0 ]]; then
        printf '%s\n' "${all_files[@]}" | sort -u | grep -v '^[[:space:]]*$' || true
    fi
}

# ─── _test_build_targeted_cmd (ADR-034 / #846) ───────────────────────────────
# Converts a newline-delimited list of test file paths into a runnable command.
# .sh files → direct bash invocation (chained with &&).
# Empty file list → returns base_cmd unchanged (full-suite fallback).
# Mixed or non-.sh files → returns base_cmd unchanged (unrecognized runner).
# Usage: _test_build_targeted_cmd <base_cmd> <file_list>
_test_build_targeted_cmd() {
    local base_cmd="$1"
    local file_list="$2"

    if [[ -z "$file_list" ]]; then
        printf '%s' "$base_cmd"
        return 0
    fi

    local _any_sh=0 _any_other=0 _f
    while IFS= read -r _f; do
        [[ -z "$_f" ]] && continue
        case "$_f" in
            *.sh) _any_sh=1 ;;
            *)    _any_other=1 ;;
        esac
    done <<< "$file_list"

    # Only build a targeted cmd when ALL files are .sh test scripts
    if [[ "$_any_sh" -eq 1 && "$_any_other" -eq 0 ]]; then
        local _parts=""
        while IFS= read -r _f; do
            [[ -z "$_f" ]] && continue
            if [[ -n "$_parts" ]]; then
                _parts="${_parts} && bash '${_f}'"
            else
                _parts="bash '${_f}'"
            fi
        done <<< "$file_list"
        if [[ -n "$_parts" ]]; then
            printf '%s' "$_parts"
            return 0
        fi
    fi

    # Fallback: non-.sh or mixed → run full suite
    printf '%s' "$base_cmd"
}

# ─── test_init ────────────────────────────────────────────────────────────────
# Sets plugin identity env vars and emits plugin.init.start.
test_init() {
    export ZBUILD_PLUGIN="test"
    export ZBUILD_PLUGIN_KIND="tool"
    emit_event "plugin.init.start" "plugin=test" "kind=tool"
    return 0
}

# ─── test_run ─────────────────────────────────────────────────────────────────
# Entry point called by the pipeline engine.
# Usage: test_run <stage> <state_file>
test_run() {
    local _stage="$1"  # stage name passed by engine; unused by this tool plugin
    local state_file="$2"

    # Derive paths from state_file location (state_file lives in state dir)
    local state_dir
    state_dir="$(dirname "$state_file")"
    local artifact_dir="${ZBUILD_ARTIFACT_DIR:-${state_dir}/artifacts}"
    local repo_root="${ZBUILD_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo "$state_dir")}"
    local diff_patch="${artifact_dir}/diff.patch"
    local output_json="${artifact_dir}/test-results.json"
    local test_cmd="${ZBUILD_TEST_CMD:-npm test}"

    mkdir -p "$artifact_dir"

    _test_run_inner "$diff_patch" "$repo_root" "$output_json" "$test_cmd"
    return 0
}

# ─── _test_run_inner ──────────────────────────────────────────────────────────
# Core logic: rsync repo HEAD to a temp dir, run tests, write artifact.
# Always returns 0 — verdict is in the JSON.
# Wave 12-C (#662): no longer applies diff.patch (path retained as positional
# arg for back-compat with existing callers; the missing-diff guard below is
# kept as defense-in-depth so a broken pipeline state still produces a valid
# artifact).
# Usage: _test_run_inner <diff_patch_path> <repo_root> <output_json> <test_cmd>
_test_run_inner() {
    local diff_patch_path="$1"
    local repo_root="$2"
    local output_json="$3"
    local test_cmd="$4"

    # ADR-034 / #846: read targeted-run control vars BEFORE mktemp / fresh-shell
    # so they're captured in the parent shell (not scrubbed by _zbuild_make_fresh_shell).
    local _zbtr_red_set="${ZBUILD_TEST_RED_SET:-}"
    local _zbtr_changed="${ZBUILD_TEST_CHANGED_FILES:-}"
    local _zbtr_full_gate="${ZBUILD_TEST_FULL_SUITE_GATE:-}"

    local tmp
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/zbuild-test-stage.XXXXXX")"
    # #628: function-scoped RETURN trap self-cleans the staging dir on every
    # exit path (missing-diff guard, apply-fail return, success). No conflict
    # with the runner's SCRIPT-level EXIT trap (_runner_abort_trap) — RETURN
    # fires per-function-frame only. Single-quoted body: $tmp is expanded at
    # trap-install time and "frozen" into the trap action so reassigning
    # $tmp later (never happens here, but defensively) wouldn't redirect rm.
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp' 2>/dev/null || true" RETURN
    local verdict="error"
    local exit_code=2
    local diff_applied=false
    local test_output=""

    # ── Guard: diff.patch must exist ──────────────────────────────────────────
    if [[ ! -f "$diff_patch_path" ]]; then
        _test_write_result "$output_json" \
            "error" 2 0 0 "" "false" "$test_cmd"
        # #628: $tmp cleanup handled by RETURN trap above.
        emit_event "plugin.run.complete" "plugin=test" "verdict=error" "reason=missing_diff_patch"
        return 0
    fi

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
    # On iter 2+, if ZBUILD_TEST_RED_SET or ZBUILD_TEST_CHANGED_FILES is set
    # AND ZBUILD_TEST_FULL_SUITE_GATE is NOT set, attempt a targeted run.
    # _test_compute_target_files uses $tmp (the rsync'd copy) as repo_root so
    # relative paths are stable between iters. If no target files are found OR
    # the runner is not .sh-based, falls back to full_cmd → run_mode stays full.
    local run_mode="full"
    local actual_test_cmd="$test_cmd"
    if [[ -z "$_zbtr_full_gate" ]] && [[ -n "$_zbtr_red_set" || -n "$_zbtr_changed" ]]; then
        local _target_files
        _target_files="$(ZBUILD_TEST_RED_SET="$_zbtr_red_set" \
                         ZBUILD_TEST_CHANGED_FILES="$_zbtr_changed" \
                         _test_compute_target_files "$tmp")"
        if [[ -n "$_target_files" ]]; then
            local _targeted_cmd
            _targeted_cmd="$(_test_build_targeted_cmd "$test_cmd" "$_target_files")"
            if [[ "$_targeted_cmd" != "$test_cmd" ]]; then
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
    # ADR-024 / #671 (Wave 13-B): the test subprocess is a fresh-user-shell
    # class spawn — it must look exactly like the user running `npm test`
    # from their own login shell with no zBuild runner in the process tree.
    # _zbuild_make_fresh_shell scrubs the entire ZBUILD_* namespace and
    # closes fd 3 (the ADR-015 stage-io channel). This supersedes Wave 11A
    # (#645)'s narrow `unset ZBUILD_STAGE_IO_FD && exec 3>&-` — the wider
    # scrub also covers ZBUILD_RUN_ID + ZBUILD_EVENTS_JSONL, which Wave 13
    # dogfood discovered were triggering router C6 precondition refusals
    # when the test subprocess recursed back into the router.
    raw_output="$(
        # Copilot P1 on #673: guard cd BEFORE the helper, because the
        # helper disables errexit (fresh-user-shell posture). A failed
        # cd here would otherwise silently run the test command against
        # the runner's cwd instead of the rsync'd staging dir.
        cd "$tmp" || exit 99
        _zbuild_make_fresh_shell
        eval "$actual_test_cmd" 2>&1
    )" || test_rc=$?

    # Truncate output to 10 KB to keep artifact manageable. Wave 15-C (#681)
    # sanitizes first so the head-c budget carries signal, not framework
    # decoration (banner pairs, ANSI color codes, redaction-tag wrappers).
    test_output="$(printf '%s' "$raw_output" | _zbuild_sanitize_test_output | head -c 10240)"

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

    # ── ADR-021 amendment (#511 F2): derive test-failures-summary.md ────────
    # Pre-verdict-write, post-verdict-derivation. Consumed by the build stage
    # as cycle feedback on the next iter (manifest input `prior_test_failures`,
    # source: cycle_feedback). "missing == empty" — file is ABSENT when no
    # failures present; never empty-but-present (mitigates silent-failure #1).
    local _tfs_path
    _tfs_path="$(dirname "$output_json")/test-failures-summary.md"
    # failures-summary expects a numeric `failed_count`; translate null→0 here.
    local _failed_for_summary="$failed"
    [[ "$_failed_for_summary" == "null" ]] && _failed_for_summary=0
    _test_emit_failures_summary "$_tfs_path" "$verdict" "$_failed_for_summary" "$exit_code" "$raw_output"

    # ── ADR-034 / #846: write test-red-set.json from this run's failures ──────
    # Stores the repo-relative paths of files that failed so the next iter can
    # target them without re-running the full suite. Paths are made relative to
    # $tmp (the rsync'd repo copy) by stripping the leading "$tmp/" prefix.
    # Written as a JSON array ONLY when failures exist; absent when no failures
    # ("missing == empty": absent red-set means clean run or no prior run).
    local _red_set_path
    _red_set_path="$(dirname "$output_json")/test-red-set.json"
    {
        local _raw_fail_paths _rel_paths
        _raw_fail_paths="$(_test_extract_failing_files "$raw_output")"
        if [[ -n "$_raw_fail_paths" ]]; then
            _rel_paths="$(printf '%s\n' "$_raw_fail_paths" \
                | sed "s|^${tmp}/||" | sort -u | grep -v '^[[:space:]]*$')"
        else
            _rel_paths=""
        fi
        if [[ -n "$_rel_paths" ]]; then
            printf '%s\n' "$_rel_paths" \
                | jq -Rn '[inputs | select(. != "")]' 2>/dev/null \
                | atomic_write "$_red_set_path" 2>/dev/null || true
        fi
    }

    _test_write_result "$output_json" \
        "$verdict" "$exit_code" "$passed" "$failed" \
        "$test_output" "$diff_applied" "$test_cmd" "$reason" "$run_mode"

    # #628: $tmp cleanup handled by RETURN trap installed at top of function.
    emit_event "plugin.run.complete" "plugin=test" "verdict=${verdict}" "exit_code=${exit_code}" \
        "run_mode=${run_mode}"
    return 0
}

# ─── _test_emit_io_end ───────────────────────────────────────────────────────
# #497: close the stage-io banner pair opened by stage_io_begin at the start of
# _test_run_inner. Computes wall duration from $t0_us, then calls stage_io_end
# with the derived one-line summary as --output. Best-effort — failures are
# swallowed so they can never destabilize the test verdict path. Skips entirely
# when seq is empty (begin was suppressed, e.g. no template destinations).
# Usage: _test_emit_io_end <seq> <t0_us> <verdict> <exit_code> <passed> <failed> <summary>
_test_emit_io_end() {
    local seq="$1" t0_us="$2" verdict="$3" exit_code="$4"
    local passed="$5" failed="$6" summary="$7"
    [[ -z "$seq" ]] && return 0
    local t1_us="${EPOCHREALTIME/./}"
    local dur_ms=$(( (10#${t1_us} - 10#${t0_us}) / 1000 ))
    (( dur_ms < 0 )) && dur_ms=0
    stage_io_end --stage test --kind command --seq "$seq" \
        --output "$summary" \
        --exit-code "$exit_code" \
        --duration-ms "$dur_ms" \
        --metadata "verdict=$verdict" \
        --metadata "passed=$passed" \
        --metadata "failed=$failed" \
        --metadata "exit_code=$exit_code" 2>/dev/null || true
    return 0
}

# ─── _test_emit_failures_summary (#511 F2) ──────────────────────────────────
# Write a small markdown summary of the test failures when the verdict is
# fail|error AND there is something concrete to report. ABSENT-on-empty
# semantics: if there are no detectable failures, do NOT write the file
# (so the cycle feedback layer sees "missing == nothing to inject" and the
# build FEEDBACK section is omitted entirely — see _build_read_prior_assessment).
#
# Size cap: 8 KB (cycle feedback files must stay small — they are appended
# to the next iter's build prompt). When truncated, append a `[truncated]`
# marker so the consumer knows the slice is partial.
#
# Usage: _test_emit_failures_summary <out_path> <verdict> <failed_count> <exit_code> <raw_output>
_test_emit_failures_summary() {
    local out_path="$1" verdict="$2" failed_count="$3" exit_code="$4" raw_output="$5"
    # Best-effort: nothing useful to emit → ensure file is ABSENT (do not
    # leave a stale prior-iter summary around to mislead the next build).
    if [[ "$verdict" == "pass" ]]; then
        rm -f "$out_path" 2>/dev/null || true
        return 0
    fi
    # error verdict with no recognizable failure content → ABSENT too.
    if [[ "$verdict" == "error" && -z "$raw_output" ]]; then
        rm -f "$out_path" 2>/dev/null || true
        return 0
    fi

    # Extract failing test lines (best-effort across common formats).
    # We keep matched lines verbatim — the build agent reads them as-is.
    local extracted
    extracted="$(printf '%s' "$raw_output" \
        | grep -E '(FAIL|✗|✘|Error:|Failure:|AssertionError|expected|Expected)' \
        | head -n 60 || true)"

    # If nothing matched but verdict says fail/error, fall back to first ~40
    # lines of raw output so the build agent at least sees something.
    if [[ -z "$extracted" ]]; then
        extracted="$(printf '%s' "$raw_output" | head -n 40 || true)"
    fi

    # Pin: if extraction still yields zero non-whitespace content, file must
    # be ABSENT (empty-but-present is impossible — silent-failure guard #1).
    local _nows
    _nows="$(printf '%s' "$extracted" | tr -d '[:space:]')"
    if [[ -z "$_nows" ]]; then
        rm -f "$out_path" 2>/dev/null || true
        return 0
    fi

    mkdir -p "$(dirname "$out_path")" 2>/dev/null || true
    local tmp; tmp="$(mktemp "${out_path}.XXXXXX" 2>/dev/null || echo "${out_path}.tmp")"
    {
        printf '# Test failures summary\n\n'
        printf '- verdict: %s\n' "$verdict"
        printf '- failed: %s\n' "$failed_count"
        printf '- exit_code: %s\n\n' "$exit_code"
        printf '## Failing lines (extracted)\n\n'
        printf '```\n%s\n```\n' "$extracted"
    } > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }

    # 8 KB cap with truncation marker.
    local _max=8192
    local _bytes
    _bytes="$(wc -c < "$tmp" 2>/dev/null | tr -d ' ')"
    if [[ "$_bytes" =~ ^[0-9]+$ && "$_bytes" -gt "$_max" ]]; then
        local _tmp2; _tmp2="$(mktemp "${out_path}.XXXXXX" 2>/dev/null || echo "${out_path}.tmp2")"
        head -c "$_max" "$tmp" > "$_tmp2" 2>/dev/null
        printf '\n\n[truncated]\n' >> "$_tmp2"
        mv -f "$_tmp2" "$tmp"
    fi

    mv -f "$tmp" "$out_path" 2>/dev/null || rm -f "$tmp"
    return 0
}

# ─── _test_write_result ───────────────────────────────────────────────────────
# Writes test-results.json atomically via a temp file.
# Usage: _test_write_result <path> <verdict> <exit_code> <passed> <failed>
#                            <test_output> <diff_applied> <test_cmd> [reason]
# #584: passed/failed may be the literal token "null" to record that the
# parser did not recognize this runner's output (honest fail-safe — never
# fabricate counts). The `reason` field is optional and emitted only when
# non-empty; values include `summary_unavailable` (#584 fail-safe),
# `silent_failure` (#485 no-op guard). Wave 12-C (#662) removed the
# `diff_apply_failed` reason — no caller writes it anymore.
# #626: sanitize a numeric slot — accept "null", integers, or fall back to "null".
# Anything else (whitespace, "abc", embedded quotes) becomes JSON null so jq
# --argjson never barfs and the writer stays fail-CLOSED.
_test_sanitize_numeric() {
    local v="$1"
    if [[ "$v" == "null" ]] || [[ "$v" =~ ^-?[0-9]+$ ]]; then
        printf '%s' "$v"
    else
        printf 'null'
    fi
}

# #626: sanitize a boolean slot — only literal true/false survive; everything
# else becomes false. Mirrors the numeric sanitizer's fail-closed posture.
_test_sanitize_bool() {
    local v="$1"
    if [[ "$v" == "true" || "$v" == "false" ]]; then
        printf '%s' "$v"
    else
        printf 'false'
    fi
}

_test_write_result() {
    local path="$1"
    local verdict="$2"
    local exit_code="$3"
    local passed="$4"
    local failed="$5"
    local test_output="$6"
    local diff_applied="$7"
    local test_cmd="$8"
    local reason="${9:-}"
    # ADR-034 / #846: run_mode field (full|targeted). Defaults to "full" so
    # callers that do not pass the arg (e.g. the missing-diff guard path) get
    # the safe default that does not suppress cycle convergence.
    local run_mode="${10:-full}"

    local dir
    dir="$(dirname "$path")"
    mkdir -p "$dir"

    # #584: pass through "null" literal so --argjson treats it as JSON null;
    # numeric values pass through unchanged.
    # #626: defensive sanitizers — adversarial input (whitespace, control
    # chars, embedded quotes) must never crash jq. Anything that is not a
    # bare integer or the "null" token becomes JSON null; anything that is
    # not true/false becomes false.
    local exit_code_json passed_json failed_json diff_applied_json
    exit_code_json="$(_test_sanitize_numeric "$exit_code")"
    passed_json="$(_test_sanitize_numeric "$passed")"
    failed_json="$(_test_sanitize_numeric "$failed")"
    diff_applied_json="$(_test_sanitize_bool "$diff_applied")"

    # #507: write via atomic_write (helpers.sh) so the manifest-declared
    # primary output `test-results.json` passes the atomicity guard test.
    # #626 + Copilot P2 on #640: stream jq → atomic_write directly with a
    # subshell-scoped pipefail so large test_output never buffers in a
    # bash variable. Check the jq-side exit via PIPESTATUS[0]; on failure
    # write a degenerate-but-valid fallback so the primary artifact always
    # exists and emit test.result_write.fallback. All jq stderr is
    # suppressed so internal sanitization failures never leak.
    jq -n \
        --arg verdict "$verdict" \
        --argjson exit_code "$exit_code_json" \
        --argjson passed "$passed_json" \
        --argjson failed "$failed_json" \
        --arg test_output "$test_output" \
        --argjson diff_applied "$diff_applied_json" \
        --arg test_cmd "$test_cmd" \
        --arg reason "$reason" \
        --arg run_mode "$run_mode" \
        '{
            schema_version: 1,
            verdict: $verdict,
            exit_code: $exit_code,
            passed: $passed,
            failed: $failed,
            test_output: $test_output,
            diff_applied: $diff_applied,
            test_cmd: $test_cmd,
            run_mode: $run_mode
        } + (if $reason != "" then {reason: $reason} else {} end)' \
        2>/dev/null \
      | atomic_write "$path"
    local _jq_rc="${PIPESTATUS[0]}"

    if (( _jq_rc != 0 )); then
        # Fail-closed: overwrite with a degenerate-but-valid JSON object so
        # the primary output always parses. Sanitizers already constrained
        # exit_code_json to {integer, "null"} so %s interpolation is safe.
        printf '{"schema_version":1,"verdict":"error","reason":"result_write_failed","exit_code":%s,"passed":null,"failed":null,"test_output":"","diff_applied":false,"test_cmd":""}\n' \
            "$exit_code_json" | atomic_write "$path"
        emit_event "test.result_write.fallback" "path=$path" 2>/dev/null || true
    fi
}

# ─── test_finalize ────────────────────────────────────────────────────────────
test_finalize() {
    emit_event "plugin.finalize.complete" "plugin=test" "kind=tool"
    return 0
}

# ─── test_cleanup ─────────────────────────────────────────────────────────────
test_cleanup() {
    emit_event "plugin.cleanup.complete" "plugin=test" "kind=tool"
    return 0
}
