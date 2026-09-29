#!/usr/bin/env bash
# Tests: plugins/agent/intake — the v2 result contract (#1837): manifest, the
# result file on every exit path, and the one word each way of stopping earns.
# Split from intake-test.sh (1,046 lines), which keeps goal capture, the gh
# fetch and the closed-issue gate.
#
# D1 [change] closed issue → misconfigured (nothing was down; the operator
#             chose a closed issue) — covered across a process boundary in
#             tests/integration/intake-refuse-on-closed-subprocess-test.sh
# D2 [change] a failed issue fetch with no --goal → unavailable: GitHub, a
#             service zBuild depends on, is not responding
# D3 [guard]  no goal and no issue → misconfigured
# D4 [change] a goal that sanitizes to nothing → misconfigured (the input is
#             empty; zBuild is not broken)
# D5 [change] the workspace branch: a failed fetch of the remote branch →
#             unavailable; any other refusal → misconfigured
# D6 [change] the caller's own TERM handler is back after intake returns
# D7 [change] a result file that cannot be written is reported: rc 1 and a
#             message naming the file — never a silent pass with no result
# D8 [change] no fallback path: with no ZBUILD_ARTIFACT_DIR intake writes no
#             result beside the state file, and says the engine gave it none
# D9 [change] intake's result writer takes the disposition as its THIRD
#             argument, like every other stage's, so the disposition-word lint
#             sees intake's words (it saw none)
# D10 [change] a signal after intake wrote its result leaves that result alone
#             (review: a graceful-drain TERM after the pass turned it into a failure)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugin: intake — v2 result contract (#1837)"
setup_test_env "plugin-intake-result"
_ZB_ID="$(zb_test_issue)"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_INTAKE_SKIP_BRANCH=1

# shellcheck source=../../../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
PLUGIN_DIR="$REPO_ROOT/plugins/agent/intake"

STATE_DIR="$TEST_TEMP_DIR/state"
STATE_FILE="$STATE_DIR/pipeline-state.json"
mkdir -p "$STATE_DIR"
echo '{"schema_version":1,"run_id":"test","issue":"0","stage_statuses":{}}' > "$STATE_FILE"
ARTIFACT_DIR="$STATE_DIR/artifacts"
mkdir -p "$ARTIFACT_DIR"
export ZBUILD_ARTIFACT_DIR="$ARTIFACT_DIR"

# shellcheck source=../../../../plugins/agent/intake/plugin.sh
source "$PLUGIN_DIR/plugin.sh"

# _disp — the disposition intake last wrote; _reason — its reason.
_disp()   { jq -r '.disposition // empty' "$ARTIFACT_DIR/intake-result.json" 2>/dev/null || true; }
_reason() { jq -r '.reason // empty' "$ARTIFACT_DIR/intake-result.json" 2>/dev/null || true; }
# _run_intake [state_file] — runs intake with a clean result file; prints rc.
_run_intake() {
    rm -f "$ARTIFACT_DIR/intake-result.json"
    local rc=0
    intake_run "intake" "${1-$STATE_FILE}" >/dev/null 2>&1 || rc=$?
    printf '%s' "$rc"
}

# ════════════════════════════════════════════════════════════════════════════
# #1837: v2 contract — acceptance assertions
# ════════════════════════════════════════════════════════════════════════════

_mf="$PLUGIN_DIR/manifest.yaml"

# ─── SPEC-4 [change]: manifest declares provides.result_contract: 2 ─────────
_s4_contract="$(yaml_get "$_mf" "provides.result_contract" 2>/dev/null || true)"
assert_eq "[#1837/SPEC-4] manifest provides.result_contract == 2" "2" "$_s4_contract"

# ─── SPEC-5 [change]: manifest config.valid_verdicts: [pass, fail] ───────────
_s5_vv_section="$(grep -A6 'valid_verdicts' "$_mf" 2>/dev/null || true)"
if grep -q 'pass' <<< "$_s5_vv_section" && grep -q 'fail' <<< "$_s5_vv_section"; then
    assert_pass "[#1837/SPEC-5] manifest config.valid_verdicts declares pass and fail"
else
    assert_fail "[#1837/SPEC-5] manifest config.valid_verdicts must declare pass and fail" \
        "${_s5_vv_section:-absent}"
fi

