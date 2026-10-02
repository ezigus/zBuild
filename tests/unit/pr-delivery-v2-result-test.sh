#!/usr/bin/env bash
# tests/unit/pr-delivery-v2-result-test.sh — contract v2 result assertions for
# the pr-delivery plugin (issue #1844).
#
# SPEC coverage:
#   [#1844/SPEC-1]  manifest: result_contract:2, valid_verdicts, events, role, primary, hooks
#   [#1844/SPEC-2]  missing state_file → rc=1, pr-result.json verdict=error/misconfigured
#   [#1844/SPEC-3]  review_report via ZBUILD_STAGE_INPUTS signals block → rc=1/error/complete
#   [#1844/SPEC-4]  dry-run → rc=0, verdict=pass, disposition=complete
#   [#1844/SPEC-5]  merge delegation success → rc=0, verdict=pass, disposition=complete
#   [#1844/SPEC-6]  merge delegation failure → rc=1, verdict=error, disposition=unavailable
#   [#1844/SPEC-7]  pr-open delegation success → rc=0, verdict=pass, disposition=complete
#   [#1844/SPEC-8]  pr-open verdict=blocked → rc=1, verdict=error, disposition=complete, reason=review_signal_missing
#   [#1844/SPEC-9]  fallback gh-pr-create success → rc=0, verdict=pass, disposition=complete
#   [#1844/SPEC-10] fallback gh-pr-create failure → rc=1, verdict=error, disposition=unavailable
#   [#1844/SPEC-11] plugin.sh has no hardcoded gate-aggregator-result.json or review-report.json
#   [#1844/SPEC-12] plugin.sh has no hardcoded review.json literal
#   [#1844/SPEC-13] manifest config: section comments intentional router: absence
#   [#1844/SPEC-14] plugin.sh installs _pr_delivery_on_signal trap; SIGTERM → interrupted/rc=1
#   [#1844/SPEC-15] manifest inputs: every entry has only id: and required: fields
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
PR_PLUGIN="$REPO_ROOT/plugins/agent/pr-delivery/plugin.sh"

# ─── SPEC-1: manifest provides declares result_contract:2, valid_verdicts, events ─
print_test_section "SPEC-1: manifest provides declares result_contract:2, valid_verdicts, events, role, primary, hooks"

_prov_rc="$(awk '/^provides:/{f=1} f && /result_contract:/{print $2; exit}' "$PR_MANIFEST" || echo '')"
assert_eq "[#1844/SPEC-1] manifest provides.result_contract is 2" "2" "$_prov_rc"

_vv_pass="$(grep -v '^#' "$PR_MANIFEST" | grep -c '^[[:space:]]*- pass$' || true)"
_vv_error="$(grep -v '^#' "$PR_MANIFEST" | grep -c '^[[:space:]]*- error$' || true)"
[[ "$_vv_pass" -gt 0 ]] \
    && assert_pass "[#1844/SPEC-1] config.valid_verdicts includes pass" \
    || assert_fail "[#1844/SPEC-1] config.valid_verdicts includes pass" "missing"
[[ "$_vv_error" -gt 0 ]] \
    && assert_pass "[#1844/SPEC-1] config.valid_verdicts includes error" \
    || assert_fail "[#1844/SPEC-1] config.valid_verdicts includes error" "missing"

_ev_blocked="$(grep -c 'pr\.delivery\.blocked' "$PR_MANIFEST" || true)"
_ev_opened="$(grep -c 'pr\.delivery\.opened' "$PR_MANIFEST" || true)"
_ev_dry="$(grep -c 'pr\.delivery\.dry_run' "$PR_MANIFEST" || true)"
[[ "$_ev_blocked" -gt 0 ]] \
    && assert_pass "[#1844/SPEC-1] provides.events includes pr.delivery.blocked" \
    || assert_fail "[#1844/SPEC-1] provides.events includes pr.delivery.blocked" "absent"
[[ "$_ev_opened" -gt 0 ]] \
    && assert_pass "[#1844/SPEC-1] provides.events includes pr.delivery.opened" \
    || assert_fail "[#1844/SPEC-1] provides.events includes pr.delivery.opened" "absent"
