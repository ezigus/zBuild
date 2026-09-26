#!/usr/bin/env bash
# tests/unit/pr-open-v2-result-test.sh
# Contract v2 result assertions for the pr-open plugin (issue #1849).
# SPEC coverage:
#   [SPEC-8]  manifest provides declares result_contract:2 (no role — constraint preserved)
#   [SPEC-9]  pr-open/config valid_verdicts updated to [pass,blocked,error]
#   [SPEC-10] pr-result.json carries result_contract:2, verdict=pass, disposition, reason
#   [SPEC-11] pr-result.json carries result_contract:2, verdict=blocked, disposition, reason; rc=0
#   [SPEC-12] pr-result.json carries result_contract:2, verdict=error, disposition, reason; rc=1
#   [SPEC-13] all exit paths return rc ∈ {0,1} — no rc=2
#   [SPEC-14] / [SPEC-31] — inputs from the engine's index: pr-open-v2-inputs-test.sh
#   [SPEC-30] an outward action that fails (push, gh pr create) reports unavailable
#   [SPEC-24] tier_default:T0, no router: block
#   [SPEC-25] outputs.pr_url retains primary: true after v2 migration
#   [SPEC-26] provides retains events:[plugin.pr_open.branch_fallback_used,
#             plugin.pr_open.preflight_remote_has_work] and has no role
#   [SPEC-28] hooks section has only run:, no cleanup:
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "pr-open plugin: v2 result contract (issue #1849)"
setup_test_env "pr-open-v2-result"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="/dev/null"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_RUN_ID="pr-open-v2-result-test-$$"
mkdir -p "$ZBUILD_EVENTS_DIR"
: > "$ZBUILD_EVENTS_JSONL"

PR_MANIFEST="$REPO_ROOT/plugins/tool/pr-open/manifest.yaml"

# ─── SPEC-8: manifest provides declares result_contract:2, no role ───────────
print_test_section "SPEC-8: manifest provides declares result_contract:2 (no role — constraint preserved)"

_s8_prov_rc="$(awk '/^provides:/{f=1} f && /result_contract:/{print $2; exit}' "$PR_MANIFEST" || echo '')"
assert_eq "[SPEC-8] manifest provides.result_contract is 2" "2" "$_s8_prov_rc"

# provides section ends at the next top-level key; look for role: within provides
_s8_role="$(awk '
    /^provides:/{in_prov=1; next}
    /^[a-z]/{in_prov=0}
    in_prov && /^[[:space:]]+role:/{print $2; exit}
' "$PR_MANIFEST" || echo '')"
assert_eq "[SPEC-8] manifest provides has no role (do-not-add constraint)" "" "$_s8_role"

# existing events must be retained after adding result_contract:2
_s8_ev1="$(awk '/^provides:/{f=1} f && /plugin\.pr_open\.branch_fallback_used/{print; exit}' "$PR_MANIFEST" || echo '')"
[[ -n "$_s8_ev1" ]] \
    && assert_pass "[SPEC-8] provides retains event plugin.pr_open.branch_fallback_used" \
    || assert_fail "[SPEC-8] provides retains event plugin.pr_open.branch_fallback_used" "absent from $PR_MANIFEST"

_s8_ev2="$(awk '/^provides:/{f=1} f && /plugin\.pr_open\.preflight_remote_has_work/{print; exit}' "$PR_MANIFEST" || echo '')"
[[ -n "$_s8_ev2" ]] \
    && assert_pass "[SPEC-8] provides retains event plugin.pr_open.preflight_remote_has_work" \
    || assert_fail "[SPEC-8] provides retains event plugin.pr_open.preflight_remote_has_work" "absent from $PR_MANIFEST"

# ─── SPEC-9: valid_verdicts includes pass, blocked, error ────────────────────
print_test_section "SPEC-9: config valid_verdicts updated to [pass, blocked, error]"

_vv_pass="$(grep -v '^#' "$PR_MANIFEST" | grep -c '^[[:space:]]*- pass$' || true)"
_vv_blocked="$(grep -v '^#' "$PR_MANIFEST" | grep -c '^[[:space:]]*- blocked$' || true)"
_vv_error="$(grep -v '^#' "$PR_MANIFEST" | grep -c '^[[:space:]]*- error$' || true)"
[[ "$_vv_pass" -gt 0 ]] \
    && assert_pass "[SPEC-9] valid_verdicts includes pass" \
    || assert_fail "[SPEC-9] valid_verdicts includes pass" "missing from $PR_MANIFEST"
