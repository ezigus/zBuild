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
# Redaction chokepoint stub (copy-through). Overridden per-test below.
# shellcheck disable=SC2329  # invoked indirectly by the sourced plugin
apply_scope_redaction() { cp "$1" "$2"; return 0; }

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
assert_eq "[SPEC-1] run returns 0 (advisory never aborts)" "0" "$_rc"
assert_eq "[SPEC-1] exactly ONE LLM call for the lens" "1" "$(wc -l < "$_RL_CALLS" | tr -d ' ')"
assert_file_exists "[SPEC-1] writes lens-security.json" "$out"
assert_eq "[SPEC-1] normalized name == lens id" "security" "$(jq -r '.name' "$out")"
assert_eq "[SPEC-1] schema_version present" "1" "$(jq -r '.schema_version' "$out")"
assert_eq "[SPEC-1] score floored to integer" "3" "$(jq -r '.score' "$out")"
assert_eq "[SPEC-1] findings normalized (1 finding)" "1" "$(jq '.findings | length' "$out")"
assert_eq "[SPEC-1] severity lowercased to enum" "critical" "$(jq -r '.findings[0].severity' "$out")"

# ─── SPEC-2: redaction reaches the model; raw text never sent without it ─────
_p="$(cat "$_RL_PROMPT")"
assert_contains "[SPEC-2] redacted evidence reached the prompt" "$_p" "exec user input at line 10"
assert_contains "[SPEC-2] prompt carries the security charter (not wildcard)" "$_p" "injection risks"
assert_contains "[SPEC-2] prompt is the single-lens advisory contract" "$_p" '"security" review lens'

# ─── SPEC-3: parametrized — SAME plugin serves a different lens (charter swap) ─
out_perf="$artifact_dir/lens-performance.json"
: > "$_RL_CALLS"
set +e
_review_lens_run_inner "performance" "$scope_manifest" "$evidence" "$out_perf" "$artifact_dir"
set -e
assert_eq "[SPEC-3] performance lens name" "performance" "$(jq -r '.name' "$out_perf")"
assert_eq "[SPEC-3] performance score" "8" "$(jq -r '.score' "$out_perf")"
_pp="$(cat "$_RL_PROMPT")"
assert_contains "[SPEC-3] performance charter swapped in" "$_pp" "O(n^2)"

# ─── SPEC-4: redaction refusal degrades to empty + event + rc 0 (ADR-004) ────
# shellcheck disable=SC2329  # re-defined mock invoked indirectly by the plugin
apply_scope_redaction() { return 1; }   # force chokepoint to refuse
out_refuse="$artifact_dir/lens-correctness.json"
: > "$_RL_CALLS"
set +e
_review_lens_run_inner "correctness" "$scope_manifest" "$evidence" "$out_refuse" "$artifact_dir"
_rc_refuse=$?
set -e
assert_eq "[SPEC-4] redaction refusal still returns 0" "0" "$_rc_refuse"
assert_eq "[SPEC-4] NO LLM call when redaction refuses" "0" "$(wc -l < "$_RL_CALLS" | tr -d ' ')"
assert_file_exists "[SPEC-4] empty lens result still written" "$out_refuse"
assert_eq "[SPEC-4] empty result has score 0" "0" "$(jq -r '.score' "$out_refuse")"
assert_eq "[SPEC-4] empty result has empty findings" "0" "$(jq '.findings | length' "$out_refuse")"
if grep -q '"review_lens.redaction_failed"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_pass "[SPEC-4] review_lens.redaction_failed event emitted"
else
    assert_fail "[SPEC-4] review_lens.redaction_failed event should be emitted" "absent"
fi
# shellcheck disable=SC2329  # re-defined mock invoked indirectly by the plugin
apply_scope_redaction() { cp "$1" "$2"; return 0; }   # restore

