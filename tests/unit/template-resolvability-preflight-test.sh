#!/usr/bin/env bash
# tests/unit/template-resolvability-preflight-test.sh — EPIC #1277 / issue #1282.
#
# ADR-047 §5: the engine-owned _ZBUILD_CANONICAL_STAGES closed-vocabulary fence is
# retired (fully deleted in #1299); its membership role is the FAIL-CLOSED, manifest-
# derived resolvability preflight (_runner_validate_leaf_resolvability, core/pipeline/
# runner.sh), and its canonical-order role the upstream-input data-dependency DAG
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
#   SOLE-ENFORCEMENT (SPEC-6/6b): the preflight ACCEPTS the shipped template corpus
#     (fixtures + config/templates — every leaf resolves) and REJECTS templates with a
#     genuinely-unresolvable leaf. The preflight stands on its own — the old canonical
#     fence + ZBUILD_LEGACY_STAGE_VALIDATION baseline are deleted (#1299).
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

# ─── SPEC-6: the preflight stands on its own (#1299 — the old canonical fence +
# ZBUILD_LEGACY_STAGE_VALIDATION baseline are deleted; the strangler-agreement
# framing retires with them). The property that must hold: the manifest-derived
# preflight ACCEPTS the SHIPPED templates (config/templates — every leaf resolves to
# a real plugin) and REJECTS a template with a genuinely-unresolvable leaf. No
# comparison to a legacy verdict — the preflight is now the sole membership
# enforcement.
#
# Scope note: only config/templates (the shipped, production templates) are asserted
# to fully resolve. tests/fixtures/templates deliberately contains synthetic stages
# with no backing plugin (harness fixtures), so they are NOT a resolvability corpus.
#
# NOTE: the template layer no longer fences on membership (load succeeds for any
# id); the resolvability preflight over the resolved leaves is what has teeth.
REAL_PLUGINS="$REPO_ROOT/plugins"

# The shipped corpus: every production template must LOAD and every resolved leaf
# must resolve to a real plugin (regression guard — no shipped template names a
# missing plugin).
_corpus=()
for _t in "$REPO_ROOT/config/templates"/*.yaml; do
    [[ -f "$_t" ]] && _corpus+=("$_t")
done
_corpus_ok=1
for _t in "${_corpus[@]}"; do
    set +e
    load_template "$_t" >/dev/null 2>&1
    _load_rc=$?
    set -e
    if [[ $_load_rc -ne 0 ]]; then
        _corpus_ok=0
        printf '  corpus REGRESSION: %s failed to load\n' "$(basename "$_t")" >&2
        continue
    fi
    # shellcheck disable=SC2034  # passed BY NAME to the resolvability helper
    local_leaves=("${_TPL_STAGES[@]+"${_TPL_STAGES[@]}"}")
    set +e
    _runner_validate_leaf_resolvability local_leaves "$REAL_PLUGINS" >/dev/null 2>&1
    _pf_rc=$?
    set -e
    if [[ $_pf_rc -ne 0 ]]; then
        _corpus_ok=0
        printf '  corpus REGRESSION: %s has an unresolvable leaf\n' "$(basename "$_t")" >&2
    fi
done
assert_eq "SPEC-6: shipped corpus loads and every leaf resolves (preflight accepts, corpus=${#_corpus[@]})" "1" "$_corpus_ok"

# Synthetic membership-violation templates: a genuinely-unresolvable leaf MUST be
# rejected by the preflight (the teeth of the sole membership enforcement).
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
_rejected=0
for _t in "$_MEMBER_BAD_1" "$_MEMBER_BAD_2"; do
    set +e
    load_template "$_t" >/dev/null 2>&1   # template layer no longer fences on id
    set -e
    # shellcheck disable=SC2034  # passed BY NAME to the resolvability helper
    bad_leaves=("${_TPL_STAGES[@]+"${_TPL_STAGES[@]}"}")
    set +e
    _runner_validate_leaf_resolvability bad_leaves "$REAL_PLUGINS" >/dev/null 2>&1
    _bad_pf_rc=$?
    set -e
    [[ $_bad_pf_rc -ne 0 ]] && _rejected=$((_rejected + 1))
done
# Guard against a vacuous green: BOTH synthetic unresolvable-leaf templates must be
# rejected. If not, the resolvability path stopped catching truly-missing plugins.
assert_eq "SPEC-6b: preflight rejects both genuinely-unresolvable-leaf templates" "2" "$_rejected"

# ─── SPEC-7: ACCEPTED RESIDUAL — an order-only swap of two resolvable, dependency-
# free stages is NOT a resolvability failure. The new world's order enforcement is
# the data-dependency DAG (contract-validator, tested separately): no declared
# dependency = no constraint. This is the documented, accepted ADR-047 §5 residual.
# We prove the direction directly (no legacy-fence baseline): swapped resolvable
# leaves still resolve.
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
load_template "$_ORDER_RESIDUAL" >/dev/null 2>&1
set -e
_residual_leaves=("${_TPL_STAGES[@]+"${_TPL_STAGES[@]}"}")
set +e
_runner_validate_leaf_resolvability _residual_leaves "$REAL_PLUGINS" >/dev/null 2>&1
_residual_pf_rc=$?
set -e
assert_eq "SPEC-7: residual — swapped resolvable leaves still resolve (accepted, rc=0)" "0" "$_residual_pf_rc"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
