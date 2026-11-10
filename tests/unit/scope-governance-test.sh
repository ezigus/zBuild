#!/usr/bin/env bash
# Unit: scripts/lib/scope-governance.sh — the security floor (#840, ADR-030
# Layer 1): hard, non-bypassable. #2508 (ADR-030 §8): the collateral classes,
# the evidence check and the request resolver are gone with build's file list.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "unit: scope-governance — the security floor (#840)"
setup_test_env "scope-governance-840"

# shellcheck source=../../scripts/lib/scope-governance.sh
source "$REPO_ROOT/scripts/lib/scope-governance.sh"

# ─── Security floor (hard) ───────────────────────────────────────────────
# scope_floor_denied <path> → rc 0 = DENIED (on floor), rc 1 = past floor.
for p in legacy-DoNotUse/scripts/lib/pipeline-intelligence.sh legacy-DoNotUse/anything.sh legacy-DoNotUse \
         .env config/.env secrets/key.pem deploy/credentials.json; do
    if scope_floor_denied "$p"; then
        assert_pass "floor DENIES '$p'"
    else
        assert_fail "floor should DENY '$p'" "got: allowed"
    fi
done
# Absolute + repo-escape paths are denied.
for p in /etc/passwd ../outside/file.sh /Users/x/secret; do
    if scope_floor_denied "$p"; then
        assert_pass "floor DENIES out-of-repo '$p'"
    else
        assert_fail "floor should DENY out-of-repo '$p'" "got: allowed"
    fi
done
# Normal repo paths pass the floor.
for p in tests/unit/foo-test.sh config/templates/simple.yaml docs/KEEPERS.md \
         core/pipeline/runner.sh scripts/lib/helpers.sh; do
    if scope_floor_denied "$p"; then
        assert_fail "floor should ALLOW '$p'" "got: denied"
    else
        assert_pass "floor ALLOWS '$p'"
    fi
done

cleanup_test_env
print_test_results
exit $((FAIL > 0))
