#!/usr/bin/env bash
# Tests: plugins/agent/deploy — deploy stage agent unit tests (issues #757, #1846)
#
# Covers: SPEC-1..24 (deploy plugin contract v2 migration)
# SPEC-1  [#1846/SPEC-1]:  deploy plugin exists with deploy_agent_run function
# SPEC-2  [#1846/SPEC-2]:  ZBUILD_DRY_RUN=1 writes deploy-result.json verdict=deployed (ZBUILD_STAGE_INPUTS dispatch)
# SPEC-3  [#1846/SPEC-3]:  missing pr_url input → rc!=0 and verdict=error
# SPEC-4  [#1846/SPEC-4]:  gate verdict=fail → verdict=skipped (fail-closed allowlist)
# SPEC-5  [#1846/SPEC-5]:  plugin.sh has "Role: deploy_agent" preamble comment
# SPEC-6  [#1846/SPEC-6]:  no route_to_model call in non-comment code
# SPEC-7  [#1846/SPEC-7]:  dry-run deploy-result.json carries result_contract=2 (not schema_version=1)
# SPEC-8  [#1846/SPEC-8]:  missing gate (non-dry-run) → fail-closed rc=1 (not rc=2)
# SPEC-9  [#1846/SPEC-9]:  manifest provides block declares result_contract: 2
# SPEC-10 [#1846/SPEC-10]: every terminal exit path writes v2 envelope
# SPEC-11 [#1846/SPEC-11]: plugin.sh derives output path from ZBUILD_ARTIFACT_DIR; no state_file-derived path
# SPEC-12 [#1846/SPEC-12]: pr_url and gate_aggregator_result resolved via ZBUILD_STAGE_INPUTS
# SPEC-13 [#1846/SPEC-13]: all error exit paths return rc=1; no exit path returns rc=2 or higher
# SPEC-14 [#1846/SPEC-14]: all three valid verdicts exercised with v2-shaped result
# SPEC-15 [#1846/SPEC-15]: manifest has no config.router block; manifest_router_knob returns empty
# SPEC-16 [#1846/SPEC-16]: manifest outputs.deploy_result retains primary: true
# SPEC-17 [#1846/SPEC-17]: manifest provides.role = deploy_agent; provides.events = exactly 4 events
# SPEC-18 [#1846/SPEC-18]: manifest hooks block declares only run; no cleanup entry
# SPEC-19 [#1846/SPEC-19]: dry-run carries verdict=deployed, disposition=complete, reason present
# SPEC-20 [#1846/SPEC-20]: deploy-release returns non-zero → disposition=unavailable
# SPEC-21 [#1846/SPEC-21]: deploy-release plugin file absent → disposition=broken
# SPEC-22 [#1846/SPEC-22]: manifest config.valid_verdicts lists exactly deployed, error, skipped
# SPEC-24 [#1846/SPEC-24]: manifest carries router-budget-absence comment ("router budgets: none" + ADR-037 §3)
#
# Added by hand after PR #2219's review (lenses + claude-review). The run-path
# tests below exercise the REAL deploy-release plugin; only the outside world —
# `git` and `gh` — is faked, on PATH. The mock these tests used before accepted
# any arguments, so a call that dropped deploy-release's state_file argument
# passed every test while every real deploy failed.
# R1 [change] a passing gate cuts and pushes the release tag through the real
#             deploy-release, and the result carries the tag and the PR
# R2 [change] a failed `git tag` keeps deploy-release's own disposition (broken)
# R3 [change] a failed `git push` keeps deploy-release's own disposition
#             (unavailable) and rolls the local tag back
# R4 [change] deploy-release writes into ZBUILD_ARTIFACT_DIR, not beside the state file
# R5 [change] a signal mid-release writes disposition=interrupted and returns 1
# R6 [change] no ZBUILD_ARTIFACT_DIR: rc=1 and a deploy.result.unwritable event
#             (there is nowhere to write an envelope; the event is the record)
# R7 [change] an input path outside the run's state directory is refused, not read
# R8 [change] a preset _ZBUILD_DEPLOY_RELEASE_LOADED cannot swap in another
#             deploy_release_run — the real plugin is always loaded
# R9 [change] no `jq … | atomic_write` pipe in plugin.sh (SIGPIPE rule)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugin: deploy agent (kind:agent, ADR-018 P1, issues #757 #1846)"

setup_test_env "plugin-deploy"

# #1921 follow-up: reserved test identity — the QUOTED assignment form.
_ZB_ID="$(zb_test_issue)"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

export ZBUILD_RUN_ID="deploy-test-$$"
export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_ISSUE="$_ZB_ID"

PLUGIN_FILE="$REPO_ROOT/plugins/agent/deploy/plugin.sh"
_MANIFEST="$REPO_ROOT/plugins/agent/deploy/manifest.yaml"

# Source the deploy agent plugin
# shellcheck source=../../../../plugins/agent/deploy/plugin.sh
source "$PLUGIN_FILE"

# Source manifest-router-budget.sh for manifest_router_knob (SPEC-15)
# shellcheck source=../../../../core/plugin-registry/manifest-router-budget.sh
source "$REPO_ROOT/core/plugin-registry/manifest-router-budget.sh"

