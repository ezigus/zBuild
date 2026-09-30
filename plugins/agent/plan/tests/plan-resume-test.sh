#!/usr/bin/env bash
# Tests: plugins/agent/plan — resumable context, envelope recovery, persona, #1727 (#1052)
# Split from plan-test.sh (1,399 lines; review #2237). Shared setup: plan-test-lib.sh.
# shellcheck disable=SC2034  # PLAN_GOAL / CANNED_PLAN are read by plan-test-lib.sh's _run_plan and model mock
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugin: plan — resumable context, envelope recovery, persona, #1727 (#1052)"

setup_test_env "plugin-plan-resume"

# shellcheck source=plan-test-lib.sh
source "$SCRIPT_DIR/plan-test-lib.sh"

# ═══════════════════════════════════════════════════════════════════════════
#  Issue #1052 — Plan-stage resilience SPEC tests (RED until Wave B plugin.sh)
#  These drive through plan_run / _plan_run_inner (which exist) and the
#  envelope-recovery helpers from scripts/lib/plan-context.sh. They assert on
#  OBSERVABLE behavior (events, files, prompt content, rc) so they fail on the
#  unimplemented behavior, not on harness/sourcing errors.
# ═══════════════════════════════════════════════════════════════════════════
print_test_header "Issue #1052 — plan-stage resilience (resumable context + recovery)"

# Restore a clean passthrough redaction + canned-plan mock for these tests.
apply_scope_redaction() {
    local _input="$1" _output="$2"
    cat "$_input" > "$_output"
    return 0
}
CANNED_PLAN='{"schema_version":1,"title":"fixture","goal":"test goal","steps":[{"id":"step-1","description":"do thing","files":["core/foo.sh"],"estimated_lines":10}],"estimated_total_lines":10,"notes":""}'

# Isolate the cross-run plan-context cache under the test temp dir so no real
# $HOME/.zbuild/plan-context is touched and goal-hash collisions across tests
# are impossible.
export ZBUILD_PLAN_CONTEXT_DIR="$TEST_TEMP_DIR/plan-context-cache"
mkdir -p "$ZBUILD_PLAN_CONTEXT_DIR"

# goal_hash formula (plan §Pillar A): normalized pre-redaction goal text.
# ADR-059 §6 (#1930): this used to be a byte-identical re-implementation of
# plan_context_goal_hash. A test that re-derives the formula it is testing
# cannot detect a change to it, so it now calls the real function — sourced
# transitively through plugin.sh, like plan_context_repo_id below.

# ─── [SPEC-1][change] plan persists plan-context.json on success ─────────────
# On a successful plan run, the plugin must persist a durable plan-context
# artifact (status=complete, goal_hash set) and emit plan.context.persisted;
# the human-readable plan-context.md must be readable.
print_test_section "[SPEC-1][change] persist plan-context on success"
: > "$EVENTS_FILE"
PLAN_GOAL="test goal"
CANNED_PLAN='{"schema_version":1,"title":"fixture","goal":"test goal","steps":[{"id":"step-1","description":"do thing","files":["core/foo.sh"],"estimated_lines":10}],"estimated_total_lines":10,"notes":""}'
set +e
_run_plan "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "[SPEC-1] plan_run rc=0 on success" "0" "$rc"
assert_event_emitted "[SPEC-1] plan.context.persisted emitted on success" \
    "$EVENTS_FILE" "plan.context.persisted"
# plan-context.json lives in the per-run artifacts dir (a copy) on every outcome.
assert_file_exists "[SPEC-1] plan-context.json written to artifacts" \
    "$ARTIFACTS_DIR/plan-context.json"
_ctx_status="$(jq -r '.status // empty' "$ARTIFACTS_DIR/plan-context.json" 2>/dev/null || true)"
assert_eq "[SPEC-1] plan-context status=complete on success" "complete" "$_ctx_status"
_ctx_gh="$(jq -r '.goal_hash // empty' "$ARTIFACTS_DIR/plan-context.json" 2>/dev/null || true)"
assert_eq "[SPEC-1] plan-context goal_hash matches normalized goal" \
    "$(zbuild_goal_hash "test goal")" "$_ctx_gh"
