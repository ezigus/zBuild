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
provides:
  result_contract: 3
EOF
}

# #2366: results are contract 3, made with the engine's writer.
# shellcheck source=../../scripts/lib/stage-result.sh
source "$REPO_ROOT/scripts/lib/stage-result.sh"
# _res <outcome> <file> [data-json] — a contract-3 result.
_res() { stage_result_write "$2" "$1" "fixture" "${3:-}"; }

# ─── Test: verdict_classify pure mapping ─────────────────────────────────────
# #2366: the reader hands verdict_classify only pass, fail, or `error` for a
# stage that did not finish; no stage's own word is classified any more.
print_test_section "verdict_classify table"
for pair in "pass:pass" "fail:fail" "error:fail" \
            "approve:unknown" "request_changes:unknown" "incomplete:unknown" \
            "block:unknown" "scope_violation:unknown" "complete:unknown" "skip:unknown" \
            "inert_build:unknown" "did_not_finish:unknown" \
            ":unknown" "weird:unknown"; do
    raw="${pair%%:*}"; want="${pair##*:}"
    got="$(verdict_classify "$raw")"
    assert_eq "verdict_classify($raw) -> $want" "$want" "$got"
done

# [SPEC-3] runner_read_stage_verdict emits no pipeline.indicator.unknown_verdict
# for a contract-3 result: the outcome always maps to a word the engine knows.
print_test_section "[SPEC-3] no unknown_verdict event for a contract-3 result"
: > "$ZBUILD_EVENTS_JSONL"
spec3_dir="$TEST_TEMP_DIR/plugins/impact"
_make_manifest "$spec3_dir" "impact" "${ART_DIR}/impact-result.json" "impact_result"
for _o in pass fail timed_out; do
    _res "$_o" "$ART_DIR/impact-result.json"
    runner_read_stage_verdict "$STATE_DIR" "$spec3_dir/manifest.yaml" "impact" 0 >/dev/null
