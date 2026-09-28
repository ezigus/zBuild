#!/usr/bin/env bash
# tests/unit/deploy-release-v2-result-test.sh
# Contract v2 result assertions for the deploy-release plugin (issue #1849).
# SPEC coverage:
#   [SPEC-15] manifest provides declares result_contract:2 (role:deploy_release_executor,
#             events retained; valid_verdicts already correct and unchanged)
#   [SPEC-16] deploy-result.json carries result_contract:2, disposition, reason on every
#             exit path (dry-run, tag success, tag failure, push failure, state_file-absent)
#   [SPEC-17] all exit paths return rc ∈ {0,1} — state_file-absent returns rc=1 not rc=2
#   [SPEC-18] reads pr_url ONLY via ZBUILD_STAGE_INPUTS; plugin.sh constructs no pr-url.txt path
#   [SPEC-30] a failed tag push reports unavailable — the remote's state is unknown
#   [SPEC-32] pr_url lives under data (ADR-054 §5), not at the top level
#   [SPEC-23] deploy-result.json verdict=deployed and rc=0 on git tag+push success path
#   [SPEC-24] tier_default:T0, no router: block
#   [SPEC-25] outputs.deploy_result retains primary: true after v2 migration
#   [SPEC-27] provides retains role:deploy_release_executor and events after result_contract:2 added
#   [SPEC-28] hooks section has only run:, no cleanup:
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "deploy-release plugin: v2 result contract (issue #1849)"
setup_test_env "deploy-release-v2-result"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="/dev/null"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_RUN_ID="deploy-release-v2-test-$$"
mkdir -p "$ZBUILD_EVENTS_DIR"
: > "$ZBUILD_EVENTS_JSONL"

DR_MANIFEST="$REPO_ROOT/plugins/tool/deploy-release/manifest.yaml"

# ─── SPEC-15: manifest provides declares result_contract:2, role/events unchanged ──
print_test_section "SPEC-15: manifest provides declares result_contract:2 (role/events retained; valid_verdicts unchanged)"

_s15_prov_rc="$(awk '/^provides:/{f=1} f && /result_contract:/{print $2; exit}' "$DR_MANIFEST" || echo '')"
assert_eq "[SPEC-15] manifest provides.result_contract is 2" "2" "$_s15_prov_rc"

# role:deploy_release_executor must be retained after adding result_contract:2
_s15_prov_role="$(awk '/^provides:/{f=1} f && /^[[:space:]]*role:/{print $2; exit}' "$DR_MANIFEST" || echo '')"
assert_eq "[SPEC-15] manifest provides.role is deploy_release_executor" "deploy_release_executor" "$_s15_prov_role"

# valid_verdicts must remain [deployed, error] — do not change them
_vv_deployed="$(grep -v '^#' "$DR_MANIFEST" | grep -c '^[[:space:]]*- deployed$' || true)"
_vv_error="$(grep -v '^#' "$DR_MANIFEST" | grep -c '^[[:space:]]*- error$' || true)"
[[ "$_vv_deployed" -gt 0 ]] \
    && assert_pass "[SPEC-15] valid_verdicts retains deployed" \
    || assert_fail "[SPEC-15] valid_verdicts retains deployed" "missing"
[[ "$_vv_error" -gt 0 ]] \
    && assert_pass "[SPEC-15] valid_verdicts retains error" \
    || assert_fail "[SPEC-15] valid_verdicts retains error" "missing"

# ─── SPEC-24: tier_default:T0, no router: block ──────────────────────────────
print_test_section "SPEC-24: tier_default:T0 with no router: block"

_td="$(grep -m1 'tier_default:' "$DR_MANIFEST" | awk '{print $2}' || echo '')"
assert_eq "[SPEC-24] manifest tier_default is T0" "T0" "$_td"

_has_router="$(grep -v '^#' "$DR_MANIFEST" | grep -c '^[[:space:]]*router:' || true)"
assert_eq "[SPEC-24] manifest has no router: block" "0" "$_has_router"

# ─── SPEC-25: outputs.deploy_result retains primary: true ────────────────────
print_test_section "SPEC-25: outputs.deploy_result retains primary: true"

_has_primary="$(grep -v '^#' "$DR_MANIFEST" | grep -c 'primary:[[:space:]]*true' || true)"
[[ "$_has_primary" -gt 0 ]] \
    && assert_pass "[SPEC-25] manifest has primary: true on deploy_result output" \
    || assert_fail "[SPEC-25] manifest has primary: true on deploy_result output" "missing"

