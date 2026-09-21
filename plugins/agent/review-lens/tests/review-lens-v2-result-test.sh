#!/usr/bin/env bash
# Tests: plugins/agent/review-lens — ONE advisory review lens as an isolated LLM
# stage (#1140 C1, ADR-040 §3). Each lens is its own first-class kind:agent stage:
# one isolated, redacted route_to_model call writes a normalized lens-<name>.json.
# Advisory only: a failed/unparseable/redaction-refused lens degrades to empty and
# the stage STILL returns 0 (never blocks merge).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "plugin: review-lens — v2 result contract (#1840): every exit path writes a v2 result; manifest declarations; parser recovery"
print_test_header "plugin: review-lens — single isolated advisory lens (#1140)"
setup_test_env "plugin-review-lens"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

# shellcheck source=../../../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
PLUGIN_DIR="$REPO_ROOT/plugins/agent/review-lens"
# shellcheck source=../../../../plugins/agent/review-lens/plugin.sh
source "$PLUGIN_DIR/plugin.sh"

# ─── Mocks ───────────────────────────────────────────────────────────────────
# In-process route_to_model shadow: record the prompt that reaches the model and
# return canned per-lens JSON. A FILE counter survives any subshell.
export _RL_CALLS="$TEST_TEMP_DIR/route-calls.log"
export _RL_PROMPT="$TEST_TEMP_DIR/last-prompt.txt"
: > "$_RL_CALLS"
# shellcheck disable=SC2329  # invoked indirectly by the sourced plugin
route_to_model() {
    printf 'call\n' >> "$_RL_CALLS"
    printf '%s' "$2" > "$_RL_PROMPT"
    if [[ "$2" == *'"security" review lens'* ]]; then
        printf '%s' '{"score":3,"findings":[{"file":"core/y.sh","category":"injection","severity":"CRITICAL","line":10,"message":"shell injection risk"}]}'
    elif [[ "$2" == *'"performance" review lens'* ]]; then
        printf '%s' '{"score":8,"findings":[{"file":"core/z.sh","category":"perf","severity":"low","line":3,"message":"repeated read"}]}'
    else
        printf '%s' '{"score":10,"findings":[]}'
    fi
    return 0
}
# ADR-043: redaction is owned by route_to_model (fully mocked above), so the
# plugin never calls apply_scope_redaction — no redaction stub is needed here.

artifact_dir="$TEST_TEMP_DIR/artifacts"
mkdir -p "$artifact_dir"
scope_manifest="$TEST_TEMP_DIR/scope-manifest.md"; printf '+ core/\n' > "$scope_manifest"
evidence="$artifact_dir/diff.patch"
cat > "$evidence" <<'EOF'
diff --git a/core/y.sh b/core/y.sh
+ exec user input at line 10
EOF

# #1840: v2 contract migration — acceptance assertions
# WIRING: plugins/agent/review-lens/manifest.yaml
# ═══════════════════════════════════════════════════════════════════════════════

# Restore a stable happy-path mock for the v2 tests below (captures prompt).
# shellcheck disable=SC2329
route_to_model() {
    printf 'call\n' >> "$_RL_CALLS"
    printf '%s' "$2" > "$_RL_PROMPT"
    printf '%s' '{"score":7,"findings":[{"file":"core/a.sh","category":"correctness","severity":"high","line":5,"message":"bug found"}]}'
    return 0
}

# ─── SPEC-7 [change]: manifest provides.result_contract == 2 and valid_verdicts ─
_1840_contract="$(yaml_get "$PLUGIN_DIR/manifest.yaml" "provides.result_contract" 2>/dev/null || true)"
assert_eq "[SPEC-7] manifest provides.result_contract == 2" "2" "$_1840_contract"
# config.valid_verdicts must declare both complete and degraded
_1840_vv_section="$(grep -A5 'valid_verdicts' "$PLUGIN_DIR/manifest.yaml" 2>/dev/null || true)"
if grep -q 'complete' <<< "$_1840_vv_section" && grep -q 'degraded' <<< "$_1840_vv_section"; then
    assert_pass "[SPEC-7] config.valid_verdicts declares complete and degraded"