[[ "$_ev_dry" -gt 0 ]] \
    && assert_pass "[#1844/SPEC-1] provides.events includes pr.delivery.dry_run" \
    || assert_fail "[#1844/SPEC-1] provides.events includes pr.delivery.dry_run" "absent"

_prov_role="$(awk '/^provides:/{f=1} f && /^[[:space:]]*role:/{print $2; exit}' "$PR_MANIFEST" || echo '')"
assert_eq "[#1844/SPEC-1] provides.role is pr" "pr" "$_prov_role"

_has_primary="$(grep -v '^#' "$PR_MANIFEST" | grep -c 'primary:[[:space:]]*true' || true)"
[[ "$_has_primary" -gt 0 ]] \
    && assert_pass "[#1844/SPEC-1] pr_url output retains primary: true" \
    || assert_fail "[#1844/SPEC-1] pr_url output retains primary: true" "missing"

_has_cleanup="$(grep -v '^#' "$PR_MANIFEST" | grep -c '^[[:space:]]*cleanup:' || true)"
assert_eq "[#1844/SPEC-1] hooks has no cleanup:" "0" "$_has_cleanup"

_has_run="$(grep -v '^#' "$PR_MANIFEST" | grep -c '^[[:space:]]*run:' || true)"
[[ "$_has_run" -gt 0 ]] \
    && assert_pass "[#1844/SPEC-1] hooks has run:" \
    || assert_fail "[#1844/SPEC-1] hooks has run:" "missing"

# ─── Source plugin for behavioral tests ───────────────────────────────────────
# shellcheck source=../../plugins/agent/pr-delivery/plugin.sh
source "$PR_PLUGIN"

# _mk_state <label> — creates a temp dir with pipeline-state.json, returns path
_mk_state() {
    local d="$TEST_TEMP_DIR/state-$1"
    mkdir -p "$d/artifacts"
    printf '{"issue":1844,"branch":"zbuild/issue-1844-test"}\n' > "$d/pipeline-state.json"
    printf '%s/pipeline-state.json' "$d"
}

# _mk_si <dest> [review_report_path] [gate_path] — writes stage-inputs.json
_mk_si() {
    local dest="$1" rr="${2:-}" gate="${3:-}"
    if [[ -n "$rr" && -n "$gate" ]]; then
        printf '{"inputs":{"review_report":"%s","gate_aggregator_result":"%s"}}\n' \
            "$rr" "$gate" > "$dest"
    elif [[ -n "$rr" ]]; then
        printf '{"inputs":{"review_report":"%s"}}\n' "$rr" > "$dest"
    elif [[ -n "$gate" ]]; then
        printf '{"inputs":{"gate_aggregator_result":"%s"}}\n' "$gate" > "$dest"
    else
        printf '{"inputs":{}}\n' > "$dest"
    fi
}

# ─── SPEC-2: missing state_file → rc=1, pr-result.json verdict=error/misconfigured
print_test_section "SPEC-2: missing state_file → rc=1, pr-result.json result_contract:2/error/misconfigured"

_s2_art="$TEST_TEMP_DIR/spec2-artifacts"
mkdir -p "$_s2_art"
(
    export ZBUILD_ARTIFACT_DIR="$_s2_art"
    pr_stage_run "pr"
) >/dev/null 2>&1; _s2_rc=$?
assert_eq "[#1844/SPEC-2] missing state_file → rc=1 (not rc=2)" "1" "$_s2_rc"
if [[ -f "$_s2_art/pr-result.json" ]]; then
    assert_eq "[#1844/SPEC-2] pr-result.json result_contract is 2" "2" \
        "$(jq -r '.result_contract // empty' "$_s2_art/pr-result.json" 2>/dev/null || true)"
    assert_eq "[#1844/SPEC-2] pr-result.json verdict is error" "error" \
        "$(jq -r '.verdict // empty' "$_s2_art/pr-result.json" 2>/dev/null || true)"
    assert_eq "[#1844/SPEC-2] pr-result.json disposition is misconfigured" "misconfigured" \
        "$(jq -r '.disposition // empty' "$_s2_art/pr-result.json" 2>/dev/null || true)"
else
    assert_fail "[#1844/SPEC-2] pr-result.json written on missing state_file" "file absent at $_s2_art/pr-result.json"
