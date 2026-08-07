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

exec "$_RUN_ALL_REPO_ROOT/scripts/run-tests.sh" --tier all "$@"
