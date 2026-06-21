#!/usr/bin/env bash
# Tests: config/templates/simple.yaml skeleton (issue #968, EPIC #966 I2)
# ADR-027 (recursive flow shape), ADR-016 (shipped template, extends: null),
# ADR-037 (merge_policy: auto_unless_flagged skeleton presence)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "config/templates/simple.yaml — skeleton load and stage assertions (#968)"
setup_test_env "template-simple-yaml"

_test_cleanup_hook() { cleanup_test_env; }

# ─── Source under test ───────────────────────────────────────────────────────

# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
# shellcheck source=../../core/pipeline/template-resolver.sh
source "$REPO_ROOT/core/pipeline/template-resolver.sh"

SIMPLE_TPL="$REPO_ROOT/config/templates/simple.yaml"

# ─── SPEC-1: template loads without error ────────────────────────────────────
# CHANGE: simple.yaml did not exist at merge-base → load_template returned
# non-zero. Now it must return 0.

set +e
load_template "$SIMPLE_TPL"
_load_rc=$?
set -e

assert_eq "[SPEC-1] simple.yaml loads without error (exit 0)" "0" "$_load_rc"

# ─── SPEC-2: _TPL_STAGES has exactly 8 entries in canonical order ─────────────
# CHANGE: issue #970 moves objective-gate from index 2 (after plan) to index 5
# (after test, before review). The required flat sequence is now:
#   intake→plan→design→build→test→objective-gate→review→pr
# test_assessment and acceptance-gate explicitly omitted (ADR-037 / issue #968 DoD).

assert_eq "[SPEC-2] _TPL_STAGES count is 8" "8" "${#_TPL_STAGES[@]}"

_expected_stages=(intake plan design build test objective-gate review pr)
_i=0
for _s in "${_expected_stages[@]}"; do
    assert_eq "[SPEC-2] _TPL_STAGES[$_i] == $_s" "$_s" "${_TPL_STAGES[$_i]}"
    _i=$((_i + 1))
done

# [SPEC-2] merge_policy is a reserved template-level knob, NOT a stage section
# (#968 review): it must never appear in _TPL_STAGES nor as a phantom stage def.
_mp_is_stage=0
for _s in "${_TPL_STAGES[@]}"; do [[ "$_s" == "merge_policy" ]] && _mp_is_stage=1; done
assert_eq "[SPEC-2] merge_policy is not parsed as a stage" "0" "$_mp_is_stage"

# ─── SPEC-3: stage roles, io destinations, and router knobs match simple.yaml ─
# CHANGE: at merge-base the file was absent → all stage vars were unset.

# intake
assert_eq "[SPEC-3] intake roles"    "intake"       "$_TPL_STAGE_ROLES_intake"
assert_eq "[SPEC-3] intake io_dests" "file,stdout"  "$_TPL_STAGE_IO_DESTS_intake"

# plan
assert_eq "[SPEC-3] plan roles"             "planner"     "$_TPL_STAGE_ROLES_plan"
assert_eq "[SPEC-3] plan io_dests"          "file,stdout" "$_TPL_STAGE_IO_DESTS_plan"
assert_eq "[SPEC-3] plan router timeout"    "300"         "$_TPL_STAGE_ROUTER_TIMEOUT_plan"
assert_eq "[SPEC-3] plan router max_turns"  "25"          "$_TPL_STAGE_ROUTER_MAX_TURNS_plan"

# objective-gate (T0 tool — no router section)
assert_eq "[SPEC-3] objective-gate roles"    "objective-gate" "$_TPL_STAGE_ROLES_objective_gate"
assert_eq "[SPEC-3] objective-gate io_dests" "file,stdout"    "$_TPL_STAGE_IO_DESTS_objective_gate"

# design
assert_eq "[SPEC-3] design roles"            "designer"    "$_TPL_STAGE_ROLES_design"
assert_eq "[SPEC-3] design io_dests"         "file,stdout" "$_TPL_STAGE_IO_DESTS_design"
assert_eq "[SPEC-3] design router timeout"   "600"         "$_TPL_STAGE_ROUTER_TIMEOUT_design"
assert_eq "[SPEC-3] design router max_turns" "0"           "$_TPL_STAGE_ROUTER_MAX_TURNS_design"

# build
assert_eq "[SPEC-3] build roles"            "builder"     "$_TPL_STAGE_ROLES_build"
assert_eq "[SPEC-3] build io_dests"         "file,stdout" "$_TPL_STAGE_IO_DESTS_build"
assert_eq "[SPEC-3] build router timeout"   "900"         "$_TPL_STAGE_ROUTER_TIMEOUT_build"
assert_eq "[SPEC-3] build router max_turns" "0"           "$_TPL_STAGE_ROUTER_MAX_TURNS_build"

