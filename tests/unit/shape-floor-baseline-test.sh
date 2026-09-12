#!/usr/bin/env bash
# tests/unit/shape-floor-baseline-test.sh
# shape-floor tells "I could not check" apart from "I checked and found nothing" (#2064).
#
# `_sf_shape_floor` resolves its baseline through zbuild_resolve_merge_base.
# When that returns EMPTY — the honest answer #1655 made it give — _sf_diff_files
# prints nothing, no floor path can match, and the gate reported
# `SHAPE_FLOOR SKIP no_shape_change`: a claim about a diff it had never seen,
# indistinguishable downstream from a branch that genuinely touches no shape.
#
# This file is deliberately its own, not assertions bolted onto
# shape-floor-test.sh. Two reasons, both the ones route-missing-include-test.sh
# records for the same decision:
#   1. Every one of that file's 16 SPECs drives the gate through ZBUILD_DIFF_CMD,
#      which hands it a diff and so never reaches baseline resolution at all.
#      These SPECs are the opposite: REAL git repos, no override, because the
#      defect lives entirely in the path the override skips. Different mechanism,
#      different fixtures, different failure mode.
#   2. That file is already near CLAUDE.md's 500-line limit, and a baseline
#      failure here should not arrive buried in a run of unrelated diff-exemption
#      assertions.
#
# SPEC coverage:
#   [SPEC-17] unresolvable baseline      → SKIP no_baseline, and NOT no_shape_change
#   [SPEC-18] resolved baseline, non-shape diff → SKIP no_shape_change, NOT no_baseline
#   [SPEC-19] resolved baseline, EMPTY diff     → SKIP no_shape_change, NOT no_baseline
#   [SPEC-20] the honest reason reaches shape-floor-result.json, verdict still `skip`
#
# SPEC-19 is the load-bearing one. It and SPEC-17 hand every line below
# _sf_diff_files the IDENTICAL input — zero changed files — so only the baseline
# tells them apart. An implementation keyed off "the diff came back empty"
# rather than off the resolver passes SPEC-17 and SPEC-18 and fails only here.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "shape-floor: an unresolvable baseline is not a clean diff (#2064)"
setup_test_env "shape-floor-baseline"

_test_cleanup_hook() { cleanup_test_env; }

# shape-floor.sh brings merge-base.sh (zbuild_resolve_merge_base,
# zbuild_resolve_default_branch) with it — the preconditions below assert on the
# same resolver the gate uses, not a reimplementation of it.
# shellcheck source=../../scripts/lib/shape-floor.sh
source "$REPO_ROOT/scripts/lib/shape-floor.sh"
# shellcheck source=../../plugins/tool/shape-floor/plugin.sh
source "$REPO_ROOT/plugins/tool/shape-floor/plugin.sh"


_sf_git_id() {
    git -C "$1" config user.email "test@zbuild.local"
    git -C "$1" config user.name  "Test"
    git -C "$1" config commit.gpgsign false
}

# _sf_mk_floor_repo <dir> <initial-branch> — a minimal shape-floor repo carrying
# one commit: shape-change-paths.txt, a golden, and a template. No remote, so the
# caller decides whether a trunk (and therefore a baseline) resolves at all.
_sf_mk_floor_repo() {
    local dir="$1" branch="$2"
    mkdir -p "$dir/config/templates" "$dir/tests/golden/mytest" "$dir/scripts/lib"
    git -C "$dir" init -q -b "$branch"
    _sf_git_id "$dir"
    printf 'config/templates/*.yaml\n' > "$dir/config/shape-change-paths.txt"
    printf 'golden-event-content\n' > "$dir/tests/golden/mytest/event-sequence.golden"
    printf 'stages:\n  - build\n' > "$dir/config/templates/simple.yaml"
    printf 'helper\n' > "$dir/scripts/lib/helpers.sh"
    git -C "$dir" add -A
    git -C "$dir" commit -q -m "baseline"
}

# ─── SPEC-17 (#2064): unresolvable baseline → SKIP no_baseline ───────────────
# Trunk cannot be resolved (no origin, no main/master), so the resolver returns
# EMPTY — the one input that reaches this branch. The shape-change commit is
# real: were a baseline available, this diff WOULD be a shape change, so a
# `no_shape_change` answer here is not merely unhelpful, it is false.

_sr_nb="$TEST_TEMP_DIR/no-baseline-repo"
_sf_mk_floor_repo "$_sr_nb" "feat/work"
printf 'stages:\n  - build\n  - test\n' > "$_sr_nb/config/templates/simple.yaml"
git -C "$_sr_nb" add -A
git -C "$_sr_nb" commit -q -m "add a stage — a real shape change"

# Preconditions. Without these the SPEC is vacuous: it would pass on a fixture
# that simply had nothing to resolve for uninteresting reasons.
if [[ -z "$(zbuild_resolve_default_branch "$_sr_nb")" ]]; then
    assert_pass "[SPEC-17] precondition: no trunk resolves in the fixture"
else
    assert_fail "[SPEC-17] precondition: trunk must be unresolvable" \
        "got '$(zbuild_resolve_default_branch "$_sr_nb")'"
fi
assert_eq "[SPEC-17] precondition: zbuild_resolve_merge_base returns EMPTY" \
    "" "$(zbuild_resolve_merge_base "$_sr_nb")"
if git -C "$_sr_nb" rev-parse --verify 'HEAD~1' >/dev/null 2>&1; then
    assert_pass "[SPEC-17] precondition: HEAD~1 exists (there IS a prior commit to have seen)"
