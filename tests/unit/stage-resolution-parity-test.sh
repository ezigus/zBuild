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
# whose plugin id ≠ stage name (every lens-*→review-lens) — they were stamped
# verdict=error and aborted the cycle/group.
#
# (#1129 Change C, ADR-012/013: simple.yaml dropped the lint/coverage/mutation
# read-out gates as cycle members — they were redundant with the test suite. They
# were once the canonical id≠name examples here; the surviving role-bound stages
# whose plugin id ≠ stage name are now the lens-* parallel group, which exercises
# the SAME resolve_stage_plugin code path cycle dispatch uses.)
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

# Helper: basename of resolve_stage_plugin output (empty on miss). Guard the
# empty case explicitly — `basename ""` prints "." on some implementations.
_resolve() { local _p; _p="$(resolve_stage_plugin "$1" "$PLUGINS_ROOT" 2>/dev/null || true)"; [[ -n "$_p" ]] && basename "$_p" || true; }
_resolve_raw() { resolve_stage_plugin "$1" "$PLUGINS_ROOT" 2>/dev/null || true; }
_idmatch() { _find_plugin_for_stage "$1" "$PLUGINS_ROOT" 2>/dev/null || true; }

# ─── SPEC-1: baseline symptom — id-only resolution returns EMPTY for the ─────
# role-bound stages whose plugin id ≠ stage name. This is the exact failure
# cycle/parallel hit (lens-*→review-lens; id-match finds no plugin id "lens-*").
assert_eq "[SPEC-1] id-only (_find_plugin_for_stage) returns EMPTY for lens-security" "" "$(_idmatch lens-security)"
assert_eq "[SPEC-1] id-only returns EMPTY for lens-correctness" "" "$(_idmatch lens-correctness)"

# ─── SPEC-2: the fix — resolve_stage_plugin (role-then-id) resolves the ──────
# role-bound stages whose plugin id ≠ stage name. cycle_dispatch_stage and
# parallel_dispatch_stage BOTH call this helper, so this proves both paths.
assert_eq "[SPEC-2] parallel member lens-security → review-lens"    "review-lens" "$(_resolve lens-security)"
assert_eq "[SPEC-2] parallel member lens-performance → review-lens" "review-lens" "$(_resolve lens-performance)"
assert_eq "[SPEC-2] parallel member lens-red-team → review-lens"    "review-lens" "$(_resolve lens-red-team)"
assert_eq "[SPEC-2] parallel member lens-correctness → review-lens" "review-lens" "$(_resolve lens-correctness)"
assert_eq "[SPEC-2] parallel member lens-scope → review-lens"       "review-lens" "$(_resolve lens-scope)"

# Returned path is a real plugin directory with a manifest.
assert_file_exists "[SPEC-2] resolved lens plugin dir has a manifest" "$(_resolve_raw lens-security)/manifest.yaml"

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
# Assert BOTH the empty stdout and the non-zero return code (rc=1 on a miss),
# so a regression that returns rc=0 with empty output is caught.
assert_eq "[SPEC-4] unknown stage resolves to EMPTY stdout" "" "$(_resolve nonexistent-stage-xyz)"
set +e
resolve_stage_plugin nonexistent-stage-xyz "$PLUGINS_ROOT" >/dev/null 2>&1
_miss_rc=$?
set -e
assert_eq "[SPEC-4] unknown stage returns rc=1 (miss)" "1" "$_miss_rc"

# ─── Results ─────────────────────────────────────────────────────────────────
print_test_results
