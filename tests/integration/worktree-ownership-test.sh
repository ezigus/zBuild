#!/usr/bin/env bash
# tests/integration/worktree-ownership-test.sh
# The per-run worktree is ENGINE-owned run infrastructure (ADR-052, #1640).
#
# Formerly intake-worktree-isolation-test.sh, which asserted the #888 contract:
# intake acquires the worktree and cd's into it. ADR-052 reverses that ownership,
# so the assertions here reverse with it — intake must now be entirely unaware of
# worktrees, and the seams that place the runner in one belong to the engine.
#
# Scope note: end-to-end proof that every stage lands in the run's tree lives in
# worktree-run-isolation-test.sh, which dispatches through the real runner. This
# file covers the seams underneath it, plus the intake-side contract change.
#
# SPEC-1: intake checks out in whatever tree it is given — no worktree of its own
# SPEC-2: intake records no worktree file (it no longer owns one)
# SPEC-3: intake's dirty-tree preflight targets the MAIN checkout, not $PWD
# SPEC-4: ZBUILD_NO_WORKTREE=1 restores in-place behaviour (the opt-out works)
# SPEC-5: _runner_enter_worktree acquires a tree, exports it, and cd's there
# SPEC-6: a recorded worktree that has vanished fails CLOSED (rc=1)
# SPEC-7: no record + worktrees disabled is a clean in-place no-op (rc=0)
# SPEC-8: the legacy intake-worktree.txt record is still honoured (in-flight runs)
# SPEC-9: zbuild_worktree_acquire reuses the tree for the same run_id (resume)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "engine-owned worktree ownership (ADR-052, #1640)"
setup_test_env "worktree-ownership"

# Keep worktrees inside the sandbox rather than the developer's real ~/.zbuild.
export ZBUILD_RUN_ROOT="$TEST_TEMP_DIR/runroot"

# A target repo standing in for the repo being worked on.
TARGET="$TEST_TEMP_DIR/target"
mkdir -p "$TARGET"
git -C "$TARGET" init -q -b main 2>/dev/null || { git -C "$TARGET" init -q; git -C "$TARGET" checkout -q -b main 2>/dev/null; }
git -C "$TARGET" config user.email t@t; git -C "$TARGET" config user.name t
: > "$TARGET/f"; git -C "$TARGET" add -A; git -C "$TARGET" commit -qm init 2>/dev/null

_main_head() { git -C "$TARGET" rev-parse --abbrev-ref HEAD 2>/dev/null; }

# ── SPEC-1/2: intake works in the tree it is handed, and claims no worktree ──
# The engine has already re-rooted by the time intake runs, so this case hands it
# a pre-made worktree the way the runner would and asserts the checkout lands
# THERE while the main tree stays on main. Under #888 intake would have created a
# second worktree of its own; under ADR-052 it must create none.
WT1="$TEST_TEMP_DIR/handed-worktree"
git -C "$TARGET" worktree add -q --detach "$WT1" >/dev/null 2>&1
SD1="$TEST_TEMP_DIR/state-handed"; mkdir -p "$SD1"
(
    cd "$WT1" || exit 90
    export ZBUILD_RUN_ID="run-a" ZBUILD_STATE_DIR="$SD1"
    export ZBUILD_MAIN_REPO_ROOT="$TARGET"
    export ZBUILD_WORKSPACE_BRANCH="zbuild/issue-777-wt"
    # shellcheck disable=SC1091
    source "$REPO_ROOT/plugins/agent/intake/plugin.sh" 2>/dev/null
    _intake_create_workspace_branch "$SD1" 777 "worktree ownership" >/dev/null 2>&1
    printf '%s' "$?" > "$SD1/rc"
)
_rc1="$(cat "$SD1/rc" 2>/dev/null || echo 99)"
_wt1_head="$(git -C "$WT1" rev-parse --abbrev-ref HEAD 2>/dev/null)"
if [[ "$_rc1" -eq 0 && "$_wt1_head" == "zbuild/issue-777-wt" && "$(_main_head)" == "main" ]]; then
    assert_pass "[SPEC-1] intake checks out in the tree it was handed; main tree untouched"
else
    assert_fail "[SPEC-1] intake must check out in the tree it was handed" \
        "rc=$_rc1 worktree_head=$_wt1_head main_head=$(_main_head)"
fi

if [[ ! -f "$SD1/intake-worktree.txt" && ! -f "$SD1/run-worktree.txt" ]]; then
    assert_pass "[SPEC-2] intake records no worktree of its own (the engine owns it)"
else
    assert_fail "[SPEC-2] intake must not record a worktree" \
        "intake-worktree.txt=$([[ -f "$SD1/intake-worktree.txt" ]] && echo present || echo absent) run-worktree.txt=$([[ -f "$SD1/run-worktree.txt" ]] && echo present || echo absent)"
