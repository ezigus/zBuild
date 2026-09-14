#!/usr/bin/env bash
# Tests: plugins/agent/review-report — evidence-fed multi-lens merge-readiness
# report (#972, ADR-038). Advisory only: N separate lens LLM calls, aggregated +
# de-duped, NO verdict coercion, NEVER hard-blocks.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "review-report plugin — multi-lens advisory report (#972)"
setup_test_env "review-report-plugin"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
mkdir -p "$ZBUILD_EVENTS_DIR"

# shellcheck source=../../plugins/agent/review-report/plugin.sh
source "$REPO_ROOT/plugins/agent/review-report/plugin.sh"

# Per-lens route_to_model stub: the prompt names the lens; return canned findings.
# Call count is recorded to a FILE because each lens runs in a subshell (a var
# increment would not propagate to the parent).
export _RR_CALLS="$TEST_TEMP_DIR/route-calls.log"
: > "$_RR_CALLS"
route_to_model() {
    printf 'call\n' >> "$_RR_CALLS"
    local prompt="$2"
    if [[ "$prompt" == *'"correctness" review lens'* ]]; then
        printf '%s' '{"score":6,"findings":[{"file":"core/x.sh","category":"logic","severity":"medium","line":42,"message":"off-by-one in loop"}]}'
    elif [[ "$prompt" == *'"security" review lens'* ]]; then
        printf '%s' '{"score":3,"findings":[{"file":"core/x.sh","category":"logic","severity":"high","line":47,"message":"same region higher severity"},{"file":"core/y.sh","category":"injection","severity":"critical","line":10,"message":"shell injection risk"}]}'
    elif [[ "$prompt" == *'"integration" review lens'* ]]; then
        printf '%s' '{"score":10,"findings":[]}'
    elif [[ "$prompt" == *'"error-handling" review lens'* ]]; then
        printf '%s' '{"score":10,"findings":[]}'
    elif [[ "$prompt" == *'"performance" review lens'* ]]; then
        printf '%s' '{"score":10,"findings":[]}'
    elif [[ "$prompt" == *'"edge-case" review lens'* ]]; then
        printf '%s' '{"score":10,"findings":[]}'
    elif [[ "$prompt" == *'"architecture" review lens'* ]]; then
        printf '%s' '{"score":10,"findings":[]}'
    elif [[ "$prompt" == *'"red-team" review lens'* ]]; then
        printf '%s' '{"score":10,"findings":[]}'
    elif [[ "$prompt" == *'"maintainability" review lens'* ]]; then
        printf '%s' '{"score":10,"findings":[]}'
    else
        printf '%s' '{"score":10,"findings":[]}'
    fi
    return 0
}
# shellcheck disable=SC2329  # invoked indirectly by the sourced plugin's fan-out
apply_scope_redaction() { cp "$1" "$2"; return 0; }

artifact_dir="$TEST_TEMP_DIR/artifacts"
mkdir -p "$artifact_dir"
scope_manifest="$TEST_TEMP_DIR/scope-manifest.md"; touch "$scope_manifest"
evidence="$artifact_dir/diff.patch"
cat > "$evidence" <<'EOF'
diff --git a/core/x.sh b/core/x.sh
+ risky change near line 42-47
diff --git a/core/y.sh b/core/y.sh
+ exec user input at line 10
EOF
out_json="$artifact_dir/review-report.json"
out_md="$artifact_dir/review-report.md"

set +e
_rr_run_inner "$scope_manifest" "$evidence" "$out_json" "$out_md"
_run_rc=$?
set -e

# ─── SPEC-1: N-way lens fan-out — 11 separate LLM calls, 11 lens sections ─────
assert_eq "[SPEC-1] run returns 0 (advisory never aborts)" "0" "$_run_rc"
_call_count="$(wc -l < "$_RR_CALLS" | tr -d ' ')"
assert_eq "[SPEC-1] one LLM call per lens (11 separate calls, not 1 prompt)" "11" "$_call_count"
assert_eq "[SPEC-1] report has 11 lenses" "11" "$(jq '.lenses | length' "$out_json")"
for _lens in correctness security test-coverage design-conformance integration error-handling performance edge-case architecture red-team maintainability; do
    assert_contains "[SPEC-1] md has lens section: $_lens" "$(cat "$out_md")" "#### $_lens"
done

# ─── SPEC-2: aggregate + de-dupe by file + category + proximity ──────────────
# x.sh logic @42 (correctness) and @47 (security) are within the 10-line window
# → ONE merged finding carrying both lenses + max severity (high). y.sh stays
# separate. Expect 2 flat findings total.
assert_eq "[SPEC-2] flat findings de-duped to 2" "2" "$(jq '.findings | length' "$out_json")"
_merged="$(jq -c '.findings[] | select(.file=="core/x.sh")' "$out_json")"
assert_contains "[SPEC-2] merged finding carries both lenses" "$_merged" "correctness"
assert_contains "[SPEC-2] merged finding carries both lenses" "$_merged" "security"
assert_eq "[SPEC-2] merged finding takes MAX severity (high)" "high" "$(jq -r '.findings[] | select(.file=="core/x.sh") | .severity' "$out_json")"

# ─── SPEC-3: advisory only — no verdict coercion, never hard-blocks ──────────
# A critical finding (+ a lens score <=3) yields needs_attention but the stage
# STILL returns 0 and the report carries NO verdict field.
assert_eq "[SPEC-3] critical finding → merge_readiness=needs_attention" "needs_attention" "$(jq -r '.merge_readiness' "$out_json")"
if jq -e '.verdict' "$out_json" >/dev/null 2>&1; then
    assert_fail "[SPEC-3] report must carry NO verdict field" "found .verdict"
