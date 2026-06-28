#!/usr/bin/env bash
# plugins/tool/shape-floor/plugin.sh — Shape Floor Stage (ADR-040, ADR-037 §1, #1134)
#
# Kind: tool  Tier: T0  (NO LLM — ADR-037 §3 invariant)
# Runs the un-gameable shape-floor check (scripts/lib/shape-floor.sh): when a
# shape-change file is in the merge-base→HEAD diff, the event-sequence goldens
# and _TPL_STAGES[N]-indexed order tests must also be in the diff. Writes
# verdict=skip|pass|fail to shape-floor-result.json. Always returns rc=0 — the
# verdict lives in the artifact (mirrors objective-gate's artifact convention).
#
# Hook prefix: shape_floor_
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_SHAPE_FLOOR_PLUGIN_LOADED:-}" ]] && return 0
_ZBUILD_SHAPE_FLOOR_PLUGIN_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
_SF_ROOT="$_ZBUILD_PLUGIN_ROOT"

# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_SF_ROOT/core/event-bus/event-bus.sh" 2>/dev/null || true
# shellcheck source=../../../scripts/lib/shape-floor.sh
source "$_SF_ROOT/scripts/lib/shape-floor.sh" 2>/dev/null || true

# Resilient emit — no-op when event-bus is unavailable (unit-test isolation).
_sf_emit() { declare -f eb_emit_event >/dev/null 2>&1 && eb_emit_event "$@" || true; }

# ─── shape_floor_init ─────────────────────────────────────────────────────────
shape_floor_init() {
    export ZBUILD_PLUGIN="shape-floor"
    export ZBUILD_PLUGIN_KIND="tool"
    _sf_emit "plugin.init.start" "plugin=shape-floor"
    _sf_emit "plugin.init.complete" "plugin=shape-floor"
    return 0
}

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

    _sf_emit "plugin.run.start" "plugin=shape-floor"

    local _shape_out=""
    if declare -f _sf_shape_floor >/dev/null 2>&1; then
        _shape_out="$(_sf_shape_floor "$repo_root")"
    fi

    local verdict detail=""
    case "$_shape_out" in
        *"SHAPE_FLOOR PASS"*)
            verdict="pass"
            _sf_emit "shape_floor.pass"
            ;;
        *"SHAPE_FLOOR FAIL"*)
            verdict="fail"
            detail="${_shape_out##*SHAPE_FLOOR FAIL }"
            _sf_emit "shape_floor.fail" "detail=$detail"
            ;;
        *)
            verdict="skip"
            detail="${_shape_out##*SHAPE_FLOOR SKIP }"
            _sf_emit "shape_floor.skip"
            ;;
    esac

    jq -n --arg v "$verdict" --arg d "$detail" \
        '{"verdict":$v,"detail":$d}' | atomic_write "$result_path"

    _sf_emit "plugin.run.complete" "plugin=shape-floor" "verdict=$verdict"
    return 0
}

# ─── shape_floor_finalize ─────────────────────────────────────────────────────
shape_floor_finalize() {
    _sf_emit "plugin.finalize.start" "plugin=shape-floor"
    _sf_emit "plugin.finalize.complete" "plugin=shape-floor"
    return 0
}

# ─── shape_floor_cleanup ──────────────────────────────────────────────────────
shape_floor_cleanup() {
    _sf_emit "plugin.cleanup.start" "plugin=shape-floor"
    _sf_emit "plugin.cleanup.complete" "plugin=shape-floor"
    return 0
}
