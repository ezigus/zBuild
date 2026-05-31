#!/usr/bin/env bash
# Tests: docs/adr/ADR-013-canonical-stage-list.md — content conformance (issue #292)
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
# TC-3: All 12 canonical stage ids are present in the document
# ---------------------------------------------------------------------------
# Use grep -w for portable word-boundary matching (POSIX/BSD/GNU compatible).
canonical_stages=(
    intake plan design build test test_assessment review
    compound_quality pr deploy validate monitor
)

for stage_id in "${canonical_stages[@]}"; do
    set +e
    grep -qw -- "${stage_id}" "$ADR_FILE"
    rc=$?
    set -e
    assert_eq "TC-3: stage id '${stage_id}' present in ADR-013" "0" "$rc"
done

# ---------------------------------------------------------------------------
# TC-4: Required field names appear in the document
# ---------------------------------------------------------------------------
# lifecycle_hooks replaces the earlier required_hooks column name (ADR-001
# distinguishes kind-entry hooks from optional lifecycle hooks).
required_fields=(id kind tier lifecycle_hooks expected_artifact blocking)

for field in "${required_fields[@]}"; do
    set +e
    grep -qw -- "${field}" "$ADR_FILE"
    rc=$?
    set -e
    assert_eq "TC-4: required field '${field}' appears in ADR-013" "0" "$rc"
done

# ---------------------------------------------------------------------------
# TC-5: compound_quality sub-phases defined with canonical ids
# ---------------------------------------------------------------------------
# audit_plan (not plan) is the second sub-phase per ADR-013 §"compound_quality
# sub-phases". Testing the exact token prevents false-green matches on the
# generic word "plan" which appears as a stage id throughout the file.
compound_subphases=(preflight audit_plan cycle backtrack)

for subphase in "${compound_subphases[@]}"; do
    set +e
    grep -qw -- "${subphase}" "$ADR_FILE"
    rc=$?
    set -e
    assert_eq "TC-5: compound_quality sub-phase '${subphase}' defined in ADR-013" "0" "$rc"
done

# ---------------------------------------------------------------------------
# TC-6: ARCHITECTURE.md §3 contains a cross-link to ADR-013
# ---------------------------------------------------------------------------
set +e
grep -qE "(ADR-013|\[ADR-013\]|ADR-013-canonical-stage-list)" "$ARCH_FILE"
rc=$?
set -e
assert_eq "TC-6: ARCHITECTURE.md §3 cross-links to ADR-013" "0" "$rc"

# ---------------------------------------------------------------------------
# TC-7: Stage ids in Decision table match canonical list exactly — no extras
# ---------------------------------------------------------------------------
# Strategy: locate the canonical stage definitions table by its header row
# ("| id | kind | tier |"), then extract the first pipe-cell from every data
# row that follows (until a blank line or the next section header).
# This extracts ALL first-column values without an allowlist filter, so any
# extra/typo stage id in the table will be caught.  Uses POSIX awk.

canonical_sorted=$(printf '%s\n' "${canonical_stages[@]}" | sort)

found_sorted=$(awk '
    /^\| id[[:space:]]*\|/ { in_table=1; next }   # header row
    in_table && /^\|---/   { next }                # separator row
    in_table && /^\|/ {
        n = split($0, cells, "|")
        if (n >= 2) {
            val = cells[2]
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
            if (val != "" && val !~ /^-+$/ && val != "id") {
                ids[val] = 1
            }
        }
    }
    in_table && !/^\|/ { in_table=0 }
    END { for (k in ids) print k }
' "$ADR_FILE" | sort)

assert_eq "TC-7: stage id set in Decision table matches canonical list exactly" \
    "$canonical_sorted" "$found_sorted"

# ---------------------------------------------------------------------------
# TC-8: All expected_artifact table cells are non-empty
# ---------------------------------------------------------------------------
# Find the canonical stage table by its header, then check column 5
# (expected_artifact) in each data row.  Column index is 6 in the awk split
# because the first split cell is empty (line starts with |).
blank_artifacts=$(awk '
    /^\| id[[:space:]]*\|/ { header=1; next }
    header && /^\|---/ { next }
    header && /^\|/ {
        n = split($0, cells, "|")
        if (n >= 6) {
            val = cells[6]
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
            if (val == "" || val ~ /^-+$/) count++
        }
    }
    header && !/^\|/ { header=0 }
    END { print count+0 }
' "$ADR_FILE")
assert_eq "TC-8: no expected_artifact table cells are empty" "0" "$blank_artifacts"

# ---------------------------------------------------------------------------
# TC-9: All tier values are within T0–T4
# ---------------------------------------------------------------------------
# grep -Eo 'T[0-9]+' without \b is portable; filter with grep -Ev '^T[0-4]$'.
set +e
invalid_tiers=$(grep -Eo 'T[0-9]+' "$ADR_FILE" | grep -cv '^T[0-4]$' || true)
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
