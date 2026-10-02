#!/usr/bin/env bash
# tests/unit/pr-delivery-v2-result-test.sh
# Contract v2 result assertions for the pr-delivery plugin (issue #1844).
# SPEC coverage:
#   [#1844/SPEC-1]  manifest provides.result_contract is 2
#   [#1844/SPEC-2]  manifest config.valid_verdicts is [pass, error]
#   [#1844/SPEC-3]  manifest provides.events declares pr.delivery.blocked, pr.delivery.opened, pr.delivery.dry_run
#   [#1844/SPEC-4]  block guard exit path writes pr-result.json: result_contract:2, verdict=error, disposition, reason
#   [#1844/SPEC-5]  dry-run exit path writes pr-result.json: result_contract:2, verdict=pass, disposition, reason
#   [#1844/SPEC-6]  merge-delegation FAIL writes pr-result.json: result_contract:2, verdict=error, disposition, reason
#   [#1844/SPEC-7]  pr-open FAIL path has pr-result.json: result_contract:2, verdict=error (guard — pr-open writes it)
#   [#1844/SPEC-8]  fallback-gh-fail writes pr-result.json: result_contract:2, verdict=error, disposition=unavailable
#   [#1844/SPEC-9]  missing-state-file path returns rc=1 (not rc=2)
#   [#1844/SPEC-10] plugin.sh resolves gate_aggregator_result and review_report via ZBUILD_STAGE_INPUTS only
#   [#1844/SPEC-11] provides.role remains pr
#   [#1844/SPEC-12] outputs.pr_url retains primary: true
#   [#1844/SPEC-13] hooks has run: pr_stage_run and no cleanup:
#   [#1844/SPEC-14] pr-open SUCCESS path has pr-result.json: result_contract:2, verdict=pass (guard)
#   [#1844/SPEC-15] merge SUCCESS path has pr-result.json: result_contract:2, verdict=pass (guard)
#   [#1844/SPEC-16] fallback-gh SUCCESS writes pr-result.json: result_contract:2, verdict=pass, disposition=complete, reason
#   [#1844/SPEC-17] SIGTERM/SIGINT trap writes pr-result.json: result_contract:2, verdict=error, disposition=interrupted; rc=1
#   [#1844/SPEC-18] manifest has no router: block
#   [#1844/SPEC-19] dry-run v2 pr-result.json carries .data.branch and .data.draft
#   [#1844/SPEC-20] manifest inputs section declares only id and required: on each entry
#   [#1844/SPEC-21] fallback-gh SUCCESS v2 pr-result.json carries .data.branch, .data.pr_url, .data.draft
#   [#1844/SPEC-22] pr-open rc=0 but verdict≠pass → pr-result.json: verdict=error, disposition=complete, reason=review_signal_missing; rc=1
#   [#1844/SPEC-23] pr-open rc=0 but verdict≠pass → summary states no PR opened and names review_signal_missing
#   [#1844/SPEC-24] missing-state-file writes pr-result.json: result_contract:2, verdict=error, disposition, reason
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "pr-delivery plugin: v2 result contract (issue #1844)"
setup_test_env "pr-delivery-v2-result"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="/dev/null"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_RUN_ID="pr-delivery-v2-result-test-$$"
mkdir -p "$ZBUILD_EVENTS_DIR"
: > "$ZBUILD_EVENTS_JSONL"

PR_MANIFEST="$REPO_ROOT/plugins/agent/pr-delivery/manifest.yaml"

# ─── SPEC-1: manifest provides.result_contract is 2 ─────────────────────────
print_test_section "#1844/SPEC-1: manifest provides.result_contract is 2"

_s1_rc="$(awk '/^provides:/{f=1} f && /result_contract:/{print $2; exit}' "$PR_MANIFEST" || echo '')"
assert_eq "[#1844/SPEC-1] manifest provides.result_contract is 2" "2" "$_s1_rc"

# ─── SPEC-2: valid_verdicts is [pass, error] — not the empty list ─────────────
print_test_section "#1844/SPEC-2: manifest config.valid_verdicts is [pass, error]"

_vv_pass="$(grep -v '^#' "$PR_MANIFEST" | grep -c '^[[:space:]]*- pass$' || true)"
_vv_error="$(grep -v '^#' "$PR_MANIFEST" | grep -c '^[[:space:]]*- error$' || true)"
[[ "$_vv_pass" -gt 0 ]] \
    && assert_pass "[#1844/SPEC-2] valid_verdicts includes pass" \
    || assert_fail "[#1844/SPEC-2] valid_verdicts includes pass" "missing from $PR_MANIFEST"
[[ "$_vv_error" -gt 0 ]] \
    && assert_pass "[#1844/SPEC-2] valid_verdicts includes error" \
    || assert_fail "[#1844/SPEC-2] valid_verdicts includes error" "missing from $PR_MANIFEST"

# The old empty list [] must not appear — a non-empty valid_verdicts is the
# contract claim (#1708). Check that the list has at least two entries (pass + error)
# and that an explicit "[]" is gone.
_vv_empty="$(grep -v '^[[:space:]]*#' "$PR_MANIFEST" | grep -c 'valid_verdicts:[[:space:]]*\[\]' || true)"
assert_eq "[#1844/SPEC-2] valid_verdicts is not the empty list []" "0" "$_vv_empty"

