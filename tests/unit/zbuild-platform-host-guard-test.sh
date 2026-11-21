#!/usr/bin/env bash
# Guard: no code in core/, plugins/, or scripts/ uses ZBUILD_PLATFORM as a host
# OS variable (ADR-009, issue #2532 DSPLAT-2).
#
# ZBUILD_PLATFORM is the target platform a work unit builds for. It must never
# be equated with a host OS name (macos, linux, unknown). This guard scans for
# lines where ZBUILD_PLATFORM appears on the same line as a host OS name in a
# non-comment context, catching both assignments and comparisons.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"

print_test_header "ZBUILD_PLATFORM host-OS guard — core/, plugins/, scripts/ (ADR-009, #2532)"

# ─── [DSPLAT-2] detector fixture tests ────────────────────────────────────────
# Verify the detector catches what it must and ignores what it must not.
# When: a file under core/, plugins/, or scripts/ contains code that tests
# ZBUILD_PLATFORM against a host OS value such as macos, linux, or unknown
# Then: the guard test exits non-zero
print_test_section "[DSPLAT-2] detector fixture tests"

# Helper: run the guard scan on a single temporary fixture file.
# Prints the offending lines found (empty string = clean).
# Single-file grep -n outputs "linenum:content"; filter comments with ^[0-9]+:.
_zbp_scan_file() {
    local fixture="$1"
    {
        grep -nE '\bZBUILD_PLATFORM\b' "$fixture" 2>/dev/null || true
    } | {
        grep -vE '^[0-9]+:[[:space:]]*#' || true
    } | {
        grep -E '\b(macos|linux|unknown)\b' || true
    }
}

# Given: a fixture file with ZBUILD_PLATFORM assigned to a host OS name
_zbp_fixture="$TEST_TEMP_DIR/fixture.sh"

# When: fixture assigns macos to ZBUILD_PLATFORM
printf '    Darwin)  ZBUILD_PLATFORM=macos ;;\n' > "$_zbp_fixture"
_zbp_hit="$(_zbp_scan_file "$_zbp_fixture")"
# Then: guard finds the violation (non-empty output)
if [[ -n "$_zbp_hit" ]]; then
    assert_pass "[DSPLAT-2] detector catches ZBUILD_PLATFORM=macos (assignment)"
else
    assert_fail "[DSPLAT-2] detector catches ZBUILD_PLATFORM=macos (assignment)" \
        "scan returned no output for 'ZBUILD_PLATFORM=macos'"
fi

# When: fixture assigns linux to ZBUILD_PLATFORM
printf '    Linux)   ZBUILD_PLATFORM=linux ;;\n' > "$_zbp_fixture"
_zbp_hit="$(_zbp_scan_file "$_zbp_fixture")"
# Then: guard finds the violation
if [[ -n "$_zbp_hit" ]]; then
    assert_pass "[DSPLAT-2] detector catches ZBUILD_PLATFORM=linux (assignment)"
else
    assert_fail "[DSPLAT-2] detector catches ZBUILD_PLATFORM=linux (assignment)" \
        "scan returned no output for 'ZBUILD_PLATFORM=linux'"
fi

# When: fixture assigns unknown to ZBUILD_PLATFORM
printf '    *)       ZBUILD_PLATFORM=unknown ;;\n' > "$_zbp_fixture"
_zbp_hit="$(_zbp_scan_file "$_zbp_fixture")"
# Then: guard finds the violation
if [[ -n "$_zbp_hit" ]]; then
    assert_pass "[DSPLAT-2] detector catches ZBUILD_PLATFORM=unknown (assignment)"
else
    assert_fail "[DSPLAT-2] detector catches ZBUILD_PLATFORM=unknown (assignment)" \
        "scan returned no output for 'ZBUILD_PLATFORM=unknown'"
fi

# When: fixture reads ZBUILD_PLATFORM in a comparison with a host OS name
printf '[[ "$ZBUILD_PLATFORM" == "macos" ]] && do_mac_thing\n' > "$_zbp_fixture"
_zbp_hit="$(_zbp_scan_file "$_zbp_fixture")"
# Then: guard finds the violation
if [[ -n "$_zbp_hit" ]]; then
    assert_pass "[DSPLAT-2] detector catches \$ZBUILD_PLATFORM == macos (comparison)"
else
    assert_fail "[DSPLAT-2] detector catches \$ZBUILD_PLATFORM == macos (comparison)" \
        "scan returned no output for '== macos'"
