#!/usr/bin/env bash
# Tests: ADR-056 — run+cleanup-only lifecycle contract (issue #1828)
# Covers SPEC-1 through SPEC-5.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"

print_test_header "plugin-hook-contract — ADR-056 run+cleanup-only lifecycle"

setup_test_env "plugin-hook-contract"

# ─── SPEC-1: hooks.init absent from all plugin manifests ─────────────────────
# CHANGE: before ADR-056, 27+ plugin manifests declared hooks.init;
# this assertion fails at that baseline.
_init_count=0
while IFS= read -r _mf; do
    if grep -qE "^\s+init:" "$_mf" 2>/dev/null; then
        _init_count=$((_init_count + 1))
    fi
done < <(find "$REPO_ROOT/plugins" -name "manifest.yaml" 2>/dev/null)
assert_eq "[SPEC-1] no plugin manifest declares hooks.init (ADR-056)" "0" "$_init_count"

# ─── SPEC-2: hooks.finalize absent from all plugin manifests ─────────────────
# CHANGE: before ADR-056, plugin manifests declared hooks.finalize;
# this assertion fails at that baseline.
_fin_count=0
while IFS= read -r _mf; do
    if grep -qE "^\s+finalize:" "$_mf" 2>/dev/null; then
        _fin_count=$((_fin_count + 1))
    fi
done < <(find "$REPO_ROOT/plugins" -name "manifest.yaml" 2>/dev/null)
assert_eq "[SPEC-2] no plugin manifest declares hooks.finalize (ADR-056)" "0" "$_fin_count"

# ─── SPEC-3: validate_manifest names the plugin when hooks.run is missing ────
# CHANGE: before ADR-056, validate_manifest error was generic; now it names the
# specific plugin that is missing the required hook.
_spec3_dir="$TEST_TEMP_DIR/spec3"
mkdir -p "$_spec3_dir"
cat > "$_spec3_dir/manifest.yaml" <<'EOF'
id: spec3-missing-run
name: Spec3 Missing Run
kind: tool
version: 0.0.1
hooks:
  cleanup: s3_cleanup
EOF
set +e
_spec3_err="$(validate_manifest "$_spec3_dir/manifest.yaml" 2>&1)"
_spec3_rc=$?
set -e
assert_eq "[SPEC-3] validate_manifest rejects manifest missing hooks.run (rc=1)" "1" "$_spec3_rc"
if grep -q "spec3-missing-run" <<< "$_spec3_err"; then
    assert_pass "[SPEC-3] validate_manifest error message names the failing plugin"
else
    assert_fail "[SPEC-3] validate_manifest error message names the failing plugin" \
        "got: $_spec3_err"
fi

# ─── SPEC-4: absent optional cleanup hook → rc=ZBUILD_HOOK_ABSENT (3) + event ─
# CHANGE: before ADR-056, absent cleanup returned 0 (indistinguishable from
# success). Now it returns 3 and emits plugin.cleanup.absent.
_spec4_dir="$TEST_TEMP_DIR/spec4"
mkdir -p "$_spec4_dir"
cat > "$_spec4_dir/manifest.yaml" <<'EOF'
id: spec4-no-cleanup
name: Spec4 No Cleanup
kind: tool
version: 0.0.1
hooks:
  run: s4_run
EOF
cat > "$_spec4_dir/plugin.sh" <<'EOF'
s4_run() { echo "ran"; }
EOF

# Redirect events to a temp file to capture the sentinel event.
_spec4_events="$TEST_TEMP_DIR/spec4-events.jsonl"
_old_events_dir="${ZBUILD_EVENTS_DIR:-}"
_old_events_jsonl="${ZBUILD_EVENTS_JSONL:-}"
_old_events_db="${ZBUILD_EVENTS_DB:-}"
ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR"
ZBUILD_EVENTS_JSONL="$_spec4_events"
ZBUILD_EVENTS_DB="/dev/null"

set +e
plugin_hook_call "$_spec4_dir" "cleanup" >/dev/null 2>&1
_spec4_rc=$?
set -e

ZBUILD_EVENTS_DIR="$_old_events_dir"
ZBUILD_EVENTS_JSONL="$_old_events_jsonl"
ZBUILD_EVENTS_DB="$_old_events_db"

assert_eq "[SPEC-4] absent cleanup returns ZBUILD_HOOK_ABSENT (3)" "3" "$_spec4_rc"
if [[ -f "$_spec4_events" ]] && grep -q '"plugin.cleanup.absent"' "$_spec4_events"; then
    assert_pass "[SPEC-4] absent cleanup emits plugin.cleanup.absent event"
else
    assert_fail "[SPEC-4] absent cleanup emits plugin.cleanup.absent event" \
        "events: $(cat "$_spec4_events" 2>/dev/null || echo 'none')"
fi

# ─── SPEC-5: absent required hook (run) → non-zero exit ──────────────────────
# CHANGE: before ADR-056 an absent hook returned 0 for every hook name; a required
# hook that is not declared must now be a failure, not a silent no-op.
_spec5_dir="$TEST_TEMP_DIR/spec5"
mkdir -p "$_spec5_dir"
cat > "$_spec5_dir/manifest.yaml" <<'EOF'
id: spec5-no-run
name: Spec5 No Run
kind: tool
version: 0.0.1
hooks:
  cleanup: s5_cleanup
EOF
cat > "$_spec5_dir/plugin.sh" <<'EOF'
s5_cleanup() { echo "cleanup"; }
EOF

set +e
plugin_hook_call "$_spec5_dir" "run" >/dev/null 2>&1
_spec5_rc=$?
set -e
if [[ "$_spec5_rc" -ne 0 ]]; then
    assert_pass "[SPEC-5] absent required hook (run) returns non-zero"
else
    assert_fail "[SPEC-5] absent required hook (run) returns non-zero" "got rc=0"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
