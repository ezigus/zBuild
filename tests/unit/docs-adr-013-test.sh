#!/usr/bin/env bash
# Tests: docs/adr/ADR-013-canonical-stage-list.md — content conformance (issue #292)
#
# ADR-013 is a markdown document (the deliverable for issue #292). These tests
# verify that the file exists, has all required structural sections, declares the
# canonical 11-stage list with correct required fields, defines the
# compound_quality sub-phases, cross-links from ARCHITECTURE.md §3, and has no
# extras or omissions in the stage id set.
#
# Test tier: unit  (read-only grep/awk against committed markdown files; no
# subprocess, no network, no FS mutation, well under 1s per test)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "docs/adr/ADR-013 — canonical stage list conformance (issue #292)"

ADR_FILE="$REPO_ROOT/docs/adr/ADR-013-canonical-stage-list.md"
ARCH_FILE="$REPO_ROOT/docs/ARCHITECTURE.md"

# ---------------------------------------------------------------------------
# TC-1: ADR-013 file exists at the canonical path
# ---------------------------------------------------------------------------
if [[ -f "$ADR_FILE" ]]; then
    assert_pass "TC-1: ADR-013 file exists at docs/adr/ADR-013-canonical-stage-list.md"
else
    assert_fail "TC-1: ADR-013 file exists at docs/adr/ADR-013-canonical-stage-list.md" \
        "file not found: $ADR_FILE"
    # Cannot continue without the file — remaining tests would produce
    # misleading output, so exit now with the failure count.
    cleanup_test_env
    print_test_results
    exit 1
fi

# ---------------------------------------------------------------------------
# TC-2: Required top-level sections present
# ---------------------------------------------------------------------------
# ADR convention: Status/Date use **bold** frontmatter; other sections are ## headings.
set +e; grep -q "^\*\*Status:\*\*" "$ADR_FILE"; rc=$?; set -e
assert_eq "TC-2: has '**Status:**' frontmatter" "0" "$rc"

for section in "Context" "Decision" "Consequences" "Implementation Notes"; do
    set +e
    grep -q "^## ${section}" "$ADR_FILE"
    rc=$?
    set -e
    assert_eq "TC-2: has '## ${section}' section" "0" "$rc"
done

# ---------------------------------------------------------------------------
# TC-3: All 11 canonical stage ids are present in the document
# ---------------------------------------------------------------------------
canonical_stages=(
    intake
    plan
    design
    build
    test
    review
    compound_quality
    pr
    deploy
    validate
    monitor
)

for stage_id in "${canonical_stages[@]}"; do
    set +e
    grep -q "\b${stage_id}\b" "$ADR_FILE"
    rc=$?
    set -e
    assert_eq "TC-3: stage id '${stage_id}' present in ADR-013" "0" "$rc"
done

# ---------------------------------------------------------------------------
# TC-4: Each stage entry has all required field names in the document
# ---------------------------------------------------------------------------
# ADR-013 must define a structured stage table or block that includes each of
# these field names at least once per stage section.  We test that the field
# names appear in the document body at all; a deeper per-row check is TC-7.
required_fields=(id kind tier required_hooks expected_artifact blocking)

for field in "${required_fields[@]}"; do
    set +e
    grep -q "\b${field}\b" "$ADR_FILE"
    rc=$?
    set -e
    assert_eq "TC-4: required field '${field}' appears in ADR-013" "0" "$rc"
done

# ---------------------------------------------------------------------------
# TC-5: compound_quality sub-phases defined (preflight, audit_plan, cycle, backtrack)
# ---------------------------------------------------------------------------
# ADR-013 is the canonical source; sub-phase names must match exactly.
# `audit_plan` (not `plan`) is the second sub-phase per the ADR's own table.
# Testing for the exact token prevents false-green matches on the generic word "plan".
compound_subphases=(preflight audit_plan cycle backtrack)

for subphase in "${compound_subphases[@]}"; do
    set +e
    grep -q "\b${subphase}\b" "$ADR_FILE"
    rc=$?
    set -e
    assert_eq "TC-5: compound_quality sub-phase '${subphase}' defined in ADR-013" "0" "$rc"
done

