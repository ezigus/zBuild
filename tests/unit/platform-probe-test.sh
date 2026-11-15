#!/usr/bin/env bash
# tests/unit/platform-probe-test.sh — verify that zbuild_sed_inplace and
# _zb_target_mode_v make tool-form decisions from a probe run once at load
# time, not from ZBUILD_PLATFORM.
#
# Covers: DSPRB-1, DSPRB-2, DSPRB-3, DSPRB-4, DSPRB-5, DSPRB-6, DSDEL-1, DSADR-3

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

# ─── DSPRB-1: zbuild_sed_inplace works despite a wrong ZBUILD_PLATFORM ──────
print_test_section "DSPRB-1: zbuild_sed_inplace works despite wrong ZBUILD_PLATFORM"

# Given — a file the expression changes. Code that picks its sed -i form from
# ZBUILD_PLATFORM takes the wrong form for one of the two names below on any
# host: GNU sed reads `-i ''` as a file, BSD sed reads `-i` with no suffix as
# taking the expression for one.
_f1="$TEST_TEMP_DIR/sed-target.txt"
for _wrong in macos linux; do
    printf 'old content\n' > "$_f1"
    (
        unset _ZBUILD_COMPAT_LOADED || true
        # shellcheck source=../../scripts/lib/compat.sh
        source "$REPO_ROOT/scripts/lib/compat.sh"
        ZBUILD_PLATFORM="$_wrong"

        # When — zbuild_sed_inplace is called with ZBUILD_PLATFORM set to that name
        zbuild_sed_inplace 's/old/new/' "$_f1"
    ) >/dev/null 2>&1; _dsprb1_rc=$?

    # Then
    assert_eq "[DSPRB-1] ZBUILD_PLATFORM=$_wrong: the file is edited" \
        "0|new content" "$_dsprb1_rc|$(cat "$_f1")"
done

# ─── DSPRB-2: _zb_target_mode_v returns valid mode despite wrong platform ─────
print_test_section "DSPRB-2: _zb_target_mode_v returns valid mode despite wrong ZBUILD_PLATFORM"

# Given — a file at mode 640, and a stat that answers the form this host does
# not have with a wrong but valid-looking mode (255) for that file. Code that
# picks its form from ZBUILD_PLATFORM takes the wrong form for one of the two
# names below on any host, and gets 255.
_f2="$TEST_TEMP_DIR/mode-target.txt"
printf 'test\n' > "$_f2"
chmod 640 "$_f2"
_mock2="$TEST_TEMP_DIR/mock-stat2"
mkdir -p "$_mock2"
cat > "$_mock2/stat" << EOF
#!/usr/bin/env bash
out="\$("$_real_stat" "\$@" 2>/dev/null)"; rc=\$?
if [[ "\${*: -1}" == "$_f2" && ! "\$out" =~ ^[0-7]{3,4}\$ ]]; then echo 255; exit 0; fi
printf '%s\n' "\$out"; exit "\$rc"
EOF
chmod +x "$_mock2/stat"

for _wrong in macos linux; do
    _dsprb2_mode=$(
        unset _ZBUILD_COMPAT_LOADED _ZBUILD_HELPERS_LOADED || true
        export PATH="$_mock2:$PATH"
        # shellcheck source=../../scripts/lib/helpers.sh
        source "$REPO_ROOT/scripts/lib/helpers.sh"
        ZBUILD_PLATFORM="$_wrong"
        _mode_out=""

        # When — _zb_target_mode_v is called with ZBUILD_PLATFORM set to that name
        _zb_target_mode_v _mode_out "$_f2"
        printf '%s' "$_mode_out"
    )

    # Then
    assert_eq "[DSPRB-2] ZBUILD_PLATFORM=$_wrong: the file's own mode, not the wrong form's 255" \
        "640" "$_dsprb2_mode"
done

# ─── DSPRB-3: the stat probe tries the GNU form first ────────────────────────
print_test_section "DSPRB-3: the stat probe tries the GNU -c form first"

