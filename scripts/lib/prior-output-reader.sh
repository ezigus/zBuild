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

# #2326 (ADR-050 §8): the words every prompt, index and event uses for work an
# earlier run saved. One definition, so no reader words it its own way.
# shellcheck disable=SC2034  # read by the files that source this one
ZB_EARLIER_RUN_LABEL="from an earlier run — reference only, not this run's result"

# prior_output_is_earlier_run <path> — rc 0 when <path> is a copy an earlier run
# saved (it sits in the folder hydrate restored into). Pure bash: no fork.
prior_output_is_earlier_run() {
    local p="${1:-}" r="${ZBUILD_RESTORED_ARTIFACTS_DIR:-}"
    [[ -n "$p" && -n "$r" && "$p" == "${r%/}/"* ]]
}

# Path of the prior artifact, with unified resolution order.
#
# Resolution priority (first hit wins):
#   1. Intra-cycle: ZBUILD_CYCLE_FEEDBACK_DIR/prior_<field>.txt (iter >= 2)
#   2. This run: ZBUILD_STATE_DIR/artifacts/<artifact_name>, else this run's
#      newest archived attempt copy (#2252)
#   3. Cross-run: ZBUILD_RESTORED_ARTIFACTS_DIR/<artifact_name> — only when
#      this run has produced none of its own. Restored first was #2252: #2032's
#      builds were told an earlier run's "changed nothing" after committing.
#   4. Not found: prints nothing (rc 0)
#
# A caller that puts the content in a prompt asks prior_output_is_earlier_run
# about this path and labels it (#2326).
_prior_output_path() {
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
            [[ -s "$f" ]] && { printf '%s' "$f"; return 0; }
        fi
    fi

    # ─── This run: live, then its newest archived attempt ─────────────────
    local state_dir="${ZBUILD_STATE_DIR:-./state}"
    local f="$state_dir/artifacts/$artifact_name"
    if declare -F attempt_is_this_run >/dev/null 2>&1; then
        attempt_is_this_run "$f" && { printf '%s' "$f"; return 0; }
    else
        [[ -s "$f" ]] && { printf '%s' "$f"; return 0; }
    fi
    if declare -F attempt_latest_copy >/dev/null 2>&1 \
            && f="$(attempt_latest_copy "$state_dir/artifacts" "$artifact_name")"; then
        printf '%s' "$f"; return 0
    fi

    # ─── Cross-run restored artifacts ──────────────────────────────────────
    local restored_dir="${ZBUILD_RESTORED_ARTIFACTS_DIR:-}"
    if [[ -n "$restored_dir" ]]; then
        f="$restored_dir/$artifact_name"
        [[ -s "$f" ]] && { printf '%s' "$f"; return 0; }
    fi
    return 0
}

# Read prior artifact contents (the path _prior_output_path resolves).
# Always returns 0 (silent fail on missing files).
_read_prior_output() {
    local f; f="$(_prior_output_path "${1:-}")"
    [[ -n "$f" ]] || return 0
    cat "$f" 2>/dev/null
    return 0
}
