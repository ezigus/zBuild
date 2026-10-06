#!/usr/bin/env bash
# tests/unit/prior-work-reuse-contract-test.sh — the ADR-050 statements that
# lived only in prose until #2324 (CLAUDE.md: a rule only in an ADR is a
# missing test).
#
# C1 [§1]  the engine's persistence names no stage: whatever files sit in the
#          artifact area round-trip through snapshot → restore, including names
#          no stage has, and the persistence code names no plugin
# C3 [§3]  a deterministic gate never reuses a prior verdict: no gate plugin
#          reads prior work, and design-gate / gate-aggregator judge the
#          current state even when the restored prior run says "pass"
# C5 [impl notes] pr-open reuses an existing open PR: it edits that PR and
#          never runs `gh pr create`; the result says status=updated
# C6 [#2111] a run that ended aborted on the rate limit persists like any
#          other: persist pushes the state branch; the daemon's completion
#          comment names the reset time and says to re-add the label
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/state/artifact-persist.sh
source "$REPO_ROOT/core/state/artifact-persist.sh"

print_test_header "ADR-050 prior-work reuse contract (#2324)"
setup_test_env "prior-work-reuse-contract"
unset ZBUILD_RESTORED_ARTIFACTS_DIR ZBUILD_CYCLE_FEEDBACK_DIR ZBUILD_CYCLE_ITER ZBUILD_STAGE_INPUTS 2>/dev/null || true

_ZB_ID1="$(zb_test_issue)"
_ZB_ID2="$(zb_test_issue)"

# Captured so the suite can prove it wrote no state ref into the real checkout.
_REFS_BEFORE="$(git -C "$REPO_ROOT" for-each-ref --format='%(refname)' 'refs/heads/zbuild/state/*' 2>/dev/null | sort || true)"

# A throwaway repo with a bare origin (a real push needs a real remote).
_mk_repo() {
    local remote="$TEST_TEMP_DIR/$1-remote.git" repo="$TEST_TEMP_DIR/$1"
    git init -q --bare "$remote" 2>/dev/null
    mkdir -p "$repo"
    (
        cd "$repo" || exit 1
        git init -q -b main .
        git config user.email t@e.st; git config user.name t
        git remote add origin "$remote"
        : > f; git add f; git commit -q -m init
        git push -q -u origin main
    ) >/dev/null 2>&1
    printf '%s' "$repo"
}

# ─── C1 §1: the engine snapshots a directory, never a stage ─────────────────
print_test_section "C1 §1: persistence is stage-agnostic"
_R1="$(_mk_repo c1)"
_S1="$TEST_TEMP_DIR/c1-state"
mkdir -p "$_S1/artifacts/zz-group"
printf 'made-up stage\n' > "$_S1/artifacts/zz-not-a-stage-result.json"
printf 'member\n' > "$_S1/artifacts/zz-group/member.json"
printf 'a design\n' > "$_S1/artifacts/design.md"
_artifact_persist_snapshot "$_S1" "$_ZB_ID1" "$_R1" >/dev/null 2>&1
_artifact_persist_restore "$_ZB_ID1" "$TEST_TEMP_DIR/c1-restored" "$_R1" >/dev/null 2>&1
_c1_got=""
for _f in zz-not-a-stage-result.json zz-group/member.json design.md; do
    cmp -s "$_S1/artifacts/$_f" "$TEST_TEMP_DIR/c1-restored/artifacts/$_f" && _c1_got+="$_f "
done
assert_eq "[C1] every file round-trips, including names no stage has" \
    "zz-not-a-stage-result.json zz-group/member.json design.md " "$_c1_got"

# The persistence code: the library, and the runner's stage-boundary snapshot.
_c1_code="$(grep -vE '^[[:space:]]*#' "$REPO_ROOT/core/state/artifact-persist.sh")"
_c1_code+=$'\n'"$(awk '/^_runner_snapshot_artifacts\(\) \{/{on=1} on{print} on&&/^\}/{exit}' \
    "$REPO_ROOT/core/pipeline/runner.sh" | grep -vE '^[[:space:]]*#')"
if [[ "$_c1_code" != *"_artifact_persist_snapshot"* ]]; then
    assert_fail "[C1] premise: the runner's snapshot function was extracted" "not found"
fi
_c1_named=""
for _d in "$REPO_ROOT"/plugins/*/*/; do
    _id="$(basename "$_d")"
    # A stage named as a quoted word, a result file, or an artifact path.
    if grep -qE "([\"'])${_id}\\1|${_id}-result|artifacts/${_id}([./]|\$)" <<< "$_c1_code"; then
        _c1_named+="$_id "
    fi
done
assert_eq "[C1] the persistence code names no stage" "" "$_c1_named"