else
    assert_fail "[SPEC-17] precondition: HEAD~1 must exist" "did not verify"
fi

set +e
_spec17_out="$(ZBUILD_DIFF_CMD="" _sf_shape_floor "$_sr_nb")"
set -e

assert_contains "[SPEC-17] unresolvable baseline → SHAPE_FLOOR SKIP no_baseline" \
    "$_spec17_out" "SHAPE_FLOOR SKIP no_baseline"
# The positive assertion alone would pass an implementation that printed both
# reasons, or that appended the new one to the old line.
if [[ "$_spec17_out" == *"no_shape_change"* ]]; then
    assert_fail "[SPEC-17] must not claim no_shape_change about a diff it never saw" \
        "$_spec17_out"
else
    assert_pass "[SPEC-17] no_shape_change is NOT reported for an unresolvable baseline"
fi

# ─── SPEC-18 (GUARD, #2064): a resolvable baseline still reports the diff ────
# The other direction. Without this, an implementation that reported no_baseline
# unconditionally would satisfy SPEC-17.

_sr_ok="$TEST_TEMP_DIR/baseline-nonshape-repo"
_sf_mk_floor_repo "$_sr_ok" "main"
git -C "$_sr_ok" checkout -q -b feat/nonshape
printf 'helper v2\n' > "$_sr_ok/scripts/lib/helpers.sh"
git -C "$_sr_ok" add -A
git -C "$_sr_ok" commit -q -m "touch a non-shape file only"

if [[ -n "$(zbuild_resolve_merge_base "$_sr_ok")" ]]; then
    assert_pass "[SPEC-18] precondition: a baseline DOES resolve here"
else
    assert_fail "[SPEC-18] precondition: baseline must resolve" "got empty"
fi

set +e
_spec18_out="$(ZBUILD_DIFF_CMD="" _sf_shape_floor "$_sr_ok")"
set -e

assert_contains "[SPEC-18] resolved baseline + non-shape diff → SHAPE_FLOOR SKIP no_shape_change" \
    "$_spec18_out" "SHAPE_FLOOR SKIP no_shape_change"
if [[ "$_spec18_out" == *"no_baseline"* ]]; then
    assert_fail "[SPEC-18] must not report no_baseline when a baseline resolved" \
        "$_spec18_out"
else
    assert_pass "[SPEC-18] no_baseline is NOT reported when a baseline resolved"
fi

# ─── SPEC-19 (GUARD, #2064): an EMPTY diff off a resolved baseline ──────────
# The sharp discriminator. SPEC-17 and this case produce the IDENTICAL input to
# every line below _sf_diff_files — zero changed files. Only the baseline tells
# them apart, so an implementation that keyed the new reason off "diff came back
# empty" rather than off the resolver passes SPEC-17/18 and fails here.

_sr_empty="$TEST_TEMP_DIR/baseline-emptydiff-repo"
_sf_mk_floor_repo "$_sr_empty" "main"
git -C "$_sr_empty" checkout -q -b feat/nothing

_sf_empty_base="$(zbuild_resolve_merge_base "$_sr_empty")"
if [[ -n "$_sf_empty_base" ]]; then
    assert_pass "[SPEC-19] precondition: a baseline resolves"
else
    assert_fail "[SPEC-19] precondition: baseline must resolve" "got empty"
fi
assert_eq "[SPEC-19] precondition: the diff really is empty (same input as SPEC-17)" \
    "" "$(git -C "$_sr_empty" diff --name-only "$_sf_empty_base" HEAD)"

set +e
_spec19_out="$(ZBUILD_DIFF_CMD="" _sf_shape_floor "$_sr_empty")"
set -e

assert_contains "[SPEC-19] resolved baseline + empty diff → SHAPE_FLOOR SKIP no_shape_change" \
    "$_spec19_out" "SHAPE_FLOOR SKIP no_shape_change"
if [[ "$_spec19_out" == *"no_baseline"* ]]; then
    assert_fail "[SPEC-19] an empty diff is not an absent baseline" "$_spec19_out"
else
    assert_pass "[SPEC-19] an empty diff off a resolved baseline is still no_shape_change"
fi

# ─── SPEC-20 (#2064): the artifact carries the honest reason downstream ─────
# The reason is only worth changing if it survives into shape-floor-result.json,
# which is what every downstream consumer actually reads.

_sf_art_nb="$TEST_TEMP_DIR/sf-nb-artifacts"
mkdir -p "$_sf_art_nb"

set +e
ZBUILD_DIFF_CMD="" \
ZBUILD_SCHEMA_DIFF_CMD="" \
ZBUILD_SHAPE_FLOOR_SCOPE="" \
ZBUILD_REPO_ROOT="$_sr_nb" \
ZBUILD_ARTIFACT_DIR="$_sf_art_nb" \
    shape_floor_run "shape-floor" ""
set -e

_sf_nb_result="$_sf_art_nb/shape-floor-result.json"
assert_eq "[SPEC-20] artifact verdict stays the declared 'skip'" \
    "skip" "$(jq -r '.verdict // empty' "$_sf_nb_result" 2>/dev/null)"
assert_eq "[SPEC-20] artifact reason is no_baseline, not no_shape_change" \
    "no_baseline" "$(jq -r '.reason // empty' "$_sf_nb_result" 2>/dev/null)"


# ─── Results ─────────────────────────────────────────────────────────────────

print_test_results