# The list must be exactly [pass, error]: count all entries, must be exactly 2.
_vv_total="$(awk '
    /^[[:space:]]*valid_verdicts:/{f=1; next}
    f && /^[[:space:]]*#/{next}
    f && /^[[:space:]]*-[[:space:]]/{c++}
    f && /^[[:space:]]*[^-[:space:]#]/{f=0}
    END{print c+0}
' "$PR_MANIFEST")"
assert_eq "[#1844/SPEC-2] valid_verdicts has exactly 2 entries (pass and error, no others)" "2" "$_vv_total"

# ─── SPEC-3: provides.events declares all three delivery events ───────────────
print_test_section "#1844/SPEC-3: manifest provides.events declares pr.delivery.{blocked,opened,dry_run}"

_ev_blocked="$(awk '/^provides:/{f=1} f && /pr\.delivery\.blocked/{print; exit}' "$PR_MANIFEST" || echo '')"
[[ -n "$_ev_blocked" ]] \
    && assert_pass "[#1844/SPEC-3] provides.events includes pr.delivery.blocked" \
    || assert_fail "[#1844/SPEC-3] provides.events includes pr.delivery.blocked" "absent from $PR_MANIFEST"

_ev_opened="$(awk '/^provides:/{f=1} f && /pr\.delivery\.opened/{print; exit}' "$PR_MANIFEST" || echo '')"
[[ -n "$_ev_opened" ]] \
    && assert_pass "[#1844/SPEC-3] provides.events includes pr.delivery.opened" \
    || assert_fail "[#1844/SPEC-3] provides.events includes pr.delivery.opened" "absent from $PR_MANIFEST"

_ev_dry_run="$(awk '/^provides:/{f=1} f && /pr\.delivery\.dry_run/{print; exit}' "$PR_MANIFEST" || echo '')"
[[ -n "$_ev_dry_run" ]] \
    && assert_pass "[#1844/SPEC-3] provides.events includes pr.delivery.dry_run" \
    || assert_fail "[#1844/SPEC-3] provides.events includes pr.delivery.dry_run" "absent from $PR_MANIFEST"

# ─── SPEC-11: provides.role remains pr ───────────────────────────────────────
print_test_section "#1844/SPEC-11: manifest provides.role remains pr"

_role="$(awk '/^provides:/{f=1} f && /^[[:space:]]*role:/{print $2; exit}' "$PR_MANIFEST" || echo '')"
assert_eq "[#1844/SPEC-11] manifest provides.role is pr" "pr" "$_role"

# ─── SPEC-12: outputs.pr_url retains primary: true ────────────────────────────
print_test_section "#1844/SPEC-12: outputs.pr_url retains primary: true"

_has_primary="$(grep -v '^#' "$PR_MANIFEST" | grep -c 'primary:[[:space:]]*true' || true)"
[[ "$_has_primary" -gt 0 ]] \
    && assert_pass "[#1844/SPEC-12] manifest has primary: true on pr_url output" \
    || assert_fail "[#1844/SPEC-12] manifest has primary: true on pr_url output" "missing"

# ─── SPEC-13: hooks has run: pr_stage_run and no cleanup: ─────────────────────
print_test_section "#1844/SPEC-13: hooks has run: pr_stage_run and no cleanup:"

_has_run="$(grep -v '^#' "$PR_MANIFEST" | grep -c '^[[:space:]]*run:[[:space:]]*pr_stage_run' || true)"
assert_eq "[#1844/SPEC-13] manifest hooks has run: pr_stage_run" "1" "$(( _has_run > 0 ? 1 : 0 ))"

_has_cleanup="$(grep -v '^#' "$PR_MANIFEST" | grep -c '^[[:space:]]*cleanup:' || true)"
assert_eq "[#1844/SPEC-13] manifest hooks has no cleanup:" "0" "$_has_cleanup"

# ─── SPEC-18: manifest has no router: block ───────────────────────────────────
print_test_section "#1844/SPEC-18: manifest has no router: block"

_has_router="$(grep -v '^#' "$PR_MANIFEST" | grep -c '^[[:space:]]*router:' || true)"
assert_eq "[#1844/SPEC-18] manifest has no router: block" "0" "$_has_router"

# ─── SPEC-20: inputs section declares only id and required: ──────────────────
print_test_section "#1844/SPEC-20: manifest inputs entries declare only id and required:"

# Extract the inputs section and verify no forbidden fields appear in it
_inputs_section="$(awk '/^inputs:/{f=1; next} f && /^[a-z]/{f=0} f{print}' "$PR_MANIFEST" || echo '')"

_has_path_field="$(grep -c '^\s*path:' <<< "$_inputs_section" || true)"
assert_eq "[#1844/SPEC-20] inputs section has no path: fields" "0" "$_has_path_field"

_has_type_field="$(grep -c '^\s*type:' <<< "$_inputs_section" || true)"
assert_eq "[#1844/SPEC-20] inputs section has no type: fields" "0" "$_has_type_field"

_has_from_field="$(grep -c '^\s*from:' <<< "$_inputs_section" || true)"
assert_eq "[#1844/SPEC-20] inputs section has no from: fields" "0" "$_has_from_field"

_has_producer_field="$(grep -c '^\s*producer:' <<< "$_inputs_section" || true)"
assert_eq "[#1844/SPEC-20] inputs section has no producer: fields" "0" "$_has_producer_field"

# Each input entry must declare ONLY id and required: — no other field names.
_inputs_extra_count=0
while IFS= read -r _inln; do
    [[ "$_inln" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${_inln//[[:space:]]/}" ]] && continue
    [[ "$_inln" =~ ^[[:space:]]*-[[:space:]]*id: ]] && continue
    [[ "$_inln" =~ ^[[:space:]]*required: ]] && continue
    (( _inputs_extra_count++ )) || true
done < <(awk '/^inputs:/{f=1; next} f && /^[a-z]/{f=0} f{print}' "$PR_MANIFEST")
assert_eq "[#1844/SPEC-20] inputs entries have no fields beyond id and required:" "0" "$_inputs_extra_count"

# ─── SPEC-10: plugin.sh resolves inputs via ZBUILD_STAGE_INPUTS only ──────────
print_test_section "#1844/SPEC-10: plugin.sh constructs no hardcoded gate-aggregator-result.json or review-report.json paths"

_plugin_sh="$REPO_ROOT/plugins/agent/pr-delivery/plugin.sh"

_gate_hardcoded="$(grep -v '^[[:space:]]*#' "$_plugin_sh" | grep -cF 'gate-aggregator-result.json' || true)"
assert_eq "[#1844/SPEC-10] plugin.sh constructs no gate-aggregator-result.json path" "0" "$_gate_hardcoded"

_report_hardcoded="$(grep -v '^[[:space:]]*#' "$_plugin_sh" | grep -cF 'review-report.json' || true)"
assert_eq "[#1844/SPEC-10] plugin.sh constructs no review-report.json path" "0" "$_report_hardcoded"

# Positive: plugin.sh must reference ZBUILD_STAGE_INPUTS to resolve stage inputs.
_zbuild_inputs_ref="$(grep -v '^[[:space:]]*#' "$_plugin_sh" | grep -c 'ZBUILD_STAGE_INPUTS' || true)"
assert_eq "[#1844/SPEC-10] plugin.sh references ZBUILD_STAGE_INPUTS to resolve stage inputs" "1" \
    "$(( _zbuild_inputs_ref > 0 ? 1 : 0 ))"

# ─── Plugin behavior setup ─────────────────────────────────────────────────────
# shellcheck source=../../plugins/agent/pr-delivery/plugin.sh
source "$REPO_ROOT/plugins/agent/pr-delivery/plugin.sh"

# _mk_state <dir> [review_verdict]
# Sets up a state dir. Writes review.json when review_verdict is given.
_mk_state() {
    local d="$1" review_verdict="${2:-}"
    mkdir -p "$d/artifacts"
    printf '{"issue":1844,"branch":"zbuild/issue-1844-test"}\n' > "$d/pipeline-state.json"
    [[ -n "$review_verdict" ]] && \
        printf '{"schema_version":1,"verdict":"%s","summary":"ok"}\n' "$review_verdict" \
            > "$d/artifacts/review.json"
    # Minimal stage-inputs index (no gate or report by default)
    printf '{"inputs":{}}\n' > "$d/stage-inputs.json"
    printf '%s/pipeline-state.json' "$d"
}

# _mk_bins <bindir> <branch> [push_rc] [gh_create_rc]
# Creates mock git and gh executables in bindir.
_mk_bins() {
    local bin="$1" branch="$2" push_rc="${3:-0}" create_rc="${4:-0}"
    mkdir -p "$bin"
    cat > "$bin/git" <<GITMOCK
#!/usr/bin/env bash
cmd="\${1:-}"
[[ "\$cmd" == "-C" ]] && { shift 2; cmd="\${1:-}"; }
case "\$cmd" in
    rev-parse)
        [[ "\${2:-}" == "--abbrev-ref" ]] && echo "${branch}" && exit 0
        echo "abc1234"; exit 0 ;;
    checkout|fetch|config|branch|tag|ls-remote|merge-base|symbolic-ref|cat-file|show-ref) exit 0 ;;
    push) [[ ${push_rc} -ne 0 ]] && echo "mock push error" >&2; exit ${push_rc} ;;
    *) exit 0 ;;
esac
GITMOCK
    cat > "$bin/gh" <<GHMOCK
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
    "pr list")   echo "" ;;
    "pr create") [[ ${create_rc} -ne 0 ]] && { echo "gh create error" >&2; exit ${create_rc}; }
                 echo "https://github.com/mock/repo/pull/1844" ;;
    "pr merge")  exit 0 ;;
    *)           exit 0 ;;
