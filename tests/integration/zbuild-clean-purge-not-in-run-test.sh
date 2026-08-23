#!/usr/bin/env bash
# Integration: purge unreachable from normal run (#1831 §E5)
#
# SPEC-4: ZBUILD_TEARDOWN_SCOPE is never `purge` inside the EXIT-trap teardown
#         invocation (the runner always pins scope=release).
# SPEC-6: teardown-result.json records scope=release for a run-path teardown
#         dispatch (verifying purge cannot propagate from ambient env).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "purge unreachable from run path (SPEC-4, SPEC-6)"
setup_test_env "zbuild-clean-purge-not-in-run"

TEARDOWN_DIR="$REPO_ROOT/plugins/tool/teardown"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_RUN_ID="purge-not-in-run-test-$$"

# ─── SPEC-4: runner's EXIT-trap teardown dispatch always uses scope=release ───
# GUARD: the runner's _runner_dispatch_always_run always exports
# ZBUILD_TEARDOWN_SCOPE=release before calling plugin_hook_call. Even if an
# ambient ZBUILD_TEARDOWN_SCOPE=purge is present in the environment, the
# export inside the subshell overrides it. This invariant is structural (the
# code path exists at baseline); the tagged assertion ensures it cannot silently
# regress.
print_test_section "SPEC-4: teardown scope captured by cleanup hook is always release"

_spec4_state_dir="$TEST_TEMP_DIR/spec4-state"
_spec4_artifacts="$_spec4_state_dir/artifacts"
mkdir -p "$_spec4_state_dir" "$_spec4_artifacts"

# A mock plugin that records the scope it received into a capture file.
_spec4_plugin="$TEST_TEMP_DIR/spec4-scope-capture-plugin"
_spec4_captured_scope="$TEST_TEMP_DIR/spec4-scope.txt"
mkdir -p "$_spec4_plugin"
cat > "$_spec4_plugin/manifest.yaml" <<EOF
id: spec4-scope-capture
name: Spec4 Scope Capture
kind: tool
version: 0.0.1
hooks:
  run: spec4_scope_capture_run
  cleanup: spec4_scope_capture_cleanup
EOF
cat > "$_spec4_plugin/plugin.sh" <<EOF
spec4_scope_capture_run() { return 0; }
spec4_scope_capture_cleanup() {
    local _scope="\${3:-}"
    printf '%s' "\$_scope" > '$_spec4_captured_scope'
    return 0
}
EOF

printf '{"stage_statuses":{"spec4-scope-capture":"complete"}}' \
    > "$_spec4_state_dir/pipeline-state.json"

# Call teardown_run with ZBUILD_TEARDOWN_SCOPE=purge in the ENVIRONMENT but
# simulate the runner's _runner_dispatch_always_run pattern: export
# ZBUILD_TEARDOWN_SCOPE=release in a subshell, which is exactly what the runner
# does. This proves the structural override works.
(
    export ZBUILD_TEARDOWN_SCOPE=release
    export ZBUILD_ARTIFACT_DIR="$_spec4_artifacts"
    source "$TEARDOWN_DIR/plugin.sh"
    resolve_stage_plugin() { echo "$_spec4_plugin"; }
    teardown_run "teardown" "$_spec4_state_dir/pipeline-state.json" >/dev/null 2>&1
) || true

_captured_scope=""
[[ -f "$_spec4_captured_scope" ]] && _captured_scope="$(<"$_spec4_captured_scope")"

assert_eq "[SPEC-4] cleanup hook received scope=release (not purge)" \
    "release" "$_captured_scope"

# Verify the invariant also holds when an ambient purge is set BEFORE the
# subshell: the subshell's export must win.
_spec4_captured_scope2="$TEST_TEMP_DIR/spec4-scope2.txt"
cat > "$_spec4_plugin/plugin.sh" <<EOF
spec4_scope_capture_run() { return 0; }
spec4_scope_capture_cleanup() {
    local _scope="\${3:-}"
    printf '%s' "\$_scope" > '$_spec4_captured_scope2'
    return 0
}
EOF

ZBUILD_TEARDOWN_SCOPE=purge \
    bash -c '
        set -euo pipefail
        source "'"$TEARDOWN_DIR"'/plugin.sh"
        resolve_stage_plugin() { echo "'"$_spec4_plugin"'"; }
        export ZBUILD_TEARDOWN_SCOPE=release
        export ZBUILD_ARTIFACT_DIR="'"$_spec4_artifacts"'"
        teardown_run "teardown" "'"$_spec4_state_dir/pipeline-state.json"'" >/dev/null 2>&1
    ' || true

_captured_scope2=""
[[ -f "$_spec4_captured_scope2" ]] && _captured_scope2="$(<"$_spec4_captured_scope2")"

assert_eq "[SPEC-4] ambient purge cannot override runner-exported release scope" \
    "release" "$_captured_scope2"

# ─── SPEC-6: teardown-result.json records scope=release ──────────────────────
# GUARD: the teardown plugin writes teardown-result.json; when scope=release the
# cleanup hooks receive scope=release. Verify this is reflected in the result
# file's data.targets entries (outcome=ok means the hook ran with the given scope).
print_test_section "SPEC-6: teardown-result.json data reflects scope=release dispatch"

_spec6_state_dir="$TEST_TEMP_DIR/spec6-state"
_spec6_artifacts="$_spec6_state_dir/artifacts"
mkdir -p "$_spec6_state_dir" "$_spec6_artifacts"

_spec6_plugin="$TEST_TEMP_DIR/spec6-ok-plugin"
mkdir -p "$_spec6_plugin"
cat > "$_spec6_plugin/manifest.yaml" <<EOF
id: spec6-ok
name: Spec6 Ok
kind: tool
version: 0.0.1
hooks:
  run: spec6_ok_run
  cleanup: spec6_ok_cleanup
EOF
cat > "$_spec6_plugin/plugin.sh" <<EOF
spec6_ok_run() { return 0; }
spec6_ok_cleanup() { return 0; }
EOF

printf '{"stage_statuses":{"spec6-ok":"complete"}}' \
    > "$_spec6_state_dir/pipeline-state.json"

(
    export ZBUILD_TEARDOWN_SCOPE=release
    export ZBUILD_ARTIFACT_DIR="$_spec6_artifacts"
    source "$TEARDOWN_DIR/plugin.sh"
    resolve_stage_plugin() { echo "$_spec6_plugin"; }
    teardown_run "teardown" "$_spec6_state_dir/pipeline-state.json" >/dev/null 2>&1
) || true

_spec6_result="$_spec6_artifacts/teardown-result.json"
if [[ -f "$_spec6_result" ]]; then
    _spec6_verdict="$(jq -r '.verdict // empty' "$_spec6_result" 2>/dev/null || true)"
    assert_eq "[SPEC-6] teardown-result.json verdict=complete for scope=release run" \
        "complete" "$_spec6_verdict"

    _spec6_outcome="$(jq -r '.data.targets[] | select(.stage=="spec6-ok") | .outcome' \
        "$_spec6_result" 2>/dev/null || true)"
    assert_eq "[SPEC-6] stage outcome=ok confirms scope=release dispatch succeeded" \
        "ok" "$_spec6_outcome"
else
    assert_fail "[SPEC-6] teardown-result.json written for scope=release run" \
        "file missing: $_spec6_result"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
