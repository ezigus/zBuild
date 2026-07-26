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

# ─── SPEC-2 (issue #1573): persona_lens_framing removed from persona.sh ─────
set +e
declare -F persona_lens_framing >/dev/null 2>&1; plf_defined_rc=$?
set -e
assert_eq "[SPEC-2] persona_lens_framing is not defined after sourcing the registry" "1" "$plf_defined_rc"

# SPEC-6: manifest perspective is byte-identical to the charters.sh red-team
# CASE-STATEMENT fallback — the invariant that removing the manifest would not
# change the lens charter (data-driven parity, #1457). Derive the expected text
# from charters.sh itself (not a hardcoded copy) so drift in EITHER file breaks
# this test: force the persona-registry lookup to miss so _rl_lens_charter
# returns its built-in fallback, then compare to the manifest-resolved value.
# shellcheck source=../../plugins/agent/review-lens/lib/charters.sh
source "$REPO_ROOT/plugins/agent/review-lens/lib/charters.sh"
resolve_persona_charter() { return 1; }  # force the case-statement fallback path
expected_charter="$(_rl_lens_charter red-team)"
assert_eq "[SPEC-6] manifest perspective byte-identical to charters.sh red-team charter" \
    "$expected_charter" "$rt_perspective"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
