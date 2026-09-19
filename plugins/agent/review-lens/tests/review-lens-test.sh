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

print_test_header "plugin: review-lens — single isolated advisory lens (#1140)"
setup_test_env "plugin-review-lens"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

# ─── Plugin is discoverable + manifest validates ────────────────────────────
# shellcheck source=../../../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
PLUGIN_DIR="$REPO_ROOT/plugins/agent/review-lens"
set +e
validate_manifest "$PLUGIN_DIR/manifest.yaml" >/dev/null 2>&1
rc=$?
set -e
assert_eq "review-lens manifest validates (kind: agent + requires.core)" "0" "$rc"
discovered="$(discover_plugins "$REPO_ROOT/plugins")"
assert_contains "review-lens is discovered" "$discovered" "agent/review-lens"

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

# ─── SPEC-1: ONE isolated LLM call → normalized lens-<name>.json ─────────────
out="$artifact_dir/lens-security.json"
: > "$_RL_CALLS"
set +e
_review_lens_run_inner "security" "$scope_manifest" "$evidence" "$out" "$artifact_dir"
_rc=$?
set -e
assert_eq "[#1140-1] run returns 0 (advisory never aborts)" "0" "$_rc"
assert_eq "[#1140-1] exactly ONE LLM call for the lens" "1" "$(wc -l < "$_RL_CALLS" | tr -d ' ')"
assert_file_exists "[#1140-1] writes lens-security.json" "$out"
assert_eq "[#1140-1] normalized name == lens id" "security" "$(jq -r '.name' "$out")"
assert_eq "[#1140-1] schema_version present" "1" "$(jq -r '.schema_version' "$out")"
assert_eq "[#1140-1] score floored to integer" "3" "$(jq -r '.score' "$out")"
assert_eq "[#1140-1] findings normalized (1 finding)" "1" "$(jq '.findings | length' "$out")"
assert_eq "[#1140-1] severity lowercased to enum" "critical" "$(jq -r '.findings[0].severity' "$out")"

# ─── SPEC-2: redaction reaches the model; raw text never sent without it ─────
_p="$(cat "$_RL_PROMPT")"
assert_contains "[#1140-2] redacted evidence reached the prompt" "$_p" "exec user input at line 10"
assert_contains "[#1140-2] prompt carries the security charter (not wildcard)" "$_p" "injection risks"
assert_contains "[#1140-2] prompt is the single-lens advisory contract" "$_p" '"security" review lens'

# ─── SPEC-3: parametrized — SAME plugin serves a different lens (charter swap) ─
out_perf="$artifact_dir/lens-performance.json"
: > "$_RL_CALLS"
set +e
_review_lens_run_inner "performance" "$scope_manifest" "$evidence" "$out_perf" "$artifact_dir"
set -e
assert_eq "[#1140-3] performance lens name" "performance" "$(jq -r '.name' "$out_perf")"
assert_eq "[#1140-3] performance score" "8" "$(jq -r '.score' "$out_perf")"
_pp="$(cat "$_RL_PROMPT")"
assert_contains "[#1140-3] performance charter swapped in" "$_pp" "O(n^2)"

# ─── SPEC-4: empty evidence STILL routes (ADR-043 / #952) ────────────────────
# The former empty-evidence guard skipped redaction on an empty change bundle,
# which left redaction.applied off the event stream and tripped the router C6
# precondition — refusing every lens (the observed #952 failure). ADR-043 moves
# redaction into route_to_model (owned by the router, not the plugin), so the
# guard is gone: an empty bundle must STILL route and produce a lens result.
out_empty="$artifact_dir/lens-correctness.json"
empty_evidence="$artifact_dir/empty-diff.patch"
: > "$empty_evidence"
: > "$_RL_CALLS"
set +e
_review_lens_run_inner "correctness" "$scope_manifest" "$empty_evidence" "$out_empty" "$artifact_dir"
_rc_empty=$?
set -e
assert_eq "[#1140-4] empty evidence still returns 0" "0" "$_rc_empty"
assert_eq "[#1140-4] empty evidence STILL routes — one LLM call (#952)" "1" "$(wc -l < "$_RL_CALLS" | tr -d ' ')"
assert_file_exists "[#1140-4] lens result written for empty evidence" "$out_empty"

