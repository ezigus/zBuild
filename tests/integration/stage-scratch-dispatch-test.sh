#!/usr/bin/env bash
# tests/integration/stage-scratch-dispatch-test.sh
# The dispatch seam states where a stage may write (#1918, ADR-058 §3).
#
# SPEC-2[change]: plugin_hook_call exports ZBUILD_STAGE_SCRATCH,
#                 ZBUILD_ARTIFACT_DIR and TMPDIR for the span of one dispatch
#                 and unsets all three on return.
#
# Integration rather than unit because the claim is about the real
# plugin_hook_call reaching a real plugin subshell: every part that could break
# — the `local -x` restore, the non-empty-$2 guard, the map-element key, and a
# plugin's own `${TMPDIR:-/tmp}` mktemp landing in bounds — is only observable
# from inside a dispatch.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"

print_test_header "stage scratch at the dispatch seam — ZBUILD_STAGE_SCRATCH / ZBUILD_ARTIFACT_DIR / TMPDIR (#1918)"
setup_test_env "stage-scratch-dispatch"

FIXTURE_DIR="$TEST_TEMP_DIR/plugins/tool/fixture-writer"
mkdir -p "$FIXTURE_DIR"

JOB_DIR="$TEST_TEMP_DIR/state/runs/20260822-0002"
mkdir -p "$JOB_DIR"
STATE_FILE="$JOB_DIR/pipeline-state.json"
echo '{}' > "$STATE_FILE"

# Where the fixture reports what it saw. Deliberately NOT under the job dir, so
# nothing about the report depends on the thing under test.
REPORT="$TEST_TEMP_DIR/seen.env"

# ── Stubs ───────────────────────────────────────────────────────────────────
emit_event() { :; }
verify_plugin_for_source() { return 0; }
scan_plugin_outputs() { return 0; }

cat > "$FIXTURE_DIR/manifest.yaml" <<'MANIFEST_EOF'
id: fixture-writer
name: Fixture Writer
kind: tool
version: 0.0.1
hooks:
  run: fixture_run
MANIFEST_EOF

# The fixture records the three variables as the plugin subshell sees them, and
# then does what ~20 real call sites do — mktemp against ${TMPDIR:-/tmp} — so the
# "relocates every consumer with zero plugin edits" claim is tested rather than
# asserted. Nothing here mentions ZBUILD_STAGE_SCRATCH; that is the point.
cat > "$FIXTURE_DIR/plugin.sh" <<'PLUGIN_EOF'
fixture_run() {
    local made; made="$(mktemp -d "${TMPDIR:-/tmp}/fixture-work.XXXXXX" 2>/dev/null || echo "")"
    {
        printf 'SCRATCH=%s\n' "${ZBUILD_STAGE_SCRATCH:-<unset>}"
        printf 'TMPDIR=%s\n'  "${TMPDIR:-<unset>}"
        printf 'ARTIFACT=%s\n' "${ZBUILD_ARTIFACT_DIR:-<unset>}"
        printf 'MKTEMP=%s\n'  "${made:-<none>}"
    } > "$ZB_FIXTURE_REPORT"
}
PLUGIN_EOF

export ZB_FIXTURE_REPORT="$REPORT"

_seen() { /usr/bin/grep -m1 "^$1=" "$REPORT" 2>/dev/null | cut -d= -f2-; }

# ── Pre-dispatch environment ────────────────────────────────────────────────
# setup_test_env unsets ZBUILD_ARTIFACT_DIR and sandboxes the process; re-export
# a canary so the restore assertions below have a value to come back to. This is
# the shape of the real thing: scripts/lib/test-helpers.sh saves and restores
# ZBUILD_ARTIFACT_DIR around every test, and the new `local -x` layers over it.
SANDBOX_ARTIFACTS="$TEST_TEMP_DIR/sandbox-artifacts"
export ZBUILD_ARTIFACT_DIR="$SANDBOX_ARTIFACTS"
ORIG_TMPDIR="${TMPDIR:-}"
unset ZBUILD_STAGE_SCRATCH 2>/dev/null || true

# ── SPEC-2: the three vars reach the plugin subshell ────────────────────────
: > "$REPORT"
plugin_hook_call "$FIXTURE_DIR" "run" "build" "$STATE_FILE" || true

EXPECT_SCRATCH="$JOB_DIR/scratch/build"
assert_eq "[SPEC-2] the plugin subshell sees ZBUILD_STAGE_SCRATCH" \
    "$EXPECT_SCRATCH" "$(_seen SCRATCH)"
