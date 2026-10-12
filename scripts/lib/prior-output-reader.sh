#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  zBuild prior-output-reader — a stage's latest output (#1581)             ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# A stage's latest output is the live file, whichever try or run wrote it: a
# rerun of an issue continues it, and hydrate puts an earlier run's outputs back
# in their live places (ADR-050, amended; ADR-068 §8). There is one place to
# read, and no "earlier run" label — the engine keeps no second copy.

[[ -n "${_ZBUILD_PRIOR_OUTPUT_READER_LOADED:-}" ]] && return 0
_ZBUILD_PRIOR_OUTPUT_READER_LOADED=1

# _prior_output_path <artifact_name> — the live file, or nothing (rc 0).
_prior_output_path() {
    local artifact_name="${1:-}"
    [[ -z "$artifact_name" ]] && return 0
    local f="${ZBUILD_STATE_DIR:-./state}/artifacts/$artifact_name"
    [[ -s "$f" ]] && printf '%s' "$f"
    return 0
}

# _read_prior_output <artifact_name> — its contents, or nothing (rc 0).
_read_prior_output() {
    local f; f="$(_prior_output_path "${1:-}")"
    [[ -n "$f" ]] || return 0
    cat "$f" 2>/dev/null
    return 0
}
