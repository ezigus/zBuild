#!/usr/bin/env bash
# tests/unit/lint-test-real-tree-test.sh — a test never runs a lint over the
# real checkout (#2615 R4, ADR-012): npm run lint does, once.
#
#   RT1 [code] a test that runs its lint with no root, or with the checkout, is
#              refused, naming the line
#   RT2 [code] a lint run on the test's own fixtures passes; a comment is not a run
#   RT3 [code] npm run lint runs this lint
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "lint-test-real-tree: no lint over the real checkout in a test (#2615)"
setup_test_env "lint-test-real-tree"
LINT_UNDER_TEST="$REPO_ROOT/scripts/lib/lint-test-real-tree.sh"
T="$TEST_TEMP_DIR/tree/tests/unit"; mkdir -p "$T"
_lint() { bash "$LINT_UNDER_TEST" "$TEST_TEMP_DIR/tree" 2>"$TEST_TEMP_DIR/err" >/dev/null; echo $?; }
_file() { printf '%s\n' "$@" > "$T/lint-x-test.sh"; }
# The fixture's command lines, built from parts so this file never holds one.
B='ba''sh'; L='"$LINT"'; R='"$REPO_ROOT"'; P='"$REPO_ROOT/scripts/lib/lint-y.sh"'

print_test_section "RT1: a run over the checkout"
_file '#!/usr/bin/env bash' 'LINT="$REPO_ROOT/scripts/lib/lint-x.sh"' "_rc=0; _out=\"\$($B $L $R 2>&1)\" || _rc=\$?"
assert_eq "[RT1] the checkout as its root → refused" "1" "$(_lint)"
assert_contains "[RT1] ...naming the file and line" "$(cat "$TEST_TEMP_DIR/err")" "tests/unit/lint-x-test.sh:3"
_file '#!/usr/bin/env bash' "_real=\"\$($B $L 2>&1)\"; _rc=\$?"
assert_eq "[RT1] no root (the lint's default is the checkout) → refused" "1" "$(_lint)"
_file '#!/usr/bin/env bash' "out=\"\$($B $P 2>&1)\""
assert_eq "[RT1] the lint named by its path, no root → refused" "1" "$(_lint)"

print_test_section "RT2: a run on the test's own fixtures"
_file '#!/usr/bin/env bash' "rc=0; $B $L \"\$TEST_TEMP_DIR/tree\" >/dev/null 2>&1 || rc=\$?" "# $B $L $R in a comment" "out=\"\$(ZBUILD_REPO_ROOT=\"\$FIX\" $B $P 2>&1)\""
assert_eq "[RT2] passes: its own root, a comment, a root set on the command" "0" "$(_lint)"
_file '#!/usr/bin/env bash' "ZBUILD_PLUGINS_ROOT=\"\$REPO_ROOT/plugins\" $B $P >/dev/null 2>&1"
assert_eq "[RT1] a root set on the command that is the checkout → refused" "1" "$(_lint)"

print_test_section "RT3: the lint step runs it"
assert_contains "[RT3] npm run lint runs lint-test-real-tree" "$(jq -r '.scripts.lint' "$REPO_ROOT/package.json")" "bash scripts/lib/lint-test-real-tree.sh"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