assert_eq "[SPEC-2] the plugin subshell sees TMPDIR pointed at the same dir" \
    "$EXPECT_SCRATCH" "$(_seen TMPDIR)"
assert_eq "[SPEC-2] the plugin subshell sees ZBUILD_ARTIFACT_DIR at <state_dir>/artifacts" \
    "$JOB_DIR/artifacts" "$(_seen ARTIFACT)"

if [[ -d "$EXPECT_SCRATCH" ]]; then
    assert_pass "[SPEC-2] the dispatch CREATED the scratch dir, it did not merely name one"
else
    assert_fail "[SPEC-2] the dispatch must create the scratch dir" "missing: $EXPECT_SCRATCH"
fi

# The zero-plugin-edits claim: an unmodified `${TMPDIR:-/tmp}` call site lands in
# bounds. Without the TMPDIR redirect this is /var/folders on macOS, /tmp on Linux.
_mk="$(_seen MKTEMP)"
if [[ -n "$_mk" && "$_mk" == "$EXPECT_SCRATCH"/* ]]; then
    assert_pass "[SPEC-2] an unmodified \${TMPDIR:-/tmp} mktemp inside the plugin lands in scratch"
else
    assert_fail "[SPEC-2] a plugin's own \${TMPDIR:-/tmp} write must land in scratch" \
        "mktemp=[$_mk] scratch=[$EXPECT_SCRATCH]"
fi

# ── SPEC-2: all three are gone on return ────────────────────────────────────
# `local -x` restores the prior value AND the prior export attribute. Stage N's
# scratch must not bleed into stage N+1, and TMPDIR in particular must come back
# to the caller's own value rather than being left unset — the engine and the
# test harness both keep using it after the dispatch returns.
if [[ -z "${ZBUILD_STAGE_SCRATCH:-}" ]]; then
    assert_pass "[SPEC-2] ZBUILD_STAGE_SCRATCH does not survive the dispatch"
else
    assert_fail "[SPEC-2] ZBUILD_STAGE_SCRATCH must not survive the dispatch" "${ZBUILD_STAGE_SCRATCH:-}"
fi
assert_eq "[SPEC-2] TMPDIR is restored to the caller's value, not left pointing at scratch" \
    "$ORIG_TMPDIR" "${TMPDIR:-}"
assert_eq "[SPEC-2] the harness's sandboxed ZBUILD_ARTIFACT_DIR is restored intact" \
    "$SANDBOX_ARTIFACTS" "${ZBUILD_ARTIFACT_DIR:-}"

# ── SPEC-2: stage N's scratch cannot bleed into stage N+1 ───────────────────
: > "$REPORT"
plugin_hook_call "$FIXTURE_DIR" "run" "test" "$STATE_FILE" || true
assert_eq "[SPEC-2] the next stage's dispatch names ITS OWN scratch dir" \
    "$JOB_DIR/scratch/test" "$(_seen SCRATCH)"

# ── SPEC-2: concurrent map members get their own ────────────────────────────
# The `map:` arm exports ZBUILD_MAP_ELEMENT in the generated work unit and
# plugin_hook_call is that script's last line, so the element is ambient here.
: > "$REPORT"
ZBUILD_MAP_ELEMENT="security" plugin_hook_call "$FIXTURE_DIR" "run" "review_lenses" "$STATE_FILE" || true
_sec="$(_seen SCRATCH)"
: > "$REPORT"
ZBUILD_MAP_ELEMENT="performance" plugin_hook_call "$FIXTURE_DIR" "run" "review_lenses" "$STATE_FILE" || true
_perf="$(_seen SCRATCH)"
assert_eq "[SPEC-2] a map member's dispatch is keyed on the element too" \
    "$JOB_DIR/scratch/review_lenses-security" "$_sec"
if [[ -n "$_sec" && "$_sec" != "$_perf" ]]; then
    assert_pass "[SPEC-2] two concurrent map members of one stage get different scratch dirs"
else
    assert_fail "[SPEC-2] concurrent map members must not share a scratch dir" "both=[$_sec]"
fi

# ── SPEC-2: the whole block is guarded on a non-empty state_file ────────────
# tests/unit/plugin-lifecycle-event-balance-test.sh calls
# `plugin_hook_call "$DIR" run "stage-a" ""` — an ad-hoc caller with no job
# folder to be inside. It must reach the plugin with the environment it has
# today: no scratch, no redirect, and the ambient ZBUILD_ARTIFACT_DIR untouched.
# Unguarded, `dirname ""` yields "." and the dispatch would point the stage at
# ./artifacts and ./scratch — relative to whatever CWD the run happened to have.
: > "$REPORT"
# Run this one from a KNOWN-EMPTY directory. The check below is "did the
# dispatch create anything here", so it can only mean that if the caller
# controls what was here first — asserting against the ambient CWD would let an
# unrelated ./artifacts anywhere in the tree decide the result.
_EMPTY_CWD="$TEST_TEMP_DIR/empty-cwd"
mkdir -p "$_EMPTY_CWD"
(
    cd "$_EMPTY_CWD" || exit 1
    plugin_hook_call "$FIXTURE_DIR" "run" "stage-a" "" || true
)
assert_eq "[SPEC-2] an empty state_file gets no scratch dir" "<unset>" "$(_seen SCRATCH)"
assert_eq "[SPEC-2] an empty state_file leaves TMPDIR alone" "$ORIG_TMPDIR" "$(_seen TMPDIR)"
assert_eq "[SPEC-2] an empty state_file leaves the ambient ZBUILD_ARTIFACT_DIR alone" \
    "$SANDBOX_ARTIFACTS" "$(_seen ARTIFACT)"
_stray="$(find "$_EMPTY_CWD" -mindepth 1 2>/dev/null | sort | tr '\n' ' ')"
if [[ -z "$_stray" ]]; then
    assert_pass "[SPEC-2] an empty state_file writes no ./scratch or ./artifacts beside the CWD"
else
    assert_fail "[SPEC-2] an empty state_file must not resolve paths against the CWD" \
        "stray=[$_stray] cwd=[$_EMPTY_CWD]"
fi

# ── SPEC-2: a RELATIVE state_file is refused too ────────────────────────────
# The guard is on $2 being ABSOLUTE, not merely non-empty, and this is the case
# that makes the difference. `dirname arg2` is ".", and by the time a stage
# dispatches the runner has cd'd into the run's worktree (ADR-052) — so a
# relative state_file would put scratch/ and artifacts/ INSIDE the repository
# under change. That is the exact leak ADR-058 exists to close, reintroduced by
# ADR-058's own block.
#
# Not hypothetical: tests/integration/core-plugin-registry-test.sh dispatches
# `plugin_hook_call <dir> run arg1 arg2` positionally, and a non-empty-only
# guard let that write ./scratch/arg1/ into the repo root — caught by `git add`
# rather than by any assertion, which is why this one exists.
_REL_CWD="$TEST_TEMP_DIR/relative-cwd"
mkdir -p "$_REL_CWD"
: > "$REPORT"
(
    cd "$_REL_CWD" || exit 1
    plugin_hook_call "$FIXTURE_DIR" "run" "arg1" "arg2" || true
)
assert_eq "[SPEC-2] a relative state_file gets no scratch dir" "<unset>" "$(_seen SCRATCH)"
assert_eq "[SPEC-2] a relative state_file leaves TMPDIR alone" "$ORIG_TMPDIR" "$(_seen TMPDIR)"
assert_eq "[SPEC-2] a relative state_file leaves the ambient ZBUILD_ARTIFACT_DIR alone" \
    "$SANDBOX_ARTIFACTS" "$(_seen ARTIFACT)"
_rel_stray="$(find "$_REL_CWD" -mindepth 1 2>/dev/null | sort | tr '\n' ' ')"
if [[ -z "$_rel_stray" ]]; then
    assert_pass "[SPEC-2] a relative state_file writes nothing into the CWD (the repo under change)"
else
    assert_fail "[SPEC-2] a relative state_file must not write into the CWD — that is the repo under change" \
        "stray=[$_rel_stray]"
fi

# ── SPEC-2: scratch survives between iterations of one stage ────────────────
# The build stage re-runs up to 8x. Whatever iteration 1 left must still be
# there for iteration 2 — that is the property that rules out $TMPDIR entirely.
: > "$JOB_DIR/scratch/build/iteration-1.marker"
: > "$REPORT"
plugin_hook_call "$FIXTURE_DIR" "run" "build" "$STATE_FILE" || true
assert_file_exists "[SPEC-2] a second dispatch of one stage finds the first's working files" \
    "$JOB_DIR/scratch/build/iteration-1.marker"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