fi

# ─── SPEC-3: review_report via ZBUILD_STAGE_INPUTS signals block ──────────────
# The review_report is at a non-standard path so a hardcoded-path read would miss
# it. The block is triggered by merge_readiness=needs_attention with a critical
# finding. The test fails if the plugin ignores ZBUILD_STAGE_INPUTS.
print_test_section "SPEC-3: review_report via ZBUILD_STAGE_INPUTS signals block → rc=1/error/complete"

_s3_sf="$(_mk_state s3)"
_s3_art="$(dirname "$_s3_sf")/artifacts"
_s3_rr="$TEST_TEMP_DIR/spec3-review-report.json"
jq -n '{merge_readiness:"needs_attention",findings:[{severity:"critical",summary:"blocking issue"}],summary:"test"}' \
    > "$_s3_rr"
_s3_si="$TEST_TEMP_DIR/spec3-si.json"
_mk_si "$_s3_si" "$_s3_rr"
(
    _PR_ROOT="$TEST_TEMP_DIR/fake-s3"
    mkdir -p "$_PR_ROOT/plugins/tool/merge" "$_PR_ROOT/plugins/tool/pr-open"
    ZBUILD_STAGE_INPUTS="$_s3_si"
    ZBUILD_DRY_RUN=0
    _TPL_MERGE_POLICY=manual
    _pr_stage_run_inner "$_s3_sf"
) >/dev/null 2>&1; _s3_rc=$?
assert_eq "[#1844/SPEC-3] review_report block → rc=1" "1" "$_s3_rc"
if [[ -f "$_s3_art/pr-result.json" ]]; then
    assert_eq "[#1844/SPEC-3] pr-result.json result_contract is 2" "2" \
        "$(jq -r '.result_contract // empty' "$_s3_art/pr-result.json" 2>/dev/null || true)"
    assert_eq "[#1844/SPEC-3] pr-result.json verdict is error" "error" \
        "$(jq -r '.verdict // empty' "$_s3_art/pr-result.json" 2>/dev/null || true)"
    assert_eq "[#1844/SPEC-3] pr-result.json disposition is complete" "complete" \
        "$(jq -r '.disposition // empty' "$_s3_art/pr-result.json" 2>/dev/null || true)"
else
    assert_fail "[#1844/SPEC-3] pr-result.json written on review_report block" "file absent"
fi

# ─── SPEC-4: dry-run → rc=0, result_contract:2, verdict=pass, disposition=complete
print_test_section "SPEC-4: dry-run → rc=0, pr-result.json result_contract:2/pass/complete"

_s4_sf="$(_mk_state s4)"
_s4_art="$(dirname "$_s4_sf")/artifacts"
_s4_si="$TEST_TEMP_DIR/spec4-si.json"
_mk_si "$_s4_si"
(
    ZBUILD_DRY_RUN=1
    ZBUILD_STAGE_INPUTS="$_s4_si"
    _pr_stage_run_inner "$_s4_sf"
) >/dev/null 2>&1; _s4_rc=$?
assert_eq "[#1844/SPEC-4] dry-run → rc=0" "0" "$_s4_rc"
if [[ -f "$_s4_art/pr-result.json" ]]; then
    assert_eq "[#1844/SPEC-4] pr-result.json result_contract is 2" "2" \
        "$(jq -r '.result_contract // empty' "$_s4_art/pr-result.json" 2>/dev/null || true)"
    assert_eq "[#1844/SPEC-4] pr-result.json verdict is pass" "pass" \
        "$(jq -r '.verdict // empty' "$_s4_art/pr-result.json" 2>/dev/null || true)"
    assert_eq "[#1844/SPEC-4] pr-result.json disposition is complete" "complete" \
        "$(jq -r '.disposition // empty' "$_s4_art/pr-result.json" 2>/dev/null || true)"
else
    assert_fail "[#1844/SPEC-4] pr-result.json written on dry-run" "file absent"
fi

# ─── SPEC-5: merge delegation success → rc=0, result_contract:2, verdict=pass ─
print_test_section "SPEC-5: merge delegation success → rc=0, pr-result.json result_contract:2/pass/complete"