fi

# ── SPEC-3: the dirty-tree preflight keeps its teeth ────────────────────────
# The engine hands intake a freshly-created worktree, which is ALWAYS clean. A
# preflight reading $PWD would therefore never refuse anything — silently making
# worktree mode more permissive than in-place mode. It must read the operator's
# checkout instead, so a dirty MAIN tree still stops the run from a clean CWD.
TARGET_D="$TEST_TEMP_DIR/target-dirty"
mkdir -p "$TARGET_D"
git -C "$TARGET_D" init -q -b main 2>/dev/null || { git -C "$TARGET_D" init -q; git -C "$TARGET_D" checkout -q -b main 2>/dev/null; }
git -C "$TARGET_D" config user.email t@t; git -C "$TARGET_D" config user.name t
: > "$TARGET_D/f"; git -C "$TARGET_D" add -A; git -C "$TARGET_D" commit -qm init 2>/dev/null
WT_D="$TEST_TEMP_DIR/dirty-worktree"
git -C "$TARGET_D" worktree add -q --detach "$WT_D" >/dev/null 2>&1
printf 'uncommitted\n' > "$TARGET_D/stray.txt"      # dirty the MAIN tree only
SD_D="$TEST_TEMP_DIR/state-dirty"; mkdir -p "$SD_D"
(
    cd "$WT_D" || exit 90                            # CWD is clean; main is not
    export ZBUILD_RUN_ID="run-dirty" ZBUILD_STATE_DIR="$SD_D"
    export ZBUILD_MAIN_REPO_ROOT="$TARGET_D"
    export ZBUILD_WORKSPACE_BRANCH="zbuild/issue-779-dirty"
    # shellcheck disable=SC1091
    source "$REPO_ROOT/plugins/agent/intake/plugin.sh" 2>/dev/null
    _intake_create_workspace_branch "$SD_D" 779 "dirty main" >/dev/null 2>&1
    printf '%s' "$?" > "$SD_D/rc"
)
_rc_d="$(cat "$SD_D/rc" 2>/dev/null || echo 99)"
assert_eq "[SPEC-3] a dirty MAIN checkout still refuses, from a clean worktree CWD" \
    "2" "$_rc_d"

# ── SPEC-4: the opt-out restores in-place behaviour ────────────────────────
TARGET2="$TEST_TEMP_DIR/target2"
mkdir -p "$TARGET2"
git -C "$TARGET2" init -q 2>/dev/null
git -C "$TARGET2" config user.email t@t; git -C "$TARGET2" config user.name t
: > "$TARGET2/f"; git -C "$TARGET2" add -A; git -C "$TARGET2" commit -qm init 2>/dev/null
SD2="$TEST_TEMP_DIR/state-inplace"; mkdir -p "$SD2"
(
    cd "$TARGET2" || exit 90
    export ZBUILD_RUN_ID="run-b" ZBUILD_STATE_DIR="$SD2" ZBUILD_NO_WORKTREE=1
    export ZBUILD_WORKSPACE_BRANCH="zbuild/issue-778-inplace"
    # shellcheck disable=SC1091
    source "$REPO_ROOT/plugins/agent/intake/plugin.sh" 2>/dev/null
    _intake_create_workspace_branch "$SD2" 778 "in place" >/dev/null 2>&1
    printf '%s' "$?" > "$SD2/rc"
)
_rc2="$(cat "$SD2/rc" 2>/dev/null || echo 99)"
_head2="$(git -C "$TARGET2" rev-parse --abbrev-ref HEAD 2>/dev/null)"
if [[ "$_rc2" -eq 0 && "$_head2" == "zbuild/issue-778-inplace" && ! -f "$SD2/run-worktree.txt" ]]; then
    assert_pass "[SPEC-4] ZBUILD_NO_WORKTREE=1 restores in-place checkout (no worktree recorded)"
else
    assert_fail "[SPEC-4] the opt-out must check out in place" \
        "rc=$_rc2 head=$_head2 wt_file=$([[ -f "$SD2/run-worktree.txt" ]] && echo present || echo absent)"
fi

# ── SPEC-5..8: the engine-side seams ────────────────────────────────────────
# shellcheck disable=SC1091
source "$REPO_ROOT/core/pipeline/runner.sh" 2>/dev/null || true
# runner.sh sets errexit. This file runs `set -uo pipefail` (no -e) and asserts on
# INTENTIONAL non-zero returns below, so restore the lenient mode — otherwise the
# first expected failure kills the test before print_test_results and the run looks
# like a pass-with-no-summary.
set +e

