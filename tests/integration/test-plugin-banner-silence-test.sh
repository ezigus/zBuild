#!/usr/bin/env bash
# Integration: test-plugin must not leak `git clean` / `git checkout` chatter
# into the test stage banner (#607).
#
# Wave 6 #605 codex P1 added a `git checkout HEAD -- . && git clean -fd` pair
# in `_test_run_inner` to discard scope-violation rejects before running tests.
# `git clean -fd` prints `Removing <path>` lines to STDOUT (not stderr), but
# only stderr was muted, so the lines leaked into stage_io between the input
# and output banner sections.
#
# This test: build a fixture repo containing untracked files, drive
# _test_run_inner against it, capture stdout, assert no `Removing ` line
# appears.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "integration: test-plugin banner silence (#607)"

setup_test_env "test-plugin-banner-silence"

# Isolated event bus
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

PLUGIN_DIR="$REPO_ROOT/plugins/tool/test"
ARTIFACT_DIR="$TEST_TEMP_DIR/state/artifacts"
mkdir -p "$ARTIFACT_DIR"
export ZBUILD_ARTIFACT_DIR="$ARTIFACT_DIR"

# ─── Build a fixture repo with both tracked AND untracked files ─────────────
# git clean -fd will try to remove the untracked files; the bug is that those
# `Removing ...` messages leak to stdout.
REPO_FIXTURE="$TEST_TEMP_DIR/repo"
mkdir -p "$REPO_FIXTURE"
git -C "$REPO_FIXTURE" init -q
git -C "$REPO_FIXTURE" config user.name t
git -C "$REPO_FIXTURE" config user.email t@t
printf 'hello\n' > "$REPO_FIXTURE/tracked.txt"
git -C "$REPO_FIXTURE" add tracked.txt
git -C "$REPO_FIXTURE" commit -q -m init
# Untracked files (will be removed by git clean -fd in _test_run_inner's temp copy)
printf 'leaked\n' > "$REPO_FIXTURE/untracked-leak-a.txt"
mkdir -p "$REPO_FIXTURE/untracked-dir"
printf 'leaked\n' > "$REPO_FIXTURE/untracked-dir/leak-b.txt"

EMPTY_PATCH="$ARTIFACT_DIR/diff.patch"
: > "$EMPTY_PATCH"

# shellcheck source=../../plugins/tool/test/plugin.sh
source "$PLUGIN_DIR/plugin.sh"

print_test_section "1. _test_run_inner stdout contains no 'Removing ' lines"

OUT_JSON="$ARTIFACT_DIR/test-results.json"
STDOUT_FILE="$TEST_TEMP_DIR/_test_run_inner.stdout"
STDERR_FILE="$TEST_TEMP_DIR/_test_run_inner.stderr"

# `true` keeps the test command trivial; the test command itself is irrelevant
# here, the leak is in the prep phase before the command even runs.
_test_run_inner "$EMPTY_PATCH" "$REPO_FIXTURE" "$OUT_JSON" "true" \
    >"$STDOUT_FILE" 2>"$STDERR_FILE" || true

# Sanity: untracked fixtures actually existed (otherwise the test is vacuous)
assert_file_exists "fixture: untracked file present" "$REPO_FIXTURE/untracked-leak-a.txt"

# Core assertion: no `Removing ` line on stdout.
# Use grep -c with `|| true` because grep exits 1 on no-match.
removing_count=$(grep -c '^Removing ' "$STDOUT_FILE" 2>/dev/null || true)
removing_count="${removing_count:-0}"
assert_eq "stdout has no 'Removing <path>' lines" "0" "$removing_count"

# Belt-and-suspenders: stderr should also be silent for these (the original
# `2>/dev/null` already covered stderr, but the fix preserves that).
removing_err=$(grep -c '^Removing ' "$STDERR_FILE" 2>/dev/null || true)
removing_err="${removing_err:-0}"
assert_eq "stderr has no 'Removing <path>' lines" "0" "$removing_err"

print_test_results
