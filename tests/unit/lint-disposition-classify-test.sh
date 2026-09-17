#!/usr/bin/env bash
# tests/unit/lint-disposition-classify-test.sh — the manifest↔disposition guard
# (#1959, shipped in #2129). Mirrors lint-verdict-classify-test.sh (#1708): the
# manifest declares the failure classes a plugin can put on failures[]; the
# plugin's class→disposition table is the reader; the lint asserts they agree.
#
#   SPEC-1 [change]: a declared class the table does not know fails the lint,
#                    naming the manifest and the class
#   SPEC-2 [change]: a plugin that writes failures[] (`failures+=(` in its
#                    plugin.sh) must declare the key — absent is a failure
#   SPEC-3 [guard] : a plugin that never writes failures[] needs no key
#   SPEC-4 [change]: the shipped tree passes, and the lint is wired into
#                    `npm run lint` and CI
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "lint-disposition-classify — manifest failure classes are classified (#1959)"
setup_test_env "lint-disposition-classify"

CHECKER="$REPO_ROOT/scripts/lib/lint-disposition-classify.sh"

# _mk_plugin <dir> <writes:yes|no> [classes…|NONE]
_mk_plugin() {
    local dir="$1" writes="$2"; shift 2
    mkdir -p "$dir"
    {
        printf 'id: %s\nname: Fixture\nkind: tool\nversion: 0.1.0\n\nconfig:\n' "$(basename "$dir")"
        case "${1:-}" in
            NONE)  : ;;
            EMPTY) printf '  valid_failure_classes: []\n' ;;
            BARE)  printf '  valid_failure_classes:\n' ;;
            *)     printf '  valid_failure_classes:\n'; for c in "$@"; do printf '    - %s\n' "$c"; done ;;
        esac
        printf '  tier_default: T0\n'
    } > "$dir/manifest.yaml"
    if [[ "$writes" == yes ]]; then
        printf 'fx_run() { local -a failures=(); failures+=("tautology:SPEC-1"); }\n' > "$dir/plugin.sh"
    else
        printf 'fx_run() { :; }\n' > "$dir/plugin.sh"
    fi
}
_run_lint() { LINT_OUT="$(bash "$CHECKER" "$1" 2>&1)" && LINT_RC=0 || LINT_RC=$?; return 0; }

if [[ ! -f "$CHECKER" ]]; then
    assert_fail "[SPEC-1] scripts/lib/lint-disposition-classify.sh exists" "missing"
    print_test_results
    exit 1
fi

print_test_section "1. an unknown declared class fails, and says which"
R1="$TEST_TEMP_DIR/r1"
_mk_plugin "$R1/good" yes tautology no_testfile
_mk_plugin "$R1/bad"  yes tautology xyzzy_bogus
_run_lint "$R1"
assert_eq "[SPEC-1] lint exits 1 when a declared class is unknown to the table" "1" "$LINT_RC"
assert_contains "[SPEC-1] the failure names the class" "$LINT_OUT" "xyzzy_bogus"
assert_contains "[SPEC-1] the failure names the manifest" "$LINT_OUT" "bad/manifest.yaml"

print_test_section "2. a failures[] writer must declare the key"
R2="$TEST_TEMP_DIR/r2"
_mk_plugin "$R2/undeclared" yes NONE
_run_lint "$R2"
assert_eq "[SPEC-2] lint exits 1 when a failures[] writer declares nothing" "1" "$LINT_RC"
assert_contains "[SPEC-2] the failure names the manifest" "$LINT_OUT" "undeclared/manifest.yaml"

print_test_section "2b. an explicit empty declaration is valid (review: no phantom 'list' class)"
R2b="$TEST_TEMP_DIR/r2b"
_mk_plugin "$R2b/none-inline" yes EMPTY
_mk_plugin "$R2b/none-bare"   yes BARE
_run_lint "$R2b"
assert_eq "[SPEC-2b] valid_failure_classes: [] and a bare key both pass" "0" "$LINT_RC"
if grep -q "class 'list'" <<< "$LINT_OUT"; then
    assert_fail "[SPEC-2b] the word 'list' is never reported as a class" "$LINT_OUT"
else
    assert_pass "[SPEC-2b] the word 'list' is never reported as a class"
fi

print_test_section "3. a plugin that never writes failures[] is exempt"
R3="$TEST_TEMP_DIR/r3"
_mk_plugin "$R3/quiet" no NONE
_mk_plugin "$R3/fine"  yes tautology
_run_lint "$R3"
assert_eq "[SPEC-3] no failures[] write → no declaration needed" "0" "$LINT_RC"

print_test_section "4. the shipped tree passes and the lint is wired in"
_run_lint "$REPO_ROOT/plugins"
assert_eq "[SPEC-4] the shipped plugins/ tree passes" "0" "$LINT_RC"
assert_contains "[SPEC-4] wired into npm run lint" "$(cat "$REPO_ROOT/package.json")" "lint-disposition-classify.sh"
assert_contains "[SPEC-4] wired into CI" "$(cat "$REPO_ROOT/.github/workflows/test.yml")" "lint-disposition-classify.sh"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