# ─── SPEC-5: unparseable model output degrades to empty + event + rc 0 ───────
# shellcheck disable=SC2329  # re-defined mock invoked indirectly by the plugin
route_to_model() { printf 'call\n' >> "$_RL_CALLS"; printf '%s' 'not json at all'; return 0; }
out_bad="$artifact_dir/lens-edge-case.json"
: > "$_RL_CALLS"
set +e
_review_lens_run_inner "edge-case" "$scope_manifest" "$evidence" "$out_bad" "$artifact_dir"
_rc_bad=$?
set -e
assert_eq "[#1140-5] unparseable output returns 0 (fail-open)" "0" "$_rc_bad"
assert_eq "[#1140-5] unparseable yields empty findings" "0" "$(jq '.findings | length' "$out_bad")"
if grep -q '"review_lens.unparseable"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_pass "[#1140-5] review_lens.unparseable event emitted"
else
    assert_fail "[#1140-5] review_lens.unparseable event should be emitted" "absent"
fi

# ─── SPEC-6: router failure (rc!=0) degrades to empty + review_lens.failed ───
# shellcheck disable=SC2329  # re-defined mock invoked indirectly by the plugin
route_to_model() { printf 'call\n' >> "$_RL_CALLS"; return 2; }
out_fail="$artifact_dir/lens-integration.json"
set +e
_review_lens_run_inner "integration" "$scope_manifest" "$evidence" "$out_fail" "$artifact_dir"
_rc_fail=$?
set -e
assert_eq "[#1140-6] router failure returns 0 (advisory never blocks)" "0" "$_rc_fail"
assert_eq "[#1140-6] router failure yields empty findings" "0" "$(jq '.findings | length' "$out_fail")"
if grep -q '"review_lens.failed"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_pass "[#1140-6] review_lens.failed event emitted"
else
    assert_fail "[#1140-6] review_lens.failed event should be emitted" "absent"
fi
# restore happy mock
# shellcheck disable=SC2329  # re-defined mock invoked indirectly by the plugin
route_to_model() {
    printf 'call\n' >> "$_RL_CALLS"; printf '%s' "$2" > "$_RL_PROMPT"
    printf '%s' '{"score":10,"findings":[]}'; return 0
}

# ─── SPEC-7: lens id resolution + hook contract (ZBUILD_REVIEW_LENS_ID) ──────
STATE_DIR="$TEST_TEMP_DIR/state"
mkdir -p "$STATE_DIR/artifacts"
STATE_FILE="$STATE_DIR/pipeline-state.json"
echo '{"schema_version":1,"run_id":"rl-hook-001","issue":"0","stage_statuses":{}}' > "$STATE_FILE"
printf '+ core/\n' > "$STATE_DIR/scope-manifest.md"
printf 'diff --git a/core/a.sh b/core/a.sh\n+ change\n' > "$STATE_DIR/artifacts/diff.patch"
set +e
ZBUILD_REVIEW_LENS_ID="red-team" review_lens_run "review-lens" "$STATE_FILE" >/dev/null 2>&1
_rc_hook=$?
set -e
assert_eq "[#1140-7] review_lens_run(stage, state_file) returns 0" "0" "$_rc_hook"
assert_file_exists "[#1140-7] hook derives lens-<id>.json from ZBUILD_REVIEW_LENS_ID" \
    "$STATE_DIR/artifacts/lens-red-team.json"
# stage-id prefix stripping: stage `lens_maintainability` → maintainability charter
set +e
ZBUILD_CURRENT_STAGE="lens_maintainability" review_lens_run "lens_maintainability" "$STATE_FILE" >/dev/null 2>&1
set -e
assert_file_exists "[#1140-7] stage-id prefix stripped (lens_maintainability → maintainability)" \
    "$STATE_DIR/artifacts/lens-maintainability.json"

