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
print_test_header "plugin: review-lens — v2 exit paths and budgets (#1840): interrupt/exhaustion dispositions, ADR-063 budget block, manifest guards"
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

# ─── review (#2165): Ctrl-C reaches the whole process group — the trap fires in
# this shell AND the router subshell returns 130. The result is written ONCE.
_aw_log="$TEST_TEMP_DIR/atomic-writes.log"; : > "$_aw_log"
eval "_orig_$(declare -f atomic_write)"
# shellcheck disable=SC2329
atomic_write() { printf '%s\n' "$1" >> "$_aw_log"; _orig_atomic_write "$@"; }
# shellcheck disable=SC2329
route_to_model() { kill -INT "$$"; return 130; }
out_1840_s13c="$artifact_dir/lens-1840spec13c.json"
rm -f "$out_1840_s13c" 2>/dev/null || true
set +e
_review_lens_run_inner "1840spec13c" "$scope_manifest" "$evidence" "$out_1840_s13c" "$artifact_dir"
_1840_s13c_rc=$?
set -e
eval "$(declare -f _orig_atomic_write | sed '1s/_orig_atomic_write/atomic_write/')"
assert_eq "[SPEC-13] process-group SIGINT still propagates rc=130" "130" "$_1840_s13c_rc"
assert_eq "[SPEC-13] process-group SIGINT: disposition == interrupted" \
    "interrupted" "$(jq -r '.disposition // empty' "$out_1840_s13c" 2>/dev/null)"
assert_eq "[SPEC-13] process-group SIGINT writes the result exactly once (trap + rc=130 branch)" \
    "1" "$(grep -c "lens-1840spec13c.json" "$_aw_log")"

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

# ─── SPEC-19 [change]: hooks.cleanup absent from manifest; ADR-054 §7 explanatory comment present ─
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

# ─── SPEC-20 [guard]: manifest provides.role == review_lens ──────────────────
# ADR-040 role-binding contract (#1704): provides.role was declared in v1 and
# must survive the v2 migration unchanged. The resolver reads this field at runtime.
_1840_s20_role="$(yaml_get "$PLUGIN_DIR/manifest.yaml" "provides.role" 2>/dev/null || true)"
assert_eq "[SPEC-20] manifest provides.role == review_lens" \
    "review_lens" "$_1840_s20_role"

# ─── SPEC-21 [guard]: manifest provides.events declares exactly three events ─
# ADR-001 §"Declared events" (#1717): provides.events was introduced in #1717
# (before this migration) and must be preserved through v2. Must declare
# exactly three events — no more, no fewer — so the known-event set stays consistent.
_1840_s21_events="$(awk '
    /^provides:/ { in_provides=1; next }
    in_provides && /^[^[:space:]]/ { exit }
    in_provides && /events:/ { in_events=1; next }
    in_events && /^[[:space:]]*-[[:space:]]/ { print; next }
    in_events { in_events=0 }
' "$PLUGIN_DIR/manifest.yaml" 2>/dev/null || true)"
_1840_s21_count="$(grep -c '^[[:space:]]*-[[:space:]]' <<< "$_1840_s21_events" 2>/dev/null || true)"
assert_eq "[SPEC-21] manifest provides.events declares exactly three events" \
    "3" "$_1840_s21_count"
if grep -q 'review_lens.failed' <<< "$_1840_s21_events"; then
    assert_pass "[SPEC-21] provides.events includes review_lens.failed"
else
    assert_fail "[SPEC-21] provides.events must include review_lens.failed" "absent"
fi
if grep -q 'review_lens.redaction_failed' <<< "$_1840_s21_events"; then
    assert_pass "[SPEC-21] provides.events includes review_lens.redaction_failed"
else
    assert_fail "[SPEC-21] provides.events must include review_lens.redaction_failed" "absent"
fi
if grep -q 'review_lens.unparseable' <<< "$_1840_s21_events"; then
    assert_pass "[SPEC-21] provides.events includes review_lens.unparseable"
else
    assert_fail "[SPEC-21] provides.events must include review_lens.unparseable" "absent"
fi


cleanup_test_env
print_test_results
exit $((FAIL > 0))
