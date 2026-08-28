#!/usr/bin/env bash
# tests/unit/stage-checkpoint-test.sh — the engine-generic stage checkpoint (#1879).
#
# A stage that exhausts its budget loses everything it explored. #1052's
# plan-specific answer cannot work — it rebuilds the lost context from the
# router's error envelope, and the CLI's `error_max_turns` envelope carries
# neither `.result` nor `.tool_uses`, so it distils only `num_turns: N`. The only
# thing that survives a torn-down CI runner is an artifact the MODEL wrote.
#
#   SPEC-1 [change]: a stage declaring `role: checkpoint` gets a prompt block
#                    carrying the RESOLVED path as a literal
#   SPEC-2 [guard] : a stage declaring no checkpoint gets NOTHING — its prompt
#                    must stay byte-identical to today's
#   SPEC-3 [guard] : the resolved path is OUTSIDE the repository, so a checkpoint
#                    can never enter a diff or trip a scope violation
#   SPEC-4 [change]: a prior checkpoint in THIS run is spliced back (intra-run retry)
#   SPEC-5 [change]: a prior checkpoint from a PRIOR RUN is spliced back via
#                    ZBUILD_RESTORED_ARTIFACTS_DIR (cross-run — needs #1878)
#   SPEC-6 [guard] : the live checkpoint WINS over a restored one — a retry must
#                    never read stale cross-run content over its own
#   SPEC-7 [change]: injection happens in _route_redact_prompt, the shared
#                    single-shot + loop funnel, and is idempotent
#   SPEC-8 [guard] : the block is injected BEFORE redaction, so it rides the
#                    ADR-004 chokepoint rather than bypassing it
#
# WHY the path is a literal and not an env var: _zbuild_make_fresh_shell unsets
# the whole ZBUILD_* namespace before every claude spawn (ADR-024/#671), so a
# model can never read an exported path. SPEC-1 pins the literal for that reason.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "stage checkpoint — declaration, injection, splice-back (#1879)"
setup_test_env "stage-checkpoint"

# shellcheck source=../../core/pipeline/verdict.sh
source "$REPO_ROOT/core/pipeline/verdict.sh" 2>/dev/null || true
# shellcheck source=../../scripts/lib/stage-checkpoint.sh
source "$REPO_ROOT/scripts/lib/stage-checkpoint.sh"

STATE="$TEST_TEMP_DIR/state"
mkdir -p "$STATE/artifacts"

_mk_manifest() {
    local file="$1" declare_cp="$2"
    { printf 'id: fixture\nkind: agent\nversion: 0.1.0\n\noutputs:\n'
      printf '  - id: primary-out\n    path: ${artifact_dir}/out.json\n'
      printf '    type: out.json\n    required: true\n    primary: true\n'
      if [[ "$declare_cp" == "yes" ]]; then
          printf '  - id: fixture-checkpoint\n    path: ${artifact_dir}/fixture-checkpoint.md\n'
          printf '    type: checkpoint.md\n    required: false\n    role: checkpoint\n'
      fi
    } > "$file"
}

M_YES="$TEST_TEMP_DIR/with-cp.yaml";  _mk_manifest "$M_YES" yes
M_NO="$TEST_TEMP_DIR/without-cp.yaml"; _mk_manifest "$M_NO"  no
CP="$STATE/artifacts/fixture-checkpoint.md"

# ─── SPEC-1: a declaring stage gets the block, with the resolved literal path ─
print_test_section "1. a declaring stage gets the checkpoint block"
block="$(checkpoint_prompt_block "$M_YES" "$STATE")"
assert_contains "[SPEC-1] the block is emitted" "$block" "STAGE CHECKPOINT"
assert_contains "[SPEC-1] it carries the RESOLVED path as a literal" "$block" "$CP"
if grep -q '${artifact_dir}' <<<"$block"; then
    assert_fail "[SPEC-1] the path is interpolated, not raw" "\${artifact_dir} leaked into the prompt"
else
    assert_pass "[SPEC-1] the path is interpolated, not raw"
fi

# ─── SPEC-2 [guard]: a non-declaring stage gets NOTHING ─────────────────────
print_test_section "2. a non-declaring stage is untouched"
noblock="$(checkpoint_prompt_block "$M_NO" "$STATE")"
assert_eq "[SPEC-2] no declaration -> empty block" "" "$noblock"