[[ "$_vv_blocked" -gt 0 ]] \
    && assert_pass "[SPEC-9] valid_verdicts includes blocked" \
    || assert_fail "[SPEC-9] valid_verdicts includes blocked" "missing from $PR_MANIFEST"
[[ "$_vv_error" -gt 0 ]] \
    && assert_pass "[SPEC-9] valid_verdicts includes error" \
    || assert_fail "[SPEC-9] valid_verdicts includes error" "missing from $PR_MANIFEST"

# ─── SPEC-24: tier_default:T0, no router: block ──────────────────────────────
print_test_section "SPEC-24: tier_default:T0 with no router: block"

_td="$(grep -m1 'tier_default:' "$PR_MANIFEST" | awk '{print $2}' || echo '')"
assert_eq "[SPEC-24] manifest tier_default is T0" "T0" "$_td"

_has_router="$(grep -v '^#' "$PR_MANIFEST" | grep -c '^[[:space:]]*router:' || true)"
assert_eq "[SPEC-24] manifest has no router: block" "0" "$_has_router"

# ─── SPEC-25: outputs.pr_url retains primary: true ───────────────────────────
print_test_section "SPEC-25: outputs.pr_url retains primary: true"

_has_primary="$(grep -v '^#' "$PR_MANIFEST" | grep -c 'primary:[[:space:]]*true' || true)"
[[ "$_has_primary" -gt 0 ]] \
    && assert_pass "[SPEC-25] manifest has primary: true on pr_url output" \
    || assert_fail "[SPEC-25] manifest has primary: true on pr_url output" "missing"

# ─── SPEC-26: provides retains events, no role ───────────────────────────────
print_test_section "SPEC-26: provides retains events and has no role after result_contract:2 added"

_ev1="$(awk '/^provides:/{f=1} f && /plugin\.pr_open\.branch_fallback_used/{print; exit}' "$PR_MANIFEST" || echo '')"
[[ -n "$_ev1" ]] \
    && assert_pass "[SPEC-26] provides.events includes plugin.pr_open.branch_fallback_used" \
    || assert_fail "[SPEC-26] provides.events includes plugin.pr_open.branch_fallback_used" "absent"

_ev2="$(awk '/^provides:/{f=1} f && /plugin\.pr_open\.preflight_remote_has_work/{print; exit}' "$PR_MANIFEST" || echo '')"
[[ -n "$_ev2" ]] \
    && assert_pass "[SPEC-26] provides.events includes plugin.pr_open.preflight_remote_has_work" \
    || assert_fail "[SPEC-26] provides.events includes plugin.pr_open.preflight_remote_has_work" "absent"

_s26_role="$(awk '
    /^provides:/{in_prov=1; next}
    /^[a-z]/{in_prov=0}
    in_prov && /^[[:space:]]+role:/{print $2; exit}
' "$PR_MANIFEST" || echo '')"
assert_eq "[SPEC-26] provides has no role: key (do-not-add constraint preserved)" "" "$_s26_role"

# ─── SPEC-28: hooks has only run:, no cleanup: ───────────────────────────────
print_test_section "SPEC-28: hooks section has only run:, no cleanup:"

_has_cleanup="$(grep -v '^#' "$PR_MANIFEST" | grep -c '^[[:space:]]*cleanup:' || true)"
assert_eq "[SPEC-28] manifest hooks has no cleanup:" "0" "$_has_cleanup"

_has_run="$(grep -v '^#' "$PR_MANIFEST" | grep -c '^[[:space:]]*run:[[:space:]]*pr_open_run' || true)"
[[ "$_has_run" -gt 0 ]] \
    && assert_pass "[SPEC-28] manifest hooks has run: pr_open_run" \
    || assert_fail "[SPEC-28] manifest hooks has run: pr_open_run" "missing"

# ─── Plugin behavior setup ────────────────────────────────────────────────────
# shellcheck source=../../plugins/tool/pr-open/plugin.sh
source "$REPO_ROOT/plugins/tool/pr-open/plugin.sh"

