#!/usr/bin/env bash
# Tests: Phase 2 (#1129 follow-up, ADR-039/ADR-040 §3) — ROSTER-DRIVEN
# review-aggregator. The advisory aggregator self-resolves which `aggregate:
# advisory` parallel group it serves (Phase 1 binding: it is the bound non-member
# convergence:advisory stage), reads that group's members from
# _TPL_PARALLEL_FLOW_<group>, resolves each member's manifest + DECLARED result
# artifact, and collects those files — NOT a lens-*.json filename glob. This
# proves the glob dependency is gone: members whose declared outputs are NOT
# named lens-* are still aggregated. When no group binding is in scope, it falls
# back to the legacy glob (regression safety — covered by review-aggregator-test.sh).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../plugins/agent/review-aggregator/plugin.sh
source "$REPO_ROOT/plugins/agent/review-aggregator/plugin.sh"

print_test_header "review-aggregator — roster-driven discovery (ADR-039/040 §3, Phase 2)"
setup_test_env "review-aggregator-roster"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

# ─── Fixture plugins root: minimal advisory manifests ─────────────────────────
FX_ROOT="$TEST_TEMP_DIR/plugins"
# write_member <subdir> <id> <role> <output_basename_or_template>
# Advisory member with NO provides.artifact_type — the result file is the
# basename of the primary output's declared path (mirrors review-lens).
write_member() {
    local dir="$FX_ROOT/$1" id="$2" role="$3" out="$4"
    mkdir -p "$dir"
    {
        printf 'id: %s\n' "$id"
        printf 'name: %s\n' "$id"
        printf 'kind: agent\n'
        printf 'convergence: advisory\n'
        printf 'version: 0.1.0\n'
        printf 'hooks:\n  run: r\n'
        printf 'requires:\n  core:\n    - redaction\n'
        printf 'provides:\n  role: %s\n' "$role"
        printf 'inputs: []\n'
        printf 'outputs:\n  - id: result\n    type: file\n    path: ${artifact_dir}/%s\n    required: true\n    primary: true\n' "$out"
    } > "$dir/manifest.yaml"
}
# The aggregator stage's own manifest (non-member, convergence:advisory).
write_member agent/rev-agg rev-agg review_aggregator review-report.json
# Two members with ARBITRARY, NON-lens-* output names, resolved by id.
write_member agent/adv-foo adv-foo adv_member audit-foo.json
write_member agent/adv-bar adv-bar adv_member findings-bar.json
# One member that shares a manifest resolved BY ROLE whose output path is
# PER-MEMBER parameterized (mirrors review-lens's lens-${ZBUILD_REVIEW_LENS_ID}.json).
write_member agent/shared-lens shared-lens shared_lens 'lens-${ZBUILD_REVIEW_LENS_ID}.json'

export ZBUILD_PLUGINS_ROOT="$FX_ROOT"

# ─── SPEC-0: unit-level result-file resolution (artifact_type-less, parameterized) ─
print_test_section "SPEC-0: _ra_manifest_result_file resolves declared outputs"
assert_eq "[SPEC-0] concrete output basename resolved" "audit-foo.json" \
    "$(_ra_manifest_result_file "$FX_ROOT/agent/adv-foo/manifest.yaml" "adv-foo")"
assert_eq "[SPEC-0] parameterized \${...} expands to member-derived lens id" "lens-gamma.json" \
    "$(_ra_manifest_result_file "$FX_ROOT/agent/shared-lens/manifest.yaml" "lens-gamma")"

# ─── Enter parallel-group scope (mirrors template.sh exports) ─────────────────
# Canonical stage order: members first, then the non-member advisory aggregator.
# Members: two id-matched members (adv-foo/adv-bar) + ONE role-bound member
# (lens-gamma) whose manifest is resolved BY ROLE (_TPL_STAGE_ROLES_lens_gamma →
# provides.role=shared_lens) and whose output path is PER-MEMBER parameterized
# (lens-${ZBUILD_REVIEW_LENS_ID}.json) — exactly simple.yaml's lens mechanism.
_TPL_STAGES=(adv-foo adv-bar lens-gamma rev-agg)
_TPL_PARALLEL_GROUPS=(rev_group)
_TPL_PARALLEL_AGGREGATE_rev_group="advisory"
_TPL_PARALLEL_FLOW_rev_group="adv-foo,adv-bar,lens-gamma"
_TPL_STAGE_ROLES_lens_gamma="shared_lens"
export _TPL_PARALLEL_AGGREGATE_rev_group _TPL_PARALLEL_FLOW_rev_group _TPL_STAGE_ROLES_lens_gamma

# ─── SPEC-1: self-resolution binds to the advisory group ──────────────────────
print_test_section "SPEC-1: aggregator self-resolves its bound advisory group"
assert_eq "[SPEC-1] rev-agg (the non-member advisory stage) binds to rev_group" \
    "rev_group" "$(_ra_resolve_group "$FX_ROOT" "rev-agg")"
