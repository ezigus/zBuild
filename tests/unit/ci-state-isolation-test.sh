#!/usr/bin/env bash
# tests/unit/ci-state-isolation-test.sh
# CI must keep run state OUTSIDE the repository it is editing (#1638).
#
# #1629 moved the engine out of the target and #888 moved the work into a per-run
# worktree, but state stayed pinned at ${{ github.workspace }}/state — so the run's
# own bookkeeping still landed in the tree under test, and in a different tree from
# the worktree the work happens in. This is the third axis.
#
# SPEC-1[change]: the workflow's own resolve-step, executed, yields a state dir
#                 OUTSIDE $GITHUB_WORKSPACE
# SPEC-2[change]: the artifact upload path is the SAME value, so the two cannot drift
# SPEC-3[guard]:  artifacts still upload on failure (if: always())
# SPEC-4[change]: no workflow anywhere pins the state dir under github.workspace
# SPEC-5[change]: an empty upload is reported (if-no-files-found != ignore)
#
# SPEC-1 executes the YAML's shell rather than pattern-matching it: a textual
# assertion would pass against a step that sets the variable and is never reached.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "CI state isolation — state outside the workspace (#1638)"
setup_test_env "ci-state-isolation"

WF="$REPO_ROOT/.github/workflows/zbuild-pipeline.yml"

# ── SPEC-1: run the workflow's resolve-step for real ────────────────────────
# Pull the `run:` body of the state-resolving step out of the YAML and execute it
# with a fake runner environment. Whatever that shell writes to $GITHUB_ENV is what
# the real job would export.
_extract_run_block() {
    awk '
        /^      - name: Resolve state directory/ { instep = 1; next }
        instep && /^      - name: /              { exit }
        instep && /^        run: \|/             { inrun = 1; next }
        inrun  && /^        [a-z]/               { exit }   # next key at step level
        inrun                                    { sub(/^          /, ""); print }
    ' "$WF"
}

_BLOCK="$(_extract_run_block)"
_FAKE_WS="$TEST_TEMP_DIR/workspace"
_FAKE_TMP="$TEST_TEMP_DIR/runner-temp"
mkdir -p "$_FAKE_WS" "$_FAKE_TMP"
_GH_ENV="$TEST_TEMP_DIR/github_env"
: > "$_GH_ENV"

if [[ -n "$_BLOCK" ]]; then
    (
        export RUNNER_TEMP="$_FAKE_TMP" GITHUB_WORKSPACE="$_FAKE_WS" GITHUB_ENV="$_GH_ENV"
        bash -c "$_BLOCK"
    ) >/dev/null 2>&1
fi
_STATE_DIR="$(grep -m1 '^ZBUILD_STATE_DIR=' "$_GH_ENV" 2>/dev/null | cut -d= -f2-)"

if [[ -n "$_STATE_DIR" && "$_STATE_DIR" != "$_FAKE_WS"* ]]; then
    assert_pass "[SPEC-1] the resolved state dir is outside the workspace"
else
    assert_fail "[SPEC-1] CI must not place run state inside the repo it is editing" \
        "resolved=[$_STATE_DIR] workspace=[$_FAKE_WS] block_found=$([[ -n "$_BLOCK" ]] && echo yes || echo NO)"
fi

# ── SPEC-2: the upload path is the same value, not a second literal ─────────
# Two independent literals would drift: the state moves, the upload keeps pointing
# at the old place, and `if-no-files-found` means nobody hears about it.
_UPLOAD_PATH="$(awk '
    /^      - name: Upload pipeline artifacts/ { instep = 1 }
    instep && /^          path: /              { sub(/^          path: /, ""); print; exit }
' "$WF")"
if [[ "$_UPLOAD_PATH" == *'env.ZBUILD_STATE_DIR'* ]]; then
    assert_pass "[SPEC-2] the upload path derives from the resolved state dir"
else
    assert_fail "[SPEC-2] upload path must reference the state dir, not a second literal" \
        "path=[$_UPLOAD_PATH]"
fi

# ── SPEC-3: failures still upload (CI-5's actual purpose) ───────────────────
# The reason state was pinned into the workspace was to get it uploaded. Moving it
# is only correct if the diagnostics still arrive — especially on failure, which is
# when they matter.
_ALWAYS="$(awk '
    /^      - name: Upload pipeline artifacts/ { instep = 1 }
    instep && /^        if: /                  { sub(/^        if: /, ""); print; exit }
' "$WF")"
assert_eq "[SPEC-3] pipeline artifacts upload on failure too" "always()" "$_ALWAYS"

# ── SPEC-5: a wrong path is not silent ──────────────────────────────────────
# The path is computed now, not a literal. `ignore` would turn a mistake into an
# empty artifact on a green run — the exact silent-no-op class #1634 was filed for.
_NOTFOUND="$(awk '
    /^      - name: Upload pipeline artifacts/ { instep = 1 }
    instep && /^          if-no-files-found: / { sub(/^          if-no-files-found: /, ""); print; exit }
' "$WF")"
if [[ "$_NOTFOUND" != "ignore" ]]; then
    assert_pass "[SPEC-5] an empty artifact upload is reported, not silently ignored"
else
    assert_fail "[SPEC-5] a wrong state path must not upload nothing in silence" \
        "if-no-files-found=[$_NOTFOUND]"
fi

# ── SPEC-4: no workflow pins state under the workspace ──────────────────────
_OFFENDERS="$(grep -rn 'ZBUILD_STATE_DIR' "$REPO_ROOT/.github/workflows/" 2>/dev/null \
    | grep 'github\.workspace' || true)"
if [[ -z "$_OFFENDERS" ]]; then
    assert_pass "[SPEC-4] no workflow pins ZBUILD_STATE_DIR inside github.workspace"
else
    assert_fail "[SPEC-4] state must never be pinned inside the workspace" "$_OFFENDERS"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
