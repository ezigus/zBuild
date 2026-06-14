#!/usr/bin/env bash
# Unit: REC-1 (#879) — build emits a governed scope_expansion_request when it did
# valid IN-SCOPE work (verdict=pass) but the prior-assessment feedback names
# out-of-scope files the change still requires (the suite is red because of them).
# Without this, build converges "pass" with a red suite and the cycle loops.
#
# Covers the pure decision helper _build_pending_collateral_request and that its
# output is auto-grantable by the resolver for collateral, structural for source.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "unit: build OOS-pass scope request (REC-1 #879)"
setup_test_env "build-oos-pass-request-879"

# shellcheck source=../../plugins/agent/build/plugin.sh
source "$REPO_ROOT/plugins/agent/build/plugin.sh"

# Repo-relative fixtures (resolver + evidence check run with CWD = repo root).
mkdir -p "$TEST_TEMP_DIR/repo/tests/unit" "$TEST_TEMP_DIR/repo/core/router"
PINNED="tests/unit/pins-order-test.sh"
# shellcheck disable=SC2016  # literal must be written verbatim as the evidence token
printf 'assert_eq "_TPL_STAGES[2] is impact" "impact" "${_TPL_STAGES[2]}"\n' \
    > "$TEST_TEMP_DIR/repo/$PINNED"
SRC="core/router/route.sh"
printf 'echo route\n' > "$TEST_TEMP_DIR/repo/$SRC"
cd "$TEST_TEMP_DIR/repo" || exit 1

# Plan scope contains only the in-scope source file; the test + router are OOS.
PLAN_CSV="core/pipeline/template.sh"
# Feedback names the OOS test with a quoted token that's literally in the file.
FEEDBACK="$(printf 'test failed: %s asserts %s — update to the new order.\n' \
    "$PINNED" "'_TPL_STAGES[2] is impact'")"

# ─── T1: verdict=pass + OOS test in feedback → request emitted ───────────────
REQ="$(_build_pending_collateral_request "pass" "$FEEDBACK" "$PLAN_CSV")"
assert_eq "T1: request emitted (non-empty)" "1" "$([[ -n "$REQ" ]] && echo 1 || echo 0)"
assert_eq "T1: request names the OOS test" "$PINNED" \
    "$(jq -r '.files[] | select(.path=="'"$PINNED"'") | .path' <<<"$REQ" 2>/dev/null)"
assert_eq "T1: classified collateral_tests" "collateral_tests" \
    "$(jq -r '.files[] | select(.path=="'"$PINNED"'") | .category' <<<"$REQ" 2>/dev/null)"
assert_eq "T1: evidence = old token present in file" "_TPL_STAGES[2] is impact" \
    "$(jq -r '.files[] | select(.path=="'"$PINNED"'") | .evidence' <<<"$REQ" 2>/dev/null)"

# ─── T2: verdict != pass → no request (other branches own those paths) ───────
REQ2="$(_build_pending_collateral_request "scope_violation" "$FEEDBACK" "$PLAN_CSV")"
assert_eq "T2: verdict=scope_violation → empty" "" "$REQ2"
REQ2b="$(_build_pending_collateral_request "empty_diff" "$FEEDBACK" "$PLAN_CSV")"
assert_eq "T2b: verdict=empty_diff → empty (owned by Path A)" "" "$REQ2b"

# ─── T3: no OOS file named in feedback → no request ──────────────────────────
REQ3="$(_build_pending_collateral_request "pass" "all good, nothing to change" "$PLAN_CSV")"
assert_eq "T3: no OOS named → empty" "" "$REQ3"
# File already in plan scope → not OOS → no request.
REQ3b="$(_build_pending_collateral_request "pass" "see core/pipeline/template.sh" "$PLAN_CSV")"
assert_eq "T3b: in-scope file in feedback → empty" "" "$REQ3b"

# ─── T4: OOS SOURCE file → classified structural (resolver denies, not build) ─
FEEDBACK_SRC="$(printf 'also touch %s for the route change\n' "$SRC")"
REQ4="$(_build_pending_collateral_request "pass" "$FEEDBACK_SRC" "$PLAN_CSV")"
assert_eq "T4: source file classified structural" "structural" \
    "$(jq -r '.files[] | select(.path=="'"$SRC"'") | .category' <<<"$REQ4" 2>/dev/null)"

# ─── T5: emitted request is auto-grantable for collateral by the resolver ────
# shellcheck source=../../scripts/lib/scope-governance.sh
source "$REPO_ROOT/scripts/lib/scope-governance.sh"
DEC="$(scope_resolve_request "$REQ" "true" "collateral_tests,collateral_config" "structural")"
assert_eq "T5: collateral request resolves to grant" "grant" "$(jq -r '.action' <<<"$DEC")"
# And the source-only request escalates/denies (never auto-grants source).
DEC4="$(scope_resolve_request "$REQ4" "true" "collateral_tests,collateral_config" "none")"
assert_eq "T5b: source-only request does NOT grant" "deny" "$(jq -r '.action' <<<"$DEC4")"

cd "$REPO_ROOT" || exit 1
cleanup_test_env
print_test_results
exit $((FAIL > 0))