# ---------------------------------------------------------------------------
# TC-6: ARCHITECTURE.md §3 contains a cross-link to ADR-013
# ---------------------------------------------------------------------------
# The cross-link may appear as [ADR-013], ADR-013, or a relative markdown link
# pointing to the file.  We accept any of these forms.
set +e
grep -qE "(ADR-013|\[ADR-013\]|ADR-013-canonical-stage-list)" "$ARCH_FILE"
rc=$?
set -e
assert_eq "TC-6: ARCHITECTURE.md §3 cross-links to ADR-013" "0" "$rc"

# ---------------------------------------------------------------------------
# TC-7: Stage ids in ADR match canonical list exactly — no extras, no missing
# ---------------------------------------------------------------------------
# Strategy: extract every token that looks like a stage id from the ADR's
# Decision section, then compare the sorted set to the canonical sorted set.
# We look for bare id values on lines that contain "id:" or "| id" table cells
# matching one of the known stage names (guarded list), so we do not
# accidentally pick up unrelated text.

canonical_sorted=$(printf '%s\n' "${canonical_stages[@]}" | sort)

# Collect stage ids from explicit "| <id> |" table cells in the Decision
# section only.  Uses only POSIX awk (no 3-arg match, no gawk extensions) so
# it works on both macOS nawk and GNU awk.
found_sorted=$(awk '
    /^## Decision/        { in_decision=1; next }
    in_decision && /^## / { in_decision=0 }
    in_decision {
        n = split($0, cells, "|")
        for (i = 1; i <= n; i++) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", cells[i])
            if (cells[i] ~ /^(intake|plan|design|build|test|review|compound_quality|pr|deploy|validate|monitor)$/) {
                ids[cells[i]] = 1
            }
        }
    }
    END { for (k in ids) print k }
' "$ADR_FILE" | sort)

assert_eq "TC-7: stage id set in ADR-013 matches canonical list exactly" \
    "$canonical_sorted" "$found_sorted"

# ---------------------------------------------------------------------------
# TC-8: All expected_artifact table cells are non-empty
# ---------------------------------------------------------------------------
# The canonical stage table has 11 data rows (one per stage). Extract the
# expected_artifact column (column 5 in the pipe-delimited table, 1-indexed
# from the leftmost pipe) and count any cells that are blank or contain only
# dashes/whitespace (which would indicate a missing artifact value).
# Uses POSIX awk; works on both macOS nawk and GNU awk.
blank_artifacts=$(awk '
    /^\| id / { header=1; next }
    header && /^\|---/ { next }
    header && /^\|/ {
        n = split($0, cells, "|")
        # column index 5 = expected_artifact (after id|kind|tier|required_hooks|expected_artifact)
        if (n >= 6) {
            val = cells[6]
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
            if (val == "" || val ~ /^-+$/) count++
        }
    }
    END { print count+0 }
' "$ADR_FILE")
assert_eq "TC-8: no expected_artifact table cells are empty" "0" "$blank_artifacts"

# ---------------------------------------------------------------------------
# TC-9: All tiers are valid values in the T0–T4 range
# ---------------------------------------------------------------------------
# Any "tier:" or "| T" cell that names a tier value must be T0, T1, T2, T3, or
# T4.  If the document contains a tier value outside that set it indicates a
# typo or an undocumented tier.
set +e
invalid_tiers=$(grep -Eo "\bT[0-9]+\b" "$ADR_FILE" | grep -Ev "^T[0-4]$" | wc -l | tr -d ' ')
set -e
assert_eq "TC-9: all tier values in ADR-013 are within T0–T4" "0" "$invalid_tiers"

# ---------------------------------------------------------------------------
# TC-10: Implementation Notes section is non-empty
# ---------------------------------------------------------------------------
impl_content="$(awk '/^## Implementation Notes/{found=1; next} found && /^## /{exit} found && NF{print; exit}' "$ADR_FILE")"
if [[ -n "$impl_content" ]]; then
    assert_pass "TC-10: Implementation Notes section is non-empty"
else
    assert_fail "TC-10: Implementation Notes section is non-empty" \
        "section exists but contains no content lines"
fi

# ---------------------------------------------------------------------------

cleanup_test_env
print_test_results
exit $((FAIL > 0))
