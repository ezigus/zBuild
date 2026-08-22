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

# Fixture plugin: emits plugin.result first (so SPEC-1 can inspect the fields),
# then guards on ZBUILD_PLUGIN being non-empty and returns 1 if it is empty.
#
# At baseline (lifecycle.sh has no local -x ZBUILD_PLUGIN):
#   • emit_event writes plugin.result with "plugin=""  → SPEC-1 detects empty fields
#   • return 1 causes the subshell to exit non-zero
#   • set -e fires in plugin_hook_call before plugin.run.complete is emitted
#   → complete_count stays 0 → SPEC-4's second assertion fails (CHANGE behavior)
#
# After the fix (local -x ZBUILD_PLUGIN exported):
#   • ZBUILD_PLUGIN carries "fixture-agent" → plugin.result has non-empty fields
#   • guard passes → function returns 0 → plugin.run.complete is emitted
#   → complete_count == 2 → all assertions pass
cat > "$FIXTURE_DIR/plugin.sh" << 'PLUGIN_EOF'
fixture_run() {
    emit_event "plugin.result" \
        "plugin=${ZBUILD_PLUGIN:-}" \
        "kind=${ZBUILD_PLUGIN_KIND:-}" \
        "verdict=pass"
    # #1918 (SPEC-6 below): record the write-boundary vars as this subshell sees
    # them. Written before the guard so the record exists at baseline too.
    {
        printf 'SCRATCH=%s\n'  "${ZBUILD_STAGE_SCRATCH:-<unset>}"
        printf 'ARTIFACT=%s\n' "${ZBUILD_ARTIFACT_DIR:-<unset>}"
        printf 'TMPDIR=%s\n'   "${TMPDIR:-<unset>}"
    } >> "$ZB_EBAL_BOUNDARY_LOG"
    # Guard: at baseline ZBUILD_PLUGIN is not exported → empty → return 1.
    # This causes the subshell to exit non-zero, which triggers set -e in
    # plugin_hook_call, preventing plugin.run.complete from being emitted.
    [[ -n "${ZBUILD_PLUGIN:-}" ]] || return 1
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

BOUNDARY_LOG="$TEST_TEMP_DIR/boundary.env"
: > "$BOUNDARY_LOG"
export ZB_EBAL_BOUNDARY_LOG="$BOUNDARY_LOG"
# The value the write-boundary block must NOT disturb when there is no state
# file to derive a job folder from.
_EBAL_ORIG_TMPDIR="${TMPDIR:-<unset>}"

# ── Exercise: invoke plugin_hook_call twice ───────────────────────────────────
# Use || true so that at baseline (fixture fails → set -e in plugin_hook_call)
# the test script continues instead of aborting before assertions are reached.
plugin_hook_call "$FIXTURE_DIR" "run" "stage-a" "" || true
plugin_hook_call "$FIXTURE_DIR" "run" "stage-b" "" || true

# ── Counts ────────────────────────────────────────────────────────────────────
start_count=$(grep -c '"type":"plugin\.run\.start"' "$EVENTS_LOG" 2>/dev/null || true)
complete_count=$(grep -c '"type":"plugin\.run\.complete"' "$EVENTS_LOG" 2>/dev/null || true)

# ── SPEC-4: plugin.run.complete emitted on every successful call ──────────────
# CHANGE: at baseline (no local -x ZBUILD_PLUGIN in lifecycle.sh) the fixture
# guard returns 1, the subshell exits non-zero, and set -e causes plugin_hook_call
# to exit before emitting plugin.run.complete → complete_count == 0, not 2.
# After the fix ZBUILD_PLUGIN is exported, the fixture guard passes, and
# plugin_hook_call emits plugin.run.complete for each successful invocation.
assert_eq "[SPEC-4] engine emits exactly 2 plugin.run.start events (one per call)" "2" "$start_count"
assert_eq "[SPEC-4] plugin.run.complete emitted on every successful call" "2" "$complete_count"

# ── SPEC-5: no SHIPPED plugin emits an engine-owned lifecycle event name ──────
# GUARD, repo-wide. This is a static scan rather than a fixture assertion for
# two reasons: a fixture can only speak for itself, and the mocked full run
# (tests/e2e/plugin-event-balance-full-run-test.sh) dispatches ~7 plugins while
# 15+ carried the original collision — the ones never dispatched would regress
# silently. The engine owns the whole plugin.<hook>.* lifecycle family;
# plugins report domain outcomes as plugin.result (verdict=error for failures).
#
# `error` is scanned alongside start/complete because it is the SAME defect:
# the engine emits plugin.run.error for a non-zero hook rc while 8 plugins were
# emitting it for domain failures, so the name could not distinguish "the hook
# crashed" from "the work legitimately concluded it could not proceed".
#
# `cleanup` is scanned alongside `run` for the same reason: plugin_hook_call
# brackets BOTH hooks with its own pair, and 16 plugins self-emitted a bare
# plugin.cleanup.complete — most with no matching start, which is precisely the
# uneven-skew mechanism the issue describes. A run-only scan left that half of
# the namespace uncountable.
#
# The pattern matches the per-plugin wrapper form (`_sf_emit "…"`, `_cg_emit
# "…"`) as well as emit_event, mirroring the emitted-coverage guard. The seven
# gate plugins emit exclusively through those wrappers, so an emit_event-only
# scan was structurally blind to them — it is what let the cleanup collision
# survive the first pass at this issue.
# `|| true`: grep exits 1 on no-match — the HEALTHY case — and with pipefail
# that aborts the script before the assertion ever runs.
_LIFECYCLE_RE='(emit_event|_[a-z][a-z0-9_]*_emit)[[:space:]]+"plugin\.(run|cleanup)\.(start|complete|error)"'
_self_emitters="$(
    { grep -rlnE "$_LIFECYCLE_RE" "$REPO_ROOT/plugins" 2>/dev/null || true; } | tr '\n' ' '
)"
if [[ -z "$_self_emitters" ]]; then
    assert_pass "[SPEC-5] no shipped plugin emits plugin.<run|cleanup>.start/complete/error"
