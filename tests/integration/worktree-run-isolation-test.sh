#!/usr/bin/env bash
# tests/integration/worktree-run-isolation-test.sh
# The engine owns the per-run worktree (ADR-052, #1640).
#
# The regression this exists for: #888 had INTAKE create the worktree and cd into
# it. That cd and its `export ZBUILD_REPO_ROOT` die with intake's dispatch
# subshell, so every LATER stage fell back to `git rev-parse --show-toplevel` from
# the runner's untouched CWD — the main checkout, on whatever branch it held. The
# build stage then committed there. Nothing refused and nothing warned; a run that
# died before `pr_open` reported nothing at all (#1640: 3h49m of CI work lost, and
# a stray commit landed on `main` locally).
#
# Why this file must drive the RUNNER and not a plugin: #888's own coverage called
# _intake_create_workspace_branch directly and asserted in the same shell, where
# intake's export is still visible. That shape cannot see this defect. Every case
# below dispatches at least TWO stages through the real runner, which is the only
# way stage N+1's view of the tree is ever observed.
#
# SPEC-1: after a fresh two-stage run, the main checkout's HEAD is unmoved
# SPEC-2: after a fresh two-stage run, the main checkout's BRANCH is unmoved
# SPEC-3a: the second stage's commit lands on the work branch, in the run's worktree
# SPEC-3b: the second stage RESOLVES its repo root to the worktree (the merge-base tell)
# SPEC-4: the engine records the worktree it entered, outside the target repo
# SPEC-5: a run that FAILS before any pr stage still leaves the main checkout intact
# SPEC-6: ZBUILD_NO_WORKTREE=1 still works in place (the opt-out is unchanged)
# SPEC-7: a resumed run lands in the worktree its earlier stages worked in
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER="$REPO_ROOT/core/pipeline/runner.sh"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "engine-owned per-run worktree (ADR-052, #1640)"
setup_test_env "worktree-run-isolation"
export ZBUILD_CONTRACT_VALIDATOR=warn
# Keep worktrees in the sandbox rather than the developer's real ~/.zbuild.
export ZBUILD_RUN_ROOT="$TEST_TEMP_DIR/runroot"

PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
export ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT"
HOME_DIR="$TEST_TEMP_DIR/home"; mkdir -p "$HOME_DIR/.zbuild"

# Two-leaf roster (intake → build). Two dispatched stages is the whole point: one
# stage cannot exhibit a defect that only appears when the NEXT stage runs.
TARGET="$(setup_git_temp_repo target)"
install_template_overlay "$TARGET" runner-state-dir-minimal
mock_plugin_factory "intake" "agent" 0 "" "" >/dev/null
mock_plugin_factory "build"  "agent" 0 "" "" >/dev/null

WORK_BRANCH="zbuild/issue-1640-wt"

# Stage 1 stub — stands in for intake's branch checkout. It does exactly what the
# real plugin does (checkout in whatever tree it is standing in) and, crucially,
# knows NOTHING about worktrees: under ADR-052 it must not have to.
_write_intake_stub() {
    cat > "$PLUGINS_ROOT/agent/intake/plugin.sh" <<EOF
intake_run() {
    git checkout -q -b "$WORK_BRANCH" >/dev/null 2>&1 || return 2
    printf '%s\n' "$WORK_BRANCH" > "\${ZBUILD_STATE_DIR}/intake-branch.txt"
    return 0
}
EOF
}

# Stage 2 stub — stands in for the build plugin's commit. The repo_root line is
# copied verbatim from plugins/agent/build/plugin.sh: it is the exact expression
# that resolved to the main checkout in #1640, so a stub that resolved the tree
# any other way would not be reproducing the bug.
# <rc> lets a case make the run FAIL here, before any later stage could notice.
_write_build_stub() {
    local rc="${1:-0}"
    cat > "$PLUGINS_ROOT/agent/build/plugin.sh" <<EOF
build_run() {
    local repo_root="\${ZBUILD_REPO_ROOT:-\$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
    printf 'work\n' > "\$repo_root/built.txt"
    git -C "\$repo_root" add -A >/dev/null 2>&1
    git -C "\$repo_root" -c user.email=p@l -c user.name=zbuild-pipeline \
        commit -qm "build stage output" >/dev/null 2>&1
    printf '%s\n' "\$repo_root" > "\${ZBUILD_STATE_DIR}/build-repo-root.txt"
    return $rc
}
EOF
}

