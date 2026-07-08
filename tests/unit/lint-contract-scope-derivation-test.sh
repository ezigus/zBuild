#!/usr/bin/env bash
# tests/unit/lint-contract-scope-derivation-test.sh — EPIC #1277 / issue #1279.
#
# lint-contract's check-scope is DERIVED from the manifest data-dependency graph
# (ADR-047 §5), not a hardcoded roster. This test guards two properties:
#
#   STRANGLER (SPEC-1): the derived scope is a SUPERSET-OR-EQUAL of the old curated
#     list (_LC_STAGE_IDS_TO_CHECK) — scope can never silently NARROW below what the
#     hand-maintained list validated.
#
#   FICTITIOUS-STAGE HARNESS (SPEC-2/3/4): a brand-new, fictitiously-named stage that
#     participates in the data contract is picked up by lint-contract with ZERO edits
#     to the mechanic (scripts/lib/lint-contract.sh) — proving the scope is
#     stage-agnostic. A backend service (no stage io) stays out of scope for free.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LINT="$REPO_ROOT/scripts/lib/lint-contract.sh"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/manifest-graph.sh
source "$REPO_ROOT/scripts/lib/manifest-graph.sh"

print_test_header "lint-contract scope derivation + fictitious-stage harness (#1279)"
setup_test_env "lint-contract-scope-derivation"

# ─── SPEC-1: strangler — derived scope ⊇ curated list ────────────────────────
# Recompute data-graph participation over the REAL plugins tree the same way
# lint-contract does, then assert every curated id that has a manifest is a node.
# The curated list is the independent ground truth (a hand-maintained subset);
# the derivation must not drop any of it.
declare -A _HAS_INPUT=() _PROD_REF=() _MANIFEST_ID=() _ROLE_ID=()
while IFS= read -r -d '' m; do
    id="$(manifest_graph_get_stage_id "$m")"; [[ -z "$id" ]] && continue
    _MANIFEST_ID["$id"]=1
    _role="$(awk '/^provides:/{p=1;next} p&&/^[A-Za-z_]/{p=0} p&&/^[[:space:]]+role:/{sub(/^[[:space:]]+role:[[:space:]]*/,"");gsub(/["'"'"']/,"");print;exit}' "$m")"
    [[ -n "$_role" ]] && _ROLE_ID["$_role"]="$id"
    while IFS= read -r rec; do
        [[ -z "$rec" ]] && continue
        IFS='|' read -r _iid _it _isrc _ir _ip <<< "$rec"
        if [[ "$_isrc" == stage:* ]]; then
            _HAS_INPUT["$id"]=1
            [[ -n "$_role" ]] && _HAS_INPUT["role:$_role"]=1
            _PROD_REF["${_isrc#stage:}"]=1
        fi
    done < <(manifest_graph_get_inputs "$m")
done < <(find "$REPO_ROOT/plugins" -name manifest.yaml -not -path '*/tests/*' -print0 2>/dev/null)

# in-scope iff data-graph node (mirrors _lc_id_in_scope). Resolve curated ids
# that are role-bound stage names (e.g. acceptance-gate) via the role→id map.
_derived_in_scope() {
    local s="$1"
    [[ -n "${_HAS_INPUT[$s]:-}" || -n "${_PROD_REF[$s]:-}" ]] && return 0
    # role-bound: acceptance-gate stage is served by spec-acceptance (role acceptance_gate)
    local rid="${_ROLE_ID[${s//-/_}]:-}"
    [[ -n "$rid" && ( -n "${_HAS_INPUT[$rid]:-}" || -n "${_PROD_REF[$rid]:-}" ) ]] && return 0
    return 1
}

_CURATED=(intake plan design build test test_assessment acceptance-gate cq-preflight cq-audit-plan cq-cycle cq-backtrack review pr deploy validate monitor security-lens)
_strangler_ok=1
for cur in "${_CURATED[@]}"; do
    # deploy/validate/monitor have no manifest yet — skip (nothing to validate).
    [[ -z "${_MANIFEST_ID[$cur]:-}" && -z "${_ROLE_ID[${cur//-/_}]:-}" ]] && continue
    if ! _derived_in_scope "$cur"; then
        _strangler_ok=0
        printf '  strangler: curated id NOT in derived scope: %s\n' "$cur" >&2
    fi
