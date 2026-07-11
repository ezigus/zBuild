#!/usr/bin/env bash
# Tests: versioning as an ADR-011 backend + resolve_repo_version seam (ADR-048, #873)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "versioning ADR-011 backend + resolve_repo_version seam (#873)"

setup_test_env "versioning-backend"

# Isolate config resolution from the project's real .zbuild/config.yaml.
export ZBUILD_CONFIG_FILE="/dev/null"
export ZBUILD_PROJECT_ROOT="$TEST_TEMP_DIR/project"

# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
# shellcheck source=../../core/config/config.sh
source "$REPO_ROOT/core/config/config.sh"
# shellcheck source=../../scripts/lib/version.sh
source "$REPO_ROOT/scripts/lib/version.sh"

# ─── Test 1: default capability resolves to initiative-count ─────────────────
print_test_section "1. versioning default backend"
unset ZBUILD_VERSIONING_BACKEND 2>/dev/null || true
export ZBUILD_CONFIG_FILE="/dev/null"
ver="$(zbuild_config_get_backend "versioning")"
assert_eq "versioning default is initiative-count" "initiative-count" "$ver"
assert_eq "initiative-count listed in allowed" \
    "initiative-count" "${_ZBUILD_BACKEND_ALLOWED[versioning]}"

# ─── Test 2: config file override ───────────────────────────────────────────
print_test_section "2. backends.versioning override via config file"
cfg="$TEST_TEMP_DIR/cfg.yaml"
printf 'backends:\n  versioning: date-based\n' > "$cfg"
export ZBUILD_CONFIG_FILE="$cfg"
unset ZBUILD_VERSIONING_BACKEND 2>/dev/null || true
ver="$(zbuild_config_get_backend "versioning")"
assert_eq "config override reads date-based" "date-based" "$ver"

# ─── Test 3: env var wins over config ───────────────────────────────────────
print_test_section "3. ZBUILD_VERSIONING_BACKEND env wins"
export ZBUILD_VERSIONING_BACKEND="initiative-count"
ver="$(zbuild_config_get_backend "versioning")"
assert_eq "env var wins over config file" "initiative-count" "$ver"
unset ZBUILD_VERSIONING_BACKEND

# ─── Test 4: resolve_repo_version default dispatches to initiative-count ─────
print_test_section "4. resolve_repo_version default path"
export ZBUILD_CONFIG_FILE="/dev/null"
unset ZBUILD_VERSIONING_BACKEND 2>/dev/null || true
# Pin gathered inputs so the assembled value is deterministic (no git dependency).
export ZBUILD_VERSION_ANCHOR="1.0" ZBUILD_VERSION_RELEASE_COUNT="0" ZBUILD_VERSION_ISSUES_SINCE="0"
out="$(resolve_repo_version)"
assert_eq "default resolves 4-part version" "1.0.0.0" "$out"
out2="$(ZBUILD_VERSION_RELEASE_COUNT=1 ZBUILD_VERSION_ISSUES_SINCE=12 resolve_repo_version)"
assert_eq "override inputs -> 1.0.1.12" "1.0.1.12" "$out2"
unset ZBUILD_VERSION_ANCHOR ZBUILD_VERSION_RELEASE_COUNT ZBUILD_VERSION_ISSUES_SINCE

# ─── Test 5: unknown backend fails loud (backend.missing) ───────────────────
print_test_section "5. unknown configured backend -> fail-loud rc=1"
export ZBUILD_VERSIONING_BACKEND="nonexistent-scheme"
set +e
out="$(resolve_repo_version 2>&1)"; rc=$?
set -e
assert_eq "resolve_repo_version rc=1 on unknown backend" "1" "$rc"
assert_contains "message names backend.missing" "$out" "backend.missing"
unset ZBUILD_VERSIONING_BACKEND

cleanup_test_env
print_test_results
exit $((FAIL > 0))
