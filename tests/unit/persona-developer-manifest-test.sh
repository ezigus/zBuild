#!/usr/bin/env bash
# tests/unit/persona-developer-manifest-test.sh
# Unit tests for the developer kind:persona manifest (issue #1391).
# Exercises the live plugins/persona/developer/manifest.yaml via the resolver.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"

print_test_header "developer kind:persona manifest (issue #1391)"

setup_test_env "persona-developer-manifest"

REAL_PROOT="$REPO_ROOT/plugins"
REAL_MANIFEST="$REPO_ROOT/plugins/persona/developer/manifest.yaml"

# SPEC-1: manifest is discoverable and resolves to the correct path
set +e
mf="$(find_persona developer "$REAL_PROOT")"; rc=$?
set -e
assert_eq "[SPEC-1] find_persona returns 0 for developer" "0" "$rc"
assert_contains "[SPEC-1] find_persona points at the developer manifest" \
    "$mf" "plugins/persona/developer/manifest.yaml"

# SPEC-2: role is 'a software engineer'
assert_eq "[SPEC-2] resolve_persona_role returns 'a software engineer'" \
    "a software engineer" "$(resolve_persona_role developer "$REAL_PROOT")"

# SPEC-3: perspective contains 'correctness'
dev_perspective="$(resolve_persona_perspective developer "$REAL_PROOT")"
case "$dev_perspective" in
    *correctness*) persp_ok=1 ;;
    *) persp_ok=0 ;;
esac
assert_eq "[SPEC-3] perspective contains 'correctness'" "1" "$persp_ok"

# SPEC-4: validate_manifest passes
set +e
validate_manifest "$REAL_MANIFEST" >/dev/null 2>&1; rc=$?
set -e
assert_eq "[SPEC-4] validate_manifest passes on developer manifest" "0" "$rc"

# SPEC-5: persona_stage_framing leads with perspective + task
task_intro="Build the implementation."
framing="$(persona_stage_framing developer "$task_intro" "$REAL_PROOT")"
case "$framing" in
    *correctness*) persp_ok=1 ;;
    *) persp_ok=0 ;;
esac
assert_eq "[SPEC-5] persona_stage_framing leads with perspective + task: perspective contains 'correctness'" "1" "$persp_ok"
case "$framing" in
    *"$task_intro"*) intro_ok=1 ;;
    *) intro_ok=0 ;;
esac
assert_eq "[SPEC-5] stage framing contains the supplied task_intro" "1" "$intro_ok"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
