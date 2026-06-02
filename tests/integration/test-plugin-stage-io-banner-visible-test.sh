#!/usr/bin/env bash
# Integration: when the test plugin's subshell runs a test that itself
# invokes capture_stage_io, the resulting banner MUST be visible in the
# captured raw_output (i.e. on fd 2 of the subshell, captured by the
# plugin's `2>&1`). #645.
#
# Pre-fix bug: the runner exports ZBUILD_STAGE_IO_FD=3 + opens fd 3. The
# `eval "$test_cmd" 2>&1` subshell inherits both. Inside, capture_stage_io
# writes the banner to fd 3 — which the parent's `2>&1` does NOT capture.
# Tests like core-output-stage-io-test.sh::T11/T51 grep raw_output for
# `end stage-io:` and see nothing → phantom failures.
#
# Post-fix: the subshell unsets ZBUILD_STAGE_IO_FD and closes fd 3 first,
# so stage-io.sh's `_stage_io_validate_fd` falls back to fd 2 — banner
# is captured by `2>&1` and visible in raw_output.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "integration: test-plugin stage-io banner visible (#645)"

setup_test_env "test-plugin-stage-io-banner-visible"

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

# Fixture repo
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

# ── Mimic the pipeline runner: open fd 3 + export ZBUILD_STAGE_IO_FD=3 ──────
SENTINEL="$TEST_TEMP_DIR/sentinel"
: > "$SENTINEL"
exec 3>"$SENTINEL"
export ZBUILD_STAGE_IO_FD=3

# Sanity: parent fd 3 open.
( : >&3 ) 2>/dev/null || { echo "BUG: parent fd 3 should be open" >&2; exit 1; }

# shellcheck source=../../plugins/tool/test/plugin.sh
source "$PLUGIN_DIR/plugin.sh"

print_test_section "1. capture_stage_io banner from test subshell is visible in test_output"

OUT_JSON="$ARTIFACT_DIR/test-results.json"

# Build a test_cmd that:
#   1. Stubs `template_stage_io_dests` so stage-io emits to stdout.
#   2. Sources stage-io.sh inside the subshell.
#   3. Invokes capture_stage_io so a banner is emitted.
#   4. Echoes a marker so we can confirm the test_cmd ran.
# After the fix, the subshell has fd 3 closed → stage-io falls back to fd 2,
# `2>&1` captures the banner, and `end stage-io:` appears in raw_output.
# Use a unique stage name to avoid colliding with the plugin's own
# `--stage test` banner.
BANNER_CMD='set +e; template_stage_io_dests() { printf "stdout\n"; }; export -f template_stage_io_dests; source "'"$REPO_ROOT"'/core/output/stage-io.sh"; capture_stage_io --stage fdcheck --kind computed --input in --output out >/dev/null || true; echo "MARKER_DONE"; exit 0'

_test_run_inner "$EMPTY_PATCH" "$REPO_FIXTURE" "$OUT_JSON" "$BANNER_CMD" \
    >"$TEST_TEMP_DIR/out" 2>"$TEST_TEMP_DIR/err" || true

assert_file_exists "test-results.json written" "$OUT_JSON"

captured="$(jq -r '.test_output' "$OUT_JSON" 2>/dev/null || echo "")"

# Sanity: test_cmd actually ran.
case "$captured" in
    *"MARKER_DONE"*)
        assert_pass "test_cmd ran (MARKER_DONE present)"
        ;;
    *)
        assert_fail "test_cmd did not produce marker; got: $captured"
        ;;
esac

# Core assertion: the stage-io banner string (end stage-io: <stage>) must be
# visible in the captured output. Pre-fix it goes to fd 3 → not in captured.
case "$captured" in
    *"end stage-io: fdcheck"*)
        assert_pass "banner visible in captured raw_output (subshell fd-isolated)"
        ;;
    *)
        assert_fail "banner missing from captured raw_output — fd 3 leaked into eval subshell. captured=$captured"
        ;;
esac

# Close parent fd 3.
exec 3>&-

print_test_results
