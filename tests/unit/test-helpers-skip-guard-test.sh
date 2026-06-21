#!/usr/bin/env bash
# Tests: skip_unless_platform / skip_on_platform helpers in test-helpers.sh.
# Uses the same subshell pattern as test-helpers-quiet-mode-test.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "platform skip-guard helpers"

HELPERS_PATH="$REPO_ROOT/scripts/lib/test-helpers.sh"

# Detect current platform for use in assertions below.
CURRENT_PLATFORM="$(uname -s 2>/dev/null)"
case "$CURRENT_PLATFORM" in
    Darwin) CURRENT_PLATFORM="macos" ;;
    Linux)  CURRENT_PLATFORM="linux" ;;
esac
if [[ "$CURRENT_PLATFORM" == "linux" ]]; then
    OTHER_PLATFORM="macos"
else
    OTHER_PLATFORM="linux"
fi

# Run a snippet in a fresh bash subshell that sources test-helpers.sh.
# Captures stdout+stderr merged so SKIP messages (sent to stderr) are visible.
run_in_subshell() {
    local snippet="$1"
    bash -c "
        set +e
        # shellcheck disable=SC1090
        source '$HELPERS_PATH' >/dev/null 2>&1
        $snippet
    " 2>&1
}

# Strip ANSI escape codes for plain-text matching.
strip_ansi() {
    printf '%s' "$1" | sed -E $'s/\x1b\\[[0-9;]*m//g'
}

# ─── [SPEC-1]: skip_unless_platform matching platform → execution continues ──
out="$(run_in_subshell "skip_unless_platform $CURRENT_PLATFORM; echo CONTINUED")"
if [[ "$out" == *"CONTINUED"* ]]; then
    assert_pass "[SPEC-1] skip_unless_platform matching platform: execution continues"
else
    assert_fail "[SPEC-1] skip_unless_platform matching platform: execution continues" "got: $out"
fi

# ─── [SPEC-2]: skip_unless_platform non-matching → exits 0 with SKIP output ─
out="$(run_in_subshell "skip_unless_platform $OTHER_PLATFORM; echo SHOULD_NOT_APPEAR")"
rc=$?
clean="$(strip_ansi "$out")"
if [[ $rc -eq 0 ]] && [[ "$clean" == *"SKIP"* ]] && [[ "$out" != *"SHOULD_NOT_APPEAR"* ]]; then
    assert_pass "[SPEC-2] skip_unless_platform non-matching platform: exits 0 with SKIP"
else
    assert_fail "[SPEC-2] skip_unless_platform non-matching platform: exits 0 with SKIP" \
        "rc=$rc out=$clean"
fi

# ─── [SPEC-3]: skip_on_platform matching platform → exits 0 with SKIP output ─
out="$(run_in_subshell "skip_on_platform $CURRENT_PLATFORM; echo SHOULD_NOT_APPEAR")"
rc=$?
clean="$(strip_ansi "$out")"
if [[ $rc -eq 0 ]] && [[ "$clean" == *"SKIP"* ]] && [[ "$out" != *"SHOULD_NOT_APPEAR"* ]]; then
    assert_pass "[SPEC-3] skip_on_platform matching platform: exits 0 with SKIP"
else
    assert_fail "[SPEC-3] skip_on_platform matching platform: exits 0 with SKIP" \
        "rc=$rc out=$clean"
fi

# ─── [SPEC-4]: skip_on_platform non-matching → execution continues ────────────
out="$(run_in_subshell "skip_on_platform $OTHER_PLATFORM; echo CONTINUED")"
if [[ "$out" == *"CONTINUED"* ]]; then
    assert_pass "[SPEC-4] skip_on_platform non-matching platform: execution continues"
else
    assert_fail "[SPEC-4] skip_on_platform non-matching platform: execution continues" "got: $out"
fi

# ─── [SPEC-5]: print_test_results with SKIP>0 emits SKIP banner, exits 0 ─────
out="$(run_in_subshell 'SKIP=1; print_test_results || true')"
rc=$?
clean="$(strip_ansi "$out")"
if [[ $rc -eq 0 ]] && [[ "$clean" == *"SKIP"* ]]; then
    assert_pass "[SPEC-5] print_test_results SKIP>0: emits SKIP banner and exits 0"
else
    assert_fail "[SPEC-5] print_test_results SKIP>0: emits SKIP banner and exits 0" \
        "rc=$rc out=$clean"
fi

# ─── [SPEC-6]: SKIP counter initializes to 0 at source time ──────────────────
out="$(run_in_subshell 'printf "SKIP=%s\n" "$SKIP"')"
if [[ "$out" == "SKIP=0" ]]; then
    assert_pass "[SPEC-6] SKIP counter initializes to 0"
else
    assert_fail "[SPEC-6] SKIP counter initializes to 0" "got: $out"
fi

# ─── [SPEC-7]: skip_unless_platform rejects an unknown platform (fails loudly) ─
# A typo must NOT silently skip; it must exit non-zero with an ERROR, not run on.
out="$(run_in_subshell "skip_unless_platform lniux; echo SHOULD_NOT_APPEAR")"
rc=$?
clean="$(strip_ansi "$out")"
if [[ $rc -ne 0 ]] && [[ "$clean" == *"ERROR"* ]] && [[ "$out" != *"SHOULD_NOT_APPEAR"* ]]; then
    assert_pass "[SPEC-7] skip_unless_platform invalid platform: exits non-zero with ERROR"
else
    assert_fail "[SPEC-7] skip_unless_platform invalid platform: exits non-zero with ERROR" \
        "rc=$rc out=$clean"
fi

# ─── [SPEC-8]: skip_on_platform rejects an unknown platform (fails loudly) ────
out="$(run_in_subshell "skip_on_platform darwin; echo SHOULD_NOT_APPEAR")"
rc=$?
clean="$(strip_ansi "$out")"
if [[ $rc -ne 0 ]] && [[ "$clean" == *"ERROR"* ]] && [[ "$out" != *"SHOULD_NOT_APPEAR"* ]]; then
    assert_pass "[SPEC-8] skip_on_platform invalid platform: exits non-zero with ERROR"
else
    assert_fail "[SPEC-8] skip_on_platform invalid platform: exits non-zero with ERROR" \
        "rc=$rc out=$clean"
fi

# ─── [SPEC-9]: skip_unless_capable with a passing probe → execution continues ─
out="$(run_in_subshell 'skip_unless_capable "cannot happen" true; echo CONTINUED')"
if [[ "$out" == *"CONTINUED"* ]]; then
    assert_pass "[SPEC-9] skip_unless_capable passing probe: execution continues"
else
    assert_fail "[SPEC-9] skip_unless_capable passing probe: execution continues" "got: $out"
fi

# ─── [SPEC-10]: skip_unless_capable with a failing probe → exits 0 with SKIP ──
out="$(run_in_subshell 'skip_unless_capable "probe failed" false; echo SHOULD_NOT_APPEAR')"
rc=$?
clean="$(strip_ansi "$out")"
if [[ $rc -eq 0 ]] && [[ "$clean" == *"SKIP"* ]] && [[ "$out" != *"SHOULD_NOT_APPEAR"* ]]; then
    assert_pass "[SPEC-10] skip_unless_capable failing probe: exits 0 with SKIP"
else
    assert_fail "[SPEC-10] skip_unless_capable failing probe: exits 0 with SKIP" \
        "rc=$rc out=$clean"
fi

print_test_results