# ─── SPEC-5: unparseable model output degrades to empty + event + rc 0 ───────
# shellcheck disable=SC2329  # re-defined mock invoked indirectly by the plugin
route_to_model() { printf 'call\n' >> "$_RL_CALLS"; printf '%s' 'not json at all'; return 0; }
out_bad="$artifact_dir/lens-edge-case.json"
: > "$_RL_CALLS"
set +e
_review_lens_run_inner "edge-case" "$scope_manifest" "$evidence" "$out_bad" "$artifact_dir"
_rc_bad=$?
set -e
assert_eq "[SPEC-5] unparseable output returns 0 (fail-open)" "0" "$_rc_bad"
assert_eq "[SPEC-5] unparseable yields empty findings" "0" "$(jq '.findings | length' "$out_bad")"
if grep -q '"review_lens.unparseable"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_pass "[SPEC-5] review_lens.unparseable event emitted"
else
    assert_fail "[SPEC-5] review_lens.unparseable event should be emitted" "absent"
fi

# ─── SPEC-6: router failure (rc!=0) degrades to empty + review_lens.failed ───
# shellcheck disable=SC2329  # re-defined mock invoked indirectly by the plugin
route_to_model() { printf 'call\n' >> "$_RL_CALLS"; return 2; }
out_fail="$artifact_dir/lens-integration.json"
set +e
_review_lens_run_inner "integration" "$scope_manifest" "$evidence" "$out_fail" "$artifact_dir"
_rc_fail=$?
set -e
assert_eq "[SPEC-6] router failure returns 0 (advisory never blocks)" "0" "$_rc_fail"
assert_eq "[SPEC-6] router failure yields empty findings" "0" "$(jq '.findings | length' "$out_fail")"
if grep -q '"review_lens.failed"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_pass "[SPEC-6] review_lens.failed event emitted"
else
    assert_fail "[SPEC-6] review_lens.failed event should be emitted" "absent"
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
review_lens_init >/dev/null
set +e
ZBUILD_REVIEW_LENS_ID="red-team" review_lens_run "review-lens" "$STATE_FILE" >/dev/null 2>&1
_rc_hook=$?
set -e
assert_eq "[SPEC-7] review_lens_run(stage, state_file) returns 0" "0" "$_rc_hook"
assert_file_exists "[SPEC-7] hook derives lens-<id>.json from ZBUILD_REVIEW_LENS_ID" \
    "$STATE_DIR/artifacts/lens-red-team.json"
# stage-id prefix stripping: stage `lens_maintainability` → maintainability charter
set +e
ZBUILD_CURRENT_STAGE="lens_maintainability" review_lens_run "lens_maintainability" "$STATE_FILE" >/dev/null 2>&1
set -e
assert_file_exists "[SPEC-7] stage-id prefix stripped (lens_maintainability → maintainability)" \
    "$STATE_DIR/artifacts/lens-maintainability.json"

# ─── SPEC-8: per-lens evidence selection — test-coverage prefers coverage-map ─
_ev_default="$(_review_lens_evidence_path "security" "$artifact_dir")"
assert_eq "[SPEC-8] default lens evidence falls back to diff.patch" \
    "$artifact_dir/diff.patch" "$_ev_default"
printf '{"files":[{"file":"core/x.sh"}]}\n' > "$artifact_dir/coverage-map.json"
_ev_cov="$(_review_lens_evidence_path "test-coverage" "$artifact_dir")"
assert_eq "[SPEC-8] test-coverage lens prefers coverage-map.json when present" \
    "$artifact_dir/coverage-map.json" "$_ev_cov"

# ─── SPEC-9: no merge-decision vocabulary in plugin source (advisory, ADR-040) ─
if grep -qiE '\b(approve|request_changes)\b|"block"|verdict' \
    "$PLUGIN_DIR/plugin.sh" "$PLUGIN_DIR/lib/charters.sh"; then
    assert_fail "[SPEC-9] no coercion vocabulary in review-lens source" "found coercion token"
else
    assert_pass "[SPEC-9] no coercion vocabulary in review-lens source"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
