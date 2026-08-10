#!/usr/bin/env bash
# Tests: docs/adr/ — ADR structural conformance (issue #291)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "docs/adr structure — Implementation Notes conformance (issue #291)"

ADR_DIR="$REPO_ROOT/docs/adr"
adr_files=("$ADR_DIR"/ADR-*.md)

# TC-1: Every ADR has a "## Implementation Notes" section
for f in "${adr_files[@]}"; do
    name="$(basename "$f")"
    set +e
    grep -q "^## Implementation Notes" "$f"
    rc=$?
    set -e
    assert_eq "TC-1: $name has ## Implementation Notes" "0" "$rc"
done

# TC-2: Every Implementation Notes section is non-empty (at least one content line)
for f in "${adr_files[@]}"; do
    name="$(basename "$f")"
    content="$(awk '/^## Implementation Notes/{found=1; next} found && /^## /{exit} found && NF{print; exit}' "$f")"
    if [[ -z "$content" ]]; then
        FAIL=$((FAIL + 1))
        printf "  \033[31m✗\033[0m TC-2: %s Implementation Notes section is empty\n" "$name"
    else
        PASS=$((PASS + 1))
        printf "  \033[32m✓\033[0m TC-2: %s Implementation Notes section is non-empty\n" "$name"
    fi
done

# TC-3: Advisory — heading should include parenthetical (phase/issue reference)
for f in "${adr_files[@]}"; do
    name="$(basename "$f")"
    if ! grep -q "^## Implementation Notes (" "$f"; then
        printf "  ⚠  TC-3 (advisory): %s heading lacks parenthetical\n" "$name"
    fi
done

# SPEC-8: ADR-054 and ADR-055 conform to the Implementation Notes structure requirement.
# These assertions fail at baseline (files absent) and pass once the ADRs are authored.
#
# NOT redundant with TC-1, which loops over a glob of the files that EXIST: delete
# an ADR and TC-1 iterates one fewer file and reports nothing. Naming the two files
# is what makes their ABSENCE detectable, and "no ADR file was deleted" is an
# acceptance criterion of #1820. Verified by removing ADR-054: TC-1 stayed green,
# SPEC-8 was the only failure. Same vacuous-pass shape as #1772.
for new_adr in "ADR-054-stage-contract.md" "ADR-055-inter-stage-data-contract-v2.md"; do
    f="$ADR_DIR/$new_adr"
    set +e
    grep -q "^## Implementation Notes" "$f" 2>/dev/null
    rc=$?
    set -e
    assert_eq "[SPEC-8][change] $new_adr has ## Implementation Notes" "0" "$rc"
done

cleanup_test_env
print_test_results
exit $((FAIL > 0))
