#!/usr/bin/env bash
# Tests: the persist stage (#1071) — the run-end snapshot, the push that never
# existed, and the secret gate that stands in front of it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/secret-patterns.sh
source "$REPO_ROOT/scripts/lib/secret-patterns.sh"
# shellcheck source=../../core/state/artifact-persist.sh
source "$REPO_ROOT/core/state/artifact-persist.sh"

print_test_header "persist stage (#1071)"
setup_test_env "zb-persist"

# #1921: persist_run snapshots into whatever repo is CWD. A call made outside a
# throwaway repo writes refs/heads/zbuild/state/* into the developer's OWN
# checkout — and pushes it, which is how the origin residue branch was created.
# Captured here, asserted unchanged at the end.
_REPO_STATE_REFS_BEFORE="$(git -C "$REPO_ROOT" for-each-ref \
    --format='%(refname)' 'refs/heads/zbuild/state/*' 2>/dev/null | sort || true)"

# A real repo with a real bare remote. The subject is a `git push`, so a mocked
# git would prove nothing about whether anything actually leaves the machine.
_mk_repo() {
    local name="$1"
    local remote="$TEST_TEMP_DIR/$name-remote.git"
    local repo="$TEST_TEMP_DIR/$name"
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

_remote_has() {
    ( cd "$1" && git ls-remote --heads origin "refs/heads/$2" 2>/dev/null | /usr/bin/grep -c . ) || true
}

_seed_artifacts() {
    local state_dir="$1" content="${2:-plan content}"
    mkdir -p "$state_dir/artifacts"
    printf '%s\n' "$content" > "$state_dir/artifacts/plan.json"
}

# ─── [SPEC-1][change] the push that never existed ───────────────────────────
# artifact-persist.sh has never contained a `git push`. It writes a LOCAL ref;
# the only push in the repository is a workflow `run:` block no local run
# executes. #1921 measured hundreds of local commits and nothing on origin.
print_test_section "[SPEC-1][change] _artifact_persist_push puts the branch on origin"

_P1="$(_mk_repo p1)"
_P1_STATE="$TEST_TEMP_DIR/p1-state"
_seed_artifacts "$_P1_STATE"

( cd "$_P1" && _artifact_persist_snapshot "$_P1_STATE" 4242 ) >/dev/null 2>&1
assert_eq "[SPEC-1] premise: the snapshot wrote a LOCAL branch" "1" \
    "$( cd "$_P1" && git rev-parse -q --verify refs/heads/zbuild/state/issue-4242 >/dev/null 2>&1 && echo 1 || echo 0 )"
# And that local branch is, on its own, invisible to origin — which is the whole
# defect. Asserted rather than assumed, so SPEC-1 cannot pass vacuously.
assert_eq "[SPEC-1] premise: a snapshot alone reaches origin NOT AT ALL" "0" \
    "$(_remote_has "$_P1" zbuild/state/issue-4242)"

_rc=0
( cd "$_P1" && _artifact_persist_push 4242 ) >/dev/null 2>&1 || _rc=$?
assert_exit_code "[SPEC-1] the push succeeds" "0" "$_rc"
assert_eq "[SPEC-1] the state branch is now ON ORIGIN" "1" \
    "$(_remote_has "$_P1" zbuild/state/issue-4242)"

# ─── [push-guard] a push that cannot work fails LOUDLY, never fatally ────────
# A silent push failure is how #1921 went unnoticed for the life of the feature.
print_test_section "[push-guard] an unreachable remote sets a reportable status"

_P2="$(_mk_repo p2)"
_P2_STATE="$TEST_TEMP_DIR/p2-state"
_seed_artifacts "$_P2_STATE"
( cd "$_P2" && _artifact_persist_snapshot "$_P2_STATE" 4243 ) >/dev/null 2>&1
( cd "$_P2" && git remote set-url origin "$TEST_TEMP_DIR/does-not-exist.git" ) >/dev/null 2>&1

_rc=0
( cd "$_P2" && _artifact_persist_push 4243 ) >/dev/null 2>&1 || _rc=$?
assert_exit_code "[push-guard] an unreachable remote returns non-zero" "1" "$_rc"
_p2_reason="$( cd "$_P2" && _artifact_persist_push 4243 >/dev/null 2>&1; printf '%s' "${_ARTIFACT_PERSIST_LAST_REASON:-}" )"
assert_contains "[push-guard] and names the failing operation" "$_p2_reason" "git push"

# No branch, no remote: both are 'nothing to do', NOT failures — a run that
# snapshotted nothing has not failed to publish anything.
_P3="$(_mk_repo p3)"
_rc=0
( cd "$_P3" && _artifact_persist_push 9999 ) >/dev/null 2>&1 || _rc=$?
assert_exit_code "[push-guard] no local branch to push is not a failure" "0" "$_rc"

# ─── [gate-guard] the secret gate stands in front of the push ────────────────
# These artifacts are already snapshotted to a LOCAL branch today with no scan.
# This stage is what makes them leave the machine, so the gate belongs here.
print_test_section "[gate-guard] an artifact carrying a credential refuses the push"

# shellcheck source=../../plugins/tool/persist/plugin.sh
source "$REPO_ROOT/plugins/tool/persist/plugin.sh"

_S_DIR="$TEST_TEMP_DIR/scan/artifacts"
mkdir -p "$_S_DIR"
printf 'just a plan\n' > "$_S_DIR/plan.json"
if _persist_scan_artifacts "$TEST_TEMP_DIR/scan/artifacts" >/dev/null; then
    assert_fail "[gate-guard] a clean artifact area must scan clean" "reported a finding"
else
    assert_pass "[gate-guard] a clean artifact area scans clean"
fi

# AKIA + 16 chars — the shared pattern, not a locally invented one.
printf 'aws: AKIA%s\n' "ABCDEFGHIJKLMNOP" > "$_S_DIR/leak.txt"
_finding="$(_persist_scan_artifacts "$TEST_TEMP_DIR/scan/artifacts" || true)"
assert_contains "[gate-guard] a credential-shaped artifact is found" "$_finding" "aws_access_key_id"
assert_contains "[gate-guard] and the finding names the FILE" "$_finding" "leak.txt"

# ─── [SPEC-4][guard] the extraction did not change what counts as a secret ──
# The patterns were calibrated against this repository in #1755 — the issue's
# premise was false until they were MEASURED. Moving them must not drift them.
print_test_section "[SPEC-4][guard] the extracted patterns behave identically"

assert_eq "[SPEC-4] AWS key id" "aws_access_key_id" \
    "$(zbuild_scan_secret_content "AKIAABCDEFGHIJKLMNOP" || true)"
assert_eq "[SPEC-4] credential assignment" "credential_assignment" \
    "$(zbuild_scan_secret_content 'api_key = hunter2hunter2' || true)"
# The #1755 calibration case: a workflow variable reference is NOT a secret.
# Without the whitespace exclusion this flagged every env block in the repo.
if zbuild_scan_secret_content 'token: ${{ secrets.GITHUB_TOKEN }}' >/dev/null; then
    assert_fail "[SPEC-4] a \${{ secrets.X }} reference must NOT be a finding" "flagged"
else
    assert_pass "[SPEC-4] a \${{ secrets.X }} reference is not a finding (#1755)"
fi
if zbuild_scan_secret_content 'nothing to see here' >/dev/null; then
    assert_fail "[SPEC-4] ordinary prose must not be a finding" "flagged"
else
    assert_pass "[SPEC-4] ordinary prose is not a finding"
fi

# ─── [SPEC-5][guard] persist never changes the run's fate ───────────────────
# Persistence is advisory. A run that produced good work and could not reach the
# network still produced good work.
print_test_section "[SPEC-5][guard] persist_run always returns 0"

export ZBUILD_ARTIFACT_DIR="$TEST_TEMP_DIR/r5/artifacts"
mkdir -p "$ZBUILD_ARTIFACT_DIR"
printf 'clean\n' > "$ZBUILD_ARTIFACT_DIR/plan.json"

# No issue number — a --goal run. Nothing to persist, and not a failure.
_rc=0
( ZBUILD_ISSUE_NUMBER=0 ZBUILD_STATE_DIR="$TEST_TEMP_DIR/r5" persist_run persist "" ) >/dev/null 2>&1 || _rc=$?
assert_exit_code "[SPEC-5] a --goal run (no issue) returns 0" "0" "$_rc"
assert_file_exists "[SPEC-5] and still writes its result file" \
    "$ZBUILD_ARTIFACT_DIR/persist-result.json"

# A credential present: refused, still 0, and the result says degraded.
printf 'aws: AKIA%s\n' "ABCDEFGHIJKLMNOP" > "$ZBUILD_ARTIFACT_DIR/leak.txt"
_rc=0
# In a throwaway repo: persist_run snapshots into CWD, so an identity run made
# from the source checkout writes a state ref there (guarded by SPEC-6).
_R5="$(_mk_repo r5repo)"
( cd "$_R5" && ZBUILD_ISSUE_NUMBER=4244 ZBUILD_STATE_DIR="$TEST_TEMP_DIR/r5" persist_run persist "" ) >/dev/null 2>&1 || _rc=$?
assert_exit_code "[SPEC-5] a refused push still returns 0" "0" "$_rc"
assert_eq "[SPEC-5] and records degraded, not complete" "degraded" \
    "$(jq -r '.verdict' "$ZBUILD_ARTIFACT_DIR/persist-result.json" 2>/dev/null)"
assert_eq "[SPEC-5] and records that nothing was pushed" "false" \
    "$(jq -r '.data.pushed' "$ZBUILD_ARTIFACT_DIR/persist-result.json" 2>/dev/null)"

# ─── [SPEC-2][change] data.identity_present=false for the no-identity path ────
# persist_run writes identity_present:false when there is no issue/goal identity
# and short-circuits before taking a snapshot. This field is new — at baseline
# _persist_write_result did not write it, so any assertion on it fails there.
print_test_section "[SPEC-2][change] data.identity_present=false when no identity"

_s2dir="$TEST_TEMP_DIR/s2"
mkdir -p "$_s2dir/artifacts"
printf 'clean\n' > "$_s2dir/artifacts/plan.json"
( ZBUILD_ISSUE_NUMBER=0 ZBUILD_ARTIFACT_DIR="$_s2dir/artifacts" \
  ZBUILD_STATE_DIR="$_s2dir" persist_run persist "" ) >/dev/null 2>&1 || true
# Guard: snapshot still shows skipped (existing invariant, no [SPEC-N] tag).
assert_eq "[data-snapshot-guard] no-identity run writes data.snapshot=skipped" \
    "skipped" \
    "$(jq -r '.data.snapshot // empty' "$_s2dir/artifacts/persist-result.json" 2>/dev/null)"
# Change: identity_present is a NEW field — absent at baseline (jq returns "null").
assert_eq "[SPEC-2] no-identity run writes data.identity_present=false in persist-result.json" \
    "false" \
    "$(jq -r '.data.identity_present | tostring' "$_s2dir/artifacts/persist-result.json" 2>/dev/null)"

# ─── [SPEC-3][change] data.identity_present=true after a credential-refused push
# The snapshot runs at step 1 of persist_run for identity runs, BEFORE the secret
# gate at step 2. A push refused by the gate is still an identity run, so
# identity_present must be true. This field is new — absent at baseline.
print_test_section "[SPEC-3][change] data.identity_present=true for identity run"

_s3dir="$TEST_TEMP_DIR/s3"
mkdir -p "$_s3dir/artifacts"
printf 'clean\n' > "$_s3dir/artifacts/plan.json"
printf 'aws: AKIA%s\n' "ABCDEFGHIJKLMNOP" > "$_s3dir/artifacts/leak.txt"
_S3REPO="$(_mk_repo s3repo)"
( cd "$_S3REPO" && ZBUILD_ISSUE_NUMBER=4244 ZBUILD_ARTIFACT_DIR="$_s3dir/artifacts" \
  ZBUILD_STATE_DIR="$_s3dir" persist_run persist "" ) >/dev/null 2>&1 || true
# Guard: snapshot field still carries the outcome (existing invariant).
_snap3="$(jq -r '.data.snapshot // empty' "$_s3dir/artifacts/persist-result.json" 2>/dev/null)"
if [[ -n "$_snap3" && "$_snap3" != "skipped" && "$_snap3" != "null" ]]; then
    assert_pass "[data-snapshot-guard] credential-refused persist writes non-null/non-skipped snapshot (got: $_snap3)"
else
    assert_fail "[data-snapshot-guard] credential-refused persist must write data.snapshot from snapshot before gate" \
        "got: [${_snap3:-<empty>}]"
fi
# Change: identity_present is a NEW field — absent at baseline (jq returns "null").
assert_eq "[SPEC-3] credential-refused persist writes data.identity_present=true in persist-result.json" \
    "true" \
    "$(jq -r '.data.identity_present | tostring' "$_s3dir/artifacts/persist-result.json" 2>/dev/null)"

# ─── [SPEC-6][guard] the suite leaves no state refs in the real checkout ─────
# Every persist_run above must run inside a throwaway repo. If one does not, the
# snapshot lands in this repository and a later push publishes it to origin.
print_test_section "[SPEC-6][guard] the suite writes no state refs into REPO_ROOT"

_REPO_STATE_REFS_AFTER="$(git -C "$REPO_ROOT" for-each-ref \
    --format='%(refname)' 'refs/heads/zbuild/state/*' 2>/dev/null | sort || true)"
_LEAKED="$(comm -13 <(printf '%s\n' "$_REPO_STATE_REFS_BEFORE") \
                    <(printf '%s\n' "$_REPO_STATE_REFS_AFTER") | tr '\n' ' ')"
_LEAKED="${_LEAKED#"${_LEAKED%%[![:space:]]*}"}"
_LEAKED="${_LEAKED%"${_LEAKED##*[![:space:]]}"}"
if [[ -z "$_LEAKED" ]]; then
    assert_pass "[SPEC-6] no zbuild/state ref was created in the real checkout"
else
    assert_fail "[SPEC-6] the suite leaked state refs into the real checkout" "$_LEAKED"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
