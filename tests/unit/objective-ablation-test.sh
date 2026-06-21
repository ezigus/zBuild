#!/usr/bin/env bash
# Tests: scripts/lib/objective-ablation.sh (issue #971, EPIC #966 I5)
# Three de-ceremonied ablation gates: negctl, reachability, shape floor.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "scripts/lib/objective-ablation.sh — negctl + reachability + shape floor (#971)"
setup_test_env "objective-ablation"

_test_cleanup_hook() { cleanup_test_env; }

_ABLATION_SH="$REPO_ROOT/scripts/lib/objective-ablation.sh"

# ─── SPEC-1: sources cleanly ──────────────────────────────────────────────────
# CHANGE: file absent at merge-base → source fails. Now it must source cleanly.

set +e
# shellcheck source=../../scripts/lib/objective-ablation.sh
source "$_ABLATION_SH"
_spec1_rc=$?
set -e

assert_eq "[SPEC-1] objective-ablation.sh sources without error" "0" "$_spec1_rc"

# ─── Shared git-repo setup helper ────────────────────────────────────────────
# Creates a minimal git repo at $1 with main + feature branches, first commit on main.
_make_git_repo() {
    local repo="$1"
    mkdir -p "$repo"
    git init "$repo" >/dev/null 2>&1
    git -C "$repo" config user.email "test@test.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" config commit.gpgsign false 2>/dev/null || true
    printf 'base\n' > "$repo/base.txt"
    git -C "$repo" add base.txt
    git -C "$repo" commit -m "init" >/dev/null 2>&1
    git -C "$repo" branch -M main >/dev/null 2>&1 || true
    git -C "$repo" checkout -b feature >/dev/null 2>&1
}

# ─── SPEC-2: negctl FAIL — tautological test ─────────────────────────────────
# CHANGE: function absent at baseline. Now: changed test that passes even at
# merge-base (tautological) → ABLATION_NEGCTL FAIL tautology.

_t2="$TEST_TEMP_DIR/repo-spec2"
_make_git_repo "$_t2"
mkdir -p "$_t2/scripts" "$_t2/tests/unit"
# Impl file (changed on feature branch)
printf '#!/usr/bin/env bash\necho "new"\n' > "$_t2/scripts/impl.sh"
# Test file that always passes regardless of impl (tautological)
printf '#!/usr/bin/env bash\nexit 0\n' > "$_t2/tests/unit/feature-test.sh"
git -C "$_t2" add scripts/impl.sh tests/unit/feature-test.sh
git -C "$_t2" commit -m "feature" >/dev/null 2>&1

set +e
_spec2_out="$(_og_ablation_negctl "$_t2")"
set -e

assert_contains "[SPEC-2] tautological test → ABLATION_NEGCTL FAIL tautology" \
    "$_spec2_out" "ABLATION_NEGCTL FAIL tautology"

# ─── SPEC-3: negctl PASS — load-bearing test ─────────────────────────────────
# CHANGE: function absent at baseline. Now: test fails at merge-base (impl
# reverted to "old"), passes at HEAD ("new") → ABLATION_NEGCTL PASS.

_t3="$TEST_TEMP_DIR/repo-spec3"
_make_git_repo "$_t3"
mkdir -p "$_t3/scripts" "$_t3/tests/unit"
printf '#!/usr/bin/env bash\necho "new"\n' > "$_t3/scripts/impl.sh"
# Test checks that impl outputs "new" — load-bearing
printf '#!/usr/bin/env bash\nout="$(bash scripts/impl.sh 2>/dev/null || true)"\n[[ "$out" == "new" ]]\n' \
    > "$_t3/tests/unit/feature-test.sh"
git -C "$_t3" add scripts/impl.sh tests/unit/feature-test.sh
git -C "$_t3" commit -m "feature" >/dev/null 2>&1

set +e
_spec3_out="$(_og_ablation_negctl "$_t3")"
set -e

assert_contains "[SPEC-3] load-bearing test → ABLATION_NEGCTL PASS" \
    "$_spec3_out" "ABLATION_NEGCTL PASS"

# ─── SPEC-4: negctl SKIP — no test files changed ─────────────────────────────
# CHANGE: function absent at baseline. Now: only impl file in diff (no *-test.sh)
# → ABLATION_NEGCTL SKIP no_test_files_changed.

_t4="$TEST_TEMP_DIR/repo-spec4"
_make_git_repo "$_t4"
mkdir -p "$_t4/scripts"
printf '#!/usr/bin/env bash\necho "new"\n' > "$_t4/scripts/impl.sh"
git -C "$_t4" add scripts/impl.sh
git -C "$_t4" commit -m "feature" >/dev/null 2>&1

set +e
_spec4_out="$(_og_ablation_negctl "$_t4")"
set -e

assert_contains "[SPEC-4] no test files in diff → ABLATION_NEGCTL SKIP" \
    "$_spec4_out" "ABLATION_NEGCTL SKIP"

# ─── SPEC-5: reachability FAIL — inert wiring ────────────────────────────────
# CHANGE: function absent at baseline. Now: test does not use the changed impl
# file → reverting impl causes no flip → ABLATION_REACH FAIL inert.

