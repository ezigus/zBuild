#!/usr/bin/env bash
# tests/unit/lint-test-errexit-test.sh — a test file that runs without
# stop-on-error never turns it on (#2252 G).
#
# Why: #1844 run 36969128968 — test-author wrapped a call in `set +e … set -e`
# inside pr-pipeline-test.sh, a file that runs `set -uo pipefail` (no -e). The
# `set -e` switched errexit ON for the rest of the file, so the next assertion
# that expected rc=1 killed the script; build could not edit the authored test,
# so the iteration could never pass.
#
# L1 [change] a file whose header has no -e and later runs `set -e` is refused
# L2 [change] ...also `set -euo pipefail` mid-file
# L3 [guard]  a file that starts with -e may toggle it (set +e … set -e)
# L4 [guard]  `set +e` alone, or `set -o pipefail`, is fine
# L5 [guard]  the real tree passes
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "a test file never turns stop-on-error on mid-file (#2252 G)"
setup_test_env "lint-test-errexit"
LINT="$REPO_ROOT/scripts/lib/lint-test-errexit.sh"
T="$TEST_TEMP_DIR/tree/tests"; mkdir -p "$T"
_lint() { bash "$LINT" "$TEST_TEMP_DIR/tree" >/dev/null 2>&1; echo $?; }
_file() { printf '%s\n' "$@" > "$T/x-test.sh"; }

_file '#!/usr/bin/env bash' 'set -uo pipefail' 'set +e' 'cmd' 'set -e' 'assert'
assert_eq "[L1] no -e header, then set -e → refused" "1" "$(_lint)"
_file '#!/usr/bin/env bash' 'set -uo pipefail' 'set -euo pipefail'
assert_eq "[L2] ...set -euo pipefail mid-file → refused" "1" "$(_lint)"
_file '#!/usr/bin/env bash' 'set -euo pipefail' 'set +e' 'cmd' 'set -e'
assert_eq "[L3] an -e header may toggle it" "0" "$(_lint)"
_file '#!/usr/bin/env bash' 'set -uo pipefail' 'set +e' 'set -o pipefail'
assert_eq "[L4] set +e and set -o pipefail are fine" "0" "$(_lint)"
_real="$(bash "$LINT" 2>&1)"; _rc=$?
assert_eq "[L5] the real tree passes" "0" "$_rc"
[[ "$_rc" -eq 0 ]] || printf '%s\n' "$_real" >&2

cleanup_test_env
print_test_results
exit $((FAIL > 0))