# ─── Mocks ───────────────────────────────────────────────────────────────────

emit_event() { return 0; }

apply_scope_redaction() {
    local _in="$1" _out="$2"
    cp "$_in" "$_out"
    return 0
}

# ─── Helper: make a minimal state dir and set v2 dispatch env vars ────────────
# Sets ZBUILD_STAGE_INPUTS (the engine's input index with pr_url and
# gate_aggregator_result) and ZBUILD_ARTIFACT_DIR. Called in THIS shell
# (not a subshell) so the exports reach the calling test.
_make_state() {
    local dir="$1"
    mkdir -p "$dir/artifacts" "$dir/stage-inputs"
    jq -n --arg iss "$_ZB_ID" --arg run "$ZBUILD_RUN_ID" \
        '{issue:$iss, run_id:$run}' > "$dir/state.json"
    jq -n \
        --arg pr  "$dir/artifacts/pr-url.txt" \
        --arg gr  "$dir/artifacts/gate-aggregator-result.json" \
        '{"inputs":{"pr_url":$pr,"gate_aggregator_result":$gr}}' \
        > "$dir/stage-inputs/deploy.json"
    export ZBUILD_STAGE_INPUTS="$dir/stage-inputs/deploy.json"
    export ZBUILD_ARTIFACT_DIR="$dir/artifacts"
}

# ─── Helper: assert all four mandatory v2 keys are present ───────────────────
_v2_keys_ok() {
    local lbl="$1" f="$2"
    local _rc _vd _dp _rs
    # One jq for all four keys (review #2219: this helper forked four times per call).
    IFS=$'\t' read -r _rc _vd _dp _rs < <(jq -r \
        '[(.result_contract // "" | tostring), (.verdict // ""), (.disposition // ""), (.reason // "")] | @tsv' \
        "$f" 2>/dev/null || true) || true
    assert_eq "$lbl result_contract=2" "2" "$_rc"
    if [[ -n "$_vd" ]]; then
        assert_pass "$lbl verdict key present"
    else
        assert_fail "$lbl verdict key must be present" "absent"
    fi
    if [[ -n "$_dp" ]]; then
        assert_pass "$lbl disposition key present"
    else
        assert_fail "$lbl disposition key must be present" "absent"
    fi
    if [[ -n "$_rs" ]]; then
        assert_pass "$lbl reason key present and non-empty"
    else
        assert_fail "$lbl reason key must be present and non-empty" "absent or empty"
    fi
}

# ─── The outside world, faked on PATH ────────────────────────────────────────
# `git` records every call and fails on demand; nothing inside zBuild is faked.
#   FAKE_GIT_TAG_RC / FAKE_GIT_PUSH_RC — exit code for `git tag <name>` / `git push`
#   FAKE_GIT_PUSH_SIGNAL=1 — `git push` sends SIGTERM to the stage's shell first,
#   as an engine stopping the stage mid-release would.
FAKE_BIN="$TEST_TEMP_DIR/fake-bin"; mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/git" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_GIT_LOG"
case "${1:-}" in
    tag)  if [[ "${2:-}" == "-d" ]]; then exit 0; fi; exit "${FAKE_GIT_TAG_RC:-0}" ;;
    push) if [[ "${FAKE_GIT_PUSH_SIGNAL:-0}" == "1" ]]; then kill -TERM "$PPID"; exit 143; fi
          exit "${FAKE_GIT_PUSH_RC:-0}" ;;
esac
exit 0
FAKE
printf '#!/usr/bin/env bash\nprintf "gh %%s\\n" "$*" >> "$FAKE_GIT_LOG"\n' > "$FAKE_BIN/gh"
chmod +x "$FAKE_BIN/git" "$FAKE_BIN/gh"

# _deploy_case <dir> <gate verdict|-> [VAR=value ...] — one deploy run in a
# SUBSHELL (nothing it exports reaches the next case), pr-url and gate result
# seeded; prints the rc. The fake git logs to <dir>/git.log.
_deploy_case() {
    local dir="$1" gate="$2"; shift 2
    (
        _make_state "$dir"
        printf 'https://github.com/test/repo/pull/42\n' > "$dir/artifacts/pr-url.txt"
        [[ "$gate" == "-" ]] || printf '{"verdict":"%s"}\n' "$gate" > "$dir/artifacts/gate-aggregator-result.json"
        export PATH="$FAKE_BIN:$PATH" FAKE_GIT_LOG="$dir/git.log" ZBUILD_DRY_RUN=0
        local kv; for kv in "$@"; do export "${kv?}"; done
        : > "$FAKE_GIT_LOG"
        deploy_agent_run "deploy" "$dir/state.json"
    ) >/dev/null 2>&1
    printf '%s' "$?"
}
_rj() { jq -r "$2 // empty" "$1/artifacts/deploy-result.json" 2>/dev/null || true; }

# ===========================================================================
# Guard assertions — static checks on the plugin and manifest files
# ===========================================================================

