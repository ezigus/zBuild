#!/usr/bin/env bash
# tests/integration/engine-run-branch-test.sh — the engine owns the run's branch
# and starting commit (#2367, ADR-052, ADR-050 §10).
#
# Why: intake chose the branch and wrote intake-branch.txt and
# intake-baseline-ref.txt, which build, pr, merge and the engine's own save step
# opened — the engine depending on a stage. Hydrate runs before intake, so in
# #1801 the end of hydrate pushed main over the issue branch: nothing had set
# the starting commit yet.
#
#   E1 [change] before the first stage runs, HEAD is on zbuild/issue-<n> and
#               every stage gets ZBUILD_RUN_BRANCH and ZBUILD_RUN_START_COMMIT
#   E2 [change] the template's `branch:` names the branch
#   E3 [change] the repository's .zbuild/branch overrides the template
#   E4 [guard]  ZBUILD_WORKSPACE_BRANCH (the CI setting) overrides both
#   E5 [change] no stage writes intake-branch.txt or intake-baseline-ref.txt
#   E6 [change] a branch that cannot be set up stops the run before any stage:
#               a remote that cannot be fetched leaves it resumable
#               (interrupted), a bad name fails it
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER="$REPO_ROOT/core/pipeline/runner.sh"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "the engine owns the run's branch and starting commit (#2367)"
setup_test_env "engine-run-branch"

_ZB_ID="$(zb_test_issue)"
export ZBUILD_CONTRACT_VALIDATOR=warn
export ZBUILD_RUN_ROOT="$TEST_TEMP_DIR/runroot"
PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
export ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT"
HOME_DIR="$TEST_TEMP_DIR/home"; mkdir -p "$HOME_DIR/.zbuild"
mock_plugin_factory "intake" "agent" 0 "" "" >/dev/null
mock_plugin_factory "build"  "agent" 0 "" "" >/dev/null

# The first stage records what it was given, and changes nothing.
SEEN="$TEST_TEMP_DIR/seen"
cat > "$PLUGINS_ROOT/agent/intake/plugin.sh" <<EOF
intake_run() {
    {
        printf 'head=%s\n' "\$(git -C "\${ZBUILD_REPO_ROOT:-.}" symbolic-ref --short HEAD 2>/dev/null)"
        printf 'branch=%s\n' "\${ZBUILD_RUN_BRANCH:-}"
        printf 'start=%s\n' "\${ZBUILD_RUN_START_COMMIT:-}"
    } > "$SEEN"
    $(mock_result_line intake)
    return 0
}
EOF

run_pipeline() {
    local target="$1" run_id="$2"; shift 2
    : > "$SEEN"
    ( cd "$target" && env -u ZBUILD_STATE_DIR -u ZBUILD_STATE_ROOT -u ZBUILD_STATE_FILE \
        -u ZBUILD_EVENTS_DIR -u ZBUILD_EVENTS_JSONL  -u ZBUILD_REPO_ROOT \
        -u ZBUILD_WORKSPACE_BRANCH -u ZBUILD_RUN_BRANCH -u ZBUILD_RUN_START_COMMIT \
        ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" \
        ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
        ZBUILD_RUN_ROOT="$ZBUILD_RUN_ROOT" \
        ZBUILD_CYCLES_ENABLED=0 ZBUILD_CONTRACT_VALIDATOR=warn \
        ZBUILD_RUN_ID="$run_id" HOME="$HOME_DIR" PATH="$PATH" "$@" \
        bash "$RUNNER" --issue "$_ZB_ID" --no-resume --template runner-state-dir-minimal ) \
        > "$TEST_TEMP_DIR/runner-$run_id.log" 2>&1
}
_seen() { sed -n "s/^$1=//p" "$SEEN" 2>/dev/null; }
_state_dir_for() {
    HOME="$HOME_DIR" env -u ZBUILD_STATE_DIR -u ZBUILD_STATE_ROOT -u ZBUILD_DATA_ROOT \
        bash -c 'source "$1/scripts/lib/test-helpers.sh" >/dev/null 2>&1
                 zb_expected_run_state_dir "$2" "$3" "" "$4"' _ \
        "$REPO_ROOT" "$1" "$_ZB_ID" "$2"
}

