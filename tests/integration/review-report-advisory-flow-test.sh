#!/usr/bin/env bash
# Tests: #972 (ADR-038) live wiring — the single `review` stage of simple.yaml
# resolves BY ROLE to the new review-report plugin (NOT the legacy verdict
# plugin), and the advisory stage hook returns 0 even with a critical finding so
# the pipeline proceeds. This is the end-to-end proof of the role-resolution
# risk that the plugin unit test cannot cover.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "review-report advisory flow — live role resolution (#972)"
setup_test_env "review-report-advisory-flow"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

# Resolve against the REAL shipped plugins so the new review-report plugin is
# discovered exactly as the runner discovers it.
export ZBUILD_PLUGINS_ROOT="$REPO_ROOT/plugins"

# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
# shellcheck source=../../core/pipeline/resolver.sh
source "$REPO_ROOT/core/pipeline/resolver.sh"

# ─── SPEC-5: simple.yaml binds review → role review_report ───────────────────
set +e
load_template "$REPO_ROOT/config/templates/simple.yaml"
_load_rc=$?
set -e
assert_eq "[SPEC-5] simple.yaml loads" "0" "$_load_rc"
assert_eq "[SPEC-5] review stage role is review_report" "review_report" "${_TPL_STAGE_ROLES_review:-}"

# ─── SPEC-5: the role resolves to the NEW plugin, not the legacy one ─────────
set +e
_plugin_dir="$(resolve_plugin_for_role "review_report" "" "$ZBUILD_PLUGINS_ROOT" 2>/dev/null)"
_res_rc=$?
set -e
assert_eq "[SPEC-5] review_report role resolves (rc=0)" "0" "$_res_rc"
assert_eq "[SPEC-5] resolves to the review-report plugin" "review-report" "$(basename "${_plugin_dir:-none}")"

# Standard.yaml's `reviewer` role must NOT resolve to this plugin — the legacy
# `review` plugin declares no provides.role, so reviewer falls through to the
# stage-name lookup (unchanged). Proves standard.yaml is unaffected.
set +e
_reviewer_dir="$(resolve_plugin_for_role "reviewer" "" "$ZBUILD_PLUGINS_ROOT" 2>/dev/null)"
set -e
if [[ -z "$_reviewer_dir" ]]; then
    assert_pass "[SPEC-5] legacy 'reviewer' role unclaimed (standard.yaml unaffected)"
else
    assert_eq "[SPEC-5] 'reviewer' must not resolve to review-report" "review" "$(basename "$_reviewer_dir")"
fi

# ─── SPEC-5: advisory contract opt-out (no provides.artifact_type) ───────────
_art_type="$(yaml_get "$_plugin_dir/manifest.yaml" "provides.artifact_type" 2>/dev/null || true)"
if [[ -z "$_art_type" ]]; then
    assert_pass "[SPEC-5] manifest declares no provides.artifact_type (advisory; no blocking contract)"
else
    assert_fail "[SPEC-5] manifest must not declare provides.artifact_type" "got: $_art_type"
fi

# ─── SPEC-3: the run hook returns 0 with a critical finding (advisory) ───────
# shellcheck source=../../plugins/agent/review-report/plugin.sh
source "$REPO_ROOT/plugins/agent/review-report/plugin.sh"
# Stub the LLM + redaction so the hook runs hermetically.
route_to_model() {
    printf '%s' '{"score":2,"findings":[{"file":"core/z.sh","category":"injection","severity":"critical","line":5,"message":"unsanitized exec"}]}'
    return 0
}
apply_scope_redaction() { cp "$1" "$2"; return 0; }

state_dir="$TEST_TEMP_DIR/run-state"
mkdir -p "$state_dir/artifacts"
touch "$state_dir/scope-manifest.md"
# shellcheck disable=SC2016  # literal $user_input is intentional fixture text
printf 'diff --git a/core/z.sh b/core/z.sh\n+ exec $user_input\n' > "$state_dir/artifacts/diff.patch"

set +e
review_report_run "review" "$state_dir/state.json"
_hook_rc=$?
set -e
assert_eq "[SPEC-3] advisory run hook returns 0 even with a critical finding" "0" "$_hook_rc"
assert_eq "[SPEC-3] report written" "needs_attention" "$(jq -r '.merge_readiness' "$state_dir/artifacts/review-report.json" 2>/dev/null)"
if jq -e '.verdict' "$state_dir/artifacts/review-report.json" >/dev/null 2>&1; then
    assert_fail "[SPEC-3] report carries no verdict (no coercion)" "found .verdict"
else
    assert_pass "[SPEC-3] report carries no verdict (no coercion)"
fi

# ─── SPEC-12: manifest-driven roster present in integration context ────────────
if declare -f _rr_load_lenses >/dev/null 2>&1; then
    assert_pass "[SPEC-12] _rr_load_lenses function present in integration context"
else
    assert_fail "[SPEC-12] _rr_load_lenses function must exist (manifest-driven roster)" "absent"
fi

# ─── SPEC-13: escalation_note flows end-to-end into the advisory report ───────
# score=2 + critical finding → needs_attention → escalation_note must be non-null.
_esc_note="$(jq -r '.escalation_note // empty' "$state_dir/artifacts/review-report.json" 2>/dev/null)"
if [[ -n "$_esc_note" ]]; then
    assert_pass "[SPEC-13] needs_attention report has escalation_note (integration end-to-end)"
else
    assert_fail "[SPEC-13] needs_attention report must have escalation_note (integration)" "absent"
fi

print_test_results