# ─── SPEC-6 [change]: intake-result.json primary:true IN outputs; scope_manifest not ─
# Extract the outputs section first — the stanza must live under outputs, not elsewhere.
_s6_outputs="$(awk '
    /^outputs:/ { in_s=1; next }
    in_s && /^[a-zA-Z_]/ && !/^outputs:/ { exit }
    in_s { print }
' "$_mf" 2>/dev/null || true)"

_s6_ir_stanza="$(awk '
    /intake.result|intake_result|intake-result/ { found=1 }
    found && /^[[:space:]]*-[[:space:]]*id:/ && !/intake.result|intake_result|intake-result/ { exit }
    found { print }
' <<< "$_s6_outputs" 2>/dev/null || true)"
if grep -q 'primary: true' <<< "$_s6_ir_stanza"; then
    assert_pass "[#1837/SPEC-6] intake-result.json is in outputs section with primary: true"
else
    assert_fail "[#1837/SPEC-6] intake-result.json must declare primary: true within the outputs section" \
        "${_s6_outputs:-(outputs section absent)}"
fi

_s6_sm_stanza="$(awk '
    /scope.manifest|scope_manifest/ { found=1 }
    found && /^[[:space:]]*-[[:space:]]*id:/ && !/scope.manifest|scope_manifest/ { exit }
    found { print }
' <<< "$_s6_outputs" 2>/dev/null || true)"
if grep -q 'primary: true' <<< "$_s6_sm_stanza"; then
    assert_fail "[#1837/SPEC-6] scope_manifest must NOT have primary: true after migration" "found"
else
    assert_pass "[#1837/SPEC-6] scope_manifest does not have primary: true"
fi

# ─── SPEC-7 [change]: manifest declares config.router.timeout_s and max_turns ─
# manifest_router_knob is loaded via registry.sh → manifest-validation.sh
_s7_timeout="$(manifest_router_knob "$_mf" timeout_s 2>/dev/null || true)"
_s7_maxturns="$(manifest_router_knob "$_mf" max_turns 2>/dev/null || true)"
if [[ -n "$_s7_timeout" ]]; then
    assert_pass "[#1837/SPEC-7] manifest declares config.router.timeout_s"
else
    assert_fail "[#1837/SPEC-7] manifest must declare config.router.timeout_s" "absent"
fi
if [[ -n "$_s7_maxturns" ]]; then
    assert_pass "[#1837/SPEC-7] manifest declares config.router.max_turns"
else
    assert_fail "[#1837/SPEC-7] manifest must declare config.router.max_turns" "absent"
fi

# ─── SPEC-8 [change]: scope-manifest.md and intake.md byte-identical to v1 golden ─
_s8_scope_golden="$REPO_ROOT/tests/golden/intake-scope-manifest-v1.golden"
_s8_goal_golden="$REPO_ROOT/tests/golden/intake-goal-v1.golden"
if [[ -f "$_s8_scope_golden" && -f "$_s8_goal_golden" ]]; then
    cat > "$STATE_DIR/platforms.json" <<'JSON'
{"detected":["ios","node"],"repo_head_sha":"golden"}
JSON
    export ZBUILD_GOAL="golden-parity: verify v1 intake content is preserved"
    rm -f "$STATE_DIR/scope-manifest.md" "$STATE_DIR/intake.md"
    set +e
    intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
    set -e
    if cmp -s "$STATE_DIR/scope-manifest.md" "$_s8_scope_golden"; then
        assert_pass "[#1837/SPEC-8] scope-manifest.md is byte-identical to v1 golden"
    else
        assert_fail "[#1837/SPEC-8] scope-manifest.md must match v1 golden fixture" \
            "run: diff $STATE_DIR/scope-manifest.md $_s8_scope_golden"
    fi
    if cmp -s "$STATE_DIR/intake.md" "$_s8_goal_golden"; then
        assert_pass "[#1837/SPEC-8] intake.md is byte-identical to v1 golden"
    else
        assert_fail "[#1837/SPEC-8] intake.md must match v1 golden fixture" \
            "run: diff $STATE_DIR/intake.md $_s8_goal_golden"
    fi
else
    assert_fail "[#1837/SPEC-8] v1 golden fixtures must exist before migration" \
        "missing: intake-scope-manifest-v1.golden and/or intake-goal-v1.golden"
