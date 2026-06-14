#!/usr/bin/env bash
# Tests: every event type emitted by the cq-* plugins is registered
# in config/event-schema.json known_types.  Scoped to cq-* plugins so the
# test fails before the 12 cq.* types are added and passes after.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "event-schema emitted-⊆-known_types (cq-* plugins)"

SCHEMA="$REPO_ROOT/config/event-schema.json"

# Grep only string-literal event types (no $ chars) from the cq-* plugins.
# Matches lines: eb_emit_event "cq.something.event" ...
_emitted_types="$(grep -rh \
    -E 'eb_emit_event[[:space:]]+"[a-z][a-z0-9._-]+"' \
    "$REPO_ROOT/plugins/agent/cq-preflight/" \
    "$REPO_ROOT/plugins/agent/cq-audit-plan/" \
    "$REPO_ROOT/plugins/agent/cq-cycle/" \
    "$REPO_ROOT/plugins/agent/cq-backtrack/" \
    2>/dev/null \
    | sed -E 's/.*eb_emit_event[[:space:]]+"([a-z][a-z0-9._-]+)".*/\1/' \
    | sort -u \
    || true)"

if [[ -z "$_emitted_types" ]]; then
    assert_fail "emitted-coverage: extraction" "no eb_emit_event literal sites found in cq-* plugins"
    print_test_results
    exit $((FAIL > 0))
fi

_known_types="$(jq -r '.known_types[]' "$SCHEMA")"

_missing=()
while IFS= read -r _type; do
    [[ -z "$_type" ]] && continue
    if ! printf '%s\n' "$_known_types" | grep -qxF "$_type"; then
        _missing+=("$_type")
    fi
done <<< "$_emitted_types"

if [[ ${#_missing[@]} -eq 0 ]]; then
    assert_pass "all emitted cq-* event types are registered in known_types"
else
    for _t in "${_missing[@]}"; do
        assert_fail "emitted type '$_t' is registered in known_types" \
            "not found in config/event-schema.json"
    done
fi

print_test_results
exit $((FAIL > 0))
