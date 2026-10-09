#!/usr/bin/env bash
# Guard: no test reads the real legacy/ tree (ADR-059 §2).
#
# Issue worktrees leave legacy/ out (#1802), so a test that reads a frozen legacy file fails
# inside every run's test stage while CI — a full checkout — stays green. That is what broke
# the #1752 run. legacy/ is a frozen reference, not something zBuild's tests depend on; only
# legacy/migrated/ (the tombstones, kept in every worktree) may be read.
#
# Scans every test tier for `$REPO_ROOT/legacy/…` outside legacy/migrated/. A fixture tree
# under a temp dir (`$TEST_TEMP_DIR/legacy`, `$FAKE_ROOT/legacy`, …) is not the real tree and
# is not matched. A `grep -v "^$REPO_ROOT/legacy/"` filter only drops paths, so it is allowed.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "no test reads legacy/ (ADR-059 §2)"

_offenders="$(
    {
        grep -rnE '\$\{?REPO_ROOT\}?/legacy/' \
            "$REPO_ROOT/tests" "$REPO_ROOT/plugins" "$REPO_ROOT/core" --include='*.sh' 2>/dev/null || true
    } | { grep -v '/no-test-reads-legacy-test.sh:' || true; } \
      | { grep -vE '\$\{?REPO_ROOT\}?/legacy/migrated/' || true; } \
      | { grep -vE '\^\$\{?REPO_ROOT\}?/legacy/' || true; } \
      | { grep -vE '^[^:]*:[0-9]+:[[:space:]]*#' || true; } \
      | sort -u
)"

if [[ -z "$_offenders" ]]; then
    assert_pass "no test reads a file under legacy/ outside legacy/migrated/"
else
    assert_fail "no test reads a file under legacy/ outside legacy/migrated/" \
        "issue worktrees leave legacy/ out (ADR-059 §2); offenders:"$'\n'"$_offenders"
fi

print_test_results
