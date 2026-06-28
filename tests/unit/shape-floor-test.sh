#!/usr/bin/env bash
# Tests: scripts/lib/shape-floor.sh (ADR-040, issue #1134, EPIC #1129)
# The un-gameable shape-floor check, extracted from objective-ablation.sh (#971).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "scripts/lib/shape-floor.sh — un-gameable shape floor (#1134)"
setup_test_env "shape-floor"

_test_cleanup_hook() { cleanup_test_env; }

_SHAPE_FLOOR_SH="$REPO_ROOT/scripts/lib/shape-floor.sh"

# ─── SPEC-1: sources cleanly ──────────────────────────────────────────────────

set +e
# shellcheck source=../../scripts/lib/shape-floor.sh
source "$_SHAPE_FLOOR_SH"
_spec1_rc=$?
set -e

assert_eq "[SPEC-1] shape-floor.sh sources without error" "0" "$_spec1_rc"

# ─── Shape floor tests — minimal temp repo ───────────────────────────────────
# Minimal repo with a controlled shape-change-paths.txt + golden file.
# ZBUILD_DIFF_CMD mocks the git diff output so no real git ops are needed.

_sr="$TEST_TEMP_DIR/shape-repo"
mkdir -p "$_sr/config" "$_sr/tests/golden/mytest"
printf 'config/templates/*.yaml\n' > "$_sr/config/shape-change-paths.txt"
printf 'golden-event-content\n' > "$_sr/tests/golden/mytest/event-sequence.golden"

# ─── SPEC-2: shape floor SKIP — no shape-change file in diff ──────────────────
# Diff has no file matching shape-change-paths.txt → SHAPE_FLOOR SKIP.

set +e
_spec2_out="$(ZBUILD_DIFF_CMD="printf 'scripts/lib/helpers.sh\n'" \
    _sf_shape_floor "$_sr")"
set -e

assert_contains "[SPEC-2] non-shape file in diff → SHAPE_FLOOR SKIP" \
    "$_spec2_out" "SHAPE_FLOOR SKIP no_shape_change"

# ─── SPEC-3: shape floor FAIL — shape-change file in diff, golden absent ──────
# Shape-change file detected but event-sequence.golden NOT in diff → FAIL.

set +e
_spec3_out="$(ZBUILD_DIFF_CMD="printf 'config/templates/simple.yaml\n'" \
    _sf_shape_floor "$_sr")"
set -e

assert_contains "[SPEC-3] shape change without golden in diff → SHAPE_FLOOR FAIL" \
    "$_spec3_out" "SHAPE_FLOOR FAIL missing_floor_files"

# ─── SPEC-4: shape floor PASS — shape-change file + golden both in diff ───────
# Both shape-change file and golden file in diff (no _TPL_STAGES[N] files in this
# minimal repo) → PASS.

set +e
_spec4_out="$(ZBUILD_DIFF_CMD="printf 'config/templates/simple.yaml\ntests/golden/mytest/event-sequence.golden\n'" \
    _sf_shape_floor "$_sr")"
set -e

assert_contains "[SPEC-4] shape change + golden in diff → SHAPE_FLOOR PASS" \
    "$_spec4_out" "SHAPE_FLOOR PASS"

# ─── Results ─────────────────────────────────────────────────────────────────

print_test_results
