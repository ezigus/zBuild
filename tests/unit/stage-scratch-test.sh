#!/usr/bin/env bash
# tests/unit/stage-scratch-test.sh
# The engine-owned per-stage scratch directory (#1918, ADR-058 §2/§4).
#
# SPEC-1[change]: the engine resolves one scratch dir per stage inside the job
#                 folder, stable across cycle iterations and distinct per map element.
# SPEC-3[guard]:  the resolved scratch dir is never under the system TMPDIR.
#
# SPEC-3 is a guard with two halves and they are not redundant. The behavioural
# half proves that a resolution performed while TMPDIR points somewhere lands
# elsewhere. The static half proves the resolver never READS TMPDIR — which is
# the property that matters at the dispatch seam, because that seam sets TMPDIR
# *to* the scratch dir. A resolver that read it back would return
# <scratch>/scratch/<stage> on the second call and nest one level deeper on
# every cycle iteration, and the behavioural half alone would not see it: with
# TMPDIR at its system value the first resolution looks perfectly correct.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "stage scratch — the engine-owned per-stage write area (#1918)"
setup_test_env "stage-scratch"

SCRATCH_LIB="$REPO_ROOT/core/pipeline/stage-scratch.sh"
assert_file_exists "[SPEC-1] core/pipeline/stage-scratch.sh exists" "$SCRATCH_LIB"

# shellcheck source=../../core/pipeline/stage-scratch.sh
source "$SCRATCH_LIB"

JOB_DIR="$TEST_TEMP_DIR/state/runs/20260822-0001"
mkdir -p "$JOB_DIR"

# ── SPEC-1: one dir per stage, inside the job folder ─────────────────────────
_build1="$(stage_scratch_dir "$JOB_DIR" "build" "")"
assert_eq "[SPEC-1] the scratch dir is inside the job folder, under scratch/<stage>" \
    "$JOB_DIR/scratch/build" "$_build1"

# ── SPEC-1: stable across cycle iterations ──────────────────────────────────
# The build stage re-runs up to 8x within one cycle. A resolver carrying an
# iteration counter, a timestamp, or an mktemp suffix would hand iteration 2 an
# empty directory and lose everything iteration 1 staged. Resolve twice with
# nothing but wall-clock between and demand the same answer.
_build2="$(stage_scratch_dir "$JOB_DIR" "build" "")"
assert_eq "[SPEC-1] the same stage resolves to the SAME dir across cycle iterations" \
    "$_build1" "$_build2"

# Belt and braces on the same property: no digit-only path component that could
# be an iteration index, and no mktemp-style XXXXXX residue.
if [[ "$_build1" =~ /(iter)?[0-9]+/?$ ]]; then
    assert_fail "[SPEC-1] the scratch key carries no iteration index" "$_build1"
else
    assert_pass "[SPEC-1] the scratch key carries no iteration index"
fi

# ── SPEC-1: distinct per stage ──────────────────────────────────────────────
_test_stage="$(stage_scratch_dir "$JOB_DIR" "test" "")"
if [[ "$_test_stage" != "$_build1" ]]; then
    assert_pass "[SPEC-1] two different stages resolve to different dirs"
else
    assert_fail "[SPEC-1] two different stages must not share a scratch dir" "$_build1"
fi

# ── SPEC-1: distinct per map element ────────────────────────────────────────
# The `map:` arm gives all six lens members the SAME stage name concurrently
# (ADR-047 §2). Keyed on the stage alone, six parallel members would write into
# one directory and clobber each other — which is why the element is in the key.
_lens_sec="$(stage_scratch_dir "$JOB_DIR" "review_lenses" "security")"
_lens_perf="$(stage_scratch_dir "$JOB_DIR" "review_lenses" "performance")"
assert_eq "[SPEC-1] a map member's scratch is keyed <stage>-<element>" \
    "$JOB_DIR/scratch/review_lenses-security" "$_lens_sec"
if [[ "$_lens_sec" != "$_lens_perf" ]]; then
    assert_pass "[SPEC-1] two map elements of one stage resolve to different dirs"
else
    assert_fail "[SPEC-1] concurrent map members must not share a scratch dir" "$_lens_sec"
fi

# ── SPEC-1: the key is one path component, never a path ─────────────────────
# A stage id is template-authored and a map element comes from a data list.
# Neither may climb out of the job folder (CLAUDE.md: sanitize file paths).
_evil="$(stage_scratch_dir "$JOB_DIR" "../../etc" "")"
if [[ "$_evil" == "$JOB_DIR/scratch/"* && "$_evil" != *".."* ]]; then
    assert_pass "[SPEC-1] a traversal in the stage id cannot escape the job folder"
else
    assert_fail "[SPEC-1] a traversal in the stage id must not escape the job folder" "$_evil"
fi
_evil_el="$(stage_scratch_dir "$JOB_DIR" "review_lenses" "../../../tmp/pwn")"
if [[ "$_evil_el" == "$JOB_DIR/scratch/"* && "$_evil_el" != *".."* ]]; then
    assert_pass "[SPEC-1] a traversal in the map element cannot escape the job folder"
else
    assert_fail "[SPEC-1] a traversal in the map element must not escape the job folder" "$_evil_el"
fi