else
    assert_fail "[SPEC-7] config.valid_verdicts must declare complete and degraded" \
        "${_1840_vv_section:-absent}"
fi
# validate_manifest must pass with the updated manifest
set +e
validate_manifest "$PLUGIN_DIR/manifest.yaml" >/dev/null 2>&1
_1840_vm_rc=$?
set -e
assert_eq "[SPEC-7] validate_manifest passes with result_contract:2 and valid_verdicts" \
    "0" "$_1840_vm_rc"

# ─── SPEC-12 [guard]: outputs[].lens_result declares primary: true ────────────
# Scoped to the lens_result stanza so a stray primary:true on a different output
# entry cannot satisfy this check.
_1840_s12_stanza="$(awk '
    /lens_result/ { found=1 }
    found && /^[[:space:]]*-[[:space:]]*id:/ && !/lens_result/ { exit }
    found { print }
' "$PLUGIN_DIR/manifest.yaml" 2>/dev/null || true)"
if grep -q 'primary: true' <<< "$_1840_s12_stanza"; then
    assert_pass "[SPEC-12] manifest.yaml outputs[].lens_result declares primary: true"
else
    assert_fail "[SPEC-12] manifest.yaml must declare primary: true on lens_result output" "absent"
fi

# ─── SPEC-11 [change]: _review_lens_write_result exists; no hardcoded paths ──
if grep -q '^_review_lens_write_result()' "$PLUGIN_DIR/plugin.sh" 2>/dev/null; then
    assert_pass "[SPEC-11] _review_lens_write_result function exists in plugin.sh"
else
    assert_fail "[SPEC-11] _review_lens_write_result must exist in plugin.sh" "absent"
fi
# Extract helper body (function declaration through closing brace at column 0)
_1840_helper_body="$(awk '
    /^_review_lens_write_result\(\)/ { found=1 }
    found { print }
    found && /^\}$/ { exit }
' "$PLUGIN_DIR/plugin.sh" 2>/dev/null || true)"
# Helper must contain no quoted literal artifact filenames (lens-*.json, scope-manifest.md)
if grep -qE '"lens-[^$"]*"|'"'"'lens-[^$'"'"']*'"'"'|"scope-manifest\.md"' <<< "$_1840_helper_body"; then
    assert_fail "[SPEC-11] _review_lens_write_result body must have no hardcoded artifact path literals" "found"
else
    assert_pass "[SPEC-11] _review_lens_write_result body derives paths solely from \$out parameter"
fi

# ─── review (#2165): the v1 degrade writer is gone — one write site, one guard ─
# _review_lens_write_result replaced every caller of _review_lens_empty; a
# second writer with a different atomic_write guard is a trap for the next edit.
if declare -F _review_lens_empty >/dev/null 2>&1; then
    assert_fail "[#1840-review] _review_lens_empty is removed (no callers remain)" "still defined"
else
    assert_pass "[#1840-review] _review_lens_empty is removed (no callers remain)"
fi

# ─── SPEC-1 [change]: success path writes result_contract:2 + v2 fields ──────
out_1840_s1="$artifact_dir/lens-1840spec1.json"
: > "$_RL_CALLS"
set +e
_review_lens_run_inner "1840spec1" "$scope_manifest" "$evidence" "$out_1840_s1" "$artifact_dir"
_1840_s1_rc=$?
set -e
assert_eq "[SPEC-1] success path returns 0" "0" "$_1840_s1_rc"
assert_file_exists "[SPEC-1] success path writes lens file" "$out_1840_s1"
assert_eq "[SPEC-1] result_contract == 2 on success" \
    "2" "$(jq -r '.result_contract // empty' "$out_1840_s1")"