esac
GHMOCK
    chmod +x "$bin/git" "$bin/gh"
}

# ─── SPEC-9 + SPEC-24: missing-state-file path ────────────────────────────────
print_test_section "#1844/SPEC-9 + SPEC-24: missing-state-file path returns rc=1 and writes pr-result.json"

_s9_dir="$TEST_TEMP_DIR/spec9"
mkdir -p "$_s9_dir/artifacts"
export ZBUILD_ARTIFACT_DIR="$_s9_dir/artifacts"
set +e
( pr_stage_run "pr" "" ) >/dev/null 2>&1; _s9_rc=$?
set -e
unset ZBUILD_ARTIFACT_DIR

assert_eq "[#1844/SPEC-9] missing-state-file: rc=1 (not rc=2)" "1" "$_s9_rc"

# SPEC-24: must also write pr-result.json
_s9_pr="$_s9_dir/artifacts/pr-result.json"
assert_file_exists "[#1844/SPEC-24] missing-state-file: pr-result.json written" "$_s9_pr"
if [[ -f "$_s9_pr" ]]; then
    assert_eq "[#1844/SPEC-24] missing-state-file: result_contract is 2" "2" \
        "$(jq -r '.result_contract // empty' "$_s9_pr" 2>/dev/null || true)"
    assert_eq "[#1844/SPEC-24] missing-state-file: verdict is error" "error" \
        "$(jq -r '.verdict // empty' "$_s9_pr" 2>/dev/null || true)"
    _s9_disp="$(jq -r '.disposition // empty' "$_s9_pr" 2>/dev/null || true)"
    [[ -n "$_s9_disp" ]] \
        && assert_pass "[#1844/SPEC-24] missing-state-file: disposition present" \
        || assert_fail "[#1844/SPEC-24] missing-state-file: disposition present" "absent"
    _s9_reason="$(jq -r '.reason // empty' "$_s9_pr" 2>/dev/null || true)"
    [[ -n "$_s9_reason" ]] \
        && assert_pass "[#1844/SPEC-24] missing-state-file: reason present" \
        || assert_fail "[#1844/SPEC-24] missing-state-file: reason present" "absent"