_s5_fake="$TEST_TEMP_DIR/fake-s5"
mkdir -p "$_s5_fake/plugins/tool/merge"
cat > "$_s5_fake/plugins/tool/merge/plugin.sh" <<'MERGEMOCK'
merge_run() {
    local d; d="$(dirname "$2")/artifacts"
    mkdir -p "$d"
    jq -n '{result_contract:2,verdict:"pass",disposition:"complete",reason:"squash-merged"}' \
        > "$d/merge-result.json"
    return 0
}
MERGEMOCK
_s5_sf="$(_mk_state s5)"
_s5_art="$(dirname "$_s5_sf")/artifacts"
_s5_si="$TEST_TEMP_DIR/spec5-si.json"
_mk_si "$_s5_si"
(
    _PR_ROOT="$_s5_fake"
    _TPL_MERGE_POLICY=auto
    ZBUILD_DRY_RUN=0
    ZBUILD_STAGE_INPUTS="$_s5_si"
    _pr_stage_run_inner "$_s5_sf"
) >/dev/null 2>&1; _s5_rc=$?
assert_eq "[#1844/SPEC-5] merge delegation success → rc=0" "0" "$_s5_rc"
if [[ -f "$_s5_art/pr-result.json" ]]; then
    assert_eq "[#1844/SPEC-5] pr-result.json result_contract is 2" "2" \
        "$(jq -r '.result_contract // empty' "$_s5_art/pr-result.json" 2>/dev/null || true)"
    assert_eq "[#1844/SPEC-5] pr-result.json verdict is pass" "pass" \
        "$(jq -r '.verdict // empty' "$_s5_art/pr-result.json" 2>/dev/null || true)"
    assert_eq "[#1844/SPEC-5] pr-result.json disposition is complete" "complete" \
        "$(jq -r '.disposition // empty' "$_s5_art/pr-result.json" 2>/dev/null || true)"
else
    assert_fail "[#1844/SPEC-5] pr-result.json written on merge delegation success" "file absent"
fi

# ─── SPEC-6: merge delegation failure → rc=1, verdict=error, disposition=unavailable
# The delegate writes no pr-result.json; pr-delivery supplies the fallback v2 result.
print_test_section "SPEC-6: merge delegation failure → rc=1, pr-result.json result_contract:2/error/unavailable"

_s6_fake="$TEST_TEMP_DIR/fake-s6"
mkdir -p "$_s6_fake/plugins/tool/merge"
cat > "$_s6_fake/plugins/tool/merge/plugin.sh" <<'MERGEMOCK'
merge_run() {
    return 1
}
MERGEMOCK
_s6_sf="$(_mk_state s6)"
_s6_art="$(dirname "$_s6_sf")/artifacts"
_s6_si="$TEST_TEMP_DIR/spec6-si.json"
_mk_si "$_s6_si"
(
    _PR_ROOT="$_s6_fake"
    _TPL_MERGE_POLICY=auto
    ZBUILD_DRY_RUN=0
    ZBUILD_STAGE_INPUTS="$_s6_si"
    _pr_stage_run_inner "$_s6_sf"
) >/dev/null 2>&1; _s6_rc=$?
assert_eq "[#1844/SPEC-6] merge delegation failure → rc=1" "1" "$_s6_rc"
if [[ -f "$_s6_art/pr-result.json" ]]; then
    assert_eq "[#1844/SPEC-6] pr-result.json result_contract is 2" "2" \
        "$(jq -r '.result_contract // empty' "$_s6_art/pr-result.json" 2>/dev/null || true)"
    assert_eq "[#1844/SPEC-6] pr-result.json verdict is error" "error" \
        "$(jq -r '.verdict // empty' "$_s6_art/pr-result.json" 2>/dev/null || true)"
    assert_eq "[#1844/SPEC-6] pr-result.json disposition is unavailable" "unavailable" \
        "$(jq -r '.disposition // empty' "$_s6_art/pr-result.json" 2>/dev/null || true)"
else
    assert_fail "[#1844/SPEC-6] pr-result.json written on merge delegation failure" "file absent"
fi

# ─── SPEC-7: pr-open delegation success → rc=0, verdict=pass, disposition=complete
# policy=manual bypasses both merge paths and goes directly to pr-open.
print_test_section "SPEC-7: pr-open delegation success → rc=0, pr-result.json result_contract:2/pass/complete"

