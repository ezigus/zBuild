#!/usr/bin/env bash
# Tests: the hydrate stage (#1074) — the fetch a fresh clone needs, the atomic
# promote that cannot leave a partial tree, and the local-wins read rule.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/state/artifact-persist.sh
source "$REPO_ROOT/core/state/artifact-persist.sh"
# shellcheck source=../../plugins/tool/hydrate/plugin.sh
source "$REPO_ROOT/plugins/tool/hydrate/plugin.sh"

print_test_header "hydrate stage (#1074)"
setup_test_env "zb-hydrate"

# _artifact_persist_snapshot builds a throwaway git index under
# ${ZBUILD_STAGE_SCRATCH:-${TMPDIR:-/tmp}}. Inheriting whatever the harness or
# the CI job left in ZBUILD_STAGE_SCRATCH makes this test depend on ambient
# state — pin it to a directory this test owns and knows exists.
export ZBUILD_STAGE_SCRATCH="$TEST_TEMP_DIR/scratch"
mkdir -p "$ZBUILD_STAGE_SCRATCH"

# Real repos and a real bare remote. The subject is a `git fetch` against a
# clone that has never seen the branch, so a mock would prove nothing.
_H_REMOTE="$TEST_TEMP_DIR/remote.git"
_H_AUTHOR="$TEST_TEMP_DIR/author"
git init -q --bare "$_H_REMOTE" 2>/dev/null
mkdir -p "$_H_AUTHOR"
(
    cd "$_H_AUTHOR" || exit 1
    git init -q -b main .
    git config user.email t@e.st; git config user.name t
    git remote add origin "$_H_REMOTE"
    : > f; git add f; git commit -q -m init
    git push -q -u origin main
) >/dev/null 2>&1

# The author run snapshots artifacts for issue 7001 and pushes them.
_A_STATE="$TEST_TEMP_DIR/author-state"
mkdir -p "$_A_STATE/artifacts"
printf 'prior plan\n' > "$_A_STATE/artifacts/plan.json"
printf 'prior design\n' > "$_A_STATE/artifacts/design.md"
_seed_rc=0
( cd "$_H_AUTHOR" && _artifact_persist_snapshot "$_A_STATE" 7001 && _artifact_persist_push 7001 ) \
    >"$TEST_TEMP_DIR/seed.log" 2>&1 || _seed_rc=$?
assert_exit_code "[SETUP] the author run snapshotted and pushed" "0" "$_seed_rc"
[[ $_seed_rc -eq 0 ]] || cat "$TEST_TEMP_DIR/seed.log" >&2

# ─── [SPEC-1][change] a fresh clone can hydrate at all ──────────────────────
# This is what was missing. _artifact_persist_restore reads refs/heads first and
# refs/remotes/origin second; on a fresh clone NEITHER exists until something
# fetches, so restore reported "first run" for an issue with plenty of prior
# work. Only the CI workflow's own fetch step ever covered that.
print_test_section "[SPEC-1][change] a fresh clone restores prior work"

# A CI runner has NO GLOBAL GIT IDENTITY. `_artifact_persist_snapshot` uses
# `git commit-tree`, which refuses without one — so a clone here must configure
# it explicitly. macOS passed on the operator's global config and ubuntu did
# not, which is exactly the shape of a test that depends on ambient environment.
_h_clone() {
    git clone -q --single-branch --branch main "$_H_REMOTE" "$1" 2>/dev/null
    git -C "$1" config user.email t@e.st
    git -C "$1" config user.name t
}

_H_FRESH="$TEST_TEMP_DIR/fresh"
_h_clone "$_H_FRESH"

# Premise, asserted rather than assumed: this clone has neither ref.
_h_refs="$( cd "$_H_FRESH" && git rev-parse -q --verify refs/heads/zbuild/state/issue-7001 >/dev/null 2>&1 && echo 1 || echo 0 )"
assert_eq "[SPEC-1] premise: no local state ref in a fresh clone" "0" "$_h_refs"
_h_refs="$( cd "$_H_FRESH" && git rev-parse -q --verify refs/remotes/origin/zbuild/state/issue-7001 >/dev/null 2>&1 && echo 1 || echo 0 )"
assert_eq "[SPEC-1] premise: no remote-tracking state ref either" "0" "$_h_refs"

# And the control: restore ALONE finds nothing here. Without this the SPEC below
# could pass for a reason that has nothing to do with the fetch.
# The status lives in a variable, and the `cd` has to happen in a subshell —
# so echo it OUT rather than reading it after, which returns the parent's empty
# copy and passes for the wrong reason.
_h_control="$( cd "$_H_FRESH" \
    && _artifact_persist_restore 7001 "$TEST_TEMP_DIR/control" >/dev/null 2>&1
    printf '%s' "${_ARTIFACT_PERSIST_LAST_STATUS:-}" )"
assert_eq "[SPEC-1] control: restore without a fetch reports first-run" \
    "empty" "$_h_control"

_H_STATE="$TEST_TEMP_DIR/fresh-state"
mkdir -p "$_H_STATE/artifacts"
export ZBUILD_ARTIFACT_DIR="$_H_STATE/artifacts"
export ZBUILD_RESTORED_ARTIFACTS_DIR="$_H_STATE/restored-artifacts/artifacts"
_rc=0
( cd "$_H_FRESH" && ZBUILD_ISSUE_NUMBER=7001 ZBUILD_STATE_DIR="$_H_STATE" \
    hydrate_run hydrate "" ) >/dev/null 2>&1 || _rc=$?
assert_exit_code "[SPEC-1] hydrate returns 0" "0" "$_rc"
assert_file_exists "[SPEC-1] prior plan.json was restored" \
    "$ZBUILD_RESTORED_ARTIFACTS_DIR/plan.json"
