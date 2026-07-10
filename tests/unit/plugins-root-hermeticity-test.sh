#!/usr/bin/env bash
# tests/unit/plugins-root-hermeticity-test.sh
# #1274: static guard — ZBUILD_PLUGINS_ROOT must NEVER be captured or
# re-exported inside plugins/tool/test/plugin.sh. The three re-exported
# vars in the test-stage fence set are ZBUILD_STATE_ROOT, ZBUILD_COST_LEDGER,
# ZBUILD_CACHE_DIR (and ZBUILD_TEST_TIMING_FILE / optionally
# ZBUILD_TEST_RESULTS_JSON). ZBUILD_PLUGINS_ROOT is intentionally absent:
# leaking a test-run's mock plugins root into the nested runner would resolve
# plugins from the mock tree, not the real installed tree — the same env-leak
# bug class that motivated ADR-024.
#
# SPEC-1 [guard]: scanner precondition — /usr/bin/grep must be executable;
#   a broken scanner returns a false GREEN and is itself a test failure.
# SPEC-2 [guard]: ZBUILD_PLUGINS_ROOT does not appear anywhere in
#   plugins/tool/test/plugin.sh; if it does, the invariant is broken.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

# The repo's default `grep` may be ugrep with ERE quirks; use the system
# grep for deterministic matching in a guard scan.
GREP=/usr/bin/grep

print_test_header "plugins-root hermeticity — ZBUILD_PLUGINS_ROOT never captured/re-exported in test plugin (#1274)"

# SPEC-1 [guard]: a safety guard must NEVER pass vacuously. If /usr/bin/grep
# is missing or not executable every scan would silently succeed, and the
# guard would report a false GREEN. Assert the tool up front and FAIL loudly
# instead — a broken scanner is a test failure, not a pass.
if [[ ! -x "$GREP" ]]; then
    assert_fail "[SPEC-1] scanner precondition: $GREP is executable" \
        "the hermeticity scan requires an executable $GREP; refusing to scan-and-pass vacuously"
    print_test_results
fi

assert_pass "[SPEC-1] scanner precondition: $GREP is executable"

# Target file: the test-stage plugin fence where ZBUILD_PLUGINS_ROOT must
# never appear.
_target="$REPO_ROOT/plugins/tool/test/plugin.sh"

# SPEC-2 [guard]: scan for any occurrence of the token ZBUILD_PLUGINS_ROOT
# (bare assignment, export, or reference) in the target file.
if "$GREP" -qE 'ZBUILD_PLUGINS_ROOT' "$_target" 2>/dev/null; then
    _offending_lines="$("$GREP" -nE 'ZBUILD_PLUGINS_ROOT' "$_target" 2>/dev/null || true)"
    printf '  offending lines in %s:\n' "${_target#"$REPO_ROOT/"}" >&2
    printf '    %s\n' "$_offending_lines" >&2
    assert_fail "[SPEC-2] ZBUILD_PLUGINS_ROOT does not appear in plugins/tool/test/plugin.sh" \
        "found ZBUILD_PLUGINS_ROOT reference(s) — this var must not enter the test-stage fence (ADR-024, #1274)"
else
    assert_pass "[SPEC-2] ZBUILD_PLUGINS_ROOT does not appear in plugins/tool/test/plugin.sh"
fi

print_test_results
