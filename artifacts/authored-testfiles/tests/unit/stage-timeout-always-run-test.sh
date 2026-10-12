#!/usr/bin/env bash
# [#1801/SPEC-6] _runner_dispatch_always_run reads stage_timeout_s (not
# router.timeout_s) for its time limit; simple.yaml carries stage_timeout_s
# for all stages at required values; router.timeout_s remains absent from the
# two always_run stages.
#
# [#1801/SPEC-10] _runner_dispatch_always_run kills through zbuild_pg_kill;
# no hand-rolled TERM/KILL sequence remains for stage dispatch.
#
# These tests FAIL on pre-change code (where _runner_dispatch_always_run reads
# _TPL_STAGE_ROUTER_TIMEOUT_* and uses a hand-rolled kill sequence) and PASS
# after the change.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "[#1801/SPEC-6] always_run uses stage_timeout_s; [#1801/SPEC-10] zbuild_pg_kill"
setup_test_env "stage-timeout-always-run"

# ─── [#1801/SPEC-6] runner.sh reads _TPL_STAGE_TIMEOUT_S_*, not _ROUTER_TIMEOUT ─
print_test_section "[#1801/SPEC-6] _runner_dispatch_always_run reads _TPL_STAGE_TIMEOUT_S_*"

_runner="$REPO_ROOT/core/pipeline/runner.sh"

# Extract the _runner_dispatch_always_run function body.
_ar_body=""
_ar_body="$(awk '/_runner_dispatch_always_run\(\) \{/{p=1} p{print} p && /^    \}$/{exit}' "$_runner" 2>/dev/null || true)"

if [[ -z "$_ar_body" ]]; then
    assert_fail "[#1801/SPEC-6] _runner_dispatch_always_run is defined in runner.sh" \
        "function body not found"
else
    assert_pass "[#1801/SPEC-6] _runner_dispatch_always_run is defined in runner.sh"

    # After the change: reads _TPL_STAGE_TIMEOUT_S_*, not _TPL_STAGE_ROUTER_TIMEOUT_*
    if grep -q '_TPL_STAGE_TIMEOUT_S_' <<< "$_ar_body"; then
        assert_pass "[#1801/SPEC-6] _runner_dispatch_always_run reads _TPL_STAGE_TIMEOUT_S_*"
    else
        assert_fail "[#1801/SPEC-6] _runner_dispatch_always_run reads _TPL_STAGE_TIMEOUT_S_*" \
            "_TPL_STAGE_TIMEOUT_S_* not found — still using old _TPL_STAGE_ROUTER_TIMEOUT_* or ZBUILD_RELEASE_TIMEOUT"
    fi

    # The OLD variable must not be the primary source.
    # It may still exist as a fallback to ZBUILD_STAGE_TIMEOUT_S, but
    # _TPL_STAGE_ROUTER_TIMEOUT_* must NOT be the limit variable the function uses.
    if grep -q '_ar_to.*_TPL_STAGE_ROUTER_TIMEOUT\|_TPL_STAGE_ROUTER_TIMEOUT.*_ar_to' <<< "$_ar_body"; then
        assert_fail "[#1801/SPEC-6] _runner_dispatch_always_run no longer uses _TPL_STAGE_ROUTER_TIMEOUT_* as its time limit" \
            "still reads _TPL_STAGE_ROUTER_TIMEOUT_* for _ar_to — must use _TPL_STAGE_TIMEOUT_S_* instead"
    else
        assert_pass "[#1801/SPEC-6] _runner_dispatch_always_run no longer uses _TPL_STAGE_ROUTER_TIMEOUT_* as its time limit"
    fi
fi

# ─── [#1801/SPEC-6] simple.yaml carries stage_timeout_s for all stages ────────
print_test_section "[#1801/SPEC-6] simple.yaml stage_timeout_s values"

_simple="$REPO_ROOT/config/templates/simple.yaml"
if [[ ! -f "$_simple" ]]; then
    assert_fail "[#1801/SPEC-6] config/templates/simple.yaml exists" "not found"
