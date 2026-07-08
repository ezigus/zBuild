#!/usr/bin/env bash
# tests/unit/template-resolvability-preflight-test.sh — EPIC #1277 / issue #1282.
#
# ADR-047 §5: the engine-owned _ZBUILD_CANONICAL_STAGES closed-vocabulary fence is
# retired; its membership role is re-expressed as a FAIL-CLOSED, manifest-derived
# resolvability preflight (_runner_validate_leaf_resolvability, core/pipeline/runner.sh),
# and its canonical-order role by the upstream-input data-dependency DAG
# (core/pipeline/contract-validator.sh). This test guards:
#
#   FICTITIOUS-STAGE HARNESS (SPEC-1/2/3): a brand-new, fictitiously-named stage
#     (`frobnicate`) with a valid plugin + fixture template LOADS and its leaf
#     RESOLVES via resolve_stage_plugin — with ZERO edits to core/pipeline/template.sh
#     (byte-identical shasum, contains no `frobnicate` literal). The mechanics name no
#     stage.
#
#   FAIL-CLOSED PREFLIGHT (SPEC-4/5): an unresolvable leaf ERRORS (not warns) at load
#     with the pinned ADR-047 §5 message naming the id.
#
#   STRANGLER AGREEMENT (SPEC-6): across the fixture-template corpus + config/templates,
#     the NEW resolvability preflight rejects a SUPERSET-OR-EQUAL set of what the OLD
#     canonical fence (ZBUILD_LEGACY_STAGE_VALIDATION=1) rejected — proving the
#     replacement is at least as strict before the old code is removed (a later PR).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEMPLATE_SH="$REPO_ROOT/core/pipeline/template.sh"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "template resolvability preflight + fictitious-stage harness (#1282)"
setup_test_env "template-resolvability-preflight"

# Source the mechanics: template.sh (load_template) + dispatch.sh (resolve_stage_plugin)
# + runner.sh (_runner_validate_leaf_resolvability). runner.sh guards its main behind
# an execution check, so sourcing only defines functions.
# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/dispatch.sh"
# shellcheck disable=SC1090
source "$TEMPLATE_SH"
# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/runner.sh"

# ─── SPEC-4a baseline: snapshot template.sh BEFORE any load, so a mutation during
# the harness below would be caught (the mechanic must never self-modify).
_tpl_sha_before="$(shasum "$TEMPLATE_SH" | awk '{print $1}')"

# ─── Fictitious-stage fixture plugins tree ───────────────────────────────────
# `frobnicate` — a fictitiously-named stage. kind: tool keeps the manifest minimal
# (agent kind would require requires.core: [redaction]). It declares provides.role
# so resolve_stage_plugin resolves it role-first (ADR-042); the fixture template's
# stage carries the same role.
FIXROOT="$TEST_TEMP_DIR/plugins"
mkdir -p "$FIXROOT/tool/frobnicate"
cat > "$FIXROOT/tool/frobnicate/manifest.yaml" <<'EOF'
id: frobnicate
name: Frobnicate Stage
kind: tool
version: 0.0.1
hooks:
  run: frobnicate_run
inputs: []
outputs:
  - id: frob_out
    path: "${artifact_dir}/frob.json"
    type: frob.json
    required: true
    primary: true
provides:
  role: frobnicator
EOF

# Fixture template whose flow uses the fictitious stage as a leaf (role-bound).
FROB_TPL="$TEST_TEMP_DIR/frob.yaml"
cat > "$FROB_TPL" <<'EOF'
id: frob
name: Frobnicate Pipeline
defaults:
  strategy: fanout

stages:
  - id: frobnicate
    gate: auto
    roles: [frobnicator]
EOF

# ─── SPEC-1: the fictitious-stage template LOADS at the template layer (no fence).
set +e
load_template "$FROB_TPL" 2>/dev/null
_rc_load=$?
set -e
assert_eq "SPEC-1: fictitious-stage template loads (rc=0)" "0" "$_rc_load"
assert_eq "SPEC-1: _TPL_STAGES contains the fictitious leaf" "frobnicate" "${_TPL_STAGES[0]:-}"

# ─── SPEC-2: the fictitious leaf RESOLVES to its plugin via resolve_stage_plugin.
# Template roles are loaded (above), so resolution is role-first.
_resolved="$(resolve_stage_plugin "frobnicate" "$FIXROOT" 2>/dev/null || true)"
assert_contains "SPEC-2: fictitious leaf resolves to its plugin dir" "$_resolved" "tool/frobnicate"