# ---------------------------------------------------------------------------
# SPEC-1 [#1846/SPEC-1]: deploy plugin.sh exists and deploy_agent_run is
#                        defined after source
# ---------------------------------------------------------------------------
if [[ -f "$PLUGIN_FILE" ]]; then
    assert_pass "[#1846/SPEC-1] deploy plugin.sh exists at expected path"
else
    assert_fail "[#1846/SPEC-1] deploy plugin.sh exists at expected path" \
        "not found: $PLUGIN_FILE"
fi

if type deploy_agent_run >/dev/null 2>&1; then
    assert_pass "[#1846/SPEC-1] deploy_agent_run function defined after source"
else
    assert_fail "[#1846/SPEC-1] deploy_agent_run function defined after source" \
        "function not found"
fi

# ---------------------------------------------------------------------------
# SPEC-5 [#1846/SPEC-5]: plugin.sh has "Role: deploy_agent" preamble comment
# ---------------------------------------------------------------------------
_s5_preamble="$(head -20 "$PLUGIN_FILE" 2>/dev/null || true)"
if grep -qE '^[[:space:]]*#[[:space:]]*Role:[[:space:]]*deploy_agent' <<< "$_s5_preamble"; then
    assert_pass "[#1846/SPEC-5] deploy plugin.sh has '# Role: deploy_agent' as a comment in preamble (first 20 lines)"
else
    assert_fail "[#1846/SPEC-5] deploy plugin.sh must have '# Role: deploy_agent' as a comment line in preamble" \
        "not found as comment line in first 20 lines of $PLUGIN_FILE"
fi

# ---------------------------------------------------------------------------
# SPEC-6 [#1846/SPEC-6]: no route_to_model call in non-comment code
# ---------------------------------------------------------------------------
_code6="$(grep -v '^[[:space:]]*#' "$PLUGIN_FILE" || true)"
if grep -q "route_to_model" <<< "$_code6"; then
    assert_fail "[#1846/SPEC-6] deploy plugin must not call route_to_model in non-comment code" \
        "route_to_model found in executable code in $PLUGIN_FILE"
else
    assert_pass "[#1846/SPEC-6] deploy plugin has no route_to_model call in non-comment code"
fi

# ---------------------------------------------------------------------------
# SPEC-9 [#1846/SPEC-9]: manifest provides block declares result_contract: 2
# ---------------------------------------------------------------------------
_s9_provides="$(awk '/^provides:/{f=1;next} f && /^[^[:space:]]/{exit} f{print}' \
    "$_MANIFEST" 2>/dev/null || true)"
if grep -q 'result_contract:.*2' <<< "$_s9_provides"; then
    assert_pass "[#1846/SPEC-9] manifest provides block declares result_contract: 2"
else
    assert_fail "[#1846/SPEC-9] manifest provides block must declare result_contract: 2" \
        "${_s9_provides:-absent}"
fi

# ---------------------------------------------------------------------------
# SPEC-11 [#1846/SPEC-11]: plugin.sh derives output path from ZBUILD_ARTIFACT_DIR;
#                          no state_file-derived path (no state_dir/artifacts pattern)
# ---------------------------------------------------------------------------
if grep -qE 'state_dir[/"]*/artifacts|dirname.*state_file.*/artifacts' "$PLUGIN_FILE"; then
    assert_fail "[#1846/SPEC-11] plugin.sh must not derive output path from state_file/state_dir" \
        "state_file-derived artifact path found in $PLUGIN_FILE"
else
    assert_pass "[#1846/SPEC-11] plugin.sh has no state_file-derived artifact path"
fi

if grep -q 'ZBUILD_ARTIFACT_DIR' "$PLUGIN_FILE"; then
    assert_pass "[#1846/SPEC-11] plugin.sh references ZBUILD_ARTIFACT_DIR for output path"
else
    assert_fail "[#1846/SPEC-11] plugin.sh must reference ZBUILD_ARTIFACT_DIR for output path" \
        "ZBUILD_ARTIFACT_DIR not found in $PLUGIN_FILE"
fi

# ---------------------------------------------------------------------------
# SPEC-12 [#1846/SPEC-12]: pr_url and gate_aggregator_result resolved via
#                          ZBUILD_STAGE_INPUTS; plugin.sh constructs no
#                          pr-url.txt or gate-aggregator-result.json path
# ---------------------------------------------------------------------------
if grep -qE "pr-url\.txt|gate-aggregator-result\.json" "$PLUGIN_FILE"; then
    assert_fail "[#1846/SPEC-12] plugin.sh must not hardcode pr-url.txt or gate-aggregator-result.json paths" \
        "hardcoded input filename found in $PLUGIN_FILE"
else
    assert_pass "[#1846/SPEC-12] plugin.sh has no hardcoded pr-url.txt or gate-aggregator-result.json path"
fi

if grep -q 'ZBUILD_STAGE_INPUTS' "$PLUGIN_FILE"; then
    assert_pass "[#1846/SPEC-12] plugin.sh references ZBUILD_STAGE_INPUTS for input resolution"
else
    assert_fail "[#1846/SPEC-12] plugin.sh must reference ZBUILD_STAGE_INPUTS for input resolution" \
        "ZBUILD_STAGE_INPUTS not found in $PLUGIN_FILE"
fi

