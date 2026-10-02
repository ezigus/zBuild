#!/usr/bin/env bash
# tests/unit/pr-delivery-blocked-test.sh — when pr-open refuses to open a PR, the
# pr stage says so (#2250).
#
# Why: pr-open fails closed without a review signal (ADR-001): it writes
# `verdict: "blocked"` and returns 0. pr-delivery read only the exit code and
# wrote "pass — delivered the change"; the stage then died on a missing
# pr-url.txt, so the operator saw "pass" beside an unrelated-looking failure and
# the real cause lived only in an event (seen while reworking the parity fixture
# for #1842).
#
# P1 [change] pr-open blocked → the pr stage ends rc 1
# P2 [change] ...its summary says no PR was opened and names the reason
# P3 [change] ...and never says "delivered"
# P4 [guard]  pr-open opened the PR → pass / delivered, as before
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "the pr stage reports a refused PR as a refusal (#2250)"
setup_test_env "pr-delivery-blocked"
# shellcheck source=../../plugins/agent/pr-delivery/plugin.sh
source "$REPO_ROOT/plugins/agent/pr-delivery/plugin.sh"

# A stand-in pr-open: the plugin is re-sourced from _PR_ROOT on every call.
FAKE="$TEST_TEMP_DIR/root"; mkdir -p "$FAKE/plugins/tool/pr-open"
_fake_pr_open() {  # _fake_pr_open <verdict> <reason>
    cat > "$FAKE/plugins/tool/pr-open/plugin.sh" <<EOF
pr_open_run() {
    local d; d="\$(dirname "\$2")/artifacts"
    printf '{"result_contract":2,"verdict":"$1","disposition":"complete","reason":"$2"}\n' > "\$d/pr-result.json"
    [[ "$1" == pass ]] && printf 'https://example.test/pr/1\n' > "\$d/pr-url.txt"
    return 0
}
EOF
}
_PR_ROOT="$FAKE"
S="$TEST_TEMP_DIR/state"; mkdir -p "$S/artifacts"; printf '{}\n' > "$S/pipeline-state.json"
_summary() { cat "$S/artifacts/pr-delivery-summary.md" 2>/dev/null; }

print_test_section "P1-P3: pr-open refused"
_fake_pr_open blocked "no review signal — fail-closed per ADR-001"
_pr_stage_run_inner "$S/pipeline-state.json" >/dev/null 2>&1; rc=$?
assert_eq "[P1] the pr stage ends rc 1" "1" "$rc"
assert_contains "[P2] the summary says no PR was opened" "$(_summary)" "No PR was opened"
assert_contains "[P2] ...and names the reason" "$(_summary)" "no review signal"
if grep -qi 'delivered the change' <<< "$(_summary)"; then
    assert_fail "[P3] the summary never says delivered" "$(_summary)"
else
    assert_pass "[P3] the summary never says delivered"
fi

print_test_section "P4: pr-open opened the PR"
rm -f "$S/artifacts/pr-delivery-summary.md"
_fake_pr_open pass "opened"
_pr_stage_run_inner "$S/pipeline-state.json" >/dev/null 2>&1; rc=$?
assert_eq "[P4] rc 0" "0" "$rc"
assert_contains "[P4] ...pass / delivered" "$(_summary)" "delivered the change"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
