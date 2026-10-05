#!/usr/bin/env bash
# tests/unit/no-guard-paths-test.sh — no guard path is left in engine code
# (#2304, ADR-069 §8).
#
# Why: the [guard] requirement status was retired. Its code paths — the guard
# half of the negative control, the design-gate's guard pre-check, the
# guard_regressed reason and event, the guard reader — cost about 7 engine fixes
# and caught no regression. A path that comes back unnoticed brings the old
# failure modes with it, so its names are refused in core/, scripts/ and
# plugins/ (tests excluded: they name the retired paths to prove they are gone).
#
# N1 [code] the scan finds a retired name planted in a tree (the scan is real)
# N2 [code] the real tree carries none of the retired names
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "no guard path is left in engine code (#2304)"
setup_test_env "no-guard-paths"
_test_cleanup_hook() { cleanup_test_env; }

_RETIRED='guard_regressed|_negctl_guard_|acceptance_spec_is_guard|guard_precheck'

# _scan <root> — every engine-code line naming a retired guard path, as file:line.
_scan() {
    local root="$1" d
    for d in core scripts plugins; do
        [[ -d "$root/$d" ]] || continue
        grep -rnE "$_RETIRED" "$root/$d" 2>/dev/null || true
    done | grep -v '/tests/' || true
}

print_test_section "N1: the scan finds a planted retired name"
F="$TEST_TEMP_DIR/tree"; mkdir -p "$F/scripts/lib" "$F/plugins/agent/x/tests"
printf 'acceptance_negctl_guard_precheck() { :; }\n' > "$F/scripts/lib/a.sh"
printf 'emit acceptance.gate.guard_regressed\n' > "$F/plugins/agent/x/tests/t-test.sh"
_hits="$(_scan "$F")"
assert_contains "[N1] a retired name in engine code is found" "$_hits" "scripts/lib/a.sh:1"
assert_eq "[N1] a plugin's own tests are not engine code" "0" "$(grep -c 'tests/t-test.sh' <<< "$_hits" || true)"

print_test_section "N2: the real tree has no guard path"
_hits="$(_scan "$REPO_ROOT")"
assert_eq "[N2] core/, scripts/ and plugins/ name no retired guard path" "" "$_hits"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