else
    assert_pass "[SPEC-3] report carries no verdict field"
fi
# Source-level no-coercion proof: the plugin never emits a merge decision.
if grep -qiE '\b(approve|request_changes)\b|"block"|verdict' \
    "$REPO_ROOT"/plugins/agent/review-report/plugin.sh \
    "$REPO_ROOT"/plugins/agent/review-report/lib/lenses.sh; then
    assert_fail "[SPEC-3] no coercion vocabulary in plugin source" "found coercion token"
else
    assert_pass "[SPEC-3] no coercion vocabulary in plugin source"
fi
# (The former regression-lock against the legacy verdict-coercing `review`
# plugin was dropped with #979 — that plugin is retired.)

# ─── SPEC-4: rendered CONTENT, not just non-empty (PR #1004 jq-bug lock) ─────
# The per-lens bullet list must NOT be silently blanked. Assert a known message
# is present as a bullet (the bug rendered an empty section).
_md="$(cat "$out_md")"
assert_contains "[SPEC-4] correctness section names its score" "$_md" "#### correctness (score: 6/10)"
assert_contains "[SPEC-4] lens bullet renders the finding message (not blank)" "$_md" "off-by-one in loop"
assert_contains "[SPEC-4] de-duped section renders contributing lenses" "$_md" "lenses: correctness, security"

# ─── SPEC-6: report is advisory and always routes (ADR-043) ──────────────────
# Redaction is now owned by route_to_model (mocked here), so review-report no
# longer has a per-plugin redaction-refusal degrade path — the report always
# routes its lenses and is written. Fail-closed on a missing/empty manifest is
# the router's job (covered by the router precondition tests).
: > "$_RR_CALLS"
out2_json="$artifact_dir/review-report-2.json"
out2_md="$artifact_dir/review-report-2.md"
set +e
_rr_run_inner "$scope_manifest" "$evidence" "$out2_json" "$out2_md"
_rc2=$?
set -e
assert_eq "[SPEC-6] report run returns 0 (advisory)" "0" "$_rc2"
assert_file_exists "[SPEC-6] a report is written" "$out2_json"
if [[ "$(wc -l < "$_RR_CALLS" | tr -d ' ')" -ge 1 ]]; then
    assert_pass "[SPEC-6] lenses route through route_to_model (redaction chokepoint)"
else
    assert_fail "[SPEC-6] lenses must route through route_to_model" "no LLM call"
fi

# ─── SPEC-7: markdown-injection hardening + proximity clamp (Copilot #1028) ──
# LLM-controlled message with a newline + backtick + ANSI must not break the
# bullet layout: render via the registered renderer and assert it is sanitized.
_adv_report="$(jq -nc '{schema_version:1, merge_readiness:"advisory",
  lenses:[{name:"correctness",score:5,findings:[
    {file:"core/x.sh",category:"logic",severity:"high",line:7,
     message:"line1\nline2 `tick`"}]}],
  findings:[{file:"core/x.sh",category:"logic",line:7,severity:"high",
     lenses:["correctness"],messages:["line1\nline2 `tick`"]}],
  summary:"adv"}')"
_adv_md="$(render_review_report_md "$_adv_report")"
# here-strings (NOT the pipe-into-grep SIGPIPE antipattern guarded by #1015).
if grep -q '`tick`' <<< "$_adv_md"; then
    assert_fail "[SPEC-7] backtick in LLM message must be escaped" "raw backtick present"
else
    assert_pass "[SPEC-7] backtick in LLM message is escaped"
fi
# The finding bullet must stay a single line (newline collapsed to a space).
if grep -qE '^- \[high\] core/x.sh:7 .*line1 line2' <<< "$_adv_md"; then
    assert_pass "[SPEC-7] newline in LLM message collapsed (bullet stays one line)"
else
    assert_fail "[SPEC-7] newline must be collapsed in the bullet" "bullet split across lines"
fi
# Proximity window of 0 (or garbage) must clamp, not crash the aggregate.
_clamp="$(ZBUILD_RR_PROXIMITY_WINDOW=0 _rr_aggregate "$artifact_dir/review-report-lenses.json" 2>/dev/null | jq -r '.merge_readiness // "ERR"')"
assert_contains "[SPEC-7] bad proximity window clamps (no aggregation crash)" "ready advisory needs_attention" "$_clamp"

# ─── SPEC-8: new cq audit lenses resolve to named charter branches ────────────
# Each new lens must return a non-empty charter that contains a key phrase from
# its named case branch — NOT the wildcard fallback text (I8a, ADR-038 §4).
_charter_int="$(_rr_lens_charter integration)"
assert_contains "[SPEC-8] integration charter names mismatched interfaces" "$_charter_int" "interfaces"
_charter_eh="$(_rr_lens_charter error-handling)"
assert_contains "[SPEC-8] error-handling charter names silent error swallowing" "$_charter_eh" "silent error"
_charter_perf="$(_rr_lens_charter performance)"
assert_contains "[SPEC-8] performance charter names O(n^2) pattern" "$_charter_perf" "O(n^2)"
_charter_ec="$(_rr_lens_charter edge-case)"
assert_contains "[SPEC-8] edge-case charter names zero-length inputs" "$_charter_ec" "zero-length"

# ─── SPEC-9: architecture lens resolves to named charter branch ───────────────
_charter_arch="$(_rr_lens_charter architecture)"
assert_contains "[SPEC-9] architecture charter names layer-boundary violations" "$_charter_arch" "layer-boundary"

# ─── SPEC-10: red-team lens resolves to named charter branch ─────────────────
_charter_rt="$(_rr_lens_charter red-team)"
assert_contains "[SPEC-10] red-team charter names race conditions" "$_charter_rt" "race condition"

