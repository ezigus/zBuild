#!/usr/bin/env bash
# scripts/lib/item-ids.sh — the rules every id read from an issue or written by
# design keeps (#2462, ADR-070 §1, ADR-069 §1).
#
# An id is a code of 3 or 4 capital letters or digits that describes its item,
# starting with a letter, a dash, and a number: FSTG-1. Ids were positions
# (R-1, R-2, …): when a list grew, shrank or reordered, every id after the
# change named a different item, and the stages that held the old ids judged
# the wrong things (#1805 run 41582195372). Now an id never moves, a removed one
# never comes back, and a new one takes the number after its code's highest.
# The engine checks the rules; no model judges them. Nothing here names a code.
#
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_ITEM_IDS_LOADED:-}" ]] && return 0
_ZBUILD_ITEM_IDS_LOADED=1

# The form of a new id. SPEC is the code of the old design ids (SPEC-1, …):
# still read everywhere, never written again.
_ZB_ID_NEW_RE='^([A-Z][A-Z0-9][A-Z0-9][A-Z0-9]?)-([1-9][0-9]*)$'

# zb_id_new_form <id> — rc 0 when <id> has the form a new id must have.
zb_id_new_form() {
    [[ "${1:-}" =~ $_ZB_ID_NEW_RE && "${BASH_REMATCH[1]}" != SPEC ]]
}

# zb_ids_check_v <out> <prev_active> <prev_removed> <new_active> <new_removed>
#                <text> <other_codes> [carry]
# Every rule an id list breaks, one entry each in array <out> ("<CODE> <id>
# [<detail>]"); empty when it keeps them all. The lists are space separated:
#   prev_active/prev_removed  the ids the last list had, and had removed
#   new_active/new_removed    the ids this list has, and says it removes
#   text                      the issue's own words: an id written there is a
#                             label of the issue's, never ours (#2035)
#   other_codes               codes the other kind of item uses: a NEW
#                             requirement code is never a SPEC code, and the
#                             other way round (zb_id_codes_v makes the list)
#   carry                     1 when the list itself must keep listing what was
#                             removed before (a design does; intake's engine
#                             keeps them for it)
# An earlier id not of the new form (R-1, SPEC-1) is the old numbering: it is
# given a new id, and needs no REMOVED line.
zb_ids_check_v() {
    local -n _zic="$1"
    local pa=" $2 " pr=" $3 " na="$4" nr=" $5 " text="$6" oc=" $7 " carry="${8:-0}"
    local id code num seen=" " hi
    local -A _hi=() _k=()
    _zic=()
    for id in $2 $3; do
        [[ "$id" =~ $_ZB_ID_NEW_RE ]] || continue
        code="${BASH_REMATCH[1]}"; num="${BASH_REMATCH[2]}"
        (( num > ${_hi[$code]:-0} )) && _hi[$code]="$num"
    done
    # How many new ids each code takes: k new ones are exactly the k numbers
    # after its highest, in any order (distinct, so no gap is left).
    for id in $na; do
        [[ "$pa$pr" == *" $id "* ]] && continue
        zb_id_new_form "$id" && _k[${BASH_REMATCH[1]}]=$(( ${_k[${BASH_REMATCH[1]}]:-0} + 1 ))
    done
    for id in $na; do
        if [[ "$id" =~ ^SPEC-[0-9]+$ ]]; then _zic+=("ID_OLD_FORM $id"); continue; fi
        if ! zb_id_new_form "$id"; then _zic+=("ID_BAD $id"); continue; fi
        code="${BASH_REMATCH[1]}"; num="${BASH_REMATCH[2]}"
        [[ "$seen" == *" $id "* ]] && { _zic+=("ID_DUPLICATE $id"); continue; }
        seen+="$id "
        if [[ "$pr" == *" $id "* ]]; then _zic+=("ID_REUSED $id"); continue; fi
        if [[ "$pa" != *" $id "* ]]; then
            hi="${_hi[$code]:-0}"
            (( num > hi && num <= hi + ${_k[$code]:-1} )) || _zic+=("ID_NOT_AFTER_LAST $id $code-$((hi + 1))")
        fi
        # #2476: only a new id is held to the other pool — a kept one never
        # moves; the side that just took the code is the one that changes.
        [[ "$oc" == *" $code "* && "$pa" != *" $id "* ]] && _zic+=("ID_OTHER_POOL $id")
        [[ "$text" =~ (^|[^A-Za-z0-9])$id([^0-9]|$) ]] && _zic+=("ID_IN_ISSUE $id")
    done
    for id in $2; do
        zb_id_new_form "$id" || continue
        [[ "$seen" == *" $id "* || "$nr" == *" $id "* ]] || _zic+=("ID_DROPPED $id")
    done
    # A removal names an id that was there: an invented one would hold its
    # number forever (review #2463).
    for id in $5; do
        [[ "$pa" == *" $id "* || "$pr" == *" $id "* ]] || _zic+=("ID_REMOVED_UNKNOWN $id")
    done
    if [[ "$carry" == 1 ]]; then
        for id in $3; do
            [[ "$nr" == *" $id "* || "$seen" == *" $id "* ]] || _zic+=("ID_REMOVED_LOST $id")
        done
    fi
    return 0
}