fi

# ─── SPEC-4: block guard exit path ────────────────────────────────────────────
print_test_section "#1844/SPEC-4: block guard exit path writes v2 pr-result.json"

_s4_dir="$TEST_TEMP_DIR/spec4"
_s4_sf="$(_mk_state "$_s4_dir" "block")"
_s4_art="$_s4_dir/artifacts"
_s4_pr="$_s4_art/pr-result.json"
_mk_bins "$TEST_TEMP_DIR/bin4" "zbuild/issue-1844-test"

set +e
( PATH="$TEST_TEMP_DIR/bin4:$PATH" ZBUILD_DRY_RUN=0 \
  ZBUILD_STAGE_INPUTS="$_s4_dir/stage-inputs.json" \
  pr_stage_run "pr" "$_s4_sf" ) >/dev/null 2>&1; _s4_rc=$?
set -e

assert_file_exists "[#1844/SPEC-4] block guard: pr-result.json written" "$_s4_pr"
if [[ -f "$_s4_pr" ]]; then
    assert_eq "[#1844/SPEC-4] block guard: result_contract is 2" "2" \
        "$(jq -r '.result_contract // empty' "$_s4_pr" 2>/dev/null || true)"
    assert_eq "[#1844/SPEC-4] block guard: verdict is error" "error" \
        "$(jq -r '.verdict // empty' "$_s4_pr" 2>/dev/null || true)"
    _s4_disp="$(jq -r '.disposition // empty' "$_s4_pr" 2>/dev/null || true)"
    [[ -n "$_s4_disp" ]] \
        && assert_pass "[#1844/SPEC-4] block guard: disposition present" \
        || assert_fail "[#1844/SPEC-4] block guard: disposition present" "absent"
    _s4_reason="$(jq -r '.reason // empty' "$_s4_pr" 2>/dev/null || true)"
    [[ -n "$_s4_reason" ]] \
        && assert_pass "[#1844/SPEC-4] block guard: reason present" \
        || assert_fail "[#1844/SPEC-4] block guard: reason present" "absent"
fi

# ─── SPEC-5 + SPEC-19: dry-run exit path ──────────────────────────────────────
print_test_section "#1844/SPEC-5 + SPEC-19: dry-run exit path writes v2 pr-result.json with .data.branch and .data.draft"

_s5_dir="$TEST_TEMP_DIR/spec5"
_s5_sf="$(_mk_state "$_s5_dir" "approve")"
_s5_art="$_s5_dir/artifacts"
_s5_pr="$_s5_art/pr-result.json"

set +e
( ZBUILD_DRY_RUN=1 ZBUILD_BRANCH="zbuild/issue-1844-test" \
  ZBUILD_STAGE_INPUTS="$_s5_dir/stage-inputs.json" \
  pr_stage_run "pr" "$_s5_sf" ) >/dev/null 2>&1; _s5_rc=$?
set -e

assert_file_exists "[#1844/SPEC-5] dry-run: pr-result.json written" "$_s5_pr"
if [[ -f "$_s5_pr" ]]; then
    assert_eq "[#1844/SPEC-5] dry-run: result_contract is 2" "2" \
        "$(jq -r '.result_contract // empty' "$_s5_pr" 2>/dev/null || true)"
    assert_eq "[#1844/SPEC-5] dry-run: verdict is pass" "pass" \
        "$(jq -r '.verdict // empty' "$_s5_pr" 2>/dev/null || true)"
    _s5_disp="$(jq -r '.disposition // empty' "$_s5_pr" 2>/dev/null || true)"
    [[ -n "$_s5_disp" ]] \
        && assert_pass "[#1844/SPEC-5] dry-run: disposition present" \
        || assert_fail "[#1844/SPEC-5] dry-run: disposition present" "absent"
    _s5_reason="$(jq -r '.reason // empty' "$_s5_pr" 2>/dev/null || true)"
    [[ -n "$_s5_reason" ]] \
        && assert_pass "[#1844/SPEC-5] dry-run: reason present" \
        || assert_fail "[#1844/SPEC-5] dry-run: reason present" "absent"

    # SPEC-19: v1 fields preserved inside v2 .data envelope
    _s5_branch="$(jq -r '.data.branch // empty' "$_s5_pr" 2>/dev/null || true)"
    [[ -n "$_s5_branch" ]] \
        && assert_pass "[#1844/SPEC-19] dry-run: .data.branch present" \
        || assert_fail "[#1844/SPEC-19] dry-run: .data.branch present" "absent"
    _s5_draft="$(jq -r '.data.draft // empty' "$_s5_pr" 2>/dev/null || true)"
    [[ -n "$_s5_draft" ]] \
        && assert_pass "[#1844/SPEC-19] dry-run: .data.draft present" \
        || assert_fail "[#1844/SPEC-19] dry-run: .data.draft present" "absent"
fi
assert_eq "[#1844/SPEC-5] dry-run: rc=0" "0" "$_s5_rc"

