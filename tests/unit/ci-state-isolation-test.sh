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
# SPEC-5[change]: an empty upload is reported (if-no-files-found == warn)
# SPEC-6[change]: the resolve step still runs after an earlier step fails
# SPEC-7[change]: the upload EXCLUDES the scratch directory (#1918 / ADR-058 §5)
# SPEC-8[change]: the persist outcome is surfaced in the job log, always (#1921)
# SPEC-9[change]: the hydrate outcome is surfaced the same way, always (#1921)
# SPEC-10[change]: both surface steps read the LIVE artifacts/ path, never a
#                  restored copy of a previous run's result (ADR-059)
# SPEC-11[change]: and the find fallback prunes scratch/ too — the engine
#                  redirects TMPDIR there, so it holds throwaway copies
#
# SPEC-8 is #1921's requirement that a CI run's persist outcome be readable from
# the job log, renumbered to 8 on the same rule as SPEC-7 below: this file's SPEC
# ids are its own. It belongs here because it is an assertion about the same
# workflow's step list that SPEC-3 and SPEC-5 already make.
#
# SPEC-7 is #1918's SPEC-4, renumbered to 7 because this file's SPEC ids are its
# own and 1-6 were already taken by #1638. It lives here rather than in a new
# file because it is the same invariant as SPEC-2 seen from the other side: the
# upload path and the state dir are one value, and #1918 put something inside
# that value which must not leave the machine.
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

# Keep the execution rc: "the block failed" and "there is no block" are different
# faults with the same symptom (an empty state dir), and reporting them the same
# way sends the reader after the wrong one.
_EXEC_RC="n/a"
if [[ -n "$_BLOCK" ]]; then
    (
        export RUNNER_TEMP="$_FAKE_TMP" GITHUB_WORKSPACE="$_FAKE_WS" GITHUB_ENV="$_GH_ENV"
        bash -c "$_BLOCK"
    ) >/dev/null 2>&1
    _EXEC_RC=$?
fi
_STATE_DIR="$(grep -m1 '^ZBUILD_STATE_DIR=' "$_GH_ENV" 2>/dev/null | cut -d= -f2-)"

if [[ -n "$_STATE_DIR" && "$_STATE_DIR" != "$_FAKE_WS"* ]]; then
    assert_pass "[SPEC-1] the resolved state dir is outside the workspace"
else
    assert_fail "[SPEC-1] CI must not place run state inside the repo it is editing" \
        "resolved=[$_STATE_DIR] workspace=[$_FAKE_WS] block_found=$([[ -n "$_BLOCK" ]] && echo yes || echo NO) exec_rc=$_EXEC_RC"
fi

# ── SPEC-6: the resolve step is not skipped when an earlier step fails ──────
# A step with no `if:` is skipped once anything before it has failed. The upload
# below runs on always(), so without this the upload would get an EMPTY path — a
# config error, not "no files found" — turning one early failure into two.
_RESOLVE_IF="$(awk '
    /^      - name: Resolve state directory/ { instep = 1; next }
    instep && /^      - name: /              { exit }
    instep && /^        if: /                { sub(/^        if: /, ""); print; exit }
' "$WF")"
assert_eq "[SPEC-6] the state dir is resolved even when an earlier step failed" \
    "always()" "$_RESOLVE_IF"

# ── SPEC-2: the upload path is the same value, not a second literal ─────────
# Two independent literals would drift: the state moves, the upload keeps pointing
# at the old place, and `if-no-files-found` means nobody hears about it.
# #1918 made `path:` a block scalar (one include + two `!` exclusions), so this
# reads the whole block rather than one line. Comment lines are dropped: the
# block carries an explanation of why scratch is excluded and must be free to.
_extract_upload_path_block() {
    awk '
        /^      - name: Upload pipeline artifacts/ { instep = 1 }
        instep && /^      - name: / && !/Upload pipeline artifacts/ { exit }
        # A lone block-scalar indicator (| |- > >-) is syntax, not a path.
        instep && /^          path:/ { inpath = 1; sub(/^          path:[ ]*/, "");
                                       if (NF && $0 !~ /^[|>][-+]?$/) print; next }
        inpath && /^          [a-z-]+:/ { exit }          # next key at with: level
        inpath && /^ *#/                { next }          # comment inside the block
        inpath && NF                    { sub(/^ */, ""); print }
    ' "$WF"
}
_UPLOAD_PATH="$(_extract_upload_path_block)"
if [[ "$_UPLOAD_PATH" == *'env.ZBUILD_STATE_DIR'* ]]; then
    assert_pass "[SPEC-2] the upload path derives from the resolved state dir"