# zb_id_codes_v <var> <id>... — the codes of the ids given, each once, space
# separated: the other_codes zb_ids_check_v takes (#2476). Read by the shell.
zb_id_codes_v() {
    local -n _zcv="$1"; shift
    local _zid
    _zcv=" "
    for _zid in "$@"; do
        [[ "$_zid" =~ $_ZB_ID_NEW_RE ]] || continue
        [[ "$_zcv" == *" ${BASH_REMATCH[1]} "* ]] || _zcv+="${BASH_REMATCH[1]} "
    done
    _zcv="${_zcv# }"; _zcv="${_zcv% }"
}

# zb_id_plain <violation> <noun> — the sentence a model reads for one broken
# rule; <noun> is what the id names (requirement, SPEC).
zb_id_plain() {
    local v="$1" noun="$2" rest id det
    rest="${v#* }"; id="${rest%% *}"; det="${rest#"$id"}"; det="${det# }"
    case "$v" in
        ID_OLD_FORM*)  printf '%s uses the old numbering — give the %s an id that describes it: 3 or 4 capital letters or digits starting with a letter, a dash and a number (LOOP-1 for one about loop state); the old SPEC-n ids need no REMOVED line' "$id" "$noun" ;;
        ID_BAD*)       printf '%s is not an id — an id is 3 or 4 capital letters or digits starting with a letter, a dash and a number, such as LOOP-1' "$id" ;;
        ID_DUPLICATE*) printf '%s names two %ss — give each its own id' "$id" "$noun" ;;
        ID_REUSED*)    printf '%s was removed earlier and never comes back — give the %s a new id' "$id" "$noun" ;;
        ID_NOT_AFTER_LAST*) printf '%s is new, but its number is not the next after the highest that code has had, removed ones counted — use %s' "$id" "$det" ;;
        ID_REMOVED_UNKNOWN*) printf 'REMOVED: names %s, which the last list never had — remove only an id that was there' "$id" ;;
        ID_OTHER_POOL*)
            if [[ "$noun" == requirement ]]; then
                printf '%s uses a code the design'"'"'s SPECs use — a requirement'"'"'s code is its own: choose another' "$id"
            else
                printf '%s uses a code the issue'"'"'s requirements use — a %s'"'"'s code is its own' "$id" "$noun"
            fi ;;
        ID_IN_ISSUE*)  printf '%s is written in the issue itself, where it means something else — choose another id' "$id" ;;
        ID_DROPPED*)   printf '%s was in the last list and is gone — keep it, or say why it goes on its own line: REMOVED: %s — <why>' "$id" "$id" ;;
        ID_REMOVED_LOST*) printf '%s was removed earlier — keep its REMOVED: line, so no later list uses it again' "$id" ;;
        *) printf '%s' "$v" ;;
    esac
}
