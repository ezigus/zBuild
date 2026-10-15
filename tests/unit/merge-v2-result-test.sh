#!/usr/bin/env bash
# tests/unit/merge-v2-result-test.sh
# Contract v2 result assertions for the merge plugin (issue #1849).
# SPEC coverage:
#   [SPEC-1]  manifest provides declares result_contract:3, role:merge_executor, events:[plugin.result]
#   [SPEC-2]  merge/config valid_verdicts updated to [pass, error]
#   [SPEC-3]  merge-result.json carries result_contract:3, verdict=pass, disposition:complete, reason
#   [SPEC-4]  merge-result.json carries result_contract:3, verdict=pass, data.mode=pr_fallback on fallback paths
#   [SPEC-5]  merge-result.json carries result_contract:3, verdict=error, disposition, reason on error paths
#   [SPEC-6]  all exit paths return rc ∈ {0,1} — no rc=2
#   [SPEC-7]  merges only when the engine says every loop passed
#             (ZBUILD_RUN_LOOPS_PASSED=yes, #2368); constructs no
#             gate-aggregator-result.json path
#   [SPEC-29] a PR fallback whose pr_open_run fails is reported as a failure, not a pass
#   [SPEC-30] an outward action that fails (push, gh pr create, gh pr merge) reports
#             disposition=unavailable — its outcome at the remote is unknown (#1849 "Folds in")
#   [SPEC-24] tier_default:T0, no router: block
#   [SPEC-25] outputs.merge_result retains primary: true after v2 migration
#   [SPEC-28] hooks section has only run:, no cleanup:
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "merge plugin: v2 result contract (issue #1849)"
setup_test_env "merge-v2-result"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="/dev/null"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_RUN_ID="merge-v2-result-test-$$"
mkdir -p "$ZBUILD_EVENTS_DIR"
: > "$ZBUILD_EVENTS_JSONL"

MERGE_MANIFEST="$REPO_ROOT/plugins/tool/merge/manifest.yaml"

# ─── SPEC-1: manifest provides declares result_contract:3, role, events ──────
print_test_section "SPEC-1: manifest provides declares result_contract:3, role:merge_executor, events:[plugin.result]"

_prov_rc="$(awk '/^provides:/{f=1} f && /result_contract:/{print $2; exit}' "$MERGE_MANIFEST" || echo '')"
assert_eq "[SPEC-1] manifest provides.result_contract is 3 (#2366)" "3" "$_prov_rc"

_prov_role="$(awk '/^provides:/{f=1} f && /^[[:space:]]*role:/{print $2; exit}' "$MERGE_MANIFEST" || echo '')"
assert_eq "[SPEC-1] manifest provides.role is merge_executor" "merge_executor" "$_prov_role"

_prov_ev="$(awk '/^provides:/{f=1} f && /plugin\.result/{print; exit}' "$MERGE_MANIFEST" || echo '')"
[[ -n "$_prov_ev" ]] \
    && assert_pass "[SPEC-1] manifest provides.events includes plugin.result" \
    || assert_fail "[SPEC-1] manifest provides.events includes plugin.result" "plugin.result absent"

# ─── SPEC-2: a contract-3 stage declares no verdict words (#2366) ───────────
print_test_section "SPEC-2: no valid_verdicts (#2366)"
assert_eq "[SPEC-2] manifest declares no valid_verdicts" "0" \
    "$(grep -v '^#' "$MERGE_MANIFEST" | grep -c 'valid_verdicts' || true)"

# ─── SPEC-24: tier_default:T0, no router: block ──────────────────────────────
print_test_section "SPEC-24: tier_default:T0 with no router: block"

_td="$(grep -m1 'tier_default:' "$MERGE_MANIFEST" | awk '{print $2}' || echo '')"
assert_eq "[SPEC-24] manifest tier_default is T0" "T0" "$_td"

_has_router="$(grep -v '^#' "$MERGE_MANIFEST" | grep -c '^[[:space:]]*router:' || true)"
assert_eq "[SPEC-24] manifest has no router: block" "0" "$_has_router"

# ─── SPEC-25: outputs.merge_result retains primary: true ─────────────────────
print_test_section "SPEC-25: outputs.merge_result retains primary: true"

