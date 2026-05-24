#!/usr/bin/env bash
# zBuild test runner — runs all tests under tests/ + plugins/*/test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "zBuild — full test suite"

PASS=0; FAIL=0; TOTAL=0; FAILURES=()

# Discover tests: tests/*.test.sh + plugins/*/*/test.sh
mapfile -t test_files < <(
    find "$REPO_ROOT/tests" -maxdepth 3 -name '*-test.sh' -type f 2>/dev/null
    find "$REPO_ROOT/plugins" -maxdepth 4 -name 'test.sh' -type f 2>/dev/null
)

if [[ ${#test_files[@]} -eq 0 ]]; then
    echo "No tests found yet (Phase 0 step 5+ lands the first agent plugin tests)."
    exit 0
fi

for test_file in "${test_files[@]}"; do
    [[ "$test_file" == "$0" ]] && continue
    [[ "$(basename "$test_file")" == "run-all.sh" ]] && continue
    [[ "$(basename "$test_file")" == "run-unit.sh" ]] && continue

    echo
    info "running: $test_file"
    if bash "$test_file"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILURES+=("$test_file")
    fi
    TOTAL=$((TOTAL + 1))
done

print_test_results
exit $((FAIL > 0))
