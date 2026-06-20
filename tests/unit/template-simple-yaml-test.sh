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

set +e
load_template "$SIMPLE_TPL"
_load_rc=$?
set -e

assert_eq "[SPEC-1] simple.yaml loads without error (exit 0)" "0" "$_load_rc"

# ─── SPEC-2: _TPL_STAGES has exactly 7 entries in canonical order ─────────────

assert_eq "[SPEC-2] _TPL_STAGES count is 7" "7" "${#_TPL_STAGES[@]}"

_expected_stages=(intake plan build test test_assessment acceptance-gate review)
_i=0
for _s in "${_expected_stages[@]}"; do
    assert_eq "[SPEC-2] _TPL_STAGES[$_i] == $_s" "$_s" "${_TPL_STAGES[$_i]}"
    _i=$((_i + 1))
done

# ─── SPEC-3: stage roles, io destinations, and router knobs match simple.yaml ─

# intake
assert_eq "[SPEC-3] intake roles"    "intake"       "$_TPL_STAGE_ROLES_intake"
assert_eq "[SPEC-3] intake io_dests" "file,stdout"  "$_TPL_STAGE_IO_DESTS_intake"

# plan
assert_eq "[SPEC-3] plan roles"           "planner"  "$_TPL_STAGE_ROLES_plan"
assert_eq "[SPEC-3] plan io_dests"        "file,stdout" "$_TPL_STAGE_IO_DESTS_plan"
assert_eq "[SPEC-3] plan router timeout"  "300"      "$_TPL_STAGE_ROUTER_TIMEOUT_plan"
assert_eq "[SPEC-3] plan router max_turns" "25"      "$_TPL_STAGE_ROUTER_MAX_TURNS_plan"

# build
assert_eq "[SPEC-3] build roles"           "builder"     "$_TPL_STAGE_ROLES_build"
assert_eq "[SPEC-3] build io_dests"        "file,stdout" "$_TPL_STAGE_IO_DESTS_build"
assert_eq "[SPEC-3] build router timeout"  "900"         "$_TPL_STAGE_ROUTER_TIMEOUT_build"
assert_eq "[SPEC-3] build router max_turns" "0"          "$_TPL_STAGE_ROUTER_MAX_TURNS_build"

# test
assert_eq "[SPEC-3] test roles"    "tester"       "$_TPL_STAGE_ROLES_test"
assert_eq "[SPEC-3] test io_dests" "file,stdout"  "$_TPL_STAGE_IO_DESTS_test"

# test_assessment
assert_eq "[SPEC-3] test_assessment roles"           "test_assessment" "$_TPL_STAGE_ROLES_test_assessment"
assert_eq "[SPEC-3] test_assessment io_dests"        "file,stdout"     "$_TPL_STAGE_IO_DESTS_test_assessment"
assert_eq "[SPEC-3] test_assessment router timeout"  "300"             "$_TPL_STAGE_ROUTER_TIMEOUT_test_assessment"
assert_eq "[SPEC-3] test_assessment router max_turns" "25"             "$_TPL_STAGE_ROUTER_MAX_TURNS_test_assessment"

# acceptance-gate (safe var name: acceptance_gate)
assert_eq "[SPEC-3] acceptance-gate roles"           "acceptance_gate" "$_TPL_STAGE_ROLES_acceptance_gate"
assert_eq "[SPEC-3] acceptance-gate io_dests"        "file,stdout"     "$_TPL_STAGE_IO_DESTS_acceptance_gate"
assert_eq "[SPEC-3] acceptance-gate router timeout"  "600"             "$_TPL_STAGE_ROUTER_TIMEOUT_acceptance_gate"
assert_eq "[SPEC-3] acceptance-gate router max_turns" "10"             "$_TPL_STAGE_ROUTER_MAX_TURNS_acceptance_gate"

# review
assert_eq "[SPEC-3] review roles"           "reviewer"    "$_TPL_STAGE_ROLES_review"
assert_eq "[SPEC-3] review io_dests"        "file,stdout" "$_TPL_STAGE_IO_DESTS_review"
assert_eq "[SPEC-3] review router timeout"  "300"         "$_TPL_STAGE_ROUTER_TIMEOUT_review"
assert_eq "[SPEC-3] review router max_turns" "25"         "$_TPL_STAGE_ROUTER_MAX_TURNS_review"

# ─── SPEC-4: resolve_template_file 'simple' returns the shipped path ─────────
# Guard: template-resolver already handles id→path resolution; we verify the
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

# ─── Non-SPEC: dispatch units reflect cycle structure ────────────────────────
# Informational only — no SPEC tag; confirms build_test_cycle dispatches as
# a single cycle unit covering its 3 leaf members.

assert_eq "dispatch units count is 5" "5" "${#_TPL_DISPATCH_UNITS[@]}"
assert_eq "dispatch[0] stage:intake"           "stage:intake"           "${_TPL_DISPATCH_UNITS[0]}"
assert_eq "dispatch[1] stage:plan"             "stage:plan"             "${_TPL_DISPATCH_UNITS[1]}"
assert_eq "dispatch[2] cycle:build_test_cycle" "cycle:build_test_cycle" "${_TPL_DISPATCH_UNITS[2]}"
assert_eq "dispatch[3] stage:acceptance-gate"  "stage:acceptance-gate"  "${_TPL_DISPATCH_UNITS[3]}"
assert_eq "dispatch[4] stage:review"           "stage:review"           "${_TPL_DISPATCH_UNITS[4]}"

# ─── Results ─────────────────────────────────────────────────────────────────

print_test_results
