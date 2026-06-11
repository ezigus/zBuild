#!/usr/bin/env bash
# Tests: plugins/agent/build _build_detect_scope_mismatch (#784).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "build _build_detect_scope_mismatch (#784)"

# Bootstrap stubs before sourcing plugin.
zbuild_plugin_bootstrap() { _ZBUILD_PLUGIN_DIR="$REPO_ROOT/plugins/agent/build"; _ZBUILD_PLUGIN_ROOT="$REPO_ROOT"; }
emit_event() { return 0; }
# shellcheck source=../../plugins/agent/build/plugin.sh
source "$REPO_ROOT/plugins/agent/build/plugin.sh"

# T1: feedback names paths NOT in plan → returns them
fb='Update `tests/integration/runner-test.sh` and `tests/golden/foo/event.golden` here'
plan_csv="plugins/agent/foo.sh,config/templates/standard.yaml"
out="$(_build_detect_scope_mismatch "$fb" "$plan_csv" | sort | tr '\n' ',')"
case "$out" in
    *"tests/integration/runner-test.sh"*)
        assert_pass "T1: detects out-of-scope tests/integration path" ;;
    *)
        assert_fail "T1: missing runner-test.sh: $out" ;;
esac
case "$out" in
    *"tests/golden/foo/event.golden"*)
        assert_pass "T1: detects out-of-scope golden file" ;;
    *)
        assert_fail "T1: missing golden: $out" ;;
esac

# T2: feedback names paths IN plan → returns empty
fb='Update tests/foo.sh which is in scope'
plan_csv="tests/foo.sh,plugins/agent/foo.sh"
out="$(_build_detect_scope_mismatch "$fb" "$plan_csv")"
assert_eq "T2: in-scope path → empty result" "" "$out"

# T3: empty feedback → empty result
out="$(_build_detect_scope_mismatch "" "tests/foo.sh")"
assert_eq "T3: empty feedback → empty result" "" "$out"

# T4: empty plan_files_csv → empty result (no comparison possible)
out="$(_build_detect_scope_mismatch "Update tests/foo.sh" "")"
assert_eq "T4: empty plan_files_csv → empty result" "" "$out"

# T5: mixed in-scope + out-of-scope → returns only out-of-scope
fb='Touch tests/in-scope.sh and tests/out-of-scope.sh together'
plan_csv="tests/in-scope.sh,plugins/agent/foo.sh"
out="$(_build_detect_scope_mismatch "$fb" "$plan_csv" | sort | tr '\n' ',')"
case "$out" in
    *"tests/out-of-scope.sh"*) assert_pass "T5: out-of-scope path returned" ;;
    *) assert_fail "T5: missing out-of-scope.sh: $out" ;;
esac
case "$out" in
    *"tests/in-scope.sh"*) assert_fail "T5: in-scope must NOT be returned: $out" ;;
    *) assert_pass "T5: in-scope path filtered out" ;;
esac

# T6: heuristic ignores non-zbuild paths (e.g. /usr/, https://)
fb='See /usr/bin/foo or https://example.com/x.sh'
out="$(_build_detect_scope_mismatch "$fb" "tests/foo.sh")"
assert_eq "T6: non-repo paths ignored" "" "$out"

# T7: works under set -euo pipefail (no rc leakage)
set +e
out="$(_build_detect_scope_mismatch "" "" ; echo "RC=$?")"
set -e
case "$out" in
    *"RC=0"*) assert_pass "T7: rc=0 under set -e" ;;
    *) assert_fail "T7: expected rc=0: $out" ;;
esac

print_test_results
exit $((FAIL > 0))