assert_file_exists "[SPEC-1] plan-context.md readable" \
    "$ARTIFACTS_DIR/plan-context.md"

# ─── [SPEC-2][change] resume splices PRIOR EXPLORATION CONTEXT from cache ─────
# A pre-seeded namespaced cache entry (status != complete, matching goal_hash +
# scope_manifest_ref) must be spliced into the captured prompt under a
# `PRIOR EXPLORATION CONTEXT` heading and plan.context.resumed must fire.
print_test_section "[SPEC-2][change] resume splices prior exploration context"
: > "$EVENTS_FILE"
: > "$_CAPTURED_PROMPT_FILE"
PLAN_GOAL="resume me please"
export ZBUILD_PLAN_RESUME=1
_RESUME_TOKEN="PRIOR_EXPLORATION_SENTINEL_42"
_gh="$(zbuild_goal_hash "resume me please")"
_scope_ref="$(shasum -a 256 "$STATE_DIR/scope-manifest.md" | cut -d' ' -f1)"
# Pre-seed the cache in the namespaced layout (Pillar E). repo_id/scope_key are
# derived by the plugin; we seed all candidate leaves so resume resolves
# regardless of how repo_id/scope_key hash out for this fixture.
# Seed a cache leaf the lib's read contract will accept. plan_context_read_for_resume
# refuses on ANY key mismatch (Pillar E), including repo_id — so the seed MUST
# embed the repo_id the plugin computes (derived below) and the scope_key, exactly
# as Wave A's plan_context_write does.
_seed_plan_context() {
    local dir="$1" repo_id="$2" scope_key="$3"
    mkdir -p "$dir"
    jq -n \
        --arg gh "$_gh" \
        --arg sr "$_scope_ref" \
        --arg repo "$repo_id" \
        --arg sk "$scope_key" \
        --arg pr "$_RESUME_TOKEN exploration from a prior exhausted run" \
        '{schema_version:1,goal_hash:$gh,scope_manifest_ref:$sr,
          status:"scope_too_large",num_turns:25,partial_reasoning:$pr,
          candidate_split:true,run_id:"prior-run",repo_id:$repo,scope_key:$sk,
          branch:"test",created_at:"2026-06-26T00:00:00Z"}' \
        > "$dir/$_gh.json"
    printf '# plan-context\n## Accumulated exploration\n%s\n' "$_RESUME_TOKEN" \
        > "$dir/$_gh.md"
}
# Seed the EXACT namespaced leaf the plugin reads: <repo_id>/<scope_key>/
# <goal_hash>.json. repo_id is derived the same way the plugin derives it (via
# zbuild_repo_id, sourced transitively through plugin.sh); scope_key is
# ZBUILD_ISSUE_NUMBER when present (Pillar E). The behavior under test is
# "resume happened", not the namespace math (that is SPEC-5, owned elsewhere).
export ZBUILD_ISSUE_NUMBER="$_ZB_ID"
_seed_repo_id="$(zbuild_repo_id)"
_seed_plan_context "$ZBUILD_PLAN_CONTEXT_DIR/$_seed_repo_id/$_ZB_ID" "$_seed_repo_id" "$_ZB_ID"
set +e
_run_plan "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "[SPEC-2] plan_run rc=0 with resume enabled" "0" "$rc"
_resume_prompt="$(cat "$_CAPTURED_PROMPT_FILE" 2>/dev/null || true)"
assert_contains "[SPEC-2] prompt carries PRIOR EXPLORATION CONTEXT heading" \
    "$_resume_prompt" "PRIOR EXPLORATION CONTEXT"
assert_contains "[SPEC-2] prompt carries the prior exploration sentinel" \
    "$_resume_prompt" "$_RESUME_TOKEN"
assert_event_emitted "[SPEC-2] plan.context.resumed emitted" \
    "$EVENTS_FILE" "plan.context.resumed"