assert_eq "[SPEC-1] verdict == complete on success" \
    "complete" "$(jq -r '.verdict // empty' "$out_1840_s1")"
assert_eq "[SPEC-1] disposition == complete on success" \
    "complete" "$(jq -r '.disposition // empty' "$out_1840_s1")"
_1840_s1_reason="$(jq -r '.reason // ""' "$out_1840_s1" 2>/dev/null || true)"
if [[ -n "$_1840_s1_reason" ]]; then
    assert_pass "[SPEC-1] reason is non-empty on success"
else
    assert_fail "[SPEC-1] reason must be non-empty on success" "empty"
fi
# Pre-existing fields must be unmodified
assert_eq "[SPEC-1] schema_version unchanged (1)" \
    "1" "$(jq -r '.schema_version' "$out_1840_s1")"
assert_eq "[SPEC-1] name unchanged (1840spec1)" \
    "1840spec1" "$(jq -r '.name' "$out_1840_s1")"
assert_eq "[SPEC-1] score intact" \
    "7" "$(jq -r '.score' "$out_1840_s1")"
assert_eq "[SPEC-1] findings[] present and intact (1 finding)" \
    "1" "$(jq '.findings | length' "$out_1840_s1")"

# ─── SPEC-2 [change]: router-failure degrade writes result_contract:2 ─────────
# shellcheck disable=SC2329
route_to_model() { printf 'call\n' >> "$_RL_CALLS"; return 2; }
out_1840_s2="$artifact_dir/lens-1840spec2.json"
set +e
_review_lens_run_inner "1840spec2" "$scope_manifest" "$evidence" "$out_1840_s2" "$artifact_dir"
set -e
assert_file_exists "[SPEC-2] router-failure degrade writes lens file" "$out_1840_s2"
assert_eq "[SPEC-2] result_contract == 2 on router failure" \
    "2" "$(jq -r '.result_contract // empty' "$out_1840_s2")"
assert_eq "[SPEC-2] verdict == degraded on router failure" \
    "degraded" "$(jq -r '.verdict // empty' "$out_1840_s2")"
assert_eq "[SPEC-2] disposition == broken on router failure" \
    "broken" "$(jq -r '.disposition // empty' "$out_1840_s2")"

# ─── SPEC-3 [change]: unparseable-reply degrade writes result_contract:2 ──────
# shellcheck disable=SC2329
route_to_model() { printf 'call\n' >> "$_RL_CALLS"; printf '%s' 'not json at all'; return 0; }
out_1840_s3="$artifact_dir/lens-1840spec3.json"
set +e
_review_lens_run_inner "1840spec3" "$scope_manifest" "$evidence" "$out_1840_s3" "$artifact_dir"
set -e
assert_file_exists "[SPEC-3] unparseable degrade writes lens file" "$out_1840_s3"
assert_eq "[SPEC-3] result_contract == 2 on unparseable reply" \
    "2" "$(jq -r '.result_contract // empty' "$out_1840_s3")"
assert_eq "[SPEC-3] verdict == degraded on unparseable reply" \
    "degraded" "$(jq -r '.verdict // empty' "$out_1840_s3")"
assert_eq "[SPEC-3] disposition == broken on unparseable reply" \
    "broken" "$(jq -r '.disposition // empty' "$out_1840_s3")"