else
    assert_fail "[SPEC-5] no shipped plugin emits plugin.<run|cleanup>.start/complete/error" \
        "self-emitting: $_self_emitters"
fi

# ── SPEC-1: ZBUILD_PLUGIN and ZBUILD_PLUGIN_KIND are exported to plugin subshell
# CHANGE: at baseline (before local -x exports in lifecycle.sh) the fixture
# plugin sees empty vars, producing empty .plugin/.kind on plugin.result.
# After the fix the vars carry the real id/kind and both assertions pass.
empty_plugin=$(grep '"type":"plugin\.result"' "$EVENTS_LOG" | grep -c '"plugin":""' 2>/dev/null || true)
empty_kind=$(grep '"type":"plugin\.result"' "$EVENTS_LOG" | grep -c '"kind":""' 2>/dev/null || true)
assert_eq "[SPEC-1] no plugin.result event has empty .plugin field" "0" "$empty_plugin"
assert_eq "[SPEC-1] no plugin.result event has empty .kind field" "0" "$empty_kind"

# ── SPEC-6: the #1918 write-boundary block is guarded on a non-empty $2 ──────
# GUARD (#1918). Both calls above pass "" as the state_file — the ad-hoc caller
# shape. ADR-058 §3's exports are guarded on that argument being non-empty,
# because `dirname ""` is "." and an unguarded block would silently point every
# such dispatch at ./artifacts and ./scratch, relative to whatever CWD the
# process happened to have. Worse, it would redirect TMPDIR there.
#
# This assertion lives in THIS file rather than only in the #1918 test files
# because this is the caller that exercises the shape: a future change to the
# block that drops the guard passes its own tests and breaks this one.
_ebal_scratch="$(/usr/bin/grep -c '^SCRATCH=<unset>$' "$BOUNDARY_LOG" 2>/dev/null || true)"
assert_eq "[SPEC-6] a dispatch with an empty state_file gets no ZBUILD_STAGE_SCRATCH (both calls)" \
    "2" "$_ebal_scratch"

_ebal_bad_tmpdir="$(/usr/bin/grep -c -v "^TMPDIR=${_EBAL_ORIG_TMPDIR}\$" \
    <(/usr/bin/grep '^TMPDIR=' "$BOUNDARY_LOG") 2>/dev/null || true)"
assert_eq "[SPEC-6] a dispatch with an empty state_file leaves TMPDIR untouched" \
    "0" "$_ebal_bad_tmpdir"

# `.` and `./artifacts` are what an unguarded `dirname "$2"` produces. Naming
# them explicitly is what makes the failure legible when it happens.
_ebal_cwd_artifact="$(/usr/bin/grep -cE '^ARTIFACT=(\.|\./artifacts|/artifacts)$' "$BOUNDARY_LOG" 2>/dev/null || true)"
assert_eq "[SPEC-6] a dispatch with an empty state_file resolves no CWD-relative artifact dir" \
    "0" "$_ebal_cwd_artifact"

# ── SPEC-3: plugin.result is registered as a known event type in the schema ───
# CHANGE: at baseline (before "plugin.result" is added to event-schema.json)
# the count is 0; after the addition it is 1.
schema_has_result=$(grep -c '"plugin\.result"' "$REPO_ROOT/config/event-schema.json" 2>/dev/null || true)
assert_eq "[SPEC-3] plugin.result is registered in event-schema.json" "1" "$schema_has_result"
