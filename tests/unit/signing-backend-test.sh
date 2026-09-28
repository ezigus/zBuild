#!/usr/bin/env bash
# Tests: signing as an ADR-011 backend + checksums-only default strategy (#875 REL-C)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "signing ADR-011 backend + checksums-only default (#875)"

setup_test_env "signing-backend"

# Isolate config resolution from the project's real .zbuild/config.yaml.
export ZBUILD_CONFIG_FILE="/dev/null"
export ZBUILD_PROJECT_ROOT="$TEST_TEMP_DIR/project"

# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
# shellcheck source=../../core/config/config.sh
source "$REPO_ROOT/core/config/config.sh"
# shellcheck source=../../scripts/lib/release-tarball.sh
source "$REPO_ROOT/scripts/lib/release-tarball.sh"
# shellcheck source=../../scripts/lib/signing/checksums-only.sh
source "$REPO_ROOT/scripts/lib/signing/checksums-only.sh"

# ─── Test 1: default capability resolves to checksums-only ───────────────────
print_test_section "1. signing default backend"
unset ZBUILD_SIGNING_BACKEND 2>/dev/null || true
export ZBUILD_CONFIG_FILE="/dev/null"
sig="$(zbuild_config_get_backend "signing")"
assert_eq "signing default is checksums-only" "checksums-only" "$sig"
assert_eq "checksums-only listed in allowed" \
    "checksums-only" "${_ZBUILD_BACKEND_ALLOWED[signing]}"

# ─── Test 2: config file override ────────────────────────────────────────────
print_test_section "2. backends.signing override via config file"
cfg="$TEST_TEMP_DIR/cfg.yaml"
printf 'backends:\n  signing: cosign\n' > "$cfg"
export ZBUILD_CONFIG_FILE="$cfg"
unset ZBUILD_SIGNING_BACKEND 2>/dev/null || true
sig="$(zbuild_config_get_backend "signing")"
assert_eq "config override reads cosign" "cosign" "$sig"

# ─── Test 3: env var wins over config ────────────────────────────────────────
print_test_section "3. ZBUILD_SIGNING_BACKEND env wins"
export ZBUILD_SIGNING_BACKEND="checksums-only"
sig="$(zbuild_config_get_backend "signing")"
assert_eq "env var wins over config file" "checksums-only" "$sig"
unset ZBUILD_SIGNING_BACKEND

# ─── Test 4: checksums-only sign then verify round-trips ─────────────────────
print_test_section "4. checksums-only sign+verify round-trip"
export ZBUILD_CONFIG_FILE="/dev/null"
unset ZBUILD_SIGNING_BACKEND 2>/dev/null || true
art_dir="$TEST_TEMP_DIR/art"; mkdir -p "$art_dir"
printf 'payload-bytes\n' > "$art_dir/zbuild-v1.0.0.0.tar.gz"
sums_path="$(checksums-only_sign "$art_dir/zbuild-v1.0.0.0.tar.gz" "$art_dir")"
assert_file_exists "SHA256SUMS produced" "$sums_path"
assert_contains "SHA256SUMS names the tarball basename" \
    "$(cat "$sums_path")" "zbuild-v1.0.0.0.tar.gz"
set +e
checksums-only_verify "$art_dir/zbuild-v1.0.0.0.tar.gz" "$sums_path"; vrc=$?
set -e
assert_eq "verify OK on untampered tarball rc=0" "0" "$vrc"

# ─── Test 5: unknown configured backend fails loud (backend.missing) ─────────
print_test_section "5. unknown configured backend -> fail-loud rc=1"
export ZBUILD_SIGNING_BACKEND="nonexistent-signer"
set +e
out="$(_release_resolve_signing_backend 2>&1)"; rc=$?
set -e
assert_eq "resolve signing rc=1 on unknown backend" "1" "$rc"
assert_contains "message names backend.missing" "$out" "backend.missing"
unset ZBUILD_SIGNING_BACKEND

# ─── Test 6: verify REFUSES a missing/empty SHA256SUMS entry ─────────────────
print_test_section "6. verify refuses when no entry for the artifact"
empty_sums="$TEST_TEMP_DIR/empty-sums"; : > "$empty_sums"
set +e
checksums-only_verify "$art_dir/zbuild-v1.0.0.0.tar.gz" "$empty_sums"; nrc=$?
set -e
assert_gt "verify rc!=0 when no matching SHA256SUMS entry" "$nrc" "0"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
