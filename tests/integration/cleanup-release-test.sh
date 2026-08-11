#!/usr/bin/env bash
# Integration: cleanup(scope) — release frees live resources, purge is operator-only
# ADR-054 §7 (issue #1829)
#
# Covers SPEC-1 through SPEC-4 and SPEC-6.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "cleanup(scope): release frees live resources, purge is operator-only"
setup_test_env "cleanup-release"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

TEARDOWN_DIR="$REPO_ROOT/plugins/tool/teardown"
TEST_PLUGIN_DIR="$REPO_ROOT/plugins/tool/test"

# ─── SPEC-7: the teardown plugin is self-contained ───────────────────────────
# Every other SPEC here stubs resolve_stage_plugin to isolate the dispatch loop,
# which is exactly what let a missing `source dispatch.sh` hide: sourced outside
# the runner, resolve_stage_plugin was undefined, every stage hit `continue`,
# and teardown returned 0 having freed nothing. Assert the plugin brings its own
# dependencies rather than inheriting the runner's scope.
print_test_section "SPEC-7: teardown plugin sources its own dependencies"
_spec7_out="$(bash -c '
    source "'"$TEARDOWN_DIR"'/plugin.sh" >/dev/null 2>&1
    for _fn in resolve_stage_plugin plugin_hook_call emit_event; do
        declare -F "$_fn" >/dev/null || { printf "MISSING:%s\n" "$_fn"; exit 0; }
    done
    printf "ALL_DEFINED\n"
' 2>/dev/null || true)"
if [[ "$_spec7_out" == "ALL_DEFINED" ]]; then
    assert_pass "[SPEC-7] teardown defines its own deps when sourced standalone"
else
    assert_fail "[SPEC-7] teardown defines its own deps when sourced standalone" "$_spec7_out"
fi

# ─── SPEC-1: teardown_run dispatches cleanup with scope=release for completed stages ─
# CHANGE: at baseline the teardown plugin does not exist.
print_test_section "SPEC-1: teardown_run dispatches cleanup scope=release for completed stages"

if [[ ! -d "$TEARDOWN_DIR" || ! -f "$TEARDOWN_DIR/plugin.sh" ]]; then
    assert_fail "[SPEC-1] teardown plugin exists at plugins/tool/teardown/plugin.sh" \
        "missing"
else
    # Set up: a mock plugin dir with a cleanup hook that records its scope argument.
    _spec1_plugin="$TEST_TEMP_DIR/spec1-mock-plugin"
    mkdir -p "$_spec1_plugin"
    _spec1_scope_capture="$TEST_TEMP_DIR/spec1-scope-captured"
    cat > "$_spec1_plugin/manifest.yaml" <<EOF
id: spec1-mock
name: Spec1 Mock
kind: tool
version: 0.0.1
hooks:
  run: spec1_run
  cleanup: spec1_cleanup
EOF
    cat > "$_spec1_plugin/plugin.sh" <<EOF
spec1_run() { return 0; }
spec1_cleanup() {
    local _scope="\${3:-}"
    printf '%s' "\$_scope" > '$_spec1_scope_capture'
    return 0
}
EOF

    # Set up: state file with spec1-mock stage marked complete.
    _spec1_state_dir="$TEST_TEMP_DIR/spec1-state"
    mkdir -p "$_spec1_state_dir"
    _spec1_state_file="$_spec1_state_dir/pipeline-state.json"
    printf '{"stage_statuses":{"spec1-mock":"complete"}}' > "$_spec1_state_file"

    # Source the teardown plugin with an override for resolve_stage_plugin.
    # We source in a subshell so the override doesn't leak.
    _spec1_result=0
    (
        # shellcheck source=../../plugins/tool/teardown/plugin.sh
        source "$TEARDOWN_DIR/plugin.sh"
        # Override resolve_stage_plugin to return our mock plugin dir.
        resolve_stage_plugin() { echo "$_spec1_plugin"; }
        export ZBUILD_TEARDOWN_SCOPE="release"
        teardown_run "teardown" "$_spec1_state_file" >/dev/null 2>&1
    ) || _spec1_result=$?

    assert_eq "[SPEC-1] teardown_run returns 0 (cleanup dispatched)" "0" "$_spec1_result"

    if [[ -f "$_spec1_scope_capture" ]]; then
        _captured_scope="$(cat "$_spec1_scope_capture")"
        assert_eq "[SPEC-1] cleanup hook received scope=release" "release" "$_captured_scope"
    else
        assert_fail "[SPEC-1] cleanup hook received scope=release" "scope capture file not written"
    fi