# A member stage is NOT the bound aggregator — it must not resolve.
set +e
_mem_grp="$(_ra_resolve_group "$FX_ROOT" "adv-foo")"; _mem_rc=$?
set -e 2>/dev/null || true
assert_eq "[SPEC-1] a group member does not self-resolve as the aggregator" "1" "$_mem_rc"

# ─── SPEC-2: roster collects ARBITRARILY-named member outputs (glob-independent) ─
print_test_section "SPEC-2: roster aggregates non-lens-* outputs"
ARTI="$TEST_TEMP_DIR/run/artifacts"
mkdir -p "$ARTI"
# Members' declared outputs — deliberately NOT named lens-*.json so the legacy
# glob would miss them entirely (baseline-fail proof).
printf '%s\n' '{"name":"foo","score":4,"findings":[{"file":"core/a.sh","category":"logic","severity":"high","line":7,"message":"foo issue"}]}' > "$ARTI/audit-foo.json"
printf '%s\n' '{"name":"bar","score":9,"findings":[{"file":"core/b.sh","category":"style","severity":"low","line":3,"message":"bar nit"}]}' > "$ARTI/findings-bar.json"
# Role-bound member's per-member parameterized output (lens-${ID}.json → lens-gamma.json).
printf '%s\n' '{"name":"gamma","score":5,"findings":[{"file":"core/c.sh","category":"arch","severity":"medium","line":9,"message":"gamma concern"}]}' > "$ARTI/lens-gamma.json"
# A decoy lens-*.json that is NOT a roster member — must be IGNORED by roster.
printf '%s\n' '{"name":"decoy","score":1,"findings":[{"file":"core/z.sh","category":"x","severity":"critical","line":1,"message":"decoy"}]}' > "$ARTI/lens-decoy.json"

export ZBUILD_CURRENT_STAGE="rev-agg"
OUT_JSON="$ARTI/review-report.json"
OUT_MD="$ARTI/review-report.md"
set +e
_review_aggregator_run_inner "$ARTI" "$OUT_JSON" "$OUT_MD"
_rc=$?
set -e 2>/dev/null || true
assert_eq "[SPEC-2] run returns 0 (advisory)" "0" "$_rc"
assert_eq "[SPEC-2] roster collected exactly the 3 declared members (2 id + 1 role-bound)" "3" \
    "$(jq '.lenses | length' "$OUT_JSON")"
assert_contains "[SPEC-2] foo member (audit-foo.json) aggregated" "$(cat "$OUT_JSON")" "foo issue"
assert_contains "[SPEC-2] bar member (findings-bar.json) aggregated" "$(cat "$OUT_JSON")" "bar nit"
assert_contains "[SPEC-2] role-bound lens-gamma (parameterized output) aggregated" "$(cat "$OUT_JSON")" "gamma concern"
# The decoy lens-*.json is NOT a roster member → its critical finding must be absent.
if jq -e '.findings[] | select(.message=="decoy")' "$OUT_JSON" >/dev/null 2>&1; then
    assert_fail "[SPEC-2] non-member lens-decoy.json must be IGNORED (proves no glob)" "decoy present"
else
    assert_pass "[SPEC-2] non-member lens-decoy.json ignored (roster, not glob)"
fi
# Discovery mode recorded on the completion event.
if grep -q '"discovery":"roster"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_pass "[SPEC-2] completion event records discovery=roster"
else
    assert_fail "[SPEC-2] completion event should record discovery=roster" "absent"
fi

# ─── SPEC-3: legacy glob fallback when no group binding is in scope ───────────
print_test_section "SPEC-3: no group env → legacy lens-*.json glob fallback"
unset _TPL_PARALLEL_GROUPS _TPL_STAGES _TPL_PARALLEL_AGGREGATE_rev_group _TPL_PARALLEL_FLOW_rev_group
unset ZBUILD_CURRENT_STAGE
ARTI2="$TEST_TEMP_DIR/run2/artifacts"
mkdir -p "$ARTI2"
printf '%s\n' '{"name":"sec","score":8,"findings":[]}' > "$ARTI2/lens-sec.json"
printf '%s\n' '{"name":"perf","score":7,"findings":[]}' > "$ARTI2/lens-perf.json"
# A non-lens file that the glob must ignore.
printf '%s\n' '{"name":"x","score":1,"findings":[]}' > "$ARTI2/audit-foo.json"
set +e
_review_aggregator_run_inner "$ARTI2" "$ARTI2/review-report.json" "$ARTI2/review-report.md"
set -e 2>/dev/null || true
assert_eq "[SPEC-3] fallback glob collected the 2 lens-*.json files" "2" \
    "$(jq '.lenses | length' "$ARTI2/review-report.json")"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
