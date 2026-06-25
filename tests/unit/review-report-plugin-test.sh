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
# Regression-lock: the legacy verdict plugin is UNTOUCHED (still coerces).
if grep -q "request_changes" "$REPO_ROOT/plugins/agent/review/plugin.sh"; then
    assert_pass "[SPEC-3] legacy review plugin still emits verdicts (not neutered)"
else
    assert_fail "[SPEC-3] legacy review plugin should be untouched" "request_changes missing"
fi

# ─── SPEC-4: rendered CONTENT, not just non-empty (PR #1004 jq-bug lock) ─────
# The per-lens bullet list must NOT be silently blanked. Assert a known message
# is present as a bullet (the bug rendered an empty section).
_md="$(cat "$out_md")"
assert_contains "[SPEC-4] correctness section names its score" "$_md" "#### correctness (score: 6/10)"
assert_contains "[SPEC-4] lens bullet renders the finding message (not blank)" "$_md" "off-by-one in loop"
assert_contains "[SPEC-4] de-duped section renders contributing lenses" "$_md" "lenses: correctness, security"

# ─── SPEC-6: redaction refusal degrades gracefully, still advisory (rc 0) ────
apply_scope_redaction() { return 1; }   # force the chokepoint to refuse
: > "$_RR_CALLS"
out2_json="$artifact_dir/review-report-2.json"
out2_md="$artifact_dir/review-report-2.md"
set +e
_rr_run_inner "$scope_manifest" "$evidence" "$out2_json" "$out2_md"
_rc2=$?
set -e
assert_eq "[SPEC-6] redaction refusal still returns 0" "0" "$_rc2"
assert_eq "[SPEC-6] no LLM call when redaction refuses" "0" "$(wc -l < "$_RR_CALLS" | tr -d ' ')"
if [[ -s "$out2_json" ]]; then
    assert_pass "[SPEC-6] a report is still written on redaction refusal"
else
    assert_fail "[SPEC-6] a report must still be written" "missing"
fi
if grep -q "review_report.evidence.redaction_failed" "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_pass "[SPEC-6] redaction_failed event emitted"
else
    assert_fail "[SPEC-6] redaction_failed event should be emitted" "absent"
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

print_test_results
