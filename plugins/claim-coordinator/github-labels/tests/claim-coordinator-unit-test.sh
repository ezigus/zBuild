#!/usr/bin/env bash
# Tests: plugins/claim-coordinator/github-labels/plugin.sh — local-fs backend (Wave 4)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"

print_test_header "plugin: claim-coordinator/github-labels — local-fs backend"
setup_test_env "claim-coordinator-unit"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

# Use local-fs backend so tests never call gh
export ZBUILD_CLAIM_BACKEND="local-fs"
export ZBUILD_CLAIM_STORE="$TEST_TEMP_DIR/claim-store"
export ZBUILD_CLAIM_MACHINE_ID="test-machine-1"

# shellcheck source=../../../../plugins/claim-coordinator/github-labels/plugin.sh
source "$REPO_ROOT/plugins/claim-coordinator/github-labels/plugin.sh"

# ── claim issue 42 → rc=0 ─────────────────────────────────────────────────────
: > "$ZBUILD_EVENTS_JSONL"
set +e; claim_coordinator_claim "42"; rc=$?; set -e
assert_eq "claim_coordinator_claim → rc=0" "0" "$rc"

# ── label file created after claim ───────────────────────────────────────────
labels_file="$ZBUILD_CLAIM_STORE/42/labels.txt"
if [[ -f "$labels_file" ]]; then
    assert_pass "claim store file created after claim"
else
    assert_fail "claim store file created after claim" "file not found: $labels_file"
fi

# ── label contains claimed:<machine> pattern ─────────────────────────────────
if grep -q "claimed:" "$labels_file" 2>/dev/null; then
    assert_pass "claimed label contains 'claimed:' prefix"
else
    assert_fail "claimed label contains 'claimed:' prefix" "$(cat "$labels_file" 2>/dev/null || echo '<empty>')"
fi

# ── release → rc=0 and label removed ─────────────────────────────────────────
: > "$ZBUILD_EVENTS_JSONL"
set +e; claim_coordinator_release "42"; rc=$?; set -e
assert_eq "claim_coordinator_release → rc=0" "0" "$rc"

remaining="$({ grep "claimed:" "$labels_file" 2>/dev/null || true; } | wc -l | tr -d ' \n')"
assert_eq "claimed label removed after release" "0" "$remaining"

# ── list_claims returns empty JSON array after release ────────────────────────
: > "$ZBUILD_EVENTS_JSONL"
list_out="$(claim_coordinator_list_claims 2>/dev/null || true)"
assert_eq "list_claims returns [] after release" "[]" "$list_out"

# ── heartbeat → rc=0 ─────────────────────────────────────────────────────────
: > "$ZBUILD_EVENTS_JSONL"
claim_coordinator_claim "99" 2>/dev/null
set +e; claim_coordinator_heartbeat "99"; rc=$?; set -e
assert_eq "claim_coordinator_heartbeat → rc=0" "0" "$rc"

cleanup_test_env
print_test_results
