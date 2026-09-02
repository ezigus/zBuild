#!/usr/bin/env bash
# Tests: ONE push entrypoint, invoked exactly once (#1966).
#
# The state-branch push existed twice — plugins/tool/persist/plugin.sh (the
# always-run stage) and an inline `git push` in .github/workflows/zbuild-pipeline.yml
# — and the two copies disagreed: CI's was gated on an issue number, so `--goal`
# runs snapshotted to a branch that never left the runner.
#
# These assertions pin the contract the deduplication has to satisfy:
#   ONCE    the CI backstop is a no-op once the stage has pushed
#   ALWAYS  the always-run stage still pushes on a FAILED and an ABORTED run
#   SAME    every push goes through _artifact_persist_push, including goal runs
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "persist: one push entrypoint, invoked once (#1966)"
setup_test_env "zb-persist-push"

# #1921 follow-up: reserved test identity (see zb_test_issue). The literals
# here were real issue numbers; a run keyed to one writes fabricated prior
# work onto that issue's state branch.
_ZB_ID1="$(zb_test_issue)"
_ZB_ID2="$(zb_test_issue)"
_ZB_ID3="$(zb_test_issue)"
_ZB_ID4="$(zb_test_issue)"
_ZB_ID5="$(zb_test_issue)"

# A repo with a real (bare) origin, so a push is a push.
ORIGIN="$TEST_TEMP_DIR/origin.git"; git init -q --bare "$ORIGIN"
REPO="$TEST_TEMP_DIR/repo"; mkdir -p "$REPO"
(
  cd "$REPO" && git init -q -b main . && git remote add origin "$ORIGIN" \
    && git config user.email t@t && git config user.name t \
    && echo seed > seed.txt && git add seed.txt && git commit -qm seed
) >/dev/null 2>&1

_seed() {   # <state_dir>
    mkdir -p "$1/artifacts"
    printf '{"ok":true}\n' > "$1/artifacts/plan.json"
}

# ─── [SPEC-1][change] the CLI entrypoint pushes an ISSUE run ────────────────
print_test_section "[SPEC-1][change] zbuild persist --push (issue run)"

_S1="$TEST_TEMP_DIR/s1"; _seed "$_S1"
_rc=0
( cd "$REPO" && ZBUILD_STATE_DIR="$_S1" ZBUILD_ARTIFACT_DIR="$_S1/artifacts" \
    ZBUILD_ISSUE_NUMBER=$_ZB_ID1 bash "$REPO_ROOT/scripts/zbuild" persist --push ) >/dev/null 2>&1 || _rc=$?
assert_exit_code "[SPEC-1] the subcommand exists and succeeds" "0" "$_rc"
if git -C "$ORIGIN" rev-parse --verify --quiet "refs/heads/zbuild/state/issue-$_ZB_ID1" >/dev/null 2>&1; then
    assert_pass "[SPEC-1] the issue's state branch reached origin"
else
    assert_fail "[SPEC-1] no state branch on origin for an issue run" \
        "refs on origin: $(git -C "$ORIGIN" for-each-ref --format='%(refname)' | tr '\n' ' ')"
fi

# ─── [SPEC-2][change] and a GOAL run — the case CI could never do ───────────
# CI's copy was gated on `inputs.issue_number != ''`, so goal runs never
# persisted anywhere. The engine has known goal identity since #1931.
print_test_section "[SPEC-2][change] zbuild persist --push (goal run)"

_S2="$TEST_TEMP_DIR/s2"; _seed "$_S2"
_rc=0
( cd "$REPO" && ZBUILD_STATE_DIR="$_S2" ZBUILD_ARTIFACT_DIR="$_S2/artifacts" \
    ZBUILD_ISSUE_NUMBER=0 ZBUILD_GOAL="make the widget spin" \
    bash "$REPO_ROOT/scripts/zbuild" persist --push ) >/dev/null 2>&1 || _rc=$?
