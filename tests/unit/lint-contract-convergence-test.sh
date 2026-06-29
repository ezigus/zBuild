#!/usr/bin/env bash
# tests/unit/lint-contract-convergence-test.sh — ADR-040 §5 (#1137) convergence-
# path invariant guard in scripts/lib/lint-contract.sh.
#
# "No kind:agent / LLM stage may appear in the must-pass set or in any exit_when
# predicate." Scoped to templates that adopt the decomposed gate taxonomy (a
# `type: parallel` group with a blocking aggregate). The guard must FAIL a
# template that puts an LLM stage on a merge-blocking path and PASS a clean one.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "lint-contract — ADR-040 §5 convergence-path invariant (#1137)"
setup_test_env "lint-contract-convergence"

PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
TPL_ROOT="$TEST_TEMP_DIR/templates"
mkdir -p "$PLUGINS_ROOT/tool/gate_suite" "$PLUGINS_ROOT/tool/gate_lint" \
    "$PLUGINS_ROOT/tool/gate_unmarked" "$PLUGINS_ROOT/agent/lens_security" "$TPL_ROOT"

# Minimal lint-clean manifest: id + kind + convergence marker + provides.role +
# one primary output. Fixture ids are NOT on lint-contract's ADR-020 stage-scope
# allowlist, so the inter-stage input contract is not enforced on them — only
# kind/role/convergence indexing. ADR-040 §5: the convergence-path guard keys on
# the `convergence:` MARKER, not `kind:` (so a kind:agent gate is legal when
# declared convergence:gate, and a convergence:advisory stage is flagged on the
# must-pass path).
write_manifest() {
    local dir="$1" id="$2" kind="$3" role="$4" convergence="${5:-}"
    {
        printf 'id: %s\n' "$id"
        printf 'name: %s\n' "$id"
        printf 'kind: %s\n' "$kind"
        [[ -n "$convergence" ]] && printf 'convergence: %s\n' "$convergence"
        cat <<EOF
version: 0.1.0
hooks:
  run: r
provides:
  role: $role
inputs: []
outputs:
  - id: ${id}_result
    type: file
    path: \${artifact_dir}/${id}.json
    required: true
    primary: true
EOF
    } > "$dir/manifest.yaml"
}
write_manifest "$PLUGINS_ROOT/tool/gate_suite"    gate_suite    tool  gate_suite    gate
write_manifest "$PLUGINS_ROOT/tool/gate_lint"     gate_lint     tool  gate_lint     gate
write_manifest "$PLUGINS_ROOT/agent/lens_security" lens_security agent lens_security advisory
# kind:tool stage with NO convergence marker — fail-closed: must still be illegal
# on a must-pass path (a forgotten marker must not silently de-scope a gate).
write_manifest "$PLUGINS_ROOT/tool/gate_unmarked" gate_unmarked tool  gate_unmarked

run_lint() {
    local rc=0
    LINT_OUT="$(ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" ZBUILD_TEMPLATES_ROOTS="$TPL_ROOT" \
        bash "$REPO_ROOT/scripts/lib/lint-contract.sh" 2>&1)" || rc=$?
    return $rc
}

# ── TC-1: clean decomposed template — gates all_pass (tool members), exit_when
#          targets the gate group, lenses are advisory → PASSES ───────────────
cat > "$TPL_ROOT/clean.yaml" <<'EOF'
id: clean
flow:
  - gates
  - lenses
gates:
  type: parallel
  flow:
    - gate_suite
    - gate_lint
  aggregate: all_pass
  exit_when:
    stage: gates
    field: verdict
    op: eq
    value: pass
lenses:
  type: parallel
  flow:
    - lens_security
  aggregate: advisory
gate_suite:
  roles: [gate_suite]
gate_lint:
  roles: [gate_lint]
lens_security:
  roles: [lens_security]
EOF
rc=0; run_lint || rc=$?
assert_eq "TC-1: clean decomposed template passes (rc=0)" "0" "$rc"
rm -f "$TPL_ROOT/clean.yaml"

# ── TC-2: LLM stage in the must-pass set (all_pass group member) → FAILS ──────
cat > "$TPL_ROOT/dirty_mustpass.yaml" <<'EOF'
id: dirty_mustpass
flow:
  - gates
