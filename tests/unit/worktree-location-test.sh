#!/usr/bin/env bash
# tests/unit/worktree-location-test.sh
# Acceptance tests for per-run worktree location + enablement (#888).
#
# SPEC-1: default root is $HOME/.zbuild/worktrees — NOT under $TMPDIR
# SPEC-2: template config.worktree_root overrides the default
# SPEC-3: ZBUILD_WORKTREE_ROOT overrides the template (env > template > default)
# SPEC-4: the per-run path is keyed by run_id so concurrent runs cannot collide
# SPEC-5: a missing run_id is an error, not a silently shared path
# SPEC-6: worktrees are enabled by default and ZBUILD_NO_WORKTREE=1 disables them
# SPEC-7: a worktree inside the target repo is refused
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "per-run worktree location (#888)"
setup_test_env "worktree-location"

# shellcheck disable=SC1091
source "$REPO_ROOT/core/pipeline/template.sh" 2>/dev/null || true
# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/lib/worktree.sh"

unset ZBUILD_WORKTREE_ROOT ZBUILD_NO_WORKTREE _TPL_SOURCE_FILE 2>/dev/null || true

# ── SPEC-1: default, and explicitly not $TMPDIR ─────────────────────────────
# macOS $TMPDIR is /var/folders/..., which this repo has been bitten by twice
# (#1571, #1609/#1611): entries there can vanish mid-run. In-flight work must
# not live somewhere a reaper may collect.
assert_eq "[SPEC-1] default worktree root is \$HOME/.zbuild/worktrees" \
    "$HOME/.zbuild/worktrees" "$(zbuild_worktree_root)"
# Assert INDEPENDENCE from $TMPDIR rather than a path-prefix check: the test
# harness sandboxes HOME underneath TMPDIR, so a prefix test fires spuriously
# here while the production property still holds. Changing TMPDIR must not move
# the default root.
_root_a="$(zbuild_worktree_root)"
_root_b="$(TMPDIR=/some/other/tmp zbuild_worktree_root)"
if [[ "$_root_a" == "$_root_b" ]]; then
    assert_pass "[SPEC-1] default root is independent of \$TMPDIR (not reapable on macOS)"
else
    assert_fail "[SPEC-1] default root must not derive from \$TMPDIR" "a=$_root_a b=$_root_b"
fi

# ── SPEC-2: template config.worktree_root ───────────────────────────────────
_TPL="$TEST_TEMP_DIR/tpl.yaml"
cat > "$_TPL" <<'TPLEOF'
config:
  worktree_root: /srv/zbuild-wt
stage_definitions:
  build: {}
TPLEOF
export _TPL_SOURCE_FILE="$_TPL"
assert_eq "[SPEC-2] template config.worktree_root overrides the default" \
    "/srv/zbuild-wt" "$(zbuild_worktree_root)"

# ── SPEC-3: env beats template ──────────────────────────────────────────────
export ZBUILD_WORKTREE_ROOT="/srv/from-env"
assert_eq "[SPEC-3] ZBUILD_WORKTREE_ROOT beats the template (env > template > default)" \
    "/srv/from-env" "$(zbuild_worktree_root)"

# ── SPEC-4: per-run path keyed by run_id ────────────────────────────────────
assert_eq "[SPEC-4] per-run path is keyed by run_id" \
    "/srv/from-env/20260101-1234" "$(zbuild_worktree_path 20260101-1234)"
_a="$(zbuild_worktree_path runA)"; _b="$(zbuild_worktree_path runB)"
if [[ "$_a" != "$_b" ]]; then
    assert_pass "[SPEC-4] two runs resolve to different worktrees (no collision)"
else
    assert_fail "[SPEC-4] concurrent runs must not share a worktree" "a=$_a b=$_b"
fi

# ── SPEC-5: missing run_id is an error ──────────────────────────────────────
zbuild_worktree_path >/dev/null 2>&1; _rc=$?
assert_eq "[SPEC-5] a missing run_id is an error, not a shared path" "2" "$_rc"
unset ZBUILD_WORKTREE_ROOT _TPL_SOURCE_FILE

# ── SPEC-6: enabled by default; ZBUILD_NO_WORKTREE=1 disables ───────────────
zbuild_worktree_enabled; _en=$?
assert_eq "[SPEC-6] worktrees are enabled by default" "0" "$_en"
ZBUILD_NO_WORKTREE=1 zbuild_worktree_enabled; _dis=$?
assert_eq "[SPEC-6] ZBUILD_NO_WORKTREE=1 disables worktrees" "1" "$_dis"