_t5="$TEST_TEMP_DIR/repo-spec5"
_make_git_repo "$_t5"
mkdir -p "$_t5/scripts" "$_t5/tests/unit"
printf '#!/usr/bin/env bash\necho "new"\n' > "$_t5/scripts/impl.sh"
# Test ignores impl entirely (inert)
printf '#!/usr/bin/env bash\nexit 0\n' > "$_t5/tests/unit/feature-test.sh"
git -C "$_t5" add scripts/impl.sh tests/unit/feature-test.sh
git -C "$_t5" commit -m "feature" >/dev/null 2>&1

set +e
_spec5_out="$(_og_ablation_reachability "$_t5")"
set -e

assert_contains "[SPEC-5] inert impl → ABLATION_REACH FAIL inert" \
    "$_spec5_out" "ABLATION_REACH FAIL inert"

# ─── SPEC-6: reachability PASS — load-bearing wiring ─────────────────────────
# CHANGE: function absent at baseline. Now: test exercises impl; reverting impl
# causes test to fail → flip detected → ABLATION_REACH PASS.

_t6="$TEST_TEMP_DIR/repo-spec6"
_make_git_repo "$_t6"
mkdir -p "$_t6/scripts" "$_t6/tests/unit"
printf '#!/usr/bin/env bash\necho "new"\n' > "$_t6/scripts/impl.sh"
# Test exercises impl — load-bearing wiring
printf '#!/usr/bin/env bash\nout="$(bash scripts/impl.sh 2>/dev/null || true)"\n[[ "$out" == "new" ]]\n' \
    > "$_t6/tests/unit/feature-test.sh"
git -C "$_t6" add scripts/impl.sh tests/unit/feature-test.sh
git -C "$_t6" commit -m "feature" >/dev/null 2>&1

set +e
_spec6_out="$(_og_ablation_reachability "$_t6")"
set -e

assert_contains "[SPEC-6] load-bearing impl → ABLATION_REACH PASS" \
    "$_spec6_out" "ABLATION_REACH PASS"

# ─── Shape floor tests — minimal temp repo ───────────────────────────────────
# Use a minimal repo with controlled shape-change-paths.txt and golden files.
# ZBUILD_DIFF_CMD mocks the git diff output so no real git ops are needed.

_sr="$TEST_TEMP_DIR/shape-repo"
mkdir -p "$_sr/config" "$_sr/tests/golden/mytest"
printf 'config/templates/*.yaml\n' > "$_sr/config/shape-change-paths.txt"
printf 'golden-event-content\n' > "$_sr/tests/golden/mytest/event-sequence.golden"

# ─── SPEC-7: shape floor SKIP — no shape-change file in diff ─────────────────
# CHANGE: function absent at baseline. Now: diff has no file matching
# shape-change-paths.txt → ABLATION_SHAPE SKIP no_shape_change.

set +e
_spec7_out="$(ZBUILD_DIFF_CMD="printf 'scripts/lib/helpers.sh\n'" \
    _og_ablation_shape_floor "$_sr")"
set -e

assert_contains "[SPEC-7] non-shape file in diff → ABLATION_SHAPE SKIP" \
    "$_spec7_out" "ABLATION_SHAPE SKIP no_shape_change"

# ─── SPEC-8: shape floor FAIL — shape-change file in diff, golden absent ─────
# CHANGE: function absent at baseline. Now: shape-change file detected but
# event-sequence.golden NOT in diff → ABLATION_SHAPE FAIL missing_floor_files.

set +e
_spec8_out="$(ZBUILD_DIFF_CMD="printf 'config/templates/simple.yaml\n'" \
    _og_ablation_shape_floor "$_sr")"
set -e

assert_contains "[SPEC-8] shape change without golden in diff → ABLATION_SHAPE FAIL" \
    "$_spec8_out" "ABLATION_SHAPE FAIL missing_floor_files"

# ─── SPEC-9: shape floor PASS — shape-change file + golden both in diff ──────
# CHANGE: function absent at baseline. Now: both shape-change file and golden
# file are in diff (no _TPL_STAGES[N] files in this minimal repo) → PASS.

set +e
_spec9_out="$(ZBUILD_DIFF_CMD="printf 'config/templates/simple.yaml\ntests/golden/mytest/event-sequence.golden\n'" \
    _og_ablation_shape_floor "$_sr")"
set -e

assert_contains "[SPEC-9] shape change + golden in diff → ABLATION_SHAPE PASS" \
    "$_spec9_out" "ABLATION_SHAPE PASS"

# ─── SPEC-10: reachability SKIP — only test files changed, no impl files ─────
# CHANGE: function absent at baseline. Now: diff contains only a test file
# (no non-test impl file) → ABLATION_REACH SKIP no_impl_files_changed.

_t10="$TEST_TEMP_DIR/repo-spec10"
_make_git_repo "$_t10"
mkdir -p "$_t10/tests/unit"
# Feature branch adds ONLY a test file — no impl file changed
printf '#!/usr/bin/env bash\nexit 0\n' > "$_t10/tests/unit/feature-test.sh"
git -C "$_t10" add tests/unit/feature-test.sh
git -C "$_t10" commit -m "test only" >/dev/null 2>&1

set +e
_spec10_out="$(_og_ablation_reachability "$_t10")"
set -e

assert_contains "[SPEC-10] only test files in diff → ABLATION_REACH SKIP no_impl_files_changed" \
    "$_spec10_out" "ABLATION_REACH SKIP no_impl_files_changed"

# ─── Results ─────────────────────────────────────────────────────────────────

print_test_results
