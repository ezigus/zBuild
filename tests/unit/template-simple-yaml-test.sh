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

# #1270: this test pins the resolver's returned shipped path. Defensively scrub
# any ambient ZBUILD_TEMPLATES_DIR so a leaked value can never redirect the
# resolver read-root and break the path assertions. (The #1268 engine seam that
# honored this var was reverted in #1270; this unset guards against reintroduction.)
unset ZBUILD_TEMPLATES_DIR

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

# ─── SPEC-2: _TPL_STAGES has exactly 14 entries in canonical order ────────────
# CHANGE (B6 #1138, ADR-040): build_test_cycle is recomposed from the retired
# monolithic objective-gate to the decomposed mechanical gates + gate-aggregator
# (the objective-gate plugin was then removed in B7 #1139).
# CHANGE (C3 #1142, ADR-040 §3 / ADR-039): the single `review` stage is replaced
# by the `review_lenses` advisory group followed by the `review-aggregator` leaf.
# CHANGE (#1129 Change C, ADR-012): the lint/coverage/mutation read-out gates are
# DROPPED as cycle members (redundant — mutation runs in the suite; lint+coverage
# are folded into `--tier all`/`npm test`, run by the `test` member). Their
# plugins stay canonical (ADR-013) but dormant.
# CHANGE (#1218, ADR-046): `design` is now wrapped in a `design_verify_cycle`
# (design → design-gate) that loops back to design PRE-build, and the reused
# `impact` agent is added as a lone advisory-by-placement stage after the cycle.
# design-gate + impact expand in flow order.
# CHANGE (#1295, ADR-047 §2): review_lenses converted from `type: parallel` to
# `type: map over: lenses`. The 5 lens-* member stages are replaced by DATA
# elements dispatched by _strategy_run_map; the group id itself is now the single
# flat stage entry (not its member stages). The flat sequence is now:
#   intake→plan→design→design-gate→impact→build→test→shape-floor→acceptance-gate→
#   secret-scan→gate-aggregator→review_lenses→review-aggregator→pr
# (review_lenses occupies ONE slot, not five — elements are work-unit env vars.)
# objective-gate AND review-report are UNREFERENCED here; test_assessment omitted.

assert_eq "[SPEC-2] _TPL_STAGES count is 14" "14" "${#_TPL_STAGES[@]}"

_expected_stages=(intake plan design design-gate impact build test shape-floor acceptance-gate secret-scan gate-aggregator review_lenses review-aggregator pr)
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
assert_eq "[SPEC-3] plan router max_turns"  "45"          "$_TPL_STAGE_ROUTER_MAX_TURNS_plan"

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

# design-gate (#1218, ADR-046): T0 tool PRE-build structural gate; bound by role
# design_gate (no router section — no LLM). design_verify_cycle member.
assert_eq "[SPEC-3] design-gate roles"    "design_gate" "$_TPL_STAGE_ROLES_design_gate"
assert_eq "[SPEC-3] design-gate io_dests" "file,stdout" "$_TPL_STAGE_IO_DESTS_design_gate"

# impact (#1218, ADR-046): reused T2 agent as a lone advisory-by-placement stage
# (role impact_analyzer, timeout 600 / max_turns 45 copied from standard.yaml).
# #1242: timeout right-sized 180→600 to match its tool-heavy T2 sibling `design`
# (the 180s T1-era budget was too low for a 45-turn sonnet job — rc=124 hang).
assert_eq "[SPEC-3] impact roles"            "impact_analyzer" "$_TPL_STAGE_ROLES_impact"
assert_eq "[SPEC-3] impact io_dests"         "file,stdout"     "$_TPL_STAGE_IO_DESTS_impact"
assert_eq "[SPEC-3] impact router timeout"   "600"             "$_TPL_STAGE_ROUTER_TIMEOUT_impact"
assert_eq "[SPEC-3] impact router max_turns" "45"              "$_TPL_STAGE_ROUTER_MAX_TURNS_impact"

# build
assert_eq "[SPEC-3] build roles"            "builder"     "$_TPL_STAGE_ROLES_build"
assert_eq "[SPEC-3] build io_dests"         "file,stdout" "$_TPL_STAGE_IO_DESTS_build"
assert_eq "[SPEC-3] build router timeout"   "900"         "$_TPL_STAGE_ROUTER_TIMEOUT_build"
assert_eq "[SPEC-3] build router max_turns" "0"           "$_TPL_STAGE_ROUTER_MAX_TURNS_build"

# test
assert_eq "[SPEC-3] test roles"    "tester"       "$_TPL_STAGE_ROLES_test"
assert_eq "[SPEC-3] test io_dests" "file,stdout"  "$_TPL_STAGE_IO_DESTS_test"