_has_primary="$(grep -v '^#' "$MERGE_MANIFEST" | grep -c 'primary:[[:space:]]*true' || true)"
[[ "$_has_primary" -gt 0 ]] \
    && assert_pass "[SPEC-25] manifest has primary: true on result output" \
    || assert_fail "[SPEC-25] manifest has primary: true on result output" "missing"

# ─── SPEC-28: hooks has only run:, no cleanup: ───────────────────────────────
print_test_section "SPEC-28: hooks section has only run:, no cleanup:"

_has_cleanup="$(grep -v '^#' "$MERGE_MANIFEST" | grep -c '^[[:space:]]*cleanup:' || true)"
assert_eq "[SPEC-28] manifest hooks has no cleanup:" "0" "$_has_cleanup"

_has_run="$(grep -v '^#' "$MERGE_MANIFEST" | grep -c '^[[:space:]]*run:[[:space:]]*merge_run' || true)"
[[ "$_has_run" -gt 0 ]] \
    && assert_pass "[SPEC-28] manifest hooks has run: merge_run" \
    || assert_fail "[SPEC-28] manifest hooks has run: merge_run" "missing"

# ─── Plugin behavior setup ────────────────────────────────────────────────────
# shellcheck source=../../plugins/tool/merge/plugin.sh
source "$REPO_ROOT/plugins/tool/merge/plugin.sh"
# shellcheck source=../../scripts/lib/stage-result.sh
source "$REPO_ROOT/scripts/lib/stage-result.sh"

# _make_state <dir> [gate_verdict]
# Sets up a state dir with pipeline-state.json, review.json, and optional
# gate-aggregator-result.json. Prints path to pipeline-state.json.
# #2368: the engine says whether every loop passed (ZBUILD_RUN_LOOPS_PASSED);
# a helper records the word for its gate outcome beside the state file.
_loops() { cat "$(dirname "$1")/loops-passed" 2>/dev/null; }
_make_state() {
    local d="$1" gate="${2:-}"
    mkdir -p "$d/artifacts"
    printf '{"issue":1849,"branch":"zbuild/issue-1849-test"}\n' > "$d/pipeline-state.json"
    printf '{"schema_version":1,"verdict":"approve","summary":"ok"}\n' > "$d/artifacts/review.json"
    # gate-aggregator's result, by the engine's writer (#2366).
    [[ -n "$gate" ]] && \
        stage_result_write "$d/artifacts/gate-aggregator-result.json" "$gate" "gate roll-up" >/dev/null
    # The engine's index (lifecycle.sh exports ZBUILD_STAGE_INPUTS for every
    # dispatched stage, pr-delivery included) is the only way a declared input
    # reaches the plugin.
    if [[ -n "$gate" ]]; then
        printf '{"inputs":{"gate_aggregator_result":"%s"}}\n' "$d/artifacts/gate-aggregator-result.json" > "$d/stage-inputs.json"
    else
        printf '{"inputs":{}}\n' > "$d/stage-inputs.json"
    fi
    case "${gate:-}" in pass) printf yes ;; "") : ;; *) printf no ;; esac > "$d/loops-passed"
    printf '%s/pipeline-state.json' "$d"
}

# _mk_mocks <bindir> <branch> [push_rc] [create_rc]
# Creates mock git and gh executables in bindir.
# push_rc: exit code for git push (default 0)
# create_rc: exit code for gh pr create (default 0)
_mk_mocks() {
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
    checkout|fetch|config|branch|tag) exit 0 ;;
    push) [[ ${push_rc} -ne 0 ]] && echo "mock push error" >&2; exit ${push_rc} ;;
    ls-remote) echo ""; exit 0 ;;
    merge-base|symbolic-ref) echo ""; exit 0 ;;
    cat-file|show-ref) exit 0 ;;
    *) exit 0 ;;
esac
GITMOCK
    cat > "$bin/gh" <<GHMOCK
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
    "pr create") [[ ${create_rc} -ne 0 ]] && { echo "gh create error" >&2; exit ${create_rc}; }
                 echo "https://github.com/mock/repo/pull/1849"; exit 0 ;;
    "pr merge")  exit 0 ;;
    "pr list")   echo ""; exit 0 ;;
    *)           exit 0 ;;
esac
GHMOCK
    chmod +x "$bin/git" "$bin/gh"
}

