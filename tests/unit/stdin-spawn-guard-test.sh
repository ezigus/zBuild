#!/usr/bin/env bash
# tests/unit/stdin-spawn-guard-test.sh — #2108
# Every engine spawn that runs from inside a data-bearing `while read` loop
# (or under `set -m`, which drops bash's implicit </dev/null for `&` jobs)
# must not inherit the caller's stdin. The sites below are the ones #2108
# closed; each is pinned to its fix so a refactor cannot quietly reopen it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "guard: spawns never inherit a data-bearing stdin (#2108)"

_pin() {  # <label> <file> <grep-pattern-that-must-match>
    if grep -qE -- "$3" "$REPO_ROOT/$2"; then
        assert_pass "[#2108] $1"
    else
        assert_fail "[#2108] $1" "pattern not found in $2: $3"
    fi
}
_pin "the fresh shell closes stdin" scripts/lib/env-scrub.sh '^[[:space:]]*exec </dev/null'
_pin "negctl spawns under the fresh shell" scripts/lib/acceptance-negctl.sh '^[[:space:]]*_zbuild_make_fresh_shell'
_pin "reachability spawns under the fresh shell" scripts/lib/acceptance-reachability.sh '^[[:space:]]*_zbuild_make_fresh_shell'
_pin "spec-correspondence's model call closes stdin" plugins/agent/spec-correspondence/plugin.sh 'route_to_model "\$tier" "\$_framed" </dev/null'
_pin "build's false-completion guard spawns under the fresh shell" plugins/agent/build/lib/summary.sh '_zbuild_make_fresh_shell; .*bash "\$abs"'
_pin "the test stage's suite closes stdin under set -m" plugins/tool/test/plugin.sh 'eval "\$actual_test_cmd" </dev/null'
_pin "local_engine work units close stdin" core/orch/local_engine.sh 'bash "\$work_unit" </dev/null'
_pin "orch-sequential file work units close stdin" plugins/tool/orch-sequential/plugin.sh 'bash "\$work_unit" </dev/null'
_pin "orch-sequential inline work units close stdin" plugins/tool/orch-sequential/plugin.sh 'bash -c "\$work_unit" </dev/null'

print_test_results
exit $((FAIL > 0))
