#!/usr/bin/env bash
# scripts/lib/stage-dispatch-mark.sh — when a stage's latest run started, and
# whether a result was written by it (ADR-068 §8).
#
# The engine never deletes a stage's output. So a stage that runs again and
# writes nothing leaves its previous result in place, and every reader must not
# take that result as this run's. One writer and one check, so no reader can
# decide it differently: _verdict_read_result, the stage report and build_kind
# all ask stage_result_is_current.

[[ -n "${_ZBUILD_STAGE_DISPATCH_MARK_LOADED:-}" ]] && return 0
_ZBUILD_STAGE_DISPATCH_MARK_LOADED=1

# stage_dispatch_mark_path <state_dir> <stage>
stage_dispatch_mark_path() {
    printf '%s/runtime/dispatched/%s' "$1" "${2//[^A-Za-z0-9._-]/_}"
}

# stage_dispatch_mark <state_file> <stage> — record that <stage> starts a run
# now. Fail-open: a stage is never refused over bookkeeping.
stage_dispatch_mark() {
    local state_file="${1:-}" stage="${2:-}" m
    [[ "$state_file" == /* && -n "$stage" ]] || return 0
    m="$(stage_dispatch_mark_path "$(dirname "$state_file")" "$stage")"
    mkdir -p "${m%/*}" 2>/dev/null && : > "$m" 2>/dev/null || true
    return 0
}

# stage_result_is_current <state_dir> <stage> <result_file> — rc 1 when the
# result is older than <stage>'s latest run, i.e. that run wrote none. No mark
# means the stage has not run in this state dir: its result is its latest
# output, whichever run wrote it (ADR-068 §8).
stage_result_is_current() {
    local m
    [[ -n "${2:-}" ]] || return 0
    m="$(stage_dispatch_mark_path "$1" "$2")"
    [[ -e "$m" && "$m" -nt "$3" ]] && return 1
    return 0
}