# ─── SPEC-3: squash-merge success path ───────────────────────────────────────
print_test_section "SPEC-3: squash-merge success path — result_contract:3, verdict=pass, disposition=complete, reason"

_s3_dir="$TEST_TEMP_DIR/spec3"
_s3_sf="$(_make_state "$_s3_dir" "pass")"
_s3_art="$_s3_dir/artifacts"
_mk_mocks "$TEST_TEMP_DIR/bin3" "zbuild/issue-1849-test"

( PATH="$TEST_TEMP_DIR/bin3:$PATH" ZBUILD_RUN_LOOPS_PASSED="$(_loops "$_s3_sf")" ZBUILD_STAGE_INPUTS="$(dirname "$_s3_sf")/stage-inputs.json" merge_run "pr" "$_s3_sf" ) >/dev/null 2>&1; _s3_rc=$?

assert_file_exists "[SPEC-3] merge-result.json written on success" "$_s3_art/merge-result.json"
if [[ -f "$_s3_art/merge-result.json" ]]; then
    assert_eq "[SPEC-3] result_contract is 3" "3" \
        "$(jq -r '.result_contract // empty' "$_s3_art/merge-result.json" 2>/dev/null || true)"
    assert_eq "[SPEC-3] outcome is pass" "pass" \
        "$(jq -r '.outcome // empty' "$_s3_art/merge-result.json" 2>/dev/null || true)"
    assert_eq "[SPEC-3] no verdict or disposition field" "false" \
        "$(jq 'has("verdict") or has("disposition")' "$_s3_art/merge-result.json" 2>/dev/null || true)"
    _s3_reason="$(jq -r '.reason // empty' "$_s3_art/merge-result.json" 2>/dev/null || true)"
    [[ -n "$_s3_reason" ]] \
        && assert_pass "[SPEC-3] reason field is present" \
        || assert_fail "[SPEC-3] reason field is present" "absent"
fi

# ─── SPEC-4: fallback paths — result_contract:3, verdict=pass, data.mode=pr_fallback
print_test_section "SPEC-4: fallback paths — result_contract:3, verdict=pass, data.mode=pr_fallback"

# gate absent
_s4a_dir="$TEST_TEMP_DIR/spec4a"
_s4a_sf="$(_make_state "$_s4a_dir")"
_s4a_art="$_s4a_dir/artifacts"
_mk_mocks "$TEST_TEMP_DIR/bin4a" "zbuild/issue-1849-test"

( PATH="$TEST_TEMP_DIR/bin4a:$PATH" ZBUILD_RUN_LOOPS_PASSED="$(_loops "$_s4a_sf")" ZBUILD_STAGE_INPUTS="$(dirname "$_s4a_sf")/stage-inputs.json" merge_run "pr" "$_s4a_sf" ) >/dev/null 2>&1; _s4a_rc=$?

assert_file_exists "[SPEC-4] gate-absent: merge-result.json written" "$_s4a_art/merge-result.json"
if [[ -f "$_s4a_art/merge-result.json" ]]; then
    assert_eq "[SPEC-4] gate-absent: result_contract is 3" "3" \
        "$(jq -r '.result_contract // empty' "$_s4a_art/merge-result.json" 2>/dev/null || true)"
    assert_eq "[SPEC-4] gate-absent: outcome is pass" "pass" \
        "$(jq -r '.outcome // empty' "$_s4a_art/merge-result.json" 2>/dev/null || true)"
    assert_eq "[SPEC-4] gate-absent: data.mode is pr_fallback" "pr_fallback" \
        "$(jq -r '.data.mode // empty' "$_s4a_art/merge-result.json" 2>/dev/null || true)"
fi

# gate verdict=fail
_s4b_dir="$TEST_TEMP_DIR/spec4b"
_s4b_sf="$(_make_state "$_s4b_dir" "fail")"
_s4b_art="$_s4b_dir/artifacts"
_mk_mocks "$TEST_TEMP_DIR/bin4b" "zbuild/issue-1849-test"

( PATH="$TEST_TEMP_DIR/bin4b:$PATH" ZBUILD_RUN_LOOPS_PASSED="$(_loops "$_s4b_sf")" ZBUILD_STAGE_INPUTS="$(dirname "$_s4b_sf")/stage-inputs.json" merge_run "pr" "$_s4b_sf" ) >/dev/null 2>&1; _s4b_rc=$?