# Fallback-gh tests (SPEC-8, SPEC-16, SPEC-17) require the fallback-gh path,
# which is only reached when the pr-open plugin is absent. Override _PR_ROOT
# in these subshells to a fake directory with no pr-open plugin so the fallback
# direct `gh pr create` path is taken.
_FAKE_ROOT="$TEST_TEMP_DIR/fake-pr-root"
mkdir -p "$_FAKE_ROOT/plugins/tool"  # no pr-open subdirectory

# ─── SPEC-8: fallback-gh FAIL path ────────────────────────────────────────────
print_test_section "#1844/SPEC-8: fallback-gh-fail writes pr-result.json with verdict=error, disposition=unavailable"

_s8_dir="$TEST_TEMP_DIR/spec8"
_s8_sf="$(_mk_state "$_s8_dir" "approve")"
_s8_art="$_s8_dir/artifacts"
_s8_pr="$_s8_art/pr-result.json"
# Create bins where gh pr create fails (create_rc=1)
_mk_bins "$TEST_TEMP_DIR/bin8" "zbuild/issue-1844-test" 0 1

set +e
( export _PR_ROOT="$_FAKE_ROOT"
  PATH="$TEST_TEMP_DIR/bin8:$PATH" ZBUILD_DRY_RUN=0 \
  ZBUILD_STAGE_INPUTS="$_s8_dir/stage-inputs.json" \
  _TPL_MERGE_POLICY="none" \
  pr_stage_run "pr" "$_s8_sf" ) >/dev/null 2>&1; _s8_rc=$?
set -e

assert_file_exists "[#1844/SPEC-8] fallback-gh-fail: pr-result.json written" "$_s8_pr"
if [[ -f "$_s8_pr" ]]; then
    assert_eq "[#1844/SPEC-8] fallback-gh-fail: result_contract is 2" "2" \
        "$(jq -r '.result_contract // empty' "$_s8_pr" 2>/dev/null || true)"
    assert_eq "[#1844/SPEC-8] fallback-gh-fail: verdict is error" "error" \
        "$(jq -r '.verdict // empty' "$_s8_pr" 2>/dev/null || true)"
    assert_eq "[#1844/SPEC-8] fallback-gh-fail: disposition is unavailable" "unavailable" \
        "$(jq -r '.disposition // empty' "$_s8_pr" 2>/dev/null || true)"
fi

# ─── SPEC-16 + SPEC-21: fallback-gh SUCCESS path ─────────────────────────────
print_test_section "#1844/SPEC-16 + SPEC-21: fallback-gh SUCCESS writes v2 pr-result.json with .data envelope"

_s16_dir="$TEST_TEMP_DIR/spec16"
_s16_sf="$(_mk_state "$_s16_dir" "approve")"
_s16_art="$_s16_dir/artifacts"
_s16_pr="$_s16_art/pr-result.json"
_mk_bins "$TEST_TEMP_DIR/bin16" "zbuild/issue-1844-test"

# _PR_ROOT overridden to _FAKE_ROOT so pr-open is absent → fallback-gh path taken
set +e
( export _PR_ROOT="$_FAKE_ROOT"
  PATH="$TEST_TEMP_DIR/bin16:$PATH" ZBUILD_DRY_RUN=0 \
  ZBUILD_STAGE_INPUTS="$_s16_dir/stage-inputs.json" \
  _TPL_MERGE_POLICY="none" \
  pr_stage_run "pr" "$_s16_sf" ) >/dev/null 2>&1; _s16_rc=$?
set -e

assert_file_exists "[#1844/SPEC-16] fallback-gh success: pr-result.json written" "$_s16_pr"
if [[ -f "$_s16_pr" ]]; then
    assert_eq "[#1844/SPEC-16] fallback-gh success: result_contract is 2" "2" \
        "$(jq -r '.result_contract // empty' "$_s16_pr" 2>/dev/null || true)"
    assert_eq "[#1844/SPEC-16] fallback-gh success: verdict is pass" "pass" \
        "$(jq -r '.verdict // empty' "$_s16_pr" 2>/dev/null || true)"
    assert_eq "[#1844/SPEC-16] fallback-gh success: disposition is complete" "complete" \
        "$(jq -r '.disposition // empty' "$_s16_pr" 2>/dev/null || true)"
    _s16_reason="$(jq -r '.reason // empty' "$_s16_pr" 2>/dev/null || true)"
    [[ -n "$_s16_reason" ]] \
        && assert_pass "[#1844/SPEC-16] fallback-gh success: reason present" \
        || assert_fail "[#1844/SPEC-16] fallback-gh success: reason present" "absent"

    # SPEC-21: v1 fields preserved inside .data envelope
    _s16_data_branch="$(jq -r '.data.branch // empty' "$_s16_pr" 2>/dev/null || true)"
    [[ -n "$_s16_data_branch" ]] \
        && assert_pass "[#1844/SPEC-21] fallback-gh success: .data.branch present" \
        || assert_fail "[#1844/SPEC-21] fallback-gh success: .data.branch present" "absent"
    _s16_data_pr_url="$(jq -r '.data.pr_url // empty' "$_s16_pr" 2>/dev/null || true)"
    [[ -n "$_s16_data_pr_url" ]] \
        && assert_pass "[#1844/SPEC-21] fallback-gh success: .data.pr_url present" \
        || assert_fail "[#1844/SPEC-21] fallback-gh success: .data.pr_url present" "absent"
    _s16_data_draft="$(jq -r '.data.draft // empty' "$_s16_pr" 2>/dev/null || true)"
    [[ -n "$_s16_data_draft" ]] \
        && assert_pass "[#1844/SPEC-21] fallback-gh success: .data.draft present" \
        || assert_fail "[#1844/SPEC-21] fallback-gh success: .data.draft present" "absent"
