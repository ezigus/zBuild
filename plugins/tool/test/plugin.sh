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

    # ── Copy repo into temp dir ────────────────────────────────────────────────
    # Include .git so that `git apply` has a valid repository context.
    # Use rsync when available for speed; fall back to cp.
    if command -v rsync >/dev/null 2>&1; then
        rsync -a "$repo_root/" "$tmp/" 2>/dev/null || \
            cp -r "$repo_root/." "$tmp/"
    else
        cp -r "$repo_root/." "$tmp/"
    fi

    # ── Apply diff ────────────────────────────────────────────────────────────
    # Dry-run first with --allow-empty so a no-op (empty) diff is accepted.
    local apply_check_out
    if ! apply_check_out="$(git -C "$tmp" apply --check --allow-empty "$diff_patch_path" 2>&1)"; then
        # Could not apply — write error artifact and return
        test_output="git apply --check failed: ${apply_check_out}"
        _test_emit_io_end "$_test_seq" "$_test_t0_us" "error" 2 0 0 \
            "git apply --check failed: $(printf '%s' "$apply_check_out" | head -n1)"
        _test_write_result "$output_json" \
            "error" 2 0 0 "$test_output" "false" "$test_cmd"
        rm -rf "$tmp"
        emit_event "plugin.run.complete" "plugin=test" "verdict=error" "reason=diff_apply_failed"
        return 0
    fi

    if ! git -C "$tmp" apply --allow-empty "$diff_patch_path" 2>/dev/null; then
        test_output="git apply failed after --check passed"
        _test_emit_io_end "$_test_seq" "$_test_t0_us" "error" 2 0 0 \
            "git apply failed after --check passed"
        _test_write_result "$output_json" \
            "error" 2 0 0 "$test_output" "false" "$test_cmd"
        rm -rf "$tmp"
        emit_event "plugin.run.error" "plugin=test" "reason=diff_apply_failed_after_check"
        return 0
    fi
    diff_applied=true

    # ── Run test command ───────────────────────────────────────────────────────
    local test_rc=0
    local raw_output
    raw_output="$(cd "$tmp" && eval "$test_cmd" 2>&1)" || test_rc=$?

    # Truncate output to 10 KB to keep artifact manageable
    test_output="$(printf '%s' "$raw_output" | head -c 10240)"

    exit_code="$test_rc"

    if [[ "$test_rc" -eq 0 ]]; then
        verdict="pass"
    else
        verdict="fail"
    fi

    # ── Parse pass/fail counts if possible ────────────────────────────────────
    local passed=0
    local failed=0
    # Try to parse npm/jest style: "X passed, Y failed"
    if printf '%s' "$raw_output" | grep -qE '[0-9]+ passed'; then
        passed="$(printf '%s' "$raw_output" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+' | tail -1 || echo 0)"
    fi
    if printf '%s' "$raw_output" | grep -qE '[0-9]+ failed'; then
        failed="$(printf '%s' "$raw_output" | grep -oE '[0-9]+ failed' | grep -oE '[0-9]+' | tail -1 || echo 0)"
    fi

    # ── #485 silent-failure guard: a no-op run that exits 0 with zero
    # parsed pass/fail counts is NOT a passing test suite — it is a
    # misconfigured test command (e.g. `true`, `:`, an empty script).
    # Emit verdict=error so the review stage fails closed instead of
    # silently approving a build that was never tested.
    if [[ "$verdict" == "pass" && "$passed" -eq 0 && "$failed" -eq 0 ]]; then
        verdict="error"
        if [[ -z "$test_output" ]]; then
            test_output="no-op test run: test_cmd exited 0 but produced no pass/fail counts (passed=0, failed=0)"
        fi
    fi

    # ── #497: build derived one-line summary for the output banner ──────────
    # Rules (pinned 2-agent consensus, see issue #497):
    #   pass   → "N passed, M failed"
    #   fail   → "N passed, M failed (exit N)"
    #   error (no-op #485 guard) → "no-op: 0 tests detected"
    #   error (other failure with non-empty output) → "error: <first line>" +
    #     exit_code metadata. Duration is rendered by the banner heading via
    #     --duration-ms; we don't include it in the summary string.
    local _test_summary=""
    case "$verdict" in
        pass) _test_summary="${passed} passed, ${failed} failed" ;;
        fail) _test_summary="${passed} passed, ${failed} failed (exit ${exit_code})" ;;
        error)
            # #485 no-op guard sets test_output to a known prefix when the
            # silent-failure path triggers. Map to a short summary token.
            if [[ "$test_output" == "no-op test run:"* ]]; then
                _test_summary="no-op: 0 tests detected"
            else
                local _err_first
                _err_first="$(printf '%s' "$test_output" | head -n1)"
                if [[ -z "$_err_first" ]]; then
                    _test_summary="error: (no output) exit_code=${exit_code}"
                else
                    _test_summary="error: ${_err_first}"
                fi
            fi
            ;;
    esac
    _test_emit_io_end "$_test_seq" "$_test_t0_us" "$verdict" "$exit_code" \
        "$passed" "$failed" "$_test_summary"

    _test_write_result "$output_json" \
        "$verdict" "$exit_code" "$passed" "$failed" \
        "$test_output" "$diff_applied" "$test_cmd"

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

# ─── _test_write_result ───────────────────────────────────────────────────────
# Writes test-results.json atomically via a temp file.
# Usage: _test_write_result <path> <verdict> <exit_code> <passed> <failed>
#                            <test_output> <diff_applied> <test_cmd>
_test_write_result() {
    local path="$1"
    local verdict="$2"
    local exit_code="$3"
    local passed="$4"
    local failed="$5"
    local test_output="$6"
    local diff_applied="$7"
    local test_cmd="$8"

    local dir
    dir="$(dirname "$path")"
    mkdir -p "$dir"

    local tmp_out
    tmp_out="$(mktemp "${path}.tmp.XXXXXX")"

    jq -n \
        --arg verdict "$verdict" \
        --argjson exit_code "$exit_code" \
        --argjson passed "$passed" \
        --argjson failed "$failed" \
        --arg test_output "$test_output" \
        --argjson diff_applied "$diff_applied" \
        --arg test_cmd "$test_cmd" \
        '{
            schema_version: 1,
            verdict: $verdict,
            exit_code: $exit_code,
            passed: $passed,
            failed: $failed,
            test_output: $test_output,
            diff_applied: $diff_applied,
            test_cmd: $test_cmd
        }' > "$tmp_out"

    mv "$tmp_out" "$path"
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