assert_file_exists "[SPEC-4] gate-fail: merge-result.json written" "$_s4b_art/merge-result.json"
if [[ -f "$_s4b_art/merge-result.json" ]]; then
    assert_eq "[SPEC-4] gate-fail: result_contract is 3" "3" \
        "$(jq -r '.result_contract // empty' "$_s4b_art/merge-result.json" 2>/dev/null || true)"
    assert_eq "[SPEC-4] gate-fail: outcome is pass" "pass" \
        "$(jq -r '.outcome // empty' "$_s4b_art/merge-result.json" 2>/dev/null || true)"
    assert_eq "[SPEC-4] gate-fail: data.mode is pr_fallback" "pr_fallback" \
        "$(jq -r '.data.mode // empty' "$_s4b_art/merge-result.json" 2>/dev/null || true)"
fi

# ─── SPEC-5: error paths — result_contract:3, verdict=error, disposition, reason
print_test_section "SPEC-5: error paths — result_contract:3, verdict=error, disposition, reason"

# branch is main
_s5a_dir="$TEST_TEMP_DIR/spec5a"
_s5a_sf="$(_make_state "$_s5a_dir" "pass")"
_s5a_art="$_s5a_dir/artifacts"
_mk_mocks "$TEST_TEMP_DIR/bin5a" "main"

( PATH="$TEST_TEMP_DIR/bin5a:$PATH" ZBUILD_RUN_LOOPS_PASSED="$(_loops "$_s5a_sf")" ZBUILD_STAGE_INPUTS="$(dirname "$_s5a_sf")/stage-inputs.json" merge_run "pr" "$_s5a_sf" ) >/dev/null 2>&1; _s5a_rc=$?

assert_file_exists "[SPEC-5] branch-is-main: merge-result.json written" "$_s5a_art/merge-result.json"
if [[ -f "$_s5a_art/merge-result.json" ]]; then
    assert_eq "[SPEC-5] branch-is-main: result_contract is 3" "3" \
        "$(jq -r '.result_contract // empty' "$_s5a_art/merge-result.json" 2>/dev/null || true)"
    assert_eq "[SPEC-5] branch-is-main: not finished: neither pass nor fail" "true" \
        "$(jq -r '(.outcome != null) and .outcome != "pass" and .outcome != "fail"' "$_s5a_art/merge-result.json" 2>/dev/null || true)"
    assert_eq "[SPEC-5] branch-is-main: no verdict or disposition field" "false" \
        "$(jq 'has("verdict") or has("disposition")' "$_s5a_art/merge-result.json" 2>/dev/null || true)"
    _s5a_rsn="$(jq -r '.reason // empty' "$_s5a_art/merge-result.json" 2>/dev/null || true)"
    [[ -n "$_s5a_rsn" ]] \
        && assert_pass "[SPEC-5] branch-is-main: reason present" \
        || assert_fail "[SPEC-5] branch-is-main: reason present" "absent"
fi

# push failure
_s5b_dir="$TEST_TEMP_DIR/spec5b"
_s5b_sf="$(_make_state "$_s5b_dir" "pass")"
_s5b_art="$_s5b_dir/artifacts"
_mk_mocks "$TEST_TEMP_DIR/bin5b" "zbuild/issue-1849-test" 1

( PATH="$TEST_TEMP_DIR/bin5b:$PATH" ZBUILD_RUN_LOOPS_PASSED="$(_loops "$_s5b_sf")" ZBUILD_STAGE_INPUTS="$(dirname "$_s5b_sf")/stage-inputs.json" merge_run "pr" "$_s5b_sf" ) >/dev/null 2>&1; _s5b_rc=$?

assert_file_exists "[SPEC-5] push-failure: merge-result.json written" "$_s5b_art/merge-result.json"
if [[ -f "$_s5b_art/merge-result.json" ]]; then
    assert_eq "[SPEC-5] push-failure: result_contract is 3" "3" \
        "$(jq -r '.result_contract // empty' "$_s5b_art/merge-result.json" 2>/dev/null || true)"
    assert_eq "[SPEC-5] push-failure: not finished: neither pass nor fail" "true" \
        "$(jq -r '(.outcome != null) and .outcome != "pass" and .outcome != "fail"' "$_s5b_art/merge-result.json" 2>/dev/null || true)"
    assert_eq "[SPEC-5] push-failure: no verdict or disposition field" "false" \
        "$(jq 'has("verdict") or has("disposition")' "$_s5b_art/merge-result.json" 2>/dev/null || true)"
    _s5b_rsn="$(jq -r '.reason // empty' "$_s5b_art/merge-result.json" 2>/dev/null || true)"
    [[ -n "$_s5b_rsn" ]] \
        && assert_pass "[SPEC-5] push-failure: reason present" \
        || assert_fail "[SPEC-5] push-failure: reason present" "absent"