# ─── SPEC-4 [change]: schema-gate recovery from postamble-bearing response ────
# The response has a valid lens object FIRST followed by a postamble containing
# a second JSON object that fails the schema gate (no .findings array).
# LAST-wins selects the broken postamble object; schema-gate recovery must find
# the valid first object — producing a valid lens result, NOT review_lens.unparseable.
_1840_postamble_resp='{"score":4,"findings":[{"file":"b.sh","severity":"low","line":2,"message":"nit"}]}
Some postamble reasoning text here.
{"not_a_lens_object":true,"no_findings_key":"wrong"}'
# shellcheck disable=SC2329
route_to_model() {
    printf 'call\n' >> "$_RL_CALLS"
    printf '%s' "$_1840_postamble_resp"
    return 0
}
out_1840_s4="$artifact_dir/lens-1840spec4.json"
: > "$ZBUILD_EVENTS_JSONL"
set +e
_review_lens_run_inner "1840spec4" "$scope_manifest" "$evidence" "$out_1840_s4" "$artifact_dir"
_1840_s4_rc=$?
set -e
assert_eq "[SPEC-4] schema-gate recovery returns 0" "0" "$_1840_s4_rc"
assert_file_exists "[SPEC-4] schema-gate recovery writes lens file" "$out_1840_s4"
# Must NOT emit unparseable event — recovery succeeded
if grep -q '"review_lens.unparseable"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_fail "[SPEC-4] schema-gate recovery must NOT emit review_lens.unparseable" "event emitted"
else
    assert_pass "[SPEC-4] no review_lens.unparseable when schema-gate recovery succeeds"
fi
# The recovered result must be valid (findings array present)
assert_eq "[SPEC-4] recovered lens result has valid findings array (1 finding)" \
    "1" "$(jq '.findings | length' "$out_1840_s4" 2>/dev/null || echo 0)"
# Confirm _llm_envelope_parse --schema-gate _review_lens_envelope_schema_ok is present in plugin.sh
if grep -q '_llm_envelope_parse.*--schema-gate.*_review_lens_envelope_schema_ok' \
    "$PLUGIN_DIR/plugin.sh" 2>/dev/null; then
    assert_pass "[SPEC-4] plugin.sh uses _llm_envelope_parse --schema-gate _review_lens_envelope_schema_ok"
else
    assert_fail "[SPEC-4] plugin.sh must use _llm_envelope_parse --schema-gate _review_lens_envelope_schema_ok" "absent"
fi

# ─── SPEC-5 [change]: ADR-063 budget guidance in prompt when max_turns > 0 ────
# Shadow _route_resolve_max_turns so the budget block fires regardless of manifest.
# Save original so it can be restored after this test — unset-f would destroy the
# plugin.sh definition, causing SPEC-6 Part 2 to fail with "command not found".
_1840_s5_orig_rrtm="$(declare -f _route_resolve_max_turns 2>/dev/null || true)"
# shellcheck disable=SC2329
_route_resolve_max_turns() { printf '12'; }
# shellcheck disable=SC2329
route_to_model() {
    printf '%s' "$2" > "$_RL_PROMPT"
    printf 'call\n' >> "$_RL_CALLS"
    printf '%s' '{"score":5,"findings":[]}'
    return 0
}
out_1840_s5="$artifact_dir/lens-1840spec5.json"
: > "$_RL_CALLS"
set +e
_review_lens_run_inner "1840spec5" "$scope_manifest" "$evidence" "$out_1840_s5" "$artifact_dir"
set -e
_1840_s5_prompt="$(cat "$_RL_PROMPT" 2>/dev/null || true)"
if grep -qi "TURN BUDGET" <<< "$_1840_s5_prompt"; then
    assert_pass "[SPEC-5] ADR-063 turn budget block appears in prompt when max_turns > 0"
else
    assert_fail "[SPEC-5] ADR-063 turn budget block must appear in prompt when max_turns > 0" "absent"
fi
unset -f _route_resolve_max_turns 2>/dev/null || true
# Restore the original plugin.sh definition so SPEC-6 Part 2 can call the real fn
if [[ -n "$_1840_s5_orig_rrtm" ]]; then eval "$_1840_s5_orig_rrtm"; fi
unset _1840_s5_orig_rrtm

# ─── SPEC-6 [change]: manifest declares router knobs; resolve fns return them ─
# Part 1: confirm the manifest declares both knobs
_1840_mf_timeout="$(manifest_router_knob "$PLUGIN_DIR/manifest.yaml" "timeout_s" 2>/dev/null || true)"
_1840_mf_maxturns="$(manifest_router_knob "$PLUGIN_DIR/manifest.yaml" "max_turns" 2>/dev/null || true)"
if [[ -n "$_1840_mf_timeout" ]]; then
    assert_pass "[SPEC-6] manifest declares config.router.timeout_s"