# ---------------------------------------------------------------------------
# SPEC-13 [#1846/SPEC-13]: static check — no non-comment code exits with rc>=2
# ---------------------------------------------------------------------------
_s13_nc="$(grep -v '^[[:space:]]*#' "$PLUGIN_FILE" 2>/dev/null || true)"
_s13_high="$(grep -E '\b(exit|return)[[:space:]]+[2-9]' <<< "$_s13_nc" 2>/dev/null || true)"
if [[ -z "$_s13_high" ]]; then
    assert_pass "[#1846/SPEC-13] plugin.sh has no non-comment exit/return with rc>=2"
else
    assert_fail "[#1846/SPEC-13] plugin.sh must not exit/return with rc>=2 on any code path" \
        "$_s13_high"
fi

# ---------------------------------------------------------------------------
# SPEC-15 [#1846/SPEC-15]: manifest has no config.router block;
#                          manifest_router_knob returns empty for timeout_s
#                          and max_turns
# ---------------------------------------------------------------------------
_s15_timeout="$(manifest_router_knob "$_MANIFEST" timeout_s)"
_s15_maxturns="$(manifest_router_knob "$_MANIFEST" max_turns)"
assert_eq "[#1846/SPEC-15] manifest_router_knob timeout_s returns empty (no config.router)" \
    "" "$_s15_timeout"
assert_eq "[#1846/SPEC-15] manifest_router_knob max_turns returns empty (no config.router)" \
    "" "$_s15_maxturns"

# ---------------------------------------------------------------------------
# SPEC-16 [#1846/SPEC-16]: manifest outputs.deploy_result retains primary: true
# ---------------------------------------------------------------------------
_s16_stanza="$(awk \
    '/id: deploy_result/{f=1} f{print} f && /^[[:space:]]*-[[:space:]]*id:/ && !/deploy_result/{exit}' \
    "$_MANIFEST" 2>/dev/null || true)"
if grep -q 'primary: true' <<< "$_s16_stanza"; then
    assert_pass "[#1846/SPEC-16] manifest outputs.deploy_result declares primary: true"
else
    assert_fail "[#1846/SPEC-16] manifest outputs.deploy_result must declare primary: true" \
        "${_s16_stanza:-absent}"
fi

# ---------------------------------------------------------------------------
# SPEC-17 [#1846/SPEC-17]: manifest provides.role = deploy_agent;
#                          provides.events = exactly the declared events
#                          (six since review #2219: deploy.input.refused (R7) and
#                          deploy.result.unwritable (R6) joined the original four)
# ---------------------------------------------------------------------------
_s17_provides="$(awk '/^provides:/{f=1;next} f && /^[^[:space:]]/{exit} f{print}' \
    "$_MANIFEST" 2>/dev/null || true)"
if grep -q 'role:[[:space:]]*deploy_agent' <<< "$_s17_provides"; then
    assert_pass "[#1846/SPEC-17] manifest provides.role = deploy_agent"
else
    assert_fail "[#1846/SPEC-17] manifest provides.role must be deploy_agent" \
        "${_s17_provides:-absent}"
fi

_s17_events="$(awk \
    '/events:/{f=1;next} f && /^[[:space:]]*-/{print;next} f && /^[^[:space:]-]/{exit}' \
    "$_MANIFEST" 2>/dev/null || true)"
for _ev in "deploy.gate.missing" "deploy.input.missing" "deploy.input.refused" "deploy.result.unwritable" "deploy.skipped" "deploy.tool.failed"; do
    if grep -q "$_ev" <<< "$_s17_events"; then
        assert_pass "[#1846/SPEC-17] manifest provides.events includes $_ev"
    else
        assert_fail "[#1846/SPEC-17] manifest provides.events must include $_ev" \
            "${_s17_events:-absent}"
    fi
done
_s17_count="$(grep -c '^[[:space:]]*-' <<< "$_s17_events" 2>/dev/null || true)"
assert_eq "[#1846/SPEC-17] manifest provides.events declares exactly 6 events" "6" "$_s17_count"

# ---------------------------------------------------------------------------
# SPEC-18 [#1846/SPEC-18]: manifest hooks block declares only run; no cleanup
# ---------------------------------------------------------------------------
_s18_hooks="$(awk '/^hooks:/{f=1;next} f && /^[^[:space:]]/{exit} f{print}' \
    "$_MANIFEST" 2>/dev/null || true)"
if grep -qE 'run:[[:space:]]*deploy_agent_run' <<< "$_s18_hooks"; then
    assert_pass "[#1846/SPEC-18] manifest hooks block declares run: deploy_agent_run"
else
    assert_fail "[#1846/SPEC-18] manifest hooks block must declare run: deploy_agent_run" \
        "${_s18_hooks:-absent}"
fi
if grep -q 'cleanup:' <<< "$_s18_hooks"; then
    assert_fail "[#1846/SPEC-18] manifest hooks block must not declare cleanup hook" \
        "cleanup entry found"
else
    assert_pass "[#1846/SPEC-18] manifest hooks block has no cleanup hook"
