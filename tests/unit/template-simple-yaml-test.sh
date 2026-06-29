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

# ─── SPEC-2: _TPL_STAGES has exactly 16 entries in canonical order ────────────
# CHANGE (B6 #1138, ADR-040): build_test_cycle is recomposed from the retired
# monolithic objective-gate to the decomposed mechanical gates + gate-aggregator
# (the objective-gate plugin was then removed in B7 #1139).
# CHANGE (C3 #1142, ADR-040 §3 / ADR-039): the single `review` stage is replaced
# by the `review_lenses` advisory parallel group (5 lens member stages) followed
# by the `review-aggregator` leaf. The group id itself is NOT a flat stage (like a
# cycle id); its members expand in flow order.
# CHANGE (#1129 Change C, ADR-012): the lint/coverage/mutation read-out gates are
# DROPPED as cycle members (redundant — mutation runs in the suite; lint+coverage
# are folded into `--tier all`/`npm test`, run by the `test` member). Their
# plugins stay canonical (ADR-013) but dormant. The flat sequence is now:
#   intake→plan→design→build→test→shape-floor→acceptance-gate→secret-scan→
#   gate-aggregator→lens-security→lens-performance→lens-red-team→lens-correctness→
#   lens-scope→review-aggregator→pr
# objective-gate AND review-report are UNREFERENCED here; test_assessment omitted.

assert_eq "[SPEC-2] _TPL_STAGES count is 16" "16" "${#_TPL_STAGES[@]}"

_expected_stages=(intake plan design build test shape-floor acceptance-gate secret-scan gate-aggregator lens-security lens-performance lens-red-team lens-correctness lens-scope review-aggregator pr)
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

# decomposed mechanical gates (B6 #1138, ADR-040) — bound by role, not stage id.
# shape-floor / secret-scan / gate-aggregator are T0 tools (no router section);
# acceptance-gate is the mechanical T1 contract gate.
# (#1129 Change C: lint/coverage/mutation dropped as cycle members — their roles
# are no longer present in simple.yaml; the plugins stay canonical but dormant.)
assert_eq "[SPEC-3] shape-floor roles"      "shape_floor"     "$_TPL_STAGE_ROLES_shape_floor"
assert_eq "[SPEC-3] acceptance-gate roles"  "acceptance_gate" "$_TPL_STAGE_ROLES_acceptance_gate"
assert_eq "[SPEC-3] lint stage removed (role var unset)"     "" "${_TPL_STAGE_ROLES_lint:-}"
assert_eq "[SPEC-3] coverage stage removed (role var unset)" "" "${_TPL_STAGE_ROLES_coverage:-}"
assert_eq "[SPEC-3] mutation stage removed (role var unset)" "" "${_TPL_STAGE_ROLES_mutation:-}"
assert_eq "[SPEC-3] secret-scan roles"      "secret_scan"     "$_TPL_STAGE_ROLES_secret_scan"
assert_eq "[SPEC-3] gate-aggregator roles"  "gate_aggregator" "$_TPL_STAGE_ROLES_gate_aggregator"
assert_eq "[SPEC-3] gate-aggregator io_dests" "file,stdout"   "$_TPL_STAGE_IO_DESTS_gate_aggregator"

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

# review_lenses members (C3 #1142): all five lens stages bind by role review_lens
# to the SAME review-lens plugin; they differ only by the lens id derived from the
# stage name. The legacy single `review` stage (role review_report) is removed.
assert_eq "[SPEC-3] review stage removed (role var unset)" "" "${_TPL_STAGE_ROLES_review:-}"
assert_eq "[SPEC-3] lens-security roles"    "review_lens" "$_TPL_STAGE_ROLES_lens_security"
assert_eq "[SPEC-3] lens-performance roles" "review_lens" "$_TPL_STAGE_ROLES_lens_performance"
assert_eq "[SPEC-3] lens-red-team roles"    "review_lens" "$_TPL_STAGE_ROLES_lens_red_team"
assert_eq "[SPEC-3] lens-correctness roles" "review_lens" "$_TPL_STAGE_ROLES_lens_correctness"
assert_eq "[SPEC-3] lens-scope roles"       "review_lens" "$_TPL_STAGE_ROLES_lens_scope"
assert_eq "[SPEC-3] lens-security io_dests" "file,stdout" "$_TPL_STAGE_IO_DESTS_lens_security"
assert_eq "[SPEC-3] lens-security router timeout"   "300" "$_TPL_STAGE_ROUTER_TIMEOUT_lens_security"
assert_eq "[SPEC-3] lens-security router max_turns" "25"  "$_TPL_STAGE_ROUTER_MAX_TURNS_lens_security"

