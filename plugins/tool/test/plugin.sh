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

_ZBUILD_TEST_STAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ZBUILD_TEST_STAGE_ROOT="$(cd "$_ZBUILD_TEST_STAGE_DIR/../../.." && pwd)"

# ─── Dependencies ─────────────────────────────────────────────────────────────
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_ZBUILD_TEST_STAGE_ROOT/core/event-bus/event-bus.sh"

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
        _test_write_result "$output_json" \
            "error" 2 0 0 "$test_output" "false" "$test_cmd"
        rm -rf "$tmp"
        emit_event "plugin.run.complete" "plugin=test" "verdict=error" "reason=diff_apply_failed"
        return 0
    fi

    if ! git -C "$tmp" apply --allow-empty "$diff_patch_path" 2>/dev/null; then
        test_output="git apply failed after --check passed"
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

    _test_write_result "$output_json" \
        "$verdict" "$exit_code" "$passed" "$failed" \
        "$test_output" "$diff_applied" "$test_cmd"

    rm -rf "$tmp"
    emit_event "plugin.run.complete" "plugin=test" "verdict=${verdict}" "exit_code=${exit_code}"
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