# ─── SPEC-27: provides retains role and events after result_contract:2 added ─
print_test_section "SPEC-27: provides retains role:deploy_release_executor and events after result_contract:2"

_s27_role="$(awk '/^provides:/{f=1} f && /^[[:space:]]*role:/{print $2; exit}' "$DR_MANIFEST" || echo '')"
assert_eq "[SPEC-27] provides.role is deploy_release_executor" "deploy_release_executor" "$_s27_role"

_ev_complete="$(awk '/^provides:/{f=1} f && /deploy\.release\.complete/{print; exit}' "$DR_MANIFEST" || echo '')"
[[ -n "$_ev_complete" ]] \
    && assert_pass "[SPEC-27] provides.events includes deploy.release.complete" \
    || assert_fail "[SPEC-27] provides.events includes deploy.release.complete" "absent"

_ev_dry_run="$(awk '/^provides:/{f=1} f && /deploy\.release\.dry_run/{print; exit}' "$DR_MANIFEST" || echo '')"
[[ -n "$_ev_dry_run" ]] \
    && assert_pass "[SPEC-27] provides.events includes deploy.release.dry_run" \
    || assert_fail "[SPEC-27] provides.events includes deploy.release.dry_run" "absent"

_ev_published="$(awk '/^provides:/{f=1} f && /release\.published/{print; exit}' "$DR_MANIFEST" || echo '')"
[[ -n "$_ev_published" ]] \
    && assert_pass "[SPEC-27] provides.events includes release.published" \
    || assert_fail "[SPEC-27] provides.events includes release.published" "absent"

_ev_tagged="$(awk '/^provides:/{f=1} f && /release\.tagged/{print; exit}' "$DR_MANIFEST" || echo '')"
[[ -n "$_ev_tagged" ]] \
    && assert_pass "[SPEC-27] provides.events includes release.tagged" \
    || assert_fail "[SPEC-27] provides.events includes release.tagged" "absent"

# ─── SPEC-28: hooks has only run:, no cleanup: ───────────────────────────────
print_test_section "SPEC-28: hooks section has only run:, no cleanup:"

_has_cleanup="$(grep -v '^#' "$DR_MANIFEST" | grep -c '^[[:space:]]*cleanup:' || true)"
assert_eq "[SPEC-28] manifest hooks has no cleanup:" "0" "$_has_cleanup"

_has_run="$(grep -v '^#' "$DR_MANIFEST" | grep -c '^[[:space:]]*run:[[:space:]]*deploy_release_run' || true)"
[[ "$_has_run" -gt 0 ]] \
    && assert_pass "[SPEC-28] manifest hooks has run: deploy_release_run" \
    || assert_fail "[SPEC-28] manifest hooks has run: deploy_release_run" "missing"

# ─── Plugin behavior setup ────────────────────────────────────────────────────
# shellcheck source=../../plugins/tool/deploy-release/plugin.sh
source "$REPO_ROOT/plugins/tool/deploy-release/plugin.sh"

# _make_dr_state <dir> [pr_url]
# Sets up a state dir with pipeline-state.json and optional pr-url.txt.
_make_dr_state() {
    local d="$1" pr_url="${2:-}"
    mkdir -p "$d/artifacts"
    printf '{"issue":1849,"branch":"zbuild/issue-1849-test"}\n' > "$d/pipeline-state.json"
    [[ -n "$pr_url" ]] && printf '%s\n' "$pr_url" > "$d/artifacts/pr-url.txt"
    printf '%s/pipeline-state.json' "$d"
}

# _mk_dr_mocks <bindir> [tag_rc] [push_rc]
# Creates mock git executable. tag_rc/push_rc control git tag / git push exit codes.
_mk_dr_mocks() {
    local bin="$1" tag_rc="${2:-0}" push_rc="${3:-0}"
    mkdir -p "$bin"
    cat > "$bin/git" <<GITMOCK
#!/usr/bin/env bash
case "\${1:-}" in
    tag)  [[ ${tag_rc}  -ne 0 ]] && echo "tag error"  >&2; exit ${tag_rc}  ;;
    push) [[ ${push_rc} -ne 0 ]] && echo "push error" >&2; exit ${push_rc} ;;
    *)    exit 0 ;;
