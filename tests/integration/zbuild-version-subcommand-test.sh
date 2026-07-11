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

# ─── Test 3: a 4-part VERSION (ADR-048) surfaces via config/VERSION (#873) ────
# install.sh copies the repo VERSION to $ZBUILD_HOME/config/VERSION; simulate a
# 4-part A.B.C.D value and assert `zbuild version` prints it verbatim.
printf '1.0.3.42\n' > "$ZBUILD_HOME/config/VERSION"
out3="$(bash "$ZBUILD_HOME/scripts/zbuild" version 2>&1 || true)"
assert_contains "4-part VERSION surfaces in version output" "$out3" "zbuild 1.0.3.42"

# ─── Test 4: case-insensitive-FS metadata collision does NOT leak as semver ──
# Re-create the lowercase `version` metadata file (sha=...). On a case-insensitive
# FS $ZBUILD_HOME/VERSION and $ZBUILD_HOME/version are the same inode; the shape
# guard + config/VERSION-first probe must still print the real semver, never sha=.
cat > "$ZBUILD_HOME/version" <<VEOF2
sha=$FAKE_SHA
branch=$FAKE_BRANCH
installed_at=$FAKE_DATE
VEOF2
out4="$(bash "$ZBUILD_HOME/scripts/zbuild" version 2>&1 || true)"
assert_contains "semver line still 4-part (not sha=)" "$out4" "zbuild 1.0.3.42"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
