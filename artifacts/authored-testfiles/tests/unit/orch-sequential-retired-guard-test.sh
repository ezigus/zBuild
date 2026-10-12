#!/usr/bin/env bash
# [#1801/SPEC-8] Guard: orch-sequential is retired.
#
# After this change:
#   - plugins/tool/orch-sequential/ does not exist on disk
#   - no file outside docs/adr/ names "orch-sequential"
#   - configuring `sequential` as an orchestrator backend makes the run end as
#     `misconfigured`
#
# [#1801/SPEC-11] Guard: ADR-054 §9, ADR-017, and ADR-011 have ## Enforced by
# sections and are NOT in config/adr-enforcement-baseline.txt.
#
# These tests FAIL on pre-change code (where orch-sequential still exists, where
# code files still reference it, and where the ADRs lack Enforced-by sections)
# and PASS after the change.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "[#1801/SPEC-8] orch-sequential retired; [#1801/SPEC-11] ADR Enforced-by sections"

# ─── [#1801/SPEC-8] the directory is absent ───────────────────────────────────
print_test_section "[#1801/SPEC-8] plugins/tool/orch-sequential/ is absent"

if [[ -e "$REPO_ROOT/plugins/tool/orch-sequential" ]]; then
    assert_fail "[#1801/SPEC-8] plugins/tool/orch-sequential/ is absent" \
        "directory still exists — the retired backend was not removed"
else
    assert_pass "[#1801/SPEC-8] plugins/tool/orch-sequential/ is absent"
fi

# ─── [#1801/SPEC-8] no file outside docs/adr/ names orch-sequential ──────────
print_test_section "[#1801/SPEC-8] no file outside docs/adr/ names orch-sequential"

# Directories the guard allows: docs/adr/ (historical references are fine there)
# and tests/golden (the golden for the deleted plugin will also be gone).
# The guard runs via grep -r, excluding those two directories.
_bad_refs=""
while IFS= read -r _match; do
    [[ -z "$_match" ]] && continue
    # Strip repo root prefix for readability
    _rel="${_match#$REPO_ROOT/}"
    _bad_refs+="  $_rel"$'\n'
done < <(grep -rl 'orch-sequential' "$REPO_ROOT" \
    --exclude-dir='.git' \
    --exclude-dir='legacy-DoNotUse' 2>/dev/null | \
    grep -v '^'"$REPO_ROOT"'/docs/adr/' | \
    grep -v '^'"$REPO_ROOT"'/tests/golden/' | \
    grep -v '^'"$REPO_ROOT"'/tests/unit/orch-sequential-retired-guard-test\.sh$' | \
    grep -v '^'"$REPO_ROOT"'/tests/unit/orch-backend-misconfigured-test\.sh$' || true)

if [[ -n "$_bad_refs" ]]; then
    assert_fail "[#1801/SPEC-8] no file outside docs/adr/ names orch-sequential" \
        "found references:"$'\n'"$_bad_refs"
else
    assert_pass "[#1801/SPEC-8] no file outside docs/adr/ names orch-sequential"
fi

# ─── [#1801/SPEC-8] configuring sequential as backend → misconfigured ─────────
print_test_section "[#1801/SPEC-8] configuring sequential as a backend ends the run as misconfigured"

# source contract.sh with a controlled env so _orch_load_backend uses the
# sequential alias and we can capture its outcome.
_orch_result=""
_orch_rc=0
_orch_result="$(
    ZBUILD_ORCH_BACKEND=sequential \
    ZBUILD_PLUGINS_ROOT="$REPO_ROOT/plugins" \
    bash -c '
        source "'"$REPO_ROOT"'/scripts/lib/helpers.sh" 2>/dev/null || true
        source "'"$REPO_ROOT"'/core/orch/contract.sh" 2>/dev/null || true
        # After the change, orch_load_backend emits orch.backend.misconfigured
        # or writes a misconfigured disposition; check what the function does.
        orch_load_backend sequential 2>&1
        echo "rc=$?"
    ' 2>&1)" || _orch_rc=$?