esac
GITMOCK
    chmod +x "$bin/git"
}

# ─── SPEC-16/SPEC-17: state_file-absent path — rc=1, not rc=2 ────────────────
print_test_section "SPEC-17 (partial) / SPEC-16: state_file-absent path — rc=1, result_contract:2 in deploy-result.json"

export ZBUILD_ARTIFACT_DIR="$TEST_TEMP_DIR/absent-art"
mkdir -p "$ZBUILD_ARTIFACT_DIR"

set +e
deploy_release_run "deploy" ""
_sfabs_rc=$?
set -e

assert_eq "[SPEC-17] state_file-absent: rc=1 (not rc=2)" "1" "$_sfabs_rc"

# v2 contract: deploy-result.json written to ZBUILD_ARTIFACT_DIR even on state_file-absent
if [[ -f "$ZBUILD_ARTIFACT_DIR/deploy-result.json" ]]; then
    assert_eq "[SPEC-16] state_file-absent: result_contract is 2" "2" \
        "$(jq -r '.result_contract // empty' "$ZBUILD_ARTIFACT_DIR/deploy-result.json" 2>/dev/null || true)"
    _sfabs_disp="$(jq -r '.disposition // empty' "$ZBUILD_ARTIFACT_DIR/deploy-result.json" 2>/dev/null || true)"
    [[ -n "$_sfabs_disp" ]] \
        && assert_pass "[SPEC-16] state_file-absent: disposition present" \
        || assert_fail "[SPEC-16] state_file-absent: disposition present" "absent"
    _sfabs_reason="$(jq -r '.reason // empty' "$ZBUILD_ARTIFACT_DIR/deploy-result.json" 2>/dev/null || true)"
    [[ -n "$_sfabs_reason" ]] \
        && assert_pass "[SPEC-16] state_file-absent: reason present" \
        || assert_fail "[SPEC-16] state_file-absent: reason present" "absent"
else
    assert_fail "[SPEC-16] state_file-absent: deploy-result.json written to ZBUILD_ARTIFACT_DIR" \
        "file missing at $ZBUILD_ARTIFACT_DIR/deploy-result.json"
fi

unset ZBUILD_ARTIFACT_DIR

# ─── review #2219: the result goes to ZBUILD_ARTIFACT_DIR, never beside the state file ─
# (Written after the change, not before it — the deploy agent's R4 test was the
# red step for this behaviour; this pins deploy-release's own half.)
print_test_section "review #2219: no ZBUILD_ARTIFACT_DIR → rc=1, nothing written beside the state file"
_s_nod_dir="$TEST_TEMP_DIR/spec-noartdir"
_s_nod_sf="$(_make_dr_state "$_s_nod_dir")"
rm -rf "$_s_nod_dir/artifacts"
set +e
( unset ZBUILD_ARTIFACT_DIR; ZBUILD_DRY_RUN=1 deploy_release_run "deploy" "$_s_nod_sf" ) >/dev/null 2>&1
_s_nod_rc=$?
set -e
assert_eq "[#2219] no ZBUILD_ARTIFACT_DIR → rc=1" "1" "$_s_nod_rc"
if [[ -e "$_s_nod_dir/artifacts" ]]; then
    assert_fail "[#2219] nothing is written beside the state file" "$_s_nod_dir/artifacts exists"
else
    assert_pass "[#2219] nothing is written beside the state file"
fi

# ─── SPEC-16 / SPEC-23: dry-run path ─────────────────────────────────────────
print_test_section "SPEC-16: dry-run path — result_contract:2, disposition, reason"

_s_dry_dir="$TEST_TEMP_DIR/spec-dry"
_s_dry_sf="$(_make_dr_state "$_s_dry_dir")"
_s_dry_art="$_s_dry_dir/artifacts"

set +e
( ZBUILD_DRY_RUN=1 ZBUILD_ARTIFACT_DIR="${_s_dry_sf%/*}/artifacts" deploy_release_run "deploy" "$_s_dry_sf" ) >/dev/null 2>&1
_s_dry_rc=$?
set -e

