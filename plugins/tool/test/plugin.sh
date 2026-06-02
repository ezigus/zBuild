#!/usr/bin/env bash
# plugins/tool/test/plugin.sh — Test Stage plugin (ADR-013, issue #342)
#
# Kind: tool  Tier: T0  (NO LLM calls — NEVER call route_to_model)
# Applies diff.patch from the artifact directory in a temp copy of the repo,
# runs the project test suite, and writes test-results.json.
# Always exits 0; verdict is encoded in the artifact.
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
# Core logic: apply diff in a temp dir, run tests, write artifact.
# Always returns 0 — verdict is in the JSON.
# Usage: _test_run_inner <diff_patch_path> <repo_root> <output_json> <test_cmd>
_test_run_inner() {
    local diff_patch_path="$1"
    local repo_root="$2"
    local output_json="$3"
    local test_cmd="$4"

    local tmp
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/zbuild-test-stage.XXXXXX")"
    local verdict="error"
    local exit_code=2
    local diff_applied=false
    local test_output=""

    # ── Guard: diff.patch must exist ──────────────────────────────────────────
    if [[ ! -f "$diff_patch_path" ]]; then
        _test_write_result "$output_json" \
            "error" 2 0 0 "" "false" "$test_cmd"
        rm -rf "$tmp"
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

    # ── Copy repo + reset to HEAD + apply canonical diff ─────────────────────
    # #602 + codex P1 on #605: rsync brings the LLM's working-tree edits, BUT
    # in the scope-violation case the build emptied diff.patch while leaving
    # rejected edits in the working tree. If we just trust the rsync, the
    # test runs against code that will not be in the PR. Fix: reset temp to
    # HEAD and apply the CANONICAL diff.patch artifact (which build
    # sanctioned). Restores the Wave 1 #548 contract. Empty diff.patch is
    # fine — tests just run against HEAD.
    if command -v rsync >/dev/null 2>&1; then
        rsync -a "$repo_root/" "$tmp/" 2>/dev/null || \
            cp -r "$repo_root/." "$tmp/"
    else
        cp -r "$repo_root/." "$tmp/"
    fi
    git -C "$tmp" checkout HEAD -- . >/dev/null 2>&1 || true
    git -C "$tmp" clean -fdq >/dev/null 2>&1 || true
    # #608 + #625: post-#608 the build commits each iter to HEAD, so a
    # `git diff HEAD` artifact is empty whenever no further edits were made.
    # The `-s` guard skips apply-check for zero-byte patches (tests run
    # against HEAD); without it, `git apply --check` returns 128 and falls
    # into the apply-failure path below.
    if [[ -s "$diff_patch_path" ]]; then
        if ! git -C "$tmp" apply --check "$diff_patch_path" 2>/dev/null; then
            test_output="diff_apply_failed: canonical diff.patch does not apply"
            # #625: exit_code MUST be numeric — jq --argjson rejects strings.
            # Slot the label into the trailing `reason` field, use exit_code=2
            # as the apply-failure sentinel (matches missing-diff guard above).
            _test_write_result "$output_json" "error" 2 \
                0 0 "$test_output" false "$test_cmd" "diff_apply_failed"
            return 0
        fi
        git -C "$tmp" apply "$diff_patch_path" 2>/dev/null || true
    fi
    diff_applied=true

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
    raw_output="$(cd "$tmp" && eval "$test_cmd" 2>&1)" || test_rc=$?

    # Truncate output to 10 KB to keep artifact manageable
    test_output="$(printf '%s' "$raw_output" | head -c 10240)"

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
        # from `diff_apply_failed` above.
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

    _test_write_result "$output_json" \
        "$verdict" "$exit_code" "$passed" "$failed" \
        "$test_output" "$diff_applied" "$test_cmd" "$reason"

    rm -rf "$tmp"
    emit_event "plugin.run.complete" "plugin=test" "verdict=${verdict}" "exit_code=${exit_code}"
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
# `silent_failure` (#485 no-op guard), `diff_apply_failed` (callers above).
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

    local dir
    dir="$(dirname "$path")"
    mkdir -p "$dir"

    # #584: pass through "null" literal so --argjson treats it as JSON null;
    # numeric values pass through unchanged.
    local passed_json="$passed" failed_json="$failed"

    # #507: write via atomic_write (helpers.sh) so the manifest-declared
    # primary output `test-results.json` passes the atomicity guard test.
    jq -n \
        --arg verdict "$verdict" \
        --argjson exit_code "$exit_code" \
        --argjson passed "$passed_json" \
        --argjson failed "$failed_json" \
        --arg test_output "$test_output" \
        --argjson diff_applied "$diff_applied" \
        --arg test_cmd "$test_cmd" \
        --arg reason "$reason" \
        '{
            schema_version: 1,
            verdict: $verdict,
            exit_code: $exit_code,
            passed: $passed,
            failed: $failed,
            test_output: $test_output,
            diff_applied: $diff_applied,
            test_cmd: $test_cmd
        } + (if $reason != "" then {reason: $reason} else {} end)' \
      | atomic_write "$path"
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
