#!/usr/bin/env bash
# tests/unit/runner-post-stage-capability-test.sh — EPIC #1277 / issue #1283.
#
# The runner names no stage (ADR-047 §6). Two former couplings are removed:
#   1. the post-intake scope-override merge, now keyed on
#      `capabilities.merges_scope_override` (any stage), not the literal "intake";
#   2. the missing/empty-template fallback, formerly a hardcoded
#      `active_stages=(intake security-lens output)` roster, now FAIL-CLOSED.
#
# This guards the invariants structurally (no stage-name literal in the mechanic),
# proves the capability read is generic (intake AND a fictitious stage), and
# exercises the fail-closed path.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER="$REPO_ROOT/core/pipeline/runner.sh"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "runner post-stage hook + derived fallback — stage-agnostic (#1283)"
setup_test_env "runner-post-stage-capability"

# ─── SPEC-1: the mechanic names no stage for these behaviors ─────────────────
if grep -qE '"\$stage"[[:space:]]*==[[:space:]]*"intake"' "$RUNNER"; then
    assert_fail "SPEC-1a: runner.sh does not key the scope-override on the literal 'intake'" "found == \"intake\""
else
    assert_pass "SPEC-1a: scope-override is capability-keyed, not name-keyed"
fi
if grep -qE 'active_stages=\(intake' "$RUNNER"; then
    assert_fail "SPEC-1b: runner.sh has no hardcoded built-in stage roster" "found active_stages=(intake ...)"
else
    assert_pass "SPEC-1b: no hardcoded built-in stage roster (fail-closed fallback)"
fi

# ─── SPEC-2: the capability read is generic (intake + a fictitious stage) ────
source "$REPO_ROOT/scripts/lib/manifest-graph.sh"
_manifest_graph_ensure_yaml_get 2>/dev/null || true

_intake_cap="$(yaml_get "$REPO_ROOT/plugins/agent/intake/manifest.yaml" "capabilities.merges_scope_override" 2>/dev/null)"
assert_eq "SPEC-2a: intake declares capabilities.merges_scope_override=true" "true" "$_intake_cap"

# A fictitiously-named stage declaring the same capability reads identically —
# the runner would merge its scope override with ZERO code change.
FROB="$TEST_TEMP_DIR/plugins/tool/frobnicate"
mkdir -p "$FROB"
cat > "$FROB/manifest.yaml" <<'EOF'
id: frobnicate
name: Frobnicate
kind: tool
version: 0.0.1
inputs: []
outputs:
  - id: frob_out
    path: ${artifact_dir}/frob.json
    type: json
    required: true
    primary: true
capabilities:
  merges_scope_override: true
EOF
_frob_cap="$(yaml_get "$FROB/manifest.yaml" "capabilities.merges_scope_override" 2>/dev/null)"
assert_eq "SPEC-2b: a fictitious stage declaring the capability reads true (generic)" "true" "$_frob_cap"

# A stage that does NOT declare it reads empty → the merge would not fire.
NOCAP="$TEST_TEMP_DIR/plugins/tool/nocap"
mkdir -p "$NOCAP"
cat > "$NOCAP/manifest.yaml" <<'EOF'
id: nocap
name: No Cap
kind: tool
version: 0.0.1
inputs: []
outputs:
  - id: nocap_out
    path: ${artifact_dir}/nocap.json
    type: json
    required: true
    primary: true
EOF
_nocap_cap="$(yaml_get "$NOCAP/manifest.yaml" "capabilities.merges_scope_override" 2>/dev/null)"
assert_eq "SPEC-2c: a stage without the capability reads empty (merge skipped)" "" "$_nocap_cap"

# ─── SPEC-3: missing template fails closed (no bogus built-in roster) ─────────
set +e
out="$(bash "$RUNNER" --issue 83 --dry-run --template no_such_template_xyz 2>&1)"; _rc=$?
set -e
assert_eq "SPEC-3: missing template → fail-closed (rc=2)" "2" "$_rc"
assert_contains "SPEC-3: error names the missing template / not found" "$out" "not found"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