# ─── C3 §3: gates re-evaluate; they never reuse a prior verdict ─────────────
print_test_section "C3 §3: a deterministic gate never reuses a prior verdict"
_c3_readers=""
for _g in tool/test tool/shape-floor agent/spec-acceptance tool/secret-scan \
          tool/gate-aggregator tool/design-gate agent/review-aggregator; do
    [[ -d "$REPO_ROOT/plugins/$_g" ]] || { _c3_readers+="$_g(missing) "; continue; }
    while IFS= read -r _f; do
        if grep -qE '_read_prior_output|ZBUILD_RESTORED_ARTIFACTS_DIR|restored-artifacts|prior-output-reader' "$_f"; then
            _c3_readers+="${_f#"$REPO_ROOT"/} "
        fi
    done < <(find "$REPO_ROOT/plugins/$_g" -name '*.sh' -not -path '*/tests/*')
done
assert_eq "[C3] no gate plugin reads prior work" "" "$_c3_readers"

# A restored prior run that passed everything, next to a current state that fails.
_C3="$TEST_TEMP_DIR/c3/state"; _C3R="$TEST_TEMP_DIR/c3/restored/artifacts"
mkdir -p "$_C3/artifacts" "$_C3R"
printf '{}' > "$_C3/pipeline-state.json"
printf '# Design\n\nno scope, no acceptance\n' > "$_C3/artifacts/design.md"
printf '# Design\n\n```scope\nfoo.sh\n```\n' > "$_C3R/design.md"
for _rf in design-gate-result.json test-results.json shape-floor-result.json acceptance-gate-result.json \
           lint-result.json coverage-result.json mutation-result.json secret-scan-result.json; do
    printf '{"result_contract":2,"verdict":"pass","disposition":"complete","reason":"prior run"}\n' > "$_C3R/$_rf"
done
( source "$REPO_ROOT/plugins/tool/design-gate/plugin.sh" >/dev/null 2>&1
  emit_event() { :; }; eb_emit_event() { :; }
  export ZBUILD_RESTORED_ARTIFACTS_DIR="$_C3R"
  design_gate_run design-gate "$_C3/pipeline-state.json" ) >/dev/null 2>&1 || true
assert_eq "[C3] design-gate fails the current design despite a restored pass" "fail" \
    "$(jq -r '.verdict // empty' "$_C3/artifacts/design-gate-result.json" 2>/dev/null)"
( source "$REPO_ROOT/plugins/tool/gate-aggregator/plugin.sh" >/dev/null 2>&1
  eb_emit_event() { :; }
  unset ZBUILD_CYCLE_ID
  export ZBUILD_RESTORED_ARTIFACTS_DIR="$_C3R"
  gate_aggregator_run gate-aggregator "$_C3/pipeline-state.json" ) >/dev/null 2>&1 || true
assert_eq "[C3] gate-aggregator fails when this run has no gate results, whatever the prior run said" "fail" \
    "$(jq -r '.verdict // empty' "$_C3/artifacts/gate-aggregator-result.json" 2>/dev/null)"

# ─── C5: pr-open reuses the existing PR ─────────────────────────────────────
print_test_section "C5: pr-open updates an existing PR instead of opening a second"
_GH_LOG="$TEST_TEMP_DIR/gh-calls"; : > "$_GH_LOG"; export _GH_LOG
_C5="$TEST_TEMP_DIR/c5"; mkdir -p "$_C5/artifacts"
printf '{"issue":1849,"branch":"zbuild/issue-1849-test"}\n' > "$_C5/pipeline-state.json"
printf '{"schema_version":1,"verdict":"approve","summary":"ok"}\n' > "$_C5/artifacts/review.json"
(
    export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events" ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
    mkdir -p "$ZBUILD_EVENTS_DIR"
    # shellcheck source=../../plugins/tool/pr-open/plugin.sh
    source "$REPO_ROOT/plugins/tool/pr-open/plugin.sh"
    git() { [[ "${1:-} ${2:-}" == "rev-parse --abbrev-ref" ]] && echo "zbuild/issue-1849-test"; return 0; }
    gh() {
        printf '%s\n' "$*" >> "$_GH_LOG"
        case "${1:-} ${2:-}" in
            "pr list")   echo "1849" ;;
            "pr view")   echo "https://github.com/mock/repo/pull/1849" ;;
            "pr create") echo "https://github.com/mock/repo/pull/9999" ;;
            *) return 0 ;;
        esac
    }
    export -f git gh
    _pr_open_run_inner "$_C5/artifacts/review.json" "$_C5/pipeline-state.json" "$_C5/artifacts/pr-result.json" 1849
) >/dev/null 2>&1 || true
assert_eq "[C5] the result says the PR was updated" "updated 1849" \
    "$(jq -r '"\(.data.status) \(.data.pr_number)"' "$_C5/artifacts/pr-result.json" 2>/dev/null)"