gates:
  type: parallel
  flow:
    - gate_suite
    - lens_security
  aggregate: all_pass
gate_suite:
  roles: [gate_suite]
lens_security:
  roles: [lens_security]
EOF
rc=0; run_lint || rc=$?
assert_eq "TC-2: agent in must-pass set detected (rc=1)" "1" "$rc"
assert_contains "TC-2: diagnostic names the LLM member" "$LINT_OUT" "lens_security"
assert_contains "TC-2: diagnostic cites ADR-040" "$LINT_OUT" "ADR-040"
rm -f "$TPL_ROOT/dirty_mustpass.yaml"

# ── TC-3: LLM stage in an exit_when convergence predicate → FAILS ────────────
# A blocking parallel group (gates) activates strict mode; a sibling cycle then
# illegally drives convergence off an LLM leaf via exit_when.
cat > "$TPL_ROOT/dirty_exitwhen.yaml" <<'EOF'
id: dirty_exitwhen
flow:
  - gates
  - converge
gates:
  type: parallel
  flow:
    - gate_suite
  aggregate: all_pass
converge:
  type: cycle
  flow:
    - gate_lint
    - lens_security
  exit_when:
    stage: lens_security
    field: verdict
    op: eq
    value: pass
gate_suite:
  roles: [gate_suite]
gate_lint:
  roles: [gate_lint]
lens_security:
  roles: [lens_security]
EOF
rc=0; run_lint || rc=$?
assert_eq "TC-3: agent in exit_when detected (rc=1)" "1" "$rc"
assert_contains "TC-3: diagnostic mentions exit_when" "$LINT_OUT" "exit_when"
assert_contains "TC-3: diagnostic names the LLM stage" "$LINT_OUT" "lens_security"
rm -f "$TPL_ROOT/dirty_exitwhen.yaml"

# ── TC-4: legacy template (NO parallel group) is NOT retro-checked → PASSES ───
# An exit_when on an agent leaf in a plain cycle is the pre-ADR-040 model
# (standard.yaml's review/impact cycles). Without a blocking parallel group the
# guard stays inert, so the production template is never broken.
cat > "$TPL_ROOT/legacy.yaml" <<'EOF'
id: legacy
flow:
  - review_cycle
review_cycle:
  type: cycle
  flow:
    - gate_lint
    - lens_security
  exit_when:
    stage: lens_security
    field: verdict
    op: eq
    value: approve
gate_lint:
  roles: [gate_lint]
lens_security:
  roles: [lens_security]
EOF
rc=0; run_lint || rc=$?
assert_eq "TC-4: legacy (no parallel group) not retro-checked (rc=0)" "0" "$rc"
rm -f "$TPL_ROOT/legacy.yaml"

# ── TC-6: unmarked kind:tool member on a must-pass set → FAILS (fail-closed) ──
# A mechanical-looking tool stage that FORGOT its `convergence: gate` marker must
# not slip onto the must-pass path: the roster-driven gate-aggregator keys on the
# marker, so an unmarked member would be silently de-scoped from convergence.
cat > "$TPL_ROOT/dirty_unmarked.yaml" <<'EOF'
id: dirty_unmarked
flow:
  - gates
gates:
  type: parallel
  flow:
    - gate_suite
    - gate_unmarked
  aggregate: all_pass
gate_suite:
  roles: [gate_suite]
gate_unmarked:
  roles: [gate_unmarked]
EOF
rc=0; run_lint || rc=$?
assert_eq "TC-6: unmarked tool in must-pass set detected (rc=1)" "1" "$rc"
assert_contains "TC-6: diagnostic names the unmarked member" "$LINT_OUT" "gate_unmarked"
assert_contains "TC-6: diagnostic cites ADR-040" "$LINT_OUT" "ADR-040"
rm -f "$TPL_ROOT/dirty_unmarked.yaml"

# ── TC-5: real-repo templates still pass the guard (no false positives) ──────
rc=0
ZBUILD_PLUGINS_ROOT="$REPO_ROOT/plugins" bash "$REPO_ROOT/scripts/lib/lint-contract.sh" \
    >/dev/null 2>&1 || rc=$?
assert_eq "TC-5: real repo templates pass (rc=0)" "0" "$rc"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
