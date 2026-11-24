#!/usr/bin/env bash
# Guard: no code in core/, plugins/, or scripts/ uses ZBUILD_PLATFORM as a host
# OS variable (ADR-009, issue #2532 DSPLAT-2).
#
# ZBUILD_PLATFORM is the target platform a work unit builds for. It must never
# be equated with a host OS name (macos, linux, unknown). This guard scans for
# lines where ZBUILD_PLATFORM appears on the same line as a host OS name in a
# non-comment context, catching both assignments and comparisons. Full-line
# comments and trailing inline comments are excluded before the host-OS check.
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

# _zbp_scan <path>... — the offending lines under the paths, as
# "<file>:<n>:<line>": ZBUILD_PLATFORM and a host OS name on one line, or a
# variable copied from ZBUILD_PLATFORM compared with one on a later line (the
# two-line indirection a lens found on #2532 run 45231040380). Comments are set
# aside first: a whole comment line, and a trailing one. Every scan here uses
# this one function, so the single-file and multi-file checks cannot drift.
_zbp_scan() {
    local -a _zbp_files=()
    mapfile -t _zbp_files < <(grep -rlE '\bZBUILD_PLATFORM\b' "$@" --include='*.sh' 2>/dev/null || true)
    (( ${#_zbp_files[@]} > 0 )) || return 0
    awk '
        FNR == 1 { split("", copy) }
        { line = $0; sub(/^[[:space:]]*#.*$/, "", line); sub(/[[:space:]]+#.*$/, "", line) }
        line == "" { next }
        { hostos = (line ~ /(^|[^A-Za-z0-9_])(macos|linux|unknown)([^A-Za-z0-9_]|$)/) }
        line ~ /(^|[^A-Za-z0-9_])ZBUILD_PLATFORM([^A-Za-z0-9_]|$)/ {
            if (hostos) { print FILENAME ":" FNR ":" line; next }
            if (match(line, /[A-Za-z_][A-Za-z0-9_]*=["\047]?\$\{?ZBUILD_PLATFORM/)) {
                v = substr(line, RSTART, RLENGTH); sub(/=.*/, "", v); copy[v] = 1
            }
            next
        }
        hostos { for (v in copy) if (line ~ ("\\$\\{?" v "([^A-Za-z0-9_]|$)")) { print FILENAME ":" FNR ":" line; next } }
    ' "${_zbp_files[@]}"
}

# Helper: run the guard scan on a single temporary fixture file.
# Prints the offending lines found (empty string = clean).
# Single-file grep -n outputs "linenum:content"; filter comments with ^[0-9]+:.
_zbp_scan_file() { _zbp_scan "$1"; }

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

# When: code line has ZBUILD_PLATFORM where the host OS name appears only in a trailing
# inline comment (the code itself carries a target platform, not a host OS name)
printf 'export ZBUILD_PLATFORM="${platform}"  # was linux in compat.sh\n' > "$_zbp_fixture"
_zbp_hit="$(_zbp_scan_file "$_zbp_fixture")"
# Then: guard does NOT flag this — host OS name is only in the inline comment
if [[ -z "$_zbp_hit" ]]; then
    assert_pass "[DSPLAT-2] detector ignores host OS name that appears only in a trailing inline comment"
else
    assert_fail "[DSPLAT-2] detector ignores host OS name that appears only in a trailing inline comment" \
        "scan incorrectly flagged inline comment: $_zbp_hit"
fi

# ─── [DSPLAT-2] recursive scan finds injected violation ───────────────────────
# Prove the multi-file grep scan DOES reach its assert_fail branch when a
# violating file exists. Uses temp scan dirs so no real source file is touched.
print_test_section "[DSPLAT-2] recursive scan correctly exits non-zero on injected violation"

# Given: a scripts/ subtree in TEST_TEMP_DIR with a violating .sh file
_zbp_scan_dir="$TEST_TEMP_DIR/scan-test"
mkdir -p "$_zbp_scan_dir/scripts/lib" "$_zbp_scan_dir/core" "$_zbp_scan_dir/plugins"
_zbp_inject="$_zbp_scan_dir/scripts/lib/fake-compat.sh"
printf '    Darwin)  ZBUILD_PLATFORM=macos ;;\n' > "$_zbp_inject"

# When: the recursive grep scan is run against those directories
_zbp_inject_hits="$(_zbp_scan "$_zbp_scan_dir/core" "$_zbp_scan_dir/plugins" "$_zbp_scan_dir/scripts")"
if [[ -n "$_zbp_inject_hits" ]]; then
    _zbp_inject_count="$(printf '%s\n' "$_zbp_inject_hits" | grep -cE '.' || true)"
else
    _zbp_inject_count=0
fi

# Then: the scan finds the violation — the guard would exit non-zero
if [[ "$_zbp_inject_count" -gt 0 ]]; then
    assert_pass "[DSPLAT-2] recursive scan finds injected ZBUILD_PLATFORM=macos violation"
else
    assert_fail "[DSPLAT-2] recursive scan finds injected ZBUILD_PLATFORM=macos violation" \
        "recursive scan returned 0 matches for a known-bad file; scan logic is broken"
fi

# Given: a two-line indirection — the value copied into a variable on one
# line, that variable compared with a host OS name on another (lens finding,
# #2532 run 45231040380: a one-line scan let it through)
printf '_p="$ZBUILD_PLATFORM"\nif [[ "$_p" == linux ]]; then :; fi\n' > "$_zbp_scan_dir/scripts/lib/fake-indirect.sh"
_zbp_ind_hits="$(_zbp_scan "$_zbp_scan_dir/core" "$_zbp_scan_dir/plugins" "$_zbp_scan_dir/scripts")"
if [[ "$_zbp_ind_hits" == *fake-indirect.sh* ]]; then
    assert_pass "[DSPLAT-2] the scan catches a two-line indirection"
else
    assert_fail "[DSPLAT-2] the scan catches a two-line indirection" "no hit: ${_zbp_ind_hits:-<none>}"
fi
rm -f "$_zbp_scan_dir/scripts/lib/fake-indirect.sh"

# Given: a comment-only line and a trailing comment that name a host OS, in
# the multi-file scan too (lens finding: its comment filter was another regex)
printf '# ZBUILD_PLATFORM is never macos\nZBUILD_PLATFORM=ios  # not linux\n' > "$_zbp_scan_dir/scripts/lib/fake-comments.sh"
_zbp_cm_hits="$(_zbp_scan "$_zbp_scan_dir/core" "$_zbp_scan_dir/plugins" "$_zbp_scan_dir/scripts")"
if [[ "$_zbp_cm_hits" == *fake-comments.sh* ]]; then
    assert_fail "[DSPLAT-2] the multi-file scan sets comments aside" "hit: $_zbp_cm_hits"
else
    assert_pass "[DSPLAT-2] the multi-file scan sets comments aside"
fi
rm -f "$_zbp_scan_dir/scripts/lib/fake-comments.sh"

# Given: the violating file is removed (clean state)
rm -f "$_zbp_inject"

# When: the same recursive scan is run again
_zbp_clean_hits="$(_zbp_scan "$_zbp_scan_dir/core" "$_zbp_scan_dir/plugins" "$_zbp_scan_dir/scripts")"

# Then: scan returns clean after the violating file is removed
if [[ -z "$_zbp_clean_hits" ]]; then
    assert_pass "[DSPLAT-2] recursive scan returns clean after injected violation removed"
else
    assert_fail "[DSPLAT-2] recursive scan returns clean after injected violation removed" \
        "scan still matched: $_zbp_clean_hits"
fi

# ─── [DSPLAT-2] real codebase scan ────────────────────────────────────────────
print_test_section "[DSPLAT-2] scan core/, plugins/, scripts/ for host-OS ZBUILD_PLATFORM use"

# Given: all three scan directories must exist so the scan is non-vacuous
# A missing directory causes grep to silently produce no output, making the
# guard declare clean on a scan that never ran. [DSPLAT-2]
for _zbp_req_dir in "$REPO_ROOT/core" "$REPO_ROOT/plugins" "$REPO_ROOT/scripts"; do
    if [[ ! -d "$_zbp_req_dir" ]]; then
        assert_fail "[DSPLAT-2] scan directory must exist before declaring clean: $_zbp_req_dir" \
            "REPO_ROOT='$REPO_ROOT'; guard cannot determine clean state without all three dirs"
    fi
done

# When: scan all .sh files under core/, plugins/, and scripts/
_zbp_offenders="$(_zbp_scan "$REPO_ROOT/core" "$REPO_ROOT/plugins" "$REPO_ROOT/scripts" | sort -u)"

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
