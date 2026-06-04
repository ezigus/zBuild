#!/usr/bin/env bash
# Unit: scripts/lib/env-scrub.sh — _zbuild_make_fresh_shell helper (ADR-024, #671)
#
# Asserts:
#   1. ZBUILD_* env vars are scrubbed in the calling shell
#   2. Non-ZBUILD_* vars are preserved
#   3. fd 3 is closed after the helper runs
#   4. Helper is idempotent (second call is a no-op, no error)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "unit: env-scrub _zbuild_make_fresh_shell (#671)"

# shellcheck source=../../scripts/lib/env-scrub.sh
source "$REPO_ROOT/scripts/lib/env-scrub.sh"

print_test_section "1. scrubs ZBUILD_* and preserves non-ZBUILD_*"

# Run the helper in a subshell so the test's own env stays intact.
result="$(
    export ZBUILD_FOO=a
    export ZBUILD_BAR=b
    export NON_ZBUILD_VAR=c
    _zbuild_make_fresh_shell 2>/dev/null
    printf 'ZBUILD_FOO=%s\n' "${ZBUILD_FOO:-<unset>}"
    printf 'ZBUILD_BAR=%s\n' "${ZBUILD_BAR:-<unset>}"
    printf 'NON_ZBUILD_VAR=%s\n' "${NON_ZBUILD_VAR:-<unset>}"
)"

assert_contains "ZBUILD_FOO unset after scrub" "ZBUILD_FOO=<unset>" "$result"
assert_contains "ZBUILD_BAR unset after scrub" "ZBUILD_BAR=<unset>" "$result"
assert_contains "NON_ZBUILD_VAR preserved" "NON_ZBUILD_VAR=c" "$result"

print_test_section "2. fd 3 is closed after helper"

SENTINEL="$TEST_TEMP_DIR/env-scrub-sentinel"
: > "$SENTINEL"

# Open fd 3 in a subshell, call helper, then probe fd 3.
fd_probe="$(
    exec 3>"$SENTINEL"
    # Sanity: fd 3 open before scrub
    if ! ( : >&3 ) 2>/dev/null; then
        printf 'BUG: fd 3 not open pre-scrub\n'
        exit 1
    fi
    _zbuild_make_fresh_shell 2>/dev/null
    if ( : >&3 ) 2>/dev/null; then
        printf 'OPEN\n'
    else
        printf 'CLOSED\n'
    fi
)"

assert_eq "fd 3 closed after helper" "CLOSED" "$fd_probe"
assert_eq "sentinel file received no writes" "" "$(cat "$SENTINEL" 2>/dev/null || true)"

print_test_section "3. scrubs _TPL_* (Wave 15-I / #683)"

# Wave 15-I: template.sh load_template EXPORTS per-stage _TPL_STAGE_* env vars.
# These survived `npm test` fork boundary pre-fix and contaminated integration
# tests running under the pipeline test stage (fd-3 sentinel leak via leaked
# _TPL_STAGE_IO_DESTS_test; Tr-5 router timeout via leaked
# _TPL_STAGE_ROUTER_TIMEOUT_plan). The scrub now covers _TPL_* too.
tpl_result="$(
    export _TPL_STAGE_IO_DESTS_test="file,stdout"
    export _TPL_STAGE_ROUTER_TIMEOUT_plan=300
    export _TPL_STAGES_FOO=bar
    export NON_TPL_KEEP=keepme
    _zbuild_make_fresh_shell 2>/dev/null
    printf '_TPL_STAGE_IO_DESTS_test=%s\n' "${_TPL_STAGE_IO_DESTS_test:-<unset>}"
    printf '_TPL_STAGE_ROUTER_TIMEOUT_plan=%s\n' "${_TPL_STAGE_ROUTER_TIMEOUT_plan:-<unset>}"
    printf '_TPL_STAGES_FOO=%s\n' "${_TPL_STAGES_FOO:-<unset>}"
    printf 'NON_TPL_KEEP=%s\n' "${NON_TPL_KEEP:-<unset>}"
)"

assert_contains "_TPL_STAGE_IO_DESTS_test unset after scrub" \
    "_TPL_STAGE_IO_DESTS_test=<unset>" "$tpl_result"
assert_contains "_TPL_STAGE_ROUTER_TIMEOUT_plan unset after scrub" \
    "_TPL_STAGE_ROUTER_TIMEOUT_plan=<unset>" "$tpl_result"
assert_contains "_TPL_STAGES_FOO unset after scrub" \
    "_TPL_STAGES_FOO=<unset>" "$tpl_result"
assert_contains "NON_TPL_KEEP preserved" \
    "NON_TPL_KEEP=keepme" "$tpl_result"

print_test_section "4. idempotent on repeat call"

idem_rc=0
(
    export ZBUILD_FOO=a
    _zbuild_make_fresh_shell 2>/dev/null
    _zbuild_make_fresh_shell 2>/dev/null
) || idem_rc=$?
assert_eq "second call returns 0 (no error)" "0" "$idem_rc"

print_test_results
exit $((FAIL > 0))
