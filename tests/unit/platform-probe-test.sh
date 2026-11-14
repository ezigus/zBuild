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

# When — source compat.sh (which runs any load-time probe), then override
# ZBUILD_PLATFORM to the wrong value for this host; call zbuild_sed_inplace.
# Base code reads ZBUILD_PLATFORM at call time and picks `sed -i ''` (BSD),
# which on GNU sed treats '' as the script and treats the expression as a
# filename that does not exist — the edit fails.
# New code uses the probe result (GNU form) and ignores ZBUILD_PLATFORM.
(
    unset _ZBUILD_COMPAT_LOADED || true
    # shellcheck source=../../scripts/lib/compat.sh
    source "$REPO_ROOT/scripts/lib/compat.sh"
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

# When — source helpers.sh in a subshell with the mock stat, then override
# ZBUILD_PLATFORM to the wrong value and call _zb_target_mode_v.
_dsprb2_mode=$(
    unset _ZBUILD_COMPAT_LOADED _ZBUILD_HELPERS_LOADED || true
    export PATH="$_mock2:$PATH"
    # shellcheck source=../../scripts/lib/helpers.sh
    source "$REPO_ROOT/scripts/lib/helpers.sh"
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

# Given — a recording stat that appends its argument list to a log file.
# The log captures every stat call made while helpers.sh loads.  On GNU
# (Linux CI) stat -c '%a' succeeds, so the probe stores that form.
_calls3="$TEST_TEMP_DIR/dsprb3-calls"
: > "$_calls3"
_mock3="$TEST_TEMP_DIR/mock-stat3"
mkdir -p "$_mock3"
cat > "$_mock3/stat" << EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$_calls3"
exec "$_real_stat" "\$@"
EOF
chmod +x "$_mock3/stat"

# When — source helpers.sh in a subshell with the recording stat.
(
    unset _ZBUILD_COMPAT_LOADED _ZBUILD_HELPERS_LOADED || true
    export PATH="$_mock3:$PATH"
    # shellcheck source=../../scripts/lib/helpers.sh
    source "$REPO_ROOT/scripts/lib/helpers.sh"
)

# Then — the probe ran at load time (calls file is non-empty) and the first
# call used the GNU -c form.
# Base code: no probe → empty file → first call is "" → -c not found → FAIL.
_dsprb3_first=""
{ IFS= read -r _dsprb3_first || true; } < "$_calls3"
assert_contains "[DSPRB-3] the stat probe encodes the GNU -c form (first call uses -c)" \
    "$_dsprb3_first" "-c"

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

# Given — a recording sed that appends a marker to a log file for every call.
# A probe run at load time will make at least one sed call during source;
# base code has no probe, so zero sed calls happen during source.
_sed_calls5="$TEST_TEMP_DIR/dsprb5-sed-calls"
: > "$_sed_calls5"
_mock5="$TEST_TEMP_DIR/mock-sed5"
mkdir -p "$_mock5"
cat > "$_mock5/sed" << EOF
#!/usr/bin/env bash
printf 'sed\n' >> "$_sed_calls5"
exec "$_real_sed" "\$@"
EOF
chmod +x "$_mock5/sed"

# When — source compat.sh in a subshell with the recording sed; inspect the
# counter before zbuild_sed_inplace is ever called.
(
    unset _ZBUILD_COMPAT_LOADED || true
    export PATH="$_mock5:$PATH"
    # shellcheck source=../../scripts/lib/compat.sh
    source "$REPO_ROOT/scripts/lib/compat.sh"
)
_dsprb5_load_calls="$(wc -l < "$_sed_calls5" | tr -d ' ')"

# Then — sed was called at least once during source (probe ran at load time).
assert_gt "[DSPRB-5] sed probe ran at load time (non-zero calls during source)" \
    "$_dsprb5_load_calls" "0"

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
