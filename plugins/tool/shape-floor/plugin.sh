#!/usr/bin/env bash
# plugins/tool/shape-floor/plugin.sh — Shape Floor Stage (ADR-040, ADR-037 §1, #1134)
#
# Kind: tool  Tier: T0  (NO LLM — ADR-037 §3 invariant)
# Runs the un-gameable shape-floor check (scripts/lib/shape-floor.sh): when a
# shape-change file is in the merge-base→HEAD diff, the event-sequence goldens
# and _TPL_STAGES[N]-indexed order tests must also be in the diff. Writes
# verdict=skip|pass|fail to shape-floor-result.json. Always returns rc=0 — the
# verdict lives in the artifact (ADR-040 verdict-in-artifact convention).
#
# Hook prefix: shape_floor_
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_SHAPE_FLOOR_PLUGIN_LOADED:-}" ]] && return 0
_ZBUILD_SHAPE_FLOOR_PLUGIN_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
# shellcheck source=../../../scripts/lib/stage-summary.sh
# NOT `|| true`: this helper is how the gate's findings reach a prompt at
# all. Swallowing a failed load would leave stage_summary_write undefined and
# every finding silently unpublished — the exact shape #1991 guards.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/stage-summary.sh"
_SF_ROOT="$_ZBUILD_PLUGIN_ROOT"

# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_SF_ROOT/core/event-bus/event-bus.sh" 2>/dev/null || true
# #1783: source via the contract-reader seam so a run that edits the floor's own
# lib is measured by its copy rather than the installed engine's.
# shellcheck source=../../../scripts/lib/shape-floor.sh
source "$_ZBUILD_CONTRACT_LIB_DIR/shape-floor.sh" 2>/dev/null || true

# Resilient emit — no-op when event-bus is unavailable (unit-test isolation).
_sf_emit() { declare -f eb_emit_event >/dev/null 2>&1 && eb_emit_event "$@" || true; }

# ─── shape_floor_run ──────────────────────────────────────────────────────────
# Runs _sf_shape_floor, parses the SHAPE_FLOOR verdict, emits shape_floor.{pass,
# fail,skip}, and writes the verdict to shape-floor-result.json. Always rc=0.
# Args: $1 = stage_id, $2 = state_file
shape_floor_run() {
    local stage_id="${1:-shape-floor}"; : "$stage_id"
    local state_file="${2:-}"

    local artifacts_dir
    if [[ -n "$state_file" && -d "$(dirname "$state_file")" ]]; then
        artifacts_dir="$(dirname "$state_file")/artifacts"
    else
        artifacts_dir="${ZBUILD_ARTIFACT_DIR:-${TMPDIR:-/tmp}/zbuild-shape-floor-artifacts}"
    fi
    mkdir -p "$artifacts_dir"

    local result_path="$artifacts_dir/shape-floor-result.json"
    local repo_root="${ZBUILD_REPO_ROOT:-$_SF_ROOT}"

    if ! declare -f _sf_shape_floor >/dev/null 2>&1; then
        # Library failed to load — halts instead of silently skipping (#1758).
        jq -n '{"result_contract":2,"verdict":"fail","disposition":"broken","reason":"library_load_failure"}' \
            | atomic_write "$result_path"
        stage_summary_write "$artifacts_dir/shape-floor-detail.md" "shape-floor" "fail" \
            "library load failure — shape-floor.sh did not load; floor check disabled"
        _sf_emit "plugin.result" "plugin=shape-floor" "verdict=fail"
        return 0
    fi

    local _shape_out=""
    _shape_out="$(_sf_shape_floor "$repo_root")"

    local verdict detail=""
    case "$_shape_out" in
        *"SHAPE_FLOOR PASS"*)
            verdict="pass"
            _sf_emit "shape_floor.pass"
            ;;
        *"SHAPE_FLOOR FAIL"*)
            verdict="fail"
            detail="${_shape_out##*SHAPE_FLOOR FAIL }"
            # Key matches the artifact's `reason` field — an event and the artifact
            # describing the same failure must not name it two different things.
            _sf_emit "shape_floor.fail" "reason=$detail"
            ;;
        *)
            verdict="skip"
            detail="${_shape_out##*SHAPE_FLOOR SKIP }"
            _sf_emit "shape_floor.skip"
            ;;
    esac

    # Out-of-scope escalation: if every missing floor file is absent from build's scope,
    # route back to design so scope can be expanded rather than spinning in build.
    # Empty scope (pre-plan runs) is treated as unconstrained — no escalation.
    local fault=""
    if [[ "$verdict" == "fail" ]]; then
        local _scope="${ZBUILD_SHAPE_FLOOR_SCOPE:-${ZBUILD_SCOPE_ALLOWLIST:-}}"
        if [[ -n "$_scope" ]] && declare -f _sf_collect_missing_floor_files >/dev/null 2>&1 \
            && declare -f _sf_diff_files >/dev/null 2>&1; then
            local _diff_files _total=0 _oos=0 _mf
            _diff_files="$(_sf_diff_files "$repo_root")"
            while IFS= read -r _mf; do
                [[ -z "$_mf" ]] && continue
                _total=$(( _total + 1 ))
                # #1884: the substitution completes before grep -q runs, so its early exit signals nobody.
                if ! grep -qxF "$_mf" <<< "$(printf '%s' "$_scope" | tr ',' '\n')"; then
                    _oos=$(( _oos + 1 ))
                fi
            done < <(_sf_collect_missing_floor_files "$repo_root" "$_diff_files")
            if [[ $_total -gt 0 && $_oos -eq $_total ]]; then
                # #1987: the BOUNDARY is wrong — every missing floor file is
                # outside the build's scope allowlist, so build cannot touch
                # them. This gate knows that much about its own failure; where
                # a scope fault is corrected is the template's to decide.
                fault="scope"
                _sf_emit "shape_floor.oos_escalation"
            fi
        fi
    fi

    if [[ -n "$fault" ]]; then
        jq -n --arg v "$verdict" --arg r "$detail" --arg f "$fault" \
            '{"result_contract":2,"verdict":$v,"disposition":"complete","reason":$r,"fault":$f}' \
            | atomic_write "$result_path"
    else
        jq -n --arg v "$verdict" --arg r "$detail" \
            '{"result_contract":2,"verdict":$v,"disposition":"complete","reason":$r}' \
            | atomic_write "$result_path"
    fi

    # #1988: publish what only this gate knows. Its detail used to reach a
    # prompt only through the aggregator's rendering; it is now a declared
    # summary output (#1976), and cleared on a non-fail so a stale file from a
    # previous iteration never renders as a current finding.
    # #2053: outside the fault branch. `fault` is set only for an out-of-scope
    # failure, so nesting this under it left the output — declared required —
    # missing on pass, skip and an ordinary in-scope fail, and could not clear
    # anything on a non-fail because it never ran there. ADR-055 §9: written on
    # EVERY terminal verdict, because absence is not a legitimate state.
    stage_summary_write "$artifacts_dir/shape-floor-detail.md" "shape-floor" "$verdict" "$detail"

    _sf_emit "plugin.result" "plugin=shape-floor" "verdict=$verdict"
    return 0
}

# ─── shape_floor_cleanup ──────────────────────────────────────────────────────
