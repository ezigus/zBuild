#!/usr/bin/env bash
# Guard: engine defaults land under the data root, never ${TMPDIR} (#2004).
#
# ADR-059 §1 makes the path the keying — a reclaimer deletes a `runs/<id>/` or
# an `issues/<N>/` and the scope follows from where it sits. A default that
# writes into ${TMPDIR} is outside every reclaimable path BY CONSTRUCTION: there
# is nothing for a reclaimer to name. ADR-023 and ADR-059 §1 also reject
# ${TMPDIR} for durable state on measured evidence — on macOS its entries can
# vanish mid-run (#1571, #1609/#1611).
#
# Measured before this change: 3063 zbuild-* directories (180 MB) had
# accumulated on one developer machine, ~2300 of them zbuild-ephemeral-events.*.
# `cleanup.sh`'s ZBUILD_TMPDIR_PATTERNS scanner exists to sweep them, which
# makes it a workaround for these defaults rather than a feature.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "ADR-059: engine defaults are reclaimable, not \${TMPDIR}-rooted (#2004)"
setup_test_env "adr059-no-tmpdir"

FAKE_TMP="$TEST_TEMP_DIR/fake-tmp"; mkdir -p "$FAKE_TMP"
DATA_ROOT="$TEST_TEMP_DIR/data-root"; mkdir -p "$DATA_ROOT"

# ─── SPEC-1: the unpinned event-bus dir is under the data root ──────────────
# Nothing pinned is the ad-hoc/test path; it produced ~2300 leaked dirs.
_s1="$(env -u ZBUILD_EVENTS_DIR -u ZBUILD_EVENTS_JSONL -u ZBUILD_EVENTS_DB \
        TMPDIR="$FAKE_TMP" ZBUILD_DATA_ROOT="$DATA_ROOT" \
        bash -c 'source "'"$REPO_ROOT"'/core/event-bus/event-bus.sh" >/dev/null 2>&1; printf "%s" "$ZBUILD_EVENTS_DIR"')"
