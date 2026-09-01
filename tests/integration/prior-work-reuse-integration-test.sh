#!/usr/bin/env bash
# Integration: ADR-050 (#1581) prior-work reuse — the cross-run chain the runner
# and CI rely on, exercised end-to-end against a REAL git fixture (no mocks):
#
#   persist (snapshot to state branch)
#     → CI cross-runner round-trip (bare remote push + fresh clone)
#       → restore into ZBUILD_RESTORED_ARTIFACTS_DIR
#         → _read_prior_output seam pickup (what every wired stage calls)
#
# Plus the pr-open remote-aware preflight ref math (the #1570 fix): local HEAD at
# the merge-base but origin/<work-branch> carrying commits ⇒ "remote has work".
#
# The engine helper (core/state/artifact-persist.sh) and the seam
# (scripts/lib/prior-output-reader.sh) each have their own unit tests; this proves
# they compose the way runner.sh (restore at startup → export the env var →
# snapshot at each boundary) and the CI workflow (fetch/push the state branch) wire
# them together.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/state/artifact-persist.sh
source "$REPO_ROOT/core/state/artifact-persist.sh"
# shellcheck source=../../scripts/lib/prior-output-reader.sh
source "$REPO_ROOT/scripts/lib/prior-output-reader.sh"
# shellcheck source=../../scripts/lib/git-remote.sh
source "$REPO_ROOT/scripts/lib/git-remote.sh"

print_test_header "prior-work reuse — cross-run chain (ADR-050 / #1581)"
setup_test_env "prior-work-reuse-integration"

# #1921 follow-up: reserved test identity (see zb_test_issue). The literals
# here were real issue numbers; a run keyed to one writes fabricated prior
# work onto that issue's state branch.
_ZB_ID="$(zb_test_issue)"

GIT="$(command -v git)"
ISSUE=4242
WORK="zbuild/issue-${ISSUE}-ci"
STATE_BRANCH="zbuild/state/issue-${ISSUE}"

# ─── Fixture: a repo with a work branch carrying one build commit ─────────────
fx="$TEST_TEMP_DIR/origin-src"
mkdir -p "$fx"
(
    cd "$fx"
    "$GIT" init -q -b main
    "$GIT" config user.email t@t.t; "$GIT" config user.name t; "$GIT" config commit.gpgsign false
    echo base > app.txt; "$GIT" add app.txt; "$GIT" commit -q -m base
    "$GIT" checkout -q -b "$WORK"
    echo work >> app.txt; "$GIT" commit -qam "build: real work commit"
    "$GIT" checkout -q main
)

# A prior run's artifact area (what the runner would snapshot at each boundary).
state_dir="$fx/state"
mkdir -p "$state_dir/artifacts"
printf 'PRIOR DESIGN — the acceptance contract from the earlier attempt.\n' > "$state_dir/artifacts/design.md"
printf '{"schema_version":1,"goal":"prior plan goal"}\n' > "$state_dir/artifacts/plan.json"
printf '{"schema_version":4,"verdict":"empty_diff","files_changed":["app.txt"]}\n' > "$state_dir/artifacts/build-summary.json"

# ─── T1: snapshot the artifact area onto the state branch ─────────────────────
_artifact_persist_snapshot "$state_dir" "$ISSUE" "$fx"
if "$GIT" -C "$fx" rev-parse -q --verify "refs/heads/$STATE_BRANCH" >/dev/null 2>&1; then
    assert_pass "T1 snapshot created state branch $STATE_BRANCH"
else
    assert_fail "T1 snapshot created state branch" "branch missing"
fi

# ─── T2: publish to a BARE remote and clone fresh (CI cross-runner simulation) ─
bare="$TEST_TEMP_DIR/origin.git"
"$GIT" init -q --bare "$bare"
"$GIT" -C "$fx" remote add origin "$bare"
"$GIT" -C "$fx" push -q origin "main" "$WORK" "$STATE_BRANCH"

# Fresh runner: clone only main (like the CI shallow checkout), then explicitly
# fetch the state + work branches into remote-tracking refs (exactly Layer B).
runner_ws="$TEST_TEMP_DIR/ci-runner"
"$GIT" clone -q --branch main --single-branch "$bare" "$runner_ws"
"$GIT" -C "$runner_ws" config user.email t@t.t; "$GIT" -C "$runner_ws" config user.name t
"$GIT" -C "$runner_ws" fetch -q origin "refs/heads/$STATE_BRANCH:refs/remotes/origin/$STATE_BRANCH" || true
"$GIT" -C "$runner_ws" fetch -q origin "refs/heads/$WORK:refs/remotes/origin/$WORK" || true

if "$GIT" -C "$runner_ws" rev-parse -q --verify "refs/remotes/origin/$STATE_BRANCH" >/dev/null 2>&1; then
    assert_pass "T2 fresh runner has origin/$STATE_BRANCH after fetch (restore source present)"
else
    assert_fail "T2 fresh runner has origin/$STATE_BRANCH" "remote-tracking ref missing"
fi

# ─── T3: restore on the fresh runner (via the origin/<branch> fallback) ────────
# This is exactly what runner.sh does once at startup.
restored_root="$runner_ws/state/restored-artifacts"
_artifact_persist_restore "$ISSUE" "$restored_root" "$runner_ws"
if [[ -s "$restored_root/artifacts/design.md" ]]; then
    assert_pass "T3 restore populated restored-artifacts/artifacts/ on the fresh runner"
