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

# ─── Test 6: release_count robust outside a git worktree (Copilot, PR #1387) ─
print_test_section "6. _versioning_release_count never aborts outside a git tree"
# shellcheck source=../../scripts/lib/versioning/initiative-count.sh
source "$REPO_ROOT/scripts/lib/versioning/initiative-count.sh"
_ng="$TEST_TEMP_DIR/not-a-git-tree"; mkdir -p "$_ng"
# Run in a non-git dir under strict mode: a git-tag pipeline failure (no .git /
# grep no-match under pipefail) must NOT abort — it degrades to 0 prior releases.
set +e
_rc_out="$( set -euo pipefail; cd "$_ng" && _versioning_release_count "1.0" )"; _rc=$?
set -e
assert_eq "release_count rc=0 in strict mode outside a git worktree" "0" "$_rc"
assert_eq "release_count prints 0 outside a git worktree" "0" "$_rc_out"

# ─── Test 7: cadence reset semantics — patch preserves z ─────────────────────
print_test_section "7. [SPEC-1] patch cadence: z (issues) preserved, not reset"
export ZBUILD_CONFIG_FILE="/dev/null"
unset ZBUILD_VERSIONING_BACKEND 2>/dev/null || true
# Patch with 5 issues_since: w.x.y.z should remain intact (no reset).
out_patch="$(ZBUILD_VERSION_ANCHOR="1.0" ZBUILD_VERSION_RELEASE_COUNT="2" \
    ZBUILD_VERSION_ISSUES_SINCE="5" ZBUILD_VERSION_CADENCE="patch" \
    resolve_repo_version)"
assert_eq "[SPEC-1] patch cadence: issues_since preserved → 1.0.2.5" "1.0.2.5" "$out_patch"

# ─── Test 8: cadence reset semantics — minor resets z ────────────────────────
print_test_section "8. [SPEC-2] minor cadence: z forced to 0 on initiative cut"
# Minor with 5 issues_since: z must be reset to 0, producing w.(x+1).0.0.
out_minor="$(ZBUILD_VERSION_ANCHOR="1.0" ZBUILD_VERSION_RELEASE_COUNT="2" \
    ZBUILD_VERSION_ISSUES_SINCE="5" ZBUILD_VERSION_CADENCE="minor" \
    resolve_repo_version)"
assert_eq "[SPEC-2] minor cadence: z reset → 1.1.0.0" "1.1.0.0" "$out_minor"

# ─── Test 9: cadence reset semantics — major resets z ────────────────────────
print_test_section "9. [SPEC-3] major cadence: z forced to 0 on initiative cut"
# Major with 5 issues_since: z must be reset to 0, producing (w+1).0.0.0.
out_major="$(ZBUILD_VERSION_ANCHOR="1.0" ZBUILD_VERSION_RELEASE_COUNT="2" \
    ZBUILD_VERSION_ISSUES_SINCE="5" ZBUILD_VERSION_CADENCE="major" \
    resolve_repo_version)"
assert_eq "[SPEC-3] major cadence: z reset → 2.0.0.0" "2.0.0.0" "$out_major"
unset ZBUILD_VERSION_CADENCE

cleanup_test_env
print_test_results
exit $((FAIL > 0))