fi

# ─── SPEC-2: teardown_run returns 0 when cleanup returns non-zero + emits event ─
# CHANGE: at baseline the teardown plugin does not exist.
print_test_section "SPEC-2: cleanup non-zero → event emitted, teardown still returns 0"

if [[ ! -d "$TEARDOWN_DIR" || ! -f "$TEARDOWN_DIR/plugin.sh" ]]; then
    assert_fail "[SPEC-2] teardown plugin exists" "missing"
else
    _spec2_plugin="$TEST_TEMP_DIR/spec2-mock-plugin"
    mkdir -p "$_spec2_plugin"
    cat > "$_spec2_plugin/manifest.yaml" <<'EOF'
id: spec2-mock
name: Spec2 Mock
kind: tool
version: 0.0.1
hooks:
  run: spec2_run
  cleanup: spec2_cleanup
EOF
    cat > "$_spec2_plugin/plugin.sh" <<'EOF'
spec2_run() { return 0; }
spec2_cleanup() { return 7; }
EOF

    _spec2_state_dir="$TEST_TEMP_DIR/spec2-state"
    mkdir -p "$_spec2_state_dir"
    _spec2_state_file="$_spec2_state_dir/pipeline-state.json"
    printf '{"stage_statuses":{"spec2-mock":"complete"}}' > "$_spec2_state_file"

    _spec2_events="$TEST_TEMP_DIR/spec2-events.jsonl"
    _spec2_result=0
    (
        export ZBUILD_EVENTS_JSONL="$_spec2_events"
        export ZBUILD_EVENTS_DB="/dev/null"
        source "$TEARDOWN_DIR/plugin.sh"
        resolve_stage_plugin() { echo "$_spec2_plugin"; }
        export ZBUILD_TEARDOWN_SCOPE="release"
        teardown_run "teardown" "$_spec2_state_file" >/dev/null 2>&1
    ) || _spec2_result=$?

    assert_eq "[SPEC-2] teardown_run returns 0 even when cleanup hook fails" "0" "$_spec2_result"

    if [[ -f "$_spec2_events" ]] && grep -q '"stage.cleanup.failed"' "$_spec2_events" 2>/dev/null; then
        assert_pass "[SPEC-2] stage.cleanup.failed event emitted on non-zero cleanup"
    else
        assert_fail "[SPEC-2] stage.cleanup.failed event emitted on non-zero cleanup" \
            "event not found in: $(cat "$_spec2_events" 2>/dev/null | head -5 || echo none)"
    fi
fi

# ─── SPEC-3: test_cleanup scope=release kills PGID but does not delete staging dir ─
# CHANGE: at baseline test_cleanup ignores scope and doesn't handle release/purge.
print_test_section "SPEC-3: scope=release kills PGID, staging dir remains intact"

