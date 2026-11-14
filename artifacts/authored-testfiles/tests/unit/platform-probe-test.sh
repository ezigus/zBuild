#!/usr/bin/env bash
# tests/unit/platform-probe-test.sh — verify that zbuild_sed_inplace and
# _zb_target_mode_v make tool-form decisions from a probe run once at load
# time, not from ZBUILD_PLATFORM.
#
# Covers: DSPRB-1, DSPRB-2, DSPRB-3, DSPRB-4, DSPRB-5, DSDEL-1, DSADR-3

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"

print_test_header "platform probe: load-time tool-form decisions (ADR-009)"
setup_test_env "platform-probe"

# Capture real tool paths before any mock is installed in TEST_TEMP_DIR/bin.
_real_sed="$(command -v sed)"
_real_stat="$(command -v stat)"

# ─── DSPRB-1: zbuild_sed_inplace works despite ZBUILD_PLATFORM=macos ─────────
print_test_section "DSPRB-1: zbuild_sed_inplace works despite wrong ZBUILD_PLATFORM"

# Given — a file containing text that the substitution expression will change
_f1="$TEST_TEMP_DIR/sed-target.txt"
printf 'old content\n' > "$_f1"

# When — ZBUILD_PLATFORM=macos is exported before sourcing compat.sh (Given);
# compat.sh sets ZBUILD_PLATFORM from uname (overwrites to linux on Linux CI).
# After sourcing the wrong value is re-asserted so old code (reading at call
# time) picks `sed -i ''` (BSD), which GNU sed rejects; new code uses the
# probe stored at load time and ignores ZBUILD_PLATFORM entirely.
(
    export ZBUILD_PLATFORM=macos    # exported before sourcing compat.sh (Given)
    unset _ZBUILD_COMPAT_LOADED || true
    # shellcheck source=../../scripts/lib/compat.sh
    source "$REPO_ROOT/scripts/lib/compat.sh"
    # compat.sh overwrites ZBUILD_PLATFORM from uname on Linux CI; re-assert
    # the wrong value so old code takes the wrong-platform branch at call time.
    ZBUILD_PLATFORM=macos
    zbuild_sed_inplace 's/old/new/' "$_f1"
); _dsprb1_rc=$?

# Then
assert_eq "[DSPRB-1] exit code is 0 — file edited despite wrong ZBUILD_PLATFORM" \
    "0" "$_dsprb1_rc"
assert_eq "[DSPRB-1] the file content is changed as directed by the expression" \
    "new content" "$(cat "$_f1")"

# ─── DSPRB-2: _zb_target_mode_v returns valid mode despite wrong platform ─────
print_test_section "DSPRB-2: _zb_target_mode_v returns valid mode despite wrong ZBUILD_PLATFORM"

# Given — a file with known mode and a mock stat that makes the BSD -f form
# return a wrong-but-valid-looking mode ("255").  Base code on ZBUILD_PLATFORM=macos
# uses -f first and accepts 255 without trying the fallback.  New code uses the
# probe (GNU -c form) and never calls -f, so the actual mode comes back.
_f2="$TEST_TEMP_DIR/mode-target.txt"
printf 'test\n' > "$_f2"
chmod 644 "$_f2"
_actual_mode="$("$_real_stat" -c '%a' "$_f2")"

_mock2="$TEST_TEMP_DIR/mock-stat2"
mkdir -p "$_mock2"
cat > "$_mock2/stat" << EOF
#!/usr/bin/env bash
# BSD form (-f): return a wrong but valid-looking mode so the caller cannot
# fall back and still get the right answer.
if [[ "\${1:-}" == "-f" ]]; then echo "255"; exit 0; fi
exec "$_real_stat" "\$@"
EOF
chmod +x "$_mock2/stat"

