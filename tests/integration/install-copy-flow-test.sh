#!/usr/bin/env bash
# Tests: install.sh copies pipeline tree into $ZBUILD_HOME (issue #595, ADR-023).
# Covers: rsync of scripts/core/plugins/config, shim creation, version file,
# migration from symlink, branch-isolation invariant.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "install.sh copy flow + ZBUILD_HOME isolation (#595)"

setup_test_env "install-copy-flow"

# Carve out a sandbox source clone so the live REPO_ROOT is never mutated by
# install.sh (it shouldn't be — but defense in depth, and the branch-isolation
# test below intentionally rewrites the sandbox clone).
SANDBOX_SRC="$TEST_TEMP_DIR/src"
mkdir -p "$SANDBOX_SRC"
# Only copy what install.sh needs; keep this cheap.
for d in scripts core plugins config; do
    cp -R "$REPO_ROOT/$d" "$SANDBOX_SRC/$d"
done
cp "$REPO_ROOT/install.sh" "$SANDBOX_SRC/install.sh"

# Pretend the sandbox is a git clone on branch `sandbox-branch` at a known SHA.
# install.sh reads HEAD via git rev-parse, so we need a real repo here.
(
    cd "$SANDBOX_SRC"
    git init -q -b sandbox-branch
    git -c user.email=t@t -c user.name=t add -A
    git -c user.email=t@t -c user.name=t commit -q -m "fixture"
)
SANDBOX_SHA="$(cd "$SANDBOX_SRC" && git rev-parse HEAD)"

# Target paths
export ZBUILD_HOME="$TEST_TEMP_DIR/zhome"
export ZBUILD_INSTALL_DIR="$TEST_TEMP_DIR/bin-install"
mkdir -p "$ZBUILD_INSTALL_DIR"

# ─── Test 1: clean install populates $ZBUILD_HOME ────────────────────────────
bash "$SANDBOX_SRC/install.sh" >"$TEST_TEMP_DIR/install.log" 2>&1 \
    || { cat "$TEST_TEMP_DIR/install.log"; assert_fail "install.sh exits 0"; exit 1; }
assert_pass "install.sh exits 0"

assert_file_exists "scripts/zbuild copied into ZBUILD_HOME" "$ZBUILD_HOME/scripts/zbuild"
if [[ -L "$ZBUILD_HOME/scripts/zbuild" ]]; then
    assert_fail "ZBUILD_HOME/scripts/zbuild must be a regular file, not a symlink"
else
    assert_pass "ZBUILD_HOME/scripts/zbuild is a regular file"
fi

for d in scripts core plugins config; do
    if [[ -d "$ZBUILD_HOME/$d" ]] && [[ -n "$(ls -A "$ZBUILD_HOME/$d" 2>/dev/null)" ]]; then
        assert_pass "ZBUILD_HOME/$d populated"
    else
        assert_fail "ZBUILD_HOME/$d populated" "missing or empty"
    fi
done

# ─── Test 2: tests/ and docs/ NOT copied ─────────────────────────────────────
assert_file_not_exists "tests/ NOT copied to ZBUILD_HOME" "$ZBUILD_HOME/tests/run-all.sh"
if [[ -d "$ZBUILD_HOME/tests" ]]; then
    assert_fail "ZBUILD_HOME/tests/ should not exist"
else
    assert_pass "ZBUILD_HOME/tests/ does not exist"
fi
if [[ -d "$ZBUILD_HOME/docs" ]]; then
    assert_fail "ZBUILD_HOME/docs/ should not exist"
else
    assert_pass "ZBUILD_HOME/docs/ does not exist"
fi

# ─── Test 3: version file captured ───────────────────────────────────────────
assert_file_exists "ZBUILD_HOME/version exists" "$ZBUILD_HOME/version"
version_content="$(cat "$ZBUILD_HOME/version")"
assert_contains "version file contains source SHA" "$version_content" "$SANDBOX_SHA"
assert_contains "version file contains branch" "$version_content" "sandbox-branch"

# ─── Test 4: shim is a regular file (not symlink) referencing ZBUILD_HOME ────
SHIM="$ZBUILD_INSTALL_DIR/zbuild"
assert_file_exists "shim installed at TARGET_DIR/zbuild" "$SHIM"
if [[ -L "$SHIM" ]]; then
    assert_fail "shim must be a regular file, not a symlink"
else
    assert_pass "shim is a regular file"
fi
shim_content="$(cat "$SHIM")"
assert_contains "shim references ZBUILD_HOME" "$shim_content" "ZBUILD_HOME"
assert_contains "shim execs scripts/zbuild" "$shim_content" "scripts/zbuild"

# ─── Test 5: migration — pre-existing symlink replaced with shim ─────────────
rm -rf "$ZBUILD_HOME" "$ZBUILD_INSTALL_DIR"
mkdir -p "$ZBUILD_INSTALL_DIR"
ln -s "/nonexistent/old-zbuild" "$ZBUILD_INSTALL_DIR/zbuild"
[[ -L "$ZBUILD_INSTALL_DIR/zbuild" ]] || { assert_fail "pre-condition: symlink exists"; exit 1; }
bash "$SANDBOX_SRC/install.sh" >"$TEST_TEMP_DIR/install-migrate.log" 2>&1 \
    || { cat "$TEST_TEMP_DIR/install-migrate.log"; assert_fail "install.sh exits 0 (migrate)"; exit 1; }
if [[ -L "$ZBUILD_INSTALL_DIR/zbuild" ]]; then
    assert_fail "old symlink should have been replaced"
else
    assert_pass "old symlink replaced with regular file"
fi
log_content="$(cat "$TEST_TEMP_DIR/install-migrate.log")"
assert_contains "install printed migration notice" "$log_content" "migrat"

# ─── Test 6: branch-isolation invariant ──────────────────────────────────────
# After install, mutating the source clone (touch a file, switch branch) must
# leave ZBUILD_HOME files unchanged.
copied_runner_sha="$(shasum "$ZBUILD_HOME/core/pipeline/runner.sh" | awk '{print $1}')"

(
    cd "$SANDBOX_SRC"
    git checkout -q -b another-branch
    echo "MUTATION $(date +%s%N)" >> core/pipeline/runner.sh
    git -c user.email=t@t -c user.name=t commit -q -am "mutate"
)

after_sha="$(shasum "$ZBUILD_HOME/core/pipeline/runner.sh" | awk '{print $1}')"
assert_eq "ZBUILD_HOME/core/pipeline/runner.sh unchanged after source mutation" \
    "$copied_runner_sha" "$after_sha"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