if grep -q '^pr edit 1849' "$_GH_LOG"; then
    assert_pass "[C5] the existing PR is edited"
else
    assert_fail "[C5] the existing PR is edited" "calls: $(tr '\n' ';' < "$_GH_LOG")"
fi
# review #2336: the lookup asks only for OPEN PRs; a closed one must not be reused.
if grep -q '^pr list .*--state open' "$_GH_LOG"; then
    assert_pass "[C5] the existing-PR lookup asks only for open PRs"
else
    assert_fail "[C5] the existing-PR lookup asks only for open PRs" "calls: $(tr '\n' ';' < "$_GH_LOG")"
fi
if grep -q '^pr create' "$_GH_LOG"; then
    assert_fail "[C5] no second PR is opened" "gh pr create was called"
else
    assert_pass "[C5] no second PR is opened"
fi

# ─── C6 #2111: a rate-limited run persists, and the daemon says when ────────
print_test_section "C6 #2111: an aborted, rate-limited run persists like any other"
# shellcheck source=../../plugins/tool/persist/plugin.sh
source "$REPO_ROOT/plugins/tool/persist/plugin.sh" >/dev/null 2>&1
_R6="$(_mk_repo c6)"
_S6="$TEST_TEMP_DIR/c6-state"; mkdir -p "$_S6/artifacts"
printf 'plan\n' > "$_S6/artifacts/plan.json"
jq -n --argjson i "$_ZB_ID2" '{issue:$i,status:"aborted",reason:"llm_rate_limited"}' > "$_S6/pipeline-state.json"
( cd "$_R6" && emit_event() { :; } && ZBUILD_ISSUE_NUMBER="$_ZB_ID2" ZBUILD_STATE_DIR="$_S6" \
    ZBUILD_ARTIFACT_DIR="$_S6/artifacts" persist_run persist "$_S6/pipeline-state.json" ) >/dev/null 2>&1 || true
_c6_remote="$(git -C "$_R6" ls-remote --heads origin "refs/heads/zbuild/state/issue-$_ZB_ID2" 2>/dev/null || true)"
if [[ -n "$_c6_remote" ]]; then
    assert_pass "[C6] the state branch reaches origin after a rate-limit abort"
else
    assert_fail "[C6] the state branch reaches origin after a rate-limit abort" "not on origin"
fi

# The daemon's completion step, run as written in the workflow.
_c6_step="$(awk '
    /- name: Post run-completion comment/ {found=1; next}
    found && /^[[:space:]]+run: \|/ {match($0, /^[[:space:]]+/); ind=RLENGTH; inrun=1; next}
    inrun { if ($0 ~ /^[[:space:]]*$/) {print; next}
            match($0, /^[[:space:]]+/); if (RLENGTH <= ind) exit; print substr($0, ind + 3) }
' "$REPO_ROOT/.github/workflows/zbuild-daemon.yml")"
_c6_step="${_c6_step//\$\{\{ github.repository \}\}/o/r}"
# review #2336: the extraction depends on the step's indentation. If the YAML is
# ever reformatted, fail here, not on text that happens to match.
assert_contains "[C6] fixture: the completion step was read whole" "$_c6_step" 'ABORT_REASON" == "llm_rate_limited"' 
_c6_body="$TEST_TEMP_DIR/c6-body"
(
    gh() { while [[ $# -gt 0 ]]; do [[ "$1" == "--body" ]] && printf '%s' "$2" > "$_c6_body"; shift; done; }
    export PIPELINE_RESULT=failure ABORT_REASON=llm_rate_limited ABORT_DETAIL="resets 3pm (UTC)" \
        ISSUE_NUMBER=7 RUN_URL=https://example.invalid/run
    eval "$_c6_step"
) >/dev/null 2>&1 || true
_c6_text="$(cat "$_c6_body" 2>/dev/null)"
assert_contains "[C6] the completion comment names the reset time" "$_c6_text" "resets 3pm (UTC)"
assert_contains "[C6] ...and says to re-add the label to resume" "$_c6_text" 're-add `zbuild-run`'

# ─── guard: nothing leaked into the real checkout ───────────────────────────
_REFS_AFTER="$(git -C "$REPO_ROOT" for-each-ref --format='%(refname)' 'refs/heads/zbuild/state/*' 2>/dev/null | sort || true)"
assert_eq "[guard] no state ref was written into REPO_ROOT" "$_REFS_BEFORE" "$_REFS_AFTER"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
