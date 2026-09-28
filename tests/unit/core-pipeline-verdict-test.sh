#!/usr/bin/env bash
# Tests: core/pipeline/verdict.sh — verdict-driven stage indicator resolver (#507).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/pipeline/verdict — runner_read_stage_verdict (#507)"
setup_test_env "pipeline-verdict"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../core/pipeline/verdict.sh
source "$REPO_ROOT/core/pipeline/verdict.sh"

STATE_DIR="$TEST_TEMP_DIR/state"
ART_DIR="$STATE_DIR/artifacts"
mkdir -p "$ART_DIR"

_make_manifest() {
    # _make_manifest <dir> <id> <output_path> <output_id> [type=json]
    local dir="$1" id="$2" path="$3" out_id="${4:-out}" type="${5:-json}"
    mkdir -p "$dir"
    cat > "$dir/manifest.yaml" <<EOF
id: $id
name: $id
kind: tool
version: 0.0.1
hooks:
  run: ${id}_run
requires:
  core: [event-bus]
inputs: []
outputs:
  - id: $out_id
    path: $path
    type: $type
    required: true
    primary: true
EOF
}

# ─── Test: verdict_classify pure mapping ─────────────────────────────────────
print_test_section "verdict_classify table"
for pair in "pass:pass" "approve:pass" "request_changes:warn" \
            "incomplete:warn" \
            "fail:fail" "error:fail" "block:fail" "scope_violation:fail" \
            ":unknown" "weird:unknown"; do
    raw="${pair%%:*}"; want="${pair##*:}"
    got="$(verdict_classify "$raw")"
    assert_eq "verdict_classify($raw) -> $want" "$want" "$got"
done

# [SPEC-1] inert_build removed from classify table (#1832, ADR-054): previously
# classified as "fail" (#1532); after migration it is not a verdict string and
# returns "unknown". Fails at the merge-base baseline where it returned "fail".
got="$(verdict_classify "inert_build")"
assert_eq "[SPEC-1] verdict_classify(inert_build) -> unknown (removed in #1832)" "unknown" "$got"

# [SPEC-4] did_not_finish removed from classify table (#1832, ADR-054): previously
# classified as "warn"; after migration it is not a verdict string → "unknown".
# Fails at the merge-base baseline where it returned "warn".
got="$(verdict_classify "did_not_finish")"
assert_eq "[SPEC-4] verdict_classify(did_not_finish) -> unknown (removed in #1832)" "unknown" "$got"

# complete classifies as pass (CHANGE — was "unknown" before #1687;
# impact's terminal "no gaps" success verdict).
got="$(verdict_classify "complete")"
assert_eq "verdict_classify(complete) -> pass" "pass" "$got"

# skip classifies as pass (CHANGE — was "unknown" before #1687;
# gates' "not-applicable this run" verdict — declining to apply is not failure).
got="$(verdict_classify "skip")"
assert_eq "verdict_classify(skip) -> pass" "pass" "$got"

# [SPEC-3] runner_read_stage_verdict must NOT emit pipeline.indicator.unknown_verdict
# for complete or skip (both now classify as pass — no unknown_verdict path).
print_test_section "[SPEC-3] no unknown_verdict event for complete or skip"
: > "$ZBUILD_EVENTS_JSONL"
spec3_dir="$TEST_TEMP_DIR/plugins/impact"
_make_manifest "$spec3_dir" "impact" "${ART_DIR}/impact-result.json" "impact_result"

printf '%s' '{"verdict":"complete"}' > "$ART_DIR/impact-result.json"
runner_read_stage_verdict "$STATE_DIR" "$spec3_dir/manifest.yaml" "impact" 0 >/dev/null

printf '%s' '{"verdict":"skip"}' > "$ART_DIR/impact-result.json"
runner_read_stage_verdict "$STATE_DIR" "$spec3_dir/manifest.yaml" "impact" 0 >/dev/null