fi
rm -f "$STATE_DIR/platforms.json"

# ─── SPEC-2 [change]: intake-result.json written on every exit path ──────────
# Success path: run with a known goal and no issue
rm -f "$ARTIFACT_DIR/intake-result.json"
export ZBUILD_GOAL="spec-2 success verification"
export ZBUILD_ISSUE="0"
set +e
intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
set -e
assert_file_exists "[#1837/SPEC-2] intake-result.json written on success" \
    "$ARTIFACT_DIR/intake-result.json"

# No-goal failure path
rm -f "$ARTIFACT_DIR/intake-result.json"
export ZBUILD_GOAL=""
export ZBUILD_ISSUE="0"
set +e
intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
set -e
assert_file_exists "[#1837/SPEC-2] intake-result.json written on no-goal failure" \
    "$ARTIFACT_DIR/intake-result.json"

# Missing state_file path (SPEC-1 + SPEC-2)
rm -f "$ARTIFACT_DIR/intake-result.json"
export ZBUILD_GOAL="spec-1-2 missing-state-file check"
export ZBUILD_ISSUE="0"
set +e
_s1_miss_rc=0
intake_run "intake" "" >/dev/null 2>&1 || _s1_miss_rc=$?
set -e
assert_eq "[#1837/SPEC-1] missing state_file returns rc=1" "1" "$_s1_miss_rc"
assert_file_exists "[#1837/SPEC-2] intake-result.json written on missing state_file" \
    "$ARTIFACT_DIR/intake-result.json"

# Empty-after-sanitization path (SPEC-1 + SPEC-2)
# A goal consisting only of a stripped sentinel sanitizes to the empty string.
rm -f "$ARTIFACT_DIR/intake-result.json"
export ZBUILD_GOAL=$'\n\nHUMAN FEEDBACK\ngoal that sanitizes to nothing'
export ZBUILD_ISSUE="0"
set +e
_s1_empty_rc=0
intake_run "intake" "$STATE_FILE" >/dev/null 2>&1 || _s1_empty_rc=$?
set -e
assert_eq "[#1837/SPEC-1] empty-after-sanitization returns rc=1" "1" "$_s1_empty_rc"
assert_file_exists "[#1837/SPEC-2] intake-result.json written on empty-after-sanitization failure" \
    "$ARTIFACT_DIR/intake-result.json"

# Branch-refused path (SPEC-1 + SPEC-2)
rm -f "$ARTIFACT_DIR/intake-result.json"
export ZBUILD_GOAL="spec-1-2 branch-refused path check"
export ZBUILD_ISSUE="0"
# Stub the branch op inside a subshell: `unset -f` afterwards would delete the
# REAL function for every later test in this file, not restore it.
_s1_branch_rc="$(
    # shellcheck disable=SC2317  # called indirectly via intake_run
    _intake_create_workspace_branch() { return 1; }
    unset ZBUILD_INTAKE_SKIP_BRANCH
    intake_run "intake" "$STATE_FILE" >/dev/null 2>&1; printf '%s' "$?"
)"
assert_eq "[#1837/SPEC-1] branch-refused returns rc=1" "1" "$_s1_branch_rc"
assert_file_exists "[#1837/SPEC-2] intake-result.json written on branch-refused failure" \
    "$ARTIFACT_DIR/intake-result.json"