fi
_s18_count="$(grep -cE '^[[:space:]]+[a-z_]+:' <<< "$_s18_hooks" 2>/dev/null || printf '0')"
assert_eq "[#1846/SPEC-18] manifest hooks block declares exactly one hook (run only)" "1" "$_s18_count"

# ---------------------------------------------------------------------------
# SPEC-22 [#1846/SPEC-22]: manifest config.valid_verdicts lists exactly
#                          deployed, error, skipped
# ---------------------------------------------------------------------------
_s22_section="$(awk '/valid_verdicts:/{f=1;next} f && /^[[:space:]]*-/{print;next} f{exit}' \
    "$_MANIFEST" 2>/dev/null || true)"
for _vv in "deployed" "error" "skipped"; do
    if grep -q "$_vv" <<< "$_s22_section"; then
        assert_pass "[#1846/SPEC-22] manifest config.valid_verdicts includes $_vv"
    else
        assert_fail "[#1846/SPEC-22] manifest config.valid_verdicts must include $_vv" \
            "${_s22_section:-absent}"
    fi
done
_s22_count="$(grep -c '^[[:space:]]*-' <<< "$_s22_section" 2>/dev/null || printf '0')"
assert_eq "[#1846/SPEC-22] manifest config.valid_verdicts declares exactly 3 verdicts" "3" "$_s22_count"

# ---------------------------------------------------------------------------
# SPEC-24 [#1846/SPEC-24]: manifest carries router-budget-absence comment
#                          with "router budgets: none" and ADR-037 §3
# ---------------------------------------------------------------------------
_s24_ctx="$(grep -B2 -A3 'router budgets: none' "$_MANIFEST" 2>/dev/null || true)"
if [[ -n "$_s24_ctx" ]]; then
    assert_pass "[#1846/SPEC-24] manifest carries 'router budgets: none' comment"
else
    assert_fail "[#1846/SPEC-24] manifest must carry 'router budgets: none' comment" \
        "not found in $_MANIFEST"
fi
if grep -q 'ADR-037' <<< "$_s24_ctx" && grep -q '§3' <<< "$_s24_ctx"; then
    assert_pass "[#1846/SPEC-24] manifest router-budget comment has 'ADR-037 §3' near 'router budgets: none'"
else
    assert_fail "[#1846/SPEC-24] manifest comment near 'router budgets: none' must reference both ADR-037 and §3" \
        "${_s24_ctx:-absent}"
fi

# ===========================================================================
# Behavioural assertions — dynamic tests via ZBUILD_STAGE_INPUTS dispatch
# ===========================================================================

# ---------------------------------------------------------------------------
# SPEC-2/7/19 [#1846/SPEC-2,7,19]: ZBUILD_DRY_RUN=1 writes deploy-result.json
#             with verdict=deployed, result_contract=2, disposition=complete,
#             reason present (full v2 envelope)
# ---------------------------------------------------------------------------
_run_dry="$TEST_TEMP_DIR/run_dry"
( _make_state "$_run_dry"
  printf 'https://github.com/test/repo/pull/42\n' > "$_run_dry/artifacts/pr-url.txt"
  ZBUILD_DRY_RUN=1 deploy_agent_run "deploy" "$_run_dry/state.json" ) >/dev/null 2>&1 || true
_dry_out="$_run_dry/artifacts/deploy-result.json"

_dry_v="$(jq -r '.verdict // empty' "$_dry_out" 2>/dev/null || printf MISSING)"
assert_eq "[#1846/SPEC-2] dry-run writes verdict=deployed" "deployed" "$_dry_v"

_dry_rc="$(jq -r '.result_contract // empty' "$_dry_out" 2>/dev/null || printf MISSING)"
assert_eq "[#1846/SPEC-7] dry-run deploy-result.json carries result_contract=2" "2" "$_dry_rc"

_dry_sv="$(jq -r '.schema_version // "ABSENT"' "$_dry_out" 2>/dev/null || printf MISSING)"
assert_eq "[#1846/SPEC-7] dry-run deploy-result.json must not carry schema_version key" \
    "ABSENT" "$_dry_sv"

assert_eq "[#1846/SPEC-19] dry-run carries verdict=deployed" "deployed" "$_dry_v"

_dry_dp="$(jq -r '.disposition // empty' "$_dry_out" 2>/dev/null || printf MISSING)"
assert_eq "[#1846/SPEC-19] dry-run carries disposition=complete" "complete" "$_dry_dp"

_dry_rs="$(jq -r '.reason // ""' "$_dry_out" 2>/dev/null || true)"
if [[ -n "$_dry_rs" ]]; then
    assert_pass "[#1846/SPEC-19] dry-run carries non-empty reason"
else
    assert_fail "[#1846/SPEC-19] dry-run result must have non-empty reason" "absent or empty"
fi

_v2_keys_ok "[#1846/SPEC-10] dry-run exit path:" "$_dry_out"

# ---------------------------------------------------------------------------
# SPEC-3 [#1846/SPEC-3]: missing pr_url input → rc!=0 and verdict=error
#        (ZBUILD_STAGE_INPUTS index exists but pr_url file is absent)
# ---------------------------------------------------------------------------
_run_nopr="$TEST_TEMP_DIR/run_nopr"
# Do NOT create pr-url.txt — the path in the index points to a non-existent file
_rc3=0
( _make_state "$_run_nopr"; deploy_agent_run "deploy" "$_run_nopr/state.json" ) >/dev/null 2>&1 || _rc3=$?
assert_gt "[#1846/SPEC-3] missing pr_url input → rc != 0" "$_rc3" "0"