else
    assert_fail "[SPEC-2] upload path must reference the state dir, not a second literal" \
        "path=[$_UPLOAD_PATH]"
fi

# The include line must still be the bare state dir. An exclusion-only or
# narrowed include would upload nothing (or only part), and `if-no-files-found:
# warn` means SPEC-5 would let it pass as an annotation nobody reads.
_INCLUDES="$(printf '%s\n' "$_UPLOAD_PATH" | /usr/bin/grep -v '^!' || true)"
assert_eq "[SPEC-2] the upload still includes the whole state dir, unnarrowed" \
    '${{ env.ZBUILD_STATE_DIR }}' "$_INCLUDES"

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
# Pin the exact value, not merely "not ignore". `error` is also not `ignore` but
# would FAIL runs that legitimately produce no state (dry runs, aborts before the
# first stage) — the opposite of the intent, and a loose check would wave it through.
assert_eq "[SPEC-5] an empty artifact upload is reported, not silently ignored" \
    "warn" "$_NOTFOUND"

# ── SPEC-7: the upload excludes scratch (#1918, ADR-058 §5) ─────────────────
# The engine now redirects TMPDIR into <state_dir>/scratch/<stage>, so the run's
# entire throwaway working set — the test stage's staging copy of the repo, every
# router mktemp, and the model's own temp writes — is inside the uploaded path.
# It must not ship: gigabytes per run, and RAW UNREDACTED prompts and model
# output carried off the machine, around the redaction chokepoint (ADR-004).
#
# Asserted against the parsed block rather than a `grep scratch` over the file:
# the word appears in the surrounding comment, so a grep would stay green if the
# exclusion lines themselves were deleted.
_EXCLUSIONS="$(printf '%s\n' "$_UPLOAD_PATH" | /usr/bin/grep '^!' || true)"
if printf '%s\n' "$_EXCLUSIONS" | /usr/bin/grep -qF '/scratch/**'; then
    assert_pass "[SPEC-7] the artifact upload excludes the scratch directory"
else
    assert_fail "[SPEC-7] scratch must be excluded from the artifact upload — it holds raw model I/O" \
        "exclusions=[${_EXCLUSIONS:-none}] block=[$_UPLOAD_PATH]"
fi

# Both layouts. The CI job folder IS $ZBUILD_STATE_DIR ($RUNNER_TEMP/zbuild-state),
# so scratch is a direct child there; the local per-run default nests it under
# runs/<id>/. One glob covers one of those, and a resume or a nested run would
# silently ship the other.
_missing_globs=()
for _g in '${{ env.ZBUILD_STATE_DIR }}/scratch/**' '${{ env.ZBUILD_STATE_DIR }}/**/scratch/**'; do
    printf '%s\n' "$_EXCLUSIONS" | /usr/bin/grep -qxF "!$_g" || _missing_globs+=("$_g")
done
assert_eq "[SPEC-7] both the direct-child and the nested scratch layouts are excluded (missing: ${_missing_globs[*]:-none})" \
    "0" "${#_missing_globs[@]}"

# The exclusions are exactly scratch. `!` patterns are how a whole subtree gets
# silently dropped from a diagnostic upload, so anything else here is a defect
# in this step regardless of what it names.
_non_scratch="$(printf '%s\n' "$_EXCLUSIONS" | /usr/bin/grep -v '/scratch/\*\*$' || true)"
if [[ -z "$_non_scratch" ]]; then
    assert_pass "[SPEC-7] the upload excludes nothing except scratch"
else
    assert_fail "[SPEC-7] the upload must not silently drop anything but scratch" "$_non_scratch"
fi

# ── SPEC-4: no workflow pins state under the workspace ──────────────────────
_OFFENDERS="$(grep -rn 'ZBUILD_STATE_DIR' "$REPO_ROOT/.github/workflows/" 2>/dev/null \
    | grep 'github\.workspace' || true)"
if [[ -z "$_OFFENDERS" ]]; then
    assert_pass "[SPEC-4] no workflow pins ZBUILD_STATE_DIR inside github.workspace"
else
    assert_fail "[SPEC-4] state must never be pinned inside the workspace" "$_OFFENDERS"
fi

# ── SPEC-8 [change]: Surface persist result step is always-run ──────────────
# This step (#1921) surfaces persist-result.json fields as ::notice:: annotations
# so an operator can see why a snapshot was skipped or why a push failed without
# downloading the artifact zip. It must run on every outcome — if it were
# conditional it would be absent on the failure cases where it matters most.
# Checking the `if:` key extracted from the YAML also proves the step EXISTS:
# a missing step produces an empty string, which fails the assert_eq below.
_SURFACE_IF="$(awk '
    /^      - name: Surface persist result/ { instep = 1; next }
    instep && /^      - name: /            { exit }
    instep && /^        if: /              { sub(/^        if: /, ""); print; exit }
