#!/usr/bin/env bash
# Tests: core/router/route.sh — redaction by construction is PARALLEL-SAFE
# (ADR-043 + ADR-039 §3).
#
# Parallel-group members (core/pipeline/parallel-orchestrator.sh) run
# concurrently and emit interleaved events to the SHARED run-level event log.
# Under ADR-043 the router redacts each member's prompt by construction: the
# per-stage "already redacted?" check (scoped to ZBUILD_CURRENT_STAGE, stamped
# onto every event) is now a DEDUP guard, not a refusal gate. A member that
# already redacted (its own redaction.applied is most-recent FOR ITS STAGE)
# proceeds without re-redacting; a member that has NOT redacted gets its OWN
# router redaction — it never rides a sibling's redaction (ADR-004 preserved),
# and it is never blocked by a sibling's interleaved event (the dogfood failure
# run 20260629214235-33569, now dissolved by redaction-by-construction).
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

# ─── Test 1: member A already redacted (own redaction.applied is most-recent
# FOR-ITS-STAGE) → DEDUP: the router proceeds WITHOUT re-redacting (no double
# emit) and routes.
export ZBUILD_CURRENT_STAGE="review-lens-a"
applied_before_a="$(grep -c '"redaction.applied"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
set +e
out="$(route_to_model "T2" "ping" 2>/dev/null)"
rc=$?
set -e
assert_eq "member A: own redaction is most-recent for its stage → proceeds (rc=0)" "0" "$rc"
assert_eq "member A: response passthrough" "OK-RESPONSE" "$out"

route_a_fired="$(jq -r --arg rid "$ZBUILD_RUN_ID" \
    'select(.run_id==$rid and .type=="model.route") | .type' "$ZBUILD_EVENTS_JSONL" 2>/dev/null \
    | grep -c "model.route" || true)"
assert_gt "member A: model.route emitted after dedup" "$route_a_fired" "0"

applied_after_a="$(grep -c '"redaction.applied"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
assert_eq "member A: NO second redaction.applied (dedup — no double redaction)" \
    "$applied_before_a" "$applied_after_a"

# ─── Test 2: member B has NOT redacted (own most-recent is plugin.run.start).
# The router redacts for B BY CONSTRUCTION — B gets its OWN redaction.applied
# (stamped stage=review-lens-b), it does NOT ride sibling A's (ADR-004 intact).
: > "$ZBUILD_EVENTS_JSONL"
_emit "plugin.run.start" "review-lens-a"
_emit "redaction.applied" "review-lens-a"
_emit "plugin.run.start" "review-lens-b"   # B's own most-recent: no redaction

export ZBUILD_CURRENT_STAGE="review-lens-b"
set +e
out="$(route_to_model "T2" "ping" 2>/dev/null)"
rc=$?
set -e
assert_eq "member B: no own redaction → router redacts by construction (rc=0)" "0" "$rc"

# The freshly-emitted redaction.applied must be stamped with B's stage, proving
# B got its OWN redaction rather than riding A's.
applied_b_stage="$(jq -r --arg rid "$ZBUILD_RUN_ID" \
    'select(.run_id==$rid and .type=="redaction.applied") | .stage // empty' \
    "$ZBUILD_EVENTS_JSONL" 2>/dev/null | tail -1 || true)"
assert_eq "member B: router-emitted redaction.applied is stamped stage=review-lens-b" \
    "review-lens-b" "$applied_b_stage"

# ─── Test 3: member C whose stage has NO events yet → still redacted by
# construction (never blocked by absence of a sibling's redaction).
: > "$ZBUILD_EVENTS_JSONL"
_emit "plugin.run.start" "review-lens-a"
_emit "redaction.applied" "review-lens-a"

export ZBUILD_CURRENT_STAGE="review-lens-c"   # no events for this stage at all
set +e
out="$(route_to_model "T2" "ping" 2>/dev/null)"
rc=$?
set -e
assert_eq "member C: no events for its stage → router redacts by construction (rc=0)" "0" "$rc"
applied_c_stage="$(jq -r --arg rid "$ZBUILD_RUN_ID" \
    'select(.run_id==$rid and .type=="redaction.applied") | .stage // empty' \
    "$ZBUILD_EVENTS_JSONL" 2>/dev/null | tail -1 || true)"
assert_eq "member C: router-emitted redaction.applied is stamped stage=review-lens-c" \
    "review-lens-c" "$applied_c_stage"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