fi

# ─── SPEC-6: merge-delegation FAIL path ───────────────────────────────────────
print_test_section "#1844/SPEC-6: merge-delegation FAIL writes pr-result.json: result_contract:2, verdict=error"

_s6_dir="$TEST_TEMP_DIR/spec6"
_s6_sf="$(_mk_state "$_s6_dir" "approve")"
_s6_art="$_s6_dir/artifacts"
_s6_pr="$_s6_art/pr-result.json"
# Set up a gate so auto_unless_flagged doesn't short-circuit to pr-open.
# We need merge_run to be called and to fail. Use branch=main so merge errors.
_mk_bins "$TEST_TEMP_DIR/bin6" "main"
# gate pass + review-report ready so auto_unless_flagged takes the merge path
printf '{"schema_version":1,"verdict":"pass"}\n' \
    > "$_s6_art/gate-aggregator-result.json"
printf '{"schema_version":1,"merge_readiness":"ready","findings":[]}\n' \
    > "$_s6_art/review-report.json"
printf '{"inputs":{"gate_aggregator_result":"%s","review_report":"%s"}}\n' \
    "$_s6_art/gate-aggregator-result.json" "$_s6_art/review-report.json" \
    > "$_s6_dir/stage-inputs.json"

set +e
( PATH="$TEST_TEMP_DIR/bin6:$PATH" ZBUILD_DRY_RUN=0 \
  ZBUILD_STAGE_INPUTS="$_s6_dir/stage-inputs.json" \
  _TPL_MERGE_POLICY="auto_unless_flagged" \
  pr_stage_run "pr" "$_s6_sf" ) >/dev/null 2>&1; _s6_rc=$?
set -e

assert_file_exists "[#1844/SPEC-6] merge-fail: pr-result.json written" "$_s6_pr"
if [[ -f "$_s6_pr" ]]; then
    assert_eq "[#1844/SPEC-6] merge-fail: result_contract is 2" "2" \
        "$(jq -r '.result_contract // empty' "$_s6_pr" 2>/dev/null || true)"
    assert_eq "[#1844/SPEC-6] merge-fail: verdict is error" "error" \
        "$(jq -r '.verdict // empty' "$_s6_pr" 2>/dev/null || true)"
    _s6_disp="$(jq -r '.disposition // empty' "$_s6_pr" 2>/dev/null || true)"
    [[ -n "$_s6_disp" ]] \
        && assert_pass "[#1844/SPEC-6] merge-fail: disposition present" \
        || assert_fail "[#1844/SPEC-6] merge-fail: disposition present" "absent"
    _s6_reason="$(jq -r '.reason // empty' "$_s6_pr" 2>/dev/null || true)"
    [[ -n "$_s6_reason" ]] \
        && assert_pass "[#1844/SPEC-6] merge-fail: reason present" \
        || assert_fail "[#1844/SPEC-6] merge-fail: reason present" "absent"
fi

# ─── SPEC-7: pr-open FAIL path (guard — pr-open already writes it) ────────────
print_test_section "#1844/SPEC-7: pr-open FAIL path has pr-result.json: result_contract:2, verdict=error (guard)"

_s7_dir="$TEST_TEMP_DIR/spec7"
_s7_sf="$(_mk_state "$_s7_dir" "approve")"
_s7_art="$_s7_dir/artifacts"
_s7_pr="$_s7_art/pr-result.json"
# gh pr create fails → pr-open writes error result; pr-delivery must not regress it
_mk_bins "$TEST_TEMP_DIR/bin7" "zbuild/issue-1844-test" 0 1

set +e
( PATH="$TEST_TEMP_DIR/bin7:$PATH" ZBUILD_DRY_RUN=0 \
  ZBUILD_STAGE_INPUTS="$_s7_dir/stage-inputs.json" \
  _TPL_MERGE_POLICY="none" \
  pr_stage_run "pr" "$_s7_sf" ) >/dev/null 2>&1; _s7_rc=$?
set -e

assert_file_exists "[#1844/SPEC-7] pr-open fail: pr-result.json written" "$_s7_pr"
if [[ -f "$_s7_pr" ]]; then
    assert_eq "[#1844/SPEC-7] pr-open fail: result_contract is 2" "2" \
        "$(jq -r '.result_contract // empty' "$_s7_pr" 2>/dev/null || true)"
    assert_eq "[#1844/SPEC-7] pr-open fail: verdict is error" "error" \
        "$(jq -r '.verdict // empty' "$_s7_pr" 2>/dev/null || true)"
fi

# ─── SPEC-14: pr-open SUCCESS path (guard — pr-open already writes it) ────────
print_test_section "#1844/SPEC-14: pr-open SUCCESS path has pr-result.json: result_contract:2, verdict=pass (guard)"

_s14_dir="$TEST_TEMP_DIR/spec14"
_s14_sf="$(_mk_state "$_s14_dir" "approve")"
_s14_art="$_s14_dir/artifacts"
_s14_pr="$_s14_art/pr-result.json"
_mk_bins "$TEST_TEMP_DIR/bin14" "zbuild/issue-1844-test"

set +e
( PATH="$TEST_TEMP_DIR/bin14:$PATH" ZBUILD_DRY_RUN=0 \
  ZBUILD_STAGE_INPUTS="$_s14_dir/stage-inputs.json" \
  _TPL_MERGE_POLICY="none" \
  pr_stage_run "pr" "$_s14_sf" ) >/dev/null 2>&1; _s14_rc=$?
set -e

