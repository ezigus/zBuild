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
source "$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
_ZBUILD_TEST_STAGE_DIR="$_ZBUILD_PLUGIN_DIR"
_ZBUILD_TEST_STAGE_ROOT="$_ZBUILD_PLUGIN_ROOT"

# ─── Dependencies ─────────────────────────────────────────────────────────────
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_ZBUILD_TEST_STAGE_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../../scripts/lib/stage-summary.sh
source "$_ZBUILD_TEST_STAGE_ROOT/scripts/lib/stage-summary.sh"
# #2366: one outcome from the engine's list, through the one writer.
# shellcheck source=../../../scripts/lib/stage-result.sh
source "$_ZBUILD_TEST_STAGE_ROOT/scripts/lib/stage-result.sh"
# shellcheck source=../../../core/output/stage-io.sh
# #497: stage_io_begin/_end wrap the eval below to satisfy ADR-015 §v4
# input-before-action / output-after-action ordering contract.
source "$_ZBUILD_TEST_STAGE_ROOT/core/output/stage-io.sh"
# shellcheck source=./lib/parse.sh
# #584: pattern bank for known test runners + honest fail-safe.
source "$_ZBUILD_TEST_STAGE_DIR/lib/parse.sh"
# shellcheck source=./lib/findings.sh
source "$_ZBUILD_TEST_STAGE_DIR/lib/findings.sh"
# shellcheck source=../../../scripts/lib/env-scrub.sh
# ADR-024 / #671: fresh-user-shell helper for the eval subshell below.
source "$_ZBUILD_TEST_STAGE_ROOT/scripts/lib/env-scrub.sh"
# shellcheck source=../../../scripts/lib/test-output-sanitize.sh
# Wave 15-C / #681: strip stage-io banners + ANSI + redaction-tag wrappers
# before truncation so the 10KB head-c budget carries signal, not decoration.
source "$_ZBUILD_TEST_STAGE_ROOT/scripts/lib/test-output-sanitize.sh"
# shellcheck source=../../../scripts/lib/framework-result.sh
# ADR-040 / #1133: opt-in shared lint/coverage/mutation read-out helpers.
source "$_ZBUILD_TEST_STAGE_ROOT/scripts/lib/framework-result.sh"
# shellcheck source=../../../scripts/lib/proc-group.sh
# Shared setsid capability probe + process-group kill (extracted from route.sh).
source "$_ZBUILD_TEST_STAGE_ROOT/scripts/lib/proc-group.sh"
# #2121: the acceptance tests (#2508: found by their tags) are part of the targeted set.
# #2372: the acceptance grammar comes through the contract-reader seam (#963),
# like every contract lib the acceptance check reads — a run that edits the
# grammar is checked by its own copy. A lib that fails to load is recorded.
# shellcheck source=../../../scripts/lib/acceptance-block.sh
source "$_ZBUILD_CONTRACT_LIB_DIR/acceptance-block.sh" || _ZBUILD_CONTRACT_LOAD_ERRORS+=" acceptance-block.sh"
# #2372: test checks its own run — the acceptance contract, and
# that the assertion files are the ones their author wrote.
# shellcheck source=lib/acceptance-check.sh
source "$_ZBUILD_TEST_STAGE_DIR/lib/acceptance-check.sh"
# #2364: earlier work is found by what it contains, never by which stage made it.
# shellcheck source=../../../scripts/lib/earlier-output.sh
source "$_ZBUILD_TEST_STAGE_ROOT/scripts/lib/earlier-output.sh"
# shellcheck source=lib/own-checks.sh
source "$_ZBUILD_TEST_STAGE_DIR/lib/own-checks.sh"
# shellcheck source=lib/targets.sh
source "$_ZBUILD_TEST_STAGE_DIR/lib/targets.sh"
# shellcheck source=lib/run.sh
source "$_ZBUILD_TEST_STAGE_DIR/lib/run.sh"
# shellcheck source=lib/suite.sh
source "$_ZBUILD_TEST_STAGE_DIR/lib/suite.sh"
# shellcheck source=lib/report.sh
source "$_ZBUILD_TEST_STAGE_DIR/lib/report.sh"
# shellcheck source=lib/result.sh
source "$_ZBUILD_TEST_STAGE_DIR/lib/result.sh"

# ─── test_run ─────────────────────────────────────────────────────────────────
# Entry point called by the pipeline engine.
# Usage: test_run <stage> <state_file>
test_run() {
    local _stage="$1"  # stage name passed by engine; the checks run under it
    local state_file="$2"

    # Derive paths from state_file location (state_file lives in state dir)
    local state_dir
    state_dir="$(dirname "$state_file")"
    local artifact_dir="${ZBUILD_ARTIFACT_DIR:-${state_dir}/artifacts}"
    local repo_root="${ZBUILD_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo "$state_dir")}"
    local output_json="${artifact_dir}/test-results.json"
    local test_cmd="${ZBUILD_TEST_CMD:-npm test}"

    mkdir -p "$artifact_dir"

    _test_run_inner "" "$repo_root" "$output_json" "$test_cmd"
    _test_own_checks "$_stage" "$state_file" "$output_json" "$repo_root"
    return 0
}

# test_cleanup was retired in #2024 (ADR-062 §3). Both halves are engine-owned:
# teardown(release) frees the suite's process group from the record registered
# at spawn, and teardown(purge) deletes `<run>/scratch/` as a path.
#
# The RETURN trap's _test_kill_staging_pg STAYS. It runs while the stage is
# alive, which is a different job from reclaiming after it dies — retiring the
# hook does not make in-process cleanup someone else’s problem.