else
    # Verify required stage_timeout_s values by parsing the template.
    # Each check verifies that the section contains `stage_timeout_s: N`.
    # Strategy: for each stage, confirm that stage_timeout_s appears in simple.yaml
    # with the required value by extracting the section and checking.
    _check_stage_timeout() {
        local _stage="$1" _expected_s="$2"
        # Find the stage section and look for stage_timeout_s: N within it.
        # Use awk to extract from the stage heading to the next top-level entry.
        local _found
        _found="$(awk -v stage="$_stage:" '
            $0 == stage { in_stage=1; next }
            in_stage && /^[a-zA-Z_]/ { exit }
            in_stage && /stage_timeout_s:/ { print; exit }
        ' "$_simple" 2>/dev/null | grep -oE '[0-9]+')"

        if [[ "$_found" == "$_expected_s" ]]; then
            assert_pass "[#1801/SPEC-6] simple.yaml $_stage: stage_timeout_s == ${_expected_s}s"
        else
            assert_fail "[#1801/SPEC-6] simple.yaml $_stage: stage_timeout_s == ${_expected_s}s" \
                "got '${_found:-<absent>}'"
        fi
    }

    _check_stage_timeout "release" "30"
    _check_stage_timeout "persist" "120"
    _check_stage_timeout "test" "5400"
    _check_stage_timeout "build" "4200"
    _check_stage_timeout "design" "3900"
    _check_stage_timeout "plan" "1200"
    _check_stage_timeout "test-author" "900"
    _check_stage_timeout "spec-coverage" "600"
    _check_stage_timeout "acceptance-gate" "600"
    _check_stage_timeout "issue-acceptance" "600"
    _check_stage_timeout "spec-correspondence" "600"
    _check_stage_timeout "review_lenses" "600"
    _check_stage_timeout "intake" "600"
    _check_stage_timeout "pr" "600"
    _check_stage_timeout "hydrate" "600"
    _check_stage_timeout "secret-scan" "600"
    _check_stage_timeout "shape-floor" "600"
    _check_stage_timeout "design-gate" "600"
    _check_stage_timeout "gate-aggregator" "600"
    _check_stage_timeout "assertion-integrity" "600"
    _check_stage_timeout "review-aggregator" "600"

    # ─── [#1801/SPEC-6] release and persist have no router.timeout_s ──────────
    # The two always_run stages convert their router.timeout_s to stage_timeout_s.
    # After the change they must not declare router.timeout_s.
    for _ar_stage in release persist; do
        _router_to=""
        _router_to="$(awk -v stage="$_ar_stage:" '
            $0 == stage { in_stage=1; next }
            in_stage && /^[a-zA-Z_]/ { exit }
            in_stage && /router:/ { in_router=1; next }
            in_stage && in_router && /timeout_s:/ { print; exit }
            in_stage && in_router && /^[[:space:]]+[a-z_]+:/ && !/timeout_s/ { in_router=0 }
        ' "$_simple" 2>/dev/null || true)"

        if [[ -n "$_router_to" ]]; then
            assert_fail "[#1801/SPEC-6] simple.yaml $_ar_stage: no router.timeout_s (converted to stage_timeout_s)" \
                "router.timeout_s still present: $_router_to"
        else
            assert_pass "[#1801/SPEC-6] simple.yaml $_ar_stage: no router.timeout_s (converted to stage_timeout_s)"
        fi
    done
fi

# ─── [#1801/SPEC-10] _runner_dispatch_always_run uses zbuild_pg_kill ──────────
print_test_section "[#1801/SPEC-10] _runner_dispatch_always_run uses zbuild_pg_kill"

if [[ -n "$_ar_body" ]]; then
    if grep -q 'zbuild_pg_kill' <<< "$_ar_body"; then
        assert_pass "[#1801/SPEC-10] _runner_dispatch_always_run calls zbuild_pg_kill"
    else
        assert_fail "[#1801/SPEC-10] _runner_dispatch_always_run calls zbuild_pg_kill" \
            "zbuild_pg_kill not found in function body"
    fi

    # The hand-rolled `kill -TERM -- -` pattern must be gone from this function.
    # (The pattern is `kill -TERM -- -"$_ar_pid"` in the old code.)
    if grep -qE 'kill -TERM -- -"\$_ar_pid"' <<< "$_ar_body"; then
        assert_fail "[#1801/SPEC-10] _runner_dispatch_always_run has no hand-rolled TERM/KILL sequence" \
            "found 'kill -TERM -- -\"\$_ar_pid\"' — replace with zbuild_pg_kill"
    else
        assert_pass "[#1801/SPEC-10] _runner_dispatch_always_run has no hand-rolled TERM/KILL sequence"
    fi
fi

# ─── [#1801/SPEC-10] lifecycle.sh uses zbuild_pg_kill for stage dispatch ──────
print_test_section "[#1801/SPEC-10] lifecycle.sh uses zbuild_pg_kill (not hand-rolled TERM/KILL) for dispatch"

_lc="$REPO_ROOT/core/plugin-registry/lifecycle.sh"
if [[ ! -f "$_lc" ]]; then
    assert_fail "[#1801/SPEC-10] core/plugin-registry/lifecycle.sh exists" "not found"
else
    if grep -q 'zbuild_pg_kill' "$_lc"; then
        assert_pass "[#1801/SPEC-10] lifecycle.sh calls zbuild_pg_kill for stage dispatch"
    else
        assert_fail "[#1801/SPEC-10] lifecycle.sh calls zbuild_pg_kill for stage dispatch" \
            "zbuild_pg_kill not found — the per-dispatch watchdog must use it"
    fi
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