else
    assert_fail "[SPEC-6] manifest must declare config.router.timeout_s" "absent"
fi
if [[ -n "$_1840_mf_maxturns" ]]; then
    assert_pass "[SPEC-6] manifest declares config.router.max_turns"
else
    assert_fail "[SPEC-6] manifest must declare config.router.max_turns" "absent"
fi
# Part 2: _route_resolve_* return manifest values when no template or env override
_1840_prev_plugin_dir="${ZBUILD_PLUGIN_DIR:-__UNSET__}"
_1840_prev_stage="${ZBUILD_CURRENT_STAGE:-__UNSET__}"
_1840_prev_rt="${ZBUILD_ROUTER_TIMEOUT:-__UNSET__}"
_1840_prev_rm="${ZBUILD_ROUTER_MAX_TURNS:-__UNSET__}"
export ZBUILD_PLUGIN_DIR="$PLUGIN_DIR"
# Use a novel stage name that no template accessor function will match
export ZBUILD_CURRENT_STAGE="review-lens-1840-spec6-notemplate"
unset ZBUILD_ROUTER_TIMEOUT 2>/dev/null || true
unset ZBUILD_ROUTER_MAX_TURNS 2>/dev/null || true
# Ensure the standard template accessor names are not defined for this test stage
# (they return empty for unknown stages, so _route_resolve_knob falls through to manifest)
_1840_resolved_timeout="$(_route_resolve_timeout)"
_1840_resolved_maxturns="$(_route_resolve_max_turns)"
assert_eq "[SPEC-6] _route_resolve_timeout returns manifest config.router.timeout_s" \
    "$_1840_mf_timeout" "$_1840_resolved_timeout"
assert_eq "[SPEC-6] _route_resolve_max_turns returns manifest config.router.max_turns" \
    "$_1840_mf_maxturns" "$_1840_resolved_maxturns"
# Restore
[[ "$_1840_prev_plugin_dir" == "__UNSET__" ]] && unset ZBUILD_PLUGIN_DIR \
    || export ZBUILD_PLUGIN_DIR="$_1840_prev_plugin_dir"
[[ "$_1840_prev_stage" == "__UNSET__" ]] && unset ZBUILD_CURRENT_STAGE \
    || export ZBUILD_CURRENT_STAGE="$_1840_prev_stage"
[[ "$_1840_prev_rt" == "__UNSET__" ]] && unset ZBUILD_ROUTER_TIMEOUT \
    || export ZBUILD_ROUTER_TIMEOUT="$_1840_prev_rt"
[[ "$_1840_prev_rm" == "__UNSET__" ]] && unset ZBUILD_ROUTER_MAX_TURNS \
    || export ZBUILD_ROUTER_MAX_TURNS="$_1840_prev_rm"

# ─── SPEC-8 [guard]: existing advisory degrade behavior unchanged ─────────────
# Router failure path: rc=0, review_lens.failed emitted, advisory-absence language.
# shellcheck disable=SC2329
route_to_model() { printf 'call\n' >> "$_RL_CALLS"; return 2; }
out_1840_s8f="$artifact_dir/lens-1840spec8fail.json"
rm -f "$artifact_dir/lens-1840spec8fail-summary.md" 2>/dev/null || true
: > "$ZBUILD_EVENTS_JSONL"
set +e
_review_lens_run_inner "1840spec8fail" "$scope_manifest" "$evidence" "$out_1840_s8f" "$artifact_dir"
_1840_s8f_rc=$?
set -e
assert_eq "[SPEC-8] router failure rc=0 (advisory never blocks)" "0" "$_1840_s8f_rc"
if grep -q '"review_lens.failed"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_pass "[SPEC-8] review_lens.failed event emitted on router failure"
else
    assert_fail "[SPEC-8] review_lens.failed event must be emitted on router failure" "absent"