_s7_fake="$TEST_TEMP_DIR/fake-s7"
mkdir -p "$_s7_fake/plugins/tool/pr-open"
cat > "$_s7_fake/plugins/tool/pr-open/plugin.sh" <<'PROMOCK'
pr_open_run() {
    local d; d="$(dirname "$2")/artifacts"
    mkdir -p "$d"
    jq -n '{result_contract:2,verdict:"pass",disposition:"complete",reason:"PR opened",data:{pr_url:"https://github.com/mock/pull/7",draft:false}}' \
        > "$d/pr-result.json"
    printf 'https://github.com/mock/pull/7\n' > "$d/pr-url.txt"
    return 0
}
PROMOCK
_s7_sf="$(_mk_state s7)"
_s7_art="$(dirname "$_s7_sf")/artifacts"
_s7_si="$TEST_TEMP_DIR/spec7-si.json"
_mk_si "$_s7_si"
(
    _PR_ROOT="$_s7_fake"
    _TPL_MERGE_POLICY=manual
    ZBUILD_DRY_RUN=0
    ZBUILD_STAGE_INPUTS="$_s7_si"
    _pr_stage_run_inner "$_s7_sf"
) >/dev/null 2>&1; _s7_rc=$?
assert_eq "[#1844/SPEC-7] pr-open delegation success → rc=0" "0" "$_s7_rc"
if [[ -f "$_s7_art/pr-result.json" ]]; then
    assert_eq "[#1844/SPEC-7] pr-result.json result_contract is 2" "2" \
        "$(jq -r '.result_contract // empty' "$_s7_art/pr-result.json" 2>/dev/null || true)"
    assert_eq "[#1844/SPEC-7] pr-result.json verdict is pass" "pass" \
        "$(jq -r '.verdict // empty' "$_s7_art/pr-result.json" 2>/dev/null || true)"
    assert_eq "[#1844/SPEC-7] pr-result.json disposition is complete" "complete" \
        "$(jq -r '.disposition // empty' "$_s7_art/pr-result.json" 2>/dev/null || true)"
else
    assert_fail "[#1844/SPEC-7] pr-result.json written on pr-open delegation success" "file absent"
fi

# ─── SPEC-8: pr-open returns verdict=blocked → rc=1, error/complete, reason=review_signal_missing
print_test_section "SPEC-8: pr-open verdict=blocked → rc=1, pr-result.json result_contract:2/error/complete/review_signal_missing"

_s8_fake="$TEST_TEMP_DIR/fake-s8"
mkdir -p "$_s8_fake/plugins/tool/pr-open"
cat > "$_s8_fake/plugins/tool/pr-open/plugin.sh" <<'PROMOCK'
pr_open_run() {
    local d; d="$(dirname "$2")/artifacts"
    mkdir -p "$d"
    jq -n '{result_contract:2,verdict:"blocked",disposition:"complete",reason:"review_signal_missing"}' \
        > "$d/pr-result.json"
    return 0
}
PROMOCK
_s8_sf="$(_mk_state s8)"
_s8_art="$(dirname "$_s8_sf")/artifacts"
_s8_si="$TEST_TEMP_DIR/spec8-si.json"
_mk_si "$_s8_si"
(
    _PR_ROOT="$_s8_fake"
    _TPL_MERGE_POLICY=manual
    ZBUILD_DRY_RUN=0
    ZBUILD_STAGE_INPUTS="$_s8_si"
    _pr_stage_run_inner "$_s8_sf"
) >/dev/null 2>&1; _s8_rc=$?
assert_eq "[#1844/SPEC-8] pr-open verdict=blocked → rc=1" "1" "$_s8_rc"
if [[ -f "$_s8_art/pr-result.json" ]]; then
    assert_eq "[#1844/SPEC-8] pr-result.json result_contract is 2" "2" \
        "$(jq -r '.result_contract // empty' "$_s8_art/pr-result.json" 2>/dev/null || true)"
    assert_eq "[#1844/SPEC-8] pr-result.json verdict is error" "error" \
        "$(jq -r '.verdict // empty' "$_s8_art/pr-result.json" 2>/dev/null || true)"
    assert_eq "[#1844/SPEC-8] pr-result.json disposition is complete" "complete" \
        "$(jq -r '.disposition // empty' "$_s8_art/pr-result.json" 2>/dev/null || true)"
    _s8_reason="$(jq -r '.reason // empty' "$_s8_art/pr-result.json" 2>/dev/null || true)"
    if grep -q 'review_signal_missing' <<< "$_s8_reason"; then
        assert_pass "[#1844/SPEC-8] pr-result.json reason contains review_signal_missing"
    else
        assert_fail "[#1844/SPEC-8] pr-result.json reason contains review_signal_missing" \
            "got: $_s8_reason"
    fi
