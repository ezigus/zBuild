#!/usr/bin/env bash
# Tests: cycle-* event registrations in config/event-schema.json (ADR-021, #512)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "cycle events — schema registrations (ADR-021)"
setup_test_env "cycle-events"

SCHEMA="$REPO_ROOT/config/event-schema.json"

# All cycle events that MUST be registered per ADR-021 §Event-schema additions
required_events=(
    "cycle.start"
    "cycle.complete"
    "cycle.plateau"
    "cycle.divergence"
    "cycle.iteration.complete"
    "cycle.aborted"
    "cycle.config.invalid"
    "cycle.feedback.missing"
    "cycle.iteration.verdict_missing"
    "cycle.history.lost"
    "cycle.metric.invalid"
    "cycle.plateau.skipped"
    "cycle.iter.stale_artifact"
)

for ev in "${required_events[@]}"; do
    if jq -e --arg t "$ev" '.known_types | index($t)' "$SCHEMA" >/dev/null 2>&1; then
        assert_pass "event registered: $ev"
    else
        assert_fail "event registered: $ev" "missing from known_types"
    fi
done

print_test_results
