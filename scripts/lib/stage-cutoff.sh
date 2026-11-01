#!/usr/bin/env bash
# scripts/lib/stage-cutoff.sh — what a model call cut off at its time limit did,
# for the stage's next try (#2443, ADR-063).
#
# A cut-off call writes nothing of its own, but its steps were recorded as it
# made them (#2139). The engine lists them — each file read, command run and
# sentence said — beside the stage's notes, and Previous work gives the list to
# the stage's next try. A call that is not cut off removes it, so the list is
# only ever about the call just before.
#
# Source-only; no `set -e` at top level (would mutate caller options).

[[ -n "${_ZBUILD_STAGE_CUTOFF_LOADED:-}" ]] && return 0
_ZBUILD_STAGE_CUTOFF_LOADED=1

# The latest steps are the ones the next try needs, so a long call keeps its last.
_ZB_CUTOFF_MAX_STEPS="${ZBUILD_CUTOFF_MAX_STEPS:-60}"

# stage_cutoff_path_v <var> <state_dir> <stage> — next to the stage's notes.
stage_cutoff_path_v() {
    local _scp
    declare -F stage_notes_path_v >/dev/null 2>&1 || { printf -v "$1" '%s' ""; return 1; }
    stage_notes_path_v _scp "$2" "$3"
    printf -v "$1" '%s' "${_scp%.md}.cut-off.md"
}

# _stage_cutoff_current_v <var> — the list's path for the stage now running.
_stage_cutoff_current_v() {
    printf -v "$1" '%s' ""
    [[ -n "${ZBUILD_STATE_DIR:-}" && -n "${ZBUILD_CURRENT_STAGE:-}" ]] || return 1
    stage_cutoff_path_v "$1" "$ZBUILD_STATE_DIR" "$ZBUILD_CURRENT_STAGE"
}

# stage_cutoff_clear — the call was not cut off: no list.
stage_cutoff_clear() {
    local _scc; _stage_cutoff_current_v _scc || return 0
    [[ -n "$_scc" && -e "$_scc" ]] && rm -f "$_scc" 2>/dev/null
    return 0
}

# stage_cutoff_write <record> — list the steps in <record> (the call's step
# stream, one JSON object per line) for the stage's next try.
stage_cutoff_write() {
    local record="$1" dest
    [[ -s "$record" ]] || return 0
    _stage_cutoff_current_v dest || return 0
    [[ -n "$dest" ]] || return 0
    mkdir -p "${dest%/*}" 2>/dev/null || return 0
    # Kept to what Previous work shows of it, newest first, so nothing the next
    # try needs is cut silently (review on #2444).
    local max_bytes="${ZBUILD_CUTOFF_MAX_BYTES:-$(( ${_ZB_SP_NOTES_MAX_BYTES:-8192} - 256 ))}"
    jq -rs --argjson max "$_ZB_CUTOFF_MAX_STEPS" --argjson maxb "$max_bytes" '
        def cut: gsub("\\s+"; " ") | if length > 300 then .[0:300] + "…" else . end;
        [ .[] | select(type == "object" and .type == "assistant") | .message.content[]?
          | if .type == "text" then "- said: " + (.text | cut)
            elif .type == "tool_use" then
              "- " + .name + ": " + ((.input.file_path // .input.command // .input.pattern
                                      // .input.path // (.input | tostring)) | tostring | cut)
            else empty end ] as $all
        | ($all | .[-$max:] | reverse
           | reduce .[] as $l ({b: 0, k: [], full: false};
               if .full or .b + ($l | utf8bytelength) + 1 > $maxb then .full = true
               else .b += ($l | utf8bytelength) + 1 | .k += [$l] end)
           | .k | reverse) as $kept
        | if ($kept | length) == 0 then empty
          else (if ($all | length) > ($kept | length)
                then ["- (… " + ((($all | length) - ($kept | length)) | tostring) + " earlier steps not shown)"] + $kept
                else $kept end) | join("\n") end
    ' "$record" > "$dest.tmp" 2>/dev/null || { rm -f "$dest.tmp"; return 0; }
    if [[ -s "$dest.tmp" ]]; then mv -f "$dest.tmp" "$dest"; else rm -f "$dest.tmp"; fi
    return 0
}