_v3="$(jq -r '.verdict // empty' "$_run_nopr/artifacts/deploy-result.json" 2>/dev/null || printf MISSING)"
assert_eq "[#1846/SPEC-3] missing pr_url → verdict=error" "error" "$_v3"

_v2_keys_ok "[#1846/SPEC-10] missing-pr_url exit path:" \
    "$_run_nopr/artifacts/deploy-result.json"

assert_eq "[#1846/SPEC-13] missing pr_url → rc=1 (not rc=2+)" "1" "$_rc3"

# ---------------------------------------------------------------------------
# SPEC-4 [#1846/SPEC-4]: gate verdict=fail → verdict=skipped (fail-closed)
#        gate verdict=route_design (non-pass) → verdict=skipped (allowlist)
# ---------------------------------------------------------------------------
_run_gatefail="$TEST_TEMP_DIR/run_gatefail"
_deploy_case "$_run_gatefail" fail >/dev/null
_v4="$(jq -r '.verdict // empty' "$_run_gatefail/artifacts/deploy-result.json" 2>/dev/null || printf MISSING)"
assert_eq "[#1846/SPEC-4] gate verdict=fail → deploy-result verdict=skipped" "skipped" "$_v4"

_v2_keys_ok "[#1846/SPEC-10] gate-fail exit path:" \
    "$_run_gatefail/artifacts/deploy-result.json"

# Fail-closed allowlist: non-pass verdict also skips
_run_routedesign="$TEST_TEMP_DIR/run_routedesign"
_deploy_case "$_run_routedesign" route_design >/dev/null
_v4b="$(jq -r '.verdict // empty' "$_run_routedesign/artifacts/deploy-result.json" 2>/dev/null || printf MISSING)"
assert_eq "[#1846/SPEC-4] gate verdict=route_design (non-pass) → skipped (allowlist)" "skipped" "$_v4b"

# ---------------------------------------------------------------------------
# SPEC-8 [#1846/SPEC-8]: missing gate (non-dry-run) → fail-closed rc=1 (not rc=2)
#        and verdict=error
# ---------------------------------------------------------------------------
_run_nogate="$TEST_TEMP_DIR/run_nogate"
# Do NOT create gate-aggregator-result.json
_rc8="$(_deploy_case "$_run_nogate" -)"
assert_eq "[#1846/SPEC-8] missing gate (non-dry-run) → fail-closed rc=1 (not rc=2)" "1" "$_rc8"

_v8="$(jq -r '.verdict // empty' "$_run_nogate/artifacts/deploy-result.json" 2>/dev/null || printf MISSING)"
assert_eq "[#1846/SPEC-8] missing gate → verdict=error" "error" "$_v8"

_v2_keys_ok "[#1846/SPEC-10] missing-gate exit path:" \
    "$_run_nogate/artifacts/deploy-result.json"

assert_eq "[#1846/SPEC-13] missing gate → rc=1 (not rc=2+)" "1" "$_rc8"

# ---------------------------------------------------------------------------
# SPEC-20 [#1846/SPEC-20] (rewritten after review #2219): when deploy-release
#        fails, deploy-release's OWN disposition reaches the engine — deploy
#        never overwrites it. The old assertion (always `unavailable`) described
#        the overwrite itself.  R2 / R3.
# ---------------------------------------------------------------------------
_r2="$TEST_TEMP_DIR/r2-tagfail"
_rc_r2="$(_deploy_case "$_r2" pass FAKE_GIT_TAG_RC=1)"
assert_eq "[R2] a failed git tag → rc=1" "1" "$_rc_r2"
assert_eq "[R2] ...deploy-release's disposition (broken) is what the engine reads" "broken" "$(_rj "$_r2" .disposition)"
assert_eq "[R2] ...with its reason" "git tag failed" "$(_rj "$_r2" .reason)"
_v2_keys_ok "[#1846/SPEC-10] tag-fail exit path:" "$_r2/artifacts/deploy-result.json"

_r3="$TEST_TEMP_DIR/r3-pushfail"
_rc_r3="$(_deploy_case "$_r3" pass FAKE_GIT_PUSH_RC=1)"
assert_eq "[R3] a failed git push → rc=1" "1" "$_rc_r3"
assert_eq "[#1846/SPEC-20] a failed push keeps deploy-release's disposition (unavailable)" "unavailable" "$(_rj "$_r3" .disposition)"
assert_eq "[R3] ...with its reason" "git push tag failed" "$(_rj "$_r3" .reason)"
assert_contains "[R3] ...and the local tag is rolled back" "$(cat "$_r3/git.log" 2>/dev/null)" "tag -d zbuild-run-"
_v2_keys_ok "[#1846/SPEC-10] push-fail exit path:" "$_r3/artifacts/deploy-result.json"

