#!/usr/bin/env bash
# scripts/lib/stage-notes-version.sh — whether a stage's own notes and output
# were written for the version of what it is asked that it is given now
# (#2575, ADR-068 §8). Sourced by stage-previous-work.sh.
#
# What a stage is asked is the `ask` outputs of the other stages it takes (the
# design, the requirements) — not their results or summaries, which describe a
# try and change on every one. Compared by content, read by the shell: no
# program, and a restored file's time says nothing.
#
# The record sits beside the notes (<notes>.asked, so it is saved and restored
# with them) and holds three parts, split by a record separator: what the notes
# were written for ("=" the same as the next part, "?" not known), what the
# stage was given at its last dispatch, and the notes as they were then. Notes
# that differ from that copy were written by that dispatch, for what it was
# given.
#
# Sourced library: inherits the caller's shell options; do NOT add set -euo.

[[ -n "${_ZBUILD_STAGE_NOTES_VERSION_LOADED:-}" ]] && return 0
_ZBUILD_STAGE_NOTES_VERSION_LOADED=1

# _sp_asked_sig_v <var> <stage> <state_dir> <plugins_root> <takes> <ins_array> — what <stage>
# is asked now: "<id><US><content><GS>" for each `ask` output of another stage
# in the producer index (<ins_array>: "<id><TAB><path>" entries, a map's paths
# joined by a unit separator), in the index's order. "" when it takes none.
_sp_asked_sig_v() {
    local -n _sas="$1" _sas_ins="$6"
    local stage="$2" state_dir="$3" proot="$4" takes="$5" e id v k m roles r t tid tp c p
    local -A _sas_roles=() _sas_not=()
    _sas=""
    [[ -z "$takes" || "$takes" == *" ask "* ]] || return 0
    for e in ${_sas_ins[@]+"${_sas_ins[@]}"}; do
        id="${e%%$'\t'*}"; v="${e#*$'\t'}"
        k="${_IR_PRODUCER[$id]:-}"
        [[ -n "$k" && "$k" != "$stage" ]] || continue
        if [[ -z "${_sas_roles[$k]+x}" ]]; then
            roles=""; m=""
            _inputs_stage_manifest_v m "$k" "$proot" 2>/dev/null || true
            [[ -n "$m" ]] && _sp_manifest_roles_v roles "$m" "$state_dir"
            _sas_roles[$k]="$roles"
            while IFS=$'\t' read -r r tp; do
                [[ "$r" == [PS] ]] && _sas_not["$k:$tp"]=1
            done <<< "$roles"
        fi
        t=""
        while IFS=$'\t' read -r r tid tp p; do
            [[ "$r" == T && "$tp" == "$id" ]] || continue
            t="$tid"; [[ -n "${_sas_not["$k:$p"]+x}" ]] && t=""
            break
        done <<< "${_sas_roles[$k]}"
        [[ "$t" == ask ]] || continue
        _sas+="$id"$'\x1f'
        while IFS= read -r p; do
            [[ -n "$p" && -r "$p" ]] || continue
            c=""; IFS= read -r -d '' c < "$p" || true
            _sas+="$c"
        done <<< "${v//$'\x1f'/$'\n'}"
        _sas+=$'\x1d'
    done
    return 0
}

# _sp_sig_changed_v <var> <old> <new> — the ids whose content differs between
# two signatures, in <new>'s order then those gone, "a, b and c" (empty when
# none). <old> "?" names every id of <new>.
_sp_sig_changed_v() {
    local -n _ssc="$1"; local old="$2" new="$3" e id
    local -A _ssc_o=() _ssc_seen=()
    local -a w=()
    _ssc=""
    if [[ "$old" != "?" ]]; then
        while IFS= read -r -d $'\x1d' e; do _ssc_o["${e%%$'\x1f'*}"]="${e#*$'\x1f'}"; done <<< "$old"
    fi
    while IFS= read -r -d $'\x1d' e; do
        id="${e%%$'\x1f'*}"; _ssc_seen[$id]=1
        [[ "$old" != "?" && -n "${_ssc_o[$id]+x}" && "${_ssc_o[$id]}" == "${e#*$'\x1f'}" ]] && continue
        w+=("$id")
    done <<< "$new"
    for id in "${!_ssc_o[@]}"; do [[ -n "${_ssc_seen[$id]+x}" ]] || w+=("$id"); done
    # "a, b and c", in this shell.
    local i n=${#w[@]}
    for (( i = 0; i < n; i++ )); do
        (( i == 0 )) || { (( i == n - 1 )) && _ssc+=" and " || _ssc+=", "; }
        _ssc+="${w[i]}"
    done
    return 0
}

# _sp_notes_version <notes_path> <sig> — reads and updates the record beside the
# notes; sets _SP_NOTES_OLD (what changed since the notes were written: names,
# or empty) and _SP_OUTPUT_OLD (what changed since the stage's last dispatch).
# A stage asked nothing gets neither.
_sp_notes_version() {
    local np="$1" sig="$2" rec="" w l n notes="" f
    _SP_NOTES_OLD=""; _SP_OUTPUT_OLD=""
    [[ -n "$np" ]] || return 0
    f="${np%.md}.asked"
    [[ -s "$np" ]] && { IFS= read -r -d '' notes < "$np" || true; }
    if [[ -s "$f" ]]; then
        IFS= read -r -d '' rec < "$f" || true
        w="${rec%%$'\x1e'*}"; rec="${rec#*$'\x1e'}"
        l="${rec%%$'\x1e'*}"; n="${rec#*$'\x1e'}"
        [[ "$w" == "=" ]] && w="$l"
        # Notes that changed since the last dispatch were written by it.
        [[ "$notes" != "$n" ]] && w="$l"
    else
        w="?"; l="?"
    fi
    if [[ -n "$sig" ]]; then
        [[ -n "$notes" && "$w" != "$sig" ]] && _sp_sig_changed_v _SP_NOTES_OLD "$w" "$sig"
        [[ "$l" != "$sig" && "$l" != "?" ]] && _sp_sig_changed_v _SP_OUTPUT_OLD "$l" "$sig"
    fi
    [[ -n "$notes" ]] || w="$sig"
    [[ "$w" == "$sig" ]] && w="="
    [[ -d "${f%/*}" ]] || mkdir -p "${f%/*}" 2>/dev/null || return 0
    printf '%s\x1e%s\x1e%s' "$w" "$sig" "$notes" > "$f" 2>/dev/null || true
    return 0
}