done
unk_count=$(grep -c '"pipeline.indicator.unknown_verdict"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)
assert_eq "[SPEC-3] no pipeline.indicator.unknown_verdict emitted" "0" "$unk_count"

# ─── Test: rc != 0 always wins ───────────────────────────────────────────────
print_test_section "rc != 0 overrides verdict"
m_dir="$TEST_TEMP_DIR/plugins/test"
_make_manifest "$m_dir" "test" "${ART_DIR}/test-results.json" "test_results"
_res pass "$ART_DIR/test-results.json"
got="$(runner_read_stage_verdict "$STATE_DIR" "$m_dir/manifest.yaml" "test" 1)"
assert_eq "rc=1 forces fail even when verdict=pass" "fail" "$got"

# ─── Test: test outcome pass / fail / did not finish ──────────────────────────
print_test_section "test plugin outcome mapping"
_res pass "$ART_DIR/test-results.json"
got="$(runner_read_stage_verdict "$STATE_DIR" "$m_dir/manifest.yaml" "test" 0)"
assert_eq "test outcome=pass -> pass" "pass" "$got"

_res fail "$ART_DIR/test-results.json"
got="$(runner_read_stage_verdict "$STATE_DIR" "$m_dir/manifest.yaml" "test" 0)"
assert_eq "test outcome=fail -> fail" "fail" "$got"

_res broken "$ART_DIR/test-results.json"
got="$(runner_read_stage_verdict "$STATE_DIR" "$m_dir/manifest.yaml" "test" 0)"
# #550: a stage that did not finish reads as raw `error`, so the cycle blocked
# predicate can tell it from a generic "fail".
assert_eq "test outcome=broken -> error (pass-through #550)" "error" "$got"

# ─── Test: build outcome via the pushed result (ADR-047 §3) ───────────────────
# #1280: the reader is stage-agnostic. #2366: a scope violation is outcome=fail
# with the detail kept beside it.
print_test_section "build plugin outcome"
b_dir="$TEST_TEMP_DIR/plugins/build"
_make_manifest "$b_dir" "build" "${ART_DIR}/build-summary.json" "build_summary"

_res pass "$ART_DIR/build-summary.json"
got="$(runner_read_stage_verdict "$STATE_DIR" "$b_dir/manifest.yaml" "build" 0)"
assert_eq "build outcome=pass -> pass" "pass" "$got"

printf '{"scope_violation":true}\n' > "$ART_DIR/build-summary.json"
stage_result_add "$ART_DIR/build-summary.json" fail "scope_violation"
got="$(runner_read_stage_verdict "$STATE_DIR" "$b_dir/manifest.yaml" "build" 0)"
assert_eq "build scope violation (outcome=fail) -> fail" "fail" "$got"

_res timed_out "$ART_DIR/build-summary.json"
got="$(runner_read_stage_verdict "$STATE_DIR" "$b_dir/manifest.yaml" "build" 0)"
assert_eq "build outcome=timed_out -> error (pass-through #550)" "error" "$got"

# ─── Test: plan (no .verdict field) falls back to pass when present ──────────
print_test_section "a result with no outcome -> error"
p_dir="$TEST_TEMP_DIR/plugins/plan"
_make_manifest "$p_dir" "plan" "${ART_DIR}/plan.json" "plan"
jq -nc '{result_contract:3, reason:"fixture", steps:[]}' > "$ART_DIR/plan.json"
got="$(runner_read_stage_verdict "$STATE_DIR" "$p_dir/manifest.yaml" "plan" 0)"
# #1850/#2366: a result always carries an outcome; one with none is a violation
# (it used to read as a clean pass).
assert_eq "a result with no .outcome -> error (missing_field)" "error" "$got"

# ─── Test: missing artifact -> structural failure (#1850; was warn) ──────────
print_test_section "missing primary artifact at rc 0 is a contract violation"
: > "$ZBUILD_EVENTS_JSONL"
rm -f "$ART_DIR/test-results.json"
got="$(runner_read_stage_verdict "$STATE_DIR" "$m_dir/manifest.yaml" "test" 0)"
assert_eq "missing artifact -> error (#1850)" "error" "$got"
miss_count=$(grep -c '"stage.verdict.contract_violation"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)
[[ "$miss_count" -ge 1 ]] \
    && assert_pass "stage.verdict.contract_violation emitted on absent artifact" \
    || assert_fail "stage.verdict.contract_violation emitted on absent artifact" "got $miss_count"
assert_eq "missing artifact -> reason contract_violation:missing_result" "contract_violation:missing_result" \
    "$(runner_read_stage_reason "$STATE_DIR" "$m_dir/manifest.yaml" "test" 0)"

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

# ─── Test: non-JSON primary -> structural failure (#1850; was presence = pass) ─
print_test_section "non-JSON primary path -> contract violation"
pr_dir="$TEST_TEMP_DIR/plugins/pr"
_make_manifest "$pr_dir" "pr" "${ART_DIR}/pr-url.txt" "pr_url" "pr-url.txt"
printf 'https://example/pr/1\n' > "$ART_DIR/pr-url.txt"
got="$(runner_read_stage_verdict "$STATE_DIR" "$pr_dir/manifest.yaml" "pr" 0)"
assert_eq "non-JSON primary present -> error (#1850)" "error" "$got"

# ─── Test: no manifest -> structural failure (#1850; was unknown) ─────────────
print_test_section "no manifest -> contract violation"
got="$(runner_read_stage_verdict "$STATE_DIR" "" "ghost" 0)"
assert_eq "absent manifest -> error (#1850)" "error" "$got"

# ─── Test: manifest without primary -> structural failure (#1850; was pass) ──
print_test_section "manifest without primary -> contract violation on rc=0"
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
assert_eq "no primary declared, rc=0 -> error (#1850)" "error" "$got"

# ═══ ADR-054 / #1821 / #2366 — the result contract ═══════════════════════════
# The engine reads one contract: 3 (#2366; v1 went with #1850, v2 with #2366).
#
# The version key is `result_contract`, NOT `schema_version`: schema_version is
# already the ARTIFACT's own schema, independently per type (build-summary.json
# is at 4, #602). See the regression guard at the end of this section.

c3_dir="$TEST_TEMP_DIR/plugins/c3stage"
_make_manifest "$c3_dir" "c3stage" "${ART_DIR}/c3-result.json" "result" "json"
_c3_result="$ART_DIR/c3-result.json"

# _write_c3 <outcome> <reason> — omit a field by passing OMIT. Hand-written on
# purpose: the writer refuses exactly the results these cases need.
_write_c3() {
    local jqf='{result_contract:3}'
    [[ "$1" != OMIT ]] && jqf="$jqf + {outcome:\$o}"
    [[ "$2" != OMIT ]] && jqf="$jqf + {reason:\$r}"
    jq -nc --arg o "$1" --arg r "$2" \
       "$jqf + {data:{c3stage:{note:\"engine never interprets this\"}}}" > "$_c3_result"
}

print_test_section "a v1 or v2 fixture fails; a contract-3 fixture resolves"
jq -nc '{verdict:"pass"}' > "$_c3_result"
assert_eq "v1 fixture (no result_contract) -> error (#1850)" \
    "error" "$(runner_read_stage_verdict "$STATE_DIR" "$c3_dir/manifest.yaml" "c3stage" 0)"
assert_eq "v1 fixture -> the reason names the unsupported contract" "contract_violation:unsupported_contract:1" \
    "$(runner_read_stage_reason "$STATE_DIR" "$c3_dir/manifest.yaml" "c3stage" 0)"
jq -nc '{result_contract:2,verdict:"pass",disposition:"complete",reason:"r"}' > "$_c3_result"
assert_eq "v2 fixture -> the reason names the unsupported contract (#2366)" "contract_violation:unsupported_contract:2" \
    "$(runner_read_stage_reason "$STATE_DIR" "$c3_dir/manifest.yaml" "c3stage" 0)"
_write_c3 pass "both mandatory fields present"
assert_eq "contract-3 fixture -> pass" \
    "pass" "$(runner_read_stage_verdict "$STATE_DIR" "$c3_dir/manifest.yaml" "c3stage" 0)"
assert_eq "the raw channel returns the outcome" \
    "pass" "$(runner_read_stage_verdict_raw "$STATE_DIR" "$c3_dir/manifest.yaml" "c3stage" 0)"
assert_eq "the reason is readable" \
    "both mandatory fields present" \
    "$(runner_read_stage_reason "$STATE_DIR" "$c3_dir/manifest.yaml" "c3stage" 0)"

print_test_section "a missing mandatory field is a structural failure"
# One assertion per mandatory field. `data` is deliberately NOT mandatory.
for _f in outcome reason; do
    case "$_f" in
        outcome) _write_c3 OMIT "r" ;;
        reason)  _write_c3 pass OMIT ;;
    esac
    : > "$ZBUILD_EVENTS_JSONL"
    got="$(runner_read_stage_verdict "$STATE_DIR" "$c3_dir/manifest.yaml" "c3stage" 0)"
    assert_eq "missing .$_f -> error (not unknown, not warn)" "error" "$got"
    got="$(runner_read_stage_reason "$STATE_DIR" "$c3_dir/manifest.yaml" "c3stage" 0)"
    assert_eq "missing .$_f -> reason names the field" \
        "contract_violation:missing_field:$_f" "$got"