case "$_s1" in
    "$DATA_ROOT"/*) assert_pass "[SPEC-1] unpinned event dir is under the data root" ;;
    "$FAKE_TMP"/*)  assert_fail "[SPEC-1] unpinned event dir is under the data root" \
                        "landed in \$TMPDIR — unreclaimable by construction: $_s1" ;;
    *)              assert_fail "[SPEC-1] unpinned event dir is under the data root" "got: $_s1" ;;
esac

# ─── SPEC-2: an explicit pin still wins ────────────────────────────────────
# The fix must not override an operator's or the runner's explicit choice.
_s2="$(env -u ZBUILD_EVENTS_JSONL -u ZBUILD_EVENTS_DB \
        TMPDIR="$FAKE_TMP" ZBUILD_DATA_ROOT="$DATA_ROOT" ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/pinned" \
        bash -c 'source "'"$REPO_ROOT"'/core/event-bus/event-bus.sh" >/dev/null 2>&1; printf "%s" "$ZBUILD_EVENTS_DIR"')"
assert_eq "[SPEC-2] an explicit ZBUILD_EVENTS_DIR pin still wins" "$TEST_TEMP_DIR/pinned" "$_s2"

# ─── SPEC-3: pool dirs sit under the run's state dir ───────────────────────
# ADR-059 §1 places them at runs/<run_id>/pool/. ZBUILD_STATE_DIR already
# resolves to runs/<run_id>/ under the issue (or goal) area.
STATE_DIR="$TEST_TEMP_DIR/issues/42/runs/r1"; mkdir -p "$STATE_DIR"
_s3="$(env -u ZBUILD_POOL_ROOT TMPDIR="$FAKE_TMP" ZBUILD_STATE_DIR="$STATE_DIR" ZBUILD_RUN_ID="r1" \
        bash -c 'source "'"$REPO_ROOT"'/plugins/tool/orch-bash-parallel/plugin.sh" >/dev/null 2>&1; _orch_par_pool_dir p1')"
case "$_s3" in
    "$STATE_DIR"/pool/*) assert_pass "[SPEC-3] bash-parallel pool dir is under runs/<run_id>/pool" ;;
    "$FAKE_TMP"/*)       assert_fail "[SPEC-3] bash-parallel pool dir is under runs/<run_id>/pool" \
                             "landed in \$TMPDIR: $_s3" ;;
    *)                   assert_fail "[SPEC-3] bash-parallel pool dir is under runs/<run_id>/pool" "got: $_s3" ;;
esac

# ─── SPEC-4: the sequential backend agrees ─────────────────────────────────
# Both backends are covered, or a flow using the other one still leaks.
_s4="$(env -u ZBUILD_POOL_ROOT TMPDIR="$FAKE_TMP" ZBUILD_STATE_DIR="$STATE_DIR" ZBUILD_RUN_ID="r1" \
        bash -c 'source "'"$REPO_ROOT"'/plugins/tool/orch-sequential/plugin.sh" >/dev/null 2>&1; _orch_seq_pool_dir p1')"
case "$_s4" in
    "$STATE_DIR"/pool/*) assert_pass "[SPEC-4] sequential pool dir is under runs/<run_id>/pool" ;;
    *)                   assert_fail "[SPEC-4] sequential pool dir is under runs/<run_id>/pool" "got: $_s4" ;;
esac

# ─── SPEC-5: an explicit ZBUILD_POOL_ROOT still wins ───────────────────────
_s5="$(TMPDIR="$FAKE_TMP" ZBUILD_STATE_DIR="$STATE_DIR" ZBUILD_POOL_ROOT="$TEST_TEMP_DIR/pinned-pool" \
        bash -c 'source "'"$REPO_ROOT"'/plugins/tool/orch-bash-parallel/plugin.sh" >/dev/null 2>&1; _orch_par_pool_dir p1')"
assert_eq "[SPEC-5] an explicit ZBUILD_POOL_ROOT pin still wins" \
    "$TEST_TEMP_DIR/pinned-pool/zbuild-pool-p1" "$_s5"

# ─── SPEC-6 (#2004 audit): the ruflo-hive backend agrees with the other two ─
# It was missed when the bash-parallel and sequential backends were fixed, and
# it is worse than they were: no per-run namespace at all, and `zbuild-hive-*`
# is absent from ZBUILD_TMPDIR_PATTERNS, so nothing swept it either.
_s6="$(env -u ZBUILD_POOL_ROOT TMPDIR="$FAKE_TMP" ZBUILD_STATE_DIR="$STATE_DIR" ZBUILD_RUN_ID="r1" \
        bash -c 'source "'"$REPO_ROOT"'/plugins/tool/orch-ruflo-hive/plugin.sh" >/dev/null 2>&1; _orch_hive_pool_dir p1')"
case "$_s6" in
    "$STATE_DIR"/pool/*) assert_pass "[SPEC-6] ruflo-hive pool dir is under runs/<run_id>/pool" ;;
    "$FAKE_TMP"/*)       assert_fail "[SPEC-6] ruflo-hive pool dir is under runs/<run_id>/pool" \
                             "landed in \$TMPDIR: $_s6" ;;
    *)                   assert_fail "[SPEC-6] ruflo-hive pool dir is under runs/<run_id>/pool" "got: $_s6" ;;
esac

# ─── SPEC-7: an explicit ZBUILD_POOL_ROOT still wins for hive too ──────────
_s7="$(TMPDIR="$FAKE_TMP" ZBUILD_STATE_DIR="$STATE_DIR" ZBUILD_POOL_ROOT="$TEST_TEMP_DIR/pinned-hive" \
        bash -c 'source "'"$REPO_ROOT"'/plugins/tool/orch-ruflo-hive/plugin.sh" >/dev/null 2>&1; _orch_hive_pool_dir p1')"
assert_eq "[SPEC-7] hive honours an explicit ZBUILD_POOL_ROOT" \
    "$TEST_TEMP_DIR/pinned-hive/zbuild-hive-p1" "$_s7"

# ─── SPEC-8: with NO state dir at all, the fallback is still reclaimable ────
# The ad-hoc/test caller. This arm used to root in ${TMPDIR}, which quietly
# reintroduced the leak the rest of this file exists to prevent — the event bus
# and the pool backends had answered the same question two different ways.
for _b in orch-bash-parallel orch-sequential orch-ruflo-hive; do
    _fn="_orch_par_pool_dir"
    [[ "$_b" == "orch-sequential" ]] && _fn="_orch_seq_pool_dir"
    [[ "$_b" == "orch-ruflo-hive" ]] && _fn="_orch_hive_pool_dir"
    _s8="$(env -u ZBUILD_POOL_ROOT -u ZBUILD_STATE_DIR -u ZBUILD_STATE_ROOT \
            TMPDIR="$FAKE_TMP" ZBUILD_DATA_ROOT="$DATA_ROOT" ZBUILD_RUN_ID="r1" \
            bash -c 'source "'"$REPO_ROOT"'/plugins/tool/'"$_b"'/plugin.sh" >/dev/null 2>&1; '"$_fn"' p1')"
    case "$_s8" in
        "$DATA_ROOT"/*) assert_pass "[SPEC-8] $_b falls back to the data root, not \$TMPDIR" ;;
        "$FAKE_TMP"/*)  assert_fail "[SPEC-8] $_b falls back to the data root, not \$TMPDIR" \
                            "landed in \$TMPDIR: $_s8" ;;
        *)              assert_fail "[SPEC-8] $_b falls back to the data root, not \$TMPDIR" "got: $_s8" ;;
    esac
done

cleanup_test_env
print_test_results
exit $((FAIL > 0))