# Given — a stat that answers a mode for either form, so only the order the
# probe tries them in decides.
_mock3="$TEST_TEMP_DIR/mock-stat3"
mkdir -p "$_mock3"
printf '#!/usr/bin/env bash\necho 644\n' > "$_mock3/stat"
chmod +x "$_mock3/stat"

# When — helpers.sh is sourced and the probe's choice read before any call
_dsprb3_cmd=$(
    unset _ZBUILD_COMPAT_LOADED _ZBUILD_HELPERS_LOADED || true
    export PATH="$_mock3:$PATH"
    # shellcheck source=../../scripts/lib/helpers.sh
    source "$REPO_ROOT/scripts/lib/helpers.sh"
    printf '%s' "${_ZB_STAT_MODE_CMD:-}"
)

# Then
assert_eq "[DSPRB-3] the probe chose the GNU -c form" "-c" "$_dsprb3_cmd"

# ─── DSPRB-6: the stat probe takes a form only when it answers a mode ───────
print_test_section "DSPRB-6: a -c form that exits 0 but answers no mode is not chosen"

# Given — a stat whose -c form exits 0 but prints no mode (a shim)
_mock6="$TEST_TEMP_DIR/mock-stat6"
mkdir -p "$_mock6"
printf '#!/usr/bin/env bash\n[[ "$1" == -c ]] && { echo "File: x"; exit 0; }\necho 644\n' > "$_mock6/stat"
chmod +x "$_mock6/stat"

# When — helpers.sh is sourced and the probe's choice read
_dsprb6_cmd=$(
    unset _ZBUILD_COMPAT_LOADED _ZBUILD_HELPERS_LOADED || true
    export PATH="$_mock6:$PATH"
    # shellcheck source=../../scripts/lib/helpers.sh
    source "$REPO_ROOT/scripts/lib/helpers.sh"
    printf '%s' "${_ZB_STAT_MODE_CMD:-}"
)

# Then
assert_eq "[DSPRB-6] the probe chose the -f form" "-f" "$_dsprb6_cmd"

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

# Given — helpers.sh is sourced with the stat probe set by load-time code;
# probe calls are cleared before the function call so only per-call stats
# are counted. Base code with ZBUILD_PLATFORM=macos: stat -f '%Lp' (call 1,
# fails on GNU), fallback stat -c '%a' (call 2) = 2 calls → assertion fails.
# New code uses probe result (single stat -c '%a') = 1 call → passes.
(
    unset _ZBUILD_COMPAT_LOADED _ZBUILD_HELPERS_LOADED || true
    export PATH="$_mock4:$PATH"
    # shellcheck source=../../scripts/lib/helpers.sh
    source "$REPO_ROOT/scripts/lib/helpers.sh"
    : > "$_calls4"          # exclude load-time probe calls from the count
    ZBUILD_PLATFORM=macos   # wrong value — new code ignores it
    _mode_out4=""

    # When — _zb_target_mode_v is called exactly once
    _zb_target_mode_v _mode_out4 "$_f4"
)
_dsprb4_count="$(wc -l < "$_calls4" | tr -d ' ')"

# Then
assert_eq "[DSPRB-4] exactly one stat process runs per _zb_target_mode_v call" \
    "1" "$_dsprb4_count"

# ─── DSPRB-5: sed probe variable is set at compat.sh load time ───────────────
print_test_section "DSPRB-5: sed probe runs at compat.sh load time, not per call"

# Given — compat.sh sourced in a fresh shell (not yet loaded before sourcing)
_dsprb5_len=$(
    unset _ZBUILD_COMPAT_LOADED || true
    # shellcheck source=../../scripts/lib/compat.sh
    source "$REPO_ROOT/scripts/lib/compat.sh"

    # When — the sed probe module variable is inspected immediately after
    # sourcing, before any call to zbuild_sed_inplace
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
