#!/usr/bin/env bash
# Unit tests for the RUN-scoped temp root (ADR-058 C10).
#
# ADR-058 §3 redirects TMPDIR per DISPATCH (core/plugin-registry/lifecycle.sh,
# `local -x TMPDIR="$_ws_scratch"`). That is fail-open and dispatch-scoped, so
# engine code running between dispatches — and any child spawned outside
# plugin_hook_call — falls back to ${TMPDIR:-/tmp}, which is literally /tmp on
# every Linux CI runner. C9 records the measured consequence by name:
#   stage=intake path=/tmp/zb-route-redact-out.*
#   stage=build  path=/tmp/zbuild-tpl.*
#   stage=test   path=/tmp/zb-numstat.*
# C9's own cure is a RUN-scoped TMPDIR. This file pins the root it resolves to.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/pipeline/stage-scratch.sh
source "$REPO_ROOT/core/pipeline/stage-scratch.sh"

print_test_header "run-scoped temp root — ADR-058 C10"
setup_test_env "run-tmpdir"

JOB_DIR="$TEST_TEMP_DIR/state/runs/20260907-run-tmp"
mkdir -p "$JOB_DIR"

# ─── SPEC-1: resolves under the job folder, and is created ──────────────────
_rt="$(ZBUILD_STATE_DIR="$JOB_DIR" zbuild_run_tmpdir 2>/dev/null || true)"
assert_eq "[SPEC-1] the run temp root sits under the job folder's scratch" \
    "$JOB_DIR/scratch/run-tmp" "$_rt"
assert_eq "[SPEC-1] the run temp root exists (callers mktemp into it)" \
    "1" "$([[ -d "$_rt" ]] && echo 1 || echo 0)"

# One dir per RUN, not one per call — it is the ambient temp for everything the
# run spawns, so a fresh dir per call would defeat reclamation and grow the
# job folder without bound (the cost ADR-058 already accepted once for scratch).
_rt2="$(ZBUILD_STATE_DIR="$JOB_DIR" zbuild_run_tmpdir 2>/dev/null || true)"
assert_eq "[SPEC-1] the run temp root is stable across calls" "$_rt" "$_rt2"

# ─── SPEC-2: it is never the system temp ────────────────────────────────────
# The whole point is to stop resolving to /tmp. Assert behaviourally AND
# statically, mirroring stage-scratch-test.sh SPEC-3: a resolver that READ
# $TMPDIR would nest the run temp inside whatever the last dispatch left.
case "$_rt" in
    /tmp/*|/var/tmp/*) assert_fail "[SPEC-2] the run temp root is not the system temp" "got $_rt" ;;
    *)                 assert_pass "[SPEC-2] the run temp root is not the system temp" ;;
esac

_reads_tmpdir=$(sed -n '/^zbuild_run_tmpdir()/,/^}/p' "$REPO_ROOT/scripts/lib/helpers.sh" \
    | grep -c 'TMPDIR' || true)
assert_eq "[SPEC-2] zbuild_run_tmpdir reads TMPDIR nowhere" "0" "$_reads_tmpdir"

# ─── SPEC-3: no state dir means no answer, not a wrong one ──────────────────
# Fail-open is the ADR's own posture: a run must never die because a temp dir
# was unavailable. An empty answer lets the caller keep what it has.
_rt_none="$(unset ZBUILD_STATE_DIR; zbuild_run_tmpdir 2>/dev/null || true)"
assert_eq "[SPEC-3] with no state dir the run temp root resolves to nothing" "" "$_rt_none"

# ─── SPEC-4: a stage cannot mint the reserved key ───────────────────────────
# stage_scratch keys on <stage>[-<element>] and sanitises to [A-Za-z0-9_-], so a
# stage literally named run-tmp would land on the run temp root and have its
# throwaway files reclaimed by a different owner.
_collide=0
_k="$(_stage_scratch_key "run-tmp" 2>/dev/null || true)"
[[ "$_k" == "run-tmp" ]] && _collide=1
assert_eq "[SPEC-4] a stage named run-tmp cannot take the reserved key" "0" "$_collide"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
