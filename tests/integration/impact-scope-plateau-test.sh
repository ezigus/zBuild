#!/usr/bin/env bash
# Integration test (#936): impact converges design_impact_cycle when it is only
# re-flagging real-but-irrelevant COLLATERAL adjacents in a true plateau.
#
# Drives impact_run end-to-end (through the #781 floor + #911 drop + the #936
# backstop). iter 1 records the non-floor set and stays incomplete; iter 2 with
# the SAME set flips verdict->complete and emits impact.scope.plateau.
#
#   P1: iter 1 (ZBUILD_CYCLE_ITER=1) -> verdict=incomplete, sidecar written
#   P2: iter 2 (ZBUILD_CYCLE_ITER=2, same set) -> verdict=complete (backstop)
#   P3: impact.scope.plateau emitted on iter 2
#   P4 (control): iter 2 with a STRUCTURAL file in the set -> stays incomplete
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "impact over-scope convergence #936 — collateral plateau"
setup_test_env "impact-scope-plateau-it"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"

PLUGIN_DIR="$REPO_ROOT/plugins/agent/impact"
STATE_DIR="$TEST_TEMP_DIR/state"
ARTIFACTS_DIR="$STATE_DIR/artifacts"
mkdir -p "$STATE_DIR" "$ARTIFACTS_DIR"

cat > "$STATE_DIR/scope-manifest.md" <<'SCOPE'
+ config/
+ core/
+ plugins/
+ tests/
SCOPE

# Non-shape design + plan so the #781/#881 floor stays inert.
cat > "$ARTIFACTS_DIR/design.md" <<'DESIGN'
# Design

```scope
plugins/agent/foo/plugin.sh
```
DESIGN
cat > "$ARTIFACTS_DIR/plan.json" <<'PLAN'
{"schema_version":1,"title":"non-shape","goal":"g","steps":[{"id":"step-1","description":"edit foo","files":["plugins/agent/foo/plugin.sh"],"estimated_lines":3}],"estimated_total_lines":3,"notes":""}
PLAN

# shellcheck source=../../plugins/agent/impact/plugin.sh
source "$PLUGIN_DIR/plugin.sh"

apply_scope_redaction() { cat "$1" > "$2"; return 0; }

# A real, existing COLLATERAL (tests/) file so #911 keeps it and the backstop
# accepts it. Use this very test file.
COLLATERAL_REL="tests/integration/impact-scope-plateau-test.sh"
CANNED_IMPACT_RESPONSE="{\"schema_version\":1,\"verdict\":\"incomplete\",\"missing\":[{\"step_id\":\"s1\",\"files_to_add\":[\"$COLLATERAL_REL\"],\"reason\":\"adjacent\"}],\"impact_feedback_md\":\"gap\"}"
route_to_model() { printf '%s' "$CANNED_IMPACT_RESPONSE"; return 0; }

export ZBUILD_REPO_ROOT="$REPO_ROOT"
STATE_FILE="$STATE_DIR/pipeline-state.json"
printf '%s' '{"schema_version":1,"run_id":"t936","issue":"936","stage_statuses":{}}' > "$STATE_FILE"

# ─── P1: iter 1 records the set, stays incomplete ───────────────────────────
: > "$ZBUILD_EVENTS_JSONL"
export ZBUILD_CYCLE_ITER=1
set +e; impact_run "impact" "$STATE_FILE" >/dev/null 2>&1; rc=$?; set -e
assert_eq "P1: iter1 impact_run rc=0" "0" "$rc"
assert_eq "P1: iter1 verdict stays incomplete (first pass never fires)" \
    "incomplete" "$(jq -r '.verdict' "$ARTIFACTS_DIR/impact.json" 2>/dev/null)"
assert_file_exists "P1: prior-missing sidecar written" "$ARTIFACTS_DIR/impact-prior-missing.txt"

# ─── P2/P3: iter 2 same set -> backstop converges + event ───────────────────
: > "$ZBUILD_EVENTS_JSONL"
export ZBUILD_CYCLE_ITER=2
set +e; impact_run "impact" "$STATE_FILE" >/dev/null 2>&1; rc=$?; set -e
assert_eq "P2: iter2 impact_run rc=0" "0" "$rc"
assert_eq "P2: iter2 collateral plateau -> verdict flips to complete" \
    "complete" "$(jq -r '.verdict' "$ARTIFACTS_DIR/impact.json" 2>/dev/null)"
_p3_plateau_n="$(grep -c 'impact.scope.plateau' "$ZBUILD_EVENTS_JSONL" 2>/dev/null)" || _p3_plateau_n=0
assert_eq "P3: impact.scope.plateau emitted exactly once" "1" \
    "$_p3_plateau_n"

# ─── P4 (control): a STRUCTURAL file in the set blocks convergence ──────────
rm -f "$ARTIFACTS_DIR/impact-prior-missing.txt"
CANNED_IMPACT_RESPONSE="{\"schema_version\":1,\"verdict\":\"incomplete\",\"missing\":[{\"step_id\":\"s1\",\"files_to_add\":[\"$COLLATERAL_REL\",\"scripts/lib/impact-prefilter.sh\"],\"reason\":\"adjacent\"}],\"impact_feedback_md\":\"gap\"}"
export ZBUILD_CYCLE_ITER=1
set +e; impact_run "impact" "$STATE_FILE" >/dev/null 2>&1; set -e
export ZBUILD_CYCLE_ITER=2
: > "$ZBUILD_EVENTS_JSONL"
set +e; impact_run "impact" "$STATE_FILE" >/dev/null 2>&1; set -e
# verdict is the authoritative no-fire signal end-to-end; the unit test
# (impact-scope-plateau-test.sh SPEC-2) covers the no-event case directly (the
# db-backed event bus re-materializes prior events into the JSONL, so a mid-test
# truncation can't isolate a single iter's emissions here).
assert_eq "P4: structural (scripts/lib) in set -> stays incomplete (no false converge)" \
    "incomplete" "$(jq -r '.verdict' "$ARTIFACTS_DIR/impact.json" 2>/dev/null)"

unset ZBUILD_CYCLE_ITER
cleanup_test_env
print_test_results
exit $((FAIL > 0))