# When — ZBUILD_PLATFORM=macos is exported before sourcing helpers.sh (Given);
# helpers.sh sources compat.sh, which overwrites on Linux CI. After sourcing
# the wrong value is re-asserted so old code (reading at call time) calls
# stat -f (mock returns "255"); new code uses the probe result.
_dsprb2_mode=$(
    unset _ZBUILD_COMPAT_LOADED _ZBUILD_HELPERS_LOADED || true
    export PATH="$_mock2:$PATH"
    export ZBUILD_PLATFORM=macos    # exported before sourcing helpers.sh (Given)
    # shellcheck source=../../scripts/lib/helpers.sh
    source "$REPO_ROOT/scripts/lib/helpers.sh"
    # helpers.sh sources compat.sh, which sets ZBUILD_PLATFORM=linux on Linux CI;
    # re-assert the wrong value so old code takes the wrong-platform branch at call time.
    ZBUILD_PLATFORM=macos
    _mode_out=""
    _zb_target_mode_v _mode_out "$_f2"
    printf '%s' "$_mode_out"
)

# Then
assert_contains_regex "[DSPRB-2] the nameref variable matches ^[0-7]{3,4}$" \
    "$_dsprb2_mode" "^[0-7]{3,4}$"
assert_eq "[DSPRB-2] mode matches actual mode (not mock BSD value '255')" \
    "$_actual_mode" "$_dsprb2_mode"

# ─── DSPRB-3: stat probe encodes GNU form at load time ────────────────────────
print_test_section "DSPRB-3: stat probe uses GNU -c form when host stat supports it"

# Given — scripts/lib/helpers.sh is sourced on a host where stat -c '%a'
# succeeds on a known path (Linux CI always satisfies this).

# When — source helpers.sh in a subshell and inspect the stat probe module
# variable _ZB_STAT_MODE_CMD immediately after sourcing, before any call to
# _zb_target_mode_v.
_dsprb3_cmd=$(
    unset _ZBUILD_COMPAT_LOADED _ZBUILD_HELPERS_LOADED || true
    # shellcheck source=../../scripts/lib/helpers.sh
    source "$REPO_ROOT/scripts/lib/helpers.sh"
    printf '%s' "${_ZB_STAT_MODE_CMD:-}"
)

# Then — _ZB_STAT_MODE_CMD is non-empty and encodes the GNU -c form, not BSD -f.
# Base code: no probe → _ZB_STAT_MODE_CMD unset → empty → "-c" absent → FAIL.
# New code: probe runs at load time, tries -c first (RQPRO-3), succeeds on
# Linux CI → stores the -c form in _ZB_STAT_MODE_CMD → assertion passes.
assert_contains "[DSPRB-3] the stat probe encodes the GNU -c form (not BSD -f)" \
    "$_dsprb3_cmd" "-c"

# ─── DSPRB-4: exactly one stat call per _zb_target_mode_v invocation ──────────
print_test_section "DSPRB-4: each _zb_target_mode_v runs exactly one stat command"

# Given — helpers.sh loaded with a counting stat; probe calls are cleared
# before the function call so only per-call stats are counted.
_f4="$TEST_TEMP_DIR/mode-count-target.txt"
printf 'count-test\n' > "$_f4"
chmod 644 "$_f4"
_calls4="$TEST_TEMP_DIR/dsprb4-calls"
: > "$_calls4"
_mock4="$TEST_TEMP_DIR/mock-stat4"
mkdir -p "$_mock4"
cat > "$_mock4/stat" << EOF
#!/usr/bin/env bash
printf 'stat\n' >> "$_calls4"
exec "$_real_stat" "\$@"
EOF
chmod +x "$_mock4/stat"

