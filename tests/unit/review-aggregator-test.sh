#!/usr/bin/env bash
# Tests: plugins/agent/review-aggregator — collapse N parallel lens outputs into
# ONE advisory merge-readiness report (#1141 C2, ADR-040 §3/§4; evolves ADR-038).
# Globs lens-<name>.json from the shared artifacts dir, de-dupes findings by
# file + category + proximity (max severity + union of lenses/messages), renders
# review-report.json + .md. Advisory only: NEVER blocks — always returns 0.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "review-aggregator — advisory lens collapse (#1141)"
setup_test_env "review-aggregator"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

# ─── Plugin is discoverable + manifest validates ────────────────────────────
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
PLUGIN_DIR="$REPO_ROOT/plugins/agent/review-aggregator"
set +e
validate_manifest "$PLUGIN_DIR/manifest.yaml" >/dev/null 2>&1
rc=$?
set -e
assert_eq "review-aggregator manifest validates (kind: agent + requires.core)" "0" "$rc"
discovered="$(discover_plugins "$REPO_ROOT/plugins")"
assert_contains "review-aggregator is discovered" "$discovered" "agent/review-aggregator"

# shellcheck source=../../plugins/agent/review-aggregator/plugin.sh
source "$PLUGIN_DIR/plugin.sh"

# write_lens <artifact_dir> <name> <json> — writes a lens-<name>.json fixture.
write_lens() {
    printf '%s\n' "$3" > "$1/lens-$2.json"
}

# ─── Fixtures: mirror the review-report aggregation test's canned lens set ────
# x.sh logic @42 (correctness, medium) and @47 (security, high) are within the
# 10-line proximity window → ONE merged finding carrying both lenses + max
# severity (high). y.sh injection @10 (security, critical) stays separate.
artifact_dir="$TEST_TEMP_DIR/artifacts"
mkdir -p "$artifact_dir"
write_lens "$artifact_dir" "correctness" \
    '{"schema_version":1,"name":"correctness","score":6,"findings":[{"file":"core/x.sh","category":"logic","severity":"medium","line":42,"message":"off-by-one in loop"}]}'
write_lens "$artifact_dir" "security" \
    '{"schema_version":1,"name":"security","score":3,"findings":[{"file":"core/x.sh","category":"logic","severity":"high","line":47,"message":"same region higher severity"},{"file":"core/y.sh","category":"injection","severity":"critical","line":10,"message":"shell injection risk"}]}'
write_lens "$artifact_dir" "performance" \
    '{"schema_version":1,"name":"performance","score":10,"findings":[]}'
write_lens "$artifact_dir" "architecture" \
    '{"schema_version":1,"name":"architecture","score":10,"findings":[]}'

out_json="$artifact_dir/review-report.json"
out_md="$artifact_dir/review-report.md"

set +e
_review_aggregator_run_inner "$artifact_dir" "$out_json" "$out_md"
_run_rc=$?
set -e

# ─── SPEC-1: glob collapses N lens files → one report with N lenses ──────────
assert_eq "[SPEC-1] run returns 0 (advisory never aborts)" "0" "$_run_rc"
assert_file_exists "[SPEC-1] writes review-report.json" "$out_json"
assert_eq "[SPEC-1] report has 4 lenses (one per lens-*.json)" "4" "$(jq '.lenses | length' "$out_json")"
assert_eq "[SPEC-1] schema_version present" "1" "$(jq -r '.schema_version' "$out_json")"

# ─── SPEC-2: dedup by file + category + proximity (max sev + union of lenses) ─
assert_eq "[SPEC-2] flat findings de-duped to 2" "2" "$(jq '.findings | length' "$out_json")"
_merged="$(jq -c '.findings[] | select(.file=="core/x.sh")' "$out_json")"
assert_contains "[SPEC-2] merged finding carries the correctness lens" "$_merged" "correctness"
assert_contains "[SPEC-2] merged finding carries the security lens" "$_merged" "security"
assert_eq "[SPEC-2] merged finding takes MAX severity (high)" "high" \
    "$(jq -r '.findings[] | select(.file=="core/x.sh") | .severity' "$out_json")"
assert_eq "[SPEC-2] y.sh stays a separate critical finding" "critical" \
    "$(jq -r '.findings[] | select(.file=="core/y.sh") | .severity' "$out_json")"

# ─── SPEC-3: advisory only — needs_attention, but rc 0 and NO verdict field ──
assert_eq "[SPEC-3] critical finding → merge_readiness=needs_attention" "needs_attention" \
    "$(jq -r '.merge_readiness' "$out_json")"
if jq -e '.verdict' "$out_json" >/dev/null 2>&1; then
    assert_fail "[SPEC-3] report must carry NO verdict field" "found .verdict"
else
    assert_pass "[SPEC-3] report carries no verdict field"