done
# Present-but-empty is not "present": a result that cannot explain itself is
# incomplete, so an empty string fails the same way an absent key does.
_write_c3 pass ""
assert_eq "empty .reason -> error" \
    "error" "$(runner_read_stage_verdict "$STATE_DIR" "$c3_dir/manifest.yaml" "c3stage" 0)"

print_test_section "an outcome off the list is a violation that names the word"
: > "$ZBUILD_EVENTS_JSONL"
_write_c3 xyzzy "r"
assert_eq "an outcome off the list -> error" \
    "error" "$(runner_read_stage_verdict "$STATE_DIR" "$c3_dir/manifest.yaml" "c3stage" 0)"
assert_eq "...and the reason names the word" "contract_violation:unknown_outcome:xyzzy" \
    "$(runner_read_stage_reason "$STATE_DIR" "$c3_dir/manifest.yaml" "c3stage" 0)"
_cv_line="$(grep '"stage.verdict.contract_violation"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
if grep -q 'c3-result.json' <<< "$_cv_line"; then
    assert_pass "the contract_violation event carries a non-empty artifact path"
else
    assert_fail "the contract_violation event carries a non-empty artifact path" \
        "path missing/empty in: ${_cv_line:-<no event>}"
fi

print_test_section "the contract key is NOT schema_version (regression guard)"
# CAUGHT BY THE local-vs-CI PARITY GOLDEN, not by review: the first cut of the
# v2 reader keyed the contract version off `.schema_version >= 2`. But
# schema_version is already taken — it is the ARTIFACT's own schema, versioned
# independently per artifact type. build-summary.json has been at 4 since #602.
# A result is identified by `result_contract`, which nothing else uses. Such an
# artifact is refused, and the reason proves which key was read: contract 1
# (absent result_contract), never schema_version's 4.
jq -nc '{schema_version:4,verdict:"fail",files_changed:[],iterations:1}' > "$_c3_result"
assert_eq "schema_version:4 artifact with no result_contract -> refused as contract 1" \
    "contract_violation:unsupported_contract:1" "$(runner_read_stage_reason "$STATE_DIR" "$c3_dir/manifest.yaml" "c3stage" 0)"