# ─── SPEC-2b: the runner resolvability preflight PASSES for the fictitious leaf.
_active=(frobnicate)
set +e
_runner_validate_leaf_resolvability _active "$FIXROOT" 2>/dev/null
_rc_pf=$?
set -e
assert_eq "SPEC-2b: resolvability preflight passes for resolvable leaf (rc=0)" "0" "$_rc_pf"

# ─── SPEC-3: the harness required ZERO stage-specific code in template.sh. Proven
# two ways: (a) template.sh is byte-identical before/after, and (b) it contains no
# `frobnicate` literal — resolution is manifest-derived, not enumerated.
_tpl_sha_after="$(shasum "$TEMPLATE_SH" | awk '{print $1}')"
assert_eq "SPEC-3a: template.sh byte-identical after onboarding a fictitious stage" "$_tpl_sha_before" "$_tpl_sha_after"
if grep -q "frobnicate" "$TEMPLATE_SH"; then
    assert_fail "SPEC-3b: template.sh names no fixture stage" "template.sh contains 'frobnicate'"
else
    assert_pass "SPEC-3b: template.sh names no fixture stage (mechanics name no stage)"
fi

# ─── SPEC-4: an UNRESOLVABLE leaf ERRORS (fail-closed) with the pinned message. ─
_active_bad=(frobnicate no_such_stage_xyz)
set +e
_pf_out="$(_runner_validate_leaf_resolvability _active_bad "$FIXROOT" 2>&1)"
_rc_bad=$?
set -e
assert_eq "SPEC-4: unresolvable leaf → preflight returns non-zero (fail-closed)" "1" "$_rc_bad"
assert_contains "SPEC-4b: error names the unresolvable id" "$_pf_out" "no_such_stage_xyz"
assert_contains "SPEC-4c: error is the pinned ADR-047 §5 resolvability message" \
    "$_pf_out" "resolves to no plugin"

# ─── SPEC-5: an EMPTY leaf set is trivially satisfied (nothing to resolve). ─────
_active_empty=()
set +e
_runner_validate_leaf_resolvability _active_empty "$FIXROOT" 2>/dev/null
_rc_empty=$?
set -e
assert_eq "SPEC-5: empty leaf set → preflight passes (rc=0)" "0" "$_rc_empty"