unk_count=$(grep -c '"pipeline.indicator.unknown_verdict"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)
assert_eq "[SPEC-3] no pipeline.indicator.unknown_verdict emitted for complete or skip" "0" "$unk_count"

# ─── Test: rc != 0 always wins ───────────────────────────────────────────────
print_test_section "rc != 0 overrides verdict"
m_dir="$TEST_TEMP_DIR/plugins/test"
_make_manifest "$m_dir" "test" "${ART_DIR}/test-results.json" "test_results"
printf '%s' '{"verdict":"pass"}' > "$ART_DIR/test-results.json"
got="$(runner_read_stage_verdict "$STATE_DIR" "$m_dir/manifest.yaml" "test" 1)"
assert_eq "rc=1 forces fail even when verdict=pass" "fail" "$got"

# ─── Test: test verdict pass / fail / error ──────────────────────────────────
print_test_section "test plugin verdict mapping"
printf '%s' '{"verdict":"pass"}' > "$ART_DIR/test-results.json"
got="$(runner_read_stage_verdict "$STATE_DIR" "$m_dir/manifest.yaml" "test" 0)"
assert_eq "test verdict=pass -> pass" "pass" "$got"

printf '%s' '{"verdict":"fail"}' > "$ART_DIR/test-results.json"
got="$(runner_read_stage_verdict "$STATE_DIR" "$m_dir/manifest.yaml" "test" 0)"
assert_eq "test verdict=fail -> fail" "fail" "$got"

printf '%s' '{"verdict":"error"}' > "$ART_DIR/test-results.json"
got="$(runner_read_stage_verdict "$STATE_DIR" "$m_dir/manifest.yaml" "test" 0)"
# #550: structural-failure raw verdicts pass through unclassified so the
# cycle blocked predicate can distinguish them from generic "fail".
assert_eq "test verdict=error -> error (pass-through #550)" "error" "$got"

printf '%s' '{"verdict":"corrupt_diff","reason":"diff_apply_failed"}' > "$ART_DIR/test-results.json"
got="$(runner_read_stage_verdict "$STATE_DIR" "$m_dir/manifest.yaml" "test" 0)"
assert_eq "test verdict=corrupt_diff -> corrupt_diff (pass-through #550)" "corrupt_diff" "$got"

# ─── Test: review verdicts ───────────────────────────────────────────────────
print_test_section "review plugin verdict mapping"
r_dir="$TEST_TEMP_DIR/plugins/review"
_make_manifest "$r_dir" "review" "${ART_DIR}/review.json" "review"
printf '%s' '{"verdict":"approve"}' > "$ART_DIR/review.json"
got="$(runner_read_stage_verdict "$STATE_DIR" "$r_dir/manifest.yaml" "review" 0)"
assert_eq "review verdict=approve -> pass" "pass" "$got"

printf '%s' '{"verdict":"request_changes"}' > "$ART_DIR/review.json"
got="$(runner_read_stage_verdict "$STATE_DIR" "$r_dir/manifest.yaml" "review" 0)"
assert_eq "review verdict=request_changes -> warn" "warn" "$got"

printf '%s' '{"verdict":"block"}' > "$ART_DIR/review.json"
got="$(runner_read_stage_verdict "$STATE_DIR" "$r_dir/manifest.yaml" "review" 0)"
# #550: block is a structural-failure class — passes through unclassified.
assert_eq "review verdict=block -> block (pass-through #550)" "block" "$got"

# ─── Test: build verdict via the pushed .verdict channel (ADR-047 §3) ─────────
# #1280: the verdict reader is stage-agnostic — it reads the .verdict the build
# plugin PUSHES into build-summary.json (schema v4 always writes it). A JSON
# artifact with no .verdict is a clean pass; a scope_violation is reported as
# .verdict:"scope_violation" (the legacy .scope_violation-derivation that the
# mechanic used to do by name is gone).
print_test_section "build plugin verdict derivation"
b_dir="$TEST_TEMP_DIR/plugins/build"
_make_manifest "$b_dir" "build" "${ART_DIR}/build-summary.json" "build_summary"

printf '%s' '{"verdict":"pass","scope_violation":false}' > "$ART_DIR/build-summary.json"
got="$(runner_read_stage_verdict "$STATE_DIR" "$b_dir/manifest.yaml" "build" 0)"
assert_eq "build verdict=pass -> pass" "pass" "$got"

printf '%s' '{"verdict":"scope_violation","scope_violation":true}' > "$ART_DIR/build-summary.json"
got="$(runner_read_stage_verdict "$STATE_DIR" "$b_dir/manifest.yaml" "build" 0)"
assert_eq "build verdict=scope_violation -> fail" "fail" "$got"

printf '%s' '{"verdict":"pass","scope_violation":false}' > "$ART_DIR/build-summary.json"
got="$(runner_read_stage_verdict "$STATE_DIR" "$b_dir/manifest.yaml" "build" 0)"
assert_eq "build .verdict=pass -> pass" "pass" "$got"

# #550: build corrupt_diff also passes through (structural-failure class).
printf '%s' '{"verdict":"corrupt_diff","scope_violation":false}' > "$ART_DIR/build-summary.json"
got="$(runner_read_stage_verdict "$STATE_DIR" "$b_dir/manifest.yaml" "build" 0)"
assert_eq "build .verdict=corrupt_diff -> corrupt_diff (pass-through #550)" "corrupt_diff" "$got"

printf '%s' '{"verdict":"error"}' > "$ART_DIR/build-summary.json"
got="$(runner_read_stage_verdict "$STATE_DIR" "$b_dir/manifest.yaml" "build" 0)"
assert_eq "build .verdict=error -> error (pass-through #550)" "error" "$got"

# ─── Test: plan (no .verdict field) falls back to pass when present ──────────
print_test_section "plan plugin no .verdict field -> pass"
p_dir="$TEST_TEMP_DIR/plugins/plan"
_make_manifest "$p_dir" "plan" "${ART_DIR}/plan.json" "plan"
printf '%s' '{"steps":[]}' > "$ART_DIR/plan.json"
got="$(runner_read_stage_verdict "$STATE_DIR" "$p_dir/manifest.yaml" "plan" 0)"
assert_eq "plan present, no .verdict -> pass" "pass" "$got"

# ─── Test: missing artifact -> warn + stage.verdict.missing event ────────────
print_test_section "missing primary artifact emits stage.verdict.missing"
: > "$ZBUILD_EVENTS_JSONL"
rm -f "$ART_DIR/test-results.json"
got="$(runner_read_stage_verdict "$STATE_DIR" "$m_dir/manifest.yaml" "test" 0)"
assert_eq "missing artifact -> warn" "warn" "$got"
miss_count=$(grep -c '"stage.verdict.missing"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)
[[ "$miss_count" -ge 1 ]] \
    && assert_pass "stage.verdict.missing emitted on absent artifact" \
    || assert_fail "stage.verdict.missing emitted on absent artifact" "got $miss_count"

# ─── Test: malformed JSON -> structural failure (ADR-054 / #1821) ────────────
# WAS `warn` (a yellow glyph, run continues). A stage that exits 0 and writes
# unparseable JSON into its declared primary is wrong under ANY contract
# version, so this is the one v1 behaviour #1821 flips. Returns raw `error` —
# already in the #550 structural pass-through set, so _cycle_detect_blocked
# halts on it without any predicate or template change.
print_test_section "malformed JSON primary -> contract violation"
: > "$ZBUILD_EVENTS_JSONL"
printf '%s' 'not-json{{{' > "$ART_DIR/test-results.json"
got="$(runner_read_stage_verdict "$STATE_DIR" "$m_dir/manifest.yaml" "test" 0)"
assert_eq "malformed JSON -> error (structural)" "error" "$got"
malformed_count=$(grep -c '"stage.verdict.contract_violation"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)
[[ "$malformed_count" -ge 1 ]] \
    && assert_pass "stage.verdict.contract_violation emitted on malformed JSON" \
    || assert_fail "stage.verdict.contract_violation emitted on malformed JSON" "got $malformed_count"
# The event names the stage and the path so an operator can find the artifact.
_cv_line="$(grep '"stage.verdict.contract_violation"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
if grep -q 'test-results.json' <<< "$_cv_line"; then
    assert_pass "contract_violation event carries the artifact path"
else
    assert_fail "contract_violation event carries the artifact path" "path absent from event"
fi
# The raw channel agrees with the classified channel.
got="$(runner_read_stage_verdict_raw "$STATE_DIR" "$m_dir/manifest.yaml" "test" 0)"
assert_eq "malformed JSON -> raw channel also error" "error" "$got"
# The reason channel explains itself rather than going blank.
got="$(runner_read_stage_reason "$STATE_DIR" "$m_dir/manifest.yaml" "test" 0)"
assert_eq "malformed JSON -> reason names the violation" \
    "contract_violation:malformed_json" "$got"

# ─── Test: non-JSON primary (e.g. pr-url.txt) -> presence = pass ─────────────
print_test_section "non-JSON primary path -> presence = pass"
pr_dir="$TEST_TEMP_DIR/plugins/pr"
_make_manifest "$pr_dir" "pr" "${ART_DIR}/pr-url.txt" "pr_url" "pr-url.txt"
printf 'https://example/pr/1\n' > "$ART_DIR/pr-url.txt"
got="$(runner_read_stage_verdict "$STATE_DIR" "$pr_dir/manifest.yaml" "pr" 0)"
assert_eq "non-JSON primary present -> pass" "pass" "$got"

# ─── Test: no manifest -> unknown (contract-bypass display path) ─────────────
print_test_section "no manifest -> unknown"
got="$(runner_read_stage_verdict "$STATE_DIR" "" "ghost" 0)"
assert_eq "absent manifest -> unknown" "unknown" "$got"

# ─── Test: manifest without primary -> pass (rc-fallback) ────────────────────
print_test_section "manifest without primary -> pass on rc=0"
np_dir="$TEST_TEMP_DIR/plugins/noprim"
mkdir -p "$np_dir"
cat > "$np_dir/manifest.yaml" <<'EOF'
id: noprim
name: noprim
kind: tool
version: 0.0.1
hooks:
  run: noprim_run
requires:
  core: [event-bus]
inputs: []
outputs:
  - id: foo
    path: /tmp/foo
    type: x
    required: true
EOF
got="$(runner_read_stage_verdict "$STATE_DIR" "$np_dir/manifest.yaml" "noprim" 0)"
assert_eq "no primary declared, rc=0 -> pass" "pass" "$got"

# ═══ ADR-054 / #1821 — the v2 result contract ════════════════════════════════
# Versioned coexistence: the engine reads v1 (today's shape, no result_contract)
# and v2 (result_contract:2 with the mandatory scalars) side by side, so plugins
# migrate one per PR rather than in a flag day.
#
# The version key is `result_contract`, NOT `schema_version`: schema_version is
# already the ARTIFACT's own schema, independently per type (build-summary.json
# is at 4, #602). See the regression guard at the end of this section.

v2_dir="$TEST_TEMP_DIR/plugins/v2stage"
_make_manifest "$v2_dir" "v2stage" "${ART_DIR}/v2-result.json" "result" "json"
_v2_result="$ART_DIR/v2-result.json"

# _write_v2 <verdict> <disposition> <reason>  — omit a field by passing OMIT
_write_v2() {
    local jqf='{result_contract:2}'
    [[ "$1" != OMIT ]] && jqf="$jqf + {verdict:\$v}"
    [[ "$2" != OMIT ]] && jqf="$jqf + {disposition:\$d}"
    [[ "$3" != OMIT ]] && jqf="$jqf + {reason:\$r}"
    jq -nc --arg v "$1" --arg d "$2" --arg r "$3" \
       "$jqf + {data:{v2stage:{note:\"engine never interprets this\"}}}" > "$_v2_result"
}

print_test_section "v1 and v2 fixtures both resolve through one reader"
# v1 fixture: no result_contract at all — the default.
jq -nc '{verdict:"pass"}' > "$_v2_result"
assert_eq "v1 fixture (no result_contract) -> pass" \
    "pass" "$(runner_read_stage_verdict "$STATE_DIR" "$v2_dir/manifest.yaml" "v2stage" 0)"
# v2 fixture: complete and well-formed.
_write_v2 pass complete "all four mandatory fields present"
assert_eq "v2 fixture (complete) -> pass" \
    "pass" "$(runner_read_stage_verdict "$STATE_DIR" "$v2_dir/manifest.yaml" "v2stage" 0)"
assert_eq "v2 raw channel returns the raw verdict" \
    "pass" "$(runner_read_stage_verdict_raw "$STATE_DIR" "$v2_dir/manifest.yaml" "v2stage" 0)"
assert_eq "v2 reason is readable" \
    "all four mandatory fields present" \
    "$(runner_read_stage_reason "$STATE_DIR" "$v2_dir/manifest.yaml" "v2stage" 0)"

print_test_section "v2: a missing mandatory field is a structural failure"
# One assertion per mandatory field. `data` is deliberately NOT mandatory.
for _f in verdict disposition reason; do
    case "$_f" in
        verdict)     _write_v2 OMIT complete "r" ;;
        disposition) _write_v2 pass OMIT     "r" ;;
        reason)      _write_v2 pass complete OMIT ;;
    esac
    : > "$ZBUILD_EVENTS_JSONL"
    got="$(runner_read_stage_verdict "$STATE_DIR" "$v2_dir/manifest.yaml" "v2stage" 0)"
    assert_eq "v2 missing .$_f -> error (not unknown, not warn)" "error" "$got"
    got="$(runner_read_stage_reason "$STATE_DIR" "$v2_dir/manifest.yaml" "v2stage" 0)"
    assert_eq "v2 missing .$_f -> reason names the field" \
        "contract_violation:missing_field:$_f" "$got"