fi
_1840_s8f_summary="$(cat "$artifact_dir/lens-1840spec8fail-summary.md" 2>/dev/null || true)"
if grep -qi "Absence\|Advisory" <<< "$_1840_s8f_summary"; then
    assert_pass "[SPEC-8] stage summary contains advisory-absence language on router failure"
else
    assert_fail "[SPEC-8] stage summary must contain advisory-absence language on router failure" \
        "${_1840_s8f_summary:-absent}"
fi
# Unparseable path: rc=0, review_lens.unparseable emitted, advisory-absence language.
# shellcheck disable=SC2329
route_to_model() { printf 'call\n' >> "$_RL_CALLS"; printf '%s' 'not json'; return 0; }
out_1840_s8u="$artifact_dir/lens-1840spec8unparse.json"
rm -f "$artifact_dir/lens-1840spec8unparse-summary.md" 2>/dev/null || true
: > "$ZBUILD_EVENTS_JSONL"
set +e
_review_lens_run_inner "1840spec8unparse" "$scope_manifest" "$evidence" "$out_1840_s8u" "$artifact_dir"
_1840_s8u_rc=$?
set -e
assert_eq "[SPEC-8] unparseable rc=0 (advisory never blocks)" "0" "$_1840_s8u_rc"
if grep -q '"review_lens.unparseable"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_pass "[SPEC-8] review_lens.unparseable event emitted on unparseable reply"
else
    assert_fail "[SPEC-8] review_lens.unparseable event must be emitted on unparseable reply" "absent"
fi
_1840_s8u_summary="$(cat "$artifact_dir/lens-1840spec8unparse-summary.md" 2>/dev/null || true)"
if grep -qi "Absence\|Advisory" <<< "$_1840_s8u_summary"; then
    assert_pass "[SPEC-8] stage summary contains advisory-absence language on unparseable reply"
else
    assert_fail "[SPEC-8] stage summary must contain advisory-absence language on unparseable reply" \
        "${_1840_s8u_summary:-absent}"
fi

# ─── SPEC-9 [change]: passing run output is backward-compatible — v1 fields present and unmodified ─
# Every pre-existing v1 field (schema_version, name, score, findings[]) must survive
# the v2 migration unchanged; the v2 additions (result_contract, verdict, disposition,
# reason) must coexist with them. If any v1 field were dropped this block fails on the
# empty/null result from jq.
# shellcheck disable=SC2329
route_to_model() {
    printf 'call\n' >> "$_RL_CALLS"
    printf '%s' "$2" > "$_RL_PROMPT"
    printf '%s' '{"score":6,"findings":[{"file":"core/b.sh","category":"correctness","severity":"medium","line":3,"message":"null deref"}]}'
    return 0
}
out_1840_s9="$artifact_dir/lens-1840spec9.json"
: > "$_RL_CALLS"
set +e
_review_lens_run_inner "1840spec9" "$scope_manifest" "$evidence" "$out_1840_s9" "$artifact_dir"
_1840_s9_rc=$?
set -e
assert_eq "[SPEC-9] success path returns 0" "0" "$_1840_s9_rc"
assert_file_exists "[SPEC-9] success path writes lens file" "$out_1840_s9"
# v1 fields must be present with correct values — absence produces empty string, which fails
assert_eq "[SPEC-9] v1 field schema_version present and == 1" \
    "1" "$(jq -r '.schema_version // empty' "$out_1840_s9")"
assert_eq "[SPEC-9] v1 field name present and unmodified (== 1840spec9)" \
    "1840spec9" "$(jq -r '.name // empty' "$out_1840_s9")"
assert_eq "[SPEC-9] v1 field score present and unmodified (== 6)" \
    "6" "$(jq -r '.score // empty' "$out_1840_s9")"