assert_file_exists "[#1844/SPEC-14] pr-open success: pr-result.json written" "$_s14_pr"
if [[ -f "$_s14_pr" ]]; then
    assert_eq "[#1844/SPEC-14] pr-open success: result_contract is 2" "2" \
        "$(jq -r '.result_contract // empty' "$_s14_pr" 2>/dev/null || true)"
    assert_eq "[#1844/SPEC-14] pr-open success: verdict is pass" "pass" \
        "$(jq -r '.verdict // empty' "$_s14_pr" 2>/dev/null || true)"
fi

# ─── SPEC-15: merge SUCCESS path (guard — merge already writes it) ────────────
print_test_section "#1844/SPEC-15: merge SUCCESS path has pr-result.json: result_contract:2, verdict=pass (guard)"

_s15_dir="$TEST_TEMP_DIR/spec15"
_s15_sf="$(_mk_state "$_s15_dir" "approve")"
_s15_art="$_s15_dir/artifacts"
_s15_pr="$_s15_art/pr-result.json"
_mk_bins "$TEST_TEMP_DIR/bin15" "zbuild/issue-1844-test"
printf '{"schema_version":1,"verdict":"pass"}\n' \
    > "$_s15_art/gate-aggregator-result.json"
printf '{"schema_version":1,"merge_readiness":"ready","findings":[]}\n' \
    > "$_s15_art/review-report.json"
printf '{"inputs":{"gate_aggregator_result":"%s","review_report":"%s"}}\n' \
    "$_s15_art/gate-aggregator-result.json" "$_s15_art/review-report.json" \
    > "$_s15_dir/stage-inputs.json"

set +e
( PATH="$TEST_TEMP_DIR/bin15:$PATH" ZBUILD_DRY_RUN=0 \
  ZBUILD_STAGE_INPUTS="$_s15_dir/stage-inputs.json" \
  _TPL_MERGE_POLICY="auto_unless_flagged" \
  pr_stage_run "pr" "$_s15_sf" ) >/dev/null 2>&1; _s15_rc=$?
set -e

assert_file_exists "[#1844/SPEC-15] merge success: pr-result.json written" "$_s15_pr"
if [[ -f "$_s15_pr" ]]; then
    assert_eq "[#1844/SPEC-15] merge success: result_contract is 2" "2" \
        "$(jq -r '.result_contract // empty' "$_s15_pr" 2>/dev/null || true)"
    assert_eq "[#1844/SPEC-15] merge success: verdict is pass" "pass" \
        "$(jq -r '.verdict // empty' "$_s15_pr" 2>/dev/null || true)"
fi

# ─── SPEC-17: SIGTERM/SIGINT trap ─────────────────────────────────────────────
print_test_section "#1844/SPEC-17: SIGTERM trap writes pr-result.json: result_contract:2, verdict=error, disposition=interrupted; rc=1"

_s17_dir="$TEST_TEMP_DIR/spec17"
_s17_sf="$(_mk_state "$_s17_dir" "approve")"
_s17_art="$_s17_dir/artifacts"
_s17_pr="$_s17_art/pr-result.json"

# Run a subshell that sources the plugin and sends SIGTERM to itself during a
# slow operation. We do this by having the fake gh pause and then signal itself.
_mk_bins "$TEST_TEMP_DIR/bin17" "zbuild/issue-1844-test"
# Override gh to send SIGTERM to the process group so the plugin trap fires
cat > "$TEST_TEMP_DIR/bin17/gh" <<'GHSIGTERM'
#!/usr/bin/env bash
# Send SIGTERM to the calling process (the subshell running pr_stage_run)
kill -TERM "$PPID" 2>/dev/null || true
exit 1
GHSIGTERM
chmod +x "$TEST_TEMP_DIR/bin17/gh"

set +e
( export _PR_ROOT="$_FAKE_ROOT"
  PATH="$TEST_TEMP_DIR/bin17:$PATH" ZBUILD_DRY_RUN=0 \
  ZBUILD_STAGE_INPUTS="$_s17_dir/stage-inputs.json" \
  _TPL_MERGE_POLICY="none" \
  pr_stage_run "pr" "$_s17_sf" ) >/dev/null 2>&1; _s17_rc=$?
set -e

# The trap should have written the result file with disposition=interrupted
assert_file_exists "[#1844/SPEC-17] SIGTERM: pr-result.json written" "$_s17_pr"
if [[ -f "$_s17_pr" ]]; then
    assert_eq "[#1844/SPEC-17] SIGTERM: result_contract is 2" "2" \
        "$(jq -r '.result_contract // empty' "$_s17_pr" 2>/dev/null || true)"
    assert_eq "[#1844/SPEC-17] SIGTERM: verdict is error" "error" \
        "$(jq -r '.verdict // empty' "$_s17_pr" 2>/dev/null || true)"
    assert_eq "[#1844/SPEC-17] SIGTERM: disposition is interrupted" "interrupted" \
        "$(jq -r '.disposition // empty' "$_s17_pr" 2>/dev/null || true)"
fi
assert_eq "[#1844/SPEC-17] SIGTERM: rc=1" "1" "$_s17_rc"

# SIGINT path — same requirement: pr-result.json with disposition=interrupted and rc=1
print_test_section "#1844/SPEC-17: SIGINT trap writes pr-result.json: result_contract:2, verdict=error, disposition=interrupted; rc=1"

_s17i_dir="$TEST_TEMP_DIR/spec17i"
_s17i_sf="$(_mk_state "$_s17i_dir" "approve")"
_s17i_art="$_s17i_dir/artifacts"
_s17i_pr="$_s17i_art/pr-result.json"