# ── SPEC-1: an unnameable stage is refused, not silently shared ─────────────
# A scratch dir with no owner is a shared temp dir with extra steps.
_norc=0
stage_scratch_dir "$JOB_DIR" "" "" >/dev/null 2>&1 || _norc=$?
assert_eq "[SPEC-1] a dispatch with no stage to name gets no scratch dir (rc=2)" "2" "$_norc"

# ── SPEC-1: ensure creates it 0700 ──────────────────────────────────────────
_made="$(stage_scratch_ensure "$JOB_DIR" "build" "" 2>/dev/null)"
assert_eq "[SPEC-1] stage_scratch_ensure returns the resolved path" "$_build1" "$_made"
if [[ -d "$_made" ]]; then
    assert_pass "[SPEC-1] stage_scratch_ensure creates the directory"
else
    assert_fail "[SPEC-1] stage_scratch_ensure creates the directory" "missing: $_made"
fi
_mode="$(/usr/bin/stat -f '%Lp' "$_made" 2>/dev/null || stat -c '%a' "$_made" 2>/dev/null)"
assert_eq "[SPEC-1] scratch is 0700 — it holds raw prompts and raw model output" "700" "$_mode"

# Creating twice must not disturb what is already there (the cycle-iteration
# property again, this time on the filesystem rather than the resolver).
: > "$_made/iteration-1.marker"
stage_scratch_ensure "$JOB_DIR" "build" "" >/dev/null 2>&1
assert_file_exists "[SPEC-1] re-ensuring an existing scratch dir preserves its contents" \
    "$_made/iteration-1.marker"

# ── SPEC-1: falls back to the ambient dispatch identity ─────────────────────
# plugin_hook_call's callers should not have to re-state what the engine already
# exported. With no arguments the resolver reads ZBUILD_STATE_DIR /
# ZBUILD_CURRENT_STAGE / ZBUILD_MAP_ELEMENT.
_ambient="$(ZBUILD_STATE_DIR="$JOB_DIR" ZBUILD_CURRENT_STAGE="review_lenses" \
            ZBUILD_MAP_ELEMENT="security" bash -c \
            'source "$1"; stage_scratch_dir' _ "$SCRATCH_LIB" 2>/dev/null)"
assert_eq "[SPEC-1] with no arguments the resolver uses the ambient dispatch identity" \
    "$_lens_sec" "$_ambient"

# ── SPEC-3[guard]: never under the system TMPDIR — behavioural ──────────────
_CANARY_TMP="$TEST_TEMP_DIR/canary-tmpdir"
mkdir -p "$_CANARY_TMP"

_under_tmp="$(TMPDIR="$_CANARY_TMP" bash -c \
    'source "$1"; stage_scratch_dir "$2" build ""' _ "$SCRATCH_LIB" "$JOB_DIR" 2>/dev/null)"
if [[ -n "$_under_tmp" && "$_under_tmp" != "$_CANARY_TMP"* ]]; then
    assert_pass "[SPEC-3] a resolution with TMPDIR set does not land under TMPDIR"
else
    assert_fail "[SPEC-3] the scratch dir must never be under the system TMPDIR" \
        "resolved=[$_under_tmp] TMPDIR=[$_CANARY_TMP]"
fi

# The same guard on the LAST-RESORT arm, which is where a TMPDIR default would
# most plausibly be written: no state dir named, no override set.
_bare="$(TMPDIR="$_CANARY_TMP" ZBUILD_STATE_ROOT="$TEST_TEMP_DIR/root" ZBUILD_RUN_ID="r1" \
    bash -c 'unset ZBUILD_STATE_DIR ZBUILD_SCRATCH_ROOT; source "$1"; stage_scratch_dir "" build ""' \
    _ "$SCRATCH_LIB" 2>/dev/null)"
if [[ -n "$_bare" && "$_bare" != "$_CANARY_TMP"* ]]; then
    assert_pass "[SPEC-3] the no-state-dir fallback does not land under TMPDIR either"
else
    assert_fail "[SPEC-3] the fallback arm must not default to TMPDIR" \
        "resolved=[$_bare] TMPDIR=[$_CANARY_TMP]"
fi
assert_eq "[SPEC-3] the fallback arm is per-run, so two runs never share scratch" \
    "$TEST_TEMP_DIR/root/runs/r1/scratch/build" "$_bare"

# ── SPEC-3[guard]: the resolver never READS TMPDIR — static ────────────────
# See the header: this is the half that catches nesting at the dispatch seam,
# where TMPDIR has already been pointed AT the scratch dir. Comments are
# stripped first — the file discusses TMPDIR at length and must be free to.
_CODE_ONLY="$TEST_TEMP_DIR/stage-scratch.code"
sed 's/#.*$//' "$SCRATCH_LIB" > "$_CODE_ONLY"
_tmpdir_reads="$(/usr/bin/grep -n 'TMPDIR' "$_CODE_ONLY" || true)"
if [[ -z "$_tmpdir_reads" ]]; then
    assert_pass "[SPEC-3] the resolver's code reads TMPDIR nowhere"
else
    assert_fail "[SPEC-3] the resolver must not read TMPDIR — the dispatch seam points it AT the scratch dir" \
        "$_tmpdir_reads"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
