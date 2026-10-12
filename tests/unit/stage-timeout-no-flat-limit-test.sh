#!/usr/bin/env bash
# [#1801/SPEC-7] Guard: removing ZBUILD_ORCH_TIMEOUT from the three strategy files
# means the per-dispatch watchdog is the only stage time limit.
#
# Before this change the strategy files had `orch_collect … --timeout
# "${ZBUILD_ORCH_TIMEOUT:-300}"` as a flat ceiling; a plan dispatch running
# longer than 300 s would have been killed even when its `stage_timeout_s`
# allowed more. After the change, orch_collect is called without --timeout (or
# with no ceiling), leaving the per-dispatch watchdog in lifecycle.sh as the
# only limit.
#
# The assertions are source-level: they verify that each strategy file no
# longer carries the flat ceiling. This test FAILS on pre-change code
# (where ZBUILD_ORCH_TIMEOUT still appears) and PASSES after the change.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "[#1801/SPEC-7] ZBUILD_ORCH_TIMEOUT absent from strategy files"

# ─── Each strategy file must not reference ZBUILD_ORCH_TIMEOUT ───────────────
# These are the three files the design names: fanout.sh, sequential.sh, map.sh.
# Every occurrence of ZBUILD_ORCH_TIMEOUT pins a flat ceiling that the per-dispatch
# watchdog is meant to replace.

for _sf in \
    core/pipeline/strategies/fanout.sh \
    core/pipeline/strategies/sequential.sh \
    core/pipeline/strategies/map.sh; do

    _file="$REPO_ROOT/$_sf"
    if [[ ! -f "$_file" ]]; then
        assert_fail "[#1801/SPEC-7] $_sf exists" "file not found: $_file"
        continue
    fi

    if grep -q 'ZBUILD_ORCH_TIMEOUT' "$_file"; then
        assert_fail "[#1801/SPEC-7] $_sf carries no ZBUILD_ORCH_TIMEOUT flat ceiling" \
            "ZBUILD_ORCH_TIMEOUT still present — a plan dispatch longer than the default 300 s" \
            "would be killed before its stage_timeout_s expires"
    else
        assert_pass "[#1801/SPEC-7] $_sf carries no ZBUILD_ORCH_TIMEOUT flat ceiling"
    fi

    # Also verify orch_collect/orch_wait calls carry no --timeout flag.
    # A hard-coded --timeout N in the orch call would impose a flat ceiling
    # independent of ZBUILD_ORCH_TIMEOUT and would kill long-but-valid dispatches.
    if grep -qE 'orch_collect.*--timeout|orch_wait.*--timeout' "$_file"; then
        assert_fail "[#1801/SPEC-7] $_sf orch_collect/orch_wait carry no --timeout flag" \
            "--timeout found in orch call — imposes a flat ceiling that overrides stage_timeout_s"
    else
        assert_pass "[#1801/SPEC-7] $_sf orch_collect/orch_wait carry no --timeout flag"
    fi
done

print_test_results
exit $((FAIL > 0))
