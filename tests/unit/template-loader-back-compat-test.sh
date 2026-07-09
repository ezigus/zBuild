#!/usr/bin/env bash
# Tests: ADR-027 back-compat shim — pre-ADR-027 (Wave 15-D era) shape still
# loads correctly and emits `template.deprecated_shape` event (Wave 17-B, #703)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "template loader — back-compat shim (Wave 17-B / ADR-027)"
setup_test_env "template-loader-back-compat"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
: > "$ZBUILD_EVENTS_JSONL"

# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"

OLD_TPL="$TEST_TEMP_DIR/old-shape.yaml"
cat > "$OLD_TPL" <<'EOF'
id: old-shape
name: Old Shape Pipeline
extends: null
defaults:
  strategy: fanout

stages:
  - id: intake
    gate: auto
    roles: [intake]
  - id: plan
    gate: auto
    roles: [planner]
  - id: build_test_cycle
    type: cycle
    stages: [build, test]
    until:
      stage: test
      field: verdict
      op: eq
      value: pass
    max_iterations: 3
    on_max: continue
  - id: review
    gate: auto
    roles: [reviewer]

stage_definitions:
  build:
    roles: [builder]
  test:
    roles: [tester]
EOF

_TPL_STAGES=()
_TPL_CYCLES=()

set +e
load_template "$OLD_TPL"; rc=$?
set -e
assert_eq "T1: old shape loads rc=0" "0" "$rc"

joined="${_TPL_STAGES[*]}"
assert_eq "T2: stages flattened" \
    "intake plan build test review" "$joined"

assert_eq "T3: cycle captured" "build_test_cycle" "${_TPL_CYCLES[*]}"

# T4: deprecated_shape event emitted (best-effort — event bus may degrade
# without event schema; require either the event OR a stderr hint marker).
if [[ -s "$ZBUILD_EVENTS_JSONL" ]] && grep -q '"template.deprecated_shape"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_pass "T4: template.deprecated_shape event emitted"
else
    assert_fail "T4: template.deprecated_shape event emitted" \
        "events.jsonl missing template.deprecated_shape"
fi

# T5 (#979): standard.yaml (the last shipped old-shape template) is retired.
# The shim's "a real old-shape template reloads cleanly with stages populated"
# contract is now exercised against the owned OLD_TPL fixture (a second load,
# proving the shim is re-entrant and leaves _TPL_STAGES populated).
_TPL_STAGES=()
_TPL_CYCLES=()
: > "$ZBUILD_EVENTS_JSONL"
set +e
load_template "$OLD_TPL"; rc=$?
set -e
assert_eq "T5: old-shape template reloads via shim rc=0" "0" "$rc"
assert_eq "T5: reload leaves _TPL_STAGES populated" "1" \
    "$([[ ${#_TPL_STAGES[@]} -gt 0 ]] && echo 1 || echo 0)"

print_test_results