fi

# When: fixture uses ZBUILD_PLATFORM against linux in a case statement
printf 'case "$ZBUILD_PLATFORM" in linux) use_gnu ;; esac\n' > "$_zbp_fixture"
_zbp_hit="$(_zbp_scan_file "$_zbp_fixture")"
# Then: guard finds the violation
if [[ -n "$_zbp_hit" ]]; then
    assert_pass "[DSPLAT-2] detector catches case on \$ZBUILD_PLATFORM with linux"
else
    assert_fail "[DSPLAT-2] detector catches case on \$ZBUILD_PLATFORM with linux" \
        "scan returned no output for case linux"
fi

# When: fixture uses ZBUILD_PLATFORM=ios (a target platform, not a host OS name)
printf 'export ZBUILD_PLATFORM=ios\n' > "$_zbp_fixture"
_zbp_hit="$(_zbp_scan_file "$_zbp_fixture")"
# Then: guard finds no violation (ios is a target platform, not a host OS name)
if [[ -z "$_zbp_hit" ]]; then
    assert_pass "[DSPLAT-2] detector ignores ZBUILD_PLATFORM=ios (target platform)"
else
    assert_fail "[DSPLAT-2] detector ignores ZBUILD_PLATFORM=ios (target platform)" \
        "scan flagged 'ios' as a host OS name: $_zbp_hit"
fi

# When: fixture mentions ZBUILD_PLATFORM_OVERRIDE with macos (different variable)
printf 'ZBUILD_PLATFORM_OVERRIDE=macos\n' > "$_zbp_fixture"
_zbp_hit="$(_zbp_scan_file "$_zbp_fixture")"
# Then: guard finds no violation (ZBUILD_PLATFORM_OVERRIDE is a different variable)
if [[ -z "$_zbp_hit" ]]; then
    assert_pass "[DSPLAT-2] detector ignores ZBUILD_PLATFORM_OVERRIDE=macos"
else
    assert_fail "[DSPLAT-2] detector ignores ZBUILD_PLATFORM_OVERRIDE=macos" \
        "scan incorrectly flagged ZBUILD_PLATFORM_OVERRIDE: $_zbp_hit"
fi

# When: fixture is a comment explaining the contract
printf '# ZBUILD_PLATFORM is not a host OS; macos and linux are not valid values\n' > "$_zbp_fixture"
_zbp_hit="$(_zbp_scan_file "$_zbp_fixture")"
# Then: guard finds no violation (comment lines are excluded)
if [[ -z "$_zbp_hit" ]]; then
    assert_pass "[DSPLAT-2] detector ignores comment lines mentioning host OS names"
else
    assert_fail "[DSPLAT-2] detector ignores comment lines mentioning host OS names" \
        "scan incorrectly flagged comment: $_zbp_hit"
fi

# ─── [DSPLAT-2] real codebase scan ────────────────────────────────────────────
print_test_section "[DSPLAT-2] scan core/, plugins/, scripts/ for host-OS ZBUILD_PLATFORM use"

# When: scan all .sh files under core/, plugins/, and scripts/
_zbp_offenders="$(
    {
        grep -rnE '\bZBUILD_PLATFORM\b' \
            "$REPO_ROOT/core" "$REPO_ROOT/plugins" "$REPO_ROOT/scripts" \
            --include='*.sh' 2>/dev/null || true
    } | {
        grep -vE '^[^:]*:[0-9]+:[[:space:]]*#' || true
    } | {
        grep -E '\b(macos|linux|unknown)\b' || true
    } | sort -u
)"

# Count offenders without piping into grep -q
if [[ -z "$_zbp_offenders" ]]; then
    _zbp_count=0
else
    _zbp_count="$(printf '%s\n' "$_zbp_offenders" | grep -cE '.' || true)"
fi

# Then: no such patterns exist in the codebase
if [[ "$_zbp_count" -eq 0 ]]; then
    assert_pass "[DSPLAT-2] no ZBUILD_PLATFORM/host-OS usage in core/, plugins/, scripts/"
else
    echo "  offending lines (ZBUILD_PLATFORM equated with a host OS name):" >&2
    printf '%s\n' "$_zbp_offenders" >&2
    assert_fail "[DSPLAT-2] no ZBUILD_PLATFORM/host-OS usage in core/, plugins/, scripts/" \
        "found $_zbp_count occurrence(s); see list above (ADR-009, #2532)"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
