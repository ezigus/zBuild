#!/usr/bin/env bash
# Tests: core/pipeline/dispatch.sh resolve_stage_plugin (ADR-042, Change A)
# Uniform stage→plugin resolution across leaf/cycle/parallel dispatch paths.
#
# Invariant under test: a stage resolves to its plugin by the SAME role-then-id
# rule everywhere. A stage's flow-name need NOT equal its plugin `id` — role
# binding (ADR-001) wins, with id-match as the backward-compat fallback.
#
# Baseline (pre-change) this FAILS: cycle_dispatch_stage / parallel_dispatch_stage
# used _find_plugin_for_stage (id-only), which returns EMPTY for role-bound stages
# whose plugin id ≠ stage name (lint→lint-gate, coverage→coverage-gate,
# mutation→mutation-gate, every lens-*→review-lens) — they were stamped
# verdict=error and aborted the cycle/group.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/pipeline/dispatch.sh — resolve_stage_plugin role-then-id parity (ADR-042)"
setup_test_env "stage-resolution-parity"

_test_cleanup_hook() { cleanup_test_env; }

# ─── Source under test ───────────────────────────────────────────────────────
# template.sh provides template_stage_roles + load_template (sets _TPL_STAGE_ROLES_*);
# resolver.sh provides resolve_plugin_for_role; dispatch.sh provides
# resolve_stage_plugin + _find_plugin_for_stage (and sources the registry).
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
# shellcheck source=../../core/pipeline/resolver.sh
source "$REPO_ROOT/core/pipeline/resolver.sh"
# shellcheck source=../../core/pipeline/dispatch.sh
source "$REPO_ROOT/core/pipeline/dispatch.sh"

PLUGINS_ROOT="$REPO_ROOT/plugins"
SIMPLE_TPL="$REPO_ROOT/config/templates/simple.yaml"

# Load the shipped template so template_stage_roles has the _TPL_STAGE_ROLES_*
# data the engine populates at runtime (exactly what cycle/parallel dispatch see).
set +e
load_template "$SIMPLE_TPL"
_load_rc=$?
set -e
assert_eq "[SETUP] simple.yaml loads without error" "0" "$_load_rc"

# Helper: basename of resolve_stage_plugin output (empty on miss).
_resolve() { basename "$(resolve_stage_plugin "$1" "$PLUGINS_ROOT" 2>/dev/null || true)" 2>/dev/null || true; }
_resolve_raw() { resolve_stage_plugin "$1" "$PLUGINS_ROOT" 2>/dev/null || true; }
_idmatch() { _find_plugin_for_stage "$1" "$PLUGINS_ROOT" 2>/dev/null || true; }

# ─── SPEC-1: baseline symptom — id-only resolution returns EMPTY for the 8 ───
# previously-broken stages. This is the exact failure cycle/parallel hit.
assert_eq "[SPEC-1] id-only (_find_plugin_for_stage) returns EMPTY for lint" "" "$(_idmatch lint)"
assert_eq "[SPEC-1] id-only returns EMPTY for coverage" "" "$(_idmatch coverage)"
assert_eq "[SPEC-1] id-only returns EMPTY for mutation" "" "$(_idmatch mutation)"
assert_eq "[SPEC-1] id-only returns EMPTY for lens-security" "" "$(_idmatch lens-security)"

# ─── SPEC-2: the fix — resolve_stage_plugin (role-then-id) resolves all 8 ────
# role-bound stages whose plugin id ≠ stage name. cycle_dispatch_stage and
# parallel_dispatch_stage BOTH call this helper, so this proves both paths.
assert_eq "[SPEC-2] cycle member lint → lint-gate"        "lint-gate"     "$(_resolve lint)"
assert_eq "[SPEC-2] cycle member coverage → coverage-gate" "coverage-gate" "$(_resolve coverage)"
assert_eq "[SPEC-2] cycle member mutation → mutation-gate" "mutation-gate" "$(_resolve mutation)"
assert_eq "[SPEC-2] parallel member lens-security → review-lens"    "review-lens" "$(_resolve lens-security)"
assert_eq "[SPEC-2] parallel member lens-performance → review-lens" "review-lens" "$(_resolve lens-performance)"
assert_eq "[SPEC-2] parallel member lens-red-team → review-lens"    "review-lens" "$(_resolve lens-red-team)"
assert_eq "[SPEC-2] parallel member lens-correctness → review-lens" "review-lens" "$(_resolve lens-correctness)"
assert_eq "[SPEC-2] parallel member lens-scope → review-lens"       "review-lens" "$(_resolve lens-scope)"

# Returned path is a real plugin directory with a manifest.
assert_file_exists "[SPEC-2] resolved lint plugin dir has a manifest" "$(_resolve_raw lint)/manifest.yaml"

# ─── SPEC-3: regression invariant — current cycle members resolve to the SAME ─
# plugin as before (id-match and role-match are identical for them). build has
# NO provides.role (template role 'builder' has no plugin) → falls through to
# id-match, exactly as the old id-only path did.
assert_eq "[SPEC-3] test → test (role tester)"               "test"            "$(_resolve test)"
assert_eq "[SPEC-3] shape-floor → shape-floor"               "shape-floor"     "$(_resolve shape-floor)"
assert_eq "[SPEC-3] acceptance-gate → acceptance-gate"       "acceptance-gate" "$(_resolve acceptance-gate)"
assert_eq "[SPEC-3] secret-scan → secret-scan"               "secret-scan"     "$(_resolve secret-scan)"
assert_eq "[SPEC-3] gate-aggregator → gate-aggregator"       "gate-aggregator" "$(_resolve gate-aggregator)"
assert_eq "[SPEC-3] build → build (role-miss falls to id-match)" "build"       "$(_resolve build)"

# ─── SPEC-4: unknown stage with no role and no id resolves to nothing ────────
assert_eq "[SPEC-4] unknown stage resolves to EMPTY (return 1)" "" "$(_resolve nonexistent-stage-xyz)"

# ─── Results ─────────────────────────────────────────────────────────────────
print_test_results