' "$WF")"
assert_eq "[SPEC-8] Surface persist result step exists and runs on always()" \
    "always()" "$_SURFACE_IF"

# ── SPEC-9 [change]: Surface hydrate result step is always-run ───────────────
# The persist half says what was SAVED; this says what was RESTORED and from
# where. Without it a warm start is inferred rather than read — and #1836 is the
# standing example of an inference credited to the wrong mechanism.
_HYDRATE_IF="$(awk '
    /^      - name: Surface hydrate result/ { instep = 1; next }
    instep && /^      - name: /             { exit }
    instep && /^        if: /               { sub(/^        if: /, ""); print; exit }
' "$WF")"
assert_eq "[SPEC-9] Surface hydrate result step exists and runs on always()" \
    "always()" "$_HYDRATE_IF"

# ── SPEC-10 [change]: the surface steps must not read restored-artifacts/ ────
# ADR-059: restore extracts into a SEPARATE restored-artifacts/ area and
# "input-resolve.sh reads the live path first". An unanchored
# `find "$ZBUILD_STATE_DIR" -name '<stage>-result.json' -print -quit` does not:
# it returns whatever readdir yields first, which on run 33359409653 was the
# RESTORED copy — the job log reported a previous run's hydrate (restored=76)
# while the run itself had restored 95. A diagnostic that reports another run's
# outcome is worse than none.
print_test_section "[SPEC-10][change] surface steps read the live artifacts path"

# grep -q, not `grep -c || printf 0`: grep -c prints 0 AND exits 1, so the
# fallback would append a second 0 and the comparison would read "00".
# lint-grep-c bans that idiom repo-wide, and #1969 extended it to tests/.
if grep -q "find \"\$ZBUILD_STATE_DIR\" -name '[a-z]*-result.json' -print -quit" "$WF"; then
    assert_fail "[SPEC-10] no surface step may search the whole state dir for a result file" \
        "an unanchored find remains — it can return restored-artifacts/"
else
    assert_pass "[SPEC-10] no surface step searches the whole state dir for a result file"
fi

# The prune is the actual protection: without it the fallback can still walk
# into restored-artifacts/. Dropping it would otherwise stay green.
if grep -qE "restored-artifacts.*-prune" "$WF"; then
    assert_pass "[SPEC-10] the find fallback prunes restored-artifacts/"
else
    assert_fail "[SPEC-10] the find fallback must prune restored-artifacts/" \
        "no -prune guard found in the workflow"
fi

# And each step must name the live path explicitly.
for _stage in persist hydrate; do
    if grep -q "ZBUILD_STATE_DIR}\?/artifacts/${_stage}-result.json" "$WF"; then
        assert_pass "[SPEC-10] the ${_stage} step names \$ZBUILD_STATE_DIR/artifacts/${_stage}-result.json"
    else
        assert_fail "[SPEC-10] the ${_stage} step must read the live artifacts path" "not found in workflow"
    fi
done

# ── SPEC-11 [change]: the fallback must prune scratch/ as well ───────────────
# Run 33474879520 proved restored-artifacts/ was only half the hazard. The
# backstop step and the Surface step ran the same lookup ONE SECOND apart and
# disagreed — the backstop parsed a result file ("backstop is a no-op") while
# Surface printed verdict=? snapshot=? pushed=? reason=?. The uploaded artifact
# had no persist-result.json under artifacts/ at all, because the upload
# excludes scratch/ (ADR-058 §3) — which is exactly where the copies they each
# found were living. The engine redirects TMPDIR into <state_dir>/scratch, so
# every stage's throwaway writes land there.
print_test_section "[SPEC-11][change] the find fallback prunes scratch/"

_FALLBACKS="$(grep -cE "find \"\\\$ZBUILD_STATE_DIR\"" "$WF" || true)"
_PRUNES_SCRATCH="$(grep -cE "\-name 'scratch' .*-prune|-prune.*'scratch'" "$WF" || true)"
assert_eq "[SPEC-11] every result-file fallback prunes scratch/" \
    "$_FALLBACKS" "$_PRUNES_SCRATCH"
if [[ "${_FALLBACKS:-0}" -gt 0 ]]; then
    assert_pass "[SPEC-11] and there is at least one fallback to guard"
else
    assert_fail "[SPEC-11] expected at least one result-file fallback" "found none"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
