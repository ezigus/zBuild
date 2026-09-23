#!/usr/bin/env bash
# core/plugin-registry/attempt-archive.sh — #2183: every dispatch keeps its own
# record.
#
# A stage writes its declared outputs to FIXED paths, so the next dispatch of the
# same stage overwrites them. #1841 run 35802918016: build attempt 1 ended on
# three router timeouts, committed 66259d79 (1 file, +21 lines), was redispatched
# on `disposition: interrupted`, and attempt 2's `changed 0 file(s)` replaced the
# record of what attempt 1 had done. One level up, cycle iteration 2's PASSING
# test-output.log replaced iteration 1's FAILING one inside the same run — the
# failing suite output had to be recovered from a model transcript.
#
# After each run hook the engine copies that stage's DECLARED outputs into
# `<artifact_dir>/attempts/<stage>/iter-<n>-attempt-<m>/`. The live paths do not
# move, so no consumer changes and the newest attempt is still what they read.
# Manifest-driven: the engine copies what the plugin declared, and a plugin that
# declares nothing archives nothing.
#
# Fail-open throughout: bookkeeping never changes a stage's fate.
# Sourced library: inherits the caller's pipefail settings.

[[ -n "${_ZBUILD_ATTEMPT_ARCHIVE_LOADED:-}" ]] && return 0
_ZBUILD_ATTEMPT_ARCHIVE_LOADED=1

# shellcheck source=output-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/output-paths.sh" 2>/dev/null || true

# ─── attempt_archive_outputs <plugin_dir> <state_file> <stage> [rc] ─────────
attempt_archive_outputs() {
    local plugin_dir="${1:-}" state_file="${2:-}" stage="${3:-}" rc="${4:-}"
    [[ -n "$plugin_dir" && -n "$stage" ]] || return 0
    declare -F _registry_resolve_output_path >/dev/null 2>&1 || return 0

    local manifest="$plugin_dir/manifest.yaml"
    [[ -s "$manifest" ]] || return 0

    local state_dir artifact_dir
    if [[ -n "$state_file" ]]; then state_dir="$(dirname "$state_file")"
    else state_dir="${ZBUILD_STATE_DIR:-}"; fi
    [[ -n "$state_dir" ]] || return 0
    artifact_dir="${ZBUILD_ARTIFACT_DIR:-$state_dir/artifacts}"
    [[ -d "$artifact_dir" ]] || return 0

    # One path component each, so no stage id or iteration can climb out.
    local _safe_stage="${stage//[^A-Za-z0-9_-]/_}"
    local _iter="${ZBUILD_CYCLE_ITER:-0}"
    [[ "$_iter" =~ ^[0-9]+$ ]] || _iter=0

    # The attempt number is the count of attempt dirs already recorded for this
    # (stage, iteration) — derived from disk, so a redispatch in any arm of the
    # engine numbers itself without the engine having to carry a counter.
    local _base="$artifact_dir/attempts/$_safe_stage"
    local _n=0
    if [[ -d "$_base" ]]; then
        _n="$(find "$_base" -maxdepth 1 -type d -name "iter-${_iter}-attempt-*" 2>/dev/null | grep -c . || true)"
        [[ "$_n" =~ ^[0-9]+$ ]] || _n=0
    fi
    local _dest="$_base/iter-${_iter}-attempt-$(( _n + 1 ))"
    mkdir -p "$_dest" 2>/dev/null || return 0

    # EVERY declared output, not only the required ones: the summary and the
    # error channel are `required: false`, and they are most of what a reader of
    # an old attempt wants. _registry_output_path_rows drops those by design (it
    # serves the fail-closed presence scan), so this reads the block itself —
    # one awk per dispatch, no shared index state to be warm or cold.
    local _paths
    _paths="$(awk '
        /^outputs:[[:space:]]*$/ { in_block = 1; next }
        in_block && /^[a-zA-Z_]/  { in_block = 0 }
        in_block && /^[[:space:]]+path:[[:space:]]*/ {
            line = $0
            sub(/^[[:space:]]+path:[[:space:]]*/, "", line)
            sub(/[[:space:]]*#.*/, "", line)
            gsub(/^["'"'"']|["'"'"']$/, "", line)
            if (line != "") print line
        }
    ' "$manifest" 2>/dev/null || true)"
    [[ -n "$_paths" ]] || { rmdir "$_dest" 2>/dev/null || true; return 0; }

    local raw resolved copied=0
    while IFS= read -r raw; do
        [[ -n "$raw" ]] || continue
        resolved="$(_registry_resolve_output_path "$raw" "$state_dir" "$artifact_dir" 2>/dev/null || true)"
        [[ -n "$resolved" && -e "$resolved" ]] || continue
        # Flattened to the basename: the archive answers "what did this attempt
        # produce", and a declared output's basename is unique within a plugin.
        cp -p "$resolved" "$_dest/${resolved##*/}" 2>/dev/null && copied=$(( copied + 1 ))
    done <<< "$_paths"

    if [[ "$copied" -eq 0 ]]; then
        rmdir "$_dest" 2>/dev/null || true
        return 0
    fi
    # What the copy is OF — the archive is useless without the attempt's own
    # identity, and a reader must not have to infer it from the directory name.
    # `generated_at`, not a private name: the parity check normalises exactly
    # this field, and a per-run timestamp under another name reads as divergence.
    printf '{"stage":"%s","cycle_iter":%s,"attempt":%s,"rc":"%s","generated_at":"%s","files":%s}\n' \
        "$stage" "$_iter" "$(( _n + 1 ))" "${rc:-}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$copied" \
        > "$_dest/attempt.json" 2>/dev/null || true
    return 0
}