(
    source "$TEST_PLUGIN_DIR/plugin.sh"

    _spec3_state_dir="$TEST_TEMP_DIR/spec3-state"
    mkdir -p "$_spec3_state_dir/artifacts" "$_spec3_state_dir/runtime"
    _spec3_state_file="$_spec3_state_dir/pipeline-state.json"
    printf '{}' > "$_spec3_state_file"
    # Live-resource bookkeeping lives under runtime/, not artifacts/ (#1829).
    _spec3_runtime_dir="$_spec3_state_dir/runtime"

    # Create a staging directory simulating what _test_run_inner would create,
    # populated so "deletes nothing" can be asserted as a tree diff, not just
    # a directory-exists check.
    _spec3_staging="$TEST_TEMP_DIR/spec3-staging"
    mkdir -p "$_spec3_staging/nested"
    printf 'sentinel' > "$_spec3_staging/sentinel.txt"
    printf 'evidence' > "$_spec3_staging/nested/failure.log"
    _spec3_before="$(cd "$_spec3_staging" && find . -type f | sort | while read -r _f; do
        printf '%s %s\n' "$_f" "$(wc -c < "$_f" | tr -d ' ')"
    done)"

    # Write a long-running background process and record its PID.
    sleep 60 &
    _spec3_bgpid=$!
    printf '%s' "$_spec3_bgpid" > "$_spec3_runtime_dir/test-stage.pid"
    printf '%s' "$_spec3_staging" > "$_spec3_runtime_dir/test-staging-path"

    # Call release cleanup.
    test_cleanup "test" "$_spec3_state_file" "release" >/dev/null 2>&1 || true

    _spec3_after="$(cd "$_spec3_staging" 2>/dev/null && find . -type f | sort | while read -r _f; do
        printf '%s %s\n' "$_f" "$(wc -c < "$_f" | tr -d ' ')"
    done)"
    if [[ "$_spec3_before" == "$_spec3_after" ]]; then
        printf 'SPEC3_TREE_IDENTICAL\n'
    else
        printf 'SPEC3_TREE_CHANGED\n'
    fi

    # The background sleep should be dead.
    sleep 0.2 2>/dev/null || true
    if kill -0 "$_spec3_bgpid" 2>/dev/null; then
        printf 'SPEC3_PROC_STILL_ALIVE\n'
        kill "$_spec3_bgpid" 2>/dev/null || true
    else
        printf 'SPEC3_PROC_DEAD\n'
    fi

    # The staging dir must still exist (release does NOT delete it).
    if [[ -d "$_spec3_staging" ]]; then
        printf 'SPEC3_DIR_ALIVE\n'
    else
        printf 'SPEC3_DIR_GONE\n'
    fi
) > "$TEST_TEMP_DIR/spec3-out.txt" 2>/dev/null || true

_spec3_out="$(cat "$TEST_TEMP_DIR/spec3-out.txt" 2>/dev/null || echo '')"
if grep -q 'SPEC3_PROC_DEAD' <<< "$_spec3_out"; then
    assert_pass "[SPEC-3] scope=release kills the recorded PGID"
else
    assert_fail "[SPEC-3] scope=release kills the recorded PGID" \
        "process was still alive after release"
fi
if grep -q 'SPEC3_DIR_ALIVE' <<< "$_spec3_out"; then
    assert_pass "[SPEC-3] scope=release does not delete the staging directory"
else
    assert_fail "[SPEC-3] scope=release does not delete the staging directory" \
        "staging dir was deleted by release"
fi
# The acceptance asks for this positively: diff the populated tree, so a
# release that deleted a nested file (but left the dir) cannot pass.
if grep -q 'SPEC3_TREE_IDENTICAL' <<< "$_spec3_out"; then
    assert_pass "[SPEC-3] scope=release leaves the populated staging tree byte-identical"
else
    assert_fail "[SPEC-3] scope=release leaves the populated staging tree byte-identical" \
        "file list/sizes changed across release"
fi

# ─── SPEC-4: absent cleanup hook → ZBUILD_HOOK_ABSENT=3 → teardown no-op (no error) ─
# CHANGE: at baseline teardown plugin doesn't exist; absent hook semantics not tested here.
print_test_section "SPEC-4: absent cleanup hook is a no-op (ZBUILD_HOOK_ABSENT=3)"

if [[ ! -d "$TEARDOWN_DIR" || ! -f "$TEARDOWN_DIR/plugin.sh" ]]; then
    assert_fail "[SPEC-4] teardown plugin exists" "missing"
else
    _spec4_plugin="$TEST_TEMP_DIR/spec4-no-cleanup-plugin"
    mkdir -p "$_spec4_plugin"
    cat > "$_spec4_plugin/manifest.yaml" <<'EOF'
id: spec4-no-cleanup
name: Spec4 No Cleanup
kind: tool
version: 0.0.1
hooks:
  run: spec4_run
EOF
    cat > "$_spec4_plugin/plugin.sh" <<'EOF'
