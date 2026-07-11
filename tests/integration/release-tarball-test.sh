#!/usr/bin/env bash
# Tests: build a release tarball + SHA256SUMS (checksums-only default), verify OK,
# then TAMPER and assert verify REFUSES (non-zero, artifact not applied). (#875 REL-C)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "release tarball build + SHA256SUMS + tamper->refuse (#875)"

setup_test_env "release-tarball"

export ZBUILD_CONFIG_FILE="/dev/null"
export ZBUILD_PROJECT_ROOT="$TEST_TEMP_DIR/project"
unset ZBUILD_SIGNING_BACKEND 2>/dev/null || true

# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
# shellcheck source=../../core/config/config.sh
source "$REPO_ROOT/core/config/config.sh"
# shellcheck source=../../scripts/lib/release-tarball.sh
source "$REPO_ROOT/scripts/lib/release-tarball.sh"

# ─── Build a minimal fixture repo with the mandatory payload members ─────────
FIX="$TEST_TEMP_DIR/repo"
mkdir -p "$FIX/scripts" "$FIX/core" "$FIX/plugins" "$FIX/config" "$FIX/.github/issues"
printf '#!/usr/bin/env bash\necho hi\n' > "$FIX/scripts/zbuild"
printf 'core\n'    > "$FIX/core/marker"
printf 'plugin\n'  > "$FIX/plugins/marker"
printf 'cfg\n'     > "$FIX/config/marker"
printf 'issue\n'   > "$FIX/.github/issues/marker"
printf '#!/usr/bin/env bash\n' > "$FIX/install.sh"
printf '1.2.3.4\n' > "$FIX/VERSION"

OUT="$TEST_TEMP_DIR/out"

# ─── Test 1: build produces tarball + SHA256SUMS ─────────────────────────────
print_test_section "1. build_release_tarball produces artifact + SHA256SUMS"
tarball="$(build_release_tarball "$FIX" "1.2.3.4" "$OUT")" \
    || { assert_fail "build_release_tarball exits 0"; cleanup_test_env; print_test_results; exit 1; }
assert_pass "build_release_tarball exits 0"
assert_file_exists "tarball named by version" "$OUT/zbuild-v1.2.3.4.tar.gz"
assert_eq "returned path matches expected" "$OUT/zbuild-v1.2.3.4.tar.gz" "$tarball"
assert_file_exists "SHA256SUMS produced" "$OUT/SHA256SUMS"

# ─── Test 2: the tarball carries the install payload set ─────────────────────
print_test_section "2. tarball contains the install payload set"
listing="$(tar -tzf "$tarball")"
for member in scripts/ core/ plugins/ config/ .github/issues/ install.sh VERSION; do
    assert_contains "tarball includes $member" "$listing" "$member"
done

# ─── Test 3: verify OK on the untampered artifact ────────────────────────────
print_test_section "3. verify_release_tarball OK on untampered artifact"
set +e
verify_release_tarball "$tarball" "$OUT/SHA256SUMS"; vrc=$?
set -e
assert_eq "verify rc=0 on untampered tarball" "0" "$vrc"

# ─── Test 4: TAMPER -> verify REFUSES (non-zero, not applied) ─────────────────
print_test_section "4. tamper -> verify refuses"
# Corrupt the downloaded artifact after SHA256SUMS was produced.
printf 'malicious-extra-bytes\n' >> "$tarball"
set +e
verify_release_tarball "$tarball" "$OUT/SHA256SUMS"; trc=$?
set -e
assert_gt "verify rc!=0 after tamper (REFUSE)" "$trc" "0"

# ─── Test 5: determinism — rebuild identical inputs yields identical digest ──
print_test_section "5. deterministic rebuild -> identical SHA256SUMS"
OUT2="$TEST_TEMP_DIR/out2"
build_release_tarball "$FIX" "1.2.3.4" "$OUT2" >/dev/null
d1="$(awk '{print $1}' "$OUT/SHA256SUMS")"
# OUT/SHA256SUMS digest was for the pre-tamper tarball; recompute a fresh clean
# build in OUT3 to compare against OUT2 (OUT's tarball is now tampered).
OUT3="$TEST_TEMP_DIR/out3"
build_release_tarball "$FIX" "1.2.3.4" "$OUT3" >/dev/null
d2="$(awk '{print $1}' "$OUT2/SHA256SUMS")"
d3="$(awk '{print $1}' "$OUT3/SHA256SUMS")"
if tar --sort=name --version >/dev/null 2>&1; then
    assert_eq "GNU tar: two clean builds share one digest (reproducible)" "$d2" "$d3"
else
    # BSD/macOS tar embeds mtimes; determinism is best-effort. Just assert both
    # builds produced a non-empty digest.
    assert_gt "clean build produced a digest (BSD tar)" "${#d2}" "0"
    assert_gt "clean build produced a digest (BSD tar)" "${#d3}" "0"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
