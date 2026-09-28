#!/usr/bin/env bash
# Tests (#2201): the write-boundary sweep never attributes git's internals to a
# stage. CI (PR #2200): another process's `.git/index.lock` in the watched engine
# root was blamed on `intake` and `test`, the stage resolved `broken`, and since
# #2197 `broken` halts the run.
#
# SPEC-1 [change]: a file created under a watched tree's .git/ after the mark is
#   not reported by the sweep.
# SPEC-2 [guard] : a stray file in the same watched tree still is.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/pipeline/write-boundary.sh
source "$REPO_ROOT/core/pipeline/write-boundary.sh"

print_test_header "write-boundary sweep ignores git internals (#2201)"
setup_test_env "wb-git-internals"
_test_cleanup_hook() { cleanup_test_env; }

W="$TEST_TEMP_DIR/watched"; mkdir -p "$W/.git"
printf '%s maxdepth:2\n' "$W" > "$TEST_TEMP_DIR/watch.txt"
export ZBUILD_WRITE_BOUNDARY_WATCH="$TEST_TEMP_DIR/watch.txt"
MARK="$TEST_TEMP_DIR/mark"; : > "$MARK"
sleep 1.1   # the marker's mtime must be strictly older than what follows
: > "$W/.git/index.lock"
: > "$W/stray.txt"
_found="$(write_boundary_sweep "$MARK" 2>/dev/null)"

assert_eq "[SPEC-1] .git/index.lock is not reported" "0" "$(grep -c 'index.lock' <<< "$_found" || true)"
assert_contains "[SPEC-2] a stray file in the same tree still is" "$_found" "stray.txt"

print_test_results
exit $((FAIL > 0))