spec4_run() { return 0; }
EOF

    _spec4_state_dir="$TEST_TEMP_DIR/spec4-state"
    mkdir -p "$_spec4_state_dir"
    _spec4_state_file="$_spec4_state_dir/pipeline-state.json"
    printf '{"stage_statuses":{"spec4-no-cleanup":"complete"}}' > "$_spec4_state_file"

    _spec4_events="$TEST_TEMP_DIR/spec4-events.jsonl"
    _spec4_result=0
    (
        export ZBUILD_EVENTS_JSONL="$_spec4_events"
        export ZBUILD_EVENTS_DB="/dev/null"
        source "$TEARDOWN_DIR/plugin.sh"
        resolve_stage_plugin() { echo "$_spec4_plugin"; }
        export ZBUILD_TEARDOWN_SCOPE="release"
        teardown_run "teardown" "$_spec4_state_file" >/dev/null 2>&1
    ) || _spec4_result=$?

    assert_eq "[SPEC-4] teardown_run returns 0 when stage has no cleanup hook" "0" "$_spec4_result"
    # No stage.cleanup.failed event should be emitted (ZBUILD_HOOK_ABSENT is not a failure).
    if [[ -f "$_spec4_events" ]] && grep -q '"stage.cleanup.failed"' "$_spec4_events" 2>/dev/null; then
        assert_fail "[SPEC-4] absent cleanup hook emits no failure event" \
            "unexpected stage.cleanup.failed event found"
    else
        assert_pass "[SPEC-4] absent cleanup hook emits no failure event (ZBUILD_HOOK_ABSENT=3 is a no-op)"
    fi
fi

# ─── SPEC-6: teardown_run never dispatches scope=purge ────────────────────────
# CHANGE: at baseline teardown plugin doesn't exist; this verifies its code never
# calls cleanup with scope=purge.
print_test_section "SPEC-6: teardown_run never dispatches scope=purge"

if [[ ! -d "$TEARDOWN_DIR" || ! -f "$TEARDOWN_DIR/plugin.sh" ]]; then
    assert_fail "[SPEC-6] teardown plugin exists" "missing"
else
    _spec6_plugin="$TEST_TEMP_DIR/spec6-mock-plugin"
    mkdir -p "$_spec6_plugin"
    _spec6_scope_capture="$TEST_TEMP_DIR/spec6-scope-captured"
    cat > "$_spec6_plugin/manifest.yaml" <<EOF
id: spec6-mock
name: Spec6 Mock
kind: tool
version: 0.0.1
hooks:
  run: spec6_run
  cleanup: spec6_cleanup
EOF
    cat > "$_spec6_plugin/plugin.sh" <<EOF
spec6_run() { return 0; }
spec6_cleanup() {
    local _scope="\${3:-}"
    printf '%s\n' "\$_scope" >> '$_spec6_scope_capture'
    return 0
}
EOF

    _spec6_state_dir="$TEST_TEMP_DIR/spec6-state"
    mkdir -p "$_spec6_state_dir"
    _spec6_state_file="$_spec6_state_dir/pipeline-state.json"
    printf '{"stage_statuses":{"spec6-mock":"complete"}}' > "$_spec6_state_file"

    (
        source "$TEARDOWN_DIR/plugin.sh"
        resolve_stage_plugin() { echo "$_spec6_plugin"; }
        export ZBUILD_TEARDOWN_SCOPE="release"
        teardown_run "teardown" "$_spec6_state_file" >/dev/null 2>&1
    ) || true

    if [[ -f "$_spec6_scope_capture" ]]; then
        _spec6_scopes="$(cat "$_spec6_scope_capture")"
        if grep -q "purge" <<< "$_spec6_scopes"; then
            assert_fail "[SPEC-6] teardown_run never dispatches scope=purge" \
                "purge scope was dispatched: $_spec6_scopes"
        else
            assert_pass "[SPEC-6] teardown_run never dispatches scope=purge (only release)"
        fi
    else
        assert_fail "[SPEC-6] teardown_run never dispatches scope=purge" \
            "scope capture file not written — cleanup was not called"
    fi
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
