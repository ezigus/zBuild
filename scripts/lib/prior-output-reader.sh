#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  zBuild prior-output-reader — Unified artifact resolution (#1581)         ║
# ║  Read prior artifacts from intra-cycle or cross-run contexts              ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

[[ -n "${_ZBUILD_PRIOR_OUTPUT_READER_LOADED:-}" ]] && return 0
_ZBUILD_PRIOR_OUTPUT_READER_LOADED=1

# shellcheck source=../../core/plugin-registry/attempt-archive.sh
declare -F attempt_latest_copy >/dev/null 2>&1 || \
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/core/plugin-registry/attempt-archive.sh" 2>/dev/null || true

# Read prior artifact contents with unified resolution order.
#
# Resolution priority (first hit wins):
#   1. Intra-cycle: ZBUILD_CYCLE_FEEDBACK_DIR/prior_<field>.txt (iter >= 2)
#   2. This run: ZBUILD_STATE_DIR/artifacts/<artifact_name>, else this run's
#      newest archived attempt copy (#2252)
#   3. Cross-run: ZBUILD_RESTORED_ARTIFACTS_DIR/<artifact_name> — only when
#      this run has produced none of its own. Restored first was #2252: #2032's
#      builds were told an earlier run's "changed nothing" after committing.
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

    # ─── This run: live, then its newest archived attempt ─────────────────
    local state_dir="${ZBUILD_STATE_DIR:-./state}"
    local f="$state_dir/artifacts/$artifact_name"
    if declare -F attempt_is_this_run >/dev/null 2>&1; then
        attempt_is_this_run "$f" && cat "$f" 2>/dev/null && return 0
    else
        [[ -s "$f" ]] && cat "$f" 2>/dev/null && return 0
    fi
    if declare -F attempt_latest_copy >/dev/null 2>&1 \
            && f="$(attempt_latest_copy "$state_dir/artifacts" "$artifact_name")"; then
        cat "$f" 2>/dev/null && return 0
    fi

    # ─── Cross-run restored artifacts ──────────────────────────────────────
    local restored_dir="${ZBUILD_RESTORED_ARTIFACTS_DIR:-}"
    if [[ -n "$restored_dir" ]]; then
        f="$restored_dir/$artifact_name"
        [[ -s "$f" ]] && cat "$f" 2>/dev/null && return 0
    fi

    # ─── Not found: return empty (rc 0) ────────────────────────────────────
    return 0
}
