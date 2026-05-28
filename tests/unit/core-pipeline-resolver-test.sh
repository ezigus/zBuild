#!/usr/bin/env bash
# Tests: core/pipeline/resolver.sh — role-based plugin resolver (ADR-009)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/pipeline/resolver — role-based plugin resolver (ADR-009)"
setup_test_env "pipeline-resolver"

# Use shared factory from test-helpers.sh (Wave 4)
_make_plugin() { mock_plugin_factory "$@"; }

# ─── Shared env — point all subsystems at the test temp dir ─────────────────
export ZBUILD_PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$TEST_TEMP_DIR/events"

# Source the module under test (after env is set so event-bus picks up dirs).
# shellcheck source=../core/pipeline/resolver.sh
source "$REPO_ROOT/core/pipeline/resolver.sh"

# ─── Test 1: role match → generic plugin returned ────────────────────────────
_make_plugin "auditor-generic" "agent" 0 "" "security-auditor" "1.0.0"

set +e
result="$(resolve_plugin_for_role "security-auditor" 2>/dev/null)"
rc=$?
set -e

assert_eq "generic role match returns rc=0" "0" "$rc"
assert_contains "generic role match returns plugin dir" "$result" "auditor-generic"

# ─── Test 2: platform-specific plugin wins over generic ──────────────────────
_make_plugin "auditor-ios"     "agent" 0 "ios" "security-auditor" "1.0.0"
# auditor-generic (created above) is the generic competitor

set +e
result="$(resolve_plugin_for_role "security-auditor" "ios" 2>/dev/null)"
rc=$?
set -e

assert_eq "platform match returns rc=0" "0" "$rc"
assert_contains "platform-specific plugin wins over generic" "$result" "auditor-ios"

# ─── Test 3: generic fallback when platform-specific missing ─────────────────
# auditor-generic has no platform; no android-specific plugin exists.
set +e
result="$(resolve_plugin_for_role "security-auditor" "android" 2>/dev/null)"
rc=$?
set -e

assert_eq "generic fallback returns rc=0" "0" "$rc"
assert_contains "generic fallback returned when platform-specific missing" "$result" "auditor-generic"

# ─── Test 4: no match → returns 1 ────────────────────────────────────────────
set +e
resolve_plugin_for_role "nonexistent-role" >/dev/null 2>&1
rc=$?
set -e

assert_eq "no match returns rc=1" "1" "$rc"

# ─── Test 5: no match emits registry.role-unresolved event ───────────────────
# Clear the event log, then trigger another no-match.
: > "$ZBUILD_EVENTS_JSONL"

set +e
resolve_plugin_for_role "still-nonexistent" >/dev/null 2>&1
set -e

event_count=$(grep -c '"registry.role-unresolved"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)
assert_gt "registry.role-unresolved event emitted on no match" "$event_count" "0"
assert_event_emitted "registry.role-unresolved event via assert_event_emitted" "$ZBUILD_EVENTS_JSONL" "registry.role-unresolved"

# ─── Test 6: tie-break by version — higher version wins ──────────────────────
_make_plugin "coder-old" "agent" 0 "" "coder" "0.1.0"
_make_plugin "coder-new" "agent" 0 "" "coder" "0.2.0"

set +e
result="$(resolve_plugin_for_role "coder" 2>/dev/null)"
rc=$?
set -e

assert_eq "version tie-break returns rc=0" "0" "$rc"
assert_contains "higher version wins tie-break" "$result" "coder-new"

# ─── Test 7: tie-break by id — alphabetically first id wins ──────────────────
_make_plugin "coder-a" "agent" 0 "" "coder-tie" "1.0.0"
_make_plugin "coder-b" "agent" 0 "" "coder-tie" "1.0.0"

set +e
result="$(resolve_plugin_for_role "coder-tie" 2>/dev/null)"
rc=$?
set -e

assert_eq "id tie-break returns rc=0" "0" "$rc"
assert_contains "alphabetically first id wins tie-break" "$result" "coder-a"

# ─── Test 8: resolve with no platform arg ────────────────────────────────────
_make_plugin "intake-generic" "agent" 0 "" "intake" "1.0.0"

set +e
result="$(resolve_plugin_for_role "intake" 2>/dev/null)"
rc=$?
set -e

assert_eq "no platform arg returns rc=0" "0" "$rc"
assert_contains "no platform arg resolves generic plugin" "$result" "intake-generic"

# ─── Teardown ────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
exit $((FAIL > 0))
