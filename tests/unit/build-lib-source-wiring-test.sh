#!/usr/bin/env bash
# Tests: lib/*.sh source wiring in plugins/agent/build/plugin.sh (#1533)
#
# Verifies that plugin.sh sources each lib module and exposes the expected
# functions, and that the stripped plugin.sh is under 500 lines.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "build lib/*.sh source wiring (#1533)"
setup_test_env "build-lib-source-wiring"

PLUGIN="$REPO_ROOT/plugins/agent/build/plugin.sh"

# ---------------------------------------------------------------------------
# SPEC-1..5: source directives present in plugin.sh
# ---------------------------------------------------------------------------
_count_source() { grep -c "$1" "$PLUGIN" 2>/dev/null || true; }

assert_gt "[SPEC-1] plugin.sh sources lib/context.sh" "$(_count_source 'lib/context\.sh')" 0
assert_gt "[SPEC-2] plugin.sh sources lib/diff.sh"    "$(_count_source 'lib/diff\.sh')"    0
assert_gt "[SPEC-3] plugin.sh sources lib/commit.sh"  "$(_count_source 'lib/commit\.sh')"  0
assert_gt "[SPEC-4] plugin.sh sources lib/prompt.sh"  "$(_count_source 'lib/prompt\.sh')"  0
assert_gt "[SPEC-5] plugin.sh sources lib/scope.sh"   "$(_count_source 'lib/scope\.sh')"   0

# ---------------------------------------------------------------------------
# SPEC-6: plugin.sh line count under 500
# ---------------------------------------------------------------------------
_PLUGIN_LINES="$(wc -l < "$PLUGIN")"
if [[ "$_PLUGIN_LINES" -lt 500 ]]; then
    assert_pass "[SPEC-6] plugin.sh line count under 500 (got $_PLUGIN_LINES)"
else
    assert_fail "[SPEC-6] plugin.sh line count under 500" "got $_PLUGIN_LINES lines"
fi

# ---------------------------------------------------------------------------
# SPEC-7..11: functions defined when plugin.sh is sourced (guards)
# ---------------------------------------------------------------------------
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR"

# Minimal stubs so plugin.sh can be sourced without a running daemon.
route_to_model_loop() { return 0; }
emit_event() { return 0; }

# shellcheck source=../../plugins/agent/build/plugin.sh
source "$PLUGIN"

_assert_fn() {
    local desc="$1" fn="$2"
    if declare -f "$fn" &>/dev/null; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "function $fn not defined"
    fi
}

_assert_fn "[SPEC-7] _build_load_context defined after sourcing plugin.sh"                   "_build_load_context"
_assert_fn "[SPEC-8] _build_harvest_diff defined after sourcing plugin.sh"                   "_build_harvest_diff"
_assert_fn "[SPEC-9] _build_commit_iteration defined after sourcing plugin.sh"               "_build_commit_iteration"
_assert_fn "[SPEC-10] _build_compose_prompt_body defined after sourcing plugin.sh"           "_build_compose_prompt_body"
_assert_fn "[SPEC-11] _build_collect_scope_expansion_request defined after sourcing plugin.sh" "_build_collect_scope_expansion_request"

cleanup_test_env
print_test_results
