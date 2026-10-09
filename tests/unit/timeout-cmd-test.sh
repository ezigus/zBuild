#!/usr/bin/env bash
# Tests: scripts/lib/timeout-cmd.sh — the one shared timeout helper (#1752, ADR-036
# amendment 2026-10-09).
#
# H1-H3  on a host with only `gtimeout`, the helper builds a gtimeout bound, with
#        `-k <grace>` when the binary supports it (grace from the argument, else
#        ZBUILD_NEGCTL_KILL_GRACE, else 10)
# H4     `none` asks for a TERM-only bound: no `-k`, and no probe is spent on it
# H5     the `-k` probe runs once per process
# H6     no binary at all → empty bound, rc 0 (the caller runs unbounded — never
#        skips the command)
# C1-C2  the contract-lib snapshot carries the helper: the closure lists it, and
#        acceptance-block.sh loaded from a snapshot defines the helper (the first
#        dogfood of #1752 graded itself vacuously when it did not)
# C3     build's summary.sh still loads acceptance-block.sh when the helper alone
#        is already defined (route.sh now loads it)
#
# The no-`timeout` host is a PATH holding every tool on this machine EXCEPT
# timeout/gtimeout, plus a recording `gtimeout` shim — never test-helpers.sh's
# `timeout` mock, which ignores its duration and so cannot show a bound.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "timeout-cmd.sh — one shared timeout helper (#1752)"
setup_test_env "timeout-cmd"
_test_cleanup_hook() { cleanup_test_env; }

HELPER="$REPO_ROOT/scripts/lib/timeout-cmd.sh"

# ─── the gtimeout-only host ──────────────────────────────────────────────────
FARM="$TEST_TEMP_DIR/farm"; SHIM="$TEST_TEMP_DIR/shim"; NOK="$TEST_TEMP_DIR/shim-nok"
mkdir -p "$FARM" "$SHIM" "$NOK"
IFS=: read -r -a _path_dirs <<< "$PATH"
for _d in "${_path_dirs[@]}"; do
    [[ -d "$_d" ]] || continue
    for _f in "$_d"/*; do
        _n="${_f##*/}"
        [[ "$_n" == timeout || "$_n" == gtimeout ]] && continue
        [[ -x "$_f" && ! -e "$FARM/$_n" ]] && ln -s "$_f" "$FARM/$_n" 2>/dev/null || true
    done
done
# Records its argv, then runs the command the way timeout(1) would.
cat > "$SHIM/gtimeout" <<SH
#!$BASH
printf '%s\n' "\$*" >> "\$GT_LOG"
[[ "\$1" == "-k" ]] && shift 2
shift
"\$@"
SH
# A gtimeout that rejects -k, as a pre-7.0 coreutils would.
cat > "$NOK/gtimeout" <<SH
#!$BASH
printf '%s\n' "\$*" >> "\$GT_LOG"
[[ "\$1" == "-k" ]] && exit 125
shift
"\$@"
SH
chmod +x "$SHIM/gtimeout" "$NOK/gtimeout"
export GT_LOG="$TEST_TEMP_DIR/gt.log"
GT_ONLY="$SHIM:$FARM"

# _bound <PATH> <args...> — source the helper in a fresh shell on <PATH>, call it,
# print `rc=<rc> argv=<_ACCEPTANCE_TOUT>`.
_bound() {
    local p="$1"; shift
    env -u _ACCEPTANCE_TIMEOUT_KILL_OK PATH="$p" "$BASH" -c '
        source "$1" || exit 99; shift
        rc=0; _acceptance_timeout_prefix "$@" || rc=$?
        printf "rc=%s argv=%s\n" "$rc" "${_ACCEPTANCE_TOUT[*]}"' _ "$HELPER" "$@" 2>&1
}

print_test_section "H: the helper on a host with only gtimeout"
: > "$GT_LOG"
assert_eq "[H1] gtimeout-only host → gtimeout bound with -k and the default grace" \
    "rc=0 argv=gtimeout -k 10 33" "$(_bound "$GT_ONLY" 33)"
assert_eq "[H2] a grace argument feeds -k" \
    "rc=0 argv=gtimeout -k 4 33" "$(_bound "$GT_ONLY" 33 4)"
assert_eq "[H3] with no grace argument ZBUILD_NEGCTL_KILL_GRACE feeds -k" \
    "rc=0 argv=gtimeout -k 7 33" "$(ZBUILD_NEGCTL_KILL_GRACE=7 _bound "$GT_ONLY" 33)"
assert_eq "[H3] a gtimeout without -k → TERM-only bound" \
    "rc=0 argv=gtimeout 33" "$(_bound "$NOK:$FARM" 33 4)"

: > "$GT_LOG"
assert_eq "[H4] 'none' → TERM-only bound" "rc=0 argv=gtimeout 33" "$(_bound "$GT_ONLY" 33 none)"
assert_eq "[H4] 'none' spends no -k probe" "" "$(cat "$GT_LOG")"

: > "$GT_LOG"
_twice="$(env -u _ACCEPTANCE_TIMEOUT_KILL_OK PATH="$GT_ONLY" "$BASH" -c '
    source "$1"; _acceptance_timeout_prefix 5; _acceptance_timeout_prefix 6 2
    printf "%s\n" "${_ACCEPTANCE_TOUT[*]}"' _ "$HELPER" 2>&1)"
assert_eq "[H5] the second call still binds" "gtimeout -k 2 6" "$_twice"
assert_eq "[H5] the -k probe ran once in the process" "1" \
    "$(/usr/bin/grep -c -- '^-k 1 1 ' "$GT_LOG" || true)"

assert_eq "[H6] neither binary → empty bound, rc 0" "rc=0 argv=" "$(_bound "$FARM" 33)"

print_test_section "C: the contract-lib snapshot carries the helper"
# shellcheck source=/dev/null
source "$REPO_ROOT/core/pipeline/runner.sh" >/dev/null 2>&1 || true
declare -F _runner_contract_lib_closure >/dev/null 2>&1 \
    || _runner_contract_lib_closure() { return 1; }
declare -F _runner_snapshot_contract_libs >/dev/null 2>&1 \
    || _runner_snapshot_contract_libs() { return 1; }
assert_contains "[C1] the contract-lib closure lists timeout-cmd.sh" \
    "$(_runner_contract_lib_closure "$REPO_ROOT/scripts/lib" || true)" "timeout-cmd.sh"

SNAP="$TEST_TEMP_DIR/snap"
_runner_snapshot_contract_libs "$REPO_ROOT/scripts/lib" "$SNAP" >/dev/null 2>&1 || true
_snap_out="$("$BASH" -c '
    source "$1/acceptance-block.sh" 2>&1
    _acceptance_timeout_prefix 9 && declare -F _acceptance_timeout_prefix' _ "$SNAP" 2>&1 || true)"
assert_eq "[C2] acceptance-block.sh loaded from the snapshot defines the helper, with no error" \
    "_acceptance_timeout_prefix" "$_snap_out"

_c3="$("$BASH" -c '
    source "$1/scripts/lib/timeout-cmd.sh"
    source "$1/plugins/agent/build/lib/summary.sh" >/dev/null 2>&1
    declare -F _acceptance_file_timeout || echo missing' _ "$REPO_ROOT" 2>&1 || true)"
assert_eq "[C3] summary.sh loads acceptance-block.sh even when the helper is already defined" \
    "_acceptance_file_timeout" "$_c3"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