else
    assert_fail "T3 restore populated artifacts" "design.md absent after restore"
fi

# ─── T4: the seam picks up the restored artifacts (what every wired stage does) ─
# runner.sh exports ZBUILD_RESTORED_ARTIFACTS_DIR at the artifacts subdir.
export ZBUILD_RESTORED_ARTIFACTS_DIR="$restored_root/artifacts"
unset ZBUILD_CYCLE_ITER ZBUILD_CYCLE_FEEDBACK_DIR
export ZBUILD_STATE_DIR="$runner_ws/state"   # empty artifacts/ locally → not the source

got_design="$(_read_prior_output "design.md")"
assert_contains "T4 seam returns the restored design (cross-run tier)" "$got_design" "acceptance contract from the earlier attempt"
got_plan="$(_read_prior_output "plan.json")"
assert_contains "T4 seam returns the restored plan.json" "$got_plan" "prior plan goal"
got_bs="$(_read_prior_output "build-summary.json")"
assert_contains "T4 seam returns the restored build-summary" "$got_bs" "empty_diff"

# ─── T5: cross-run tier beats the local state fallback ────────────────────────
# Seam order is intra-cycle > restored > local. With a DIFFERENT local copy and no
# cycle, the restored (prior-run) artifact must win.
mkdir -p "$ZBUILD_STATE_DIR/artifacts"
printf 'LOCAL STALE DESIGN — must not win\n' > "$ZBUILD_STATE_DIR/artifacts/design.md"
got_design2="$(_read_prior_output "design.md")"
assert_contains "T5 restored (cross-run) beats local fallback" "$got_design2" "earlier attempt"
if [[ "$got_design2" == *"LOCAL STALE"* ]]; then
    assert_fail "T5 restored beats local fallback" "local stale copy leaked through"
else
    assert_pass "T5 local stale copy did not leak"
fi

# ─── T6: absent state branch → restore no-op, seam falls through to empty ──────
runner_ws2="$TEST_TEMP_DIR/ci-runner-firstrun"
"$GIT" clone -q --branch main --single-branch "$bare" "$runner_ws2"
none_root="$runner_ws2/state/restored-artifacts"
_artifact_persist_restore $_ZB_ID "$none_root" "$runner_ws2"
if [[ ! -d "$none_root/artifacts" ]]; then
    assert_pass "T6 restore of an issue with no state branch is a clean no-op"
else
    assert_fail "T6 restore no-op" "created a dir when no state branch exists"
fi
unset ZBUILD_RESTORED_ARTIFACTS_DIR
export ZBUILD_STATE_DIR="$runner_ws2/state"   # no artifacts/ here
[[ -z "$(_read_prior_output "design.md")" ]] \
    && assert_pass "T6 seam returns empty when nothing is available (first run)" \
    || assert_fail "T6 seam returns empty on first run" "got non-empty"

# ─── T7: pr-open remote-aware preflight ref math (the #1570 fix) ───────────────
# On the fresh runner, HEAD (main) is at the merge-base; origin/<work> carries the
# real commit. The preflight decides shippability by counting merge-base..origin/work.
mb="$("$GIT" -C "$runner_ws" merge-base main "refs/remotes/origin/$WORK" 2>/dev/null || true)"
local_ahead="$("$GIT" -C "$runner_ws" rev-list --count "${mb}..HEAD" 2>/dev/null || echo -1)"
remote_ahead="$("$GIT" -C "$runner_ws" rev-list --count "${mb}..refs/remotes/origin/$WORK" 2>/dev/null || echo -1)"
assert_eq "T7 local HEAD has 0 commits ahead of merge-base (cold start)" "0" "$local_ahead"
if [[ "$remote_ahead" =~ ^[0-9]+$ && "$remote_ahead" -gt 0 ]]; then
    assert_pass "T7 origin/<work> has commits ⇒ preflight proceeds (not 'nothing to ship')"
else
    assert_fail "T7 origin/<work> has commits" "remote_ahead=$remote_ahead"
fi

# ─── T8: zbuild_push_reconcile no-ops on a strictly-ahead remote (#1570 loop) ──
# The exact scenario that broke #1570: this run's local branch is BEHIND origin's
# (origin carries the real work). pr-open falls through to push_reconcile, which
# MUST NOT overwrite the remote — it returns 0 (no-op) and leaves origin intact,
# so the subsequent PR reuse/create ships origin's work. Exercise it directly.
remote_work_before="$("$GIT" -C "$runner_ws" ls-remote --heads origin "$WORK" 2>/dev/null | awk '{print $1}')"
set +e
( cd "$runner_ws" && zbuild_push_reconcile "$WORK" >/dev/null 2>&1 ); pr_rc=$?
set -e
assert_eq "T8 push_reconcile returns 0 (no-op) when remote is strictly ahead" "0" "$pr_rc"
remote_work_after="$("$GIT" -C "$runner_ws" ls-remote --heads origin "$WORK" 2>/dev/null | awk '{print $1}')"
assert_eq "T8 origin/<work> tip is UNCHANGED (prior work never clobbered)" "$remote_work_before" "$remote_work_after"

cleanup_test_env
print_test_results
