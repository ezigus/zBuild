#!/usr/bin/env bash
# Tests: plugins/tool/health-check — health-check tool unit tests (issue #757)
#
# SPEC-HC1: dry-run returns 0 (mock 200 response, no curl)
# SPEC-HC2: empty ZBUILD_HEALTH_CHECK_URL → rc!=0 (no probe target)
# SPEC-HC3: non-http(s) scheme (SSRF guard) → rc!=0, curl never runs (#757 review fix)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugin: health-check tool (kind:tool, SSRF guard, issue #757)"
setup_test_env "plugin-health-check"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_RUN_ID="hc-test-$$"

# shellcheck source=../../../../plugins/tool/health-check/plugin.sh
source "$REPO_ROOT/plugins/tool/health-check/plugin.sh"

# no-op event emission (no backend needed for these unit tests)
emit_event() { return 0; }

# ---------------------------------------------------------------------------
# SPEC-HC1: dry-run → rc=0 without touching the network
# ---------------------------------------------------------------------------
_rc=0
ZBUILD_DRY_RUN=1 health_check_run "validate" "/tmp/none" >/dev/null 2>&1 || _rc=$?
assert_eq "[SPEC-HC1] dry-run health probe returns 0" "0" "$_rc"

# ---------------------------------------------------------------------------
# SPEC-HC2: empty probe URL → rc!=0 (no target)
# ---------------------------------------------------------------------------
_rc=0
ZBUILD_DRY_RUN=0 ZBUILD_HEALTH_CHECK_URL="" \
    health_check_run "validate" "/tmp/none" >/dev/null 2>&1 || _rc=$?
assert_gt "[SPEC-HC2] empty probe URL → rc != 0" "$_rc" "0"

# ---------------------------------------------------------------------------
# SPEC-HC3: SSRF guard — non-http(s) schemes rejected before curl runs
# ---------------------------------------------------------------------------
_rc=0
ZBUILD_DRY_RUN=0 ZBUILD_HEALTH_CHECK_URL="file:///etc/passwd" \
    health_check_run "validate" "/tmp/none" >/dev/null 2>&1 || _rc=$?
assert_gt "[SPEC-HC3] file:// scheme rejected (SSRF guard) → rc != 0" "$_rc" "0"

_rc=0
ZBUILD_DRY_RUN=0 ZBUILD_HEALTH_CHECK_URL="gopher://169.254.169.254/" \
    health_check_run "validate" "/tmp/none" >/dev/null 2>&1 || _rc=$?
assert_gt "[SPEC-HC3] gopher:// scheme rejected (SSRF guard) → rc != 0" "$_rc" "0"

# a valid http(s) scheme must get PAST the guard (proves the guard is not
# reject-all): probe an almost-certainly-closed local port and assert the output
# is NOT the scheme-rejection message (curl then fails on the unreachable host).
_hc_out="$(ZBUILD_DRY_RUN=0 ZBUILD_HEALTH_CHECK_URL="https://127.0.0.1:9/zbuild-hc-probe" \
    health_check_run "validate" "/tmp/none" 2>&1 || true)"
if grep -q "refusing non-http" <<< "$_hc_out"; then
    assert_fail "[SPEC-HC3] https:// scheme passes the guard (not scheme-rejected)" \
        "https URL was scheme-rejected: $_hc_out"
else
    assert_pass "[SPEC-HC3] https:// scheme passes the guard (reaches probe, not rejected)"
fi

_test_cleanup_hook() { cleanup_test_env; }

print_test_results
exit $((FAIL > 0))
