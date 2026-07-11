#!/usr/bin/env bash
# Tests: `zbuild upgrade --tag <v>` fetches a release tarball, verifies checksum
# BEFORE applying, applies on OK, and REFUSES (does not apply) on tamper. Network
# is mocked via the ZBUILD_RELEASE_LOCAL_DIR seam — no real gh download. (#875)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "zbuild upgrade --tag fetch+verify-before-apply, tamper->refuse (#875)"

setup_test_env "zbuild-upgrade-tag-verify"

export ZBUILD_CONFIG_FILE="/dev/null"
unset ZBUILD_SIGNING_BACKEND 2>/dev/null || true

# ─── Build a sandbox source clone (the install payload), then install it ─────
SANDBOX_SRC="$TEST_TEMP_DIR/src"
mkdir -p "$SANDBOX_SRC"
for d in scripts core plugins config; do
    cp -R "$REPO_ROOT/$d" "$SANDBOX_SRC/$d"
done
cp "$REPO_ROOT/install.sh" "$SANDBOX_SRC/install.sh"
mkdir -p "$SANDBOX_SRC/.github/issues"
cp -R "$REPO_ROOT/.github/issues/." "$SANDBOX_SRC/.github/issues/" 2>/dev/null || true
[[ -f "$REPO_ROOT/VERSION" ]] && cp "$REPO_ROOT/VERSION" "$SANDBOX_SRC/VERSION"

export ZBUILD_HOME="$TEST_TEMP_DIR/zhome"
export ZBUILD_INSTALL_DIR="$TEST_TEMP_DIR/bin-install"
mkdir -p "$ZBUILD_INSTALL_DIR"
bash "$SANDBOX_SRC/install.sh" >/dev/null 2>&1 \
    || { assert_fail "initial install succeeded"; cleanup_test_env; print_test_results; exit 1; }
assert_pass "initial install succeeded"

# ─── Build a release tarball + SHA256SUMS for a tag, into a mock "release" dir ─
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
# shellcheck source=../../core/config/config.sh
source "$REPO_ROOT/core/config/config.sh"
# shellcheck source=../../scripts/lib/release-tarball.sh
source "$REPO_ROOT/scripts/lib/release-tarball.sh"

TAG="v1.2.3.4"
RELEASE_DIR="$TEST_TEMP_DIR/release"
build_release_tarball "$SANDBOX_SRC" "1.2.3.4" "$RELEASE_DIR" >/dev/null \
    || { assert_fail "release tarball built"; cleanup_test_env; print_test_results; exit 1; }
# release-tarball names the file zbuild-v1.2.3.4.tar.gz; the fetch seam expects
# zbuild-<tag>.tar.gz == zbuild-v1.2.3.4.tar.gz — they match.
assert_file_exists "release tarball present" "$RELEASE_DIR/zbuild-v1.2.3.4.tar.gz"
assert_file_exists "release SHA256SUMS present" "$RELEASE_DIR/SHA256SUMS"

# ─── Test 1: upgrade --tag applies a verified (untampered) release ───────────
print_test_section "1. upgrade --tag applies a verified release"
orig_version="$(cat "$ZBUILD_HOME/version")"
out_ok="$(ZBUILD_RELEASE_LOCAL_DIR="$RELEASE_DIR" \
    bash "$ZBUILD_HOME/scripts/zbuild" upgrade --tag "$TAG" 2>&1)" \
    || { echo "$out_ok"; assert_fail "upgrade --tag exits 0 on verified release"; cleanup_test_env; print_test_results; exit 1; }
assert_pass "upgrade --tag exits 0 on verified release"
assert_contains "reports checksum/signature verified" "$out_ok" "verified"

# ─── Test 2: TAMPER the release tarball -> upgrade --tag REFUSES, not applied ─
print_test_section "2. tampered release -> upgrade --tag refuses (not applied)"
TAMPER_DIR="$TEST_TEMP_DIR/release-tampered"
mkdir -p "$TAMPER_DIR"
cp "$RELEASE_DIR/SHA256SUMS" "$TAMPER_DIR/SHA256SUMS"
cp "$RELEASE_DIR/zbuild-v1.2.3.4.tar.gz" "$TAMPER_DIR/zbuild-v1.2.3.4.tar.gz"
# Corrupt the tarball AFTER SHA256SUMS was computed (a MITM / bad mirror).
printf 'evil-appended-bytes\n' >> "$TAMPER_DIR/zbuild-v1.2.3.4.tar.gz"

# Record install state so we can prove nothing was applied.
pre_tamper_version="$(cat "$ZBUILD_HOME/version")"
set +e
out_bad="$(ZBUILD_RELEASE_LOCAL_DIR="$TAMPER_DIR" \
    bash "$ZBUILD_HOME/scripts/zbuild" upgrade --tag "$TAG" 2>&1)"; bad_rc=$?
set -e
assert_gt "upgrade --tag rc!=0 on tampered release" "$bad_rc" "0"
assert_contains "refuses / not applied message" "$out_bad" "NOT applied"
post_tamper_version="$(cat "$ZBUILD_HOME/version")"
assert_eq "install untouched after refused tamper" "$pre_tamper_version" "$post_tamper_version"

# ─── Test 3: --from and --tag are mutually exclusive ─────────────────────────
print_test_section "3. --from and --tag are mutually exclusive"
set +e
out_both="$(bash "$ZBUILD_HOME/scripts/zbuild" upgrade --from "$SANDBOX_SRC" --tag "$TAG" 2>&1)"; both_rc=$?
set -e
assert_gt "rc!=0 when both --from and --tag given" "$both_rc" "0"
assert_contains "explains exactly one of --from/--tag" "$out_both" "exactly one"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
