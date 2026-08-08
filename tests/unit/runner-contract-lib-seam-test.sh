#!/usr/bin/env bash
# tests/unit/runner-contract-lib-seam-test.sh — the contract-reader seam (#1783).
#
#   SPEC-1 [change]: the snapshot set is DERIVED, so it includes the transitive
#                    deps the old hand-list missed (env-scrub, impact-prefilter)
#   SPEC-2 [change]: the snapshot is a self-contained root — every lib it copies
#                    can be sourced from it without reaching outside
#   SPEC-3 [change]: no once-guard — a later call picks up a changed tree
#   SPEC-4 [change]: a design whose WIRING targets a contract lib is detected
#   SPEC-5 [guard] : a design with no contract-lib target is NOT detected
#
# The engine grades a run with the contract readers from the INSTALLED engine.
# When the run's own change edits one of those libs, the pre-change reader
# judges the fix and the verdict cannot move. This seam is the carve-out.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "runner — contract-reader seam (#1783)"
setup_test_env "runner-contract-lib-seam"

# runner.sh is guarded, so sourcing yields its functions without running a pipeline.
# shellcheck source=/dev/null
source "$REPO_ROOT/core/pipeline/runner.sh" >/dev/null 2>&1 || true

# At the merge-base these functions do not exist yet. Stub them to a failing
# value rather than letting `set -e` kill the file on the first call: an aborted
# baseline marks NO assertion, so every [change] SPEC here would be inconclusive
# instead of red, and the negative control would prove nothing.
declare -F _runner_contract_lib_closure >/dev/null 2>&1 \
    || _runner_contract_lib_closure() { return 1; }
declare -F _runner_snapshot_contract_libs >/dev/null 2>&1 \
    || _runner_snapshot_contract_libs() { return 1; }
declare -F _runner_design_targets_contract_lib >/dev/null 2>&1 \
    || _runner_design_targets_contract_lib() { return 1; }

LIB="$REPO_ROOT/scripts/lib"

# ─── SPEC-1: the set is derived, not hand-listed ─────────────────────────────
print_test_section "1. closure includes transitive dependencies"

CLOSURE="$(_runner_contract_lib_closure "$LIB" || true)"

assert_contains "[SPEC-1] closure includes env-scrub.sh (sourced by acceptance-negctl)" \
    "$CLOSURE" "env-scrub.sh"
assert_contains "[SPEC-1] closure includes impact-prefilter.sh (sourced by shape-floor)" \
    "$CLOSURE" "impact-prefilter.sh"
assert_contains "[SPEC-1] closure still includes the entry points" \
    "$CLOSURE" "acceptance-negctl.sh"

# ─── SPEC-2: the snapshot is a self-contained root ───────────────────────────
print_test_section "2. snapshot is self-contained"

SNAP="$TEST_TEMP_DIR/snap"
rc=0
_runner_snapshot_contract_libs "$LIB" "$SNAP" || rc=$?
assert_eq "[SPEC-2] snapshot succeeds" "0" "$rc"

# The real property: every same-dir `source` inside a copied lib resolves within
# the snapshot. A missing transitive dep is an UNGUARDED source, so it breaks the
# reader at parse time rather than degrading.
_missing=0
for _f in "$SNAP"/*.sh; do
    [[ -f "$_f" ]] || continue
    while IFS= read -r _dep; do
        [[ -z "$_dep" ]] && continue
        [[ -f "$SNAP/$_dep" ]] || _missing=$((_missing + 1))
    done < <(/usr/bin/grep -oE '^[[:space:]]*(source|\.)[[:space:]]+"\$[A-Za-z_][A-Za-z0-9_]*/[A-Za-z0-9._-]+\.sh"' \
                "$_f" 2>/dev/null | sed -E 's#.*/([A-Za-z0-9._-]+\.sh)"$#\1#')
done
assert_eq "[SPEC-2] every same-dir dependency resolves inside the snapshot" "0" "$_missing"

# ─── SPEC-3: no once-guard — the snapshot tracks the tree ────────────────────
print_test_section "3. snapshot refreshes rather than freezing"

FAKE="$TEST_TEMP_DIR/tree/scripts/lib"
mkdir -p "$FAKE"
for _f in $(_runner_contract_lib_closure "$LIB" || true); do cp "$LIB/$_f" "$FAKE/$_f" 2>/dev/null || true; done

SNAP2="$TEST_TEMP_DIR/snap2"
_runner_snapshot_contract_libs "$FAKE" "$SNAP2" >/dev/null 2>&1 || true

printf '\n# ZBUILD_1783_MARKER\n' >> "$FAKE/acceptance-block.sh" 2>/dev/null || true
_runner_snapshot_contract_libs "$FAKE" "$SNAP2" >/dev/null 2>&1 || true

_hits="$(/usr/bin/grep -cF 'ZBUILD_1783_MARKER' "$SNAP2/acceptance-block.sh" 2>/dev/null || true)"
assert_eq "[SPEC-3] a second snapshot picks up a changed lib (no once-guard)" \
    "1" "${_hits//[^0-9]/}"

# ─── SPEC-4 / SPEC-5: declarative detection off the design's WIRING ──────────
print_test_section "4. detection keys on the design's declared WIRING targets"

# Deliberately NOT sourcing acceptance-block.sh here. Pre-sourcing it made these
# assertions pass while the live path was dead: the WIRING reader is defined in
# that lib, which only PLUGINS source, and they run inside a subshell whose
# definitions never reach the runner. The detection must stand up in the shell
# the runner actually has — which is this one.
assert_eq "[SPEC-4] the WIRING reader is NOT pre-loaded (matches the live runner shell)" \
    "" "$(declare -F acceptance_list_wiring 2>/dev/null || true)"

mk_design() {
    local path="$1" target="$2"
    cat > "$path" <<EOF
# Design

\`\`\`acceptance
SPEC-1[change]: something changes.
WIRING:
${target}
TESTFILES:
SPEC-1: tests/unit/x-test.sh
\`\`\`
EOF
}

D_HIT="$TEST_TEMP_DIR/design-hit.md"
mk_design "$D_HIT" "scripts/lib/acceptance-negctl.sh"
_out="$(_runner_design_targets_contract_lib "$D_HIT" "$LIB" 2>/dev/null || true)"
assert_contains "[SPEC-4] a WIRING target inside the contract-reader set is detected" \
    "$_out" "acceptance-negctl.sh"

D_MISS="$TEST_TEMP_DIR/design-miss.md"
mk_design "$D_MISS" "plugins/tool/pr-open/plugin.sh"
_out2="$(_runner_design_targets_contract_lib "$D_MISS" "$LIB" 2>/dev/null || true)"
assert_eq "[SPEC-5] an ordinary WIRING target does not trigger self-grading" "" "$_out2"

# A same-named file OUTSIDE scripts/lib is not this seam.
D_DECOY="$TEST_TEMP_DIR/design-decoy.md"
mk_design "$D_DECOY" "vendor/other/merge-base.sh"
_out3="$(_runner_design_targets_contract_lib "$D_DECOY" "$LIB" 2>/dev/null || true)"
assert_eq "[SPEC-5] a same-named file outside scripts/lib does not trigger it" "" "$_out3"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