done
assert_eq "SPEC-1: derived scope ⊇ curated _LC_STAGE_IDS_TO_CHECK (strangler)" "1" "$_strangler_ok"

# ─── Fictitious-stage fixture plugins tree ───────────────────────────────────
FIXROOT="$TEST_TEMP_DIR/plugins"
mkdir -p "$FIXROOT/agent/producer" "$FIXROOT/agent/frobnicate" "$FIXROOT/tool/backend-svc"

cat > "$FIXROOT/agent/producer/manifest.yaml" <<'EOF'
id: producer
name: Producer
kind: agent
version: 0.0.1
inputs: []
outputs:
  - id: real_out
    path: "${artifact_dir}/producer.json"
    type: producer.json
    required: true
    primary: true
EOF

# frobnicate — a fictitiously-named stage that CONSUMES a stage artifact (data-graph
# node) and declares a REQUIRED input whose output id the producer does NOT provide.
# If the derivation onboards it, lint MUST flag the missing output.
cat > "$FIXROOT/agent/frobnicate/manifest.yaml" <<'EOF'
id: frobnicate
name: Frobnicate
kind: agent
version: 0.0.1
inputs:
  - id: nonexistent_out
    source: stage:producer
    required: true
outputs:
  - id: frob_out
    path: "${artifact_dir}/frob.json"
    type: frob.json
    required: true
    primary: true
EOF

# backend-svc — a service with NO stage io (not a data-graph node). It has a
# deliberately MISSING inputs: block; if it were in scope, lint would flag it.
cat > "$FIXROOT/tool/backend-svc/manifest.yaml" <<'EOF'
id: backend-svc
name: Backend service
kind: tool
version: 0.0.1
outputs:
  - id: svc_out
    path: "${artifact_dir}/svc.json"
    type: svc.json
    required: true
    primary: true
EOF

set +e
_out="$(ZBUILD_PLUGINS_ROOT="$FIXROOT" bash "$LINT" 2>&1)"; _rc=$?
set -e

# SPEC-2: the fictitiously-named stage entered scope via derivation → its contract
# violation is caught (rc!=0, message names it).
assert_eq "SPEC-2: fictitious contract-participant is linted (rc=1)" "1" "$_rc"
assert_contains "SPEC-2: violation names the fictitious stage 'frobnicate'" "$_out" "frobnicate"
assert_contains "SPEC-2: violation is the missing producer output" "$_out" "nonexistent_out"

# SPEC-3: the backend service (no stage io) is NOT in scope — its missing inputs:
# block is NOT flagged (would-be complaint absent).
if printf '%s' "$_out" | grep -q "backend-svc"; then
    assert_fail "SPEC-3: backend-svc (no stage io) stays OUT of scope" "lint flagged backend-svc: $_out"
else
    assert_pass "SPEC-3: backend-svc (no stage io) stays OUT of scope"
fi

# SPEC-4: onboarding the fictitious stage required ZERO stage-specific code in the
# mechanic. Proven two ways: (a) the mechanic is byte-identical before/after the lint
# run (it never self-modifies / hardcodes the new stage), and (b) the mechanic source
# contains no fixture stage-name literal — the scope is derived, not enumerated.
_sha_before="$(shasum "$LINT" | awk '{print $1}')"
ZBUILD_PLUGINS_ROOT="$FIXROOT" bash "$LINT" >/dev/null 2>&1 || true
_sha_after="$(shasum "$LINT" | awk '{print $1}')"
assert_eq "SPEC-4a: lint-contract.sh is byte-identical after onboarding a new stage" "$_sha_before" "$_sha_after"
if grep -q "frobnicate" "$LINT"; then
    assert_fail "SPEC-4b: mechanic names no fixture stage" "lint-contract.sh contains 'frobnicate'"
else
    assert_pass "SPEC-4b: mechanic names no fixture stage (scope is derived, not enumerated)"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