fi
_esc_note="$(jq -r '.escalation_note // empty' "$out_json" 2>/dev/null)"
if [[ -n "$_esc_note" ]]; then
    assert_pass "[SPEC-3] needs_attention report carries non-empty escalation_note"
else
    assert_fail "[SPEC-3] needs_attention report must carry escalation_note" "field absent"
fi
# Source-level no-coercion proof: the aggregator never emits a merge decision.
if grep -qiE '\b(approve|request_changes)\b|"block"|verdict' "$PLUGIN_DIR/plugin.sh"; then
    assert_fail "[SPEC-3] no coercion vocabulary in review-aggregator source" "found coercion token"
else
    assert_pass "[SPEC-3] no coercion vocabulary in review-aggregator source"
fi

# ─── SPEC-4: .md rendered with per-lens + de-duped sections (reused renderer) ─
_md="$(cat "$out_md")"
assert_contains "[SPEC-4] md names the correctness lens + score" "$_md" "#### correctness (score: 6/10)"
assert_contains "[SPEC-4] md renders a finding message (not blank)" "$_md" "off-by-one in loop"
assert_contains "[SPEC-4] de-duped section names contributing lenses" "$_md" "lenses: correctness, security"

# ─── SPEC-5: aggregation EQUIVALENCE with review-report's _rr_aggregate ──────
# DoD: the collapsed report must match the current review-report aggregation.
# Feed the SAME lenses array to both functions and assert byte-identical output.
# shellcheck source=../../plugins/agent/review-report/lib/lenses.sh
source "$REPO_ROOT/plugins/agent/review-report/lib/lenses.sh"
_lenses_arr="$artifact_dir/review-aggregator-lenses.json"
assert_file_exists "[SPEC-5] aggregator wrote its combined lenses array" "$_lenses_arr"
_ra_out="$(_ra_aggregate "$_lenses_arr")"
_rr_out="$(_rr_aggregate "$_lenses_arr")"
assert_eq "[SPEC-5] _ra_aggregate output matches _rr_aggregate byte-for-byte" "$_rr_out" "$_ra_out"

# ─── SPEC-6: empty lens group degrades to an empty report (rc 0 + event) ─────
_empty_dir="$TEST_TEMP_DIR/empty"
mkdir -p "$_empty_dir"
set +e
_review_aggregator_run_inner "$_empty_dir" "$_empty_dir/review-report.json" "$_empty_dir/review-report.md"
_empty_rc=$?
set -e
assert_eq "[SPEC-6] empty lens group returns 0" "0" "$_empty_rc"
assert_file_exists "[SPEC-6] a report is still written on an empty group" "$_empty_dir/review-report.json"
assert_eq "[SPEC-6] empty group → 0 lenses" "0" "$(jq '.lenses | length' "$_empty_dir/review-report.json")"
assert_eq "[SPEC-6] empty group → 0 findings" "0" "$(jq '.findings | length' "$_empty_dir/review-report.json")"
if grep -q '"review_aggregator.no_lenses"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_pass "[SPEC-6] review_aggregator.no_lenses event emitted"
else
    assert_fail "[SPEC-6] review_aggregator.no_lenses event should be emitted" "absent"
fi

# ─── SPEC-7: a malformed lens file degrades to empty, never aborts ───────────
_bad_dir="$TEST_TEMP_DIR/bad"
mkdir -p "$_bad_dir"
printf '{ not json at all ' > "$_bad_dir/lens-correctness.json"
write_lens "$_bad_dir" "security" \
    '{"schema_version":1,"name":"security","score":9,"findings":[]}'
set +e
_review_aggregator_run_inner "$_bad_dir" "$_bad_dir/review-report.json" "$_bad_dir/review-report.md"
_bad_rc=$?
set -e
assert_eq "[SPEC-7] malformed lens file still returns 0" "0" "$_bad_rc"
assert_eq "[SPEC-7] malformed lens collected as empty entry (2 lenses)" "2" \
    "$(jq '.lenses | length' "$_bad_dir/review-report.json")"

# ─── SPEC-8: hook contract — review_aggregator_run(stage, state_file) ────────
STATE_DIR="$TEST_TEMP_DIR/state"
mkdir -p "$STATE_DIR/artifacts"
STATE_FILE="$STATE_DIR/pipeline-state.json"
echo '{"schema_version":1,"run_id":"ra-hook-001","issue":"0","stage_statuses":{}}' > "$STATE_FILE"
write_lens "$STATE_DIR/artifacts" "edge-case" \
    '{"schema_version":1,"name":"edge-case","score":8,"findings":[]}'
review_aggregator_init >/dev/null
set +e
review_aggregator_run "review-aggregator" "$STATE_FILE" >/dev/null 2>&1
_rc_hook=$?
set -e
assert_eq "[SPEC-8] review_aggregator_run(stage, state_file) returns 0" "0" "$_rc_hook"
assert_file_exists "[SPEC-8] hook writes review-report.json into artifacts dir" \
    "$STATE_DIR/artifacts/review-report.json"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
