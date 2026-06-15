#!/usr/bin/env bash
# Unit: REC-2 (#880) — build emits a governed scope_expansion_request for
# existing out-of-scope collateral it EDITED in a clean run, instead of silently
# reverting with no record. The caller reverts the file to HEAD first so the old
# value is present for the evidence check; created files take the #870 lane.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "unit: build edited-OOS scope request (REC-2 #880)"
setup_test_env "build-edited-oos-request-880"

# shellcheck source=../../plugins/agent/build/plugin.sh
source "$REPO_ROOT/plugins/agent/build/plugin.sh"

# Repo-relative fixtures (resolver/evidence run with CWD = repo root); files hold
# the OLD value (as if reverted to HEAD after build's edit).
mkdir -p "$TEST_TEMP_DIR/repo/tests/unit" "$TEST_TEMP_DIR/repo/config" "$TEST_TEMP_DIR/repo/core"
EDITED="tests/unit/pins-old-test.sh"
printf 'assert_eq "count" "%s" "$n"\n' "'8 stages'" > "$TEST_TEMP_DIR/repo/$EDITED"
CREATED="tests/unit/brand-new-test.sh"
printf 'assert "new"\n' > "$TEST_TEMP_DIR/repo/$CREATED"
SRC="core/route.sh"
printf 'echo route\n' > "$TEST_TEMP_DIR/repo/$SRC"
cd "$TEST_TEMP_DIR/repo" || exit 1

FEEDBACK="$(printf 'test failed: %s pins %s — update it.\n' "$EDITED" "'8 stages'")"

# ─── T1: edited collateral (in feedback) → request w/ evidence, collateral ───
REQ="$(_build_edited_collateral_request "$FEEDBACK" "" "$EDITED")"
assert_eq "T1: request emitted" "1" "$([[ -n "$REQ" ]] && echo 1 || echo 0)"
assert_eq "T1: classified collateral_tests" "collateral_tests" \
    "$(jq -r '.files[] | select(.path=="'"$EDITED"'") | .category' <<<"$REQ" 2>/dev/null)"
assert_eq "T1: evidence = old value present in file" "8 stages" \
    "$(jq -r '.files[] | select(.path=="'"$EDITED"'") | .evidence' <<<"$REQ" 2>/dev/null)"

# ─── T2: a CREATED file is excluded (it takes the #870 created lane) ──────────
# Both edited + created passed as the OOS set; created passed in the exclude list.
REQ2="$(_build_edited_collateral_request "$FEEDBACK" "$CREATED" "$(printf '%s\n%s\n' "$EDITED" "$CREATED")")"
has_created="$(jq -r '[.files[] | select(.path=="'"$CREATED"'")] | length' <<<"$REQ2" 2>/dev/null)"
assert_eq "T2: created file excluded from edited request" "0" "$has_created"
has_edited="$(jq -r '[.files[] | select(.path=="'"$EDITED"'")] | length' <<<"$REQ2" 2>/dev/null)"
assert_eq "T2: edited file still present" "1" "$has_edited"

# ─── T3: OOS source file → structural (resolver denies, not build) ───────────
REQ3="$(_build_edited_collateral_request "touch $SRC" "" "$SRC")"
assert_eq "T3: source classified structural" "structural" \
    "$(jq -r '.files[] | select(.path=="'"$SRC"'") | .category' <<<"$REQ3" 2>/dev/null)"

# ─── T4: no edited files (all created) → no request ──────────────────────────
REQ4="$(_build_edited_collateral_request "$FEEDBACK" "$CREATED" "$CREATED")"
assert_eq "T4: all-created → empty request" "" "$REQ4"

# ─── T5: emitted edited request is auto-grantable for collateral ─────────────
# shellcheck source=../../scripts/lib/scope-governance.sh
source "$REPO_ROOT/scripts/lib/scope-governance.sh"
DEC="$(scope_resolve_request "$REQ" "true" "collateral_tests,collateral_config" "structural")"
assert_eq "T5: edited collateral request resolves to grant" "grant" "$(jq -r '.action' <<<"$DEC")"
DEC3="$(scope_resolve_request "$REQ3" "true" "collateral_tests,collateral_config" "none")"
assert_eq "T5b: source-only edited request does NOT grant" "deny" "$(jq -r '.action' <<<"$DEC3")"

cd "$REPO_ROOT" || exit 1
cleanup_test_env
print_test_results
exit $((FAIL > 0))