fi

# gh pr create failure
_s5c_dir="$TEST_TEMP_DIR/spec5c"
_s5c_sf="$(_make_state "$_s5c_dir" "pass")"
_s5c_art="$_s5c_dir/artifacts"
_mk_mocks "$TEST_TEMP_DIR/bin5c" "zbuild/issue-1849-test" 0 1

( PATH="$TEST_TEMP_DIR/bin5c:$PATH" ZBUILD_RUN_LOOPS_PASSED="$(_loops "$_s5c_sf")" ZBUILD_STAGE_INPUTS="$(dirname "$_s5c_sf")/stage-inputs.json" merge_run "pr" "$_s5c_sf" ) >/dev/null 2>&1; _s5c_rc=$?

assert_file_exists "[SPEC-5] gh-failure: merge-result.json written" "$_s5c_art/merge-result.json"
if [[ -f "$_s5c_art/merge-result.json" ]]; then
    assert_eq "[SPEC-5] gh-failure: result_contract is 3" "3" \
        "$(jq -r '.result_contract // empty' "$_s5c_art/merge-result.json" 2>/dev/null || true)"
    assert_eq "[SPEC-5] gh-failure: not finished: neither pass nor fail" "true" \
        "$(jq -r '(.outcome != null) and .outcome != "pass" and .outcome != "fail"' "$_s5c_art/merge-result.json" 2>/dev/null || true)"
    assert_eq "[SPEC-5] gh-failure: no verdict or disposition field" "false" \
        "$(jq 'has("verdict") or has("disposition")' "$_s5c_art/merge-result.json" 2>/dev/null || true)"
    _s5c_rsn="$(jq -r '.reason // empty' "$_s5c_art/merge-result.json" 2>/dev/null || true)"
    [[ -n "$_s5c_rsn" ]] \
        && assert_pass "[SPEC-5] gh-failure: reason present" \
        || assert_fail "[SPEC-5] gh-failure: reason present" "absent"
fi

# ─── SPEC-6: no exit path returns rc=2 ───────────────────────────────────────
print_test_section "SPEC-6: all exit paths return rc ∈ {0,1} — no rc=2"

assert_eq "[SPEC-6] success path rc=0" "0" "$_s3_rc"
assert_eq "[SPEC-6] gate-absent fallback rc=0" "0" "$_s4a_rc"
assert_eq "[SPEC-6] gate-fail fallback rc=0" "0" "$_s4b_rc"
assert_eq "[SPEC-6] branch-is-main error rc=1" "1" "$_s5a_rc"
assert_eq "[SPEC-6] push-failure error rc=1" "1" "$_s5b_rc"
assert_eq "[SPEC-6] gh-failure error rc=1" "1" "$_s5c_rc"

# ─── SPEC-7: the engine's word decides the merge (#2368) ─────────────────────
print_test_section "SPEC-7: merge reads ZBUILD_RUN_LOOPS_PASSED, not another stage's result"

# SPEC-7a: every loop passed → the merge path is taken.
_s7a_dir="$TEST_TEMP_DIR/spec7a"
_s7a_sf="$(_make_state "$_s7a_dir")"
_s7a_art="$_s7a_dir/artifacts"
_mk_mocks "$TEST_TEMP_DIR/bin7a" "zbuild/issue-1849-test"
( PATH="$TEST_TEMP_DIR/bin7a:$PATH" ZBUILD_RUN_LOOPS_PASSED=yes \
  merge_run "pr" "$_s7a_sf" ) >/dev/null 2>&1; _s7a_rc=$?
