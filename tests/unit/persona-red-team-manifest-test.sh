#!/usr/bin/env bash
# tests/unit/persona-red-team-manifest-test.sh
# Unit tests for the red-team kind:persona manifest (issue #156-1-2).
# Exercises the live plugins/persona/red-team/manifest.yaml via the resolver.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"

print_test_header "red-team kind:persona manifest (issue #156-1-2)"

setup_test_env "persona-red-team-manifest"

REAL_PROOT="$REPO_ROOT/plugins"
REAL_MANIFEST="$REPO_ROOT/plugins/persona/red-team/manifest.yaml"

# SPEC-1: manifest is discoverable and resolves to the correct path
set +e
mf="$(find_persona red-team "$REAL_PROOT")"; rc=$?
set -e
assert_eq "[SPEC-1] find_persona returns 0 for red-team" "0" "$rc"
assert_contains "[SPEC-1] find_persona points at the red-team manifest" \
    "$mf" "plugins/persona/red-team/manifest.yaml"

# SPEC-2: role is 'a red-team operator'
assert_eq "[SPEC-2] resolve_persona_role returns 'a red-team operator'" \
    "a red-team operator" "$(resolve_persona_role red-team "$REAL_PROOT")"

# SPEC-3: perspective contains 'reviewer' (matches charters.sh red-team charter)
rt_perspective="$(resolve_persona_perspective red-team "$REAL_PROOT")"
case "$rt_perspective" in
    *reviewer*) persp_ok=1 ;;
    *) persp_ok=0 ;;
esac
assert_eq "[SPEC-3] perspective contains 'reviewer'" "1" "$persp_ok"

# SPEC-4: validate_manifest passes
set +e
validate_manifest "$REAL_MANIFEST" >/dev/null 2>&1; rc=$?
set -e
assert_eq "[SPEC-4] validate_manifest passes on red-team manifest" "0" "$rc"

# SPEC-5: persona_lens_framing composes a framing containing role + charter
charter="Find every exploitable flaw."
framing="$(persona_lens_framing red-team "$charter" "$REAL_PROOT")"
case "$framing" in
    *"red-team operator"*) role_ok=1 ;;
    *) role_ok=0 ;;
esac
assert_eq "[SPEC-5] lens framing contains 'red-team operator'" "1" "$role_ok"
case "$framing" in
    *"$charter"*) charter_ok=1 ;;
    *) charter_ok=0 ;;
esac
assert_eq "[SPEC-5] lens framing contains the supplied charter" "1" "$charter_ok"

# SPEC-6: manifest perspective is byte-identical to the charters.sh red-team charter
EXPECTED_CHARTER="Examine the change as a hostile reviewer looking for exploitable flaws: race conditions, privilege escalation paths, logic errors that can be triggered by adversarial input, and security assumptions that break under adversarial conditions."
actual_perspective="$(resolve_persona_perspective red-team "$REAL_PROOT")"
assert_eq "[SPEC-6] manifest perspective byte-identical to charters.sh red-team charter" \
    "$EXPECTED_CHARTER" "$actual_perspective"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