# ─── SPEC-8: per-lens evidence selection — test-coverage prefers coverage-map ─
_ev_default="$(_review_lens_evidence_path "security" "$artifact_dir")"
assert_eq "[#1140-8] default lens evidence falls back to diff.patch" \
    "$artifact_dir/diff.patch" "$_ev_default"
printf '{"files":[{"file":"core/x.sh"}]}\n' > "$artifact_dir/coverage-map.json"
_ev_cov="$(_review_lens_evidence_path "test-coverage" "$artifact_dir")"
assert_eq "[#1140-8] test-coverage lens prefers coverage-map.json when present" \
    "$artifact_dir/coverage-map.json" "$_ev_cov"

# ─── SPEC-9: no merge-decision vocabulary in plugin source (advisory, ADR-040) ─
# [#1840/SPEC-10] 'verdict' is removed from this check: after the v2 migration
# _review_lens_write_result uses 'verdict' as a jq field, not a coercion token.
# SPEC-10 below independently verifies the full story.
if grep -qiE '\b(approve|request_changes)\b|"block"' \
    "$PLUGIN_DIR/plugin.sh" "$PLUGIN_DIR/lib/charters.sh"; then
    assert_fail "[#1140-9] no coercion vocabulary in review-lens source" "found coercion token"
else
    assert_pass "[#1140-9] no coercion vocabulary in review-lens source"
fi

# ─── SPEC-10: persona manifest charter takes precedence over case statement ───
# When a kind:persona manifest exists for the lens id (with persona.perspective),
# _rl_lens_charter must use its text instead of the case-statement fallback.
_prev_plugins_root="${ZBUILD_PLUGINS_ROOT:-}"
_spec10_plugins="$TEST_TEMP_DIR/spec10-plugins"
mkdir -p "$_spec10_plugins/persona/test-lens"
cat > "$_spec10_plugins/persona/test-lens/manifest.yaml" <<'SPEC10_EOF'
id: test-lens
name: Test Lens Persona
kind: persona
version: 0.1.0
persona:
  role: a test lens persona
  perspective: SENTINEL_PERSONA_CHARTER_XYZ987
SPEC10_EOF
export ZBUILD_PLUGINS_ROOT="$_spec10_plugins"
out_spec10="$artifact_dir/lens-test-lens.json"
: > "$_RL_CALLS"
set +e
_review_lens_run_inner "test-lens" "$scope_manifest" "$evidence" "$out_spec10" "$artifact_dir"
_rc_spec10=$?
set -e
_pp_spec10="$(cat "$_RL_PROMPT")"
assert_eq "[#1140-10] persona manifest lens returns 0 (advisory)" "0" "$_rc_spec10"
assert_contains "[#1140-10] persona charter text reaches the prompt" \
    "$_pp_spec10" "SENTINEL_PERSONA_CHARTER_XYZ987"
# Ensure the wildcard fallback text is NOT used when persona manifest exists
if grep -q "Examine the change for issues relevant to the test-lens concern" <<< "$_pp_spec10"; then
    assert_fail "[#1140-10] wildcard fallback must NOT fire when persona manifest exists" "wildcard text found"
else
    assert_pass "[#1140-10] wildcard fallback is suppressed by persona manifest"
fi
export ZBUILD_PLUGINS_ROOT="$_prev_plugins_root"

# ─── SPEC-11 [SPEC-6]: live-tree correctness persona parity ──────────────────
# With ZBUILD_PLUGINS_ROOT pointing at the live repo plugins tree,
# _rl_lens_charter('correctness') must return the manifest perspective text
# (containing 'logic errors') and must NOT fall through to the wildcard fallback.
_prev_plugins_root_spec11="${ZBUILD_PLUGINS_ROOT:-}"
export ZBUILD_PLUGINS_ROOT="$REPO_ROOT/plugins"
_corr_charter="$(_rl_lens_charter "correctness")"
case "$_corr_charter" in
    *"logic errors"*) corr_charter_ok=1 ;;
    *) corr_charter_ok=0 ;;
