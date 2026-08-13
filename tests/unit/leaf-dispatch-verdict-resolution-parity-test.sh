#!/usr/bin/env bash
# Tests: runner.sh leaf dispatch uses resolve_stage_plugin for verdict resolution (#1770).
#
# The leaf dispatch rc==0 verdict-resolution block previously called
# _find_plugin_for_stage (id-only), which silently misses role-bound stages whose
# plugin id ≠ stage name. This test verifies the fix: resolve_stage_plugin
# (role-then-id) is used instead, matching the cycle and parallel paths.
#
# SPEC-1 (change): a role-bound divergent-id stage gets a real verdict, not 'unknown'.
#   Fails at baseline because _find_plugin_for_stage returns empty for such stages,
#   leaving _verdict_manifest unset → runner_read_stage_verdict returns 'unknown'.
# SPEC-2 (change): _verdict_plugin_dir assignment in runner.sh uses resolve_stage_plugin.
#   Fails at baseline because the line contains _find_plugin_for_stage.
# SPEC-3 (guard): existing same-id leaf stages still resolve correctly.
#   resolve_stage_plugin falls through to id-match for these — behavior unchanged.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "leaf dispatch verdict resolution — resolve_stage_plugin parity (#1770)"
setup_test_env "leaf-dispatch-verdict-parity"

_test_cleanup_hook() { cleanup_test_env; }

# ─── Events setup (required by verdict.sh / eb_emit_event) ──────────────────
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../core/pipeline/dispatch.sh
source "$REPO_ROOT/core/pipeline/dispatch.sh"
# shellcheck source=../../core/pipeline/verdict.sh
source "$REPO_ROOT/core/pipeline/verdict.sh"

REAL_PLUGINS_ROOT="$REPO_ROOT/plugins"

# ─── Fixture: divergent-id plugin served by a role ──────────────────────────
# Stage name 'my-stage' → role 'my_custom_role' → plugin id 'my-impl-plugin'
# _find_plugin_for_stage("my-stage") returns EMPTY (no plugin with id=my-stage).
# resolve_stage_plugin("my-stage") finds it via the role binding.
FIXTURE_PLUGIN_DIR="$TEST_TEMP_DIR/plugins/my-impl-plugin"
STATE_DIR="$TEST_TEMP_DIR/state"
ART_DIR="$STATE_DIR/artifacts"
mkdir -p "$FIXTURE_PLUGIN_DIR" "$ART_DIR"

cat > "$FIXTURE_PLUGIN_DIR/manifest.yaml" <<'EOF'
id: my-impl-plugin
name: My Impl Plugin
kind: tool
version: 0.0.1
hooks:
  run: my_impl_plugin_run
requires:
  core: [event-bus]
inputs: []
outputs:
  - id: my_result
    path: ${artifact_dir}/my-result.json
    type: json
    required: true
    primary: true
EOF

# Write a passing verdict artifact so runner_read_stage_verdict returns 'pass'.
printf '%s' '{"verdict":"pass"}' > "$ART_DIR/my-result.json"

FIXTURE_PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"

# Mock role resolution: 'my-stage' → role 'my_custom_role' → FIXTURE_PLUGIN_DIR.
# Defined AFTER sourcing dispatch.sh (which checks declare -F at call time).
template_stage_roles() {
    case "$1" in
        my-stage) echo "my_custom_role" ;;
        *) true ;;
    esac
}
resolve_plugin_for_role() {
    local role="$1" platform="$2"
    if [[ "$role" == "my_custom_role" && -z "$platform" ]]; then
        echo "$FIXTURE_PLUGIN_DIR"
    fi
}

# ─── SPEC-1: role-bound divergent-id stage gets real verdict via resolve_stage_plugin
print_test_section "[SPEC-1] divergent-id verdict via role binding"

# Confirm the baseline failure: id-only lookup returns EMPTY for 'my-stage'.
_id_only_dir="$(_find_plugin_for_stage "my-stage" "$FIXTURE_PLUGINS_ROOT" 2>/dev/null || true)"
assert_eq "[SPEC-1] baseline: _find_plugin_for_stage returns empty for role-bound stage" \
    "" "$_id_only_dir"