assert_eq "[SPEC-7] loops passed → merge path taken (not pr_fallback)" "pass merge" \
    "$(jq -r '"\(.outcome // "") \(if .data.mode == "pr_fallback" then "pr_fallback" else "merge" end)"' "$_s7a_art/merge-result.json" 2>/dev/null)"

# SPEC-7b: the word is not set → the PR fallback, fail-closed.
_s7b_dir="$TEST_TEMP_DIR/spec7b"
_s7b_sf="$(_make_state "$_s7b_dir")"
_s7b_art="$_s7b_dir/artifacts"
_mk_mocks "$TEST_TEMP_DIR/bin7b" "zbuild/issue-1849-test"
( unset ZBUILD_RUN_LOOPS_PASSED; PATH="$TEST_TEMP_DIR/bin7b:$PATH" \
  merge_run "pr" "$_s7b_sf" ) >/dev/null 2>&1; _s7b_rc=$?
assert_eq "[SPEC-7] word not set → PR fallback" \
    "pr_fallback" "$(jq -r '.data.mode // empty' "$_s7b_art/merge-result.json" 2>/dev/null || true)"
assert_eq "[SPEC-7] plugin.sh constructs no gate-aggregator-result.json path" "0" \
    "$(grep -v '^[[:space:]]*#' "$REPO_ROOT/plugins/tool/merge/plugin.sh" | grep -cF 'gate-aggregator-result.json' || true)"

# ─── SPEC-29: PR fallback whose pr_open_run fails ─────────────────────────────
print_test_section "SPEC-29: a PR fallback that fails is reported as a failure"
_s29_dir="$TEST_TEMP_DIR/spec29"
_s29_sf="$(_make_state "$_s29_dir")"          # gate absent → fallback
_mk_mocks "$TEST_TEMP_DIR/bin29" "zbuild/issue-1849-test" 0 1   # gh pr create fails
( PATH="$TEST_TEMP_DIR/bin29:$PATH" ZBUILD_RUN_LOOPS_PASSED="$(_loops "$_s29_dir/x")" ZBUILD_STAGE_INPUTS="$_s29_dir/stage-inputs.json" \
  merge_run "pr" "$_s29_sf" ) >/dev/null 2>&1; _s29_rc=$?
assert_eq "[SPEC-29] rc=1" "1" "$_s29_rc"
assert_eq "[SPEC-29] merge-result.json is not a pass" "true" \
    "$(jq -r '.outcome != "pass"' "$_s29_dir/artifacts/merge-result.json" 2>/dev/null || true)"
assert_eq "[SPEC-29] …carrying pr-open's own outcome" \
    "$(jq -r '.outcome // empty' "$_s29_dir/artifacts/pr-result.json" 2>/dev/null || echo none)" \
    "$(jq -r '.outcome // empty' "$_s29_dir/artifacts/merge-result.json" 2>/dev/null || true)"

# ─── SPEC-30: outward failures are `unavailable` ──────────────────────────────
print_test_section "SPEC-30: a failed outward action reports unavailable"
assert_eq "[SPEC-30] push failure → unavailable" "unavailable" \
    "$(jq -r '.outcome // empty' "$_s5b_art/merge-result.json" 2>/dev/null || true)"
assert_eq "[SPEC-30] gh pr create failure → unavailable" "unavailable" \
    "$(jq -r '.outcome // empty' "$_s5c_art/merge-result.json" 2>/dev/null || true)"
_s30_dir="$TEST_TEMP_DIR/spec30"
_s30_sf="$(_make_state "$_s30_dir" "pass")"
_mk_mocks "$TEST_TEMP_DIR/bin30" "zbuild/issue-1849-test"
sed -i.bak 's|"pr merge")  exit 0 ;;|"pr merge")  exit 1 ;;|' "$TEST_TEMP_DIR/bin30/gh"
( PATH="$TEST_TEMP_DIR/bin30:$PATH" ZBUILD_RUN_LOOPS_PASSED="$(_loops "$_s30_dir/x")" ZBUILD_STAGE_INPUTS="$_s30_dir/stage-inputs.json" \
  merge_run "pr" "$_s30_sf" ) >/dev/null 2>&1
assert_eq "[SPEC-30] gh pr merge failure → unavailable" "unavailable" \
    "$(jq -r '.outcome // empty' "$_s30_dir/artifacts/merge-result.json" 2>/dev/null || true)"

# ─── Teardown ─────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
exit $((FAIL > 0))
