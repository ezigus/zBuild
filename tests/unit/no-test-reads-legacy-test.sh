#!/usr/bin/env bash
# Guard: no test reads the frozen upstream tree, legacy-DoNotUse/ (ADR-059 §2, ADR-002).
#
# Issue worktrees leave legacy-DoNotUse/ out entirely (#1802), so a test that reads a frozen
# file fails inside every run's test stage while CI — a full checkout — stays green. That is
# what broke the #1752 run. The tree is a frozen reference, not something zBuild's tests depend
# on; no part of it may be read, with no subdirectory excepted.
#
# Scans every test tier for `$REPO_ROOT/legacy-DoNotUse/…`, or `$SOME_DIR/../legacy-DoNotUse/…`
# (a path climbing out of the test's own directory). The tree's old top-level name is matched
# too, so a test cannot reach it under either name. A fixture tree under a temp dir
# (`$TEST_TEMP_DIR/legacy-DoNotUse`, `$FAKE_ROOT/…`) is not the real tree and is not matched.
# A `grep -v "^$REPO_ROOT/legacy-DoNotUse/"` filter only drops paths, so it is allowed.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "no test reads legacy-DoNotUse/ (ADR-059 §2)"

_tree='legacy(-DoNotUse)?[/]'
_offenders="$(
    {
        grep -rnE "\\\$\\{?(REPO_ROOT\\}?|[A-Za-z_]+\\}?(/\\.\\.)+)/${_tree}" \
            "$REPO_ROOT/tests" "$REPO_ROOT/plugins" "$REPO_ROOT/core" --include='*.sh' 2>/dev/null || true
    } | { grep -v '/no-test-reads-legacy-test.sh:' || true; } \
      | { grep -vE "\\^\\\$\\{?REPO_ROOT\\}?/${_tree}" || true; } \
      | { grep -vE '^[^:]*:[0-9]+:[[:space:]]*#' || true; } \
      | sort -u
)"

if [[ -z "$_offenders" ]]; then
    assert_pass "no test reads a file under legacy-DoNotUse/"
else
    assert_fail "no test reads a file under legacy-DoNotUse/" \
        "issue worktrees leave legacy-DoNotUse/ out (ADR-059 §2); offenders:"$'\n'"$_offenders"
fi

print_test_results