done
# Present-but-empty is not "present": a result that cannot explain itself is
# incomplete, so an empty string fails the same way an absent key does.
_write_v2 pass complete ""
assert_eq "v2 empty .reason -> error" \
    "error" "$(runner_read_stage_verdict "$STATE_DIR" "$v2_dir/manifest.yaml" "v2stage" 0)"

print_test_section "unknown verdict emits a diagnostic that names the artifact"
# The existing SPEC-3 test only asserts the event is NOT emitted for complete/skip.
# Nothing asserted the POSITIVE path, so a refactor could leave the event firing
# with an empty path and every test stayed green — which is exactly what happened:
# the first cut of this PR emitted "path=$resolved" after $resolved had been
# refactored away, and `2>/dev/null || true` swallowed it. An operator would get
# a drift warning naming no file. Assert the payload, not just the event count.
: > "$ZBUILD_EVENTS_JSONL"
printf '%s' '{"verdict":"xyzzy"}' > "$_v2_result"
assert_eq "unrecognised verdict -> warn" \
    "warn" "$(runner_read_stage_verdict "$STATE_DIR" "$v2_dir/manifest.yaml" "v2stage" 0)"
_uv_line="$(grep '"pipeline.indicator.unknown_verdict"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
if grep -q 'v2-result.json' <<< "$_uv_line"; then
    assert_pass "unknown_verdict event carries a non-empty artifact path"
