#!/usr/bin/env bash
# Tests: build post-LLM no-progress diagnostic (#792).
#
# Contract (the POST-LLM signal, NOT pre-LLM gate):
# When all three hold at build_summary-write time:
#   1. terminated_reason == done_sentinel  (LLM emitted LOOP_COMPLETE normally)
#   2. files_changed_count == 0            (empty diff — no actual edits)
#   3. _feedback_body contains paths NOT in plan.files[]
# Then build-summary.json carries:
#   verdict: "empty_diff"        (existing — this is the empty-diff path)
#   reason: "no_progress_scope_blocked"
#   out_of_scope_files: [...]
#
# Build STILL ran the LLM with prior_test_assessment in the prompt — this
# is a diagnostic, not a short-circuit. The feedback contract is preserved.
#
# Pinned assertions:
#   T1: _build_detect_out_of_scope_files returns paths in feedback NOT in plan
#   T2: returns empty when all paths in scope
#   T3: returns empty when feedback empty
#   T4: heuristic excludes path:NNN line citations (not change-requests)
#   T5: works under set -euo pipefail
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "build post-LLM no-progress diagnostic helper (#792)"

# Stub plugin bootstrap before sourcing.
zbuild_plugin_bootstrap() { _ZBUILD_PLUGIN_DIR="$REPO_ROOT/plugins/agent/build"; _ZBUILD_PLUGIN_ROOT="$REPO_ROOT"; }
emit_event() { return 0; }

# shellcheck source=../../plugins/agent/build/plugin.sh
source "$REPO_ROOT/plugins/agent/build/plugin.sh"

# T1: out-of-scope paths returned.
fb='## Failures
Update tests/integration/runner-test.sh (line 42)
Also fix tests/golden/foo/event.golden — missing event'
plan_csv="plugins/agent/foo.sh,config/templates/simple.yaml"
out="$(_build_detect_out_of_scope_files "$fb" "$plan_csv" | sort | tr '\n' ',')"
case "$out" in
    *"tests/integration/runner-test.sh"*)
        assert_pass "T1: runner-test.sh detected as out-of-scope" ;;
    *)
        assert_fail "T1: missing runner-test.sh: $out" ;;
esac
case "$out" in
    *"tests/golden/foo/event.golden"*)
        assert_pass "T1: golden detected as out-of-scope" ;;
    *)
        assert_fail "T1: missing golden: $out" ;;
esac

# T2: in-scope paths return empty.
fb='Update tests/foo.sh — needs a fix'
plan_csv="tests/foo.sh"
out="$(_build_detect_out_of_scope_files "$fb" "$plan_csv")"
assert_eq "T2: in-scope path → empty result" "" "$out"

# T3: empty feedback → empty result.
out="$(_build_detect_out_of_scope_files "" "tests/foo.sh")"
assert_eq "T3: empty feedback → empty result" "" "$out"

# T4: path:NNN line citations are filtered (not change-requests).
# Without this, `at plugins/agent/build/plugin.sh:136` would be flagged.
fb='See emit_event call at plugins/agent/build/plugin.sh:136 for the wiring'
plan_csv="tests/foo.sh"
out="$(_build_detect_out_of_scope_files "$fb" "$plan_csv")"
case "$out" in
    *"plugins/agent/build/plugin.sh"*)
        assert_fail "T4: path:NNN citation should NOT be flagged: $out" ;;
    *)
        assert_pass "T4: path:NNN citation filtered out" ;;
esac

# T5: set -euo pipefail safety with zero matches.
set +e
out="$(_build_detect_out_of_scope_files "" "" ; echo "RC=$?")"
set -e
case "$out" in
    *"RC=0"*) assert_pass "T5: rc=0 under set -e with no matches" ;;
    *) assert_fail "T5: expected rc=0: $out" ;;
esac

# T6: mixed in-scope + out-of-scope.
fb='Update tests/in.sh and tests/out.sh together'
plan_csv="tests/in.sh"
out="$(_build_detect_out_of_scope_files "$fb" "$plan_csv" | sort | tr '\n' ',')"
case "$out" in
    *"tests/out.sh"*) assert_pass "T6: out-of-scope path returned" ;;
    *) assert_fail "T6: missing out.sh: $out" ;;
esac
case "$out" in
    *"tests/in.sh"*) assert_fail "T6: in-scope must NOT be returned: $out" ;;
    *) assert_pass "T6: in-scope path filtered out" ;;
esac

print_test_results
exit $((FAIL > 0))