esac
assert_eq "[#1140-11] correctness charter from live manifest contains 'logic errors'" "1" "$corr_charter_ok"
if grep -q "Examine the change for issues relevant to the correctness concern" <<< "$_corr_charter"; then
    assert_fail "[#1140-11] wildcard fallback must NOT fire when correctness manifest exists" "wildcard text found"
else
    assert_pass "[#1140-11] wildcard fallback is suppressed by correctness persona manifest"
fi
export ZBUILD_PLUGINS_ROOT="$_prev_plugins_root_spec11"

# ─── SPEC-12 [SPEC-6]: live-tree scope persona parity ────────────────────────
# With ZBUILD_PLUGINS_ROOT pointing at the live repo plugins tree,
# _rl_lens_charter('scope') must return the manifest perspective text
# (containing 'WARN ONLY') and must NOT fall through to the wildcard fallback.
_prev_plugins_root_spec12="${ZBUILD_PLUGINS_ROOT:-}"
export ZBUILD_PLUGINS_ROOT="$REPO_ROOT/plugins"
_scope_charter="$(_rl_lens_charter "scope")"
case "$_scope_charter" in
    *"WARN ONLY"*) scope_charter_ok=1 ;;
    *) scope_charter_ok=0 ;;
esac
assert_eq "[#1140-12] scope charter from live manifest contains 'WARN ONLY'" "1" "$scope_charter_ok"
if grep -q "Examine the change for issues relevant to the scope concern" <<< "$_scope_charter"; then
    assert_fail "[#1140-12] wildcard fallback must NOT fire when scope manifest exists" "wildcard text found"
else
    assert_pass "[#1140-12] wildcard fallback is suppressed by scope persona manifest"
fi
export ZBUILD_PLUGINS_ROOT="$_prev_plugins_root_spec12"

# ─── SPEC-1/2/3: ZBUILD_STAGE_IO_PERSONA carrier wiring (#1577) ─────────────
# _review_lens_run_inner must export ZBUILD_STAGE_IO_PERSONA=<lens> when a
# persona manifest exists for the lens id, and <lens>:fallback when absent,
# so the INPUT banner shows the resolved persona via the #1567 carrier.
# The carrier must be unset/restored after the call so it does not leak to
# outer callers. Uses the in-process route_to_model shadow to capture the
# carrier value at the moment route_to_model is invoked.
export _RL_PERSONA_AT_CALL="$TEST_TEMP_DIR/persona-at-call.txt"
# shellcheck disable=SC2329  # re-defined mock invoked indirectly by the plugin
route_to_model() {
    printf '%s' "${ZBUILD_STAGE_IO_PERSONA:-__unset__}" > "$_RL_PERSONA_AT_CALL"
    printf 'call\n' >> "$_RL_CALLS"
    printf '%s' '{"score":5,"findings":[]}'
    return 0
}

# SPEC-1[change]: persona manifest present (security) → carrier = 'security'
_prev_plugins_root_spec1="${ZBUILD_PLUGINS_ROOT:-}"
export ZBUILD_PLUGINS_ROOT="$REPO_ROOT/plugins"
out_spec1="$artifact_dir/lens-spec1-security.json"
: > "$_RL_PERSONA_AT_CALL"
set +e
_review_lens_run_inner "security" "$scope_manifest" "$evidence" "$out_spec1" "$artifact_dir"
_rc_spec1=$?
set -e
assert_eq "[#1577-1] persona-present lens returns 0" "0" "$_rc_spec1"
_persona_spec1="$(cat "$_RL_PERSONA_AT_CALL" 2>/dev/null || true)"
assert_eq "[#1577-1] ZBUILD_STAGE_IO_PERSONA='security' when persona manifest present" \
    "security" "$_persona_spec1"
export ZBUILD_PLUGINS_ROOT="$_prev_plugins_root_spec1"

