#!/usr/bin/env bash
# Tests: every event type emitted (as a string literal) anywhere under
# plugins/agent/ + core/ is registered in config/event-schema.json known_types.
# Widened from the original cq-*-only scope (#862) to all stages + core (#915)
# after the #867 dogfood shipped an unregistered test_assessment event the
# cq-scoped test could not see.
#
# Coverage limitation: this matches only STRING-LITERAL event names. Three
# dynamic call sites emit via a variable and are structurally invisible here —
# core/pipeline/cycle-orchestrator.sh (`_cycle_emit` wrapper, eb_emit_event
# "$type"), core/event-bus/event-bus.sh (`eb_emit_event "$@"` pass-through),
# and core/router/route.sh (eb_emit_event "$override_event"). The literals that
# flow into those vars are emitted as literals elsewhere or already registered,
# so there is no hidden gap today — but a NEW dynamic-only type would slip past.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "event-schema emitted-⊆-known_types (all agent + core)"

SCHEMA="$REPO_ROOT/config/event-schema.json"

# Grep string-literal event types (no $ chars) from all agent plugins + core.
# Matches both `emit_event "x.y"` and the `eb_emit_event "x.y"` core form (the
# `eb_` prefix is absorbed by the leading `.*`).
_emitted_types="$(grep -rh \
    -E 'emit_event[[:space:]]+"[a-z][a-z0-9._-]+"' \
    "$REPO_ROOT/plugins/agent/" \
    "$REPO_ROOT/core/" \
    2>/dev/null \
    | sed -E 's/.*emit_event[[:space:]]+"([a-z][a-z0-9._-]+)".*/\1/' \
    | sort -u \
    || true)"

if [[ -z "$_emitted_types" ]]; then
    assert_fail "emitted-coverage: extraction" "no emit_event literal sites found under plugins/agent + core"
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
    assert_pass "all emitted agent + core event types are registered in known_types"
else
    for _t in "${_missing[@]}"; do
        assert_fail "emitted type '$_t' is registered in known_types" \
            "not found in config/event-schema.json"
    done
fi

print_test_results
exit $((FAIL > 0))