# ─── SPEC-6: STRANGLER AGREEMENT — new preflight rejects ⊇ old fence (MEMBERSHIP)
# The strangler claim: every template the OLD canonical fence rejects for a
# MEMBERSHIP reason (an unknown/unregistered stage id) is ALSO rejected in the new
# world (template loads leniently → runner resolvability preflight rejects the leaf
# that has no plugin). Two corpora feed this:
#   (a) the shipped corpus (fixture templates + config/templates) — all use
#       resolvable canonical stages, so the old fence accepts them (no membership
#       rejection to assert); walking them proves the mechanism is exercised on the
#       real set and never regresses.
#   (b) synthetic MEMBERSHIP-violation templates — an unknown leaf. Here the old
#       fence rejects (unknown stage id) AND the new preflight rejects (no plugin
#       resolves). This is where superset-or-equal has teeth.
# The order residual is EXCLUDED from this claim by construction (see SPEC-7) — it
# is the ADR-047 §5 accepted residual, not a strangler violation.
REAL_PLUGINS="$REPO_ROOT/plugins"
_corpus=()
for _t in "$REPO_ROOT/tests/fixtures/templates"/*.yaml "$REPO_ROOT/config/templates"/*.yaml; do
    [[ -f "$_t" ]] && _corpus+=("$_t")
done

# Synthetic membership-violation templates appended to the corpus.
_MEMBER_BAD_1="$TEST_TEMP_DIR/member-bad-1.yaml"
cat > "$_MEMBER_BAD_1" <<'EOF'
id: member-bad-1
name: Member Bad 1
defaults:
  strategy: fanout
stages:
  - id: intake
    gate: auto
    roles: [intake]
  - id: zzz_bogus_stage
    gate: auto
    roles: [zzz_bogus_role]
EOF
_MEMBER_BAD_2="$TEST_TEMP_DIR/member-bad-2.yaml"
cat > "$_MEMBER_BAD_2" <<'EOF'
id: member-bad-2
name: Member Bad 2
defaults:
  strategy: fanout
stages:
  - id: qqq_not_a_stage
    gate: auto
    roles: [qqq_not_a_role]
EOF
_corpus+=("$_MEMBER_BAD_1" "$_MEMBER_BAD_2")

_strangler_ok=1
_checked=0
for _t in "${_corpus[@]}"; do
    # OLD verdict: does the canonical fence reject this template at load?
    set +e
    ZBUILD_LEGACY_STAGE_VALIDATION=1 load_template "$_t" >/dev/null 2>&1
    _old_rc=$?
    set -e
    [[ $_old_rc -eq 0 ]] && continue   # old fence accepted → nothing to assert

    # Distinguish MEMBERSHIP rejection from ORDER rejection: reload under the
    # fence and inspect the message. Only membership rejections are in the
    # strangler claim (order is the accepted residual, SPEC-7).
    set +e
    _old_err="$(ZBUILD_LEGACY_STAGE_VALIDATION=1 load_template "$_t" 2>&1)"
    set -e
    [[ "$_old_err" == *"unknown stage id"* ]] || continue   # order-only → residual, skip

    _checked=$((_checked + 1))
    # NEW verdict: template load (fence off) THEN resolvability preflight over the
    # resolved leaves against the real plugins tree. A rejection in EITHER phase
    # counts as a new-world rejection.
    set +e
    ZBUILD_LEGACY_STAGE_VALIDATION='' load_template "$_t" >/dev/null 2>&1
    _new_load_rc=$?
    set -e
    _new_reject=0
    if [[ $_new_load_rc -ne 0 ]]; then
        _new_reject=1
    else
        # shellcheck disable=SC2034  # passed BY NAME to the resolvability helper
        local_leaves=("${_TPL_STAGES[@]+"${_TPL_STAGES[@]}"}")
        set +e
        _runner_validate_leaf_resolvability local_leaves "$REAL_PLUGINS" >/dev/null 2>&1
        _new_pf_rc=$?
        set -e
        [[ $_new_pf_rc -ne 0 ]] && _new_reject=1
    fi
    if [[ $_new_reject -eq 0 ]]; then
        _strangler_ok=0
        printf '  strangler: OLD fence REJECTED %s (membership) but NEW world ACCEPTED it\n' "$(basename "$_t")" >&2
    fi
done
assert_eq "SPEC-6: new preflight rejects ⊇ old fence for membership (strangler)" "1" "$_strangler_ok"
# Guard against a vacuous green: the synthetic templates MUST have exercised at
# least the 2 membership rejections we injected. If _checked is 0, the old fence
# stopped rejecting unknown ids (a real regression to catch).
if [[ $_checked -ge 2 ]]; then
    assert_pass "SPEC-6b: strangler agreement exercised on real membership rejections ($_checked, corpus=${#_corpus[@]})"
else
    assert_fail "SPEC-6b: strangler agreement was vacuous" "expected ≥2 membership rejections, got $_checked"
fi

# ─── SPEC-7: ACCEPTED RESIDUAL — order-only swap that violates no data dependency.
# The old fence rejected two independent stages in swapped canonical order. The
# new world (data-dependency DAG) does NOT — no declared dependency = no constraint.
# This is the documented, accepted residual (ADR-047 §5), NOT a strangler failure.
# We prove the direction: an order-only swap of two resolvable, dependency-free
# stages is rejected by the OLD fence but the leaves still RESOLVE in the new world.
_ORDER_RESIDUAL="$TEST_TEMP_DIR/order-residual.yaml"
cat > "$_ORDER_RESIDUAL" <<'EOF'
id: order-residual
name: Order Residual
defaults:
  strategy: fanout
stages:
  - id: pr
    gate: auto
    roles: [pr]
  - id: intake
    gate: auto
    roles: [intake]
EOF
set +e
_old_order_err="$(ZBUILD_LEGACY_STAGE_VALIDATION=1 load_template "$_ORDER_RESIDUAL" 2>&1)"
_old_order_rc=$?
set -e
assert_eq "SPEC-7a: old fence rejects the order swap (rc=1)" "1" "$_old_order_rc"
assert_contains "SPEC-7b: old rejection is an ORDER violation (not membership)" "$_old_order_err" "order"
# New world: both leaves resolve against the real plugins tree; the swap violates
# no declared data dependency, so it is NOT a resolvability failure. (Any genuine
# data dependency would be caught by the contract-validator DAG, tested separately.)
set +e
ZBUILD_LEGACY_STAGE_VALIDATION='' load_template "$_ORDER_RESIDUAL" >/dev/null 2>&1
set -e
_residual_leaves=("${_TPL_STAGES[@]+"${_TPL_STAGES[@]}"}")
set +e
_runner_validate_leaf_resolvability _residual_leaves "$REAL_PLUGINS" >/dev/null 2>&1
_residual_pf_rc=$?
set -e
assert_eq "SPEC-7c: residual — swapped resolvable leaves still resolve (accepted, rc=0)" "0" "$_residual_pf_rc"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