# SPEC-2[change]: no persona manifest for lens id (edge-case) → carrier = 'edge-case:fallback'
_prev_plugins_root_spec2="${ZBUILD_PLUGINS_ROOT:-}"
export ZBUILD_PLUGINS_ROOT="$REPO_ROOT/plugins"
out_spec2="$artifact_dir/lens-spec2-edge-case.json"
: > "$_RL_PERSONA_AT_CALL"
set +e
_review_lens_run_inner "edge-case" "$scope_manifest" "$evidence" "$out_spec2" "$artifact_dir"
_rc_spec2=$?
set -e
assert_eq "[#1577-2] fallback lens returns 0" "0" "$_rc_spec2"
_persona_spec2="$(cat "$_RL_PERSONA_AT_CALL" 2>/dev/null || true)"
assert_eq "[#1577-2] ZBUILD_STAGE_IO_PERSONA='edge-case:fallback' when no persona manifest" \
    "edge-case:fallback" "$_persona_spec2"
export ZBUILD_PLUGINS_ROOT="$_prev_plugins_root_spec2"

# SPEC-3[change]: carrier is unset/restored after _review_lens_run_inner returns
# (must not leak to outer callers).
_prev_plugins_root_spec3="${ZBUILD_PLUGINS_ROOT:-}"
export ZBUILD_PLUGINS_ROOT="$REPO_ROOT/plugins"
unset ZBUILD_STAGE_IO_PERSONA
out_spec3="$artifact_dir/lens-spec3-security.json"
set +e
_review_lens_run_inner "security" "$scope_manifest" "$evidence" "$out_spec3" "$artifact_dir"
set -e
assert_eq "[#1577-3] ZBUILD_STAGE_IO_PERSONA unset after _review_lens_run_inner (no leak)" \
    "" "${ZBUILD_STAGE_IO_PERSONA:-}"
export ZBUILD_PLUGINS_ROOT="$_prev_plugins_root_spec3"

# SPEC-3b[change]: when ZBUILD_STAGE_IO_PERSONA held a value BEFORE the call, it
# is restored to that exact value afterward — the restore-to-prior-value branch,
# distinct from the unset→unset path above (#1577 review, red-team).
_prev_plugins_root_spec3b="${ZBUILD_PLUGINS_ROOT:-}"
export ZBUILD_PLUGINS_ROOT="$REPO_ROOT/plugins"
export ZBUILD_STAGE_IO_PERSONA="outer-sentinel-1577"
out_spec3b="$artifact_dir/lens-spec3b-security.json"
set +e
_review_lens_run_inner "security" "$scope_manifest" "$evidence" "$out_spec3b" "$artifact_dir"
set -e
assert_eq "[#1577-3b] ZBUILD_STAGE_IO_PERSONA restored to prior value after _review_lens_run_inner" \
    "outer-sentinel-1577" "${ZBUILD_STAGE_IO_PERSONA:-}"
unset ZBUILD_STAGE_IO_PERSONA
export ZBUILD_PLUGINS_ROOT="$_prev_plugins_root_spec3b"

# ═══════════════════════════════════════════════════════════════════════════════
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
# Anchored to the outputs: section so a stray primary:true elsewhere doesn't satisfy it.
_1840_s12_outputs="$(awk '/^outputs:/{found=1} found && /^[^ ]/{if(!/^outputs:/)exit} found{print}' \
    "$PLUGIN_DIR/manifest.yaml" 2>/dev/null || true)"
if grep -q 'lens_result' <<< "$_1840_s12_outputs" && grep -q 'primary: true' <<< "$_1840_s12_outputs"; then
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

# ─── SPEC-9 [guard]: passing run output is backward-compatible — v1 fields present and unmodified ─
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

# ─── SPEC-10 [guard]: merge-action coercion tokens absent; verdict appears only as jq field in _review_lens_write_result ─
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

# ─── SPEC-13 [change]: rc=130 writes disposition:interrupted; distinct from rc=0 ─
# shellcheck disable=SC2329
route_to_model() { printf 'call\n' >> "$_RL_CALLS"; return 130; }
out_1840_s13a="$artifact_dir/lens-1840spec13a.json"
rm -f "$out_1840_s13a" 2>/dev/null || true
set +e
_review_lens_run_inner "1840spec13a" "$scope_manifest" "$evidence" "$out_1840_s13a" "$artifact_dir"
_1840_s13a_rc=$?
set -e
# rc=130 is distinct from the advisory rc=0 degrade paths
assert_eq "[SPEC-13] rc=130 path propagates rc=130 (distinct from advisory rc=0)" \
    "130" "$_1840_s13a_rc"