else
    assert_fail "[#1844/SPEC-8] pr-result.json written on pr-open blocked" "file absent"
fi

# ─── SPEC-9: fallback gh-pr-create success → rc=0, verdict=pass, disposition=complete
# No pr-open plugin in fake root → falls through to direct gh pr create.
print_test_section "SPEC-9: fallback gh-pr-create success → rc=0, pr-result.json result_contract:2/pass/complete"

_s9_fake="$TEST_TEMP_DIR/fake-s9"
mkdir -p "$_s9_fake/plugins/tool"
_s9_bin="$TEST_TEMP_DIR/bin-s9"
mkdir -p "$_s9_bin"
cat > "$_s9_bin/gh" <<'GHMOCK'
#!/usr/bin/env bash
[[ "${1:-} ${2:-}" == "pr create" ]] && { echo "https://github.com/mock/pull/9"; exit 0; }
exit 0
GHMOCK
cat > "$_s9_bin/git" <<'GITMOCK'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse) echo "zbuild/issue-1844-test"; exit 0 ;;
    *) exit 0 ;;
esac
GITMOCK
chmod +x "$_s9_bin/gh" "$_s9_bin/git"
_s9_sf="$(_mk_state s9)"
_s9_art="$(dirname "$_s9_sf")/artifacts"
_s9_si="$TEST_TEMP_DIR/spec9-si.json"
_mk_si "$_s9_si"
(
    _PR_ROOT="$_s9_fake"
    _TPL_MERGE_POLICY=manual
    ZBUILD_DRY_RUN=0
    ZBUILD_STAGE_INPUTS="$_s9_si"
    PATH="$_s9_bin:$PATH"
    _pr_stage_run_inner "$_s9_sf"
) >/dev/null 2>&1; _s9_rc=$?
assert_eq "[#1844/SPEC-9] fallback gh-pr-create success → rc=0" "0" "$_s9_rc"
if [[ -f "$_s9_art/pr-result.json" ]]; then
    assert_eq "[#1844/SPEC-9] pr-result.json result_contract is 2" "2" \
        "$(jq -r '.result_contract // empty' "$_s9_art/pr-result.json" 2>/dev/null || true)"
    assert_eq "[#1844/SPEC-9] pr-result.json verdict is pass" "pass" \
        "$(jq -r '.verdict // empty' "$_s9_art/pr-result.json" 2>/dev/null || true)"
    assert_eq "[#1844/SPEC-9] pr-result.json disposition is complete" "complete" \
        "$(jq -r '.disposition // empty' "$_s9_art/pr-result.json" 2>/dev/null || true)"
else
    assert_fail "[#1844/SPEC-9] pr-result.json written on fallback gh success" "file absent"
fi

# ─── SPEC-10: fallback gh-pr-create failure → rc=1, verdict=error, disposition=unavailable
print_test_section "SPEC-10: fallback gh-pr-create failure → rc=1, pr-result.json result_contract:2/error/unavailable"

_s10_fake="$TEST_TEMP_DIR/fake-s10"
mkdir -p "$_s10_fake/plugins/tool"
_s10_bin="$TEST_TEMP_DIR/bin-s10"
mkdir -p "$_s10_bin"
cat > "$_s10_bin/gh" <<'GHMOCK'
#!/usr/bin/env bash
[[ "${1:-} ${2:-}" == "pr create" ]] && { echo "gh pr create failed" >&2; exit 1; }
exit 0
GHMOCK
cat > "$_s10_bin/git" <<'GITMOCK'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse) echo "zbuild/issue-1844-test"; exit 0 ;;
    *) exit 0 ;;
