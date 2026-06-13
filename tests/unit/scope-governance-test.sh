#!/usr/bin/env bash
# Unit: scripts/lib/scope-governance.sh — the testable core of governed scope
# expansion (#840). Covers the security floor (hard, non-bypassable), the
# collateral path-class detector, the evidence check, and the pure request
# resolver (grant/escalate/deny).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "unit: scope-governance — floor + detector + resolver (#840)"
setup_test_env "scope-governance-840"

# shellcheck source=../../scripts/lib/scope-governance.sh
source "$REPO_ROOT/scripts/lib/scope-governance.sh"

# ─── Security floor (hard) ───────────────────────────────────────────────
# scope_floor_denied <path> → rc 0 = DENIED (on floor), rc 1 = past floor.
for p in legacy/scripts/lib/pipeline-intelligence.sh legacy/anything.sh \
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
for p in tests/unit/foo-test.sh config/templates/standard.yaml docs/KEEPERS.md \
         core/pipeline/runner.sh scripts/lib/helpers.sh; do
    if scope_floor_denied "$p"; then
        assert_fail "floor should ALLOW '$p'" "got: denied"
    else
        assert_pass "floor ALLOWS '$p'"
    fi
done

# ─── Collateral class detector (path-shape only) ─────────────────────────
assert_eq "test path → collateral_tests" "collateral_tests" \
    "$(scope_collateral_class tests/unit/core-pipeline-template-cycles-test.sh)"
assert_eq "integration test → collateral_tests" "collateral_tests" \
    "$(scope_collateral_class tests/integration/runner-job-control-regression-test.sh)"
assert_eq "golden → collateral_tests" "collateral_tests" \
    "$(scope_collateral_class tests/golden/full-pipeline/event-sequence.golden)"
assert_eq "config → collateral_config" "collateral_config" \
    "$(scope_collateral_class config/event-schema.json)"
assert_eq "docs md → collateral_docs" "collateral_docs" \
    "$(scope_collateral_class docs/adr/ADR-013.md)"
assert_eq "core source → structural" "structural" \
    "$(scope_collateral_class core/pipeline/template.sh)"
assert_eq "scripts/lib → structural" "structural" \
    "$(scope_collateral_class scripts/lib/helpers.sh)"

# ─── Evidence check ──────────────────────────────────────────────────────
EVF="$TEST_TEMP_DIR/pins-eight.sh"
printf 'assert_eq "still has 8 stages" "8" "${#_TPL_STAGES[@]}"\n' > "$EVF"
if scope_evidence_present "$EVF" '8 stages'; then
    assert_pass "evidence present → rc 0"
else
    assert_fail "evidence '8 stages' should be found in file"
fi
if scope_evidence_present "$EVF" 'totally-unrelated-token-xyz'; then
    assert_fail "absent evidence should not be found"
else
    assert_pass "absent evidence → rc 1"
fi

# ─── Resolver: grant ─────────────────────────────────────────────────────
# Build emits REPO-RELATIVE paths; the resolver runs with CWD=repo root. We
# emulate that by cd-ing into a temp "repo" and using a relative path.
mkdir -p "$TEST_TEMP_DIR/repo/tests/unit"
printf 'pins literal 8 here\n' > "$TEST_TEMP_DIR/repo/tests/unit/some-test.sh"
GRANT_REL="tests/unit/some-test.sh"
pushd "$TEST_TEMP_DIR/repo" >/dev/null || exit 1
REQ_GRANT="$(jq -nc --arg p "$GRANT_REL" '{files:[{path:$p, category:"collateral_tests", evidence:"literal 8", reason:"pins old count"}]}')"
DEC="$(scope_resolve_request "$REQ_GRANT" "true" "collateral_tests,collateral_config" "structural")"
assert_eq "grant: action=grant" "grant" "$(jq -r '.action' <<<"$DEC")"
assert_eq "grant: granted file present" "$GRANT_REL" "$(jq -r '.granted[0]' <<<"$DEC")"
popd >/dev/null || exit 1

# ─── Resolver: deny when expandable=false ────────────────────────────────
pushd "$TEST_TEMP_DIR/repo" >/dev/null || exit 1
DEC="$(scope_resolve_request "$REQ_GRANT" "false" "collateral_tests" "structural")"
assert_eq "expandable=false → deny" "deny" "$(jq -r '.action' <<<"$DEC")"

# ─── Resolver: deny when class not enabled ───────────────────────────────
DEC="$(scope_resolve_request "$REQ_GRANT" "true" "collateral_config" "none")"
assert_eq "class not in auto_grant → deny" "deny" "$(jq -r '.action' <<<"$DEC")"

# ─── Resolver: deny when evidence absent (no blind trust) ────────────────
REQ_NOEV="$(jq -nc --arg p "$GRANT_REL" '{files:[{path:$p, category:"collateral_tests", evidence:"NOT-IN-FILE", reason:"x"}]}')"
DEC="$(scope_resolve_request "$REQ_NOEV" "true" "collateral_tests" "structural")"
assert_eq "evidence absent → deny" "deny" "$(jq -r '.action' <<<"$DEC")"
popd >/dev/null || exit 1

# ─── Resolver: floor beats everything ────────────────────────────────────
REQ_FLOOR="$(jq -nc '{files:[{path:"legacy/x.sh", category:"collateral_tests", evidence:"x", reason:"x"}]}')"
DEC="$(scope_resolve_request "$REQ_FLOOR" "true" "collateral_tests" "structural")"
assert_eq "floor path → deny regardless of policy" "deny" "$(jq -r '.action' <<<"$DEC")"

# ─── Resolver: escalate structural ───────────────────────────────────────
STRUCT_FILE="$TEST_TEMP_DIR/core-thing.sh"; printf 'token-abc\n' > "$STRUCT_FILE"
REQ_STRUCT="$(jq -nc --arg p "core/pipeline/template.sh" '{files:[{path:$p, category:"structural", evidence:"", reason:"need core"}]}')"
DEC="$(scope_resolve_request "$REQ_STRUCT" "true" "collateral_tests" "structural")"
assert_eq "structural + escalate=structural → escalate" "escalate" "$(jq -r '.action' <<<"$DEC")"

# structural with escalate=none → deny
DEC="$(scope_resolve_request "$REQ_STRUCT" "true" "collateral_tests" "none")"
assert_eq "structural + escalate=none → deny" "deny" "$(jq -r '.action' <<<"$DEC")"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
