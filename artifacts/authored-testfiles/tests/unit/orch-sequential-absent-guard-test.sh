#!/usr/bin/env bash
# Guard: the orch-sequential plugin is removed from the installed tree (#1801,
# SPEC-3). A guard that passes while the directory still exists would let a
# trivially-present plugin defeat the whole point of SPEC-2's no-fallback rule.
#
# Two assertions:
#   1. The plugin directory itself does not exist in the installed tree.
#   2. No code or config file outside docs/adr/ still names "orch-sequential"
#      (the golden file, manifests, contract.sh hardcoded path, test references).
#
# Both must FAIL on current code (the directory exists and is referenced
# throughout) and PASS after the implementation removes the plugin.
#
# [#1801/SPEC-3]
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "orch-sequential is absent from the installed tree (#1801 SPEC-3)"
setup_test_env "orch-sequential-absent-guard"

# ── SPEC-3a: plugin directory does not exist ─────────────────────────────────
_orch_seq_dir="$REPO_ROOT/plugins/tool/orch-sequential"
if [[ ! -d "$_orch_seq_dir" ]]; then
    assert_pass "[#1801/SPEC-3] orch-sequential plugin directory does not exist"
else
    assert_fail "[#1801/SPEC-3] orch-sequential plugin directory does not exist" \
        "directory still present: $_orch_seq_dir"
fi

# ── SPEC-3b: no code or config file outside docs/adr/ names orch-sequential ──
# Files allowed to reference orch-sequential: docs/adr/ (ADR prose)
# Files NOT allowed: core/, plugins/, scripts/, config/, tests/, .github/
_hits=""
while IFS= read -r _f; do
    # Skip docs/adr/ — ADR prose is allowed to name the deleted plugin
    case "$_f" in
        */docs/adr/*) continue ;;
        # Skip the guard test itself (this file)
        */orch-sequential-absent-guard-test.sh) continue ;;
    esac
    _hits="${_hits}${_f}"$'\n'
done < <(grep -rl "orch-sequential" \
    "$REPO_ROOT/core" \
    "$REPO_ROOT/plugins" \
    "$REPO_ROOT/scripts" \
    "$REPO_ROOT/config" \
    "$REPO_ROOT/tests" \
    "$REPO_ROOT/.github" \
    2>/dev/null || true)

# Remove trailing newline for display
_hits="${_hits%$'\n'}"
if [[ -z "$_hits" ]]; then
    assert_pass "[#1801/SPEC-3] no code or config file outside docs/adr/ names orch-sequential"
else
    assert_fail "[#1801/SPEC-3] no code or config file outside docs/adr/ names orch-sequential" \
        "still referenced in: $(printf '%s' "$_hits" | tr '\n' ' ')"
fi

print_test_results