print_test_section "E1: the branch and starting commit are set before the first stage"
T1="$(setup_git_temp_repo t1)"; install_template_overlay "$T1" runner-state-dir-minimal
_start="$(git -C "$T1" rev-parse HEAD)"
run_pipeline "$T1" run-e1
assert_eq "[E1] the first stage is already on the run's branch" "zbuild/issue-$_ZB_ID" "$(_seen head)"
assert_eq "[E1] ...and is told its name" "zbuild/issue-$_ZB_ID" "$(_seen branch)"
assert_eq "[E1] ...and the commit the run started from" "$_start" "$(_seen start)"

print_test_section "E2: the template names the branch"
_tpl="$TEST_TEMP_DIR/branch-tpl.yaml"
sed 's|^branch:.*|branch: work/{key}|' "$REPO_ROOT/config/templates/simple.yaml" > "$_tpl"
assert_eq "[E2] the shipped template says the default" "zbuild/{key}" \
    "$(bash -c 'source "$1/scripts/lib/helpers.sh"; source "$1/core/pipeline/template.sh"
                load_template "$1/config/templates/simple.yaml" >/dev/null 2>&1; template_branch' _ "$REPO_ROOT")"
assert_eq "[E2] the template's branch: is used" "work/issue-$_ZB_ID" \
    "$(bash -c 'source "$1/scripts/lib/helpers.sh"; source "$1/core/pipeline/template.sh"
                source "$1/scripts/lib/run-branch-setup.sh"
                load_template "$2" >/dev/null 2>&1
                zbuild_run_branch_name "$3" "" "$(template_branch)" ""' _ "$REPO_ROOT" "$_tpl" "$_ZB_ID")"
T2="$(setup_git_temp_repo t2)"; install_template_overlay "$T2" runner-state-dir-minimal

print_test_section "E3: .zbuild/branch overrides the template"
printf 'mine/{key}\n' > "$T2/.zbuild/branch"
run_pipeline "$T2" run-e3
assert_eq "[E3] the repository's .zbuild/branch is used" "mine/issue-$_ZB_ID" "$(_seen branch)"

print_test_section "E4: ZBUILD_WORKSPACE_BRANCH overrides both"
run_pipeline "$T2" run-e4 ZBUILD_WORKSPACE_BRANCH="ci/issue-$_ZB_ID-ci"
assert_eq "[E4] the CI setting is used" "ci/issue-$_ZB_ID-ci" "$(_seen branch)"

print_test_section "E5: no stage's files hold the branch or starting commit"
_sd="$(_state_dir_for "$T1" run-e1)"
assert_file_not_exists "[E5] no intake-branch.txt" "$_sd/intake-branch.txt"
assert_file_not_exists "[E5] no intake-baseline-ref.txt" "$_sd/intake-baseline-ref.txt"
if grep -qE 'intake-(branch|baseline-ref)\.txt' "$REPO_ROOT/plugins/agent/intake/manifest.yaml"; then
    assert_fail "[E5] intake declares no branch or baseline output" "found in its manifest"
else
    assert_pass "[E5] intake declares no branch or baseline output"
fi

print_test_section "E6: a branch that cannot be set up stops the run"
T6="$(setup_git_temp_repo t6)"; install_template_overlay "$T6" runner-state-dir-minimal
git -C "$T6" remote add origin "$TEST_TEMP_DIR/no-such-remote.git"
git -C "$T6" update-ref refs/remotes/origin/zb/fetch-fails HEAD
run_pipeline "$T6" run-e6a ZBUILD_WORKSPACE_BRANCH=zb/fetch-fails; _rc6a=$?
assert_eq "[E6] no stage ran" "" "$(_seen branch)"
assert_eq "[E6] the run stops" "1" "$([[ $_rc6a -ne 0 ]] && echo 1 || echo 0)"
assert_eq "[E6] a remote that cannot be fetched leaves the run resumable" "interrupted" \
    "$(jq -r '.status' "$(_state_dir_for "$T6" run-e6a)/pipeline-state.json" 2>/dev/null)"
assert_contains "[E6] ...and says the remote is not responding" \
    "$(cat "$TEST_TEMP_DIR/runner-run-e6a.log")" "the git remote is not responding"
run_pipeline "$T6" run-e6b ZBUILD_WORKSPACE_BRANCH=bad..name
assert_eq "[E6] a bad branch name fails the run" "failed" \
    "$(jq -r '.status' "$(_state_dir_for "$T6" run-e6b)/pipeline-state.json" 2>/dev/null)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