# ─── SPEC-11: maintainability lens resolves to named charter branch ───────────
_charter_maint="$(_rr_lens_charter maintainability)"
assert_contains "[SPEC-11] maintainability charter names code smells" "$_charter_maint" "code smell"

# ─── SPEC-12: _RR_LENSES sourced from manifest config.lenses, not hardcoded ──
# Change spec: _rr_load_lenses function must exist (absent at baseline).
if declare -f _rr_load_lenses >/dev/null 2>&1; then
    assert_pass "[SPEC-12] _rr_load_lenses function exists (roster is manifest-driven)"
else
    assert_fail "[SPEC-12] _rr_load_lenses function must exist (manifest-driven roster)" "function absent"
fi
# The loaded _RR_LENSES content must match the manifest config.lenses section.
_manifest_lenses="$(awk '
    BEGIN { in_cfg=0; in_lst=0 }
    /^config:$/              { in_cfg=1; next }
    in_cfg && /^[^ ]/        { in_cfg=0; in_lst=0; next }
    in_cfg && /^  lenses:$/  { in_lst=1; next }
    in_lst && /^  [^ #]/     { in_lst=0 }
    in_lst && /^    - [a-z]/ { val=substr($0,7); gsub(/[[:space:]]+$/,"",val); if (val!="") printf "%s ", val }
' "$REPO_ROOT/plugins/agent/review-report/manifest.yaml" | sed 's/ $//')"
_actual_lenses="${_RR_LENSES[*]}"
assert_eq "[SPEC-12] _RR_LENSES content matches manifest config.lenses" \
    "$_manifest_lenses" "$_actual_lenses"

# ─── SPEC-13: needs_attention report carries escalation_note + routing note ───
# Change spec: _rr_aggregate must emit escalation_note when merge_readiness=needs_attention.
# out_json is from the main run above (security lens score=3 + critical finding → needs_attention).
_esc_note="$(jq -r '.escalation_note // empty' "$out_json" 2>/dev/null)"
if [[ -n "$_esc_note" ]]; then
    assert_pass "[SPEC-13] needs_attention JSON carries non-empty escalation_note"
else
    assert_fail "[SPEC-13] needs_attention report must carry escalation_note in JSON" "field absent or null"
fi
assert_contains "[SPEC-13] rendered markdown contains the routing advisory blockquote" \
    "$(cat "$out_md")" "Advisory:"

# ─── SPEC-14: _rr_lens_evidence — registered lens returns path, unregistered empty ─
if declare -f _rr_lens_evidence >/dev/null 2>&1; then
    _spec14_artifact="$TEST_TEMP_DIR/spec14-artifact.txt"
    printf 'spec14 content\n' > "$_spec14_artifact"
    _RR_LENS_ARTIFACT_REGISTRY[correctness]="$_spec14_artifact"
    _spec14_result="$(_rr_lens_evidence "correctness" "$artifact_dir")"
    assert_eq "[SPEC-14] registered lens returns its artifact path" \
        "$_spec14_artifact" "$_spec14_result"
    _spec14_result2="$(_rr_lens_evidence "security" "$artifact_dir")"
    assert_eq "[SPEC-14] unregistered lens returns empty stdout" \
        "" "$_spec14_result2"
    unset '_RR_LENS_ARTIFACT_REGISTRY[correctness]'
else
    assert_fail "[SPEC-14] _rr_lens_evidence function must exist" "function absent"
fi

# ─── SPEC-15: per-lens artifact wires into prompt; unregistered falls back ───
apply_scope_redaction() { cp "$1" "$2"; return 0; }   # restore for per-lens test
_spec15_dir="$TEST_TEMP_DIR/spec15"
mkdir -p "$_spec15_dir"
printf 'SHARED BUNDLE DATA\n' > "$_spec15_dir/diff.patch"
_spec15_artifact="$TEST_TEMP_DIR/spec15-correctness.txt"
printf 'CORRECTNESS SPECIFIC ARTIFACT\n' > "$_spec15_artifact"
declare -A _RR_LENS_ARTIFACT_REGISTRY 2>/dev/null || true
_RR_LENS_ARTIFACT_REGISTRY[correctness]="$_spec15_artifact"
: > "$_RR_CALLS"
set +e
_rr_fanout_lenses "$scope_manifest" "$_spec15_dir/diff.patch" "$_spec15_dir" "T2"
set -e
_correctness_prompt="$(cat "$_spec15_dir/lens-correctness-prompt.txt" 2>/dev/null || echo MISSING)"
_security_prompt="$(cat "$_spec15_dir/lens-security-prompt.txt" 2>/dev/null || echo MISSING)"
assert_contains "[SPEC-15] correctness prompt embeds per-lens artifact content" \
    "$_correctness_prompt" "CORRECTNESS SPECIFIC ARTIFACT"
assert_contains "[SPEC-15] security prompt uses shared bundle (no per-lens artifact)" \
    "$_security_prompt" "SHARED BUNDLE DATA"
unset '_RR_LENS_ARTIFACT_REGISTRY[correctness]'

# ─── SPEC-3: _rr_populate_artifact_registry registers design-conformance ──────
# CHANGE: _rr_populate_artifact_registry absent at merge-base. After
# implementation, function must exist and set _RR_LENS_ARTIFACT_REGISTRY
# ["design-conformance"] to the reachability-ablation.json path when non-empty.

if declare -f _rr_populate_artifact_registry >/dev/null 2>&1; then
    assert_pass "[SPEC-3] _rr_populate_artifact_registry function exists"
    _spec3_dir="$TEST_TEMP_DIR/spec3"
    mkdir -p "$_spec3_dir"
    _spec3_ablation="$_spec3_dir/reachability-ablation.json"
    printf '{"negctl_verdict":"pass","negctl_detail":"ABLATION_NEGCTL PASS","reachability_verdict":"pass","reachability_detail":"ABLATION_REACH PASS"}\n' \
        > "$_spec3_ablation"
    # Reset registry entry so we start from a clean state.
    unset '_RR_LENS_ARTIFACT_REGISTRY[design-conformance]'
    _rr_populate_artifact_registry "$_spec3_dir"
    _spec3_reg="${_RR_LENS_ARTIFACT_REGISTRY[design-conformance]:-}"
    assert_eq "[SPEC-3] design-conformance registered to reachability-ablation.json" \
        "$_spec3_ablation" "$_spec3_reg"
    # Verify no-op when file is absent.
    unset '_RR_LENS_ARTIFACT_REGISTRY[design-conformance]'
    _rr_populate_artifact_registry "$TEST_TEMP_DIR/nonexistent-dir"
    _spec3_noop="${_RR_LENS_ARTIFACT_REGISTRY[design-conformance]:-}"
    assert_eq "[SPEC-3] _rr_populate_artifact_registry is no-op when ablation absent" \
        "" "$_spec3_noop"
else
    assert_fail "[SPEC-3] _rr_populate_artifact_registry function must exist" "function absent"
    assert_fail "[SPEC-3] design-conformance registered to reachability-ablation.json" "function absent"
    assert_fail "[SPEC-3] _rr_populate_artifact_registry is no-op when ablation absent" "function absent"
fi

# ─── SPEC-4: design-conformance prompt embeds ablation artifact content ───────
# CHANGE: design-conformance lens had no registered artifact at merge-base and
# fell back to the shared diff bundle. After implementation, _rr_run_inner calls
# _rr_populate_artifact_registry so the prompt for design-conformance contains
# the reachability-ablation.json evidence, not the shared bundle.

apply_scope_redaction() { cp "$1" "$2"; return 0; }   # restore for this test
_spec4_dir="$TEST_TEMP_DIR/spec4"
mkdir -p "$_spec4_dir"
_spec4_ablation="$_spec4_dir/reachability-ablation.json"
printf '{"negctl_verdict":"pass","negctl_detail":"ABLATION_NEGCTL PASS","reachability_verdict":"skip","reachability_detail":"SPEC4_UNIQUE_ABLATION_CONTENT"}\n' \
    > "$_spec4_ablation"
printf 'SHARED BUNDLE DATA ONLY\n' > "$_spec4_dir/diff.patch"
# Reset registry so _rr_run_inner's populate call wires it fresh.
unset '_RR_LENS_ARTIFACT_REGISTRY[design-conformance]'
set +e
_rr_run_inner "$scope_manifest" "$_spec4_dir/diff.patch" \
    "$_spec4_dir/review-report.json" "$_spec4_dir/review-report.md"
set -e
_spec4_dc_prompt="$(cat "$_spec4_dir/lens-design-conformance-prompt.txt" 2>/dev/null || echo MISSING)"
assert_contains "[SPEC-4] design-conformance prompt contains ablation artifact content" \
    "$_spec4_dc_prompt" "SPEC4_UNIQUE_ABLATION_CONTENT"
_spec4_sec_prompt="$(cat "$_spec4_dir/lens-security-prompt.txt" 2>/dev/null || echo MISSING)"
assert_contains "[SPEC-4] security prompt still uses shared bundle (not ablation)" \
    "$_spec4_sec_prompt" "SHARED BUNDLE DATA ONLY"
# ─── SPEC-3: _rr_register_lens_artifact exists and updates _RR_LENS_ARTIFACT_REGISTRY ─
# CHANGE: function absent at merge-base. After implementation it must exist and
# set _RR_LENS_ARTIFACT_REGISTRY[<lens>]=<path> so callers can wire evidence
# without sourcing private internals.

if declare -f _rr_register_lens_artifact >/dev/null 2>&1; then
    _spec3_artifact="$TEST_TEMP_DIR/spec3-artifact.txt"
    printf 'SPEC3 CONTENT\n' > "$_spec3_artifact"
    _rr_register_lens_artifact "test-coverage" "$_spec3_artifact"
    _spec3_registered="${_RR_LENS_ARTIFACT_REGISTRY[test-coverage]:-}"
    assert_eq "[SPEC-3] _rr_register_lens_artifact sets registry entry" \
        "$_spec3_artifact" "$_spec3_registered"
    unset '_RR_LENS_ARTIFACT_REGISTRY[test-coverage]'
else
    assert_fail "[SPEC-3] _rr_register_lens_artifact function must exist" "function absent"
fi

# ─── SPEC-4: _rr_run_inner wires coverage-map.json to test-coverage lens ─────
# CHANGE: at merge-base _rr_run_inner never called _rr_register_lens_artifact, so
# test-coverage always received the shared diff bundle. After implementation it must
# register coverage-map.json for test-coverage when the file exists in artifact_dir.

apply_scope_redaction() { cp "$1" "$2"; return 0; }   # ensure cp-stub active
unset _RR_LENS_ARTIFACT_REGISTRY; declare -A _RR_LENS_ARTIFACT_REGISTRY  # hard reset
_spec4_dir="$TEST_TEMP_DIR/spec4"
mkdir -p "$_spec4_dir"
printf '{"files":[{"file":"core/x.sh","covered":5,"total":10,"pct":50.0}],"total_pct":50.0}\n' \
    > "$_spec4_dir/coverage-map.json"
printf 'SPEC4 SHARED BUNDLE\n' > "$_spec4_dir/diff.patch"
: > "$_RR_CALLS"
set +e
_rr_run_inner "$scope_manifest" "$_spec4_dir/diff.patch" \
    "$_spec4_dir/review-report.json" "$_spec4_dir/review-report.md"
_spec4_rc=$?
set -e

assert_eq "[SPEC-4] _rr_run_inner returns 0 when coverage-map present" "0" "$_spec4_rc"

# ─── SPEC-5: test-coverage lens prompt embeds coverage-map content ────────────
# CHANGE: at merge-base test-coverage always got the shared bundle. After
# implementation the prompt file must contain the coverage-map artifact content.

_spec5_tc_prompt="$(cat "$_spec4_dir/lens-test-coverage-prompt.txt" 2>/dev/null || echo MISSING)"
assert_contains "[SPEC-5] test-coverage prompt embeds coverage-map file entry" \
    "$_spec5_tc_prompt" "core/x.sh"
_spec5_sec_prompt="$(cat "$_spec4_dir/lens-security-prompt.txt" 2>/dev/null || echo MISSING)"
assert_contains "[SPEC-5] security prompt uses shared bundle (no per-lens override)" \
    "$_spec5_sec_prompt" "SPEC4 SHARED BUNDLE"

# ─── SPEC-6: fail-soft — test-coverage falls back to shared bundle when absent ─
# GUARD: when coverage-map.json is absent, _rr_run_inner must still return 0 and
# the test-coverage lens must receive the shared diff bundle (no hard failure).

unset _RR_LENS_ARTIFACT_REGISTRY; declare -A _RR_LENS_ARTIFACT_REGISTRY  # hard reset
_spec6_dir="$TEST_TEMP_DIR/spec6"
mkdir -p "$_spec6_dir"
# Intentionally NO coverage-map.json in this dir.
printf 'SPEC6 SHARED BUNDLE\n' > "$_spec6_dir/diff.patch"
: > "$_RR_CALLS"
set +e
_rr_run_inner "$scope_manifest" "$_spec6_dir/diff.patch" \
    "$_spec6_dir/review-report.json" "$_spec6_dir/review-report.md"
_spec6_rc=$?
set -e

assert_eq "[SPEC-6] _rr_run_inner returns 0 when coverage-map absent (fail-soft)" "0" "$_spec6_rc"
_spec6_tc_prompt="$(cat "$_spec6_dir/lens-test-coverage-prompt.txt" 2>/dev/null || echo MISSING)"
assert_contains "[SPEC-6] test-coverage falls back to shared bundle when map absent" \
    "$_spec6_tc_prompt" "SPEC6 SHARED BUNDLE"

# ════════════════════════════════════════════════════════════════════════════
# Contract v2 migration SPECs (#1843): result_contract:2, _rr_write_result,
# _rr_budget_guidance, schema-gated parse, ZBUILD_STAGE_INPUTS reading, and
# disposition=exhausted for partial lens failures.
# (test-author stage failed with router_timeout; assertions authored here)
# ════════════════════════════════════════════════════════════════════════════

_V2_MANIFEST="$REPO_ROOT/plugins/agent/review-report/manifest.yaml"
_V2_PLUGIN="$REPO_ROOT/plugins/agent/review-report/plugin.sh"
_V2_LENSES="$REPO_ROOT/plugins/agent/review-report/lib/lenses.sh"

# ─── SPEC-1: manifest declares result_contract:2 and config.router: block ────
if grep -q 'result_contract: 2' "$_V2_MANIFEST"; then
    assert_pass "[SPEC-1] manifest declares result_contract: 2 under provides:"
else
    assert_fail "[SPEC-1] manifest must declare result_contract: 2 under provides:" "not found"
fi
if grep -q 'timeout_s:' "$_V2_MANIFEST"; then
    assert_pass "[SPEC-1] manifest config.router declares timeout_s"
else
    assert_fail "[SPEC-1] manifest config.router must declare timeout_s" "not found"
fi
if grep -q 'max_turns:' "$_V2_MANIFEST"; then
    assert_pass "[SPEC-1] manifest config.router declares max_turns"
else
    assert_fail "[SPEC-1] manifest config.router must declare max_turns" "not found"
fi

# ─── SPEC-2: _rr_write_result helper exists and writes conformant v2 result ──
if grep -q '_rr_write_result' "$_V2_PLUGIN"; then
    assert_pass "[SPEC-2] _rr_write_result helper declared in plugin.sh"
else
    assert_fail "[SPEC-2] _rr_write_result must be declared in plugin.sh" "absent"
fi
_s2v2_dir="$TEST_TEMP_DIR/spec2v2"
mkdir -p "$_s2v2_dir"
_rr_write_result "$_s2v2_dir" "pass" "complete" "test_reason"
assert_file_exists "[SPEC-2] _rr_write_result writes review-report-result.json" \
    "$_s2v2_dir/review-report-result.json"
assert_eq "[SPEC-2] written file has result_contract:2" "2" \
    "$(jq -r '.result_contract' "$_s2v2_dir/review-report-result.json" 2>/dev/null || echo missing)"
assert_eq "[SPEC-2] written file has verdict field" "pass" \
    "$(jq -r '.verdict' "$_s2v2_dir/review-report-result.json" 2>/dev/null || echo missing)"
assert_eq "[SPEC-2] written file has disposition field" "complete" \
    "$(jq -r '.disposition' "$_s2v2_dir/review-report-result.json" 2>/dev/null || echo missing)"
assert_eq "[SPEC-2] written file has reason field" "test_reason" \
    "$(jq -r '.reason' "$_s2v2_dir/review-report-result.json" 2>/dev/null || echo missing)"

# ─── SPEC-3: v2 result written verdict=error, disposition=broken on missing state_file ─
_s3v2_dir="$TEST_TEMP_DIR/spec3v2"
mkdir -p "$_s3v2_dir"
export ZBUILD_ARTIFACT_DIR="$_s3v2_dir"
set +e
review_report_run "" "" 2>/dev/null
set -e
unset ZBUILD_ARTIFACT_DIR
assert_file_exists "[SPEC-3] result sidecar written on missing state_file" \
    "$_s3v2_dir/review-report-result.json"
assert_eq "[SPEC-3] verdict=error on missing state_file" "error" \
    "$(jq -r '.verdict' "$_s3v2_dir/review-report-result.json" 2>/dev/null || echo missing)"
assert_eq "[SPEC-3] disposition=broken on missing state_file" "broken" \
    "$(jq -r '.disposition' "$_s3v2_dir/review-report-result.json" 2>/dev/null || echo missing)"
assert_eq "[SPEC-3] result_contract:2 on missing state_file" "2" \
    "$(jq -r '.result_contract' "$_s3v2_dir/review-report-result.json" 2>/dev/null || echo missing)"

# ─── SPEC-4: v2 result written verdict=error, disposition=broken on missing out_json ─
_s4v2_dir="$TEST_TEMP_DIR/spec4v2"
mkdir -p "$_s4v2_dir"
export ZBUILD_ARTIFACT_DIR="$_s4v2_dir"
set +e
_rr_run_inner "$scope_manifest" "$evidence" "" "" 2>/dev/null
set -e
unset ZBUILD_ARTIFACT_DIR
assert_file_exists "[SPEC-4] result sidecar written on missing out_json" \
    "$_s4v2_dir/review-report-result.json"
assert_eq "[SPEC-4] verdict=error on missing out_json" "error" \
    "$(jq -r '.verdict' "$_s4v2_dir/review-report-result.json" 2>/dev/null || echo missing)"
assert_eq "[SPEC-4] disposition=broken on missing out_json" "broken" \
    "$(jq -r '.disposition' "$_s4v2_dir/review-report-result.json" 2>/dev/null || echo missing)"
assert_eq "[SPEC-4] result_contract:2 on missing out_json" "2" \
    "$(jq -r '.result_contract' "$_s4v2_dir/review-report-result.json" 2>/dev/null || echo missing)"

# ─── SPEC-5: v2 result sidecar written verdict=pass, disposition=complete on normal completion ─
_s5v2_dir="$TEST_TEMP_DIR/spec5v2"
mkdir -p "$_s5v2_dir"
cp "$evidence" "$_s5v2_dir/diff.patch"
: > "$_RR_CALLS"
set +e
_rr_run_inner "$scope_manifest" "$_s5v2_dir/diff.patch" \
    "$_s5v2_dir/review-report.json" "$_s5v2_dir/review-report.md"
_s5v2_rc=$?
set -e
assert_eq "[SPEC-5] _rr_run_inner returns 0 on normal completion" "0" "$_s5v2_rc"
assert_file_exists "[SPEC-5] v2 result sidecar written on normal completion" \
    "$_s5v2_dir/review-report-result.json"
assert_eq "[SPEC-5] verdict=pass on normal completion" "pass" \
    "$(jq -r '.verdict' "$_s5v2_dir/review-report-result.json" 2>/dev/null || echo missing)"
assert_eq "[SPEC-5] disposition=complete on normal completion (all lens rc=0)" "complete" \
    "$(jq -r '.disposition' "$_s5v2_dir/review-report-result.json" 2>/dev/null || echo missing)"
assert_eq "[SPEC-5] result_contract:2 on normal completion" "2" \
    "$(jq -r '.result_contract' "$_s5v2_dir/review-report-result.json" 2>/dev/null || echo missing)"

# ─── SPEC-6: _rr_budget_guidance helper exists and injects TURN BUDGET into lens prompts ─
if declare -f _rr_budget_guidance >/dev/null 2>&1; then
    assert_pass "[SPEC-6] _rr_budget_guidance function exists in plugin.sh"
else
    assert_fail "[SPEC-6] _rr_budget_guidance function must exist in plugin.sh" "function absent"
fi
_s6v2_guidance="$(_rr_budget_guidance 25 300)"
assert_contains "[SPEC-6] _rr_budget_guidance produces TURN BUDGET block" \
    "$_s6v2_guidance" "TURN BUDGET"
assert_contains "[SPEC-6] _rr_budget_guidance embeds max_turns value" \
    "$_s6v2_guidance" "25"
_s6v2_dir="$TEST_TEMP_DIR/spec6v2"
mkdir -p "$_s6v2_dir"
cp "$evidence" "$_s6v2_dir/diff.patch"
_rr_fanout_lenses "$scope_manifest" "$_s6v2_dir/diff.patch" "$_s6v2_dir" "T2" "$_s6v2_guidance" >/dev/null 2>&1 || true
_s6v2_prompt="$(cat "$_s6v2_dir/lens-correctness-prompt.txt" 2>/dev/null || echo MISSING)"
assert_contains "[SPEC-6] correctness lens prompt contains TURN BUDGET guidance from _rr_budget_guidance" \
    "$_s6v2_prompt" "TURN BUDGET"

# ─── SPEC-7: _rr_lens_envelope_schema_ok predicate exists and validates {score,findings} ─
if declare -f _rr_lens_envelope_schema_ok >/dev/null 2>&1; then
    assert_pass "[SPEC-7] _rr_lens_envelope_schema_ok predicate exists"
else
    assert_fail "[SPEC-7] _rr_lens_envelope_schema_ok predicate must exist" "function absent"
fi
if grep -qE '_rr_lens_envelope_schema_ok[[:space:]]*\(\)|function[[:space:]]+_rr_lens_envelope_schema_ok' "$_V2_LENSES"; then
    assert_pass "[SPEC-7] _rr_lens_envelope_schema_ok is defined in lenses.sh"
else
    assert_fail "[SPEC-7] _rr_lens_envelope_schema_ok must be defined in lenses.sh" "definition absent from lenses.sh"
fi
if _rr_lens_envelope_schema_ok '{"score":8,"findings":[]}' 2>/dev/null; then
    assert_pass "[SPEC-7] schema gate accepts valid {score:number, findings:array}"
else
    assert_fail "[SPEC-7] schema gate must accept {score:number, findings:array}" "rejected valid input"
fi
if ! _rr_lens_envelope_schema_ok '{"verdict":"pass"}' 2>/dev/null; then
    assert_pass "[SPEC-7] schema gate rejects object missing score and findings"
else
    assert_fail "[SPEC-7] schema gate must reject object without score/findings" "accepted invalid"
fi
if ! _rr_lens_envelope_schema_ok '"just a string"' 2>/dev/null; then
    assert_pass "[SPEC-7] schema gate rejects non-object input"
else
    assert_fail "[SPEC-7] schema gate must reject non-object" "accepted non-object"
fi

# ─── SPEC-8: _rr_parse_lens_out routes through _llm_envelope_parse --schema-gate ─
if grep -q 'extract_first_json_object' "$_V2_LENSES"; then
    assert_fail "[SPEC-8] lenses.sh must not contain extract_first_json_object (bare extract)" "found"
else
    assert_pass "[SPEC-8] extract_first_json_object absent from lenses.sh"
fi
if grep -q '_llm_envelope_parse' "$_V2_LENSES"; then
    assert_pass "[SPEC-8] lenses.sh uses _llm_envelope_parse for lens output parsing"
else
    assert_fail "[SPEC-8] _rr_parse_lens_out must use _llm_envelope_parse" "call absent"
fi
if grep -q -- '--schema-gate' "$_V2_LENSES"; then
    assert_pass "[SPEC-8] _rr_parse_lens_out calls _llm_envelope_parse with --schema-gate"
else
    assert_fail "[SPEC-8] _rr_parse_lens_out must use --schema-gate option" "flag absent"
fi
if grep -qE -- '--schema-gate[[:space:]]+_rr_lens_envelope_schema_ok' "$_V2_LENSES"; then
    assert_pass "[SPEC-8] --schema-gate argument is _rr_lens_envelope_schema_ok in lenses.sh"
else
    assert_fail "[SPEC-8] _rr_parse_lens_out must pass _rr_lens_envelope_schema_ok to --schema-gate" "exact argument absent"
fi

# ─── SPEC-9: _rr_run_inner returns 0 and advisory review-report.json written (GUARD) ─
assert_eq "[SPEC-9] _rr_run_inner returns 0 (advisory contract: never blocks)" "0" "$_run_rc"
assert_file_exists "[SPEC-9] advisory review-report.json written on normal completion" "$out_json"
_s9v2_mr="$(jq -r '.merge_readiness // empty' "$out_json" 2>/dev/null || true)"
if [[ -n "$_s9v2_mr" ]]; then
    assert_pass "[SPEC-9] advisory report contains merge_readiness field"
else
    assert_fail "[SPEC-9] advisory report must contain merge_readiness" "field absent"
fi

# ─── SPEC-10: 11 independent LLM calls still made, one per lens (GUARD) ─────
assert_eq "[SPEC-10] 11 independent LLM calls made (one per lens)" "11" "$_call_count"
assert_eq "[SPEC-10] advisory report has 11 lens result sections" "11" \
    "$(jq '.lenses | length' "$out_json")"

# ─── SPEC-11: manifest declares valid_verdicts: [] (GUARD) ──────────────────
if grep -q 'valid_verdicts: \[\]' "$_V2_MANIFEST"; then
    assert_pass "[SPEC-11] manifest declares valid_verdicts: [] (writes no verdict to pipeline channel)"
else
    assert_fail "[SPEC-11] manifest must declare valid_verdicts: []" "not found"
fi

# ─── SPEC-12: manifest first output (review_report) retains primary: true (GUARD) ─
if grep -q 'primary: true' "$_V2_MANIFEST"; then
    assert_pass "[SPEC-12] manifest first output retains primary: true after migration"
else
    assert_fail "[SPEC-12] manifest must have primary: true on first output" "not found"
fi

# ─── SPEC-13: manifest provides.role: review_report and 4 declared events (GUARD) ─
if grep -q 'role: review_report' "$_V2_MANIFEST"; then
    assert_pass "[SPEC-13] manifest provides.role: review_report present"
else
    assert_fail "[SPEC-13] manifest must declare provides.role: review_report" "not found"
fi
for _s13v2_ev in \
    "review_report.evidence.redaction_failed" \
    "review_report.lens.evidence.redaction_failed" \
    "review_report.lens.failed" \
    "review_report.lens.unparseable"; do
    if grep -q "$_s13v2_ev" "$_V2_MANIFEST"; then
        assert_pass "[SPEC-13] manifest declares event: $_s13v2_ev"
    else
        assert_fail "[SPEC-13] manifest must declare event: $_s13v2_ev" "event absent"
    fi
done

# ─── SPEC-14: no active cleanup hook in manifest; no review_report_cleanup function (GUARD) ─
# cleanup: ~ is the null sentinel (absent-and-recorded per ADR-001 §2); acceptable.
_s14v2_active=""
while IFS= read -r _s14v2_line; do
    [[ "$_s14v2_line" =~ ^[[:space:]]*# ]] && continue
    [[ "$_s14v2_line" =~ cleanup:[[:space:]]*~ ]] && continue
    [[ "$_s14v2_line" =~ cleanup: ]] && { _s14v2_active="$_s14v2_line"; break; }
done < "$_V2_MANIFEST"
if [[ -z "$_s14v2_active" ]]; then
    assert_pass "[SPEC-14] manifest has no active cleanup hook (absent or null sentinel cleanup: ~)"
else
    assert_fail "[SPEC-14] manifest must not have an active cleanup hook" "active entry: $_s14v2_active"
fi
if ! grep -q 'review_report_cleanup' "$_V2_PLUGIN"; then
    assert_pass "[SPEC-14] no review_report_cleanup function in plugin.sh"
else
    assert_fail "[SPEC-14] plugin.sh must not define review_report_cleanup" "found"
fi

# ─── SPEC-15: review_report_run reads scope_manifest from ZBUILD_STAGE_INPUTS ─
if grep -q 'ZBUILD_STAGE_INPUTS' "$_V2_PLUGIN"; then
    assert_pass "[SPEC-15] plugin.sh references ZBUILD_STAGE_INPUTS for declared inputs"
else
    assert_fail "[SPEC-15] plugin.sh must reference ZBUILD_STAGE_INPUTS" "reference absent"
fi
if grep -qE "jq -r.*inputs.scope_manifest" "$_V2_PLUGIN"; then
    assert_pass "[SPEC-15] plugin.sh calls jq -r with .inputs.scope_manifest from ZBUILD_STAGE_INPUTS"
else
    assert_fail "[SPEC-15] plugin.sh must call jq -r .inputs.scope_manifest from ZBUILD_STAGE_INPUTS" "pattern absent"
fi

# ─── SPEC-16: disposition=exhausted when at least one lens subshell returns non-zero rc ─
_s16v2_dir="$TEST_TEMP_DIR/spec16v2"
mkdir -p "$_s16v2_dir"
cp "$evidence" "$_s16v2_dir/diff.patch"
# Override route_to_model so the correctness lens returns rc=1 (signals budget exhaustion).
route_to_model() {
    printf 'call\n' >> "$_RR_CALLS"
    local prompt="${2:-}"
    if [[ "$prompt" == *'"correctness" review lens'* ]]; then
        return 1
    fi
    printf '%s' '{"score":10,"findings":[]}'
    return 0
}
: > "$_RR_CALLS"
set +e
_rr_run_inner "$scope_manifest" "$_s16v2_dir/diff.patch" \
    "$_s16v2_dir/review-report.json" "$_s16v2_dir/review-report.md" 2>/dev/null
set -e
assert_file_exists "[SPEC-16] result sidecar written when at least one lens fails" \
    "$_s16v2_dir/review-report-result.json"
assert_eq "[SPEC-16] verdict=pass when lens fails (advisory contract preserved)" "pass" \
    "$(jq -r '.verdict' "$_s16v2_dir/review-report-result.json" 2>/dev/null || echo missing)"
assert_eq "[SPEC-16] disposition=exhausted when at least one lens subshell returns non-zero rc" "exhausted" \
    "$(jq -r '.disposition' "$_s16v2_dir/review-report-result.json" 2>/dev/null || echo missing)"
# Restore original route_to_model stub for any subsequent tests.
route_to_model() {
    printf 'call\n' >> "$_RR_CALLS"
    local prompt="$2"
    if [[ "$prompt" == *'"correctness" review lens'* ]]; then
        printf '%s' '{"score":6,"findings":[{"file":"core/x.sh","category":"logic","severity":"medium","line":42,"message":"off-by-one in loop"}]}'
    elif [[ "$prompt" == *'"security" review lens'* ]]; then
        printf '%s' '{"score":3,"findings":[{"file":"core/x.sh","category":"logic","severity":"high","line":47,"message":"same region higher severity"},{"file":"core/y.sh","category":"injection","severity":"critical","line":10,"message":"shell injection risk"}]}'
    elif [[ "$prompt" == *'"integration" review lens'* ]]; then
        printf '%s' '{"score":10,"findings":[]}'
    elif [[ "$prompt" == *'"error-handling" review lens'* ]]; then
        printf '%s' '{"score":10,"findings":[]}'
    elif [[ "$prompt" == *'"performance" review lens'* ]]; then
        printf '%s' '{"score":10,"findings":[]}'
    elif [[ "$prompt" == *'"edge-case" review lens'* ]]; then
        printf '%s' '{"score":10,"findings":[]}'
    elif [[ "$prompt" == *'"architecture" review lens'* ]]; then
        printf '%s' '{"score":10,"findings":[]}'
    elif [[ "$prompt" == *'"red-team" review lens'* ]]; then
        printf '%s' '{"score":10,"findings":[]}'
    elif [[ "$prompt" == *'"maintainability" review lens'* ]]; then
        printf '%s' '{"score":10,"findings":[]}'
    else
        printf '%s' '{"score":10,"findings":[]}'
    fi
    return 0
}

# ─── SPEC-17: plugin.sh has no hardcoded state_dir path for any declared input id ─
_s17v2_found=0
for _s17v2_name in "scope-manifest.md" "plan.json" "diff.patch" "intake.md" "intake-goal.md"; do
    if grep -qE "state_dir.*${_s17v2_name}|${_s17v2_name}.*state_dir" "$_V2_PLUGIN"; then
        _s17v2_found=1
        break
    fi
done
if [[ "$_s17v2_found" -eq 0 ]]; then
    assert_pass "[SPEC-17] plugin.sh constructs no hardcoded state_dir path for declared input filenames"
else
    assert_fail "[SPEC-17] plugin.sh must not concat state_dir with declared input filename" "hardcoded path found"
fi

print_test_results
