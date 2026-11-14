#!/usr/bin/env bash
# tests/run-all.sh — orchestrate the full test suite.
#
# Wave 14-B / #675: source tests/lib/test-harness.sh so the canonical Layer 2
# env contract (ADR-024 amendment) is visible to the orchestrator shell. We
# do NOT call zb_test_init_env here — individual test files invoke it (or
# the _with_* / _capture_fd3 helpers) for their own scope. Exporting harness
# env globally would pollute tests that build their own isolated state (e.g.
# cli-session-flags-test.sh's --attach assertions rely on ZBUILD_EVENTS_JSONL
# being unset to exercise the state-dir fallback).
#
# The harness is additive and opt-in: tests that have not adopted it continue
# to behave exactly as before.
set -euo pipefail

_RUN_ALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_RUN_ALL_REPO_ROOT="$(cd "$_RUN_ALL_DIR/.." && pwd)"

# Bash 5 floor check — fail fast before sourcing anything else.
# shellcheck source=../scripts/lib/compat.sh
source "$_RUN_ALL_REPO_ROOT/scripts/lib/compat.sh"

# shellcheck source=./lib/test-harness.sh
source "$_RUN_ALL_DIR/lib/test-harness.sh"

_run_all_rc=0
"$_RUN_ALL_REPO_ROOT/scripts/run-tests.sh" --tier all "$@" || _run_all_rc=$?

# #2541 (ADR-012): a test that is killed, times out or replaces the EXIT trap
# leaves its temp folder. Once the suite is done, sweep the ones older than an
# hour — a newer one may belong to a test still running elsewhere. The patterns
# are cleanup.sh's (ZBUILD_TMPDIR_PATTERNS), the same `zbuild cleanup --tmpdirs`
# reads. The suite's exit code is kept.
# shellcheck source=../scripts/lib/cleanup.sh
source "$_RUN_ALL_REPO_ROOT/scripts/lib/cleanup.sh" 2>/dev/null || true
if declare -F _cleanup_scan_zbuild_tmpdirs >/dev/null 2>&1; then
    _run_all_plan="$(_cleanup_scan_zbuild_tmpdirs 1 2>/dev/null || true)"
    if [[ -n "$_run_all_plan" ]]; then
        _cleanup_apply_tmpdir_plan "$_run_all_plan" false
        _run_all_n=0
        while IFS= read -r _run_all_l; do [[ -n "$_run_all_l" ]] && _run_all_n=$((_run_all_n + 1)); done <<< "$_run_all_plan"
        printf 'run-all: removed %s test temp folder(s) left by earlier runs\n' "$_run_all_n"
    fi
fi
exit "$_run_all_rc"