assert_eq "[SPEC-9] v1 field findings[] present with 1 entry (unmodified)" \
    "1" "$(jq '.findings | length' "$out_1840_s9")"
# v2 additions must also be present — coexistence with v1 fields proves additive-only change
assert_eq "[SPEC-9] v2 field result_contract present and == 2 (additive)" \
    "2" "$(jq -r '.result_contract // empty' "$out_1840_s9")"
_1840_s9_verdict="$(jq -r '.verdict // empty' "$out_1840_s9" 2>/dev/null || true)"
if [[ -n "$_1840_s9_verdict" ]]; then
    assert_pass "[SPEC-9] v2 field verdict present (additive)"
else
    assert_fail "[SPEC-9] v2 field verdict must be present alongside v1 fields (additive)" "absent"
fi
_1840_s9_disposition="$(jq -r '.disposition // empty' "$out_1840_s9" 2>/dev/null || true)"
if [[ -n "$_1840_s9_disposition" ]]; then
    assert_pass "[SPEC-9] v2 field disposition present (additive)"
else
    assert_fail "[SPEC-9] v2 field disposition must be present alongside v1 fields (additive)" "absent"
fi
_1840_s9_reason="$(jq -r '.reason // empty' "$out_1840_s9" 2>/dev/null || true)"
if [[ -n "$_1840_s9_reason" ]]; then
    assert_pass "[SPEC-9] v2 field reason present (additive)"
else
    assert_fail "[SPEC-9] v2 field reason must be present alongside v1 fields (additive)" "absent"
fi

# ─── SPEC-10 [change]: merge-action coercion tokens absent; verdict appears only as jq field in _review_lens_write_result ─
# Part 1: approve, request_changes, "block" tokens remain absent from plugin source.
if grep -qiE '\b(approve|request_changes)\b|"block"' \
    "$PLUGIN_DIR/plugin.sh" "$PLUGIN_DIR/lib/charters.sh"; then
    assert_fail "[SPEC-10] merge-action coercion tokens absent from review-lens source" "found"
else
    assert_pass "[SPEC-10] merge-action tokens (approve|request_changes|block) absent"
fi
# Part 2: after migration, 'verdict' appears in _review_lens_write_result as a jq
# field; confirm the helper exists and contains 'verdict', and that the
# coercion-vocabulary grep above does NOT match it — the two must be compatible.
if grep -q '^_review_lens_write_result()' "$PLUGIN_DIR/plugin.sh" 2>/dev/null; then
    _1840_s10_helper="$(awk '/^_review_lens_write_result\(\)/{f=1} f{print} f && /^\}$/{exit}' \
        "$PLUGIN_DIR/plugin.sh" 2>/dev/null || true)"
    # "verdict" must appear as a jq field (.verdict, "verdict":, verdict:<val>, or --arg verdict),
    # not merely as a comment word — bare string match does not establish jq field.
    if grep -qE '\.verdict[^a-z_]|"verdict"|--arg[[:space:]]+verdict|verdict:[^a-zA-Z_]' <<< "$_1840_s10_helper"; then
        assert_pass "[SPEC-10] verdict appears in _review_lens_write_result body as jq field"
    else
        assert_fail "[SPEC-10] verdict must appear in _review_lens_write_result body (jq field)" "absent"
    fi
    # The amended coercion grep (approve|request_changes|block) must NOT fire on the helper body
    if grep -qiE '\b(approve|request_changes)\b|"block"' <<< "$_1840_s10_helper"; then
        assert_fail "[SPEC-10] _review_lens_write_result body must not contain merge-action tokens" "found"
    else
        assert_pass "[SPEC-10] amended coercion grep does not false-positive on verdict jq field"
    fi
else
    assert_fail "[SPEC-10] _review_lens_write_result must exist for SPEC-10 to be verifiable" "absent"
fi


cleanup_test_env
print_test_results
exit $((FAIL > 0))