esac
GITMOCK
chmod +x "$_s10_bin/gh" "$_s10_bin/git"
_s10_sf="$(_mk_state s10)"
_s10_art="$(dirname "$_s10_sf")/artifacts"
_s10_si="$TEST_TEMP_DIR/spec10-si.json"
_mk_si "$_s10_si"
(
    _PR_ROOT="$_s10_fake"
    _TPL_MERGE_POLICY=manual
    ZBUILD_DRY_RUN=0
    ZBUILD_STAGE_INPUTS="$_s10_si"
    PATH="$_s10_bin:$PATH"
    _pr_stage_run_inner "$_s10_sf"
) >/dev/null 2>&1; _s10_rc=$?
assert_eq "[#1844/SPEC-10] fallback gh-pr-create failure → rc=1" "1" "$_s10_rc"
if [[ -f "$_s10_art/pr-result.json" ]]; then
    assert_eq "[#1844/SPEC-10] pr-result.json result_contract is 2" "2" \
        "$(jq -r '.result_contract // empty' "$_s10_art/pr-result.json" 2>/dev/null || true)"
    assert_eq "[#1844/SPEC-10] pr-result.json verdict is error" "error" \
        "$(jq -r '.verdict // empty' "$_s10_art/pr-result.json" 2>/dev/null || true)"
    assert_eq "[#1844/SPEC-10] pr-result.json disposition is unavailable" "unavailable" \
        "$(jq -r '.disposition // empty' "$_s10_art/pr-result.json" 2>/dev/null || true)"
else
    assert_fail "[#1844/SPEC-10] pr-result.json written on fallback gh failure" "file absent"
fi

# ─── SPEC-11: plugin.sh has no hardcoded gate-aggregator-result.json or review-report.json
print_test_section "SPEC-11: plugin.sh has no hardcoded gate-aggregator-result.json or review-report.json"

_s11_gate="$(grep -v '^[[:space:]]*#' "$PR_PLUGIN" | grep -cF 'gate-aggregator-result.json' || true)"
assert_eq "[#1844/SPEC-11] plugin.sh has no hardcoded gate-aggregator-result.json" "0" "$_s11_gate"

_s11_rr="$(grep -v '^[[:space:]]*#' "$PR_PLUGIN" | grep -cF 'review-report.json' || true)"
assert_eq "[#1844/SPEC-11] plugin.sh has no hardcoded review-report.json" "0" "$_s11_rr"

# ─── SPEC-12: plugin.sh has no hardcoded review.json literal
print_test_section "SPEC-12: plugin.sh has no hardcoded review.json literal"

_s12_rv="$(grep -v '^[[:space:]]*#' "$PR_PLUGIN" | grep -cF 'review.json' || true)"
assert_eq "[#1844/SPEC-12] plugin.sh has no hardcoded review.json" "0" "$_s12_rv"

# ─── SPEC-13: manifest config: section comments router: absence ───────────────
print_test_section "SPEC-13: manifest config: section has comment recording intentional router: absence"

# The comment must appear in the config: section, recording no-model-call rationale
# (analogous to plugins/tool/pr-open/manifest.yaml lines 17-21).
_s13_router_comment="$(awk '/^config:/{f=1} /^[^c]/{if(f && !/^config:|^[[:space:]]/)f=0} f && /router/{print; exit}' "$PR_MANIFEST" || echo '')"
[[ -n "$_s13_router_comment" ]] \
    && assert_pass "[#1844/SPEC-13] manifest config: section has a comment about router: absence" \
    || assert_fail "[#1844/SPEC-13] manifest config: section has a comment about router: absence" \
        "no router-related comment found in config: section of $PR_MANIFEST"

# ─── SPEC-14: signal trap installs _pr_delivery_on_signal; SIGTERM → interrupted/rc=1
print_test_section "SPEC-14: plugin.sh installs _pr_delivery_on_signal; signal → pr-result.json interrupted/rc=1"

# _pr_delivery_on_signal must be defined by the plugin
if declare -f _pr_delivery_on_signal >/dev/null 2>&1; then
    assert_pass "[#1844/SPEC-14] _pr_delivery_on_signal is defined"
else
    assert_fail "[#1844/SPEC-14] _pr_delivery_on_signal is defined" "function not found"