# ─── SPEC-3 [change]: result file structure ──────────────────────────────────
# Use the success-path file written above (if present) to verify v2 structure.
# Re-run a clean success to get a predictable result.
rm -f "$ARTIFACT_DIR/intake-result.json"
export ZBUILD_GOAL="spec-3 result structure check"
export ZBUILD_ISSUE="0"
set +e
intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
set -e
_s3_file="$ARTIFACT_DIR/intake-result.json"
if [[ -f "$_s3_file" ]]; then
    assert_eq "[#1837/SPEC-3] result_contract == 2" \
        "2" "$(jq -r '.result_contract // empty' "$_s3_file" 2>/dev/null || true)"
    _s3_verdict="$(jq -r '.verdict // empty' "$_s3_file" 2>/dev/null || true)"
    if [[ "$_s3_verdict" == "pass" || "$_s3_verdict" == "fail" ]]; then
        assert_pass "[#1837/SPEC-3] verdict is in {pass, fail}"
    else
        assert_fail "[#1837/SPEC-3] verdict must be pass or fail" "got: ${_s3_verdict:-empty}"
    fi
    _s3_disp="$(jq -r '.disposition // empty' "$_s3_file" 2>/dev/null || true)"
    _s3_valid_disps="complete interrupted throttled broken unusable timed_out out_of_turns misconfigured unavailable"
    if [[ -n "$_s3_disp" ]] && grep -qw "$_s3_disp" <<< "$_s3_valid_disps"; then
        assert_pass "[#1837/SPEC-3] disposition is in engine vocabulary"
    else
        assert_fail "[#1837/SPEC-3] disposition must be in engine vocabulary" \
            "got: ${_s3_disp:-empty}"
    fi
    _s3_reason="$(jq -r '.reason // ""' "$_s3_file" 2>/dev/null || true)"
    if [[ -n "$_s3_reason" ]]; then
        assert_pass "[#1837/SPEC-3] reason is non-empty"
    else
        assert_fail "[#1837/SPEC-3] reason must be non-empty" "empty"
    fi
else
    assert_fail "[#1837/SPEC-3] intake-result.json must exist for structure check" "absent"
fi

# ─── SPEC-15 [change]: data.goal_len and data.platform_count on success ──────
# Use a known goal (no sentinels → sanitized == goal, goal_len == ${#goal}) and a
# platforms.json with a fixed count so both fields can be verified by exact value.
rm -f "$ARTIFACT_DIR/intake-result.json"
_s15_goal="spec-15 exact character count and platform count verification"
_s15_expected_len="${#_s15_goal}"
cat > "$STATE_DIR/platforms.json" <<'S15JSON'
{"detected":["ios","android"],"repo_head_sha":"s15"}
S15JSON
_s15_expected_pc=2

export ZBUILD_GOAL="$_s15_goal"
export ZBUILD_ISSUE="0"
set +e
intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
set -e
rm -f "$STATE_DIR/platforms.json"

_s15_file="$ARTIFACT_DIR/intake-result.json"
if [[ -f "$_s15_file" ]]; then
    _s15_gl="$(jq -r '.data.goal_len // empty' "$_s15_file" 2>/dev/null || true)"
    _s15_pc="$(jq -r '.data.platform_count // empty' "$_s15_file" 2>/dev/null || true)"
    assert_eq "[#1837/SPEC-15] data.goal_len equals sanitized goal character count" \
        "$_s15_expected_len" "$_s15_gl"
    assert_eq "[#1837/SPEC-15] data.platform_count equals number of detected platforms" \
        "$_s15_expected_pc" "$_s15_pc"
else
    assert_fail "[#1837/SPEC-15] intake-result.json must exist for data field check" "absent"
fi

# ─── SPEC-10 [guard]: plugin.sh references ZBUILD_ARTIFACT_DIR ───────────────
if grep -q 'ZBUILD_ARTIFACT_DIR' "$PLUGIN_DIR/plugin.sh"; then
    assert_pass "[#1837/SPEC-10] plugin.sh references ZBUILD_ARTIFACT_DIR"
else
    assert_fail "[#1837/SPEC-10] plugin.sh must reference ZBUILD_ARTIFACT_DIR" "not found"
fi

# ─── SPEC-11 [change]: manifest hooks section has no-cleanup comment (ADR-054 §7) ─
# Both halves of the ADR-054 §7 statement are required: "holds no live resources"
# AND "declares no cleanup hook" — an OR would accept a partial comment.
_s11_hooks_section="$(awk '
    /^hooks:/ { found=1 }
    found && /^[a-zA-Z_]/ && !/^hooks:/ { exit }
    found { print }
' "$_mf" 2>/dev/null || true)"
_s11_has_no_live=0
_s11_has_no_cleanup=0
grep -qiE 'no.*live.*resource|holds no live' <<< "$_s11_hooks_section" \
    && _s11_has_no_live=1 || true
grep -qiE 'no.*cleanup.*hook|declares no cleanup' <<< "$_s11_hooks_section" \
    && _s11_has_no_cleanup=1 || true
if [[ "$_s11_has_no_live" -eq 1 && "$_s11_has_no_cleanup" -eq 1 ]]; then
    assert_pass "[#1837/SPEC-11] manifest hooks section records no cleanup hook (ADR-054 §7)"
