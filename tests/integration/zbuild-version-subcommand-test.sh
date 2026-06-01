#!/usr/bin/env bash
# Tests: `zbuild version` reads $ZBUILD_HOME/version (issue #595, ADR-023).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "zbuild version subcommand reads ZBUILD_HOME/version (#595)"

setup_test_env "zbuild-version-subcommand"

# Simulate an installed tree: copy scripts/ + core/ + plugins/ + config/ into
# a fake ZBUILD_HOME and hand-write a version file.
export ZBUILD_HOME="$TEST_TEMP_DIR/zhome"
mkdir -p "$ZBUILD_HOME"
for d in scripts core plugins config; do
    cp -R "$REPO_ROOT/$d" "$ZBUILD_HOME/$d"
done

FAKE_SHA="deadbeefcafe1234567890abcdef1234567890ab"
FAKE_BRANCH="fixture-branch"
FAKE_DATE="2026-05-31T12:34:56Z"
cat > "$ZBUILD_HOME/version" <<VEOF
sha=$FAKE_SHA
branch=$FAKE_BRANCH
installed_at=$FAKE_DATE
VEOF

# ─── Test 1: version prints SHA + branch + date from version file ────────────
out="$(bash "$ZBUILD_HOME/scripts/zbuild" version 2>&1)" \
    || { echo "$out"; assert_fail "zbuild version exits 0"; exit 1; }
assert_pass "zbuild version exits 0"
assert_contains "version output contains SHA" "$out" "$FAKE_SHA"
assert_contains "version output contains branch" "$out" "$FAKE_BRANCH"
assert_contains "version output contains install date" "$out" "$FAKE_DATE"

# ─── Test 2: missing version file → graceful fallback notice ─────────────────
rm "$ZBUILD_HOME/version"
out2="$(bash "$ZBUILD_HOME/scripts/zbuild" version 2>&1 || true)"
assert_contains "missing version file → notice about re-running install" \
    "$out2" "install"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
