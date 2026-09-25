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

# ─── _attempt_output_paths <manifest> ─────────────────────────────────────────
# Every declared output path (raw, unresolved), one per line.
_attempt_output_paths() {
    local manifest="$1"
    awk '
        /^outputs:[[:space:]]*$/ { in_block = 1; next }
        in_block && /^[a-zA-Z_]/  { in_block = 0 }
        in_block && /^[[:space:]]+path:[[:space:]]*/ {
            line = $0
            sub(/^[[:space:]]+path:[[:space:]]*/, "", line)
            sub(/[[:space:]]*#.*/, "", line)
            gsub(/^["'"'"']|["'"'"']$/, "", line)
            if (line != "") print line
        }
    ' "$manifest" 2>/dev/null || true
}

# ─── attempt_outputs_fingerprint <plugin_dir> <state_file> ──────────────────
# #2186: "<basename><TAB><cksum|absent>" per declared output. Taken before the
# run hook and compared after it, so the attempt record says which outputs THIS
# dispatch changed. Content-blind: the engine compares bytes, never meaning.
attempt_outputs_fingerprint() {
    local plugin_dir="${1:-}" state_file="${2:-}"
    local manifest="$plugin_dir/manifest.yaml"
    [[ -s "$manifest" ]] || return 0
    declare -F _registry_resolve_output_path >/dev/null 2>&1 || return 0
    local state_dir artifact_dir
    if [[ -n "$state_file" ]]; then state_dir="$(dirname "$state_file")"
    else state_dir="${ZBUILD_STATE_DIR:-}"; fi
    [[ -n "$state_dir" ]] || return 0
    artifact_dir="${ZBUILD_ARTIFACT_DIR:-$state_dir/artifacts}"
    local raw resolved sum
    while IFS= read -r raw; do
        [[ -n "$raw" ]] || continue
        resolved="$(_registry_resolve_output_path "$raw" "$state_dir" "$artifact_dir" 2>/dev/null || true)"
        [[ -n "$resolved" ]] || continue
        sum="$(cksum < "$resolved" 2>/dev/null || printf 'absent')"
        printf '%s\t%s\n' "${resolved##*/}" "$sum"
    done <<< "$(_attempt_output_paths "$manifest")"
}

# ─── attempt_archive_outputs <plugin_dir> <state_file> <stage> [rc] [before] ─
# [before] is attempt_outputs_fingerprint taken before the run hook (#2186).
attempt_archive_outputs() {
    local plugin_dir="${1:-}" state_file="${2:-}" stage="${3:-}" rc="${4:-}" before="${5:-}"
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
    local _paths; _paths="$(_attempt_output_paths "$manifest")"
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
    # jq, not printf (review #2184): every other JSON write in the tree escapes
    # its values, and a stage id is interpolated here.
    # #2186: which declared outputs THIS dispatch changed. Without a before
    # fingerprint there is nothing to compare, and the record says nothing.
    local _outputs="{}" _unchanged="" _name _was _now _state
    if [[ -n "$before" ]]; then
        while IFS=$'\t' read -r _name _now; do
            [[ -n "$_name" ]] || continue
            _was="$(awk -F'\t' -v n="$_name" '$1 == n { print $2; exit }' <<< "$before")"
            if [[ "$_now" == "absent" ]]; then _state="absent"
            elif [[ "$_now" == "$_was" ]]; then _state="unchanged"; _unchanged+="${_unchanged:+,}$_name"
            else _state="changed"; fi
            _outputs="$(jq -c --arg k "$_name" --arg v "$_state" '. + {($k): $v}' <<< "$_outputs" 2>/dev/null || printf '%s' "$_outputs")"
        done <<< "$(attempt_outputs_fingerprint "$plugin_dir" "$state_file")"
    fi
    jq -n --arg s "$stage" --argjson i "$_iter" --argjson a "$(( _n + 1 ))" \
          --arg rc "${rc:-}" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson f "$copied" \
          --argjson o "$_outputs" \
          '{stage:$s, cycle_iter:$i, attempt:$a, rc:$rc, generated_at:$at, files:$f}
           + (if $o == {} then {} else {outputs:$o} end)' \
        > "$_dest/attempt.json" 2>/dev/null || true
    if [[ -n "$_unchanged" ]] && declare -F emit_event >/dev/null 2>&1; then
        emit_event "stage.outputs.unchanged" "stage=$stage" "iter=$_iter" \
            "attempt=$(( _n + 1 ))" "outputs=$_unchanged" >/dev/null 2>&1 || true
    fi
    return 0
}