assert_exit_code "[SPEC-2] a goal run's push succeeds" "0" "$_rc"
_goal_refs="$(git -C "$ORIGIN" for-each-ref --format='%(refname)' 'refs/heads/zbuild/state/goal-*' 2>/dev/null)"
if [[ -n "$_goal_refs" ]]; then
    assert_pass "[SPEC-2] a goal run's state branch reached origin"
else
    assert_fail "[SPEC-2] a --goal run still cannot persist" \
        "no refs/heads/zbuild/state/goal-* on origin — F3 of #1966"
fi

# ─── [SPEC-3][guard] never push what was not scanned ───────────────────────
# The secret gate exists to stop a credential leaving the machine. It must be
# welded to the push, not to the stage — otherwise moving the push moves it out
# from behind the gate.
print_test_section "[SPEC-3][guard] a credential blocks the push"

_S3="$TEST_TEMP_DIR/s3"; _seed "$_S3"
printf 'aws: AKIA%s\n' "ABCDEFGHIJKLMNOP" > "$_S3/artifacts/leak.txt"
_rc=0
( cd "$REPO" && ZBUILD_STATE_DIR="$_S3" ZBUILD_ARTIFACT_DIR="$_S3/artifacts" \
    ZBUILD_ISSUE_NUMBER=$_ZB_ID2 bash "$REPO_ROOT/scripts/zbuild" persist --push ) >/dev/null 2>&1 || _rc=$?
assert_exit_code "[SPEC-3] still advisory: never changes the caller's fate" "0" "$_rc"
if git -C "$ORIGIN" rev-parse --verify --quiet "refs/heads/zbuild/state/issue-$_ZB_ID2" >/dev/null 2>&1; then
    assert_fail "[SPEC-3] a credential was PUSHED to origin" "the secret gate did not cover this path"
else
    assert_pass "[SPEC-3] the push was refused — the gate covers the entrypoint"
fi

# ─── [SPEC-4][guard] identity_present distinguishes the two failure kinds ───
# The CI backstop must tell "nothing to push" (no issue, no goal) from "did not
# push" (identity existed, push did not happen). Without it the backstop either
# fires needlessly on every identity-less run or cannot fire at all.
print_test_section "[SPEC-4][guard] identity_present in the persist result"

# Driven through the CLI seam, like every case above — sourcing the plugin into
# this shell hid a load failure behind `|| true` and reported MISSING rather
# than the value under test.
_S4="$TEST_TEMP_DIR/s4"; _seed "$_S4"
( cd "$REPO" && ZBUILD_ISSUE_NUMBER=0 ZBUILD_GOAL="" ZBUILD_STATE_DIR="$_S4" \
    ZBUILD_ARTIFACT_DIR="$_S4/artifacts" bash "$REPO_ROOT/scripts/zbuild" persist --push ) >/dev/null 2>&1 || true
# NOT `// "MISSING"`: jq's alternative operator fires on `false` as well as
# `null`, so the fallback would fire on exactly the value this asserts.
_ip="$(jq -r 'if .data|has("identity_present") then (.data.identity_present|tostring) else "MISSING" end' \
        "$_S4/artifacts/persist-result.json" 2>/dev/null)"
assert_eq "[SPEC-4] a run with no identity records identity_present=false" "false" "$_ip"

# #2042: the SPEC says the field DISTINGUISHES two failure kinds. Pinning only
# the no-identity half left the distinction unproven — a field hardcoded to
# `false` would have satisfied it exactly as well as one that discriminates.
# The contrasting case is the whole point of the field.
# Reserved test identity (zb_test_issue, 90000001+): a stray zbuild/state ref
# is then unmistakably test residue and can never collide with real work.
_ZB_ID_S4B="$(zb_test_issue)"
_S4b="$TEST_TEMP_DIR/s4b"; _seed "$_S4b"
( cd "$REPO" && ZBUILD_ISSUE_NUMBER="$_ZB_ID_S4B" ZBUILD_GOAL="" ZBUILD_STATE_DIR="$_S4b" \
    ZBUILD_ARTIFACT_DIR="$_S4b/artifacts" bash "$REPO_ROOT/scripts/zbuild" persist --push ) >/dev/null 2>&1 || true