# review_lenses map group (#1295, ADR-047 §2): converted from type:parallel to
# type:map. The legacy single `review` stage (role review_report) is removed.
# lens-* individual stage vars are GONE (no stage_def_row for them any more).
assert_eq "[SPEC-3] review stage removed (role var unset)"        "" "${_TPL_STAGE_ROLES_review:-}"
assert_eq "[SPEC-3] lens-security stage removed (role var unset)" "" "${_TPL_STAGE_ROLES_lens_security:-}"
assert_eq "[SPEC-3] lens-scope stage removed (role var unset)"    "" "${_TPL_STAGE_ROLES_lens_scope:-}"
# review_lenses map group: roles/io/router come from the GROUP stage itself.
assert_eq "[SPEC-3] review_lenses is a map group" "map" "${_TPL_STAGE_TYPE_review_lenses:-}"
assert_eq "[SPEC-3] review_lenses roles"     "review_lens" "${_TPL_MAP_ROLES_review_lenses:-}"
assert_eq "[SPEC-3] review_lenses over dim"  "lenses"      "${_TPL_MAP_OVER_review_lenses:-}"
assert_eq "[SPEC-3] review_lenses elements csv" \
    "security,performance,red-team,correctness,scope,sre" \
    "${_TPL_MAP_ELEMENTS_review_lenses:-}"
assert_eq "[SPEC-3] review_lenses io_dests"     "file" "${_TPL_STAGE_IO_DESTS_review_lenses:-}"
assert_eq "[SPEC-3] review_lenses router timeout"   "300" "${_TPL_STAGE_ROUTER_TIMEOUT_review_lenses:-}"
assert_eq "[SPEC-3] review_lenses router max_turns" "25"  "${_TPL_STAGE_ROUTER_MAX_TURNS_review_lenses:-}"

# review-aggregator (C2 #1141): advisory merge of the lens results; no LLM call,
# so no router section. Bound by role review_aggregator.
assert_eq "[SPEC-3] review-aggregator roles"    "review_aggregator" "$_TPL_STAGE_ROLES_review_aggregator"
assert_eq "[SPEC-3] review-aggregator io_dests" "file,stdout"       "$_TPL_STAGE_IO_DESTS_review_aggregator"

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

# ─── SPEC-11: dispatch units are 8 (cycles + map groups each fold to one) ─────
# B6 (#1138): the build_test_cycle's members collapse into ONE cycle dispatch
# unit (6 members after #1129 Change C dropped lint/coverage/mutation). C3
# (#1142): the review_lenses group collapses into ONE dispatch unit, and
# review-aggregator is its own stage unit.
# #1218 (ADR-046): design + design-gate collapse into ONE design_verify_cycle
# dispatch unit, and impact is its own stage unit right after it.
# #1295 (ADR-047 §2): review_lenses converted from parallel:→map:review_lenses.
# Count is now 8: intake, plan, cycle:design_verify_cycle, stage:impact,
# cycle:build_test_cycle, map:review_lenses, stage:review-aggregator, pr.

assert_eq "[SPEC-11] dispatch units count is 8" "8" "${#_TPL_DISPATCH_UNITS[@]}"
assert_eq "[SPEC-11] dispatch[0] stage:intake"         "stage:intake"         "${_TPL_DISPATCH_UNITS[0]}"
assert_eq "[SPEC-11] dispatch[1] stage:plan"           "stage:plan"           "${_TPL_DISPATCH_UNITS[1]}"
assert_eq "[SPEC-11] dispatch[2] cycle:design_verify_cycle" "cycle:design_verify_cycle" "${_TPL_DISPATCH_UNITS[2]}"
assert_eq "[SPEC-11] dispatch[3] stage:impact"         "stage:impact"         "${_TPL_DISPATCH_UNITS[3]}"
assert_eq "[SPEC-11] dispatch[4] cycle:build_test_cycle" "cycle:build_test_cycle" "${_TPL_DISPATCH_UNITS[4]}"
assert_eq "[SPEC-11] dispatch[5] map:review_lenses"    "map:review_lenses"    "${_TPL_DISPATCH_UNITS[5]}"
assert_eq "[SPEC-11] dispatch[6] stage:review-aggregator" "stage:review-aggregator" "${_TPL_DISPATCH_UNITS[6]}"
assert_eq "[SPEC-11] dispatch[7] stage:pr"             "stage:pr"             "${_TPL_DISPATCH_UNITS[7]}"