# ─── [SPEC-2][guard] resume refused on mismatch / disable ────────────────────
# Resume must NOT happen on: goal_hash mismatch, scope-manifest change, or
# ZBUILD_PLAN_RESUME=0. In each case no PRIOR EXPLORATION CONTEXT splice and no
# plan.context.resumed event.
print_test_section "[SPEC-2][guard] resume refused on mismatch / disable"

# (a) ZBUILD_PLAN_RESUME=0 disables resume even with a matching cache entry.
: > "$EVENTS_FILE"; : > "$_CAPTURED_PROMPT_FILE"
export ZBUILD_PLAN_RESUME=0
set +e; _run_plan "$STATE_FILE" >/dev/null 2>&1; set -e
_guard_prompt="$(cat "$_CAPTURED_PROMPT_FILE" 2>/dev/null || true)"
if grep -qF "$_RESUME_TOKEN" <<<"$_guard_prompt"; then
    assert_fail "[SPEC-2][guard] ZBUILD_PLAN_RESUME=0 must not splice prior context"
else
    assert_pass "[SPEC-2][guard] ZBUILD_PLAN_RESUME=0 must not splice prior context"
fi
_resumed_count="$(jq -r 'select(.type=="plan.context.resumed") | .type' "$EVENTS_FILE" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "[SPEC-2][guard] no plan.context.resumed when disabled" "0" "$_resumed_count"

# (b) goal_hash mismatch — different goal text, same cache → no resume.
: > "$EVENTS_FILE"; : > "$_CAPTURED_PROMPT_FILE"
export ZBUILD_PLAN_RESUME=1
PLAN_GOAL="a completely different goal that does not match the cache"
set +e; _run_plan "$STATE_FILE" >/dev/null 2>&1; set -e
_guard_prompt="$(cat "$_CAPTURED_PROMPT_FILE" 2>/dev/null || true)"
if grep -qF "$_RESUME_TOKEN" <<<"$_guard_prompt"; then
    assert_fail "[SPEC-2][guard] goal_hash mismatch must not splice prior context"
else
    assert_pass "[SPEC-2][guard] goal_hash mismatch must not splice prior context"
fi
_resumed_count="$(jq -r 'select(.type=="plan.context.resumed") | .type' "$EVENTS_FILE" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "[SPEC-2][guard] no plan.context.resumed on goal_hash mismatch" "0" "$_resumed_count"

# (c) scope-manifest change — matching goal_hash but the manifest hash differs
# from the seeded scope_manifest_ref → refuse resume (Pillar B condition).
: > "$EVENTS_FILE"; : > "$_CAPTURED_PROMPT_FILE"
PLAN_GOAL="resume me please"
# Mutate the live manifest so its hash no longer matches the seeded ref.
cat > "$STATE_DIR/scope-manifest.md" <<'SCOPE2'
+ core/
+ plugins/
+ scripts/
SCOPE2
set +e; _run_plan "$STATE_FILE" >/dev/null 2>&1; set -e
_guard_prompt="$(cat "$_CAPTURED_PROMPT_FILE" 2>/dev/null || true)"
if grep -qF "$_RESUME_TOKEN" <<<"$_guard_prompt"; then
    assert_fail "[SPEC-2][guard] scope-manifest change must not splice prior context"
else
    assert_pass "[SPEC-2][guard] scope-manifest change must not splice prior context"
fi
_resumed_count="$(jq -r 'select(.type=="plan.context.resumed") | .type' "$EVENTS_FILE" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "[SPEC-2][guard] no plan.context.resumed on scope-manifest change" "0" "$_resumed_count"
# A cache leaf EXISTS for the goal_hash but the scope_manifest_ref guard
# rejected it — this must surface as plan.context.resume_skipped, not a silent
# degrade (#1052 review observability fix).
assert_event_emitted "[SPEC-2][guard] plan.context.resume_skipped fires on guard mismatch" \
    "$EVENTS_FILE" "plan.context.resume_skipped"