assert_file_exists "[SPEC-13] rc=130 path writes lens file before returning" "$out_1840_s13a"
assert_eq "[SPEC-13] rc=130 path result_contract == 2" \
    "2" "$(jq -r '.result_contract // empty' "$out_1840_s13a")"
assert_eq "[SPEC-13] rc=130 path verdict == degraded" \
    "degraded" "$(jq -r '.verdict // empty' "$out_1840_s13a")"
assert_eq "[SPEC-13] rc=130 path disposition == interrupted" \
    "interrupted" "$(jq -r '.disposition // empty' "$out_1840_s13a")"
# Direct invocation of _review_lens_interrupt_handler (SIGTERM simulation)
out_1840_s13b="$artifact_dir/lens-1840spec13b.json"
rm -f "$out_1840_s13b" 2>/dev/null || true
if declare -F _review_lens_interrupt_handler >/dev/null 2>&1; then
    _rl_out_ref="$out_1840_s13b"
    set +e
    _review_lens_interrupt_handler
    set -e
    assert_file_exists "[SPEC-13] interrupt_handler writes lens file (SIGTERM simulation)" \
        "$out_1840_s13b"
    assert_eq "[SPEC-13] interrupt_handler result_contract == 2" \
        "2" "$(jq -r '.result_contract // empty' "$out_1840_s13b")"
    assert_eq "[SPEC-13] interrupt_handler verdict == degraded" \
        "degraded" "$(jq -r '.verdict // empty' "$out_1840_s13b")"
    assert_eq "[SPEC-13] interrupt_handler disposition == interrupted" \
        "interrupted" "$(jq -r '.disposition // empty' "$out_1840_s13b")"
else
    assert_fail "[SPEC-13] _review_lens_interrupt_handler must exist in plugin.sh" "absent"
fi

# ─── SPEC-14 [change]: template accessor wins over manifest in budget block ───
# Define a template accessor returning 99, which must differ from the manifest default.
_1840_mf_mt_again="$(manifest_router_knob "$PLUGIN_DIR/manifest.yaml" "max_turns" 2>/dev/null || true)"
if [[ "$_1840_mf_mt_again" == "99" ]]; then
    assert_fail "[SPEC-14] manifest max_turns must NOT be 99 — test requires them to differ" "both 99"
fi
# shellcheck disable=SC2329
template_stage_router_max_turns() { printf '99'; return 0; }
# shellcheck disable=SC2329
route_to_model() {
    printf '%s' "$2" > "$_RL_PROMPT"
    printf 'call\n' >> "$_RL_CALLS"
    printf '%s' '{"score":5,"findings":[]}'
    return 0
}
out_1840_s14="$artifact_dir/lens-1840spec14.json"
_1840_prev_s14_stage="${ZBUILD_CURRENT_STAGE:-__UNSET__}"
export ZBUILD_CURRENT_STAGE="review-lens"
unset ZBUILD_ROUTER_MAX_TURNS 2>/dev/null || true
set +e
_review_lens_run_inner "1840spec14" "$scope_manifest" "$evidence" "$out_1840_s14" "$artifact_dir"
set -e
_1840_s14_prompt="$(cat "$_RL_PROMPT" 2>/dev/null || true)"
# Budget block must reflect the template sentinel (99), not the manifest default.
# '99' must appear within the TURN BUDGET block itself — checking both independently
# would pass if 99 appears elsewhere in the prompt for an unrelated reason.
_1840_s14_budget_block="$(grep -i -A10 "TURN BUDGET" <<< "$_1840_s14_prompt" 2>/dev/null || true)"
if [[ -n "$_1840_s14_budget_block" ]] && grep -q '99' <<< "$_1840_s14_budget_block"; then
    assert_pass "[SPEC-14] prompt budget block reflects template sentinel 99 (template wins over manifest)"
else
    assert_fail "[SPEC-14] prompt must contain TURN BUDGET with sentinel 99 — template accessor wins" \
        "$(grep -i 'turn budget\|99 tool' <<< "$_1840_s14_prompt" || echo absent)"
