#!/usr/bin/env bash
# tests/unit/persona-sre-manifest-test.sh
# SPEC-1..5: SRE persona manifest — discover, role, perspective, validate, framing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"

print_test_header "SRE persona manifest (plugins/persona/sre, issue #1517)"

setup_test_env "persona-sre-manifest"

REAL_PROOT="$REPO_ROOT/plugins"

# ─── SPEC-1: find_persona resolves 'sre' to the live manifest path ───────────
set +e
sre_mf="$(find_persona sre "$REAL_PROOT")"; rc=$?
set -e
assert_eq "[SPEC-1] find_persona returns 0 for id 'sre'" "0" "$rc"
assert_contains "[SPEC-1] find_persona points at plugins/persona/sre/manifest.yaml" \
    "$sre_mf" "plugins/persona/sre/manifest.yaml"

# ─── SPEC-2: role is exactly 'a site-reliability engineer' ───────────────────
assert_eq "[SPEC-2] resolve_persona_role returns 'a site-reliability engineer'" \
    "a site-reliability engineer" "$(resolve_persona_role sre "$REAL_PROOT")"

# ─── SPEC-3: perspective contains a production-framing keyword ───────────────
sre_perspective="$(resolve_persona_perspective sre "$REAL_PROOT")"
case "$sre_perspective" in
    *production*) sre_persp_ok=1 ;;
    *failure*)    sre_persp_ok=1 ;;
    *)            sre_persp_ok=0 ;;
esac
assert_eq "[SPEC-3] sre perspective contains 'production' or 'failure'" "1" "$sre_persp_ok"

# ─── SPEC-4: validate_manifest passes on the sre manifest ────────────────────
set +e
validate_manifest "$sre_mf" >/dev/null 2>&1; rc=$?
set -e
assert_eq "[SPEC-4] validate_manifest passes on the sre manifest" "0" "$rc"

# ─── SPEC-5: persona_lens_framing composes role and supplied charter ──────────
sre_framing="$(persona_lens_framing sre "Check for missing SLO coverage." "$REAL_PROOT")"
case "$sre_framing" in
    *"site-reliability engineer"*) sre_role_ok=1 ;;
    *) sre_role_ok=0 ;;
esac
assert_eq "[SPEC-5] lens framing contains 'site-reliability engineer'" "1" "$sre_role_ok"
case "$sre_framing" in
    *"Check for missing SLO coverage."*) sre_charter_ok=1 ;;
    *) sre_charter_ok=0 ;;
esac
assert_eq "[SPEC-5] lens framing contains the supplied charter" "1" "$sre_charter_ok"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