# _make_pr_state <dir> [review_verdict]
# Sets up a state dir. review_verdict is written to review.json when given.
_make_pr_state() {
    local d="$1" review_verdict="${2:-}"
    mkdir -p "$d/artifacts"
    printf '{"issue":1849,"branch":"zbuild/issue-1849-test"}\n' > "$d/pipeline-state.json"
    [[ -n "$review_verdict" ]] && \
        printf '{"schema_version":1,"verdict":"%s","summary":"ok"}\n' "$review_verdict" \
            > "$d/artifacts/review.json"
    printf '%s/pipeline-state.json' "$d"
}

# Git/gh stub functions shared across tests.
# The _pr_open_run_inner function is designed for testability (see its header comment);
# we use bash function exports so git/gh are intercepted without PATH manipulation.

_stub_git_pass() {
    git() {
        if [[ "${1:-} ${2:-}" == "rev-parse --abbrev-ref" ]]; then
            echo "zbuild/issue-1849-test"
        else
            return 0
        fi
    }
    gh() {
        case "${1:-} ${2:-}" in
            "pr list") echo "" ;;
            "pr create") echo "https://github.com/mock/repo/pull/1849" ;;
            *) return 0 ;;
        esac
    }
    export -f git gh
}

_stub_git_existing_pr() {
    git() {
        if [[ "${1:-} ${2:-}" == "rev-parse --abbrev-ref" ]]; then
            echo "zbuild/issue-1849-test"
        else
            return 0
        fi
    }
    gh() {
        case "${1:-} ${2:-}" in
            "pr list")   echo "1849" ;;
            "pr edit")   return 0 ;;
            "pr view")   echo "https://github.com/mock/repo/pull/1849" ;;
            *) return 0 ;;
        esac
    }
    export -f git gh
}

_stub_git_main() {
    git() {
        if [[ "${1:-} ${2:-}" == "rev-parse --abbrev-ref" ]]; then
            echo "main"
        else
            return 0
        fi
    }
    gh() { return 0; }
    export -f git gh
}

_stub_git_push_fail() {
    git() {
        if [[ "${1:-} ${2:-}" == "rev-parse --abbrev-ref" ]]; then
            echo "zbuild/issue-1849-test"
        elif [[ "${1:-}" == "push" ]]; then
            echo "mock push error" >&2; return 1
        else
            return 0
        fi
    }
    gh() { case "${1:-} ${2:-}" in "pr list") echo "" ;; *) return 0 ;; esac; }
    export -f git gh
}

_stub_git_gh_create_fail() {
    git() {
        if [[ "${1:-} ${2:-}" == "rev-parse --abbrev-ref" ]]; then
            echo "zbuild/issue-1849-test"
        else
            return 0
        fi
    }
    gh() {
        case "${1:-} ${2:-}" in
            "pr list")   echo "" ;;
            "pr create") echo "gh create error" >&2; return 1 ;;
            *) return 0 ;;
        esac
    }
    export -f git gh
}

_unstub() { unset -f git gh 2>/dev/null || true; }

# ─── SPEC-10: pass paths — opened and updated ────────────────────────────────
print_test_section "SPEC-10: pass paths — result_contract:2, verdict=pass, disposition, reason"

# opened path: no existing PR on remote
_s10a_dir="$TEST_TEMP_DIR/spec10a"
_make_pr_state "$_s10a_dir" "approve" >/dev/null
_s10a_art="$_s10a_dir/artifacts"
_s10a_pr="$_s10a_art/pr-result.json"

_stub_git_pass
set +e
_pr_open_run_inner "$_s10a_art/review.json" "$_s10a_dir/pipeline-state.json" "$_s10a_pr" "1849"
_s10a_rc=$?
set -e
_unstub

assert_file_exists "[SPEC-10] opened: pr-result.json written" "$_s10a_pr"
if [[ -f "$_s10a_pr" ]]; then
    assert_eq "[SPEC-10] opened: result_contract is 2" "2" \
        "$(jq -r '.result_contract // empty' "$_s10a_pr" 2>/dev/null || true)"
    assert_eq "[SPEC-10] opened: verdict is pass" "pass" \
        "$(jq -r '.verdict // empty' "$_s10a_pr" 2>/dev/null || true)"
    _s10a_disp="$(jq -r '.disposition // empty' "$_s10a_pr" 2>/dev/null || true)"
    [[ -n "$_s10a_disp" ]] \
        && assert_pass "[SPEC-10] opened: disposition present" \
        || assert_fail "[SPEC-10] opened: disposition present" "absent"
    _s10a_reason="$(jq -r '.reason // empty' "$_s10a_pr" 2>/dev/null || true)"
    [[ -n "$_s10a_reason" ]] \
        && assert_pass "[SPEC-10] opened: reason present" \
        || assert_fail "[SPEC-10] opened: reason present" "absent"