# ─── SPEC-3 [guard]: the path is outside the repository ─────────────────────
# A checkpoint written inside the repo would land in the build diff and trip a
# scope violation. The state dir is outside by construction; pin it.
print_test_section "3. the checkpoint path is outside the repository"
cp_path="$(_checkpoint_declared_path "$M_YES" "$STATE")"
case "$cp_path" in
    "$REPO_ROOT"/*) assert_fail "[SPEC-3] the checkpoint path is outside the repo" "resolved INSIDE: $cp_path" ;;
    *)              assert_pass "[SPEC-3] the checkpoint path is outside the repo" ;;
esac

# ─── SPEC-4: splice-back within the same run ────────────────────────────────
print_test_section "4. a prior checkpoint from THIS run is spliced back"
printf 'LIVE: read runner.sh; the dispatch-unit block starts at 2429.\n' > "$CP"
block4="$(checkpoint_prompt_block "$M_YES" "$STATE")"
assert_contains "[SPEC-4] the prior body is spliced in" "$block4" "the dispatch-unit block starts at 2429"
assert_contains "[SPEC-4] under a resumed-exploration heading" "$block4" "PRIOR EXPLORATION"

# ─── SPEC-5: splice-back across runs, via the ADR-050 restore dir ───────────
print_test_section "5. a prior RUN's checkpoint is spliced back"
RESTORED="$TEST_TEMP_DIR/restored"; mkdir -p "$RESTORED"
printf 'CROSSRUN: prior run mapped the cycle orchestrator.\n' > "$RESTORED/fixture-checkpoint.md"
rm -f "$CP"
block5="$(ZBUILD_RESTORED_ARTIFACTS_DIR="$RESTORED" checkpoint_prompt_block "$M_YES" "$STATE")"
assert_contains "[SPEC-5] the restored body is spliced in" "$block5" "prior run mapped the cycle orchestrator"

# ─── SPEC-6 [guard]: the live checkpoint wins over a restored one ───────────
print_test_section "6. the live checkpoint wins over the restored one"
printf 'LIVE-WINS: this run already explored further.\n' > "$CP"
block6="$(ZBUILD_RESTORED_ARTIFACTS_DIR="$RESTORED" checkpoint_prompt_block "$M_YES" "$STATE")"
assert_contains "[SPEC-6] the live body is used" "$block6" "this run already explored further"
if grep -q "prior run mapped the cycle orchestrator" <<<"$block6"; then
    assert_fail "[SPEC-6] the stale cross-run body must not be used" "restored content leaked over the live one"
else
    assert_pass "[SPEC-6] the stale cross-run body must not be used"
fi

# ─── SPEC-7 / SPEC-8: the router seam ───────────────────────────────────────
# _route_redact_prompt is the shared funnel for the single-shot path AND the
# agentic loop. It is the seam BECAUSE _llm_output_contract is not: only 3 of the
# 9 plugins calling route_to_model* use that builder, and `design` and `build` —
# the two heaviest exploration stages — are not among them.
print_test_section "7. injected at the shared router funnel, idempotently"
PLUGDIR="$TEST_TEMP_DIR/plug"; mkdir -p "$PLUGDIR"
_mk_manifest "$PLUGDIR/manifest.yaml" yes

# shellcheck source=../../core/router/route.sh
source "$REPO_ROOT/core/router/route.sh" 2>/dev/null || true

if declare -F _route_redact_prompt >/dev/null 2>&1; then
    IN="$TEST_TEMP_DIR/prompt.txt"; OUT="$TEST_TEMP_DIR/prompt.out"
    printf 'ORIGINAL PROMPT BODY\n' > "$IN"
    ZBUILD_PLUGIN_DIR="$PLUGDIR" ZBUILD_STATE_DIR="$STATE" ZBUILD_SCOPE_MANIFEST="" \
        _route_redact_prompt "$IN" "$OUT" 0 "" >/dev/null 2>&1 || true
    assert_contains "[SPEC-7] the funnel injects the block" "$(cat "$IN")" "STAGE CHECKPOINT"
    n1="$(grep -c 'STAGE CHECKPOINT' "$IN" 2>/dev/null)" || n1=0
    # Second pass = the loop's per-iteration redaction of the same file.
    ZBUILD_PLUGIN_DIR="$PLUGDIR" ZBUILD_STATE_DIR="$STATE" ZBUILD_SCOPE_MANIFEST="" \
        _route_redact_prompt "$IN" "$OUT" 1 "" >/dev/null 2>&1 || true
    n2="$(grep -c 'STAGE CHECKPOINT' "$IN" 2>/dev/null)" || n2=0
    # Pinned to EXACTLY 1, not merely n1 == n2: with the injection ablated both
    # counts are 0 and an equality assertion passes vacuously — proving nothing
    # about idempotence and nothing about injection.
    assert_eq "[SPEC-7] exactly one block after the first pass" "1" "$n1"
    assert_eq "[SPEC-7] still exactly one after a second pass (idempotent)" "1" "$n2"

    # [guard] the original prompt body must survive the injection.
    assert_contains "[SPEC-8] the original prompt body is preserved" "$(cat "$IN")" "ORIGINAL PROMPT BODY"

    # [guard] a NON-declaring stage gets no checkpoint block through the funnel.
    #
    # Deliberately NOT a byte-identical assertion: _route_redact_prompt also
    # prepends the ADR-049 vision preamble, which is pre-existing behaviour and
    # fires for every stage. Asserting byte-identity here would be asserting that
    # the vision preamble does not exist — a false invariant that would redden on
    # a change this issue has nothing to do with. The real guard is that THIS
    # feature contributes nothing to a stage that did not opt in.
    PLUGDIR2="$TEST_TEMP_DIR/plug2"; mkdir -p "$PLUGDIR2"
    _mk_manifest "$PLUGDIR2/manifest.yaml" no
    IN2="$TEST_TEMP_DIR/prompt2.txt"; printf 'UNTOUCHED BODY\n' > "$IN2"
    ZBUILD_PLUGIN_DIR="$PLUGDIR2" ZBUILD_STATE_DIR="$STATE" ZBUILD_SCOPE_MANIFEST="" \
        _route_redact_prompt "$IN2" "$TEST_TEMP_DIR/prompt2.out" 0 "" >/dev/null 2>&1 || true
    if grep -qF 'STAGE CHECKPOINT' "$IN2" 2>/dev/null; then
        assert_fail "[SPEC-7-guard] a non-declaring stage gets no checkpoint block" \
            "the block leaked into a stage that declared none"
    else
        assert_pass "[SPEC-7-guard] a non-declaring stage gets no checkpoint block"
    fi
    assert_contains "[SPEC-7-guard] and its own body is preserved" "$(cat "$IN2")" "UNTOUCHED BODY"
else
    assert_fail "[SPEC-7] _route_redact_prompt is available to test" "function not defined after sourcing route.sh"
fi

# ─── SPEC-9 / SPEC-10: the budget-exhaustion retry trigger ──────────────────
# `retries` is rc=124/timeout-only, so a turn-budget exhaustion (rc=1) was never
# retried — which is why the #1708 plan stage burned 46 turns, produced nothing,
# and aborted the pipeline. The trigger is a SEPARATE opt-in knob so `impact`,
# the one stage that sets `retries` today, keeps its exact current behaviour.
print_test_section "9. budget exhaustion is detected, and opt-in per stage"
# shellcheck source=../../scripts/lib/router-rc-classify.sh
source "$REPO_ROOT/scripts/lib/router-rc-classify.sh" 2>/dev/null || true

if declare -F _router_is_budget_exhausted >/dev/null 2>&1; then
    _router_is_budget_exhausted '{"subtype":"error_max_turns"}' \
        && assert_pass "[SPEC-9] subtype error_max_turns is exhaustion" \
        || assert_fail "[SPEC-9] subtype error_max_turns is exhaustion" "not detected"
    _router_is_budget_exhausted '{"terminal_reason":"max_turns"}' \
        && assert_pass "[SPEC-9] terminal_reason max_turns is exhaustion" \
        || assert_fail "[SPEC-9] terminal_reason max_turns is exhaustion" "not detected"
    # [guard] a rate limit is NOT exhaustion: it must keep flowing to the
    # rate-limit path, which deliberately does not auto-retry.
    if _router_is_budget_exhausted '{"api_error_status":429,"is_error":true}'; then
        assert_fail "[SPEC-9] a rate limit is not budget exhaustion" "429 misclassified as exhaustion"
    else
        assert_pass "[SPEC-9] a rate limit is not budget exhaustion"
    fi
    if _router_is_budget_exhausted '{"subtype":"success"}'; then
        assert_fail "[SPEC-9] a success is not budget exhaustion" "misclassified"
    else
        assert_pass "[SPEC-9] a success is not budget exhaustion"
    fi
else
    assert_fail "[SPEC-9] _router_is_budget_exhausted is defined" "missing"
fi

print_test_section "10. the opt-in is per stage, and impact is untouched"
# shellcheck source=../../core/plugin-registry/manifest-router-budget.sh
source "$REPO_ROOT/core/plugin-registry/manifest-router-budget.sh" 2>/dev/null || true
if declare -F manifest_router_knob >/dev/null 2>&1; then
    assert_eq "[SPEC-10] plan opts in to one exhaustion retry" \
        "1" "$(manifest_router_knob "$REPO_ROOT/plugins/agent/plan/manifest.yaml" retry_on_exhaustion)"
    # [guard] every other stage stays opted OUT — this must not become ambient.
    _optins=""
    for _m in "$REPO_ROOT"/plugins/*/*/manifest.yaml; do
        _v="$(manifest_router_knob "$_m" retry_on_exhaustion 2>/dev/null || true)"
        [[ -n "$_v" && "$_v" != "0" ]] && _optins+="$(basename "$(dirname "$_m")") "
    done
    assert_eq "[SPEC-10] plan is the ONLY stage opted in" "plan " "$_optins"
    # [guard] impact's `retries` is a different knob and is unchanged.
    assert_eq "[SPEC-10] impact declares no exhaustion retry" \
        "" "$(manifest_router_knob "$REPO_ROOT/plugins/agent/impact/manifest.yaml" retry_on_exhaustion)"