# run_pipeline <run_id> [extra env KEY=VAL ...] — a default-state run rooted at
# HOME_DIR, CWD = the target repo (as an operator or CI runner would invoke it).
# Deliberately does NOT toggle errexit: SPEC-5 drives a run that MUST fail, and a
# `set -e` here would kill the test file on the very case it exists to assert.
run_pipeline() {
    local run_id="$1"; shift
    ( cd "$TARGET" && env -u ZBUILD_STATE_DIR -u ZBUILD_STATE_ROOT -u ZBUILD_STATE_FILE \
        -u ZBUILD_EVENTS_DIR -u ZBUILD_EVENTS_JSONL -u ZBUILD_EVENTS_DB -u ZBUILD_REPO_ROOT \
        ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" \
        ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
        ZBUILD_RUN_ROOT="$ZBUILD_RUN_ROOT" \
        ZBUILD_CYCLES_ENABLED=0 ZBUILD_CONTRACT_VALIDATOR=warn \
        ZBUILD_RUN_ID="$run_id" HOME="$HOME_DIR" PATH="$PATH" "$@" \
        bash "$RUNNER" --issue 1640 --no-resume --template runner-state-dir-minimal ) >/dev/null 2>&1
    return $?
}

# #141: derived, not pinned — this file tests worktree ISOLATION, not the
# layout shape, and the per-run state dir now nests under the run's issue.
_state_dir_for() {
    HOME="$HOME_DIR" env -u ZBUILD_STATE_DIR -u ZBUILD_STATE_ROOT -u ZBUILD_DATA_ROOT \
        bash -c 'source "$1/scripts/lib/test-helpers.sh" >/dev/null 2>&1
                 zb_expected_run_state_dir "$2" 1640 "" "$3"' _ \
        "$REPO_ROOT" "$TARGET" "$1"
}
_main_head()     { git -C "$TARGET" rev-parse HEAD 2>/dev/null; }
_main_branch()   { git -C "$TARGET" rev-parse --abbrev-ref HEAD 2>/dev/null; }

# ── SPEC-1..4: a fresh run works in its own tree, main checkout untouched ────
_write_intake_stub
_write_build_stub 0
_BEFORE_HEAD="$(_main_head)"
_BEFORE_BRANCH="$(_main_branch)"
run_pipeline "run-fresh"; _rc_fresh=$?
SD_FRESH="$(_state_dir_for run-fresh)"

assert_eq "[SPEC-1] the main checkout's HEAD is unmoved by a full run" \
    "$_BEFORE_HEAD" "$(_main_head)"
assert_eq "[SPEC-2] the main checkout's branch is unmoved by a full run" \
    "$_BEFORE_BRANCH" "$(_main_branch)"

# The commit must exist, and exist on the WORK branch — not merely be absent from
# main. Asserting only "main did not move" would pass a run that committed nowhere.
_wt_path="$(cat "$SD_FRESH/run-worktree.txt" 2>/dev/null || echo "")"
_build_root="$(cat "$SD_FRESH/build-repo-root.txt" 2>/dev/null || echo "")"
_branch_sha="$(git -C "$TARGET" rev-parse "$WORK_BRANCH" 2>/dev/null || echo "")"
if [[ -n "$_wt_path" && "$_branch_sha" != "$_BEFORE_HEAD" && -n "$_branch_sha" ]] \
   && git -C "$TARGET" cat-file -e "$WORK_BRANCH:built.txt" 2>/dev/null; then
    assert_pass "[SPEC-3a] the build stage's commit landed on $WORK_BRANCH"
else
    assert_fail "[SPEC-3a] the build stage must commit to the work branch" \
        "rc=$_rc_fresh wt=$_wt_path build_root=$_build_root branch_sha=$_branch_sha base=$_BEFORE_HEAD"
fi

# The stage resolved its tree to the worktree, not the main checkout. This is the
# assertion that fails at the merge-base: pre-fix, build_root IS the main checkout.
if [[ -n "$_build_root" && -n "$_wt_path" ]] \
   && [[ "$(cd "$_build_root" 2>/dev/null && pwd -P)" == "$(cd "$_wt_path" 2>/dev/null && pwd -P)" ]]; then
    assert_pass "[SPEC-3b] stage 2 resolved its repo root to the run's worktree"
else
    assert_fail "[SPEC-3b] stage 2 must resolve its repo root to the run's worktree" \
        "build_root=$_build_root worktree=$_wt_path"