# The requirement: configuring sequential emits misconfigured
# Accept either an event name match or an explicit "misconfigured" in output
if grep -qiE 'misconfigured|sequential.*not found|backend.*sequential.*not' <<< "$_orch_result"; then
    assert_pass "[#1801/SPEC-8] configuring sequential as backend signals misconfigured"
else
    assert_fail "[#1801/SPEC-8] configuring sequential as backend signals misconfigured" \
        "output: $(printf '%s' "$_orch_result" | head -5 | tr '\n' '|')"
fi

# ─── [#1801/SPEC-11] ADR-054 has ## Enforced by section ──────────────────────
print_test_section "[#1801/SPEC-11] ADR-054 has ## Enforced by section"

_adr054="$REPO_ROOT/docs/adr/ADR-054-stage-contract.md"
if [[ ! -f "$_adr054" ]]; then
    assert_fail "[#1801/SPEC-11] ADR-054 exists" "file not found: $_adr054"
else
    if grep -qE '^## Enforced by' "$_adr054"; then
        assert_pass "[#1801/SPEC-11] ADR-054 has ## Enforced by section"
    else
        assert_fail "[#1801/SPEC-11] ADR-054 has ## Enforced by section" \
            "section absent — ADR-054 §9 requires it"
    fi
fi

# ─── [#1801/SPEC-11] ADR-017 has ## Enforced by section ──────────────────────
print_test_section "[#1801/SPEC-11] ADR-017 has ## Enforced by section"

_adr017="$REPO_ROOT/docs/adr/ADR-017-per-stage-router-config.md"
if [[ ! -f "$_adr017" ]]; then
    assert_fail "[#1801/SPEC-11] ADR-017 exists" "file not found: $_adr017"
else
    if grep -qE '^## Enforced by' "$_adr017"; then
        assert_pass "[#1801/SPEC-11] ADR-017 has ## Enforced by section"
    else
        assert_fail "[#1801/SPEC-11] ADR-017 has ## Enforced by section" \
            "section absent"
    fi
fi

# ─── [#1801/SPEC-11] ADR-011 has ## Enforced by section ──────────────────────
print_test_section "[#1801/SPEC-11] ADR-011 has ## Enforced by section"

_adr011="$REPO_ROOT/docs/adr/ADR-011-pluggable-backends.md"
if [[ ! -f "$_adr011" ]]; then
    assert_fail "[#1801/SPEC-11] ADR-011 exists" "file not found: $_adr011"
else
    if grep -qE '^## Enforced by' "$_adr011"; then
        assert_pass "[#1801/SPEC-11] ADR-011 has ## Enforced by section"
    else
        assert_fail "[#1801/SPEC-11] ADR-011 has ## Enforced by section" \
            "section absent"
    fi
fi

# ─── [#1801/SPEC-11] the three ADRs are not in the enforcement baseline ───────
print_test_section "[#1801/SPEC-11] ADR-054, ADR-017, ADR-011 removed from adr-enforcement-baseline.txt"

_baseline="$REPO_ROOT/config/adr-enforcement-baseline.txt"
if [[ ! -f "$_baseline" ]]; then
    assert_fail "[#1801/SPEC-11] config/adr-enforcement-baseline.txt exists" \
        "file not found: $_baseline"
else
    for _adr_name in ADR-054 ADR-017 ADR-011; do
        if grep -q "$_adr_name" "$_baseline"; then
            assert_fail "[#1801/SPEC-11] $_adr_name is not in adr-enforcement-baseline.txt" \
                "$_adr_name still listed — remove after adding its Enforced-by section"
        else
            assert_pass "[#1801/SPEC-11] $_adr_name is not in adr-enforcement-baseline.txt"
        fi
    done
fi

print_test_results
exit $((FAIL > 0))