if declare -F _runner_enter_worktree >/dev/null 2>&1; then
    # SPEC-5: fresh acquire — exports the tree AND cd's there. Both matter: plugins
    # that read ZBUILD_REPO_ROOT need the export, and plugins that fall back to
    # `git rev-parse --show-toplevel` need the CWD. #1640 was that fallback firing
    # in the main checkout.
    SD5="$TEST_TEMP_DIR/state-enter"; mkdir -p "$SD5"
    _r5="$(
        cd "$TARGET" || exit 90
        unset ZBUILD_REPO_ROOT ZBUILD_MAIN_REPO_ROOT
        _runner_enter_worktree "$SD5" "run-enter" >/dev/null 2>&1 \
            && printf '%s|%s' "${ZBUILD_REPO_ROOT:-}" "$(pwd -P)"
    )"
    _r5_export="${_r5%%|*}"; _r5_cwd="${_r5#*|}"
    _r5_recorded="$(cat "$SD5/run-worktree.txt" 2>/dev/null || echo "")"
    if [[ -n "$_r5_export" && "$_r5_export" == "$_r5_recorded" ]] \
       && [[ "$_r5_cwd" == "$(cd "$_r5_export" 2>/dev/null && pwd -P)" ]]; then
        assert_pass "[SPEC-5] the engine acquires a worktree, exports it, and cd's there"
    else
        assert_fail "[SPEC-5] the engine must export AND enter the run's worktree" \
            "export=$_r5_export cwd=$_r5_cwd recorded=$_r5_recorded"
    fi

    # SPEC-6: recorded worktree gone -> fail closed. Continuing in the main
    # checkout is exactly the silent damage #1640 documents.
    SDX="$TEST_TEMP_DIR/state-gone"; mkdir -p "$SDX"
    printf '%s\n' "$TEST_TEMP_DIR/definitely-not-here" > "$SDX/run-worktree.txt"
    ( cd "$TARGET" && _runner_enter_worktree "$SDX" "run-gone" ) >/dev/null 2>&1; _rc6=$?
    assert_eq "[SPEC-6] a missing recorded worktree fails closed (rc=1), not a silent fallback" \
        "1" "$_rc6"

    # SPEC-7: no record and worktrees disabled -> clean in-place no-op.
    SDY="$TEST_TEMP_DIR/state-none"; mkdir -p "$SDY"
    _r7="$(
        cd "$TARGET" || exit 90
        export ZBUILD_NO_WORKTREE=1
        unset ZBUILD_REPO_ROOT
        _runner_enter_worktree "$SDY" "run-none" >/dev/null 2>&1
        printf '%s|%s' "$?" "${ZBUILD_REPO_ROOT:-}"
    )"
    if [[ "${_r7%%|*}" == "0" && -z "${_r7#*|}" && ! -f "$SDY/run-worktree.txt" ]]; then
        assert_pass "[SPEC-7] the opt-out is a clean no-op (rc=0, nothing exported or recorded)"
    else
        assert_fail "[SPEC-7] the opt-out must leave the runner in place" "got: $_r7"
    fi

    # SPEC-8: a run started by the previous engine recorded intake-worktree.txt.
    # Reading only the new name would strand it in the main checkout mid-flight.
    SDL="$TEST_TEMP_DIR/state-legacy"; mkdir -p "$SDL"
    printf '%s\n' "$WT1" > "$SDL/intake-worktree.txt"
    _r8="$(
        cd "$TARGET" || exit 90
        unset ZBUILD_REPO_ROOT
        _runner_enter_worktree "$SDL" "run-legacy" >/dev/null 2>&1 && printf '%s' "${ZBUILD_REPO_ROOT:-}"
    )"
    assert_eq "[SPEC-8] the legacy intake-worktree.txt record is still honoured" "$WT1" "$_r8"
else
    assert_fail "[SPEC-5] _runner_enter_worktree must exist" "not defined after sourcing runner.sh"
fi

# ── SPEC-9: acquire is resume-safe for the same run_id ──────────────────────
if declare -F zbuild_worktree_acquire >/dev/null 2>&1; then
    _a1="$(cd "$TARGET" && zbuild_worktree_acquire "run-reuse" "$TARGET" 2>/dev/null)"
    _a2="$(cd "$TARGET" && zbuild_worktree_acquire "run-reuse" "$TARGET" 2>/dev/null)"
    if [[ -n "$_a1" && "$_a1" == "$_a2" ]]; then
        assert_pass "[SPEC-9] acquiring twice for one run_id reuses the same worktree"
    else
        assert_fail "[SPEC-9] acquire must be resume-safe" "first=$_a1 second=$_a2"
    fi
else
    assert_fail "[SPEC-9] zbuild_worktree_acquire must exist" "not defined"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