# ── SPEC-7: refuse a worktree nested inside the target repo ─────────────────
# #888 proposed runs/<run_id>/worktree/, but ZBUILD_STATE_DIR is the workspace in
# CI — that path would nest a worktree inside the tree it copies, and every tree
# walk (test discovery, scope/impact scanning) would see a duplicate of the repo.
zbuild_worktree_assert_outside "/repo/runs/x/worktree" "/repo" >/dev/null 2>&1; _in=$?
assert_eq "[SPEC-7] a worktree inside the target repo is refused" "1" "$_in"
zbuild_worktree_assert_outside "$HOME/.zbuild/worktrees/x" "/repo" >/dev/null 2>&1; _out=$?
assert_eq "[SPEC-7] a worktree outside the target repo is accepted" "0" "$_out"

# ── SPEC-8: the guard must not silently approve on empty arguments ──────────
# A caller doing
#   zbuild_worktree_assert_outside "$(zbuild_worktree_path)" "$ZBUILD_REPO_ROOT"
# captures "" when zbuild_worktree_path fails (missing run_id). Returning 0 there
# would approve exactly the run the guard exists to refuse — the same
# passes-when-it-should-fail class as an inert test.
zbuild_worktree_assert_outside "" "/repo" >/dev/null 2>&1; _e1=$?
assert_eq "[SPEC-8] empty worktree path is refused (rc=2), not silently approved" "2" "$_e1"
zbuild_worktree_assert_outside "/somewhere" "" >/dev/null 2>&1; _e2=$?
assert_eq "[SPEC-8] empty repo path is refused (rc=2), not silently approved" "2" "$_e2"
zbuild_worktree_assert_outside >/dev/null 2>&1; _e3=$?
assert_eq "[SPEC-8] both args missing is refused (rc=2)" "2" "$_e3"

# ── SPEC-9..13: zbuild_worktree_enter — one mechanism, all three modes ──────
# A real git repo to add worktrees to. WT root is redirected into the sandbox so
# nothing lands in the developer's $HOME.
_R="$TEST_TEMP_DIR/repo"
mkdir -p "$_R"
git -C "$_R" init -q 2>/dev/null
git -C "$_R" config user.email t@t; git -C "$_R" config user.name t
: > "$_R/f"; git -C "$_R" add -A; git -C "$_R" commit -qm init 2>/dev/null
export ZBUILD_WORKTREE_ROOT="$TEST_TEMP_DIR/wt"

# SPEC-9: create mode makes a worktree on a NEW branch
_p1="$(cd "$_R" && zbuild_worktree_enter run1 feature/one create 2>&1)"; _rc1=$?
if [[ "$_rc1" -eq 0 && -d "$_p1" ]] && [[ "$(git -C "$_p1" rev-parse --abbrev-ref HEAD)" == "feature/one" ]]; then
    assert_pass "[SPEC-9] create mode adds a worktree on the new branch"
else
    assert_fail "[SPEC-9] create mode must add a worktree on the new branch" "rc=$_rc1 out=$_p1"
fi

# SPEC-10: the worktree is OUTSIDE the repo
if [[ "$_p1" != "$_R"* ]]; then
    assert_pass "[SPEC-10] the worktree is created outside the target repo"
else
    assert_fail "[SPEC-10] worktree must not be inside the target repo" "wt=$_p1 repo=$_R"
fi

# SPEC-11: resume reuses the same worktree rather than failing on an existing path
_p1b="$(cd "$_R" && zbuild_worktree_enter run1 feature/one create 2>&1)"; _rc1b=$?
if [[ "$_rc1b" -eq 0 && "$_p1b" == "$_p1" ]]; then
    assert_pass "[SPEC-11] a second call for the same run reuses the worktree (resume-safe)"
else
    assert_fail "[SPEC-11] resume must reuse the existing worktree" "rc=$_rc1b out=$_p1b want=$_p1"
fi

# SPEC-12: refuse rather than --force when the branch is checked out elsewhere.
# feature/one is now held by run1's worktree; a different run asking for it must stop.
_out2="$(cd "$_R" && zbuild_worktree_enter run2 feature/one adopt_local 2>&1)"; _rc2=$?
if [[ "$_rc2" -eq 3 ]] && grep -q "already checked out" <<< "$_out2"; then
    assert_pass "[SPEC-12] a branch held by another worktree is refused (rc=3), not forced"
else
    assert_fail "[SPEC-12] must refuse a branch already checked out elsewhere" "rc=$_rc2 out=$_out2"
fi

# SPEC-13: adopt_remote requires a start_point; unknown modes are rejected
(cd "$_R" && zbuild_worktree_enter run3 feature/three adopt_remote) >/dev/null 2>&1; _rc3=$?
assert_eq "[SPEC-13] adopt_remote without a start_point is an error" "2" "$_rc3"
(cd "$_R" && zbuild_worktree_enter run4 feature/four bogus_mode) >/dev/null 2>&1; _rc4=$?
assert_eq "[SPEC-13] an unknown mode is rejected" "2" "$_rc4"
unset ZBUILD_WORKTREE_ROOT

cleanup_test_env
print_test_results
exit $((FAIL > 0))
