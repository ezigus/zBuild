#!/usr/bin/env bash
# Integration: zbuild clean --dry-run (#1831 §E5)
#
# SPEC-2: zbuild clean --run-id <id> --dry-run exits rc=0.
# SPEC-3: teardown.dry_run.would_clean event is emitted for each stage that
#         would be cleaned; no cleanup hooks are actually invoked (artifact
#         files remain).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "zbuild clean --dry-run: rc=0 + would_clean events (SPEC-2, SPEC-3)"
setup_test_env "zbuild-clean-dry-run"

ZBUILD_CLI="$REPO_ROOT/scripts/zbuild"
TEARDOWN_DIR="$REPO_ROOT/plugins/tool/teardown"

# ─── Seed: fake completed pipeline-state.json ────────────────────────────────
_run_id="dry-run-test-$$"
_state_dir="$TEST_TEMP_DIR/state/runs/$_run_id"
_artifacts_dir="$_state_dir/artifacts"
_events_file="$_state_dir/events.jsonl"
mkdir -p "$_state_dir" "$_artifacts_dir"

# Two stages marked complete. The plugin dir below has a cleanup hook that
# writes a sentinel file — under --dry-run that write must NOT happen.
_plugin_a="$TEST_TEMP_DIR/plugin-stage-a"
_plugin_b="$TEST_TEMP_DIR/plugin-stage-b"
_sentinel_a="$TEST_TEMP_DIR/sentinel-a"
_sentinel_b="$TEST_TEMP_DIR/sentinel-b"

for _pd in "$_plugin_a" "$_plugin_b"; do
    _id="$(basename "$_pd")"
    _fn="${_id//-/_}"
    _sentinel="$TEST_TEMP_DIR/sentinel-${_id##*-}"
    mkdir -p "$_pd"
    cat > "$_pd/manifest.yaml" <<EOF
id: $_id
name: $_id
kind: tool
version: 0.0.1
hooks:
  run: ${_fn}_run
  cleanup: ${_fn}_cleanup
EOF
    cat > "$_pd/plugin.sh" <<EOF
${_fn}_run() { return 0; }
${_fn}_cleanup() { touch '$_sentinel'; return 0; }
EOF
done

# State file with both stages marked complete.
printf '{"run_id":"%s","stage_statuses":{"plugin-stage-a":"complete","plugin-stage-b":"complete"}}' \
    "$_run_id" > "$_state_dir/pipeline-state.json"

# ─── SPEC-2: dry-run exits rc=0 ──────────────────────────────────────────────
# CHANGE: at baseline `zbuild clean` does not exist; this exits rc=2 with
# "Unknown command". After this change it exits rc=0 when --dry-run is set.
print_test_section "SPEC-2: zbuild clean --dry-run exits rc=0"

_spec2_rc=0
ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state" \
ZBUILD_EVENTS_JSONL="$_events_file" \
ZBUILD_EVENTS_DB="$_state_dir/events.db" \
ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
ZBUILD_PLUGINS_ROOT="$TEST_TEMP_DIR" \
bash "$ZBUILD_CLI" clean \
    --run-id "$_run_id" \
    --dry-run \
    >/dev/null 2>&1 || _spec2_rc=$?

assert_eq "[SPEC-2] zbuild clean --dry-run exits rc=0" "0" "$_spec2_rc"

# ─── SPEC-3: teardown.dry_run.would_clean event emitted ──────────────────────
# CHANGE: at baseline no `clean` subcommand exists; no such event is ever
# emitted. After this change the event is emitted for each stage.
print_test_section "SPEC-3: teardown.dry_run.would_clean events emitted; no hooks invoked"

if [[ -f "$_events_file" ]] && grep -q '"teardown.dry_run.would_clean"' "$_events_file"; then
    assert_pass "[SPEC-3] teardown.dry_run.would_clean event present in events log"
else
    assert_fail "[SPEC-3] teardown.dry_run.would_clean event present in events log" \
        "event absent from $_events_file"
fi

# Verify that teardown.dry_run.would_clean was emitted for at least one stage.
if [[ -f "$_events_file" ]]; then
    _wc_count="$(grep -c '"teardown.dry_run.would_clean"' "$_events_file" 2>/dev/null || echo 0)"
    if [[ "$_wc_count" -ge 1 ]]; then
        assert_pass "[SPEC-3] at least one would_clean event emitted (count: $_wc_count)"
    else
        assert_fail "[SPEC-3] at least one would_clean event emitted" "count=0"
    fi
fi

# SPEC-3: no cleanup hooks were actually invoked — sentinel files must be absent.
if [[ ! -f "$_sentinel_a" && ! -f "$_sentinel_b" ]]; then
    assert_pass "[SPEC-3] cleanup hooks not invoked (sentinel files absent)"
else
    assert_fail "[SPEC-3] cleanup hooks not invoked (sentinel files absent)" \
        "sentinel_a=$(test -f "$_sentinel_a" && echo present || echo absent) sentinel_b=$(test -f "$_sentinel_b" && echo present || echo absent)"
fi

cleanup_test_env
# ─── #1757 review: clean refuses a run that is still in progress ─────────────
# _find_state_file resolves a run_id whatever its status, so without this guard
# an operator could race the runner's own EXIT-trap teardown into the same
# cleanup hook. --dry-run invokes no hooks and stays allowed.
# _find_state_file scans <state_dir>/runs/*/pipeline-state*.json, so the fixture
# has to sit in a per-run dir to be resolvable at all.
_ip_state="$TEST_TEMP_DIR/ip-state"
mkdir -p "$_ip_state/runs/live-1"
printf '{"run_id":"live-1","status":"in_progress","stage_statuses":{"plugin-stage-a":"complete"}}' \
    > "$_ip_state/runs/live-1/pipeline-state.json"

_ip_rc=0
_ip_out="$(ZBUILD_STATE_DIR="$_ip_state" \
    ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/ip-events.jsonl" \
    ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
    ZBUILD_PLUGINS_ROOT="$TEST_TEMP_DIR" \
    bash "$ZBUILD_CLI" clean --run-id live-1 2>&1)" || _ip_rc=$?
assert_eq "clean on an in-progress run exits rc=2" "2" "$_ip_rc"
assert_contains "clean names the in-progress run in its refusal" \
    "$_ip_out" "still in progress"

_ip_dry_rc=0
ZBUILD_STATE_DIR="$_ip_state" \
    ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/ip-events.jsonl" \
    ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
    ZBUILD_PLUGINS_ROOT="$TEST_TEMP_DIR" \
    bash "$ZBUILD_CLI" clean --run-id live-1 --dry-run >/dev/null 2>&1 || _ip_dry_rc=$?
assert_eq "clean --dry-run on an in-progress run is still allowed (no hooks run)" \
    "0" "$_ip_dry_rc"

print_test_results
exit $((FAIL > 0))
