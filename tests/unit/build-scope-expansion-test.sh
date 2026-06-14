#!/usr/bin/env bash
# Unit: build's scope_expansion_request emission (#840 / ADR-030).
# _build_scope_expansion_request derives a governed request from the
# out-of-scope files build is blocked on, with evidence = a quoted old-value
# from the test feedback that is present in the file.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "unit: build scope_expansion_request emission (#840)"
setup_test_env "build-scope-expansion-840"

# shellcheck source=../../plugins/agent/build/plugin.sh
source "$REPO_ROOT/plugins/agent/build/plugin.sh"

# Build a repo-relative fixture file that pins an old value.
mkdir -p "$TEST_TEMP_DIR/repo/tests/unit"
PINNED="tests/unit/pins-eight-test.sh"
printf 'assert_eq "still has 8 stages (#754)" "8" "${#_TPL_STAGES[@]}"\n' \
    > "$TEST_TEMP_DIR/repo/$PINNED"
cd "$TEST_TEMP_DIR/repo" || exit 1

# Feedback quotes the old value that's in the file.
FEEDBACK="$(printf 'core-pipeline... line 188 pins %s — change to %s.\n' \
    "'still has 8 stages (#754)'" "'12'")"

# ─── T1: request emitted with class + evidence ───────────────────────────
REQ="$(_build_scope_expansion_request "$PINNED" "$FEEDBACK")"
assert_eq "T1: request has 1 file" "1" "$(jq -r '.files | length' <<<"$REQ")"
assert_eq "T1: path" "$PINNED" "$(jq -r '.files[0].path' <<<"$REQ")"
assert_eq "T1: classified collateral_tests" "collateral_tests" "$(jq -r '.files[0].category' <<<"$REQ")"
assert_eq "T1: evidence = old value found in file" "still has 8 stages (#754)" "$(jq -r '.files[0].evidence' <<<"$REQ")"

# ─── T2: evidence empty when feedback shares no token with the file ──────
REQ2="$(_build_scope_expansion_request "$PINNED" "unrelated feedback with no quoted tokens")"
assert_eq "T2: still emits the file" "$PINNED" "$(jq -r '.files[0].path' <<<"$REQ2")"
assert_eq "T2: evidence empty (resolver will deny → clean abandon)" "" "$(jq -r '.files[0].evidence' <<<"$REQ2")"

# ─── T3: empty OOS list → no request ─────────────────────────────────────
REQ3="$(_build_scope_expansion_request "" "$FEEDBACK")"
assert_eq "T3: empty input → empty output" "" "$REQ3"

# ─── T4: end-to-end resolvability — the emitted request grants ───────────
# The whole point: a request emitted here must be auto-grantable by the
# resolver when the policy enables collateral_tests.
# shellcheck source=../../scripts/lib/scope-governance.sh
source "$REPO_ROOT/scripts/lib/scope-governance.sh"
DEC="$(scope_resolve_request "$REQ" "true" "collateral_tests" "structural")"
assert_eq "T4: emitted request resolves to grant" "grant" "$(jq -r '.action' <<<"$DEC")"

# ─── #870: created-collateral request emission ───────────────────────────
# Build CREATED a new golden + a new config + a source file this iter. The
# created-collateral request must include the two collateral files (created:true,
# empty evidence) and DROP the source file (structural, not auto-grantable).
mkdir -p "$TEST_TEMP_DIR/repo/tests/golden" "$TEST_TEMP_DIR/repo/config" "$TEST_TEMP_DIR/repo/core"
printf 'a\nb\n' > "$TEST_TEMP_DIR/repo/tests/golden/new.golden"
printf '{}\n'    > "$TEST_TEMP_DIR/repo/config/new.json"
printf 'x\n'     > "$TEST_TEMP_DIR/repo/core/new.sh"
CREQ="$(_build_created_collateral_request "tests/golden/new.golden" "core/new.sh" "config/new.json")"
assert_eq "T5: created request has 2 files (golden+config, source dropped)" "2" "$(jq -r '.files | length' <<<"$CREQ")"
assert_eq "T5: golden created:true" "true" "$(jq -r '.files[] | select(.path=="tests/golden/new.golden") | .created' <<<"$CREQ")"
assert_eq "T5: golden class collateral_tests" "collateral_tests" "$(jq -r '.files[] | select(.path=="tests/golden/new.golden") | .category' <<<"$CREQ")"
if jq -e '.files[] | select(.path=="core/new.sh")' <<<"$CREQ" >/dev/null 2>&1; then
    assert_fail "T5: source file must NOT be in created request"
else
    assert_pass "T5: source file dropped from created request"
fi
# T6: the created request resolves to GRANT (the dogfood case, end-to-end).
DEC="$(cd "$TEST_TEMP_DIR/repo" && scope_resolve_request "$CREQ" "true" "collateral_tests,collateral_config" "structural")"
assert_eq "T6: created-collateral request resolves to grant" "grant" "$(jq -r '.action' <<<"$DEC")"
# T7: all-source created files → no request emitted (nothing to grant).
CREQ2="$(_build_created_collateral_request "core/a.sh" "scripts/lib/b.sh")"
assert_eq "T7: all-source created → empty request" "" "$CREQ2"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