fi
unset -f template_stage_router_max_turns 2>/dev/null || true
[[ "$_1840_prev_s14_stage" == "__UNSET__" ]] && unset ZBUILD_CURRENT_STAGE \
    || export ZBUILD_CURRENT_STAGE="$_1840_prev_s14_stage"

# ─── SPEC-15 [change]: rc=10 writes disposition:exhausted, propagates rc=10 ───
# rc=10 (budget exhaustion) must produce a dedicated exhausted branch — distinct
# from advisory rc=0 degrade paths (broken/router_error or broken/unparseable_reply)
# and from rc=130 interrupted. The plugin must NOT fall through to the generic
# router_rc!=0 handler that writes disposition:broken/reason:router_error.
# shellcheck disable=SC2329
route_to_model() { printf 'call\n' >> "$_RL_CALLS"; return 10; }
out_1840_s15="$artifact_dir/lens-1840spec15.json"
rm -f "$out_1840_s15" 2>/dev/null || true
set +e
_review_lens_run_inner "1840spec15" "$scope_manifest" "$evidence" "$out_1840_s15" "$artifact_dir"
_1840_s15_rc=$?
set -e
assert_eq "[SPEC-15] rc=10 path propagates rc=10 (distinct from advisory rc=0)" \
    "10" "$_1840_s15_rc"
assert_file_exists "[SPEC-15] rc=10 path writes lens file before returning" "$out_1840_s15"
assert_eq "[SPEC-15] rc=10 result_contract == 2" \
    "2" "$(jq -r '.result_contract // empty' "$out_1840_s15")"
assert_eq "[SPEC-15] rc=10 verdict == degraded" \
    "degraded" "$(jq -r '.verdict // empty' "$out_1840_s15")"
assert_eq "[SPEC-15] rc=10 disposition == exhausted" \
    "exhausted" "$(jq -r '.disposition // empty' "$out_1840_s15")"
assert_eq "[SPEC-15] rc=10 reason == budget_exhausted" \
    "budget_exhausted" "$(jq -r '.reason // empty' "$out_1840_s15")"
# Confirm rc=10 is strictly between advisory (rc=0) and interrupted (rc=130)
if [[ "$_1840_s15_rc" -eq 0 ]]; then
    assert_fail "[SPEC-15] rc=10 must NOT collapse to advisory rc=0" "rc was 0"
fi
if [[ "$_1840_s15_rc" -eq 130 ]]; then
    assert_fail "[SPEC-15] rc=10 must NOT be rc=130 (interrupted path)" "rc was 130"
fi

# ─── SPEC-16 [guard]: manifest outputs declares review_lens_summary with summary: true ─
# ADR-055 §9: the stage-statement output was present in v1 and must persist through
# the v2 migration. This guard verifies it has not been accidentally removed.
# Scoped to the review_lens_summary stanza (between its id: line and the next list
# item) so a stray summary: true on a different output entry cannot satisfy this check.
_1840_s16_stanza="$(awk '
    /^  - id: review_lens_summary/ { found=1 }
    found && /^  - id:/ && !/review_lens_summary/ { exit }
    found { print }
' "$PLUGIN_DIR/manifest.yaml" 2>/dev/null || true)"
if grep -q 'summary: true' <<< "$_1840_s16_stanza"; then
    assert_pass "[SPEC-16] manifest outputs section declares review_lens_summary with summary: true"
else
    assert_fail "[SPEC-16] manifest outputs must declare review_lens_summary with summary: true (ADR-055 §9)" \
        "absent"
fi

