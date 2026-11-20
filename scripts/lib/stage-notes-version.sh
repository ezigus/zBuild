#!/usr/bin/env bash
# scripts/lib/stage-notes-version.sh — whether a stage's own notes and output
# were written for the version of what it is asked that it is given now
# (#2575, ADR-068 §8). Sourced by stage-previous-work.sh.
#
# What a stage is asked is what defines the ask in the `ask` outputs of the
# other stages it takes: a document counts by its ```acceptance block, and only
# the stage's own one (required: true — not a working copy); a JSON file counts
# whole, less a top-level "title". Results, summaries, prose (the issue text,
# a design's reasoning) and drafts do not count: they change when the ask does
# not. Each is a fingerprint taken by the shell (digest.sh): no program, and a
# restored file's time says nothing.
#
# The record sits beside the notes (<notes>.asked, saved and restored with
# them), one "<key><TAB><value>" line each: W what the notes were written for,
# L what the stage's output was written for ("?" not known), S what the stage
# was given at its last prompt, N the notes' fingerprint then, O its result's.
# Notes that changed since were written for S; so was a result that changed.
# The record ends with "E<TAB>end"; one without it was cut short, and is none.
#
# Sourced library: inherits the caller's shell options; do NOT add set -euo.

[[ -n "${_ZBUILD_STAGE_NOTES_VERSION_LOADED:-}" ]] && return 0
_ZBUILD_STAGE_NOTES_VERSION_LOADED=1

# shellcheck source=./digest.sh
source "${BASH_SOURCE[0]%/*}/digest.sh"