# Simulate the OLD (broken) leaf path: empty dir → empty manifest → verdict=unknown.
_old_manifest=""
[[ -n "$_id_only_dir" ]] && _old_manifest="$_id_only_dir/manifest.yaml"
_old_verdict="$(runner_read_stage_verdict "$STATE_DIR" "$_old_manifest" "my-stage" 0)"
assert_eq "[SPEC-1] old leaf path (_find_plugin_for_stage): verdict is 'unknown' (baseline failure)" \
    "unknown" "$_old_verdict"

# Simulate the FIXED leaf path: resolve_stage_plugin finds dir via role → real verdict.
_new_dir="$(resolve_stage_plugin "my-stage" "$FIXTURE_PLUGINS_ROOT" 2>/dev/null || true)"
assert_eq "[SPEC-1] resolve_stage_plugin returns fixture dir via role binding" \
    "$FIXTURE_PLUGIN_DIR" "$_new_dir"

_new_manifest=""
[[ -n "$_new_dir" ]] && _new_manifest="$_new_dir/manifest.yaml"
_new_verdict="$(runner_read_stage_verdict "$STATE_DIR" "$_new_manifest" "my-stage" 0)"
assert_eq "[SPEC-1] fixed leaf path (resolve_stage_plugin): verdict is 'pass' (not 'unknown')" \
    "pass" "$_new_verdict"

# ─── SPEC-2: runner.sh _verdict_plugin_dir assignment uses resolve_stage_plugin ─
print_test_section "[SPEC-2] runner.sh verdict-resolution block parity"

# The _verdict_plugin_dir=... line must use resolve_stage_plugin, not _find_plugin_for_stage.
# At the merge-base baseline this assertion FAILS because the line contains _find_plugin_for_stage.
_bad_assign="$(grep '_verdict_plugin_dir=.*_find_plugin_for_stage' \
    "$REPO_ROOT/core/pipeline/runner.sh" || true)"
assert_eq "[SPEC-2] _verdict_plugin_dir assignment uses resolve_stage_plugin (not _find_plugin_for_stage)" \
    "" "$_bad_assign"

# Confirm the correct assignment IS present.
_good_assign="$(grep '_verdict_plugin_dir=.*resolve_stage_plugin' \
    "$REPO_ROOT/core/pipeline/runner.sh" || true)"
assert_contains "[SPEC-2] runner.sh has _verdict_plugin_dir set via resolve_stage_plugin" \
    "$_good_assign" "resolve_stage_plugin"

# ─── SPEC-3: existing same-id leaf stages still resolve via resolve_stage_plugin ─
print_test_section "[SPEC-3] same-id leaf stages resolve correctly (regression guard)"

# Unset the SPEC-1 mocks so the real id-match fallback path is exercised.
# Same-id stages (stage name == plugin id) have always used the id-match fallback;
# the change to resolve_stage_plugin is backward-compat for these.
unset -f template_stage_roles resolve_plugin_for_role

for _stage in intake plan impact review-aggregator pr deploy validate monitor; do
    _resolved_dir="$(resolve_stage_plugin "$_stage" "$REAL_PLUGINS_ROOT" 2>/dev/null || true)"
    # Guard the empty case FIRST. Without it an empty resolution builds the path
    # "/manifest.yaml" and the assertion silently interrogates the filesystem
    # root — it would report "cannot find /manifest.yaml", sending the reader
    # after a missing manifest when the real fault is that resolution returned
    # nothing, and it would pass outright on any host where that path exists.
    if [[ -z "$_resolved_dir" ]]; then
        assert_fail "[SPEC-3] resolve_stage_plugin($_stage) returns a plugin dir" \
            "resolution returned empty — no role binding and no id match under $REAL_PLUGINS_ROOT"
        continue
    fi
    assert_pass "[SPEC-3] resolve_stage_plugin($_stage) returns a plugin dir"
    assert_file_exists \
        "[SPEC-3] resolve_stage_plugin($_stage) resolves to a dir with manifest.yaml" \
        "$_resolved_dir/manifest.yaml"
done

# ─── Results ─────────────────────────────────────────────────────────────────
print_test_results