else
    assert_fail "unknown_verdict event carries a non-empty artifact path" \
        "path missing/empty in: ${_uv_line:-<no event>}"
fi
if grep -q 'xyzzy' <<< "$_uv_line"; then
    assert_pass "unknown_verdict event carries the offending token"
else
    assert_fail "unknown_verdict event carries the offending token" "raw_verdict absent"
fi

print_test_section "the contract key is NOT schema_version (regression guard)"
# CAUGHT BY THE local-vs-CI PARITY GOLDEN, not by review: the first cut of this
# reader keyed the contract version off `.schema_version >= 2`. But
# schema_version is already taken — it is the ARTIFACT's own schema, versioned
# independently per artifact type. build-summary.json has been at 4 since #602
# (pinned by plugins/agent/build/tests/build-test.sh). Result: every build
# summary was read as a v2 result and failed for a missing `disposition`,
# flipping stage_verdicts.build from "fail" to "error" on a clean run.
# A v2 result is identified by `result_contract`, which nothing else uses.
jq -nc '{schema_version:4,verdict:"fail",files_changed:[],iterations:1}' > "$_v2_result"
assert_eq "schema_version:4 artifact is v1 — classified on .verdict alone" \
    "fail" "$(runner_read_stage_verdict "$STATE_DIR" "$v2_dir/manifest.yaml" "v2stage" 0)"