# review-aggregator (C2 #1141): advisory merge of the lens results; no LLM call,
# so no router section. Bound by role review_aggregator.
assert_eq "[SPEC-3] review-aggregator roles"    "review_aggregator" "$_TPL_STAGE_ROLES_review_aggregator"
assert_eq "[SPEC-3] review-aggregator io_dests" "file,stdout"       "$_TPL_STAGE_IO_DESTS_review_aggregator"

# review_lenses parallel group registered (member-of mapping + group type).
assert_eq "[SPEC-3] review_lenses is a parallel group" "parallel" "${_TPL_STAGE_TYPE_review_lenses:-}"
assert_eq "[SPEC-3] lens-security member_of review_lenses" "review_lenses" "${_TPL_PARALLEL_MEMBER_OF_lens_security:-}"
assert_eq "[SPEC-3] review_lenses members csv" \
    "lens-security,lens-performance,lens-red-team,lens-correctness,lens-scope" \
    "${_TPL_PARALLEL_FLOW_review_lenses:-}"

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

# ─── SPEC-11: dispatch units are 7 (cycle + parallel groups each fold to one) ─
# B6 (#1138): the build_test_cycle's members collapse into ONE cycle dispatch
# unit (6 members after #1129 Change C dropped lint/coverage/mutation). C3
# (#1142): the review_lenses parallel group's 5 lens members collapse
# into ONE parallel dispatch unit, and review-aggregator is its own stage unit.
# Count is now 7: intake, plan, design, cycle:build_test_cycle,
# parallel:review_lenses, stage:review-aggregator, pr.

assert_eq "[SPEC-11] dispatch units count is 7" "7" "${#_TPL_DISPATCH_UNITS[@]}"
assert_eq "[SPEC-11] dispatch[0] stage:intake"         "stage:intake"         "${_TPL_DISPATCH_UNITS[0]}"
assert_eq "[SPEC-11] dispatch[1] stage:plan"           "stage:plan"           "${_TPL_DISPATCH_UNITS[1]}"
assert_eq "[SPEC-11] dispatch[2] stage:design"         "stage:design"         "${_TPL_DISPATCH_UNITS[2]}"
assert_eq "[SPEC-11] dispatch[3] cycle:build_test_cycle" "cycle:build_test_cycle" "${_TPL_DISPATCH_UNITS[3]}"
assert_eq "[SPEC-11] dispatch[4] parallel:review_lenses" "parallel:review_lenses" "${_TPL_DISPATCH_UNITS[4]}"
assert_eq "[SPEC-11] dispatch[5] stage:review-aggregator" "stage:review-aggregator" "${_TPL_DISPATCH_UNITS[5]}"
assert_eq "[SPEC-11] dispatch[6] stage:pr"             "stage:pr"             "${_TPL_DISPATCH_UNITS[6]}"

# ─── SPEC-14 / SPEC-5: build_test_cycle registered with correct stages and max ─
# CHANGE (B6 #1138, ADR-040): _TPL_CYCLES must contain build_test_cycle with its
# decomposed members (build/test + the mechanical gates + gate-aggregator).
# CHANGE (#1129 Change C, ADR-012): lint/coverage/mutation dropped → 6 members.
# max_iterations stays 5 (I10-B #1089) — the exit_when predicate (now on
# gate-aggregator) drives looping.

_btc_in_cycles=0
for _cyc in "${_TPL_CYCLES[@]}"; do [[ "$_cyc" == "build_test_cycle" ]] && _btc_in_cycles=1; done
assert_eq "[SPEC-14] _TPL_CYCLES contains build_test_cycle" "1" "$_btc_in_cycles"
assert_eq "[SPEC-14] _TPL_CYCLE_STAGES_build_test_cycle" \
    "build,test,shape-floor,acceptance-gate,secret-scan,gate-aggregator" \
    "$_TPL_CYCLE_STAGES_build_test_cycle"