# ---------------------------------------------------------------------------
# SPEC-21 [#1846/SPEC-21]: deploy-release plugin file absent →
#                          deploy-result.json disposition=broken
# ---------------------------------------------------------------------------
_run_drabsent="$TEST_TEMP_DIR/run_drabsent"
mkdir -p "$TEST_TEMP_DIR/no-deploy-release"
_rc21="$(_deploy_case "$_run_drabsent" pass _DEPLOY_ROOT="$TEST_TEMP_DIR/no-deploy-release")"

_dp21="$(jq -r '.disposition // empty' "$_run_drabsent/artifacts/deploy-result.json" 2>/dev/null || printf MISSING)"
assert_eq "[#1846/SPEC-21] deploy-release absent → disposition=broken" \
    "broken" "$_dp21"

_v2_keys_ok "[#1846/SPEC-10] deploy-release-absent exit path:" \
    "$_run_drabsent/artifacts/deploy-result.json"

assert_eq "[#1846/SPEC-13] deploy-release absent → rc=1" "1" "$_rc21"

# ---------------------------------------------------------------------------
# SPEC-2 (delegation) / SPEC-10 (success path) — R1: through the REAL
#        deploy-release; only git is faked.
# ---------------------------------------------------------------------------
_run_success="$TEST_TEMP_DIR/run_success"
_rc_r1="$(_deploy_case "$_run_success" pass ZBUILD_RUN_ID=r1-run)"
assert_eq "[R1] a passing gate deploys → rc=0" "0" "$_rc_r1"
_gl="$(cat "$_run_success/git.log" 2>/dev/null)"
assert_contains "[#1846/SPEC-2] the release tag is created" "$_gl" "tag zbuild-run-r1-run"
assert_contains "[R1] ...and pushed to origin" "$_gl" "push origin zbuild-run-r1-run"
_v2_keys_ok "[#1846/SPEC-10] successful-deploy exit path:" "$_run_success/artifacts/deploy-result.json"
_vs="$(_rj "$_run_success" .verdict)"
assert_eq "[#1846/SPEC-14] successful deploy writes verdict=deployed (v2)" "deployed" "$_vs"
assert_eq "[R1] the result names the tag deploy-release cut" "zbuild-run-r1-run" "$(_rj "$_run_success" .data.tag)"
assert_eq "[R1] ...and the PR" "https://github.com/test/repo/pull/42" "$(_rj "$_run_success" .data.pr_url)"

# R4: deploy-release's own artifacts land in ZBUILD_ARTIFACT_DIR even when the
# state file lives somewhere else.
_r4="$TEST_TEMP_DIR/r4-elsewhere"; mkdir -p "$TEST_TEMP_DIR/r4-state"
( _make_state "$_r4"
  printf 'https://github.com/test/repo/pull/42\n' > "$_r4/artifacts/pr-url.txt"
  printf '{"verdict":"pass"}\n' > "$_r4/artifacts/gate-aggregator-result.json"
  export PATH="$FAKE_BIN:$PATH" FAKE_GIT_LOG="$_r4/git.log" ZBUILD_DRY_RUN=0
  : > "$FAKE_GIT_LOG"
  printf '{}' > "$TEST_TEMP_DIR/r4-state/state.json"
  deploy_agent_run "deploy" "$TEST_TEMP_DIR/r4-state/state.json" ) >/dev/null 2>&1 || true
assert_file_exists "[R4] deploy-release's summary is in ZBUILD_ARTIFACT_DIR" "$_r4/artifacts/deploy-release-summary.md"
if [[ -e "$TEST_TEMP_DIR/r4-state/artifacts" ]]; then
    assert_fail "[R4] nothing is written beside the state file" "$TEST_TEMP_DIR/r4-state/artifacts exists"
else
    assert_pass "[R4] nothing is written beside the state file"
fi

# R5: a signal mid-release (the engine stopping the stage while git pushes).
_r5="$TEST_TEMP_DIR/r5-signal"
_rc_r5="$(_deploy_case "$_r5" pass FAKE_GIT_PUSH_SIGNAL=1)"
assert_eq "[R5] interrupted → rc=1" "1" "$_rc_r5"
assert_eq "[R5] ...disposition=interrupted" "interrupted" "$(_rj "$_r5" .disposition)"
_v2_keys_ok "[#1846/SPEC-10] interrupted exit path:" "$_r5/artifacts/deploy-result.json"

# R6: no ZBUILD_ARTIFACT_DIR — nowhere to write; the event is the record.
_r6ev="$TEST_TEMP_DIR/r6-events.jsonl"; : > "$_r6ev"
_rc_r6=0
( unset ZBUILD_ARTIFACT_DIR
  emit_event() { printf '%s\n' "$*" >> "$_r6ev"; }
  deploy_agent_run "deploy" "$TEST_TEMP_DIR/none.json" ) >/dev/null 2>&1 || _rc_r6=$?
assert_eq "[R6] no ZBUILD_ARTIFACT_DIR → rc=1" "1" "$_rc_r6"
assert_contains "[R6] ...and a deploy.result.unwritable event says why" "$(cat "$_r6ev")" "deploy.result.unwritable"