_ip_b="$(jq -r 'if .data|has("identity_present") then (.data.identity_present|tostring) else "MISSING" end' \
    "$_S4b/artifacts/persist-result.json" 2>/dev/null || echo MISSING)"
assert_eq "[SPEC-4] a run WITH identity records identity_present=true" "true" "$_ip_b"
assert_eq "[SPEC-4] so the field discriminates rather than being a constant" \
    "1" "$([[ "$_ip" != "$_ip_b" ]] && echo 1 || echo 0)"

_S5="$TEST_TEMP_DIR/s5"; _seed "$_S5"
( cd "$REPO" && ZBUILD_ISSUE_NUMBER=$_ZB_ID3 ZBUILD_STATE_DIR="$_S5" \
    ZBUILD_ARTIFACT_DIR="$_S5/artifacts" bash "$REPO_ROOT/scripts/zbuild" persist --push ) >/dev/null 2>&1 || true
_ip2="$(jq -r 'if .data|has("identity_present") then (.data.identity_present|tostring) else "MISSING" end' \
        "$_S5/artifacts/persist-result.json" 2>/dev/null)"
assert_eq "[SPEC-5] an issue run records identity_present=true" "true" "$_ip2"

# ─── [SPEC-6][guard] CI owns no push of its own ────────────────────────────
# The assertion that this duplication cannot return. A second implementation is
# how the two copies drifted apart in the first place (#1692's defect class).
print_test_section "[SPEC-6][guard] no state-branch push under .github/workflows"

# Match the NAME, not `git push` — the workflow built the ref in a
# `state_branch=` variable, so grepping the two together silently found nothing
# and this guard passed while the duplicate push was still there. Scoped to the
# pipeline workflow: state-branch-reclaim.yml legitimately names these refs.
_PIPE_WF="$REPO_ROOT/.github/workflows/zbuild-pipeline.yml"
_wf_state="$(grep -n 'zbuild/state/' "$_PIPE_WF" 2>/dev/null || true)"
if [[ -n "$_wf_state" ]]; then
    assert_fail "[SPEC-6] the pipeline workflow still names the state branch" \
        "hydrate and persist own it: $(printf '%s' "$_wf_state" | head -3)"
else
    assert_pass "[SPEC-6] the pipeline workflow names no state branch at all"
fi

# The backstop is allowed to INVOKE the entrypoint; it may not reimplement it.
_wf_raw="$(grep -nE 'git (push|fetch)' "$_PIPE_WF" 2>/dev/null | grep -i 'state' || true)"
if [[ -n "$_wf_raw" ]]; then
    assert_fail "[SPEC-6] a raw git push/fetch of state survives in the workflow" \
        "$(printf '%s' "$_wf_raw" | head -2)"
else
    assert_pass "[SPEC-6] no raw state push/fetch remains — only the entrypoint"
fi

# ─── [SPEC-7][change] restore records WHERE the state came from ────────────
# #1921's missing discriminator. "The branch exists" and "CI fetched it from
# origin" are different facts, and only the second answers whether a CI run
# started warm. Without this, that question is an inference from log lines.
print_test_section "[SPEC-7][change] local vs remote restore source"

# shellcheck source=../../core/state/artifact-persist.sh
source "$REPO_ROOT/core/state/artifact-persist.sh"

_S7="$TEST_TEMP_DIR/s7"; _seed "$_S7"
( cd "$REPO" && ZBUILD_STATE_DIR="$_S7" ZBUILD_ARTIFACT_DIR="$_S7/artifacts" \
    ZBUILD_ISSUE_NUMBER=$_ZB_ID4 bash "$REPO_ROOT/scripts/zbuild" persist --push ) >/dev/null 2>&1 || true

# Run IN-PROCESS, not in a subshell: _ARTIFACT_PERSIST_LAST_SOURCE is the thing
# under test, and a subshell's assignment dies with it.
_here="$PWD"
# LOCAL: refs/heads/<branch> is present in this clone.
cd "$REPO"; _artifact_persist_restore $_ZB_ID4 "$TEST_TEMP_DIR/r-local" >/dev/null 2>&1 || true; cd "$_here"
assert_eq "[SPEC-7] a restore from refs/heads reports source=local" \
    "local" "${_ARTIFACT_PERSIST_LAST_SOURCE:-MISSING}"