# Restore the canonical manifest for downstream tests.
cat > "$STATE_DIR/scope-manifest.md" <<'SCOPE'
+ core/
+ plugins/
SCOPE
unset ZBUILD_ISSUE_NUMBER ZBUILD_PLAN_RESUME 2>/dev/null || true
PLAN_GOAL="test goal"

# ─── [SPEC-4][change] envelope recovery from prose-wrapped/last-turn result ───
# _plan_recover_envelope_json must salvage exactly one schema-valid plan object
# out of a prose-wrapped / multi-turn response and the plugin must emit
# plan.envelope.recovered when it does. Since #944 this helper delegates to the
# shared framework _llm_recover_envelope_json (_plan_envelope_schema_ok gate);
# the assertions below hold identically across the delegation.
print_test_section "[SPEC-4][change] envelope recovery of a single schema-bearer"
_VALID_PLAN='{"schema_version":1,"title":"recovered","goal":"g","steps":[{"id":"step-1","description":"d","files":["core/foo.sh"],"estimated_lines":3}],"estimated_total_lines":3,"notes":""}'
_PROSE_WRAPPED="I explored the repo across several turns. Here is the final plan:

$_VALID_PLAN

That completes my planning."
set +e
_recovered="$(_plan_recover_envelope_json "$_PROSE_WRAPPED" 2>/dev/null)"
_rec_rc=$?
set -e
assert_eq "[SPEC-4] _plan_recover_envelope_json returns rc=0 on single bearer" "0" "$_rec_rc"
_rec_sv="$(printf '%s' "$_recovered" | jq -r '.schema_version // empty' 2>/dev/null || true)"
assert_eq "[SPEC-4] recovered object has schema_version=1" "1" "$_rec_sv"
_rec_steps="$(printf '%s' "$_recovered" | jq -r '.steps | length' 2>/dev/null || echo 0)"
assert_gt "[SPEC-4] recovered object has non-empty steps[]" "$_rec_steps" "0"

# ─── [SPEC-4][guard] recovery fails closed on two schema-bearers ─────────────
# Ambiguity must fail closed (#908): two schema-valid objects → no recovery.
print_test_section "[SPEC-4][guard] recovery fails closed on ambiguity"
_TWO_BEARERS="First candidate:
$_VALID_PLAN
Second candidate:
$_VALID_PLAN"
set +e
_plan_recover_envelope_json "$_TWO_BEARERS" >/dev/null 2>&1
_amb_rc=$?
set -e
assert_eq "[SPEC-4][guard] two schema-bearers → recovery rc!=0 (fail closed)" \
    "1" "$_amb_rc"
# A bearer missing steps[] must also be rejected by the shared predicate.
set +e
_plan_envelope_schema_ok '{"schema_version":1,"title":"t","steps":[]}' >/dev/null 2>&1
_nosteps_rc=$?
set -e
assert_eq "[SPEC-4][guard] object missing non-empty steps[] rejected" "1" "$_nosteps_rc"

# ─── [SPEC-5][change] happy-path recovery via the shared framework (#944) ─────
# ADR-028 v1.2: plan's rc=0 parse now routes through _llm_envelope_parse
# --schema-gate _plan_envelope_schema_ok. When the model emits the real plan
# followed by a brace-bearing postamble, LAST-wins selects the postamble; the
# schema-gate must trigger _llm_recover_envelope_json and restore the real plan.
# CHANGE: RED before #944 — extract_first_json_object (LAST-wins) picks the
# junk object → schema_violation → rc=1.
: > "$EVENTS_FILE"
_SAVED_CANNED_PLAN="$CANNED_PLAN"
CANNED_PLAN='{"schema_version":1,"title":"recovered-via-framework","goal":"g","steps":[{"id":"step-1","description":"d","files":["core/foo.sh"],"estimated_lines":3}],"estimated_total_lines":3,"notes":""}

