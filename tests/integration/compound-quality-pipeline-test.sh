#!/usr/bin/env bash
# Integration test: compound_quality migration — 4 CQ plugins (issue #755)
#
# Drives runner.sh against standard.yaml with stub plugins for all 14 leaf
# stages. Asserts the 5-trial test requirements for the CQ keeper migration:
#
#   T1: all 4 cq-* plugin.run.start events appear in events.jsonl
#   T2: cq-preflight runs before cq-audit-plan (ordering guard)
#   T3: removing cq-preflight/plugin.sh causes pipeline to fail with
#       'no plugin for stage cq-preflight' error (reproduces failure)
#   T4: cq-audit-plan runs before cq-cycle
#   T5: cq-backtrack runs after cq-cycle and before review
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER="$REPO_ROOT/core/pipeline/runner.sh"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "compound_quality migration — 4 CQ leaf-stage plugins (issue #755)"
setup_test_env "compound-quality-pipeline-755"
export ZBUILD_CONTRACT_VALIDATOR=warn
export ZBUILD_CYCLES_ENABLED=0

PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
STATE_DIR="$TEST_TEMP_DIR/state"
EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT"
export ZBUILD_STATE_DIR="$STATE_DIR"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$EVENTS_JSONL"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$STATE_DIR" "$TEST_TEMP_DIR/events"

# Minimal stub plugin factory — logs stage.run to events.jsonl via exit 0.
_make_stub() {
    local id="$1" kind="${2:-agent}"
    local dir="$PLUGINS_ROOT/$kind/$id"
    mkdir -p "$dir"
    local fn="${id//-/_}_run"
    cat > "$dir/manifest.yaml" <<EOF
id: $id
name: Stub $id
kind: $kind
version: 0.0.1
hooks:
  run: $fn
requires:
  core:
    - redaction
EOF
    printf '%s() { return 0; }\n' "$fn" > "$dir/plugin.sh"
}

# Create stubs for all 14 leaf stages in standard.yaml (#922: + acceptance-gate;
# #756: + pr). The pr stub is REQUIRED — without it the runner falls through to
# the real pr-delivery agent, which invokes `gh pr create` and hangs on CI
# runners with no gh auth/network (this hung the macOS integration leg, #996).
for s in intake plan impact design build test_assessment acceptance-gate review \
          cq-preflight cq-audit-plan cq-cycle cq-backtrack pr; do
    _make_stub "$s"
done
_make_stub "test" "tool"


# ─── T1: all 4 cq-* plugin.run.start events appear in events.jsonl ──────────
rm -f "$EVENTS_JSONL" "$STATE_DIR/pipeline-state.json"
set +e; bash "$RUNNER" --issue 755 >/dev/null 2>&1; rc=$?; set -e

for cq_stage in cq-preflight cq-audit-plan cq-cycle cq-backtrack; do
    cq_start=$(grep -c "\"plugin.run.start\"" "$EVENTS_JSONL" 2>/dev/null | \
        { grep -c "\"$cq_stage\"" "$EVENTS_JSONL" 2>/dev/null || true; })
    stage_appeared=$(grep '"stage.start"' "$EVENTS_JSONL" 2>/dev/null | \
        grep -c "\"$cq_stage\"" 2>/dev/null || true)
    assert_eq "T1: $cq_stage stage.start appears in events.jsonl" "1" "$stage_appeared"
done

# ─── T2: cq-preflight runs before cq-audit-plan (ordering guard) ─────────────
preflight_line=$(grep -n '"stage.start"' "$EVENTS_JSONL" 2>/dev/null | \
    grep '"cq-preflight"' | head -1 | cut -d: -f1 || echo 0)
auditplan_line=$(grep -n '"stage.start"' "$EVENTS_JSONL" 2>/dev/null | \
    grep '"cq-audit-plan"' | head -1 | cut -d: -f1 || echo 0)
if [[ -n "$preflight_line" && -n "$auditplan_line" && \
      "$preflight_line" -lt "$auditplan_line" ]]; then
    assert_pass "T2: cq-preflight runs before cq-audit-plan"
else
    assert_fail "T2: cq-preflight runs before cq-audit-plan" \
        "preflight_line=$preflight_line auditplan_line=$auditplan_line"
fi

# ─── T3: removing cq-preflight/plugin.sh causes pipeline to fail ─────────────
rm -f "$PLUGINS_ROOT/agent/cq-preflight/plugin.sh"
rm -f "$EVENTS_JSONL" "$STATE_DIR/pipeline-state.json"
set +e; bash "$RUNNER" --issue 755 >/dev/null 2>&1; rc_t3=$?; set -e
assert_eq "T3: missing cq-preflight plugin causes pipeline failure (rc!=0)" "1" "$rc_t3"
# Restore for subsequent tests
_make_stub "cq-preflight"

# ─── T4: cq-audit-plan runs before cq-cycle ──────────────────────────────────
rm -f "$EVENTS_JSONL" "$STATE_DIR/pipeline-state.json"
set +e; bash "$RUNNER" --issue 755 >/dev/null 2>&1; set -e
auditplan_line=$(grep -n '"stage.start"' "$EVENTS_JSONL" 2>/dev/null | \
    grep '"cq-audit-plan"' | head -1 | cut -d: -f1 || echo 0)
cycle_line=$(grep -n '"stage.start"' "$EVENTS_JSONL" 2>/dev/null | \
    grep '"cq-cycle"' | head -1 | cut -d: -f1 || echo 0)
if [[ -n "$auditplan_line" && -n "$cycle_line" && \
      "$auditplan_line" -lt "$cycle_line" ]]; then
    assert_pass "T4: cq-audit-plan runs before cq-cycle"
else
    assert_fail "T4: cq-audit-plan runs before cq-cycle" \
        "auditplan_line=$auditplan_line cycle_line=$cycle_line"
fi

# ─── T5: cq-backtrack runs after cq-cycle and before review ──────────────────
cycle_line=$(grep -n '"stage.complete"' "$EVENTS_JSONL" 2>/dev/null | \
    grep '"cq-cycle"' | head -1 | cut -d: -f1 || echo 0)
backtrack_line=$(grep -n '"stage.start"' "$EVENTS_JSONL" 2>/dev/null | \
    grep '"cq-backtrack"' | head -1 | cut -d: -f1 || echo 0)
review_line=$(grep -n '"stage.start"' "$EVENTS_JSONL" 2>/dev/null | \
    grep '"review"' | head -1 | cut -d: -f1 || echo 0)
if [[ -n "$cycle_line" && -n "$backtrack_line" && -n "$review_line" && \
      "$cycle_line" -lt "$backtrack_line" && "$backtrack_line" -lt "$review_line" ]]; then
    assert_pass "T5: cq-backtrack runs after cq-cycle and before review"
else
    assert_fail "T5: cq-backtrack runs after cq-cycle and before review" \
        "cycle_complete=$cycle_line backtrack_start=$backtrack_line review_start=$review_line"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
