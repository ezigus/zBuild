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

# ─── Test 4: a path-traversal tag is REJECTED before any download ────────────
# (Copilot: fetch_verified_release built paths from an arbitrary tag.)
print_test_section "4. path-traversal tag rejected before download"
canary="$TEST_TEMP_DIR/canary"; mkdir -p "$canary"
for bad_tag in "../evil" "v1/../2" "..%2f" "v1.2.3.4/../../x"; do
    dl="$TEST_TEMP_DIR/dl-$RANDOM"
    set +e
    # Point the fetch seam at a command that MUST NOT run for a rejected tag.
    out_bt="$(ZBUILD_RELEASE_FETCH_CMD="touch $canary/fetched-ran &&" \
        fetch_verified_release "$bad_tag" "$dl" 2>&1)"; bt_rc=$?
    set -e
    assert_gt "reject bad tag '$bad_tag' (rc!=0)" "$bt_rc" "0"
    assert_contains "bad tag '$bad_tag' names invalid/refusing" "$out_bt" "invalid tag"
done
assert_file_not_exists "no fetch ran for any rejected tag" "$canary/fetched-ran"

# ─── Test 5: a valid tag is accepted by the validator ────────────────────────
print_test_section "5. valid tags accepted by the tag validator"
for good_tag in "v1.2.3" "v1.2.3.4" "1.0.0.0"; do
    set +e
    _release_valid_tag "$good_tag"; grc=$?
    set -e
    assert_eq "valid tag accepted: $good_tag" "0" "$grc"
done

# ─── Test 6: _release_repo resolves owner/repo (env > origin > default) ───────
print_test_section "6. release repo resolution for gh --repo"
env_repo="$(ZBUILD_RELEASE_REPO="acme/widget" _release_repo)"
assert_eq "ZBUILD_RELEASE_REPO override wins" "acme/widget" "$env_repo"
# Outside a git checkout, with no override, falls back to the default owner/repo.
def_repo="$(cd "$TEST_TEMP_DIR" && unset ZBUILD_RELEASE_REPO; _release_repo)"
assert_eq "default repo is ezigus/zBuild" "ezigus/zBuild" "$def_repo"

# ─── Test 7: upgrade --tag cleans its temp dir (no leak on success) ──────────
# (Copilot: exec skipped the EXIT trap -> mktemp workdir leaked. We isolate
# TMPDIR to an empty dir and assert it is empty again after a successful run.)
print_test_section "7. upgrade --tag leaves no temp dir behind"
LEAK_TMP="$TEST_TEMP_DIR/leaktmp"; mkdir -p "$LEAK_TMP"
out_leak="$(TMPDIR="$LEAK_TMP" ZBUILD_RELEASE_LOCAL_DIR="$RELEASE_DIR" \
    bash "$ZBUILD_HOME/scripts/zbuild" upgrade --tag "$TAG" 2>&1)" \
    || { echo "$out_leak"; assert_fail "upgrade --tag (leak probe) exits 0"; cleanup_test_env; print_test_results; exit 1; }
leftovers="$(find "$LEAK_TMP" -maxdepth 1 -name 'zbuild-upgrade.*' 2>/dev/null | wc -l | tr -d '[:space:]')"
assert_eq "no zbuild-upgrade.* temp dir leaked after success" "0" "$leftovers"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