Trailing prose describing the plan. {"note":"brace-bearing postamble junk"}'
set +e
_run_plan "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "[SPEC-5] postamble-wrapped plan → framework recovery → rc=0" "0" "$rc"
_recovered_title="$(jq -r '.title // empty' "$ARTIFACTS_DIR/plan.json" 2>/dev/null || true)"
assert_eq "[SPEC-5] plan.json holds the real envelope, not the postamble" \
    "recovered-via-framework" "$_recovered_title"
CANNED_PLAN="$_SAVED_CANNED_PLAN"

# ─── [SPEC-1/SPEC-2] Persona framing fallback — prefix dropped (#1572) ───────
# SPEC-1 [change]: with product-owner manifest absent the prompt must NOT carry
#   the profession-role prefix 'You are a software planning agent.'  Fails at
#   merge-base baseline because the old fallback led with that sentence.
# SPEC-2 [guard]: with manifest present the canned behavior string must appear
#   in the prompt (persona-present path already worked; tagged, not contorted).

print_test_section "[SPEC-1/SPEC-2] persona fallback is behavior-only (no role prefix)"

# Save real persona_stage_framing so we can restore it after the section.
_ORIG_PSF="$(declare -f persona_stage_framing || true)"

# Simulate absent manifest: return rc=1 so the fallback path runs.
persona_stage_framing() { return 1; }

: > "$_CAPTURED_PROMPT_FILE"
CANNED_PLAN='{"schema_version":1,"issue":'"$_ZB_ID"',"title":"fixture","goal":"test goal","steps":[{"id":"step-1","description":"do thing","files":["core/foo.sh"],"estimated_lines":10}],"estimated_total_lines":10,"notes":""}'
set +e; _run_plan "$STATE_FILE" >/dev/null 2>&1; _spf_rc=$?; set -e
assert_eq "[SPEC-1] plan_run rc=0 with persona absent" "0" "$_spf_rc"
_spf_prompt="$(cat "$_CAPTURED_PROMPT_FILE" 2>/dev/null || true)"
if grep -q "You are a software planning agent" <<<"$_spf_prompt"; then
    assert_fail "[SPEC-1] persona fallback must NOT contain profession-prefix role declaration"
else
    assert_pass "[SPEC-1] persona fallback does not contain profession-prefix role declaration"
fi
assert_contains "[SPEC-1] persona fallback DOES contain behavior sentence" \
    "$_spf_prompt" "Decompose the goal into concrete implementation steps."

# Simulate present manifest: emit a canned sentinel string and return rc=0.
_PERSONA_FRAMING_SENTINEL="PERSONA_BEHAVIOR_SENTINEL_XYZ_1572"
persona_stage_framing() {
    printf '%s' "$_PERSONA_FRAMING_SENTINEL"
    return 0
}

: > "$_CAPTURED_PROMPT_FILE"
set +e; _run_plan "$STATE_FILE" >/dev/null 2>&1; _spf_rc2=$?; set -e
assert_eq "[SPEC-2] plan_run rc=0 with persona present" "0" "$_spf_rc2"
_spf_prompt2="$(cat "$_CAPTURED_PROMPT_FILE" 2>/dev/null || true)"
assert_contains "[SPEC-2] persona-present framing sentinel appears in prompt" \
    "$_spf_prompt2" "$_PERSONA_FRAMING_SENTINEL"

# Restore persona_stage_framing to its original definition.
unset -f persona_stage_framing
if [[ -n "$_ORIG_PSF" ]]; then eval "$_ORIG_PSF"; fi
# Restore CANNED_PLAN so the following sections run against the canonical fixture
# (this block overwrote it, mirroring the SPEC-5 restore above).
CANNED_PLAN="$_SAVED_CANNED_PLAN"

# plan_cleanup was deleted in #2001 (ADR-062 §3): its entire body was
# `return 0`. The engine now reclaims by reading the process group recorded
# at dispatch, so a no-op per-stage hook has nothing left to assert.