else
    assert_fail "[#1837/SPEC-11] manifest hooks must note both: intake holds no live resources AND declares no cleanup hook" \
        "${_s11_hooks_section:-absent}"
fi

# ─── SPEC-12 [guard]: manifest provides.role: intake ─────────────────────────
_s12_role="$(yaml_get "$_mf" "provides.role" 2>/dev/null || true)"
assert_eq "[#1837/SPEC-12] manifest provides.role == intake" "intake" "$_s12_role"

# ─── SPEC-13 [guard]: manifest provides.events lists >= 17 intake.* events ───
# Count floor plus per-event check: adding new events while dropping old ones
# would satisfy a count-only assertion but violate the no-drop requirement.
_s13_count="$(grep -c '^[[:space:]]*-[[:space:]]*intake\.' "$_mf" 2>/dev/null || true)"
if [[ "$_s13_count" -ge 17 ]]; then
    assert_pass "[#1837/SPEC-13] manifest provides.events has >= 17 intake.* events (found: $_s13_count)"
else
    assert_fail "[#1837/SPEC-13] manifest must list >= 17 intake.* events" \
        "found: ${_s13_count:-0}"
fi
_s13_required=(
    "intake.baseline.captured"
    "intake.branch.adopted"
    "intake.branch.created"
    "intake.branch.from_detached"
    "intake.branch.noop"
    "intake.branch.reclaim_refused"
    "intake.branch.reclaimed"
    "intake.branch.reused"
    "intake.error"
    "intake.override.closed_issue_allowed"
    "intake.refused.branch_exists_remote_only"
    "intake.refused.dirty_tree"
    "intake.refused.git_unavailable"
    "intake.refused.invalid_branch_name"
    "intake.refused.issue_closed"
    "intake.refused.repo_state"
    "intake.untracked_baseline.captured"
)
_s13_missing=()
for _s13_ev in "${_s13_required[@]}"; do
    if ! grep -q "^[[:space:]]*-[[:space:]]*${_s13_ev}[[:space:]]*$" "$_mf"; then
        _s13_missing+=("$_s13_ev")
    fi
done
if [[ "${#_s13_missing[@]}" -eq 0 ]]; then
    assert_pass "[#1837/SPEC-13] all 17 pre-migration intake.* events are still present"
else
    assert_fail "[#1837/SPEC-13] no pre-migration event must be dropped" \
        "missing: ${_s13_missing[*]}"
fi

# ─── SPEC-14 [change]: template_stage_router_timeout > manifest config.router.* ─
# Requires route.sh for _route_resolve_timeout. Source it only if not already loaded.
if ! declare -F _route_resolve_timeout >/dev/null 2>&1; then
    # shellcheck source=../../../../core/router/route.sh
    source "$REPO_ROOT/core/router/route.sh" 2>/dev/null || true
fi
if declare -F _route_resolve_timeout >/dev/null 2>&1; then
    _s14_mf_timeout="$(manifest_router_knob "$_mf" timeout_s 2>/dev/null || true)"
    if [[ -n "$_s14_mf_timeout" ]]; then
        _s14_prev_pdir="${ZBUILD_PLUGIN_DIR:-__UNSET__}"
        _s14_prev_stage="${ZBUILD_CURRENT_STAGE:-__UNSET__}"
        _s14_prev_rt="${ZBUILD_ROUTER_TIMEOUT:-__UNSET__}"
        export ZBUILD_PLUGIN_DIR="$PLUGIN_DIR"
        export ZBUILD_CURRENT_STAGE="intake"
        unset ZBUILD_ROUTER_TIMEOUT 2>/dev/null || true
        _s14_tpl_val=$(( _s14_mf_timeout + 100 ))
        # Define the template accessor that _route_resolve_knob calls.
        # shellcheck disable=SC2317  # called indirectly via _route_resolve_timeout
        template_stage_router_timeout() { printf '%s\n' "$_s14_tpl_val"; }
        _s14_resolved="$(_route_resolve_timeout)"
        assert_eq "[#1837/SPEC-14] template value wins over manifest config.router.timeout_s" \
            "$_s14_tpl_val" "$_s14_resolved"
        unset -f template_stage_router_timeout 2>/dev/null || true
        if [[ "$_s14_prev_pdir" == "__UNSET__" ]]; then
            unset ZBUILD_PLUGIN_DIR
        else
            export ZBUILD_PLUGIN_DIR="$_s14_prev_pdir"
        fi
        if [[ "$_s14_prev_stage" == "__UNSET__" ]]; then
            unset ZBUILD_CURRENT_STAGE
        else
            export ZBUILD_CURRENT_STAGE="$_s14_prev_stage"
        fi
        if [[ "$_s14_prev_rt" == "__UNSET__" ]]; then
            unset ZBUILD_ROUTER_TIMEOUT
        else
            export ZBUILD_ROUTER_TIMEOUT="$_s14_prev_rt"
        fi
    else
        assert_fail "[#1837/SPEC-14] manifest must declare config.router.timeout_s for template override test" \
            "absent — SPEC-7 must pass first"
    fi
