#!/usr/bin/env bash
# Unit tests for plugin_hook_call event balance:
#   - engine emits exactly one plugin.run.start and plugin.run.complete per call
#   - ZBUILD_PLUGIN / ZBUILD_PLUGIN_KIND env vars are exported to the plugin subshell
#   - plugins receive non-empty plugin/kind via the exported vars (issue #1705)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"

print_test_header "plugin lifecycle event balance — ZBUILD_PLUGIN/KIND export and event symmetry (#1705)"
setup_test_env "plugin-lifecycle-event-balance"

FIXTURE_DIR="$TEST_TEMP_DIR/plugins/agent/fixture-agent"
EVENTS_LOG="$TEST_TEMP_DIR/events.jsonl"

mkdir -p "$FIXTURE_DIR"
: > "$EVENTS_LOG"

# Minimal fixture manifest: agent kind, declares run hook
cat > "$FIXTURE_DIR/manifest.yaml" << 'MANIFEST_EOF'
id: fixture-agent
name: Fixture Agent
kind: agent
version: 0.0.1
hooks:
  run: fixture_run
MANIFEST_EOF

# Fixture plugin: uses the exported env vars for its domain-result emit.
# SPEC-4 CHANGE assertion depends on this: at baseline (no local -x in
# lifecycle.sh) ZBUILD_PLUGIN/ZBUILD_PLUGIN_KIND are empty in the subshell,
# producing empty .plugin/.kind fields → the non-empty assertion below fails.
cat > "$FIXTURE_DIR/plugin.sh" << 'PLUGIN_EOF'
fixture_run() {
    emit_event "plugin.result" \
        "plugin=${ZBUILD_PLUGIN}" \
        "kind=${ZBUILD_PLUGIN_KIND}" \
        "verdict=pass"
}
PLUGIN_EOF

# ── Stubs ─────────────────────────────────────────────────────────────────────
# Record every emit_event call as a JSON line. Subshells inherit this function.
emit_event() {
    local type="$1"; shift
    local entry
    entry="{\"type\":\"${type}\""
    for kv in "$@"; do
        local key="${kv%%=*}"
        local val="${kv#*=}"
        entry+=",\"${key}\":\"${val}\""
    done
    entry+="}"
    echo "$entry" >> "$EVENTS_LOG"
}

# verify_plugin_for_source — always passes; we are not testing tamper checks.
verify_plugin_for_source() { return 0; }

# scan_plugin_outputs — always passes; no real artifacts in this fixture.
scan_plugin_outputs() { return 0; }

# ── Exercise: invoke plugin_hook_call twice ───────────────────────────────────
plugin_hook_call "$FIXTURE_DIR" "run" "stage-a" ""
plugin_hook_call "$FIXTURE_DIR" "run" "stage-b" ""

# ── Counts ────────────────────────────────────────────────────────────────────
start_count=$(grep -c '"type":"plugin\.run\.start"' "$EVENTS_LOG" 2>/dev/null || true)
complete_count=$(grep -c '"type":"plugin\.run\.complete"' "$EVENTS_LOG" 2>/dev/null || true)
result_count=$(grep -c '"type":"plugin\.result"' "$EVENTS_LOG" 2>/dev/null || true)

# ── SPEC-1: engine emits exactly one plugin.run.start per invocation ─────────
# GUARD: lifecycle.sh has always owned this emit; two invocations → two starts.
assert_eq "[SPEC-1] engine emits exactly 2 plugin.run.start events (one per call)" "2" "$start_count"

# ── SPEC-5: lifecycle events are balanced (starts == completes) ───────────────
# GUARD: plugin_hook_call must emit equal starts and completes.
assert_eq "[SPEC-5] plugin.run.start count equals plugin.run.complete count" "$start_count" "$complete_count"

# ── SPEC-3: no plugin self-emits engine-owned lifecycle event names ───────────
# GUARD: the fixture emits plugin.result, never plugin.run.start/.run.complete.
# Total starts == 2 (engine only) and total completes == 2 (engine only).
# A self-emitting plugin would raise these counts above 2.
self_emit_starts=$(( start_count - 2 ))
self_emit_completes=$(( complete_count - 2 ))
assert_eq "[SPEC-3] no self-emitted plugin.run.start from fixture plugin" "0" "$self_emit_starts"
assert_eq "[SPEC-3] no self-emitted plugin.run.complete from fixture plugin" "0" "$self_emit_completes"

# ── SPEC-4: ZBUILD_PLUGIN and ZBUILD_PLUGIN_KIND are exported to plugin subshell
# CHANGE: at baseline (before local -x exports in lifecycle.sh) the fixture
# plugin sees empty vars, emitting plugin="" and kind="". After the fix the
# vars carry the real id/kind and both assertions below pass.
empty_plugin=$(grep '"type":"plugin\.' "$EVENTS_LOG" | grep -c '"plugin":""' 2>/dev/null || true)
empty_kind=$(grep '"type":"plugin\.' "$EVENTS_LOG" | grep -c '"kind":""' 2>/dev/null || true)
assert_eq "[SPEC-4] no plugin.* event has empty .plugin field" "0" "$empty_plugin"
assert_eq "[SPEC-4] no plugin.* event has empty .kind field" "0" "$empty_kind"
