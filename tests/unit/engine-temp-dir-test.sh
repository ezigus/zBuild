#!/usr/bin/env bash
# Tests: zbuild_engine_tmp — one definition of "where engine code writes a
# temporary file" (#2010).
#
# Engine code used to say `${TMPDIR:-/tmp}` and land in the stage scratch dir,
# but only because ADR-058 §3 sets `local -x TMPDIR="$_ws_scratch"` at the
# dispatch chokepoint. That made every such line correct INSIDE a dispatch and
# a leak OUTSIDE one, with nothing in the line to tell them apart.
#
# TMPDIR keeps its one real job — it is the only channel that reaches a spawned
# model, because env-scrub strips every ZBUILD_* (#1873). Engine code has no
# such constraint: it can name the scratch dir directly.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "zbuild_engine_tmp — one definition, no \${TMPDIR} leak (#2010)"
setup_test_env "engine-temp-dir"

# shellcheck source=../../core/pipeline/stage-scratch.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"

FAKE_TMP="$TEST_TEMP_DIR/fake-tmp"; mkdir -p "$FAKE_TMP"
DATA_ROOT="$TEST_TEMP_DIR/data-root"; mkdir -p "$DATA_ROOT"
SCRATCH="$TEST_TEMP_DIR/scratch";     mkdir -p "$SCRATCH"

# ─── SPEC-1: inside a dispatch → the stage scratch dir ──────────────────────
_s1="$(ZBUILD_STAGE_SCRATCH="$SCRATCH" TMPDIR="$FAKE_TMP" ZBUILD_DATA_ROOT="$DATA_ROOT" \
        bash -c 'source "'"$REPO_ROOT"'/scripts/lib/helpers.sh"; zbuild_engine_tmp')"
assert_eq "[SPEC-1] with a stage scratch, that is the answer" "$SCRATCH" "$_s1"

# ─── SPEC-2: OUTSIDE a dispatch → the data root, NOT the system temp dir ───
# This is the case the redirect never covered and the whole reason for #2010.
_s2="$(env -u ZBUILD_STAGE_SCRATCH -u ZBUILD_STATE_ROOT \
        TMPDIR="$FAKE_TMP" ZBUILD_DATA_ROOT="$DATA_ROOT" \
        bash -c 'source "'"$REPO_ROOT"'/scripts/lib/helpers.sh"; zbuild_engine_tmp')"
case "$_s2" in
    "$DATA_ROOT"/*) assert_pass "[SPEC-2] outside a dispatch it resolves under the data root" ;;
    "$FAKE_TMP"/*)  assert_fail "[SPEC-2] outside a dispatch it resolves under the data root" \
                        "fell through to \$TMPDIR — the leak #2010 exists to remove: $_s2" ;;
    *)              assert_fail "[SPEC-2] outside a dispatch it resolves under the data root" "got: $_s2" ;;
esac

# ─── SPEC-3: the directory it names is usable ──────────────────────────────
# A path that does not exist is a fail-open that fails closed at first write.
_s3d="$(env -u ZBUILD_STAGE_SCRATCH -u ZBUILD_STATE_ROOT \
        TMPDIR="$FAKE_TMP" ZBUILD_DATA_ROOT="$DATA_ROOT" \
        bash -c 'source "'"$REPO_ROOT"'/scripts/lib/helpers.sh"; d="$(zbuild_engine_tmp)"; mkdir -p "$d" && mktemp "$d/probe.XXXXXX"')"
if [[ -f "$_s3d" ]]; then
    assert_pass "[SPEC-3] a temp file can actually be created there"
else
    assert_fail "[SPEC-3] a temp file can actually be created there" "got: $_s3d"
fi

# ─── SPEC-4: never returns the bare system temp dir ───────────────────────
# Belt and braces: with nothing set at all it must still not hand back $TMPDIR.
_s4="$(env -u ZBUILD_STAGE_SCRATCH -u ZBUILD_DATA_ROOT -u ZBUILD_STATE_ROOT \
        TMPDIR="$FAKE_TMP" HOME="$TEST_TEMP_DIR/home" \
        bash -c 'source "'"$REPO_ROOT"'/scripts/lib/helpers.sh"; zbuild_engine_tmp')"
case "$_s4" in
    "$FAKE_TMP"|"$FAKE_TMP"/*) assert_fail "[SPEC-4] never returns the bare \$TMPDIR" "got: $_s4" ;;
    *)                         assert_pass "[SPEC-4] never returns the bare \$TMPDIR (got ${_s4})" ;;
esac

cleanup_test_env
print_test_results
exit $((FAIL > 0))
