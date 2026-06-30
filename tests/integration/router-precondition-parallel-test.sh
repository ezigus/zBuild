#!/usr/bin/env bash
# Tests: core/router/route.sh — C6 precondition is PARALLEL-SAFE (ADR-039 §3).
#
# Parallel-group members (core/pipeline/parallel-orchestrator.sh) run
# concurrently and emit interleaved events to the SHARED run-level event log.
# A sibling member's `plugin.run.start` can therefore become the most-recent
# GLOBAL event for the run before any one member emits its own
# `redaction.applied`. The old run-level C6 check failed all members in that
# case (dogfood run 20260629214235-33569). The fix scopes C6 to the active
# stage (ZBUILD_CURRENT_STAGE, stamped onto every event's envelope) so each
# member enforces ITS OWN redaction independently — without weakening ADR-004.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "router C6 precondition — parallel-group safety (ADR-039 §3, per-stage scoping)"

setup_test_env "router-precondition-parallel"

EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_DIR="$EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
mkdir -p "$EVENTS_DIR"

# ─── Mock claude (success) ────────────────────────────────────────────────────
cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
echo "OK-RESPONSE"
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"

source "$REPO_ROOT/core/router/route.sh"

export ZBUILD_RUN_ID="precond-parallel-$$"

# _emit <type> <stage> — append an envelope-shaped event with a top-level
# `stage` field (exactly what eb_emit_event now stamps from ZBUILD_CURRENT_STAGE).
_emit() {
    jq -cn --arg rid "$ZBUILD_RUN_ID" --arg type "$1" --arg stage "$2" \
        '{ts:"2026-01-01T00:00:00Z", run_id:$rid, issue:0, type:$type,
          plugin:"", kind:"", stage:$stage, data:{}, schema_version:1}' \
        >> "$ZBUILD_EVENTS_JSONL"
}

# Simulate the interleaving observed in the dogfood failure: member A finishes
# its redaction, then sibling member B starts — so B's plugin.run.start is the
# most-recent GLOBAL event for the run, but A's redaction.applied is the
# most-recent event FOR A's stage.
: > "$ZBUILD_EVENTS_JSONL"
_emit "plugin.run.start" "review-lens-a"
_emit "redaction.applied" "review-lens-a"
_emit "plugin.run.start" "review-lens-b"   # GLOBAL most-recent (a sibling's)

# ─── Test 1: member A's OWN redaction is most-recent FOR-ITS-STAGE → C6 passes
export ZBUILD_CURRENT_STAGE="review-lens-a"
set +e
out="$(route_to_model "T2" "ping" 2>/dev/null)"
rc=$?
set -e
assert_eq "member A: own redaction.applied is most-recent for its stage → C6 passes (rc=0)" "0" "$rc"
assert_eq "member A: response passthrough" "OK-RESPONSE" "$out"

route_a_fired="$(jq -r --arg rid "$ZBUILD_RUN_ID" \
    'select(.run_id==$rid and .type=="model.route") | .type' "$ZBUILD_EVENTS_JSONL" 2>/dev/null \
    | grep -c "model.route" || true)"
assert_gt "member A: model.route emitted once C6 satisfied per-stage" "$route_a_fired" "0"

# ─── Test 2: baseline proof — WITHOUT per-stage scoping (no ZBUILD_CURRENT_STAGE)
# the same shared log fails C6, because the global most-recent event is the
# sibling's plugin.run.start. This is the bug the fix cures.
: > "$ZBUILD_EVENTS_JSONL"
_emit "plugin.run.start" "review-lens-a"
_emit "redaction.applied" "review-lens-a"
_emit "plugin.run.start" "review-lens-b"

unset ZBUILD_CURRENT_STAGE
set +e
out="$(route_to_model "T2" "ping" 2>/dev/null)"
rc=$?
set -e
assert_eq "no stage scope: global most-recent is sibling's plugin.run.start → C6 violates (rc=2)" "2" "$rc"

# ─── Test 3: ADR-004 NOT weakened — a member CANNOT ride a sibling's redaction.
# Member B's most-recent for-its-stage event is its own plugin.run.start (B has
# not redacted yet); only sibling A has redaction.applied. C6 must FAIL for B.
: > "$ZBUILD_EVENTS_JSONL"
_emit "plugin.run.start" "review-lens-a"
_emit "redaction.applied" "review-lens-a"
_emit "plugin.run.start" "review-lens-b"   # B's own most-recent: no redaction

export ZBUILD_CURRENT_STAGE="review-lens-b"
set +e
out="$(route_to_model "T2" "ping" 2>/dev/null)"
rc=$?
set -e
assert_eq "member B: own last event is plugin.run.start (no redaction for B) → C6 violates (rc=2)" "2" "$rc"

violated_b="$(jq -r --arg rid "$ZBUILD_RUN_ID" \
    'select(.run_id==$rid and .type=="router.precondition.violated") | .data.stage // empty' \
    "$ZBUILD_EVENTS_JSONL" 2>/dev/null | tail -1 || true)"
assert_eq "member B: violation event tagged with offending stage" "review-lens-b" "$violated_b"

# ─── Test 4: a member whose stage has NO events yet → fail-closed (#289) ──────
: > "$ZBUILD_EVENTS_JSONL"
_emit "plugin.run.start" "review-lens-a"
_emit "redaction.applied" "review-lens-a"

export ZBUILD_CURRENT_STAGE="review-lens-c"   # no events for this stage at all
set +e
out="$(route_to_model "T2" "ping" 2>/dev/null)"
rc=$?
set -e
assert_eq "member C: no events for its stage → C6 refuses fail-closed (rc=2)" "2" "$rc"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