# test
assert_eq "[SPEC-3] test roles"    "tester"       "$_TPL_STAGE_ROLES_test"
assert_eq "[SPEC-3] test io_dests" "file,stdout"  "$_TPL_STAGE_IO_DESTS_test"

# review
assert_eq "[SPEC-3] review roles"            "review_report" "$_TPL_STAGE_ROLES_review"
assert_eq "[SPEC-3] review io_dests"         "file,stdout" "$_TPL_STAGE_IO_DESTS_review"
assert_eq "[SPEC-3] review router timeout"   "300"         "$_TPL_STAGE_ROUTER_TIMEOUT_review"
assert_eq "[SPEC-3] review router max_turns" "25"          "$_TPL_STAGE_ROUTER_MAX_TURNS_review"

# pr (T0 tool stage — no router section)
assert_eq "[SPEC-3] pr roles"    "pr"           "$_TPL_STAGE_ROLES_pr"
assert_eq "[SPEC-3] pr io_dests" "file,stdout"  "$_TPL_STAGE_IO_DESTS_pr"

# ─── SPEC-4: resolve_template_file 'simple' returns the shipped path ─────────
# GUARD: template-resolver already handles id→path resolution; we verify the
# shipped file is reachable via the public API so --template simple dispatches
# correctly. Reverting simple.yaml would cause this assertion to also break
# (file not found → resolver returns nonexistent path), confirming load-bearing
# wiring. GUARD: not contorted to fail at baseline (resolver API unchanged).

set +e
_resolved="$(resolve_template_file "simple" "$REPO_ROOT")"
_resolve_rc=$?
set -e

assert_eq "[SPEC-4] resolve_template_file exit 0" "0" "$_resolve_rc"
assert_eq "[SPEC-4] resolve_template_file 'simple' returns shipped path" \
    "$REPO_ROOT/config/templates/simple.yaml" "$_resolved"

# ─── SPEC-11: dispatch units are 8 flat stage units (no cycles) ──────────────
# GUARD: simple.yaml uses a flat flow with no cycle stages, so every dispatch
# unit is stage:<id>. This confirms the loader did not misclassify any leaf.

assert_eq "[SPEC-11] dispatch units count is 8" "8" "${#_TPL_DISPATCH_UNITS[@]}"
assert_eq "[SPEC-11] dispatch[0] stage:intake"  "stage:intake"  "${_TPL_DISPATCH_UNITS[0]}"
assert_eq "[SPEC-11] dispatch[1] stage:plan"    "stage:plan"    "${_TPL_DISPATCH_UNITS[1]}"
assert_eq "[SPEC-11] dispatch[2] stage:design"  "stage:design"  "${_TPL_DISPATCH_UNITS[2]}"
assert_eq "[SPEC-11] dispatch[3] stage:build"   "stage:build"   "${_TPL_DISPATCH_UNITS[3]}"
assert_eq "[SPEC-11] dispatch[4] stage:test"    "stage:test"    "${_TPL_DISPATCH_UNITS[4]}"
assert_eq "[SPEC-11] dispatch[5] stage:objective-gate" "stage:objective-gate" "${_TPL_DISPATCH_UNITS[5]}"
assert_eq "[SPEC-11] dispatch[6] stage:review"  "stage:review"  "${_TPL_DISPATCH_UNITS[6]}"
assert_eq "[SPEC-11] dispatch[7] stage:pr"      "stage:pr"      "${_TPL_DISPATCH_UNITS[7]}"

# ─── SPEC-12: objective-gate is at index 5 in _TPL_STAGES (after test) ────────
# CHANGE: at merge-base objective-gate was at index 2. Issue #970 moves it to
# index 5. This assertion fails at baseline and passes with the new order.

assert_eq "[SPEC-12] _TPL_STAGES[5] == objective-gate" "objective-gate" "${_TPL_STAGES[5]}"

# ─── SPEC-13: design is at index 2 (shifted from prior index 3) ──────────────
# CHANGE: issue #970 moves objective-gate out of position 2, so design shifts
# from index 3 to index 2. This assertion fails at baseline and passes here.

assert_eq "[SPEC-13] _TPL_STAGES[2] == design" "design" "${_TPL_STAGES[2]}"

# ─── Results ─────────────────────────────────────────────────────────────────

print_test_results