# _sp_ask_version_v <var> <path> <required> — the fingerprint of what defines
# the ask in one output, or empty when nothing in it does.
_sp_ask_version_v() {
    local -n _sav="$1"; local p="$2" l l2 in=0 blk=""
    local -a parts=()
    _sav=""
    [[ -r "$p" ]] || return 0
    case "$p" in
        *.md)
            [[ "$3" == 1 ]] || return 0
            # Read in its NUL-separated parts, each NUL kept as \x1a, so a byte
            # after a NUL still counts.
            mapfile -d '' parts < "$p"
            local IFS=$'\x1a'; l="${parts[*]}"; unset IFS
            while IFS= read -r l2 || [[ -n "$l2" ]]; do
                if [[ "$l2" == '```acceptance'* ]]; then in=1; continue; fi
                (( in )) || continue
                [[ "$l2" == '```'* ]] && break
                blk+="$l2"$'\n'
            done <<< "$l"
            [[ -n "$blk" ]] && zb_digest_v _sav "$blk" ;;
        *.json)
            mapfile -d '' parts < "$p"
            [[ ${#parts[@]} -gt 0 ]] || return 0
            [[ "${parts[0]}" =~ ^\{\"title\":\"([^\"\\]|\\.)*\",? ]] && parts[0]="{${parts[0]:${#BASH_REMATCH[0]}}"
            zb_parts_digest_v _sav parts ;;
    esac
    return 0
}

# _sp_asked_sig_v <var> <stage> <state_dir> <plugins_root> <takes> <ins_array>
# — what <stage> is asked now: "<id>=<fingerprint>" for each `ask` output of
# another stage in the producer index that defines some of it (<ins_array>:
# "<id><TAB><path>" entries, a map's paths joined by a unit separator), space
# separated, in the index's order. "" when it is asked nothing.
_sp_asked_sig_v() {
    local -n _sas="$1" _sas_ins="$6"
    local stage="$2" state_dir="$3" proot="$4" takes="$5" e id v k m roles r t tid tp p d all rq
    local -A _sas_roles=() _sas_not=() _sas_req=()
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
                [[ "$r" == R ]] && _sas_req["$k:$tp"]=1
            done <<< "$roles"
        fi
        t=""
        while IFS=$'\t' read -r r tid tp p; do
            [[ "$r" == T && "$tp" == "$id" ]] || continue
            t="$tid"; [[ -n "${_sas_not["$k:$p"]+x}" ]] && t=""
            break
        done <<< "${_sas_roles[$k]}"
        [[ "$t" == ask ]] || continue
        all=""; rq=""; [[ -n "${_sas_req["$k:$p"]+x}" ]] && rq=1
        while IFS= read -r tp; do
            [[ -n "$tp" ]] || continue
            _sp_ask_version_v d "$tp" "$rq"
            [[ -n "$d" ]] && all+="${all:+,}$d"
        done <<< "${v//$'\x1f'/$'\n'}"
        [[ -n "$all" ]] && _sas+="${_sas:+ }$id=$all"
    done
    return 0
}

# _sp_sig_changed_v <var> <old> <new> — the ids whose fingerprint differs
# between two signatures, in <new>'s order then those gone, "a, b and c" (empty
# when none). <old> "?" names every id of <new>.
_sp_sig_changed_v() {
    local -n _ssc="$1"; local old="$2" new="$3" e id
    local -A _ssc_o=() _ssc_seen=()
    local -a w=() _ssc_ol=() _ssc_nl=()
    _ssc=""
    read -ra _ssc_nl <<< "$new"
    if [[ "$old" != "?" ]]; then
        read -ra _ssc_ol <<< "$old"
        for e in ${_ssc_ol[@]+"${_ssc_ol[@]}"}; do _ssc_o["${e%%=*}"]="${e#*=}"; done
    fi
    for e in ${_ssc_nl[@]+"${_ssc_nl[@]}"}; do
        id="${e%%=*}"; _ssc_seen[$id]=1
        [[ "$old" != "?" && "${_ssc_o[$id]-}" == "${e#*=}" ]] && continue
        w+=("$id")
    done
    for id in "${!_ssc_o[@]}"; do [[ -n "${_ssc_seen[$id]+x}" ]] || w+=("$id"); done
    # "a, b and c", in this shell.
    local i n=${#w[@]}
    for (( i = 0; i < n; i++ )); do
        (( i == 0 )) || { (( i == n - 1 )) && _ssc+=" and " || _ssc+=", "; }
        _ssc+="${w[i]}"
    done
    return 0
}

# _sp_notes_version <notes_path> <sig> [result_path] — reads and updates the
# record beside the notes; sets _SP_NOTES_OLD (what changed since the notes
# were written: names, or empty) and _SP_OUTPUT_OLD (what changed since the
# stage's result was written). A stage asked nothing gets neither, and no
# record. The record is rewritten, whole, only when it changes.
_sp_notes_version() {
    local np="$1" sig="$2" res="${3:-}" f k v old="" new had=0
    local W="" L="" S="" N="" O="" nd rd
    _SP_NOTES_OLD=""; _SP_OUTPUT_OLD=""
    [[ -n "$np" && -n "$sig" ]] || return 0
    f="${np%.md}.asked"
    zb_file_digest_v nd "$np"
    rd=absent; [[ -n "$res" ]] && zb_file_digest_v rd "$res"
    if [[ -s "$f" ]]; then
        local ended=0
        while IFS=$'\t' read -r k v; do
            case "$k" in W) W="$v" ;; L) L="$v" ;; S) S="$v" ;; N) N="$v" ;; O) O="$v" ;; E) ended=1; continue ;; esac
            old+="$k"$'\t'"$v"$'\n'
        done < "$f"
        [[ "$ended" == 1 && -n "$S" && -n "$W" && -n "$L" ]] && had=1
        (( had )) || old=""
    fi
    if (( had )); then
        [[ "$nd" != "$N" ]] && W="$S"
        [[ "$rd" != "$O" ]] && L="$S"
    else
        W="?"; L="?"; O="$rd"
    fi
    [[ "$nd" == absent ]] && W="$sig"
    [[ "$rd" == absent ]] && L="$sig"
    [[ "$nd" != absent && "$W" != "$sig" ]] && _sp_sig_changed_v _SP_NOTES_OLD "$W" "$sig"
    [[ "$L" != "?" && "$L" != "$sig" ]] && _sp_sig_changed_v _SP_OUTPUT_OLD "$L" "$sig"
    # While the output is written for what the stage was last given, a newer
    # result moves nothing: its fingerprint need not be kept fresh.
    [[ "$L" == "$sig" ]] || O="$rd"
    new="W"$'\t'"$W"$'\n'"L"$'\t'"$L"$'\n'"S"$'\t'"$sig"$'\n'"N"$'\t'"$nd"$'\n'"O"$'\t'"$O"$'\n'
    [[ "$new" == "$old" ]] && return 0
    [[ -d "${f%/*}" ]] || mkdir -p "${f%/*}" 2>/dev/null || return 0
    # One write of the whole record, ending in its end line; a record without
    # it (a write cut short) is read as none. No rename: one program more on
    # every dispatch that changes it (ADR-065 §5).
    printf '%sE\tend\n' "$new" > "$f" 2>/dev/null || true
    return 0
}