assert_file_exists "[SPEC-16] dry-run: deploy-result.json written" "$_s_dry_art/deploy-result.json"
if [[ -f "$_s_dry_art/deploy-result.json" ]]; then
    assert_eq "[SPEC-16] dry-run: result_contract is 2" "2" \
        "$(jq -r '.result_contract // empty' "$_s_dry_art/deploy-result.json" 2>/dev/null || true)"
    _dry_disp="$(jq -r '.disposition // empty' "$_s_dry_art/deploy-result.json" 2>/dev/null || true)"
    [[ -n "$_dry_disp" ]] \
        && assert_pass "[SPEC-16] dry-run: disposition present" \
        || assert_fail "[SPEC-16] dry-run: disposition present" "absent"
    _dry_reason="$(jq -r '.reason // empty' "$_s_dry_art/deploy-result.json" 2>/dev/null || true)"
    [[ -n "$_dry_reason" ]] \
        && assert_pass "[SPEC-16] dry-run: reason present" \
        || assert_fail "[SPEC-16] dry-run: reason present" "absent"
fi

# ─── SPEC-16 / SPEC-23: tag+push success path — verdict=deployed, rc=0 ───────
print_test_section "SPEC-16 / SPEC-23: tag+push success path — result_contract:2, verdict=deployed, rc=0"

_s_ok_dir="$TEST_TEMP_DIR/spec-ok"
_s_ok_sf="$(_make_dr_state "$_s_ok_dir")"
_s_ok_art="$_s_ok_dir/artifacts"
_mk_dr_mocks "$TEST_TEMP_DIR/bin-ok"

set +e
( ZBUILD_DRY_RUN=0 PATH="$TEST_TEMP_DIR/bin-ok:$PATH" \
  ZBUILD_ARTIFACT_DIR="${_s_ok_sf%/*}/artifacts" deploy_release_run "deploy" "$_s_ok_sf" ) >/dev/null 2>&1
_s_ok_rc=$?
set -e

assert_file_exists "[SPEC-16/23] success: deploy-result.json written" "$_s_ok_art/deploy-result.json"
if [[ -f "$_s_ok_art/deploy-result.json" ]]; then
    assert_eq "[SPEC-16] success: result_contract is 2" "2" \
        "$(jq -r '.result_contract // empty' "$_s_ok_art/deploy-result.json" 2>/dev/null || true)"
    assert_eq "[SPEC-23] success: verdict is deployed" "deployed" \
        "$(jq -r '.verdict // empty' "$_s_ok_art/deploy-result.json" 2>/dev/null || true)"
    _ok_disp="$(jq -r '.disposition // empty' "$_s_ok_art/deploy-result.json" 2>/dev/null || true)"
    [[ -n "$_ok_disp" ]] \
        && assert_pass "[SPEC-16] success: disposition present" \
        || assert_fail "[SPEC-16] success: disposition present" "absent"
    _ok_reason="$(jq -r '.reason // empty' "$_s_ok_art/deploy-result.json" 2>/dev/null || true)"
    [[ -n "$_ok_reason" ]] \
        && assert_pass "[SPEC-16] success: reason present" \
        || assert_fail "[SPEC-16] success: reason present" "absent"
fi
assert_eq "[SPEC-23] tag+push success: rc=0" "0" "$_s_ok_rc"

# ─── SPEC-16: tag failure path ───────────────────────────────────────────────
print_test_section "SPEC-16: tag failure path — result_contract:2, verdict=error, disposition, reason"

_s_tf_dir="$TEST_TEMP_DIR/spec-tagfail"
_s_tf_sf="$(_make_dr_state "$_s_tf_dir")"
_s_tf_art="$_s_tf_dir/artifacts"
_mk_dr_mocks "$TEST_TEMP_DIR/bin-tagfail" 1  # tag_rc=1

set +e
( ZBUILD_DRY_RUN=0 PATH="$TEST_TEMP_DIR/bin-tagfail:$PATH" \
  ZBUILD_ARTIFACT_DIR="${_s_tf_sf%/*}/artifacts" deploy_release_run "deploy" "$_s_tf_sf" ) >/dev/null 2>&1
_s_tf_rc=$?
set -e

