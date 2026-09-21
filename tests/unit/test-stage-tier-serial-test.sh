#!/usr/bin/env bash
# test-stage-tier-serial-test.sh — inside the pipeline the suite's tiers run one
# after another (#2170).
#
# `run-tests.sh --tier all` runs its six tiers concurrently (#997), each with
# min(ZBUILD_TEST_MAX_JOBS, CPUs) workers (#2158). On the 4-CPU runner that is
# ~12 heavy processes for 4 cores, next to the outer engine: #1841's full run
# took 25 min, unit files that take seconds took 200–470 s, and timing-sensitive
# tests failed for no reason. Ordinary CI runs one tier per machine. The test
# stage asks for the same: ZBUILD_TIER_CONCURRENCY=0 (the serial switch #997 left).
#
# SPEC-1[change]: the suite the test stage spawns sees ZBUILD_TIER_CONCURRENCY=0
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "test stage: tiers run serially inside the pipeline (#2170)"
setup_test_env "test-stage-tier-serial"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
ARTIFACT_DIR="$ZBUILD_STATE_DIR/artifacts"; mkdir -p "$ARTIFACT_DIR" "$ZBUILD_STATE_DIR/runtime"
export ZBUILD_ARTIFACT_DIR="$ARTIFACT_DIR"
: > "$ARTIFACT_DIR/diff.patch"
REPO_FIXTURE="$TEST_TEMP_DIR/repo"; mkdir -p "$REPO_FIXTURE/tests"
git -C "$REPO_FIXTURE" init -q; git -C "$REPO_FIXTURE" config user.email t@t; git -C "$REPO_FIXTURE" config user.name t
: > "$REPO_FIXTURE/tests/keep"; git -C "$REPO_FIXTURE" add -A; git -C "$REPO_FIXTURE" commit -qm init
PLUGIN_DIR="$REPO_ROOT/plugins/tool/test"
# shellcheck source=../../plugins/tool/test/plugin.sh
source "$PLUGIN_DIR/plugin.sh"
SEEN="$TEST_TEMP_DIR/seen.txt"
unset ZBUILD_TIER_CONCURRENCY
_test_run_inner "$ARTIFACT_DIR/diff.patch" "$REPO_FIXTURE" "$ARTIFACT_DIR/test-results.json" \
    "printf '%s' \"\${ZBUILD_TIER_CONCURRENCY:-unset}\" > '$SEEN'; echo 'unit: 1/1 passed'; exit 0" >/dev/null 2>&1 || true
assert_eq "[SPEC-1] the spawned suite sees ZBUILD_TIER_CONCURRENCY=0 (tiers one after another)" "0" "$(cat "$SEEN" 2>/dev/null)"
cleanup_test_env
print_test_results
exit $((FAIL > 0))
