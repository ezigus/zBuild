#!/usr/bin/env bash
# tests/integration/suite-under-teststage-env-test.sh
# #1270 regression guard — the template resolver's returned path is INVARIANT
# under the in-pipeline test-stage environment.
#
# Root cause of #1268 (reverted by #1270): the engine grew a global
# ZBUILD_TEMPLATES_DIR seam that redirected the SHIPPED-template read root, and
# the test stage exported it suite-wide (a fence beside ZBUILD_STATE_ROOT /
# ZBUILD_COST_LEDGER / ZBUILD_CACHE_DIR). Two pre-existing resolver tests pin the
# resolver's returned path and did NOT unset the var, so they broke whenever it
# was set — which happened INSIDE the pipeline test-stage but NEVER in bare CI.
# The class slipped through because CI never exports the test-stage fences.
#
# This guard reproduces the missing coverage: it exports the exact test-stage
# fence set (state/ledger/cache pointed at throwaway temp dirs) PLUS a bogus
# ZBUILD_TEMPLATES_DIR, and asserts:
#   [SPEC-1] resolve_template_file returns the resolver-root shipped path for a
#            no-override id, IGNORING ZBUILD_TEMPLATES_DIR entirely — the exact
#            invariant #1268 broke (RED at merge-base: it returned $BOGUS/<id>).
#   [SPEC-2] the same holds for the extends: base path.
#   [SPEC-3] the two path-pinning resolver tests pass under the full simulated
#            test-stage environment (belt-and-braces over the whole suite).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "resolver path invariance under the test-stage fence env (#1270)"
setup_test_env "suite-under-teststage-env"

# ─── The simulated test-stage fence set ──────────────────────────────────────
# Mirrors plugins/tool/test/plugin.sh (_test_run_inner) which re-exports these
# beside a fresh-user-shell scrub. All point at throwaway dirs under TEST_TEMP_DIR
# (reaped by the master trap).
FENCE_ROOT="$TEST_TEMP_DIR/fence"; mkdir -p "$FENCE_ROOT"
BOGUS_TPL="$TEST_TEMP_DIR/bogus-templates"; mkdir -p "$BOGUS_TPL"
# A decoy standard.yaml under the bogus dir: if the resolver ever honored
# ZBUILD_TEMPLATES_DIR again it would resolve THIS path (RED signal).
: > "$BOGUS_TPL/standard.yaml"

# ─── SPEC-1/2: engine invariant — the resolver ignores ZBUILD_TEMPLATES_DIR ──
source "$REPO_ROOT/core/pipeline/template-resolver.sh"
_TEMPLATE_RESOLVER_ROOT="$TEST_TEMP_DIR/repo"
mkdir -p "$TEST_TEMP_DIR/repo/config/templates"
# A DISTINCTIVE non-stages key (name: RealBase) proves the base was read from the
# resolver root and not the bogus ZBUILD_TEMPLATES_DIR (whose standard.yaml is
# empty — see BOGUS_TPL above).
cat > "$TEST_TEMP_DIR/repo/config/templates/standard.yaml" <<'EOF'
id: standard
name: RealBase
stages:
  - id: intake
    roles: [intake]
EOF

set +e
result="$(
    export ZBUILD_STATE_ROOT="$FENCE_ROOT/state"
    export ZBUILD_COST_LEDGER="$FENCE_ROOT/state/cost-ledger.jsonl"
    export ZBUILD_CACHE_DIR="$FENCE_ROOT/state/cache"
    export ZBUILD_TEMPLATES_DIR="$BOGUS_TPL"
    resolve_template_file "standard" "$TEST_TEMP_DIR/repo" 2>/dev/null
)"
rc=$?
set -e
assert_eq "[SPEC-1] resolver exit 0 under test-stage fences" "0" "$rc"
assert_eq "[SPEC-1] no-override id → resolver-root shipped path (ZBUILD_TEMPLATES_DIR ignored)" \
    "$TEST_TEMP_DIR/repo/config/templates/standard.yaml" "$result"

# extends: base must ALSO resolve from the resolver root, not the bogus dir.
mkdir -p "$TEST_TEMP_DIR/repo/.zbuild/templates"
cat > "$TEST_TEMP_DIR/repo/.zbuild/templates/child.yaml" <<'EOF'
extends: standard

stages:
  - id: build
    roles: [builder]
EOF
set +e
merged="$(
    export ZBUILD_STATE_ROOT="$FENCE_ROOT/state"
    export ZBUILD_COST_LEDGER="$FENCE_ROOT/state/cost-ledger.jsonl"
    export ZBUILD_CACHE_DIR="$FENCE_ROOT/state/cache"
    export ZBUILD_TEMPLATES_DIR="$BOGUS_TPL"
    resolve_template_file "child" "$TEST_TEMP_DIR/repo" 2>/dev/null
)"
rc=$?
set -e
assert_eq "[SPEC-2] extends: base resolves under fences (exit 0)" "0" "$rc"
# ADR-016 full-replace: the overlay REPLACES the base's stages, so the merged
# file carries the base's NON-stages content (name: RealBase) + the overlay
# stages (build). RealBase proves the base was read from the resolver root, NOT
# the empty bogus dir (which #1268's seam would have used → no RealBase, merge
# would differ). RED at merge-base.
if [[ -f "$merged" ]] && grep -q "RealBase" "$merged" 2>/dev/null && grep -q "build" "$merged" 2>/dev/null; then
    assert_pass "[SPEC-2] merged has resolver-root base 'name: RealBase' + overlay 'build' (bogus dir ignored)"
else
    assert_fail "[SPEC-2] merged file combined resolver-root base + overlay" \
        "merged=$merged content: $(cat "$merged" 2>/dev/null | tr '\n' '|' | head -c 200)"
fi

# ─── SPEC-3: the path-pinning resolver tests pass under the full fence env ───
# Run each as a subprocess with the test-stage fence set exported (plus a bogus
# ZBUILD_TEMPLATES_DIR). They must exit 0 — the resolver path-pinning holds
# regardless of ambient state/ledger/cache/templates env.
_run_under_fence() {
    local test_path="$1"
    # ZBUILD_TESTS_DIR satisfies the #971 re-entrancy-guard exemption for a
    # fixture-isolated nested test run (test-helpers.sh:34) — without it the
    # guard refuses the nested `bash <test>.sh` with rc=2.
    ZBUILD_TESTS_DIR="$REPO_ROOT/tests" \
    ZBUILD_STATE_ROOT="$FENCE_ROOT/state" \
    ZBUILD_COST_LEDGER="$FENCE_ROOT/state/cost-ledger.jsonl" \
    ZBUILD_CACHE_DIR="$FENCE_ROOT/state/cache" \
    ZBUILD_TEMPLATES_DIR="$BOGUS_TPL" \
        bash "$test_path" >/dev/null 2>&1
}

for t in tests/unit/template-simple-yaml-test.sh tests/integration/template-resolver-extends-test.sh; do
    set +e
    _run_under_fence "$REPO_ROOT/$t"
    t_rc=$?
    set -e
    assert_eq "[SPEC-3] $t passes under test-stage fence env" "0" "$t_rc"
done

cleanup_test_env
print_test_results
exit $((FAIL > 0))