# And the two keys are orthogonal: a result may carry its own artifact schema.
jq -nc '{schema_version:4,result_contract:3,outcome:"pass",reason:"both keys present"}' > "$_c3_result"
assert_eq "result_contract:3 alongside schema_version:4 -> read as contract 3" \
    "complete" "$(runner_read_stage_disposition "$STATE_DIR" "$c3_dir/manifest.yaml" "c3stage" 0)"

print_test_section "an outcome that is how the stage ended is its disposition"
_write_c3 interrupted "SIGTERM mid-flight"
assert_eq "the disposition is the outcome" "interrupted" \
    "$(runner_read_stage_disposition "$STATE_DIR" "$c3_dir/manifest.yaml" "c3stage" 0)"
# A stage that did not finish is never a pass: it reads as raw `error`.
assert_eq "a stage that did not finish reads as error, not pass" "error" \
    "$(runner_read_stage_verdict "$STATE_DIR" "$c3_dir/manifest.yaml" "c3stage" 0)"
assert_eq "a v1 artifact is broken at rc 0 (#1850)" "broken" \
    "$(printf '%s' "$(jq -nc '{verdict:"pass"}' > "$_c3_result"; \
        runner_read_stage_disposition "$STATE_DIR" "$c3_dir/manifest.yaml" "c3stage" 0)")"

print_test_section "reason survives a non-zero exit (verdict.sh:315 discard removed)"
# THE REGRESSION THIS CLOSES: runner_read_stage_reason used to open with
# `if [[ "$rc" -ne 0 ]]; then echo ""; return 0; fi`, so a plugin that wrote a
# result and THEN returned non-zero — plan's `return 1` — left the engine
# holding only an integer. That is the mechanism by which a plan timeout kills
# a whole run.
_write_c3 timed_out "router timed out after 300s"
assert_eq "reason readable on rc=1" "router timed out after 300s" \
    "$(runner_read_stage_reason "$STATE_DIR" "$c3_dir/manifest.yaml" "c3stage" 1)"
# rc still wins for the CLASSIFIED verdict — that contract is unchanged.
assert_eq "rc=1 still classifies as fail" "fail" \
    "$(runner_read_stage_verdict "$STATE_DIR" "$c3_dir/manifest.yaml" "c3stage" 1)"
# A dispatch that died before writing anything yields empty — the honest answer,
# and what #1823's fallback classification keys on.
rm -f "$_c3_result"
assert_eq "no result written -> reason empty on rc=1" "" \
    "$(runner_read_stage_reason "$STATE_DIR" "$c3_dir/manifest.yaml" "c3stage" 1)"

# ─── Test: verdict_glyph + verdict_color non-empty ───────────────────────────
print_test_section "glyph + color tables"
assert_eq "glyph pass" "✓" "$(verdict_glyph pass)"
assert_eq "glyph warn" "⚠" "$(verdict_glyph warn)"
assert_eq "glyph fail" "✗" "$(verdict_glyph fail)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