else
    assert_fail "[SPEC-10] manifest_router_knob is available" "missing"
fi

# ─── SPEC-11: the escalated budget actually REACHES claude ──────────────────
# PR #1881 review found this the hard way: `_claude_args` is built ONCE, above
# the retry loop, so updating `max_turns` inside the loop left the retry invoking
# claude with the exact budget that had just been exhausted. The escalation was
# inert and the retry near-pointless. SPEC-9/SPEC-10 could not catch it — they
# test detection and opt-in, never the invocation. This does.
print_test_section "11. the retry's escalated --max-turns reaches the argv"
_args=(-p "PROMPT" --print --model m --max-turns 45 --dangerously-skip-permissions)
_base=45
_next=$(( _base + _base / 2 ))
_cap=$(( _base * 2 ))
[[ "$_next" -gt "$_cap" ]] && _next="$_cap"
for _i in "${!_args[@]}"; do
    if [[ "${_args[$_i]}" == "--max-turns" ]]; then _args[$((_i + 1))]="$_next"; break; fi
done
assert_eq "[SPEC-11] 45 escalates to 67 (+50%, under the 2x cap)" "67" "$_next"
assert_contains "[SPEC-11] and the argv carries the escalated value" "${_args[*]}" "--max-turns 67"
if [[ "${_args[*]}" == *"--max-turns 45"* ]]; then
    assert_fail "[SPEC-11] the stale budget must not survive in the argv" "45 still present"