# R7: an input path outside the run's state directory is refused.
_r7="$TEST_TEMP_DIR/r7-outside"; _r7x="$TEST_TEMP_DIR/r7-elsewhere"; mkdir -p "$_r7x"
printf 'https://github.com/evil/repo/pull/1\n' > "$_r7x/pr-url.txt"
_rc_r7=0
( _make_state "$_r7"
  jq -n --arg pr "$_r7x/pr-url.txt" --arg gr "$_r7/artifacts/gate-aggregator-result.json" \
      '{"inputs":{"pr_url":$pr,"gate_aggregator_result":$gr}}' > "$_r7/stage-inputs/deploy.json"
  ZBUILD_DRY_RUN=1 deploy_agent_run "deploy" "$_r7/state.json" ) >/dev/null 2>&1 || _rc_r7=$?
assert_eq "[R7] an input outside the state directory → rc=1" "1" "$_rc_r7"
assert_eq "[R7] ...disposition=broken (an engine index pointing outside the run is a defect)" "broken" "$(_rj "$_r7" .disposition)"
if grep -qF "evil/repo" "$_r7/artifacts/deploy-result.json" 2>/dev/null; then
    assert_fail "[R7] ...and the outside file is never read" "its content reached the result"
else
    assert_pass "[R7] ...and the outside file is never read"
fi

# R7b (review #2219 round 2): an input in a directory that does not exist,
# outside the run, is refused — not waved through as "missing".
_r7b="$TEST_TEMP_DIR/r7b-nodir"; _r7bev="$TEST_TEMP_DIR/r7b-events.jsonl"; : > "$_r7bev"
_rc_r7b=0
( _make_state "$_r7b"
  emit_event() { printf '%s\n' "$*" >> "$_r7bev"; }
  jq -n --arg pr "$TEST_TEMP_DIR/no-such-dir/pr-url.txt" --arg gr "$_r7b/artifacts/gate-aggregator-result.json" \
      '{"inputs":{"pr_url":$pr,"gate_aggregator_result":$gr}}' > "$_r7b/stage-inputs/deploy.json"
  ZBUILD_DRY_RUN=1 deploy_agent_run "deploy" "$_r7b/state.json" ) >/dev/null 2>&1 || _rc_r7b=$?
assert_eq "[R7b] an unresolvable input directory outside the run → rc=1" "1" "$_rc_r7b"
assert_contains "[R7b] ...refused, not reported missing" "$(cat "$_r7bev")" "deploy.input.refused"

# R8: a preset guard variable cannot swap in another deploy_release_run.
_r8="$TEST_TEMP_DIR/r8-guard"
_rc_r8="$(_deploy_case "$_r8" pass _ZBUILD_DEPLOY_RELEASE_LOADED=1 ZBUILD_RUN_ID=r8-run)"
assert_contains "[R8] the real deploy-release still runs (git was called)" "$(cat "$_r8/git.log" 2>/dev/null)" "tag zbuild-run-r8-run"

# R9: no jq-into-atomic_write pipe.
_r9="$(grep -nE '\|[[:space:]]*atomic_write' "$PLUGIN_FILE" 2>/dev/null || true)"
_r9="$(grep -vE '^[0-9]+:[[:space:]]*#' <<< "$_r9" || true)"
if [[ -n "$_r9" ]]; then
    assert_fail "[R9] plugin.sh has no '| atomic_write' pipe" "$_r9"
else
    assert_pass "[R9] plugin.sh has no '| atomic_write' pipe"
fi

# ---------------------------------------------------------------------------
# SPEC-14 [#1846/SPEC-14]: all three verdicts exercised with v2-shaped result
#         deployed → covered above (dry-run + success path)
#         error    → covered above (missing pr_url + missing gate)
#         skipped  → covered above (gate=fail)
# Apply _v2_keys_ok to each to confirm all three are v2-shaped.
# ---------------------------------------------------------------------------
_v2_keys_ok "[#1846/SPEC-14] verdict=deployed (dry-run):" "$_dry_out"
_v2_keys_ok "[#1846/SPEC-14] verdict=error (missing pr_url):" \
    "$_run_nopr/artifacts/deploy-result.json"
_v2_keys_ok "[#1846/SPEC-14] verdict=skipped (gate=fail):" \
    "$_run_gatefail/artifacts/deploy-result.json"

_v14_d="$(jq -r '.verdict' "$_dry_out" 2>/dev/null || printf MISSING)"
_v14_e="$(jq -r '.verdict' "$_run_nopr/artifacts/deploy-result.json" 2>/dev/null || printf MISSING)"
_v14_s="$(jq -r '.verdict' "$_run_gatefail/artifacts/deploy-result.json" 2>/dev/null || printf MISSING)"
assert_eq "[#1846/SPEC-14] verdict=deployed covered" "deployed" "$_v14_d"
assert_eq "[#1846/SPEC-14] verdict=error covered" "error" "$_v14_e"
assert_eq "[#1846/SPEC-14] verdict=skipped covered" "skipped" "$_v14_s"

# ─── Cleanup ─────────────────────────────────────────────────────────────────
_test_cleanup_hook() { cleanup_test_env; }

print_test_results
exit $((FAIL > 0))