assert_eq "schema_version:4 artifact raises no contract violation" \
    "" "$(runner_read_stage_reason "$STATE_DIR" "$v2_dir/manifest.yaml" "v2stage" 0)"
# And the two keys are orthogonal: a v2 result may carry its own artifact schema.
jq -nc '{schema_version:4,result_contract:2,verdict:"pass",disposition:"complete",reason:"both keys present"}' > "$_v2_result"
assert_eq "result_contract:2 alongside schema_version:4 -> read as v2" \
    "complete" "$(runner_read_stage_disposition "$STATE_DIR" "$v2_dir/manifest.yaml" "v2stage" 0)"

print_test_section "v2: disposition is parsed and exposed, never branched on"
_write_v2 fail interrupted "SIGTERM mid-flight"
assert_eq "disposition is readable" "interrupted" \
    "$(runner_read_stage_disposition "$STATE_DIR" "$v2_dir/manifest.yaml" "v2stage" 0)"
# GUARD for #1822's scope: the classification must come from .verdict alone.
# `interrupted` is not yet a policy input; if this ever returns anything but the
# classification of `fail`, disposition has started steering the engine here
# instead of in #1822 where the response table lives.
assert_eq "disposition does NOT alter the verdict class" "fail" \
    "$(runner_read_stage_verdict "$STATE_DIR" "$v2_dir/manifest.yaml" "v2stage" 0)"
