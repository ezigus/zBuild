#!/usr/bin/env bash
# tests/unit/run-all-sweep-test.sh — `npm test` (tests/run-all.sh) ends by
# removing the temp folders its tests left (#2541, ADR-012).
#
# Why: tests/lib/test-helpers.sh removes its own temp folder on exit, but a test
# that is killed, times out or replaces the EXIT trap leaves it: 172 had piled
# up on one machine, and `zbuild cleanup --tmpdirs`, which knows them, is never
# run.
#
# S1 [change] after the suite, a zb-test-auto.* / zb-test.* folder older than an
#             hour is gone, and the suite says how many it removed
# S2 [change] ...a newer one (a test still running elsewhere) is kept
# S3 [change] ...a folder of another name is kept
# S4 [change] the suite's own exit code is what npm test exits with
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "npm test sweeps the temp folders its tests left (#2541)"
setup_test_env "run-all-sweep"

# A copy of the repository's run-all.sh beside a stub suite: run-all.sh finds
# the suite by its own path, so the copy runs the stub, not the real suite.
T="$TEST_TEMP_DIR/tree"
mkdir -p "$T/tests/lib" "$T/scripts/lib"
cp "$REPO_ROOT/tests/run-all.sh" "$T/tests/run-all.sh"
cp "$REPO_ROOT/tests/lib/test-harness.sh" "$T/tests/lib/"
cp "$REPO_ROOT/scripts/lib/compat.sh" "$REPO_ROOT/scripts/lib/cleanup.sh" "$T/scripts/lib/"
for _f in "$REPO_ROOT"/scripts/lib/*.sh; do [[ -e "$T/scripts/lib/${_f##*/}" ]] || cp "$_f" "$T/scripts/lib/"; done
printf '#!/usr/bin/env bash\nexit 3\n' > "$T/scripts/run-tests.sh"; chmod +x "$T/scripts/run-tests.sh"

FT="$TEST_TEMP_DIR/faketmp"; mkdir -p "$FT/zb-test-auto.OLD1" "$FT/zb-test.OLD2" "$FT/zb-test-auto.NEW1" "$FT/myapp.OLD3"
touch -t 200001010000 "$FT/zb-test-auto.OLD1" "$FT/zb-test.OLD2" "$FT/myapp.OLD3"

_rc=0; _out="$(TMPDIR="$FT" bash "$T/tests/run-all.sh" 2>&1)" || _rc=$?
assert_eq "[S1] the old zb-test-auto folder is gone" "0" "$([[ -d "$FT/zb-test-auto.OLD1" ]] && echo 1 || echo 0)"
assert_eq "[S1] ...and the old zb-test one" "0" "$([[ -d "$FT/zb-test.OLD2" ]] && echo 1 || echo 0)"
assert_contains "[S1] ...and the suite says how many it removed" "$_out" "removed 2 test temp folder"
assert_eq "[S2] the new one is kept" "1" "$([[ -d "$FT/zb-test-auto.NEW1" ]] && echo 1 || echo 0)"
assert_eq "[S3] a folder of another name is kept" "1" "$([[ -d "$FT/myapp.OLD3" ]] && echo 1 || echo 0)"
assert_eq "[S4] npm test exits with the suite's own code" "3" "$_rc"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
