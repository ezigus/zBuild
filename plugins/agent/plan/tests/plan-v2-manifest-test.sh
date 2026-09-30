#!/usr/bin/env bash
# Tests: plugins/agent/plan — contract v2 manifest, inputs and budgets (#1835)
# Split from plan-test.sh (1,399 lines; review #2237). Shared setup: plan-test-lib.sh.
# shellcheck disable=SC2034  # PLAN_GOAL / CANNED_PLAN are read by plan-test-lib.sh's _run_plan and model mock
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugin: plan — contract v2 manifest, inputs and budgets (#1835)"

setup_test_env "plugin-plan-v2-manifest"

# shellcheck source=plan-test-lib.sh
source "$SCRIPT_DIR/plan-test-lib.sh"

# ═══════════════════════════════════════════════════════════════════════════
#  Issue #1835 — plan plugin contract v2 migration SPEC tests
# ═══════════════════════════════════════════════════════════════════════════
print_test_header "Issue #1835 — plan plugin contract v2 migration"

_MANIFEST_FILE="$PLUGIN_DIR/manifest.yaml"

# Restore canonical state for #1835 tests.
CANNED_PLAN='{"schema_version":1,"issue":'"$_ZB_ID"',"title":"fixture","goal":"test goal","steps":[{"id":"step-1","description":"do thing","files":["core/foo.sh"],"estimated_lines":10}],"estimated_total_lines":10,"notes":""}'
PLAN_GOAL="test goal"
unset ZBUILD_PLAN_RESUME ZBUILD_ISSUE_NUMBER ZBUILD_CYCLE_ITER ZBUILD_CYCLE_FEEDBACK_DIR 2>/dev/null || true

# Restore canned plan for remaining tests.
CANNED_PLAN='{"schema_version":1,"issue":'"$_ZB_ID"',"title":"fixture","goal":"test goal","steps":[{"id":"step-1","description":"do thing","files":["core/foo.sh"],"estimated_lines":10}],"estimated_total_lines":10,"notes":""}'

# ─── [#1835/SPEC-4][change] manifest declares result_contract=2 and valid_verdicts ─
print_test_section "[#1835/SPEC-4] manifest declares result_contract=2 and valid_verdicts=[pass,error]"
_s4_provides="$(awk '/^provides:/{found=1;next} found && /^[a-zA-Z]/{exit} found{print}' "$_MANIFEST_FILE" 2>/dev/null || true)"
if grep -q 'result_contract: 2' <<< "$_s4_provides" 2>/dev/null; then
    assert_pass "[#1835/SPEC-4] manifest provides.result_contract: 2"
else
    assert_fail "[#1835/SPEC-4] manifest provides.result_contract: 2"
fi
_s4_config="$(awk '/^config:/{found=1;next} found && /^[a-zA-Z]/{exit} found{print}' "$_MANIFEST_FILE" 2>/dev/null || true)"
_s4_vv="$(awk '/valid_verdicts:/{found=1;next} found && /^[[:space:]]+-/{print;next} found{exit}' <<< "$_s4_config" 2>/dev/null || true)"
if grep -q '\bpass\b' <<< "$_s4_vv" 2>/dev/null && \
   grep -q '\berror\b' <<< "$_s4_vv" 2>/dev/null; then
    assert_pass "[#1835/SPEC-4] manifest valid_verdicts contains pass and error"
else
    assert_fail "[#1835/SPEC-4] manifest valid_verdicts contains pass and error"
fi

# ─── [#1835/SPEC-5][change] reads scope_manifest from ZBUILD_STAGE_INPUTS ────
# plan_run must use the scope_manifest path from the ZBUILD_STAGE_INPUTS index
# rather than deriving it from state_dir. Fails at baseline because the plugin
# hard-codes $state_dir/scope-manifest.md.
print_test_section "[#1835/SPEC-5] reads scope_manifest from ZBUILD_STAGE_INPUTS"
_S5_STATE="$TEST_TEMP_DIR/state-spec5-1835"
mkdir -p "$_S5_STATE/artifacts"
printf '{"schema_version":1,"run_id":"test","issue":"%s","stage_statuses":{}}\n' "$_ZB_ID" > "$_S5_STATE/pipeline-state.json"
# Default state-dir manifest — different content from the custom one below so
# we can detect which path the plugin read.
cat > "$_S5_STATE/scope-manifest.md" <<'_S5SCOPE_OLD'
+ core/
_S5SCOPE_OLD
# Custom manifest routed via ZBUILD_STAGE_INPUTS with a unique prefix.
_S5_CUSTOM_MANIFEST="$TEST_TEMP_DIR/custom-scope-1835.md"
printf '+ CUSTOM_SCOPE_1835/\n+ plugins/\n' > "$_S5_CUSTOM_MANIFEST"
# Goal file — the index must name intake_goal too: plan reads its goal from the index only (#1835)
_S5_GOAL_FILE="$TEST_TEMP_DIR/goal-spec5-1835.md"
printf '%s\n' "test goal" > "$_S5_GOAL_FILE"
_S5_SI="$TEST_TEMP_DIR/stage-inputs-spec5-1835.json"
jq -n --arg sm "$_S5_CUSTOM_MANIFEST" --arg ig "$_S5_GOAL_FILE" \
    '{"inputs":{"scope_manifest":$sm,"intake_goal":$ig}}' > "$_S5_SI"

: > "$_CAPTURED_PROMPT_FILE"
export ZBUILD_STAGE_INPUTS="$_S5_SI"
set +e
_run_plan "$_S5_STATE/pipeline-state.json" >/dev/null 2>&1
_s5_rc=$?
set -e
unset ZBUILD_STAGE_INPUTS 2>/dev/null || true
_s5_prompt="$(cat "$_CAPTURED_PROMPT_FILE" 2>/dev/null || true)"
assert_eq "[#1835/SPEC-5] plan_run rc=0 with ZBUILD_STAGE_INPUTS" "0" "$_s5_rc"
if grep -qF "CUSTOM_SCOPE_1835/" <<< "$_s5_prompt"; then
    assert_pass "[#1835/SPEC-5] scope_manifest read from ZBUILD_STAGE_INPUTS (custom prefix in prompt)"
else
    assert_fail "[#1835/SPEC-5] scope_manifest read from ZBUILD_STAGE_INPUTS (custom prefix missing from prompt)" \
        "still reading from default state_dir/scope-manifest.md"
fi

# ─── [#1835/SPEC-6][change] rc=1 (not rc=2) when state_file missing; disposition=broken ─
print_test_section "[#1835/SPEC-6] rc=1 (not rc=2) when state_file missing; plan.json disposition=broken"
_S6_ARTIFACTS="$TEST_TEMP_DIR/spec6-artifacts-1835"
mkdir -p "$_S6_ARTIFACTS"
export ZBUILD_ARTIFACT_DIR="$_S6_ARTIFACTS"
set +e
_run_plan >/dev/null 2>&1
_s6_rc=$?
set -e
unset ZBUILD_ARTIFACT_DIR 2>/dev/null || true
assert_eq "[#1835/SPEC-6] plan_run returns rc=1 (not rc=2) when state_file missing" "1" "$_s6_rc"
assert_file_exists "[#1835/SPEC-6] plan.json written with v2 fields on broken path" "$_S6_ARTIFACTS/plan.json"
assert_eq "[#1835/SPEC-6] plan.json result_contract=2 on broken path" "2" \
    "$(jq -r '.result_contract // empty' "$_S6_ARTIFACTS/plan.json" 2>/dev/null || true)"
assert_eq "[#1835/SPEC-6] plan.json disposition=broken when state_file missing" "broken" \
    "$(jq -r '.disposition // empty' "$_S6_ARTIFACTS/plan.json" 2>/dev/null || true)"

# ─── [#1835/SPEC-9][change] manifest config.router max_turns=45 and timeout_s=300 ─
print_test_section "[#1835/SPEC-9] manifest router budget knobs and resolver behavior"
# Extract only the lines indented under `  router:` inside `config:`, so a stray
# max_turns in another sub-key cannot produce a false pass.
_s9_router="$(awk '
    /^config:/{in_c=1;next}
    in_c && /^  router:/{in_r=1;next}
    in_r && /^    /{print;next}
    in_r && /^  [a-zA-Z]/{exit}
    in_c && /^[a-zA-Z]/{exit}
' "$_MANIFEST_FILE" 2>/dev/null || true)"
if grep -qE 'max_turns:[[:space:]]*45' <<< "$_s9_router"; then
    assert_pass "[#1835/SPEC-9] manifest config.router.max_turns: 45"
else
    assert_fail "[#1835/SPEC-9] manifest config.router.max_turns: 45"
fi
if grep -qE 'timeout_s:[[:space:]]*300' <<< "$_s9_router"; then
    assert_pass "[#1835/SPEC-9] manifest config.router.timeout_s: 300"
else
    assert_fail "[#1835/SPEC-9] manifest config.router.timeout_s: 300"
fi
# Dynamic: _route_resolve_max_turns must return 45 from the plan manifest when no
# template or env override is set. Fails at baseline (manifest has no max_turns → default 25).
_s9_mt=""
if declare -F _route_resolve_max_turns >/dev/null 2>&1; then
    _s9_mt="$(ZBUILD_CURRENT_STAGE=plan ZBUILD_PLUGIN_DIR="$PLUGIN_DIR" \
        _route_resolve_max_turns 2>/dev/null || true)"
fi
assert_eq "[#1835/SPEC-9] _route_resolve_max_turns returns 45 from manifest (no override)" "45" "$_s9_mt"
# timeout_s resolves to 300 both from the manifest and from the default; the
# manifest assertion above is the load-bearing check for this knob.
_s9_to=""
if declare -F _route_resolve_timeout >/dev/null 2>&1; then
    _s9_to="$(ZBUILD_CURRENT_STAGE=plan ZBUILD_PLUGIN_DIR="$PLUGIN_DIR" \
        _route_resolve_timeout 2>/dev/null || true)"
fi
assert_eq "[#1835/SPEC-9] _route_resolve_timeout returns 300" "300" "$_s9_to"

# ─── [#1835/SPEC-10][guard] plan output entry declares primary: true ─────────
print_test_section "[#1835/SPEC-10] plan output entry declares primary: true (guard)"
_s10_outputs="$(awk '/^outputs:/{found=1;next} found && /^[a-zA-Z]/{exit} found{print}' "$_MANIFEST_FILE" 2>/dev/null || true)"
# Extract the block for the specific "id: plan" entry (ends at the next "- id:").
_s10_plan_block="$(awk '/id: plan$/{f=1;print;next} f && /- id:/{exit} f{print}' \
    <<< "$_s10_outputs" 2>/dev/null || true)"
if grep -q 'primary: true' <<< "$_s10_plan_block"; then
    assert_pass "[#1835/SPEC-10] primary: true is bound to the plan output entry"
else
    assert_fail "[#1835/SPEC-10] primary: true is bound to the plan output entry"
fi
# Exactly one output entry carries primary: true (no other entry must have it).
_s10_outputs_tmp="$TEST_TEMP_DIR/s10-outputs-1835.txt"
printf '%s\n' "$_s10_outputs" > "$_s10_outputs_tmp"
_s10_primary_count="$(grep -c 'primary: true' "$_s10_outputs_tmp" 2>/dev/null)" || _s10_primary_count="0"
assert_eq "[#1835/SPEC-10] exactly one primary: true in outputs block" "1" \
    "${_s10_primary_count//[$'\n\r ']/}"

# ─── [#1835/SPEC-11][change] reads goal from ZBUILD_STAGE_INPUTS intake_goal ─
# plan_run must read the goal from the ZBUILD_STAGE_INPUTS-provided intake_goal
# path and must NOT fall back to $state_dir/intake.md. Fails at baseline because
# the plugin reads it from the index only — no ZBUILD_GOAL, no $state_dir/intake.md (#1835).
print_test_section "[#1835/SPEC-11] reads goal from ZBUILD_STAGE_INPUTS intake_goal path"
_S11_STATE="$TEST_TEMP_DIR/state-spec11-1835"
mkdir -p "$_S11_STATE/artifacts"
printf '{"schema_version":1,"run_id":"test","issue":"%s","stage_statuses":{}}\n' "$_ZB_ID" > "$_S11_STATE/pipeline-state.json"
cat > "$_S11_STATE/scope-manifest.md" <<'_S11SCOPE'
+ core/
+ plugins/
_S11SCOPE
# Fallback file with distinguishably different content — must NOT be used.
printf '%s\n' "OLD_FALLBACK_INTAKE_CONTENT_1835" > "$_S11_STATE/intake.md"
# Preferred source via ZBUILD_STAGE_INPUTS intake_goal.
_S11_GOAL_FILE="$TEST_TEMP_DIR/intake-goal-spec11-1835.md"
printf '%s\n' "SI_INTAKE_GOAL_SENTINEL_1835" > "$_S11_GOAL_FILE"
_S11_SI="$TEST_TEMP_DIR/stage-inputs-spec11-1835.json"
jq -n --arg ig "$_S11_GOAL_FILE" --arg sm "$_S11_STATE/scope-manifest.md" \
    '{"inputs":{"intake_goal":$ig,"scope_manifest":$sm}}' > "$_S11_SI"

: > "$_CAPTURED_PROMPT_FILE"
CANNED_PLAN='{"schema_version":1,"issue":'"$_ZB_ID"',"title":"fixture","goal":"SI_INTAKE_GOAL_SENTINEL_1835","steps":[{"id":"step-1","description":"d","files":["core/foo.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}'
export ZBUILD_STAGE_INPUTS="$_S11_SI"
unset PLAN_GOAL
set +e
_run_plan "$_S11_STATE/pipeline-state.json" >/dev/null 2>&1
_s11_rc=$?
set -e
unset ZBUILD_STAGE_INPUTS 2>/dev/null || true
PLAN_GOAL="test goal"
_s11_prompt="$(cat "$_CAPTURED_PROMPT_FILE" 2>/dev/null || true)"
assert_eq "[#1835/SPEC-11] plan_run rc=0 when intake_goal provided via ZBUILD_STAGE_INPUTS" "0" "$_s11_rc"
if grep -qF "SI_INTAKE_GOAL_SENTINEL_1835" <<< "$_s11_prompt"; then
    assert_pass "[#1835/SPEC-11] goal read from ZBUILD_STAGE_INPUTS intake_goal path"
else
    assert_fail "[#1835/SPEC-11] goal read from ZBUILD_STAGE_INPUTS intake_goal path" \
        "sentinel not in prompt — goal not taken from the index"
fi
if grep -qF "OLD_FALLBACK_INTAKE_CONTENT_1835" <<< "$_s11_prompt"; then
    assert_fail "[#1835/SPEC-11] hardcoded \$state_dir/intake.md fallback must be removed"
else
    assert_pass "[#1835/SPEC-11] hardcoded \$state_dir/intake.md fallback is removed"
fi

# [#1835/SPEC-11] absent intake_goal path → rc=1, disposition=broken
_S11B_STATE="$TEST_TEMP_DIR/state-spec11b-1835"
mkdir -p "$_S11B_STATE/artifacts"
printf '{"schema_version":1,"run_id":"test","issue":"%s","stage_statuses":{}}\n' "$_ZB_ID" > "$_S11B_STATE/pipeline-state.json"
cat > "$_S11B_STATE/scope-manifest.md" <<'_S11BSCOPE'
+ core/
+ plugins/
_S11BSCOPE
_S11B_SI="$TEST_TEMP_DIR/stage-inputs-spec11b-1835.json"
jq -n --arg ig "/nonexistent/intake-goal-1835.md" --arg sm "$_S11B_STATE/scope-manifest.md" \
    '{"inputs":{"intake_goal":$ig,"scope_manifest":$sm}}' > "$_S11B_SI"
export ZBUILD_STAGE_INPUTS="$_S11B_SI"
unset PLAN_GOAL
CANNED_PLAN='{"schema_version":1,"title":"fixture","goal":"g","steps":[{"id":"step-1","description":"d","files":["core/foo.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}'
set +e
_run_plan "$_S11B_STATE/pipeline-state.json" >/dev/null 2>&1
_s11b_rc=$?
set -e
unset ZBUILD_STAGE_INPUTS 2>/dev/null || true
PLAN_GOAL="test goal"
assert_eq "[#1835/SPEC-11] absent intake_goal path → rc=1" "1" "$_s11b_rc"
assert_file_exists "[#1835/SPEC-11] absent intake_goal writes plan.json with disposition=broken" \
    "$_S11B_STATE/artifacts/plan.json"
assert_eq "[#1835/SPEC-11] absent intake_goal disposition=broken" "broken" \
    "$(jq -r '.disposition // empty' "$_S11B_STATE/artifacts/plan.json" 2>/dev/null || true)"

# [#1835/SPEC-11] unreadable intake_goal file → rc=1, disposition=broken
# The "file is unreadable" case is distinct from "file is absent": the path
# exists but open() fails. After migration, plan_run must treat both as broken.
_S11C_STATE="$TEST_TEMP_DIR/state-spec11c-1835"
mkdir -p "$_S11C_STATE/artifacts"
printf '{"schema_version":1,"run_id":"test","issue":"%s","stage_statuses":{}}\n' \
    "$_ZB_ID" > "$_S11C_STATE/pipeline-state.json"
cat > "$_S11C_STATE/scope-manifest.md" <<'_S11CSCOPE'
+ core/
+ plugins/
_S11CSCOPE
_S11C_GOAL="$TEST_TEMP_DIR/unreadable-intake-goal-1835.md"
printf 'unreadable goal content\n' > "$_S11C_GOAL"
chmod 000 "$_S11C_GOAL"
_S11C_SI="$TEST_TEMP_DIR/stage-inputs-spec11c-1835.json"
jq -n --arg ig "$_S11C_GOAL" --arg sm "$_S11C_STATE/scope-manifest.md" \
    '{"inputs":{"intake_goal":$ig,"scope_manifest":$sm}}' > "$_S11C_SI"
export ZBUILD_STAGE_INPUTS="$_S11C_SI"
unset PLAN_GOAL
set +e
_run_plan "$_S11C_STATE/pipeline-state.json" >/dev/null 2>&1
_s11c_rc=$?
set -e
chmod 644 "$_S11C_GOAL" 2>/dev/null || true
unset ZBUILD_STAGE_INPUTS 2>/dev/null || true
PLAN_GOAL="test goal"
assert_eq "[#1835/SPEC-11] unreadable intake_goal → rc=1" "1" "$_s11c_rc"
assert_file_exists "[#1835/SPEC-11] unreadable intake_goal writes plan.json with disposition=broken" \
    "$_S11C_STATE/artifacts/plan.json"
assert_eq "[#1835/SPEC-11] unreadable intake_goal disposition=broken" "broken" \
    "$(jq -r '.disposition // empty' "$_S11C_STATE/artifacts/plan.json" 2>/dev/null || true)"

# Restore canned plan for remaining tests.
CANNED_PLAN='{"schema_version":1,"issue":'"$_ZB_ID"',"title":"fixture","goal":"test goal","steps":[{"id":"step-1","description":"do thing","files":["core/foo.sh"],"estimated_lines":10}],"estimated_total_lines":10,"notes":""}'

# ─── [#1835/SPEC-12][change] plugin.sh has no hardcoded $state_dir/ input paths ─
# After migration, grep -E '\$state_dir/[[:alnum:]]' plugin.sh | grep -v artifacts
# must return empty. Fails at baseline: lines 111 (scope-manifest.md) and
# 117-118 (intake.md) match the pattern.
print_test_section "[#1835/SPEC-12] plugin.sh no hardcoded \$state_dir/ input paths"
_spec12_plugin="$PLUGIN_DIR/plugin.sh"
_spec12_raw="$(grep -nE '\$state_dir/[[:alnum:]]' "$_spec12_plugin" 2>/dev/null || true)"
_spec12_filtered="$(grep -v 'artifacts' <<< "$_spec12_raw" || true)"
if [[ -z "$_spec12_filtered" ]]; then
    assert_pass "[#1835/SPEC-12] plugin.sh has no hardcoded \$state_dir/<input> paths beyond artifacts_dir"
else
    assert_fail "[#1835/SPEC-12] plugin.sh has no hardcoded \$state_dir/<input> paths beyond artifacts_dir" \
        "found: $_spec12_filtered"
fi

# ─── [#1835/SPEC-13][guard] manifest provides.role: planner ─────────────────
print_test_section "[#1835/SPEC-13] manifest provides.role: planner (guard)"
_s13_provides="$(awk '/^provides:/{found=1;next} found && /^[a-zA-Z]/{exit} found{print}' "$_MANIFEST_FILE" 2>/dev/null || true)"
if grep -q 'role: planner' <<< "$_s13_provides" 2>/dev/null; then
    assert_pass "[#1835/SPEC-13] manifest provides.role: planner"
else
    assert_fail "[#1835/SPEC-13] manifest provides.role: planner"
fi

# ─── [#1835/SPEC-14][guard] manifest provides.events with 9-event vocabulary ─
print_test_section "[#1835/SPEC-14] manifest provides.events with 9-event vocabulary (guard)"
_s14_provides="$(awk '/^provides:/{found=1;next} found && /^[a-zA-Z]/{exit} found{print}' "$_MANIFEST_FILE" 2>/dev/null || true)"
for _s14_ev in \
    "plan.context.persisted" "plan.context.resume_skipped" "plan.context.resumed" \
    "plan.dod_violation" "plan.envelope.recovered" "plan.flow_wiring_missing" \
    "plan.scope.violation" "plan.scope_too_large" "plan.router_failed"; do
    if grep -qF "$_s14_ev" <<< "$_s14_provides" 2>/dev/null; then
        assert_pass "[#1835/SPEC-14] manifest declares event: $_s14_ev"
    else
        assert_fail "[#1835/SPEC-14] manifest declares event: $_s14_ev"
    fi
done

# ─── [#1835/SPEC-15][guard] manifest declares plan-summary.md and plan-checkpoint.md ─
print_test_section "[#1835/SPEC-15] manifest output entries with summary and checkpoint roles (guard)"
_s15_outputs="$(awk '/^outputs:/{found=1;next} found && /^[a-zA-Z]/{exit} found{print}' "$_MANIFEST_FILE" 2>/dev/null || true)"
# summary: true must be bound specifically to the plan-summary.md entry, not any output.
_s15_summary_block="$(awk \
    '/id: plan-summary.md/{f=1;print;next} f && /- id:/{exit} f{print}' \
    <<< "$_s15_outputs" 2>/dev/null || true)"
if grep -q 'summary: true' <<< "$_s15_summary_block"; then
    assert_pass "[#1835/SPEC-15] plan-summary.md output entry has summary: true"
else
    assert_fail "[#1835/SPEC-15] plan-summary.md output entry has summary: true"
fi
# role: checkpoint must be bound specifically to the plan-checkpoint.md entry, not any output.
_s15_checkpoint_block="$(awk \
    '/id: plan-checkpoint/{f=1;print;next} f && /- id:/{exit} f{print}' \
    <<< "$_s15_outputs" 2>/dev/null || true)"
if grep -q 'role: checkpoint' <<< "$_s15_checkpoint_block"; then
    assert_pass "[#1835/SPEC-15] plan-checkpoint.md output entry has role: checkpoint"
else
    assert_fail "[#1835/SPEC-15] plan-checkpoint.md output entry has role: checkpoint"
fi

# ─── [#1835/SPEC-16][change] runner.sh leaf-path rc=10 block deleted ─────────
# The block carrying "plan turn budget exhausted" in the leaf-path `stage:*` case
# of runner.sh must be absent after migration. Fails at baseline (lines ~3506-3522).
print_test_section "[#1835/SPEC-16] runner.sh leaf-path rc=10 plan-scope_too_large block deleted"
_RUNNER_FILE="$REPO_ROOT/core/pipeline/runner.sh"
if grep -qF "plan turn budget exhausted" "$_RUNNER_FILE" 2>/dev/null; then
    assert_fail "[#1835/SPEC-16] runner.sh leaf-path 'plan turn budget exhausted' block must be deleted" \
        "comment still present — leaf-path rc=10 block not yet removed"
else
    assert_pass "[#1835/SPEC-16] runner.sh leaf-path 'plan turn budget exhausted' block is absent"
fi

# ─── [#1835/SPEC-17][guard] manifest router retains retries=1 and retry_on_exhaustion=1 ─
print_test_section "[#1835/SPEC-17] manifest router retains retries=1 and retry_on_exhaustion=1 (guard)"
# Narrow to the config.router: sub-block so a match elsewhere in the manifest
# cannot produce a false pass (same extraction as SPEC-9).
_s17_router="$(awk '
    /^config:/{in_c=1;next}
    in_c && /^  router:/{in_r=1;next}
    in_r && /^    /{print;next}
    in_r && /^  [a-zA-Z]/{exit}
    in_c && /^[a-zA-Z]/{exit}
' "$_MANIFEST_FILE" 2>/dev/null || true)"
if grep -qE 'retries:[[:space:]]*1' <<< "$_s17_router"; then
    assert_pass "[#1835/SPEC-17] manifest config.router.retries: 1 retained"
else
    assert_fail "[#1835/SPEC-17] manifest config.router.retries: 1 retained"
fi
if grep -qE 'retry_on_exhaustion:[[:space:]]*1' <<< "$_s17_router"; then
    assert_pass "[#1835/SPEC-17] manifest config.router.retry_on_exhaustion: 1 retained"
else
    assert_fail "[#1835/SPEC-17] manifest config.router.retry_on_exhaustion: 1 retained"
fi

# ─── [#1835/SPEC-18][guard] template override beats manifest budget defaults ───
# After the manifest gains explicit max_turns:45 / timeout_s:300, a template that
# sets its own values must still win. Guards that adding manifest defaults does not
# break the template > manifest precedence documented in ADR-003.
# Fails at merge-base only if the manifest change introduces a precedence bug.
print_test_section "[#1835/SPEC-18] template override beats manifest budget defaults (guard)"
# Define template accessor stubs the router calls when ZBUILD_CURRENT_STAGE is set.
# See router-manifest-budget-test.sh [SPEC-4] for the accessor naming convention.
template_stage_router_max_turns() { printf '22\n'; }
template_stage_router_timeout()   { printf '150\n'; }

_s18_mt=""
_s18_to=""
if declare -F _route_resolve_max_turns >/dev/null 2>&1; then
    _s18_mt="$(ZBUILD_CURRENT_STAGE=plan ZBUILD_PLUGIN_DIR="$PLUGIN_DIR" \
        _route_resolve_max_turns 2>/dev/null || true)"
fi
if declare -F _route_resolve_timeout >/dev/null 2>&1; then
    _s18_to="$(ZBUILD_CURRENT_STAGE=plan ZBUILD_PLUGIN_DIR="$PLUGIN_DIR" \
        _route_resolve_timeout 2>/dev/null || true)"
fi
unset -f template_stage_router_max_turns template_stage_router_timeout 2>/dev/null || true
assert_eq "[#1835/SPEC-18] template max_turns=22 beats manifest default (45)" "22" "$_s18_mt"
assert_eq "[#1835/SPEC-18] template timeout=150 beats manifest default (300)" "150" "$_s18_to"


# ─── Teardown ─────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
exit $((FAIL > 0))