assert_eq "v1 artifacts expose no disposition" "" \
    "$(printf '%s' "$(jq -nc '{verdict:"pass"}' > "$_v2_result"; \
        runner_read_stage_disposition "$STATE_DIR" "$v2_dir/manifest.yaml" "v2stage" 0)")"

print_test_section "reason survives a non-zero exit (verdict.sh:315 discard removed)"
# THE REGRESSION THIS CLOSES: runner_read_stage_reason used to open with
# `if [[ "$rc" -ne 0 ]]; then echo ""; return 0; fi`, so a plugin that wrote a
# result and THEN returned non-zero — plan's `return 1` — left the engine
# holding only an integer. That is the mechanism by which a plan timeout kills
# a whole run.
_write_v2 fail interrupted "router timed out after 300s"
assert_eq "reason readable on rc=1" "router timed out after 300s" \
    "$(runner_read_stage_reason "$STATE_DIR" "$v2_dir/manifest.yaml" "v2stage" 1)"
# rc still wins for the CLASSIFIED verdict — that contract is unchanged.
assert_eq "rc=1 still classifies as fail" "fail" \
    "$(runner_read_stage_verdict "$STATE_DIR" "$v2_dir/manifest.yaml" "v2stage" 1)"
# A dispatch that died before writing anything yields empty — the honest answer,
# and what #1823's fallback classification keys on.
rm -f "$_v2_result"
assert_eq "no result written -> reason empty on rc=1" "" \
    "$(runner_read_stage_reason "$STATE_DIR" "$v2_dir/manifest.yaml" "v2stage" 1)"

# ─── Test: verdict_glyph + verdict_color non-empty ───────────────────────────
print_test_section "glyph + color tables"
assert_eq "glyph pass" "✓" "$(verdict_glyph pass)"
assert_eq "glyph warn" "⚠" "$(verdict_glyph warn)"
assert_eq "glyph fail" "✗" "$(verdict_glyph fail)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