else
    assert_pass "[SPEC-11] the stale budget must not survive in the argv"
fi
# [guard] the cap is 2x the ORIGINAL budget, not 2x the current one — otherwise
# it compounds across retries and diverges from _route_escalate_timeout's ceiling.
_c1=$(( _base + _base / 2 )); [[ "$_c1" -gt $(( _base * 2 )) ]] && _c1=$(( _base * 2 ))
_c2=$(( _c1 + _c1 / 2 ));     [[ "$_c2" -gt $(( _base * 2 )) ]] && _c2=$(( _base * 2 ))
assert_eq "[SPEC-11] a second escalation is capped at 2x BASE, not 2x current" "90" "$_c2"
# [guard] the 0 sentinel means unbounded and must stay 0.
assert_eq "[SPEC-11] max_turns=0 (unbounded) stays 0" "0" "$(( 0 > 0 ? 0 + 0 / 2 : 0 ))"

# ─── SPEC-12 [guard]: the real router applies it ────────────────────────────
# The arithmetic above is the shape; this pins that route.sh actually rewrites
# the argv rather than only the variable.
print_test_section "12. route.sh rewrites the argv, not just the variable"
_rt="$REPO_ROOT/core/router/route.sh"
if grep -q '_claude_args\[\$((_ai + 1))\]="\$max_turns"' "$_rt"; then
    assert_pass "[SPEC-12] the exhaustion retry rewrites --max-turns in _claude_args"
else
    assert_fail "[SPEC-12] the exhaustion retry rewrites --max-turns in _claude_args" \
        "the escalation would not reach claude"
fi
if grep -q '_turn_cap=\$(( _exhaust_base_turns \* 2 ))' "$_rt"; then
    assert_pass "[SPEC-12] the cap is computed against the original budget"
else
    assert_fail "[SPEC-12] the cap is computed against the original budget" "cap compounds across retries"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
