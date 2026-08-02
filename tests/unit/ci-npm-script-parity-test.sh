#!/usr/bin/env bash
# tests/unit/ci-npm-script-parity-test.sh — guard: npm run lint and CI lint job
# must shellcheck the same set of files (local ⊇ CI).  Fails if they diverge.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "CI / npm run lint shellcheck parity"

WORKFLOW="$REPO_ROOT/.github/workflows/test.yml"
PKG="$REPO_ROOT/package.json"

# ---------------------------------------------------------------------------
# TC-1 [SPEC-1]: Both sources use the same root paths for shellcheck find.
# We check that test.yml contains "find scripts core plugins" and package.json
# also contains "find scripts core plugins" (not the old "find scripts/lib ...").
# ---------------------------------------------------------------------------
ci_find_root=""
if grep -q "find scripts core plugins" "$WORKFLOW" 2>/dev/null; then
    ci_find_root="scripts core plugins"
fi
npm_find_root=""
if grep -q "find scripts core plugins" "$PKG" 2>/dev/null; then
    npm_find_root="scripts core plugins"
fi

if [[ "$ci_find_root" == "scripts core plugins" && "$npm_find_root" == "scripts core plugins" ]]; then
    assert_pass "[SPEC-1] CI and npm lint use same shellcheck root paths (scripts core plugins)"
else
    assert_fail "[SPEC-1] CI and npm lint use same shellcheck root paths (scripts core plugins)" \
        "ci_root='$ci_find_root' npm_root='$npm_find_root'"
fi

# ---------------------------------------------------------------------------
# TC-2 [SPEC-2]: CI's find command produces a non-empty file list from repo root.
# ---------------------------------------------------------------------------
ci_files="$(find "$REPO_ROOT/scripts" "$REPO_ROOT/core" "$REPO_ROOT/plugins" \
    -name '*.sh' -not -path '*/legacy/*' 2>/dev/null | sort)"
if [[ -n "$ci_files" ]]; then
    ci_count="$(echo "$ci_files" | wc -l | tr -d ' ')"
    assert_pass "[SPEC-2] CI shellcheck find returns non-empty file list ($ci_count files)"
else
    assert_fail "[SPEC-2] CI shellcheck find returns non-empty file list" "got empty list"
fi

# ---------------------------------------------------------------------------
# TC-3 [SPEC-3]: Every file in CI's find result is also in local lint's find
# result (local ⊇ CI superset assertion).
# ---------------------------------------------------------------------------
npm_files="$(find "$REPO_ROOT/scripts" "$REPO_ROOT/core" "$REPO_ROOT/plugins" \
    -name '*.sh' -not -path '*/legacy/*' 2>/dev/null | sort)"

missing_from_npm=()
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if ! grep -qxF "$f" <(echo "$npm_files"); then
        missing_from_npm+=("$f")
    fi
done <<< "$ci_files"

if [[ "${#missing_from_npm[@]}" -eq 0 ]]; then
    assert_pass "[SPEC-3] npm lint file set is a superset of CI lint file set"
else
    assert_fail "[SPEC-3] npm lint file set is a superset of CI lint file set" \
        "missing from npm: ${missing_from_npm[*]}"
fi

# ---------------------------------------------------------------------------
# TC-4 [SPEC-4]: scripts/run-tests.sh specifically appears in local find result.
# ---------------------------------------------------------------------------
run_tests="$REPO_ROOT/scripts/run-tests.sh"
if echo "$npm_files" | grep -qxF "$run_tests"; then
    assert_pass "[SPEC-4] scripts/run-tests.sh is in local lint file set"
else
    assert_fail "[SPEC-4] scripts/run-tests.sh is in local lint file set" \
        "not found in: $(echo "$npm_files" | head -5) ..."
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