else
    assert_fail "[#1837/SPEC-14] _route_resolve_timeout not available (route.sh failed to load)" "absent"
fi

# ─── SPEC-17 [guard]: no hardcoded input artifact path constructions ──────────
# Check multiple bypass forms: variable/../ traversal (any var, not just state_dir)
# and bare /artifacts/<name> references on non-ZBUILD_ARTIFACT_DIR / non-_intake_art
# lines (comments are excluded).  Both patterns must return zero matches.
_s17_traversal="$(grep -nE '\$\{?[a-zA-Z_][a-zA-Z_0-9]*\}?/\.\./' \
    "$PLUGIN_DIR/plugin.sh" 2>/dev/null || true)"
_s17_bare_all="$(grep -nE '/artifacts/[a-z]' "$PLUGIN_DIR/plugin.sh" 2>/dev/null || true)"
_s17_bare=""
while IFS= read -r _s17_line; do
    [[ -z "$_s17_line" ]] && continue
    # Allow lines that reference ZBUILD_ARTIFACT_DIR or the internal _intake_art
    # variable; reject comment-only lines carrying the string as documentation.
    if ! grep -qE 'ZBUILD_ARTIFACT_DIR|_intake_art' <<< "$_s17_line" && \
       ! grep -qE '^[0-9]+:[[:space:]]*#' <<< "$_s17_line"; then
        _s17_bare+="${_s17_line}"$'\n'
    fi
done <<< "$_s17_bare_all"
_s17_hits="${_s17_traversal}${_s17_bare}"
if [[ -z "$_s17_hits" ]]; then
    assert_pass "[#1837/SPEC-17] plugin.sh has no hardcoded artifact input path constructions"
else
    assert_fail "[#1837/SPEC-17] plugin.sh must not construct artifact input paths without ZBUILD_ARTIFACT_DIR" \
        "$_s17_hits"
fi

# ════════════════════════════════════════════════════════════════════════════
# #1837 close-out: one word for each way of stopping
# ════════════════════════════════════════════════════════════════════════════
print_test_section "D2: a failed issue fetch with no goal"
mock_binary "gh" 'exit 1'
unset ZBUILD_GOAL 2>/dev/null || true
export ZBUILD_ISSUE="$_ZB_ID"
assert_eq "[D2] a failed fetch with no goal fails the stage" "1" "$(_run_intake)"
assert_eq "[D2] ...as unavailable: GitHub is not responding" "unavailable" "$(_disp)"
assert_contains "[D2] ...and the reason names GitHub" "$(_reason)" "GitHub"
rm -f "$TEST_TEMP_DIR/bin/gh"

print_test_section "D3/D4: the goal itself"
export ZBUILD_ISSUE="0"
export ZBUILD_GOAL=""
_run_intake >/dev/null
assert_eq "[D3] no goal and no issue → misconfigured" "misconfigured" "$(_disp)"
export ZBUILD_GOAL=$'\n\nHUMAN FEEDBACK\ngoal that sanitizes to nothing'
_run_intake >/dev/null
assert_eq "[D4] a goal that sanitizes to nothing → misconfigured" "misconfigured" "$(_disp)"