# When — source helpers.sh (probe runs, calls land in _calls4), reset the
# counter, set ZBUILD_PLATFORM to the wrong value, then call _zb_target_mode_v
# exactly once.
# Base code with ZBUILD_PLATFORM=macos: stat -f '%Lp' (call 1, fails on GNU),
# fallback stat -c '%a' (call 2) = 2 calls → assertion fails.
# New code uses probe result (single stat -c '%a') = 1 call → passes.
(
    unset _ZBUILD_COMPAT_LOADED _ZBUILD_HELPERS_LOADED || true
    export PATH="$_mock4:$PATH"
    # shellcheck source=../../scripts/lib/helpers.sh
    source "$REPO_ROOT/scripts/lib/helpers.sh"
    : > "$_calls4"          # exclude load-time probe calls from the count
    ZBUILD_PLATFORM=macos   # wrong value — new code ignores it
    _mode_out4=""
    _zb_target_mode_v _mode_out4 "$_f4"
)
_dsprb4_count="$(wc -l < "$_calls4" | tr -d ' ')"

# Then
assert_eq "[DSPRB-4] exactly one stat process runs per _zb_target_mode_v call" \
    "1" "$_dsprb4_count"

# ─── DSPRB-5: sed probe variable is set at compat.sh load time ───────────────
print_test_section "DSPRB-5: sed probe runs at compat.sh load time, not per call"

# Given — a fresh shell (compat.sh not yet loaded)

# When — source compat.sh in a subshell and inspect the sed probe module
# variable _ZB_SED_INPLACE_ARGS immediately after sourcing, before any call
# to zbuild_sed_inplace.
_dsprb5_len=$(
    unset _ZBUILD_COMPAT_LOADED || true
    # shellcheck source=../../scripts/lib/compat.sh
    source "$REPO_ROOT/scripts/lib/compat.sh"
    if declare -p _ZB_SED_INPLACE_ARGS >/dev/null 2>&1; then
        printf '%d' "${#_ZB_SED_INPLACE_ARGS[@]}"
    else
        printf '0'
    fi
)

# Then — _ZB_SED_INPLACE_ARGS has at least one element (probe ran at load time).
# Base code: no probe → _ZB_SED_INPLACE_ARGS not declared → len 0 → FAIL.
# New code: probe runs at source time, sets _ZB_SED_INPLACE_ARGS → len ≥ 1 → PASS.
assert_gt "[DSPRB-5] the sed probe module variable is non-empty (set at load time)" \
    "$_dsprb5_len" "0"

# ─── DSDEL-1: zbuild_stat_size is not defined after sourcing compat.sh ────────
print_test_section "DSDEL-1: zbuild_stat_size is absent from compat.sh"

# When — source compat.sh in a fresh subshell and inspect the function registry.
_dsdel1_rc=$(
    unset _ZBUILD_COMPAT_LOADED || true
    # shellcheck source=../../scripts/lib/compat.sh
    source "$REPO_ROOT/scripts/lib/compat.sh"
    declare -f zbuild_stat_size > /dev/null 2>&1
    printf '%d' "$?"
)

# Then — declare -f exits non-zero because the function no longer exists.
# Base code defines zbuild_stat_size → declare -f exits 0 → "0" ≠ "1" → FAIL.
assert_eq "[DSDEL-1] declare -f zbuild_stat_size exits non-zero (function absent)" \
    "1" "$_dsdel1_rc"

# ─── DSADR-3: zbuild_sed_inplace keeps its original name ─────────────────────
print_test_section "DSADR-3: zbuild_sed_inplace name is unchanged (ADR-020 unaffected)"

# When — source compat.sh in a fresh subshell after the probe change.
_dsadr3_rc=$(
    unset _ZBUILD_COMPAT_LOADED || true
    # shellcheck source=../../scripts/lib/compat.sh
    source "$REPO_ROOT/scripts/lib/compat.sh"
    declare -f zbuild_sed_inplace > /dev/null 2>&1
    printf '%d' "$?"
)

# Then — declare -f exits 0 because the function is defined under its original name.
# This must pass on both old and new code (the name was not changed).
assert_eq "[DSADR-3] declare -f zbuild_sed_inplace exits 0 (function defined under original name)" \
    "0" "$_dsadr3_rc"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