assert_file_exists "[SPEC-16] tag-failure: deploy-result.json written" "$_s_tf_art/deploy-result.json"
if [[ -f "$_s_tf_art/deploy-result.json" ]]; then
    assert_eq "[SPEC-16] tag-failure: result_contract is 2" "2" \
        "$(jq -r '.result_contract // empty' "$_s_tf_art/deploy-result.json" 2>/dev/null || true)"
    assert_eq "[SPEC-16] tag-failure: verdict is error" "error" \
        "$(jq -r '.verdict // empty' "$_s_tf_art/deploy-result.json" 2>/dev/null || true)"
    _tf_disp="$(jq -r '.disposition // empty' "$_s_tf_art/deploy-result.json" 2>/dev/null || true)"
    [[ -n "$_tf_disp" ]] \
        && assert_pass "[SPEC-16] tag-failure: disposition present" \
        || assert_fail "[SPEC-16] tag-failure: disposition present" "absent"
    _tf_reason="$(jq -r '.reason // empty' "$_s_tf_art/deploy-result.json" 2>/dev/null || true)"
    [[ -n "$_tf_reason" ]] \
        && assert_pass "[SPEC-16] tag-failure: reason present" \
        || assert_fail "[SPEC-16] tag-failure: reason present" "absent"
fi

# ─── SPEC-16: push failure path ──────────────────────────────────────────────
print_test_section "SPEC-16: push failure path — result_contract:2, verdict=error, disposition, reason"

_s_pf_dir="$TEST_TEMP_DIR/spec-pushfail"
_s_pf_sf="$(_make_dr_state "$_s_pf_dir")"
_s_pf_art="$_s_pf_dir/artifacts"
_mk_dr_mocks "$TEST_TEMP_DIR/bin-pushfail" 0 1  # tag_rc=0, push_rc=1

set +e
( ZBUILD_DRY_RUN=0 PATH="$TEST_TEMP_DIR/bin-pushfail:$PATH" \
  ZBUILD_ARTIFACT_DIR="${_s_pf_sf%/*}/artifacts" deploy_release_run "deploy" "$_s_pf_sf" ) >/dev/null 2>&1
_s_pf_rc=$?
set -e

assert_file_exists "[SPEC-16] push-failure: deploy-result.json written" "$_s_pf_art/deploy-result.json"
if [[ -f "$_s_pf_art/deploy-result.json" ]]; then
    assert_eq "[SPEC-16] push-failure: result_contract is 2" "2" \
        "$(jq -r '.result_contract // empty' "$_s_pf_art/deploy-result.json" 2>/dev/null || true)"
    assert_eq "[SPEC-16] push-failure: verdict is error" "error" \
        "$(jq -r '.verdict // empty' "$_s_pf_art/deploy-result.json" 2>/dev/null || true)"
    _pf_disp="$(jq -r '.disposition // empty' "$_s_pf_art/deploy-result.json" 2>/dev/null || true)"
    [[ -n "$_pf_disp" ]] \
        && assert_pass "[SPEC-16] push-failure: disposition present" \
        || assert_fail "[SPEC-16] push-failure: disposition present" "absent"
    _pf_reason="$(jq -r '.reason // empty' "$_s_pf_art/deploy-result.json" 2>/dev/null || true)"
    [[ -n "$_pf_reason" ]] \
        && assert_pass "[SPEC-16] push-failure: reason present" \
        || assert_fail "[SPEC-16] push-failure: reason present" "absent"
fi

# ─── SPEC-17: no exit path returns rc=2 ──────────────────────────────────────
print_test_section "SPEC-17: all exit paths return rc ∈ {0,1} — no rc=2"

assert_eq "[SPEC-17] state_file-absent rc=1" "1" "$_sfabs_rc"
assert_eq "[SPEC-17] dry-run rc=0" "0" "$_s_dry_rc"
assert_eq "[SPEC-17] tag+push success rc=0" "0" "$_s_ok_rc"
assert_eq "[SPEC-17] tag-failure rc=1" "1" "$_s_tf_rc"
assert_eq "[SPEC-17] push-failure rc=1" "1" "$_s_pf_rc"

# ─── SPEC-30: outward failure is `unavailable` ────────────────────────────────
print_test_section "SPEC-30: a failed tag push reports unavailable"
assert_eq "[SPEC-30] push failure → unavailable" "unavailable" \
    "$(jq -r '.disposition // empty' "$_s_pf_art/deploy-result.json" 2>/dev/null || true)"

# ─── SPEC-18: pr_url resolved via ZBUILD_STAGE_INPUTS with artifacts_dir fallback
print_test_section "SPEC-18: pr_url resolved via ZBUILD_STAGE_INPUTS with artifacts_dir fallback"