# ─── SPEC-17 [guard]: success path writes lens-<name>-summary.md with affirmative language ─
# ADR-055 §9: the success summary (pass status, "reviewed" language) was present in v1
# and must persist through the v2 migration — distinct from the advisory-absence language
# on degrade paths (SPEC-8). Guard: this behavior existed in v1 and must be preserved.
# shellcheck disable=SC2329
route_to_model() {
    printf 'call\n' >> "$_RL_CALLS"
    printf '%s' "$2" > "$_RL_PROMPT"
    printf '%s' '{"score":5,"findings":[]}'
    return 0
}
out_1840_s17="$artifact_dir/lens-1840spec17.json"
_1840_s17_summary="$artifact_dir/lens-1840spec17-summary.md"
rm -f "$_1840_s17_summary" 2>/dev/null || true
set +e
_review_lens_run_inner "1840spec17" "$scope_manifest" "$evidence" "$out_1840_s17" "$artifact_dir"
_1840_s17_rc=$?
set -e
assert_eq "[SPEC-17] success path returns 0" "0" "$_1840_s17_rc"
assert_file_exists "[SPEC-17] success path writes lens summary file" "$_1840_s17_summary"
_1840_s17_body="$(cat "$_1840_s17_summary" 2>/dev/null || true)"
if grep -qi "reviewed\|-- pass" <<< "$_1840_s17_body"; then
    assert_pass "[SPEC-17] success summary contains affirmative pass-verdict language"
else
    assert_fail "[SPEC-17] success summary must contain affirmative pass-verdict language" \
        "${_1840_s17_body:-absent}"
fi

# ─── SPEC-18 [change]: wall-clock budget guidance in prompt when timeout > 0 ────
# ADR-063 §1: the v2 migration adds a WALL CLOCK BUDGET block to the prompt when
# _route_resolve_timeout returns a positive value. New in v2 — the v1 plugin had no
# _review_lens_wallclock_guidance call. Fails at merge-base; passes after migration.
_1840_s18_orig_rrt="$(declare -f _route_resolve_timeout 2>/dev/null || true)"
# shellcheck disable=SC2329
_route_resolve_timeout() { printf '300'; }
# shellcheck disable=SC2329
route_to_model() {
    printf '%s' "$2" > "$_RL_PROMPT"
    printf 'call\n' >> "$_RL_CALLS"
    printf '%s' '{"score":5,"findings":[]}'
    return 0
}
out_1840_s18="$artifact_dir/lens-1840spec18.json"
: > "$_RL_CALLS"
set +e
_review_lens_run_inner "1840spec18" "$scope_manifest" "$evidence" "$out_1840_s18" "$artifact_dir"
set -e
_1840_s18_prompt="$(cat "$_RL_PROMPT" 2>/dev/null || true)"
if grep -qi "WALL CLOCK BUDGET" <<< "$_1840_s18_prompt"; then
    assert_pass "[SPEC-18] WALL CLOCK BUDGET block appears in prompt when _route_resolve_timeout > 0"
else
    assert_fail "[SPEC-18] WALL CLOCK BUDGET block must appear in prompt when _route_resolve_timeout > 0" "absent"
fi
if [[ -n "$_1840_s18_orig_rrt" ]]; then eval "$_1840_s18_orig_rrt"; else unset -f _route_resolve_timeout 2>/dev/null || true; fi
unset _1840_s18_orig_rrt

# ─── SPEC-19 [guard]: hooks.cleanup absent from manifest; ADR-054 §7 explanatory comment present ─
# ADR-054 §7 (#1829): plugins that hold no live resources must NOT declare
# hooks.cleanup. The absence is intentional and the manifest must carry a comment
# explaining why (so future readers do not add it by mistake).
if grep -qE '^\s*cleanup\s*:' "$PLUGIN_DIR/manifest.yaml" 2>/dev/null; then
    assert_fail "[SPEC-19] hooks.cleanup must be absent from manifest.yaml" "found cleanup key"
else
    assert_pass "[SPEC-19] hooks.cleanup is absent from manifest.yaml"
fi
# The manifest must carry an explanatory comment referencing ADR-054 §7
if grep -q 'ADR-054.*§7\|ADR-054.*§ *7' "$PLUGIN_DIR/manifest.yaml" 2>/dev/null; then
    assert_pass "[SPEC-19] manifest contains explanatory comment citing ADR-054 §7"
else
    assert_fail "[SPEC-19] manifest must carry a comment citing ADR-054 §7 for absent hooks.cleanup" \
        "comment absent"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