print_test_section "D5: the workspace branch"
# A real repo whose remote-tracking ref exists but whose remote cannot be
# reached: adopting the branch needs a fetch, and the fetch fails.
_REPO="$TEST_TEMP_DIR/branch-repo"
mkdir -p "$_REPO"
git -C "$_REPO" init -q
git -C "$_REPO" config user.email t@t
git -C "$_REPO" config user.name t
git -C "$_REPO" commit -q --allow-empty -m seed
git -C "$_REPO" remote add origin "$TEST_TEMP_DIR/no-such-remote.git"
git -C "$_REPO" update-ref refs/remotes/origin/zb/fetch-fails HEAD
export ZBUILD_GOAL="branch disposition check"
unset ZBUILD_INTAKE_SKIP_BRANCH
_rc5="$( cd "$_REPO" && ZBUILD_WORKSPACE_BRANCH="zb/fetch-fails" CI=false CI_MODE=false _run_intake )"
assert_eq "[D5] a branch that cannot be fetched fails the stage" "1" "$_rc5"
assert_eq "[D5] ...as unavailable: the remote is not responding" "unavailable" "$(_disp)"
assert_contains "[D5] ...and the reason names the branch" "$(_reason)" "zb/fetch-fails"
_rc5b="$( cd "$_REPO" && ZBUILD_WORKSPACE_BRANCH="bad..name" CI=false CI_MODE=false _run_intake )"
assert_eq "[D5] an invalid branch name fails the stage" "1" "$_rc5b"
assert_eq "[D5] ...as misconfigured" "misconfigured" "$(_disp)"
export ZBUILD_INTAKE_SKIP_BRANCH=1

print_test_section "D6: the caller's TERM handler"
_out6="$(
    trap 'printf "CALLER\n"' TERM
    ZBUILD_GOAL="trap restore check" ZBUILD_ISSUE=0 intake_run "intake" "$STATE_FILE" >/dev/null 2>&1 || true
    trap -p TERM
)"
assert_contains "[D6] the caller's TERM handler is back after intake returns" "$_out6" "CALLER"

print_test_section "D7: a result that cannot be written"
_blocker="$TEST_TEMP_DIR/not-a-dir"; : > "$_blocker"
_err7="$( ZBUILD_ARTIFACT_DIR="$_blocker/artifacts" ZBUILD_GOAL="write failure check" ZBUILD_ISSUE=0 \
    intake_run "intake" "$STATE_FILE" 2>&1 >/dev/null )" && _rc7=0 || _rc7=$?
assert_eq "[D7] a result that cannot be written fails the stage" "1" "$_rc7"
assert_contains "[D7] ...and says which file" "$_err7" "intake-result.json"

print_test_section "D8: no fallback path"
rm -rf "$ARTIFACT_DIR"
_err8="$( unset ZBUILD_ARTIFACT_DIR; ZBUILD_GOAL="no artifact dir check" ZBUILD_ISSUE=0 \
    intake_run "intake" "$STATE_FILE" 2>&1 >/dev/null )" || true
assert_file_not_exists "[D8] no result is written beside the state file" "$STATE_DIR/artifacts/intake-result.json"
assert_contains "[D8] ...and intake says the engine gave it no artifact dir" "$_err8" "ZBUILD_ARTIFACT_DIR"
mkdir -p "$ARTIFACT_DIR"

print_test_section "D9: the disposition-word lint sees intake"
_L="$TEST_TEMP_DIR/lint-plugins/agent/intake"; mkdir -p "$_L"
cp "$PLUGIN_DIR/plugin.sh" "$_L/plugin.sh"
_lint9="$(bash "$REPO_ROOT/scripts/lib/lint-disposition-words.sh" "$TEST_TEMP_DIR/lint-plugins" 2>&1 || true)"
_n9="$(grep -oE '[0-9]+ literal' <<< "$_lint9" | grep -oE '[0-9]+' || true)"
assert_gt "[D9] the lint reads intake's literal dispositions (found ${_n9:-0})" "${_n9:-0}" "4"

print_test_section "D10: a signal after the result is written"
_d10="$(
    ZBUILD_GOAL="late signal check" ZBUILD_ISSUE=0 _intake_run_inner "intake" "$STATE_FILE" >/dev/null 2>&1
    _intake_on_signal "$STAGE_SIGNAL_DISPOSITION" "$STAGE_SIGNAL_REASON" >/dev/null 2>&1
)" || true
assert_eq "[D10] the pass intake wrote is still the result" "complete" "$(_disp)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
