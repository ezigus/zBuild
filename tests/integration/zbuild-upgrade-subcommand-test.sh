#!/usr/bin/env bash
# Tests: `zbuild upgrade --from <dir>` re-runs install from a source clone
# (issue #595, ADR-023).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "zbuild upgrade subcommand re-runs install (#595)"

setup_test_env "zbuild-upgrade-subcommand"

# Build a sandbox source clone with install.sh
SANDBOX_SRC="$TEST_TEMP_DIR/src"
mkdir -p "$SANDBOX_SRC"
for d in scripts core plugins config; do
    cp -R "$REPO_ROOT/$d" "$SANDBOX_SRC/$d"
done
cp "$REPO_ROOT/install.sh" "$SANDBOX_SRC/install.sh"
(
    cd "$SANDBOX_SRC"
    git init -q -b upgrade-branch
    git -c user.email=t@t -c user.name=t add -A
    git -c user.email=t@t -c user.name=t commit -q -m "fixture"
)

# Initial install
export ZBUILD_HOME="$TEST_TEMP_DIR/zhome"
export ZBUILD_INSTALL_DIR="$TEST_TEMP_DIR/bin-install"
mkdir -p "$ZBUILD_INSTALL_DIR"
bash "$SANDBOX_SRC/install.sh" >/dev/null 2>&1 \
    || { assert_fail "initial install succeeded"; exit 1; }
assert_pass "initial install succeeded"

# ─── Test 1: upgrade requires --from when not in a source clone ──────────────
out_norun="$(cd "$TEST_TEMP_DIR" && bash "$ZBUILD_HOME/scripts/zbuild" upgrade 2>&1 || true)"
assert_contains "upgrade without --from prints a hint about --from" "$out_norun" "--from"

# ─── Test 2: upgrade --from <dir> re-runs install ─────────────────────────────
# Capture the original version file, mutate source clone, upgrade, observe
# version file changes.
orig_version="$(cat "$ZBUILD_HOME/version")"

(
    cd "$SANDBOX_SRC"
    echo "# bump $(date +%s%N)" >> scripts/zbuild
    git -c user.email=t@t -c user.name=t commit -q -am "bump"
)
new_sha="$(cd "$SANDBOX_SRC" && git rev-parse HEAD)"

out_upgrade="$(bash "$ZBUILD_HOME/scripts/zbuild" upgrade --from "$SANDBOX_SRC" 2>&1)" \
    || { echo "$out_upgrade"; assert_fail "upgrade --from exits 0"; exit 1; }
assert_pass "upgrade --from exits 0"

new_version="$(cat "$ZBUILD_HOME/version")"
if [[ "$orig_version" == "$new_version" ]]; then
    assert_fail "version file should change after upgrade" "still: $new_version"
else
    assert_pass "version file changed after upgrade"
fi
assert_contains "new version contains new SHA" "$new_version" "$new_sha"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