# REMOTE: a fresh clone has only refs/remotes/origin/<branch> — the CI shape.
CLONE="$TEST_TEMP_DIR/clone"
git clone -q "$ORIGIN" "$CLONE" >/dev/null 2>&1
( cd "$CLONE" && git fetch -q origin "+refs/heads/zbuild/state/issue-$_ZB_ID4:refs/remotes/origin/zbuild/state/issue-$_ZB_ID4" ) >/dev/null 2>&1 || true
cd "$CLONE"; _artifact_persist_restore $_ZB_ID4 "$TEST_TEMP_DIR/r-remote" >/dev/null 2>&1 || true; cd "$_here"
assert_eq "[SPEC-7] a restore from refs/remotes/origin reports source=remote" \
    "remote" "${_ARTIFACT_PERSIST_LAST_SOURCE:-MISSING}"

# ─── [SPEC-8][guard] a partial plugin load must be LOUD ────────────────────
# `source … || { error; exit 2; }` only fires when source itself returns
# non-zero — which it does not when the file exists and reaches EOF despite an
# inner source failing. persist_run is then undefined, `command not found` is
# swallowed by `|| true`, and the backstop exits 0 having pushed nothing: a
# silent no-op in exactly the situation it exists for.
print_test_section "[SPEC-8][guard] backstop refuses rather than no-opping"

_FAKE="$TEST_TEMP_DIR/fakeroot"
mkdir -p "$_FAKE/scripts" "$_FAKE/plugins/tool/persist" "$_FAKE/core"
cp "$REPO_ROOT/scripts/zbuild" "$_FAKE/scripts/zbuild"
ln -s "$REPO_ROOT/scripts/lib" "$_FAKE/scripts/lib"
ln -s "$REPO_ROOT/core/state" "$_FAKE/core/state"
# A plugin that loads cleanly and defines nothing — the partial-load shape.
printf '#!/usr/bin/env bash\n# defines no persist_run\n' > "$_FAKE/plugins/tool/persist/plugin.sh"

_rc=0
_out="$( cd "$REPO" && ZBUILD_STATE_DIR="$TEST_TEMP_DIR/s8" ZBUILD_ISSUE_NUMBER=$_ZB_ID5 \
    bash "$_FAKE/scripts/zbuild" persist --push 2>&1 )" || _rc=$?
if [[ "$_rc" -eq 0 ]]; then
    assert_fail "[SPEC-8] a plugin that defines no persist_run exited 0" \
        "the backstop silently pushed nothing. output: $(printf '%s' "$_out" | tr '\n' '|' | head -c 160)"
else
    assert_pass "[SPEC-8] an unusable persist plugin is refused, not silently skipped"
fi

# ─── [SPEC-9][guard] the backstop never hands find an empty path ───────────
# `find "" -name …` is a path error: it exits non-zero, `2>/dev/null || true`
# swallows it, the result reads as "no persist-result.json", and the backstop
# then pushes UNCONDITIONALLY — breaking the exactly-once guarantee on a healthy
# run that already pushed.
print_test_section "[SPEC-9][guard] no unguarded find on ZBUILD_STATE_DIR"

# Comment lines are stripped first: the fix carries a comment quoting the bad
# form to explain it, and a guard that its own explanation can trip is a guard
# that will be deleted the first time someone documents the hazard.
_bad_find="$(grep -vE '^\s*#' "$REPO_ROOT/.github/workflows/zbuild-pipeline.yml" 2>/dev/null \
             | grep -n 'find "\${ZBUILD_STATE_DIR:-}"' || true)"
if [[ -n "$_bad_find" ]]; then
    assert_fail "[SPEC-9] find can be handed an empty path" \
        "an empty state dir reads as 'no result' and forces a second push: $(printf '%s' "$_bad_find" | head -2)"
else
    assert_pass "[SPEC-9] the state dir is checked before find is called"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
