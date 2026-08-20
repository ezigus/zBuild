#!/usr/bin/env bash
# Unit: scripts/lib/env-scrub.sh — _zbuild_make_fresh_shell helper (ADR-024, #671)
#
# Asserts:
#   1. ZBUILD_* env vars are scrubbed in the calling shell
#   2. Non-ZBUILD_* vars are preserved
#   3. fd 3 is closed after the helper runs
#   4. _TPL_* env vars are scrubbed; non-_TPL_ vars preserved
#      (Wave 15-I / #683 — template state must not survive the boundary)
#   5. Helper is idempotent (second call is a no-op, no error)
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

print_test_section "5. clears a DOUBLE-BOUND name (#1873)"

# #1873: one `unset` clears one binding. When a name is bound BOTH as a `local -x`
# in an enclosing function frame AND as a global export, a single unset peels the
# local and reveals the global underneath — the scrub reports success and the
# variable is still there in the spawned process.
#
# #1862 (c0d66a0) created exactly that shape: core/plugin-registry/lifecycle.sh
# declares `local -x ZBUILD_CURRENT_STAGE` around every plugin hook dispatch,
# while core/pipeline/runner.sh and the orchestrators already export the same
# name globally. The test stage's suite therefore inherited ZBUILD_CURRENT_STAGE=test,
# which event-bus.sh appends as a top-level `stage` key — breaking the canonical
# 8-key envelope goldens in engine-event-shape-test.sh and the post-group
# unset assertion in parallel-orchestrator-test.sh.
_dbl_hook() {
    # Mirrors lifecycle.sh's dispatch seam (ADR-054 §3.1) — this `local -x` is
    # correct and stays; the scrub is what must hold under the nesting.
    local -x ZBUILD_CURRENT_STAGE="test"
    (
        _zbuild_make_fresh_shell 2>/dev/null
        bash -c 'printf "double=%s\n" "${ZBUILD_CURRENT_STAGE:-<unset>}"'
    )
}
dbl_result="$(
    export ZBUILD_CURRENT_STAGE=test   # runner.sh:2806 global export
    _dbl_hook
)"
assert_contains "double-bound ZBUILD_CURRENT_STAGE cleared into spawned shell" \
    "$dbl_result" "double=<unset>"

# Guard: the single-bound case (pre-#1862 shape) must keep working.
sgl_result="$(
    export ZBUILD_CURRENT_STAGE=test
    _zbuild_make_fresh_shell 2>/dev/null
    bash -c 'printf "single=%s\n" "${ZBUILD_CURRENT_STAGE:-<unset>}"'
)"
assert_contains "single-bound ZBUILD_CURRENT_STAGE still cleared (guard)" \
    "$sgl_result" "single=<unset>"

print_test_section "6. a readonly ZBUILD_* name cannot spin the loop (#1873)"

# The unset-until-gone loop must not become infinite on a name `unset` can never
# clear. Bounded by an external timeout so a regression FAILS instead of hanging.
_to_bin=""
if   command -v gtimeout >/dev/null 2>&1; then _to_bin="gtimeout"
elif command -v timeout  >/dev/null 2>&1; then _to_bin="timeout"
fi

if [[ -z "$_to_bin" ]]; then
    # Section-scoped skip: skip_unless_capable ends the whole file, and the
    # other sections here are still exercisable without a timeout binary.
    SKIP=$((SKIP + 1))
    echo -e "  ${YELLOW}SKIP${RESET}: readonly-spin guard (no timeout/gtimeout on PATH)" >&2
else
    ro_rc=0
    "$_to_bin" 10 bash -c '
        source "'"$REPO_ROOT"'/scripts/lib/env-scrub.sh"
        readonly ZBUILD_READONLY_PROBE=stuck
        export ZBUILD_ALSO_SET=clearme
        _zbuild_make_fresh_shell 2>/dev/null
        # Reaching here at all proves the inner loop terminated. The scrub must
        # also have carried on past the stuck name to the rest of the namespace.
        printf "also=%s\n" "${ZBUILD_ALSO_SET:-<unset>}"
    ' > "$TEST_TEMP_DIR/ro-probe.out" 2>/dev/null || ro_rc=$?

    assert_eq "scrub terminates on a readonly ZBUILD_* name (not rc=124)" \
        "0" "$ro_rc"
    assert_contains "scrub still clears other names after a readonly one" \
        "$(cat "$TEST_TEMP_DIR/ro-probe.out" 2>/dev/null || true)" "also=<unset>"
fi

print_test_results
exit $((FAIL > 0))
