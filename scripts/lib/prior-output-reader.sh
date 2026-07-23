#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  zBuild prior-output-reader — Unified artifact resolution (#1581)         ║
# ║  Read prior artifacts from intra-cycle or cross-run contexts              ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

[[ -n "${_ZBUILD_PRIOR_OUTPUT_READER_LOADED:-}" ]] && return 0
_ZBUILD_PRIOR_OUTPUT_READER_LOADED=1

# Read prior artifact contents with unified resolution order.
#
# Resolution priority (first hit wins):
#   1. Intra-cycle: ZBUILD_CYCLE_FEEDBACK_DIR/prior_<field>.txt (iter >= 2)
#   2. Cross-run: ZBUILD_RESTORED_ARTIFACTS_DIR/<artifact_name>
#   3. Local state: ZBUILD_STATE_DIR/artifacts/<artifact_name>
#   4. Not found: returns empty (rc 0)
#
# Args:
#   $1 = artifact_name (e.g., "design.md", "plan.json", "build-summary.json")
#
# Output:
#   Prints artifact contents to stdout (or nothing if not found)
#
# Returns:
#   Always 0 (silent fail on missing files)
#
_read_prior_output() {
    local artifact_name="${1:-}"
    [[ -z "$artifact_name" ]] && return 0

    local iter="${ZBUILD_CYCLE_ITER:-}"
    local fb_dir="${ZBUILD_CYCLE_FEEDBACK_DIR:-}"

    # ─── Intra-cycle feedback (iter >= 2) ──────────────────────────────────
    if [[ -n "$iter" && -n "$fb_dir" ]]; then
        if [[ "$iter" =~ ^[0-9]+$ ]] && (( iter >= 2 )); then
            # Strip extension: design.md → design, plan.json → plan
            local field="${artifact_name%.*}"
            local f="$fb_dir/prior_${field}.txt"
            [[ -s "$f" ]] && cat "$f" 2>/dev/null && return 0
        fi
    fi

    # ─── Cross-run restored artifacts ──────────────────────────────────────
    local restored_dir="${ZBUILD_RESTORED_ARTIFACTS_DIR:-}"
    if [[ -n "$restored_dir" ]]; then
        local f="$restored_dir/$artifact_name"
        [[ -s "$f" ]] && cat "$f" 2>/dev/null && return 0
    fi

    # ─── Local state fallback ──────────────────────────────────────────────
    local state_dir="${ZBUILD_STATE_DIR:-./state}"
    local f="$state_dir/artifacts/$artifact_name"
    [[ -s "$f" ]] && cat "$f" 2>/dev/null && return 0

    # ─── Not found: return empty (rc 0) ────────────────────────────────────
    return 0
}