assert_eq "[SPEC-5] [SPEC-14] _TPL_CYCLE_MAX_build_test_cycle is 5 (I10-B)" \
    "5" "$_TPL_CYCLE_MAX_build_test_cycle"

# ─── SPEC-15: build_test_cycle exit_when predicate fields are set correctly ───
# CHANGE (I10-A #976): the exit_when block must parse into UNTIL_* vars so the
# cycle validator and runner can resolve the break-out condition.

assert_eq "[SPEC-15] _TPL_CYCLE_UNTIL_STAGE_build_test_cycle" \
    "gate-aggregator" "$_TPL_CYCLE_UNTIL_STAGE_build_test_cycle"
assert_eq "[SPEC-15] _TPL_CYCLE_UNTIL_FIELD_build_test_cycle" \
    "verdict" "$_TPL_CYCLE_UNTIL_FIELD_build_test_cycle"
assert_eq "[SPEC-15] _TPL_CYCLE_UNTIL_OP_build_test_cycle" \
    "eq" "$_TPL_CYCLE_UNTIL_OP_build_test_cycle"
assert_eq "[SPEC-15] _TPL_CYCLE_UNTIL_VALUE_build_test_cycle" \
    "pass" "$_TPL_CYCLE_UNTIL_VALUE_build_test_cycle"

# ─── SPEC-12: shape-floor is at index 5 in _TPL_STAGES (after test) ───────────
# CHANGE (B6 #1138): the first mechanical gate (shape-floor) occupies the slot
# right after the test stage.

assert_eq "[SPEC-12] _TPL_STAGES[5] == shape-floor" "shape-floor" "${_TPL_STAGES[5]}"
# CHANGE (#1129 Change C): lint/coverage/mutation removed → gate-aggregator shifts
# from flat index 11 to index 8 (build=3,test=4,shape-floor=5,acceptance-gate=6,
# secret-scan=7,gate-aggregator=8).
assert_eq "[SPEC-12] _TPL_STAGES[8] == gate-aggregator (cycle exit_when source)" \
    "gate-aggregator" "${_TPL_STAGES[8]}"

# ─── SPEC-13: design is at index 2 (shifted from prior index 3) ──────────────
# CHANGE: design sits at index 2 in the flat sequence (after intake, plan).

assert_eq "[SPEC-13] _TPL_STAGES[2] == design" "design" "${_TPL_STAGES[2]}"

# ─── SPEC-6 (guard, A3-pr #756): simple.yaml pr role unchanged by standard migration ──
# GUARD: A3-pr adds plugins/agent/pr-delivery (role: pr_delivery) for standard.yaml only.
# simple.yaml's pr stage keeps roles: [pr] — bound to the pr-open tool plugin,
# not the new pr agent. This guard confirms the migration did not inadvertently
# change simple.yaml's pr role binding.
assert_eq "[SPEC-6] simple.yaml: pr roles remain pr (not pr_delivery, guard)" \
    "pr" "${_TPL_STAGE_ROLES_pr}"

# ─── SPEC-7 (I9-B): template_merge_policy() returns "auto_unless_flagged" for simple.yaml ─
# CHANGE I9-B (#1050): simple.yaml restored to auto_unless_flagged; I9-A had set it to
# manual as a placeholder. This assertion now reflects the intended default.
assert_eq "[SPEC-7] template_merge_policy() == auto_unless_flagged" \
    "auto_unless_flagged" "$(template_merge_policy)"

# Retirement guards (I10-C #1090 + B6 #1138): test_assessment is excluded from
# build_test_cycle; convergence is owned by the gate-aggregator. That invariant
# is already enforced above — SPEC-14 pins _TPL_CYCLE_STAGES to the decomposed
# gate roster (test_assessment absent) and SPEC-15 pins the exit_when source to
# gate-aggregator. No separate assertion is added here to avoid duplicating those checks.

# ─── Results ─────────────────────────────────────────────────────────────────

print_test_results