fi

if [[ -n "$_wt_path" && -d "$_wt_path" ]] \
   && [[ "$(cd "$_wt_path" && pwd -P)" != "$(cd "$TARGET" && pwd -P)"* ]]; then
    assert_pass "[SPEC-4] the worktree is recorded and lives outside the target repo"
else
    assert_fail "[SPEC-4] the engine must record a worktree outside the target repo" \
        "wt=$_wt_path target=$TARGET"
fi

# ── SPEC-5: failing before any pr stage must still leave the checkout intact ──
# #1640's local case died in build_test_cycle and never reached pr_open, which was
# the only thing that ever caught the wrong branch. Correctness cannot depend on
# reaching a later stage, so assert the invariant on a run that fails at build.
# A second repo keeps the work branch free (run-fresh's worktree still holds it).
TARGET_PREV="$TARGET"
TARGET="$(setup_git_temp_repo target-fail)"
install_template_overlay "$TARGET" runner-state-dir-minimal
_write_build_stub 1
_BEFORE_HEAD="$(_main_head)"; _BEFORE_BRANCH="$(_main_branch)"
run_pipeline "run-fail"; _rc_fail=$?
SD_FAIL="$(_state_dir_for run-fail)"
_fail_build_root="$(cat "$SD_FAIL/build-repo-root.txt" 2>/dev/null || echo "")"
if [[ "$_rc_fail" -ne 0 ]] \
   && [[ "$(_main_head)" == "$_BEFORE_HEAD" ]] \
   && [[ "$(_main_branch)" == "$_BEFORE_BRANCH" ]] \
   && [[ -n "$_fail_build_root" ]]; then
    assert_pass "[SPEC-5] a run failing before the pr stage leaves the main checkout intact"
else
    assert_fail "[SPEC-5] the main checkout must survive a run that never reaches pr" \
        "rc=$_rc_fail head=$(_main_head) (was $_BEFORE_HEAD) branch=$(_main_branch) (was $_BEFORE_BRANCH) build_root=$_fail_build_root"
fi

# ── SPEC-6: the opt-out is unchanged — no worktree, work lands in place ──────
TARGET="$(setup_git_temp_repo target-inplace)"
install_template_overlay "$TARGET" runner-state-dir-minimal
_write_build_stub 0
run_pipeline "run-inplace" ZBUILD_NO_WORKTREE=1
SD_INPLACE="$(_state_dir_for run-inplace)"
_inplace_branch="$(_main_branch)"
_inplace_wt_recorded=0
[[ -f "$SD_INPLACE/run-worktree.txt" ]] && _inplace_wt_recorded=1
if [[ "$_inplace_branch" == "$WORK_BRANCH" ]] && [[ "$_inplace_wt_recorded" -eq 0 ]] \
   && git -C "$TARGET" cat-file -e "HEAD:built.txt" 2>/dev/null; then
    assert_pass "[SPEC-6] ZBUILD_NO_WORKTREE=1 works in place (no worktree recorded)"
else
    assert_fail "[SPEC-6] the opt-out must keep in-place semantics" \
        "branch=$_inplace_branch wt_recorded=$_inplace_wt_recorded"
fi

# ── SPEC-7: resume lands in the tree the earlier stages worked in ────────────
# Same run_id, so the worktree is re-acquired rather than recreated. Stage 2 must
# report the SAME root as the first run — otherwise a resumed run silently works
# on the main checkout while the earlier stages' commits live in the worktree.
TARGET="$TARGET_PREV"
_write_intake_stub
_write_build_stub 0
cat > "$PLUGINS_ROOT/agent/intake/plugin.sh" <<EOF
intake_run() { return 0; }   # branch already exists in the worktree from run-fresh
EOF
run_pipeline "run-fresh"
_resume_build_root="$(cat "$SD_FRESH/build-repo-root.txt" 2>/dev/null || echo "")"
if [[ -n "$_resume_build_root" && -n "$_wt_path" ]] \
   && [[ "$(cd "$_resume_build_root" 2>/dev/null && pwd -P)" == "$(cd "$_wt_path" 2>/dev/null && pwd -P)" ]]; then
    assert_pass "[SPEC-7] a re-run of the same run_id lands in the same worktree"
else
    assert_fail "[SPEC-7] resume must reuse the run's worktree" \
        "build_root=$_resume_build_root worktree=$_wt_path"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