fi

# updated path: existing PR on remote
_s10b_dir="$TEST_TEMP_DIR/spec10b"
_make_pr_state "$_s10b_dir" "approve" >/dev/null
_s10b_art="$_s10b_dir/artifacts"
_s10b_pr="$_s10b_art/pr-result.json"

_stub_git_existing_pr
set +e
_pr_open_run_inner "$_s10b_art/review.json" "$_s10b_dir/pipeline-state.json" "$_s10b_pr" "1849"
_s10b_rc=$?
set -e
_unstub

assert_file_exists "[SPEC-10] updated: pr-result.json written" "$_s10b_pr"
if [[ -f "$_s10b_pr" ]]; then
    assert_eq "[SPEC-10] updated: result_contract is 2" "2" \
        "$(jq -r '.result_contract // empty' "$_s10b_pr" 2>/dev/null || true)"
    assert_eq "[SPEC-10] updated: verdict is pass" "pass" \
        "$(jq -r '.verdict // empty' "$_s10b_pr" 2>/dev/null || true)"
    _s10b_disp="$(jq -r '.disposition // empty' "$_s10b_pr" 2>/dev/null || true)"
    [[ -n "$_s10b_disp" ]] \
        && assert_pass "[SPEC-10] updated: disposition present" \
        || assert_fail "[SPEC-10] updated: disposition present" "absent"
    _s10b_reason="$(jq -r '.reason // empty' "$_s10b_pr" 2>/dev/null || true)"
    [[ -n "$_s10b_reason" ]] \
        && assert_pass "[SPEC-10] updated: reason present" \
        || assert_fail "[SPEC-10] updated: reason present" "absent"
fi

# ─── SPEC-11: blocked paths — review verdict=block and no review signal ──────
print_test_section "SPEC-11: blocked paths — result_contract:2, verdict=blocked, disposition, reason; rc=0"

# review.json verdict=block
_s11a_dir="$TEST_TEMP_DIR/spec11a"
_make_pr_state "$_s11a_dir" "block" >/dev/null
_s11a_art="$_s11a_dir/artifacts"
_s11a_pr="$_s11a_art/pr-result.json"

_stub_git_pass
set +e
_pr_open_run_inner "$_s11a_art/review.json" "$_s11a_dir/pipeline-state.json" "$_s11a_pr" "1849"
_s11a_rc=$?
set -e
_unstub

assert_file_exists "[SPEC-11] review=block: pr-result.json written" "$_s11a_pr"
if [[ -f "$_s11a_pr" ]]; then
    assert_eq "[SPEC-11] review=block: result_contract is 2" "2" \
        "$(jq -r '.result_contract // empty' "$_s11a_pr" 2>/dev/null || true)"
    assert_eq "[SPEC-11] review=block: verdict is blocked" "blocked" \
        "$(jq -r '.verdict // empty' "$_s11a_pr" 2>/dev/null || true)"
    _s11a_disp="$(jq -r '.disposition // empty' "$_s11a_pr" 2>/dev/null || true)"
    [[ -n "$_s11a_disp" ]] \
        && assert_pass "[SPEC-11] review=block: disposition present" \
        || assert_fail "[SPEC-11] review=block: disposition present" "absent"
    _s11a_reason="$(jq -r '.reason // empty' "$_s11a_pr" 2>/dev/null || true)"
    [[ -n "$_s11a_reason" ]] \
        && assert_pass "[SPEC-11] review=block: reason present" \
        || assert_fail "[SPEC-11] review=block: reason present" "absent"
fi
assert_eq "[SPEC-11] review=block: rc=0 (not rc=2)" "0" "$_s11a_rc"

# no review signal — fail-closed: neither review.json nor review-report.json
_s11b_dir="$TEST_TEMP_DIR/spec11b"
_make_pr_state "$_s11b_dir" >/dev/null   # no review_verdict arg → no review.json
_s11b_art="$_s11b_dir/artifacts"
_s11b_pr="$_s11b_art/pr-result.json"