_mk_bins "$TEST_TEMP_DIR/bin17i" "zbuild/issue-1844-test"
cat > "$TEST_TEMP_DIR/bin17i/gh" <<'GHSIGINT'
#!/usr/bin/env bash
kill -INT "$PPID" 2>/dev/null || true
exit 1
GHSIGINT
chmod +x "$TEST_TEMP_DIR/bin17i/gh"

set +e
( export _PR_ROOT="$_FAKE_ROOT"
  PATH="$TEST_TEMP_DIR/bin17i:$PATH" ZBUILD_DRY_RUN=0 \
  ZBUILD_STAGE_INPUTS="$_s17i_dir/stage-inputs.json" \
  _TPL_MERGE_POLICY="none" \
  pr_stage_run "pr" "$_s17i_sf" ) >/dev/null 2>&1; _s17i_rc=$?
set -e

assert_file_exists "[#1844/SPEC-17] SIGINT: pr-result.json written" "$_s17i_pr"
if [[ -f "$_s17i_pr" ]]; then
    assert_eq "[#1844/SPEC-17] SIGINT: result_contract is 2" "2" \
        "$(jq -r '.result_contract // empty' "$_s17i_pr" 2>/dev/null || true)"
    assert_eq "[#1844/SPEC-17] SIGINT: verdict is error" "error" \
        "$(jq -r '.verdict // empty' "$_s17i_pr" 2>/dev/null || true)"
    assert_eq "[#1844/SPEC-17] SIGINT: disposition is interrupted" "interrupted" \
        "$(jq -r '.disposition // empty' "$_s17i_pr" 2>/dev/null || true)"
fi
assert_eq "[#1844/SPEC-17] SIGINT: rc=1" "1" "$_s17i_rc"

# ─── SPEC-22 + SPEC-23: pr-open rc=0 but verdict≠pass (#2250) ────────────────
print_test_section "#1844/SPEC-22 + SPEC-23: pr-open rc=0 but verdict=blocked → pr-delivery rewrites error result and summary"

_s22_dir="$TEST_TEMP_DIR/spec22"
_s22_sf="$(_mk_state "$_s22_dir")"   # no review.json → pr-open writes blocked
_s22_art="$_s22_dir/artifacts"
_s22_pr="$_s22_art/pr-result.json"
_s22_summary="$_s22_art/pr-delivery-summary.md"
_mk_bins "$TEST_TEMP_DIR/bin22" "zbuild/issue-1844-test"

set +e
( PATH="$TEST_TEMP_DIR/bin22:$PATH" ZBUILD_DRY_RUN=0 \
  ZBUILD_STAGE_INPUTS="$_s22_dir/stage-inputs.json" \
  _TPL_MERGE_POLICY="none" \
  pr_stage_run "pr" "$_s22_sf" ) >/dev/null 2>&1; _s22_rc=$?
set -e

# SPEC-22: pr-delivery must overwrite with verdict=error, disposition=complete,
# reason=review_signal_missing and return rc=1
assert_eq "[#1844/SPEC-22] pr-open blocked rc=0: pr-delivery returns rc=1" "1" "$_s22_rc"
assert_file_exists "[#1844/SPEC-22] pr-open blocked rc=0: pr-result.json written" "$_s22_pr"
if [[ -f "$_s22_pr" ]]; then
    assert_eq "[#1844/SPEC-22] pr-open blocked rc=0: result_contract is 2" "2" \
        "$(jq -r '.result_contract // empty' "$_s22_pr" 2>/dev/null || true)"
    assert_eq "[#1844/SPEC-22] pr-open blocked rc=0: verdict is error" "error" \
        "$(jq -r '.verdict // empty' "$_s22_pr" 2>/dev/null || true)"
    assert_eq "[#1844/SPEC-22] pr-open blocked rc=0: disposition is complete" "complete" \
        "$(jq -r '.disposition // empty' "$_s22_pr" 2>/dev/null || true)"
    assert_eq "[#1844/SPEC-22] pr-open blocked rc=0: reason is review_signal_missing" "review_signal_missing" \
        "$(jq -r '.reason // empty' "$_s22_pr" 2>/dev/null || true)"
fi

# SPEC-23: summary must NOT say "pass — delivered the change by delegating to the pr-open stage"
# and MUST name review_signal_missing and say no PR was opened
assert_file_exists "[#1844/SPEC-23] pr-open blocked rc=0: pr-delivery-summary.md written" "$_s22_summary"
if [[ -f "$_s22_summary" ]]; then
    _s23_has_pass_text=0
    grep -qi "pass.*delivered.*delegating.*pr-open" "$_s22_summary" && _s23_has_pass_text=1 || true
    assert_eq "[#1844/SPEC-23] summary does NOT say 'pass — delivered ... delegating to the pr-open stage'" \
        "0" "$_s23_has_pass_text"

    _s23_has_signal_missing=0
    grep -qi "review_signal_missing" "$_s22_summary" && _s23_has_signal_missing=1 || true
    [[ "$_s23_has_signal_missing" -eq 1 ]] \
        && assert_pass "[#1844/SPEC-23] summary names review_signal_missing" \
        || assert_fail "[#1844/SPEC-23] summary names review_signal_missing" "absent from summary"

    # Must affirmatively state that no PR was opened — not just name the reason.
    _s23_has_no_pr_opened=0
    grep -qiE "no pr|no pull request|pr.*not.*open|was not opened" "$_s22_summary" && _s23_has_no_pr_opened=1 || true
    assert_eq "[#1844/SPEC-23] summary affirmatively states no PR was opened" "1" "$_s23_has_no_pr_opened"
fi

# ─── Teardown ─────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
exit $((FAIL > 0))
