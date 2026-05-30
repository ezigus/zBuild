#!/usr/bin/env bash
# Unit test (#509): assert all 5 new apply-check / invariant event types are
# registered in config/event-schema.json::known_types.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "build #509: event-schema registers apply-check events"

SCHEMA="$REPO_ROOT/config/event-schema.json"

for et in \
    build.apply_check.failed \
    build.apply_check.skipped \
    build.apply_check.unavailable \
    build.apply_check.precondition_failed \
    build.invariant.diff_is_stub ; do
    if jq -e --arg t "$et" '.known_types | index($t)' "$SCHEMA" >/dev/null 2>&1; then
        assert_pass "schema: known_types contains $et"
    else
        assert_fail "schema: known_types contains $et" "missing in $SCHEMA"
    fi
done

print_test_results
exit $((FAIL > 0))