fi

# Verify stage_signal_begin is called with _pr_delivery_on_signal as callback;
# fire the callback immediately (simulates SIGTERM during delegation).
_s14_sf="$(_mk_state s14)"
_s14_art="$(dirname "$_s14_sf")/artifacts"
_s14_si="$TEST_TEMP_DIR/spec14-si.json"
_mk_si "$_s14_si"
_s14_fake="$TEST_TEMP_DIR/fake-s14"
mkdir -p "$_s14_fake/plugins/tool/merge" "$_s14_fake/plugins/tool/pr-open"
(
    _PR_ROOT="$_s14_fake"
    _TPL_MERGE_POLICY=manual
    export ZBUILD_DRY_RUN=0
    export ZBUILD_STAGE_INPUTS="$_s14_si"
    # Override stage_signal_begin to fire the callback immediately, simulating
    # an OS signal arriving before delegation completes.
    stage_signal_begin() {
        local _cb="$1"
        stage_signal_end() { return 0; }
        "$_cb" "$STAGE_SIGNAL_DISPOSITION" "$STAGE_SIGNAL_REASON" || true
        return 0
    }
    STAGE_SIGNAL_DISPOSITION="interrupted"
    STAGE_SIGNAL_REASON="signal_interrupt"
    _pr_stage_run_inner "$_s14_sf" || true
) >/dev/null 2>&1; _s14_rc=$?
# rc must be 1 (the run function exits 1 after the signal handler fires)
assert_eq "[#1844/SPEC-14] signal → run exits rc=1" "1" "$_s14_rc"
if [[ -f "$_s14_art/pr-result.json" ]]; then
    assert_eq "[#1844/SPEC-14] pr-result.json result_contract is 2" "2" \
        "$(jq -r '.result_contract // empty' "$_s14_art/pr-result.json" 2>/dev/null || true)"
    assert_eq "[#1844/SPEC-14] pr-result.json verdict is error" "error" \
        "$(jq -r '.verdict // empty' "$_s14_art/pr-result.json" 2>/dev/null || true)"
    assert_eq "[#1844/SPEC-14] pr-result.json disposition is interrupted" "interrupted" \
        "$(jq -r '.disposition // empty' "$_s14_art/pr-result.json" 2>/dev/null || true)"
else
    assert_fail "[#1844/SPEC-14] pr-result.json written on signal" "file absent"
fi

# ─── SPEC-15: manifest inputs: every entry has only id: and required: fields ──
print_test_section "SPEC-15: manifest inputs entries contain only id: and required: fields (ADR-055 §1)"

# Forbidden fields: path:, type:, source:, stage:
_s15_path="$(awk '/^inputs:/{f=1} /^[^i[:space:]]/{if(f && !/^inputs:/)f=0} f && /^[[:space:]]*path:/' "$PR_MANIFEST" | grep -cv '^[[:space:]]*#' || true)"
_s15_type="$(awk '/^inputs:/{f=1} /^[^i[:space:]]/{if(f && !/^inputs:/)f=0} f && /^[[:space:]]*type:/' "$PR_MANIFEST" | grep -cv '^[[:space:]]*#' || true)"
_s15_source="$(awk '/^inputs:/{f=1} /^[^i[:space:]]/{if(f && !/^inputs:/)f=0} f && /^[[:space:]]*source:/' "$PR_MANIFEST" | grep -cv '^[[:space:]]*#' || true)"
_s15_stage="$(awk '/^inputs:/{f=1} /^[^i[:space:]]/{if(f && !/^inputs:/)f=0} f && /^[[:space:]]*stage:/' "$PR_MANIFEST" | grep -cv '^[[:space:]]*#' || true)"
assert_eq "[#1844/SPEC-15] manifest inputs has no path: fields" "0" "$_s15_path"
assert_eq "[#1844/SPEC-15] manifest inputs has no type: fields" "0" "$_s15_type"
assert_eq "[#1844/SPEC-15] manifest inputs has no source: fields" "0" "$_s15_source"
assert_eq "[#1844/SPEC-15] manifest inputs has no stage: fields" "0" "$_s15_stage"

# ─── Teardown ─────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
exit $((FAIL > 0))
