#!/usr/bin/env bash
# Integration: test-plugin spawn subshell uses _zbuild_make_fresh_shell —
# the entire ZBUILD_* namespace is scrubbed (ADR-024, #671).
#
# Parent (runner mimicry) exports ZBUILD_RUN_ID, ZBUILD_EVENTS_JSONL, and
# ZBUILD_STAGE_IO_FD plus opens fd 3 to a sentinel. The plugin's
# `eval "$test_cmd"` subshell must see NONE of these three env vars and
# must NOT be able to write to fd 3.
#
# This strictly supersets Wave 11A (#645)'s narrow ZBUILD_STAGE_IO_FD-only
# test — that one still passes alongside this one.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "integration: test-plugin fresh-user-shell scrub (#671)"

setup_test_env "test-plugin-fresh-shell"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_RUN_ID="test-run-671"
mkdir -p "$ZBUILD_EVENTS_DIR"
: > "$ZBUILD_EVENTS_JSONL"

PLUGIN_DIR="$REPO_ROOT/plugins/tool/test"
ARTIFACT_DIR="$TEST_TEMP_DIR/state/artifacts"
mkdir -p "$ARTIFACT_DIR"
export ZBUILD_ARTIFACT_DIR="$ARTIFACT_DIR"

# Minimal fixture repo
REPO_FIXTURE="$TEST_TEMP_DIR/repo"
mkdir -p "$REPO_FIXTURE"
git -C "$REPO_FIXTURE" init -q
git -C "$REPO_FIXTURE" config user.name t
git -C "$REPO_FIXTURE" config user.email t@t
printf 'hello\n' > "$REPO_FIXTURE/tracked.txt"
git -C "$REPO_FIXTURE" add tracked.txt
git -C "$REPO_FIXTURE" commit -q -m init

EMPTY_PATCH="$ARTIFACT_DIR/diff.patch"
: > "$EMPTY_PATCH"

# Mimic runner: open fd 3 + export ZBUILD_STAGE_IO_FD=3
SENTINEL="$TEST_TEMP_DIR/fd3-sentinel"
: > "$SENTINEL"
exec 3>"$SENTINEL"
export ZBUILD_STAGE_IO_FD=3

# Sanity: parent fd 3 open
( : >&3 ) 2>/dev/null || { echo "BUG: parent fd 3 should be open" >&2; exit 1; }

# shellcheck source=../../plugins/tool/test/plugin.sh
source "$PLUGIN_DIR/plugin.sh"

print_test_section "1. eval subshell has NO ZBUILD_* env and fd 3 is closed"

OUT_JSON="$ARTIFACT_DIR/test-results.json"

# This test_cmd exits 0 ONLY IF:
#   - ZBUILD_RUN_ID is unset
#   - ZBUILD_EVENTS_JSONL is unset
#   - ZBUILD_STAGE_IO_FD is unset
#   - fd 3 is closed (`: >&3` fails)
ISO_CMD='
if [[ -n "${ZBUILD_RUN_ID:-}" ]]; then echo "FAIL: ZBUILD_RUN_ID=$ZBUILD_RUN_ID leaked"; exit 21; fi
if [[ -n "${ZBUILD_EVENTS_JSONL:-}" ]]; then echo "FAIL: ZBUILD_EVENTS_JSONL=$ZBUILD_EVENTS_JSONL leaked"; exit 22; fi
if [[ -n "${ZBUILD_STAGE_IO_FD:-}" ]]; then echo "FAIL: ZBUILD_STAGE_IO_FD=$ZBUILD_STAGE_IO_FD leaked"; exit 23; fi
if ( : >&3 ) 2>/dev/null; then echo "FAIL: fd 3 still open"; exit 24; fi
echo "OK: fresh shell"
exit 0
'

_test_run_inner "$EMPTY_PATCH" "$REPO_FIXTURE" "$OUT_JSON" "$ISO_CMD" \
    >"$TEST_TEMP_DIR/out" 2>"$TEST_TEMP_DIR/err" || true

assert_file_exists "test-results.json written" "$OUT_JSON"

actual_exit="$(jq -r '.data.exit_code' "$OUT_JSON" 2>/dev/null || echo "missing")"
assert_eq "subshell exit_code is 0 (all ZBUILD_* unset AND fd 3 closed)" "0" "$actual_exit"

output_snippet="$(jq -r '.data.test_output' "$OUT_JSON" 2>/dev/null || echo "")"
case "$output_snippet" in
    *"OK: fresh shell"*)
        assert_pass "test_output confirms fresh-user-shell isolation"
        ;;
    *)
        assert_fail "test_output should contain 'OK: fresh shell', got: $output_snippet"
        ;;
esac

# Sentinel file must have received no writes (fd 3 was closed pre-exec)
sentinel_content="$(cat "$SENTINEL" 2>/dev/null || true)"
assert_eq "fd 3 sentinel file is empty (no leaked writes)" "" "$sentinel_content"

# Close parent fd 3 so subsequent tests aren't affected.
exec 3>&-

print_test_results
exit $((FAIL > 0))