# SPEC-18a: ZBUILD_STAGE_INPUTS maps pr_url to a file at a custom path.
# Standard artifacts_dir has NO pr-url.txt.
# If plugin honors ZBUILD_STAGE_INPUTS: deploy-result.json captures the custom pr_url.
# If hardcoded path only: pr_url stays "" (artifacts_dir has no pr-url.txt).
_s18a_dir="$TEST_TEMP_DIR/spec18a"
_s18a_sf="$(_make_dr_state "$_s18a_dir")"   # intentionally: no pr-url.txt in artifacts_dir
_s18a_art="$_s18a_dir/artifacts"

_s18a_custom="$TEST_TEMP_DIR/custom-pr-url.txt"
printf 'https://github.com/mock/repo/pull/18a\n' > "$_s18a_custom"

_s18a_si="$TEST_TEMP_DIR/spec18a-si.json"
printf '{"inputs":{"pr_url":"%s"}}\n' "$_s18a_custom" > "$_s18a_si"

_mk_dr_mocks "$TEST_TEMP_DIR/bin18a"

set +e
( ZBUILD_DRY_RUN=1 \
  ZBUILD_STAGE_INPUTS="$_s18a_si" \
  ZBUILD_ARTIFACT_DIR="${_s18a_sf%/*}/artifacts" deploy_release_run "deploy" "$_s18a_sf" ) >/dev/null 2>&1
_s18a_rc=$?
set -e

assert_file_exists "[SPEC-18] ZBUILD_STAGE_INPUTS: deploy-result.json written" "$_s18a_art/deploy-result.json"
if [[ -f "$_s18a_art/deploy-result.json" ]]; then
    _s18a_pr_url="$(jq -r '.data.pr_url // empty' "$_s18a_art/deploy-result.json" 2>/dev/null || true)"
    if [[ "$_s18a_pr_url" == "https://github.com/mock/repo/pull/18a" ]]; then
        assert_pass "[SPEC-18] ZBUILD_STAGE_INPUTS: pr_url from custom path in deploy-result.json"
    else
        assert_fail "[SPEC-18] ZBUILD_STAGE_INPUTS: pr_url from custom path in deploy-result.json" \
            "got pr_url='$_s18a_pr_url' — ZBUILD_STAGE_INPUTS not honoured for pr_url"
    fi
fi

# SPEC-18b: no index entry → no pr_url, even with a pr-url.txt in artifacts_dir.
# The engine exports ZBUILD_STAGE_INPUTS for every dispatched stage (lifecycle.sh),
# including the deploy agent that calls this plugin.
_s18b_dir="$TEST_TEMP_DIR/spec18b"
_s18b_sf="$(_make_dr_state "$_s18b_dir" "https://github.com/mock/repo/pull/18b")"
_s18b_art="$_s18b_dir/artifacts"
printf '{"inputs":{}}\n' > "$_s18b_dir/stage-inputs.json"

_mk_dr_mocks "$TEST_TEMP_DIR/bin18b"

set +e
( ZBUILD_DRY_RUN=1 \
  ZBUILD_STAGE_INPUTS="$_s18b_dir/stage-inputs.json" \
  ZBUILD_ARTIFACT_DIR="${_s18b_sf%/*}/artifacts" deploy_release_run "deploy" "$_s18b_sf" ) >/dev/null 2>&1
_s18b_rc=$?
set -e

assert_eq "[SPEC-18] no index entry: a pr-url.txt on disk is not read" "" \
    "$(jq -r '.data.pr_url // empty' "$_s18b_art/deploy-result.json" 2>/dev/null || true)"
assert_eq "[SPEC-18] plugin.sh constructs no pr-url.txt path" "0" \
    "$(grep -v '^[[:space:]]*#' "$REPO_ROOT/plugins/tool/deploy-release/plugin.sh" | grep -cF 'pr-url.txt' || true)"

# ─── SPEC-32: plugin-specific fields live under data ──────────────────────────
print_test_section "SPEC-32: pr_url is under data, not at the top level"
assert_eq "[SPEC-32] dry-run: no top-level pr_url" "null" \
    "$(jq -c '.pr_url' "$_s18a_art/deploy-result.json" 2>/dev/null || true)"
assert_eq "[SPEC-32] success path: no top-level pr_url" "null" \
    "$(jq -c '.pr_url' "$_s_ok_art/deploy-result.json" 2>/dev/null || true)"

# ─── Teardown ─────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
exit $((FAIL > 0))