assert_file_exists "[SPEC-1] prior design.md was restored" \
    "$ZBUILD_RESTORED_ARTIFACTS_DIR/design.md"
assert_eq "[SPEC-1] the result records how many were restored" "2" \
    "$(jq -r '.data.restored' "$ZBUILD_ARTIFACT_DIR/hydrate-result.json" 2>/dev/null)"

# ─── [SPEC-2][guard] the fetch cannot clobber an unpushed local snapshot ────
# "Git wins" is about DURABILITY, not read precedence. A local snapshot may hold
# work an earlier push never delivered; preferring origin would LOSE it.
print_test_section "[SPEC-2][guard] unpushed local work survives a hydrate"

_H_LOCAL="$TEST_TEMP_DIR/localwins"
_h_clone "$_H_LOCAL"
_L_STATE="$TEST_TEMP_DIR/local-state"
mkdir -p "$_L_STATE/artifacts"
printf 'NEWER local work\n' > "$_L_STATE/artifacts/plan.json"
# Snapshot locally and deliberately do NOT push.
# `|| _snap_rc=$?` rather than a bare subshell: under `set -e` a non-zero return
# kills the whole file, and with stderr redirected it does so SILENTLY — the
# section header prints and nothing follows. That is uninterpretable in CI.
_snap_rc=0
( cd "$_H_LOCAL" && _artifact_persist_snapshot "$_L_STATE" 7001 ) \
    >"$TEST_TEMP_DIR/localsnap.log" 2>&1 || _snap_rc=$?
assert_exit_code "[SPEC-2] the local snapshot succeeded" "0" "$_snap_rc"
[[ $_snap_rc -eq 0 ]] || cat "$TEST_TEMP_DIR/localsnap.log" >&2
# `|| true`: a missing ref must FAIL AN ASSERTION, not kill the file under
# `set -e`. Without it the section aborts and every later assertion silently
# never runs — which is how this reached CI looking like one failure instead of
# a whole section that never executed.
_l_before="$( cd "$_H_LOCAL" && git rev-parse refs/heads/zbuild/state/issue-7001 2>/dev/null || true )"
if [[ -z "$_l_before" ]]; then
    assert_fail "[SPEC-2] premise: local snapshot must create refs/heads/zbuild/state/issue-7001" \
        "no ref — check git identity in the clone"
else
    assert_pass "[SPEC-2] premise: the local snapshot created a ref"
fi

_R_STATE="$TEST_TEMP_DIR/localwins-state"
mkdir -p "$_R_STATE/artifacts"
export ZBUILD_ARTIFACT_DIR="$_R_STATE/artifacts"
export ZBUILD_RESTORED_ARTIFACTS_DIR="$_R_STATE/restored-artifacts/artifacts"
( cd "$_H_LOCAL" && ZBUILD_ISSUE_NUMBER=7001 ZBUILD_STATE_DIR="$_R_STATE" \
    hydrate_run hydrate "" ) >/dev/null 2>&1

_l_after="$( cd "$_H_LOCAL" && git rev-parse refs/heads/zbuild/state/issue-7001 2>/dev/null || true )"
assert_eq "[SPEC-2] the local branch ref is unmoved by the fetch" "$_l_before" "$_l_after"
assert_contains "[SPEC-2] and the LOCAL (unpushed) content is what got restored" \
    "$(cat "$ZBUILD_RESTORED_ARTIFACTS_DIR/plan.json" 2>/dev/null)" "NEWER local work"

# ─── [SPEC-3][guard] a partial extraction is never promoted ─────────────────
# git archive | tar can fail mid-stream leaving a half-extracted tree that
# satisfies a bare -d/-n check. PR #1880's review caught the engine adopting one
# and gated on a status; staging + a single mv removes the failure mode instead.
print_test_section "[SPEC-3][guard] a failed restore leaves the area absent, not partial"

_P_STATE="$TEST_TEMP_DIR/partial-state"
mkdir -p "$_P_STATE/artifacts"
export ZBUILD_ARTIFACT_DIR="$_P_STATE/artifacts"
export ZBUILD_RESTORED_ARTIFACTS_DIR="$_P_STATE/restored-artifacts/artifacts"

# Force a restore failure that still creates a staging directory with content —
# the exact shape a mid-stream tar failure leaves behind.
_artifact_persist_restore() {
    local _issue="$1" _dir="$2"
    mkdir -p "$_dir/artifacts"
    printf 'HALF A FILE' > "$_dir/artifacts/plan.json"
    _ARTIFACT_PERSIST_LAST_STATUS="failed"
    _ARTIFACT_PERSIST_LAST_REASON="simulated mid-stream tar failure"
    return 1
}
_rc=0
( cd "$_H_FRESH" && ZBUILD_ISSUE_NUMBER=7001 ZBUILD_STATE_DIR="$_P_STATE" \
    hydrate_run hydrate "" ) >/dev/null 2>&1 || _rc=$?
assert_exit_code "[SPEC-3] hydrate still returns 0 on a failed restore" "0" "$_rc"
assert_file_not_exists "[SPEC-3] the half-extracted file was NOT promoted" \
    "$ZBUILD_RESTORED_ARTIFACTS_DIR/plan.json"
if [[ -d "$_P_STATE/restored-artifacts.staging" ]]; then
    assert_fail "[SPEC-3] the staging tree must be discarded" "still present"
else
    assert_pass "[SPEC-3] the staging tree is discarded whole"
fi
assert_eq "[SPEC-3] and the result records degraded" "degraded" \
    "$(jq -r '.verdict' "$ZBUILD_ARTIFACT_DIR/hydrate-result.json" 2>/dev/null)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