_stub_git_pass
set +e
_pr_open_run_inner "$_s11b_art/review.json" "$_s11b_dir/pipeline-state.json" "$_s11b_pr" "1849"
_s11b_rc=$?
set -e
_unstub

assert_file_exists "[SPEC-11] no-review-signal: pr-result.json written" "$_s11b_pr"
if [[ -f "$_s11b_pr" ]]; then
    assert_eq "[SPEC-11] no-review-signal: result_contract is 2" "2" \
        "$(jq -r '.result_contract // empty' "$_s11b_pr" 2>/dev/null || true)"
    assert_eq "[SPEC-11] no-review-signal: verdict is blocked (fail-closed)" "blocked" \
        "$(jq -r '.verdict // empty' "$_s11b_pr" 2>/dev/null || true)"
    _s11b_disp="$(jq -r '.disposition // empty' "$_s11b_pr" 2>/dev/null || true)"
    [[ -n "$_s11b_disp" ]] \
        && assert_pass "[SPEC-11] no-review-signal: disposition present" \
        || assert_fail "[SPEC-11] no-review-signal: disposition present" "absent"
    _s11b_reason="$(jq -r '.reason // empty' "$_s11b_pr" 2>/dev/null || true)"
    [[ -n "$_s11b_reason" ]] \
        && assert_pass "[SPEC-11] no-review-signal: reason present" \
        || assert_fail "[SPEC-11] no-review-signal: reason present" "absent"
fi
assert_eq "[SPEC-11] no-review-signal: rc=0 (not rc=2, fail-closed writes verdict=blocked)" "0" "$_s11b_rc"

# ─── SPEC-12: error paths — branch-is-main, push failure, gh failure ─────────
print_test_section "SPEC-12: error paths — result_contract:2, verdict=error, disposition, reason; rc=1 not rc=2"

# branch is main
_s12a_dir="$TEST_TEMP_DIR/spec12a"
_make_pr_state "$_s12a_dir" "approve" >/dev/null
_s12a_art="$_s12a_dir/artifacts"
_s12a_pr="$_s12a_art/pr-result.json"

_stub_git_main
set +e
_pr_open_run_inner "$_s12a_art/review.json" "$_s12a_dir/pipeline-state.json" "$_s12a_pr" "1849"
_s12a_rc=$?
set -e
_unstub

assert_file_exists "[SPEC-12] branch-is-main: pr-result.json written" "$_s12a_pr"
if [[ -f "$_s12a_pr" ]]; then
    assert_eq "[SPEC-12] branch-is-main: result_contract is 2" "2" \
        "$(jq -r '.result_contract // empty' "$_s12a_pr" 2>/dev/null || true)"
    assert_eq "[SPEC-12] branch-is-main: verdict is error" "error" \
        "$(jq -r '.verdict // empty' "$_s12a_pr" 2>/dev/null || true)"
    _s12a_disp="$(jq -r '.disposition // empty' "$_s12a_pr" 2>/dev/null || true)"
    [[ -n "$_s12a_disp" ]] \
        && assert_pass "[SPEC-12] branch-is-main: disposition present" \
        || assert_fail "[SPEC-12] branch-is-main: disposition present" "absent"
    _s12a_reason="$(jq -r '.reason // empty' "$_s12a_pr" 2>/dev/null || true)"
    [[ -n "$_s12a_reason" ]] \
        && assert_pass "[SPEC-12] branch-is-main: reason present" \
        || assert_fail "[SPEC-12] branch-is-main: reason present" "absent"
fi
assert_eq "[SPEC-12] branch-is-main: rc=1 (not rc=2)" "1" "$_s12a_rc"

# push failure
_s12b_dir="$TEST_TEMP_DIR/spec12b"
_make_pr_state "$_s12b_dir" "approve" >/dev/null
_s12b_art="$_s12b_dir/artifacts"
_s12b_pr="$_s12b_art/pr-result.json"

_stub_git_push_fail
set +e
_pr_open_run_inner "$_s12b_art/review.json" "$_s12b_dir/pipeline-state.json" "$_s12b_pr" "1849"
_s12b_rc=$?
set -e
_unstub