# ─── SPEC-16 (#1218, ADR-046): design_verify_cycle registered correctly ───────
# _TPL_CYCLES must ALSO contain design_verify_cycle (design → design-gate); its
# exit_when binds design-gate.verdict == pass (the convergence:gate member is the
# exit_when target directly — a single gate, no separate aggregator). max_iter 3.
_dvc_in_cycles=0
for _cyc in "${_TPL_CYCLES[@]}"; do [[ "$_cyc" == "design_verify_cycle" ]] && _dvc_in_cycles=1; done
assert_eq "[SPEC-16] _TPL_CYCLES contains design_verify_cycle" "1" "$_dvc_in_cycles"
assert_eq "[SPEC-16] _TPL_CYCLE_STAGES_design_verify_cycle" \
    "design,design-gate" "$_TPL_CYCLE_STAGES_design_verify_cycle"
assert_eq "[SPEC-16] _TPL_CYCLE_MAX_design_verify_cycle is 3" \
    "3" "$_TPL_CYCLE_MAX_design_verify_cycle"
assert_eq "[SPEC-16] _TPL_CYCLE_UNTIL_STAGE_design_verify_cycle" \
    "design-gate" "$_TPL_CYCLE_UNTIL_STAGE_design_verify_cycle"
assert_eq "[SPEC-16] _TPL_CYCLE_UNTIL_FIELD_design_verify_cycle" \
    "verdict" "$_TPL_CYCLE_UNTIL_FIELD_design_verify_cycle"
assert_eq "[SPEC-16] _TPL_CYCLE_UNTIL_VALUE_design_verify_cycle" \
    "pass" "$_TPL_CYCLE_UNTIL_VALUE_design_verify_cycle"

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

# ─── SPEC-17 (#1219, ADR-045/ADR-046): build_test_cycle route_back → design ───
# The final EPIC #1216 wiring: a design-rooted acceptance failure (tautology)
# surfaces as gate-aggregator.verdict==route_design, which the build_test_cycle's
# route_back edge matches to REWIND to the earlier design_verify_cycle (re-author
# the SPEC), bounded to one pass (max: 1). This parses into the sibling
# _TPL_CYCLE_ROUTE_BACK_* vars (a sibling of exit_when, #1217). Adding route_back
# is NOT a new stage/dispatch unit → the 18-entry _TPL_STAGES count (SPEC-2) and
# the 8-unit dispatch list (SPEC-11) are UNCHANGED.
assert_eq "[SPEC-17] route_back.to == design_verify_cycle (earlier top-level unit)" \
    "design_verify_cycle" "${_TPL_CYCLE_ROUTE_BACK_TO_build_test_cycle:-}"
assert_eq "[SPEC-17] route_back.when.stage == gate-aggregator" \
    "gate-aggregator" "${_TPL_CYCLE_ROUTE_BACK_STAGE_build_test_cycle:-}"
assert_eq "[SPEC-17] route_back.when.field == verdict" \
    "verdict" "${_TPL_CYCLE_ROUTE_BACK_FIELD_build_test_cycle:-}"
assert_eq "[SPEC-17] route_back.when.op == eq" \
    "eq" "${_TPL_CYCLE_ROUTE_BACK_OP_build_test_cycle:-}"
assert_eq "[SPEC-17] route_back.when.value == route_design" \
    "route_design" "${_TPL_CYCLE_ROUTE_BACK_VALUE_build_test_cycle:-}"
assert_eq "[SPEC-17] route_back.max == 1 (one re-author pass)" \
    "1" "${_TPL_CYCLE_ROUTE_BACK_MAX_build_test_cycle:-}"

# ─── SPEC-12: shape-floor is at index 7 in _TPL_STAGES (after build/test) ─────
# CHANGE (#1218, ADR-046): design-gate + impact inserted at indices 3,4 shift the
# whole build_test_cycle roster by +2 — shape-floor moves from index 5 to 7,
# gate-aggregator from 8 to 10 (design=2,design-gate=3,impact=4,build=5,test=6,
# shape-floor=7,acceptance-gate=8,secret-scan=9,gate-aggregator=10).

assert_eq "[SPEC-12] _TPL_STAGES[7] == shape-floor" "shape-floor" "${_TPL_STAGES[7]}"
assert_eq "[SPEC-12] _TPL_STAGES[10] == gate-aggregator (cycle exit_when source)" \
    "gate-aggregator" "${_TPL_STAGES[10]}"

# ─── SPEC-13: design is at index 2; design-gate at 3, impact at 4 ─────────────
# CHANGE: design sits at index 2 (after intake, plan); its verifier design-gate
# follows at 3, then the advisory impact at 4 (#1218, ADR-046).

assert_eq "[SPEC-13] _TPL_STAGES[2] == design" "design" "${_TPL_STAGES[2]}"
assert_eq "[SPEC-13] _TPL_STAGES[3] == design-gate" "design-gate" "${_TPL_STAGES[3]}"
assert_eq "[SPEC-13] _TPL_STAGES[4] == impact" "impact" "${_TPL_STAGES[4]}"

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
