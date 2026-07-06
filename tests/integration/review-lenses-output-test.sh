#!/usr/bin/env bash
# Integration: human-readable review_lenses terminal output (Issue OUT, ADR-039)
#
# Verifies the operator-facing contract for the review_lenses parallel group:
#   - each member emits EXACTLY ONE human-readable line (via the runner's
#     parallel_member_complete_hook → render_parallel_member_line), in
#     declaration order, instead of streaming its raw lens JSON;
#   - NO raw lens JSON (`{"score"` / `"findings":[`) reaches the terminal;
#   - the aggregator surfaces its merge-readiness report as PROSE.
# Mocks the lens dispatch (writes lens-<id>.json fixtures) — no LLM calls.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

# test-helpers.sh sets colors unconditionally; strip ANSI so the per-lens
# one-liner regex (anchored at line start) is stable.
_strip_ansi() { LC_ALL=C sed -E $'s/\x1b\\[[0-9;?]*[a-zA-Z]//g'; }

print_test_header "review_lenses human-readable output (Issue OUT)"
setup_test_env "review-lenses-output"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ZBUILD_STATE_DIR"

# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/template.sh"
# shellcheck disable=SC1090
source "$REPO_ROOT/scripts/lib/artifact-render.sh"
# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/parallel-orchestrator.sh"

STATE_FILE="$ZBUILD_STATE_DIR/pipeline-state.json"
ARTIFACT_DIR="$ZBUILD_STATE_DIR/artifacts"; mkdir -p "$ARTIFACT_DIR"

TPL="$TEST_TEMP_DIR/lenses.yaml"
cat > "$TPL" <<'EOF'
id: lenses
flow:
  - review_lenses
review_lenses:
  type: parallel
  flow:
    - lens-security
    - lens-performance
    - lens-red-team
    - lens-correctness
    - lens-scope
  max_parallel: 5
  on_member_error: continue
lens-security:
  roles: [review_lens]
lens-performance:
  roles: [review_lens]
lens-red-team:
  roles: [review_lens]
lens-correctness:
  roles: [review_lens]
lens-scope:
  roles: [review_lens]
EOF
load_template "$TPL"

: > "$ZBUILD_EVENTS_JSONL"
jq -n '{schema_version:1, stage_statuses:{}, stage_verdicts:{}, updated_at:"seed"}' > "$STATE_FILE"

# Seed one lens-<id>.json per member (what the real review-lens plugin writes).
_seed_lens() { printf '%s\n' "$2" > "$ARTIFACT_DIR/lens-$1.json"; }
_seed_lens security    '{"schema_version":1,"name":"security","score":6,"findings":[{"file":"a.sh","severity":"high","line":4,"message":"unquoted var"}]}'
_seed_lens performance '{"schema_version":1,"name":"performance","score":9,"findings":[]}'
_seed_lens red-team    '{"schema_version":1,"name":"red-team","score":8,"findings":[{"file":"b.sh","severity":"low","line":1,"message":"nit"}]}'
_seed_lens correctness '{"schema_version":1,"name":"correctness","score":7,"findings":[{"file":"c.sh","severity":"medium","line":9,"message":"off by one"}]}'
_seed_lens scope       '{"schema_version":1,"name":"scope","score":10,"findings":[]}'

# Mock dispatch (no LLM): the artifacts are already on disk; just set verdict.
parallel_dispatch_stage() {
    _PARALLEL_DISPATCH_VERDICT="pass"
    _PARALLEL_DISPATCH_STATUS="complete"
    return 0
}

# Wire the member-complete hook exactly as the runner does (renders one line via
# the shared helper, resolving the artifact dir from the orchestrator's state_dir).
parallel_member_complete_hook() {
    render_parallel_member_line "$2" "${state_dir}/artifacts" "$4" "$5" "$6"
}

OUT_FILE="$TEST_TEMP_DIR/terminal.out"
export ZBUILD_SEQ_PREFIX="7"
set +e
parallel_group_run "review_lenses" "$ZBUILD_STATE_DIR" "$STATE_FILE" >/dev/null 2>"$OUT_FILE"
rc=$?
set -e
unset ZBUILD_SEQ_PREFIX
term="$(cat "$OUT_FILE")"
term_plain="$(printf '%s' "$term" | _strip_ansi)"

# ─── T8: exactly 5 human-readable one-liner lines, one per lens ──────────────
print_test_section "T8: one human-readable line per lens"
one_liners="$(printf '%s\n' "$term_plain" | grep -cE '^[✓✗⚠] (security|performance|red-team|correctness|scope) ' || true)"
assert_eq "T8 exactly 5 lens one-liners" "5" "$one_liners"

# ─── T9: full lens I/O (prompt + raw JSON body) does NOT reach the terminal ──
print_test_section "T9: raw lens JSON body absent from terminal"
if grep -q '"schema_version"' <<< "$term"; then
    assert_fail "T9 no raw lens JSON body streamed" "found schema_version in terminal"
else
    assert_pass "T9 raw lens JSON body not streamed to terminal"
fi

# ─── T10 (CRITICAL): no raw JSON reaches the terminal ────────────────────────
print_test_section "T10: NO raw JSON on the terminal"
if grep -qE '\{"score"|"findings":\[' <<< "$term"; then
    assert_fail "T10 no raw JSON on terminal" "raw JSON detected"
else
    assert_pass "T10 no {\"score\" / \"findings\":[ on terminal"
fi
# The highest-severity finding surfaces in the security one-liner (spot check).
assert_contains "T10 security one-liner shows top finding" "$term" "top: high"

# ─── T11: aggregator surfaces prose merge-readiness report to the terminal ───
print_test_section "T11: aggregator prints prose report"
# shellcheck disable=SC1090
source "$REPO_ROOT/plugins/agent/review-aggregator/plugin.sh"
AGG_OUT="$TEST_TEMP_DIR/agg.out"
export _TPL_STAGE_IO_DESTS_review_aggregator="file,stdout"   # io dests include stdout
export ZBUILD_CURRENT_STAGE="review-aggregator"
set +e
review_aggregator_run "review-aggregator" "$STATE_FILE" 2>"$AGG_OUT" >/dev/null
set -e
unset ZBUILD_CURRENT_STAGE
agg="$(cat "$AGG_OUT")"
assert_contains "T11 prose report header on terminal" "$agg" "## Review Report"
assert_contains "T11 merge-readiness line on terminal" "$agg" "**Merge Readiness:**"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