assert_file_exists "[SPEC-12] push-failure: pr-result.json written" "$_s12b_pr"
if [[ -f "$_s12b_pr" ]]; then
    assert_eq "[SPEC-12] push-failure: result_contract is 2" "2" \
        "$(jq -r '.result_contract // empty' "$_s12b_pr" 2>/dev/null || true)"
    assert_eq "[SPEC-12] push-failure: verdict is error" "error" \
        "$(jq -r '.verdict // empty' "$_s12b_pr" 2>/dev/null || true)"
    _s12b_disp="$(jq -r '.disposition // empty' "$_s12b_pr" 2>/dev/null || true)"
    [[ -n "$_s12b_disp" ]] \
        && assert_pass "[SPEC-12] push-failure: disposition present" \
        || assert_fail "[SPEC-12] push-failure: disposition present" "absent"
    _s12b_reason="$(jq -r '.reason // empty' "$_s12b_pr" 2>/dev/null || true)"
    [[ -n "$_s12b_reason" ]] \
        && assert_pass "[SPEC-12] push-failure: reason present" \
        || assert_fail "[SPEC-12] push-failure: reason present" "absent"
fi
assert_eq "[SPEC-12] push-failure: rc=1 (not rc=2)" "1" "$_s12b_rc"

# gh pr create failure
_s12c_dir="$TEST_TEMP_DIR/spec12c"
_make_pr_state "$_s12c_dir" "approve" >/dev/null
_s12c_art="$_s12c_dir/artifacts"
_s12c_pr="$_s12c_art/pr-result.json"

_stub_git_gh_create_fail
set +e
_pr_open_run_inner "$_s12c_art/review.json" "$_s12c_dir/pipeline-state.json" "$_s12c_pr" "1849"
_s12c_rc=$?
set -e
_unstub

assert_file_exists "[SPEC-12] gh-failure: pr-result.json written" "$_s12c_pr"
if [[ -f "$_s12c_pr" ]]; then
    assert_eq "[SPEC-12] gh-failure: result_contract is 2" "2" \
        "$(jq -r '.result_contract // empty' "$_s12c_pr" 2>/dev/null || true)"
    assert_eq "[SPEC-12] gh-failure: verdict is error" "error" \
        "$(jq -r '.verdict // empty' "$_s12c_pr" 2>/dev/null || true)"
    _s12c_disp="$(jq -r '.disposition // empty' "$_s12c_pr" 2>/dev/null || true)"
    [[ -n "$_s12c_disp" ]] \
        && assert_pass "[SPEC-12] gh-failure: disposition present" \
        || assert_fail "[SPEC-12] gh-failure: disposition present" "absent"
    _s12c_reason="$(jq -r '.reason // empty' "$_s12c_pr" 2>/dev/null || true)"
    [[ -n "$_s12c_reason" ]] \
        && assert_pass "[SPEC-12] gh-failure: reason present" \
        || assert_fail "[SPEC-12] gh-failure: reason present" "absent"
fi
assert_eq "[SPEC-12] gh-failure: rc=1 (not rc=2)" "1" "$_s12c_rc"

# ─── SPEC-13: no exit path returns rc=2 ──────────────────────────────────────
print_test_section "SPEC-13: all exit paths return rc ∈ {0,1} — no rc=2"

assert_eq "[SPEC-13] opened path rc=0" "0" "$_s10a_rc"
assert_eq "[SPEC-13] updated path rc=0" "0" "$_s10b_rc"
assert_eq "[SPEC-13] review=block rc=0" "0" "$_s11a_rc"
assert_eq "[SPEC-13] no-review-signal rc=0" "0" "$_s11b_rc"
assert_eq "[SPEC-13] branch-is-main rc=1" "1" "$_s12a_rc"
assert_eq "[SPEC-13] push-failure rc=1" "1" "$_s12b_rc"
assert_eq "[SPEC-13] gh-failure rc=1" "1" "$_s12c_rc"

# ─── SPEC-30: outward failures are `unavailable` ──────────────────────────────
print_test_section "SPEC-30: a failed outward action reports unavailable"
assert_eq "[SPEC-30] push failure → unavailable" "unavailable" \
    "$(jq -r '.disposition // empty' "$_s12b_pr" 2>/dev/null || true)"
assert_eq "[SPEC-30] gh pr create failure → unavailable" "unavailable" \
    "$(jq -r '.disposition // empty' "$_s12c_pr" 2>/dev/null || true)"

# ─── Teardown ─────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
exit $((FAIL > 0))
