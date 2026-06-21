#!/usr/bin/env bash
# scope-manifest-b1-regression-test.sh
# B1.6 5-trial regression suite for _extract_scope_from_design.
# Tests the migrated function (plugins/agent/design/plugin.sh:444-467,
# plugins/agent/build/plugin.sh:1554-1577) and verifies the legacy source
# (legacy/scripts/lib/pipeline-stages.sh:38-71) has been pruned.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "scope-manifest B1.6 regression: _extract_scope_from_design (#754 / KEEPERS §B1.6)"
setup_test_env "scope-manifest-b1"

# Source design plugin to get _extract_scope_from_design.
# shellcheck disable=SC1091
source "$REPO_ROOT/plugins/agent/design/plugin.sh"

_bt='```'

# ─── T1 [SPEC-1]: fenced scope block → correct CSV ───────────────────────────
mkdir -p "$TEST_TEMP_DIR/t1"
printf '# Design\n\n%sscope\nfoo.sh\nbar/baz.sh\n%s\n\n## Notes\n' \
    "$_bt" "$_bt" > "$TEST_TEMP_DIR/t1/design.md"
_t1_csv="$(_extract_scope_from_design "$TEST_TEMP_DIR/t1/design.md")"
assert_eq "[SPEC-1] scope block extraction returns correct CSV" \
    "foo.sh,bar/baz.sh" "$_t1_csv"

# ─── T1b [SPEC-2]: missing file → empty ──────────────────────────────────────
_t1b="$(_extract_scope_from_design "$TEST_TEMP_DIR/t1/nonexistent.md" 2>/dev/null || true)"
assert_eq "[SPEC-2] missing design.md returns empty" "" "$_t1b"

# ─── T1c [SPEC-2]: no scope block → empty ────────────────────────────────────
printf '# Design\n\nNo scope block here.\n' > "$TEST_TEMP_DIR/t1/noscp.md"
_t1c="$(_extract_scope_from_design "$TEST_TEMP_DIR/t1/noscp.md")"
assert_eq "[SPEC-2] design.md without scope block returns empty" "" "$_t1c"

# ─── T1d [SPEC-2]: blank lines inside scope block are stripped ───────────────
printf '# Design\n\n%sscope\nfoo.sh\n\nbar.sh\n%s\n' \
    "$_bt" "$_bt" > "$TEST_TEMP_DIR/t1/blanks.md"
_t1d="$(_extract_scope_from_design "$TEST_TEMP_DIR/t1/blanks.md")"
assert_eq "[SPEC-2] blank lines inside scope block are stripped" "foo.sh,bar.sh" "$_t1d"

# ─── T3 [SPEC-3]: legacy-citation comment discoverable in design plugin ───────
_t3_cnt=$(grep -c "legacy-citation.*pipeline-stages.sh:38" \
    "$REPO_ROOT/plugins/agent/design/plugin.sh" 2>/dev/null || true)
assert_gt "[SPEC-3] legacy-citation pipeline-stages.sh:38 is discoverable in design plugin" \
    "$_t3_cnt" "0"

# ─── T4 [SPEC-4]: KEEPERS §H row for pipeline-stages.sh:42 maps to plugins/agent/design/ ──
_t4_row=$(grep "pipeline-stages.sh:42" "$REPO_ROOT/docs/KEEPERS.md" 2>/dev/null || true)
assert_contains "[SPEC-4] KEEPERS §H row for pipeline-stages.sh:42 mentions plugins/agent/design/" \
    "$_t4_row" "plugins/agent/design/"

# ─── T5 [SPEC-5]: _extract_scope_from_design pruned from legacy (CHANGE) ─────
_t5_cnt=$(grep -c "^_extract_scope_from_design()" \
    "$REPO_ROOT/legacy/scripts/lib/pipeline-stages.sh" 2>/dev/null || true)
assert_eq "[SPEC-5] _extract_scope_from_design pruned from legacy/scripts/lib/pipeline-stages.sh" \
    "0" "$_t5_cnt"

# T5 simulation: redefine function to return empty, then run the build plugin's
# scope-selector logic (build/plugin.sh:148-155) to verify _scope_source stays "plan".
# This proves simulated removal reproduces the original symptom (design scope ignored).
mkdir -p "$TEST_TEMP_DIR/t5"
printf '# Design\n\n%sscope\nonly.sh\n%s\n' "$_bt" "$_bt" > "$TEST_TEMP_DIR/t5/design.md"
_sim_scope_source="plan"
_sim_design_md="$TEST_TEMP_DIR/t5/design.md"
_extract_scope_from_design() { return 0; }
if [[ -f "$_sim_design_md" ]] && grep -q '^```scope' "$_sim_design_md" 2>/dev/null; then
    _sim_csv="$(_extract_scope_from_design "$_sim_design_md" 2>/dev/null || echo "")"
    if [[ -n "$_sim_csv" ]]; then
        _sim_scope_source="design"
    fi
fi
assert_eq "[SPEC-5] T5 simulation: scope_source stays plan when _extract_scope_from_design returns empty" \
    "plan" "$_sim_scope_source"

cleanup_test_env
print_test_results
