#!/usr/bin/env bash
# Integration: test-plugin subprocess MUST be isolated from the runner's
# stage-io fd (#645). The pipeline runner opens fd 3 with `exec 3>&2` and
# exports ZBUILD_STAGE_IO_FD=3 so plugins can emit banners independently of
# stdout/stderr. The test plugin's `eval "$test_cmd"` subshell would
# otherwise inherit BOTH the open fd 3 AND the env var — meaning tests
# inside that subshell write their stage-io banners to fd 3, escaping the
# `2>&1` capture and producing phantom failures whenever a test greps
# captured stderr for the banner string.
#
# This test mimics the runner: parent opens fd 3, exports
# ZBUILD_STAGE_IO_FD=3, then drives `_test_run_inner` with a test_cmd that
# asserts the env var is UNSET in the subshell AND fd 3 is CLOSED.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "integration: test-plugin fd isolation (#645)"

setup_test_env "test-plugin-fd-isolation"

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

# Sanity: fd 3 is open in the parent.
( : >&3 ) 2>/dev/null || { echo "BUG: parent fd 3 should be open" >&2; exit 1; }

# shellcheck source=../../plugins/tool/test/plugin.sh
source "$PLUGIN_DIR/plugin.sh"

print_test_section "1. eval subshell does NOT inherit fd 3 or ZBUILD_STAGE_IO_FD"

OUT_JSON="$ARTIFACT_DIR/test-results.json"

# This test_cmd:
#   - exits 0 ONLY IF ZBUILD_STAGE_IO_FD is unset AND fd 3 is closed.
#   - The two-part check is wrapped so a missing var or open fd both fail.
ISO_CMD='if [[ -n "${ZBUILD_STAGE_IO_FD:-}" ]]; then echo "FAIL: ZBUILD_STAGE_IO_FD=$ZBUILD_STAGE_IO_FD leaked"; exit 11; fi; if ( : >&3 ) 2>/dev/null; then echo "FAIL: fd 3 still open"; exit 12; fi; echo "OK: isolated"; exit 0'

# Drive _test_run_inner. Its `eval "$test_cmd"` should run ISO_CMD in a shell
# that has neither the env var nor fd 3.
_test_run_inner "$EMPTY_PATCH" "$REPO_FIXTURE" "$OUT_JSON" "$ISO_CMD" \
    >"$TEST_TEMP_DIR/out" 2>"$TEST_TEMP_DIR/err" || true

# The plugin always exits 0 and stuffs the subshell's exit code into
# test-results.json::.exit_code. If isolation works, exit_code should be 0.
assert_file_exists "test-results.json written" "$OUT_JSON"

actual_exit="$(jq -r '.exit_code' "$OUT_JSON" 2>/dev/null || echo "missing")"
assert_eq "subshell exit_code is 0 (env var unset AND fd 3 closed)" "0" "$actual_exit"

# Belt-and-suspenders: the JSON's captured test_output should contain "OK: isolated"
output_snippet="$(jq -r '.test_output' "$OUT_JSON" 2>/dev/null || echo "")"
case "$output_snippet" in
    *"OK: isolated"*)
        assert_pass "test_output confirms isolated subshell"
        ;;
    *)
        assert_fail "test_output should contain 'OK: isolated', got: $output_snippet"
        ;;
esac

# Close parent fd 3 so subsequent tests aren't affected.
exec 3>&-

print_test_results
