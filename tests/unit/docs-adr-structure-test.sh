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

cleanup_test_env
print_test_results
exit $((FAIL > 0))