# ═══ #1727: a wall-clock timeout (rc=124) must reach the recovery path ═══════
# At the merge-base `_plan_run_inner` returned 1 the moment router_rc != 0, and
# that return sat ABOVE the #1052 recovery / state-save block — so for exactly
# the rcs that block exists to serve (124 wall-clock, 137 OOM) it was
# unreachable. One timeout aborted the whole run with nothing salvaged.
#
# Observed on runs 20260817184959-54622 and 20260817192215-57314 (issue #1832):
# plan killed at 300s mid-tool-use, `reason=router_fatal router_rc=124`, then
# `pipeline.abort`. Twice.
print_test_section "[#1727] rc=124 falls through to recovery instead of aborting"

_SAVED_CANNED_PLAN_1727="$CANNED_PLAN"
_ORIG_RTM_1727="$(declare -f route_to_model)"

# Router times out (rc=124) AND leaves a schema-valid plan in the captured
# response — the shape a model that finished its plan but was killed during a
# trailing tool call leaves behind. Recovery should salvage it.
route_to_model() {
    printf '%s' "$_SAVED_CANNED_PLAN_1727"
    return 124
}

: > "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true
rm -f "$ARTIFACTS_DIR/plan.json" 2>/dev/null || true
set +e; _run_plan "$STATE_FILE" >/dev/null 2>&1; _rc1727=$?; set -e

# THE ASSERTION THAT REDDENS AT THE MERGE-BASE: rc=124 used to return 1 here.
assert_eq "[#1727] rc=124 with a recoverable plan -> rc=0 (was: fatal 1)" \
    "0" "$_rc1727"
if [[ -s "$ARTIFACTS_DIR/plan.json" ]]; then
    assert_pass "[#1727] the salvaged plan.json was written"
else
    assert_fail "[#1727] the salvaged plan.json was written" "artifact absent"
fi

# The diagnostic is not silently downgraded — a router failure still says so.
_ev1727="$(cat "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
if grep -q "plan.router_failed" <<< "$_ev1727"; then
    assert_pass "[#1727] plan.router_failed is emitted"
else
    assert_fail "[#1727] plan.router_failed is emitted" \
        "event absent; router failure was swallowed"
fi
# Assert the PAYLOAD, not just the event name — the claim is that the rc is
# recorded, and an event that names no rc does not support it.
if grep -qE '"router_rc":"?124"?|router_rc=124' <<< "$_ev1727"; then
    assert_pass "[#1727] the event records router_rc=124"
else
    assert_fail "[#1727] the event records router_rc=124" \
        "router_rc missing from the payload"
fi
# The optimistic field must not claim an outcome it cannot know yet.
if grep -q "recovery_attempted" <<< "$_ev1727"; then
    assert_pass "[#1727] event says recovery_attempted, not recoverable"
else
    assert_fail "[#1727] event says recovery_attempted, not recoverable" \
        "field absent or still claims recoverability before recovery ran"
fi
# ...and it must NOT claim fatality any more.
if grep -q '"reason":"router_fatal"' <<< "$_ev1727"; then
    assert_fail "[#1727] router_fatal is no longer emitted" "still emitting router_fatal"
else
    assert_pass "[#1727] router_fatal is no longer emitted"
fi

# GUARD: a genuinely unrecoverable rc=124 must still fail — falling through is
# about REACHING the decision, not about passing regardless.
route_to_model() { printf '%s' 'not-a-plan'; return 124; }
rm -f "$ARTIFACTS_DIR/plan.json" 2>/dev/null || true
set +e; _run_plan "$STATE_FILE" >/dev/null 2>&1; _rc1727b=$?; set -e
if [[ "$_rc1727b" -ne 0 ]]; then
    assert_pass "[#1727] guard: unrecoverable rc=124 still fails (rc=$_rc1727b)"
else
    assert_fail "[#1727] guard: unrecoverable rc=124 still fails" \
        "rc=0 — the fall-through turned a real failure into a pass"
fi

unset -f route_to_model
if [[ -n "$_ORIG_RTM_1727" ]]; then eval "$_ORIG_RTM_1727"; fi
CANNED_PLAN="$_SAVED_CANNED_PLAN_1727"


# ─── Teardown ─────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
exit $((FAIL > 0))
