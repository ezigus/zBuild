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

cleanup_test_env
print_test_results
exit $((FAIL > 0))
