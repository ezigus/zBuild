#!/usr/bin/env bash
# scripts/lib/item-ids.sh — the rules every id read from an issue or written by
# design keeps (#2462, ADR-070 §1, ADR-069 §1).
#
# An id is its stage's two-letter prefix (#2482, ADR-001: every stage declares
# its own), then a code of 3 or 4 capital letters or digits that describes its
# item, starting with a letter, a dash, and a number: RQFSTG-1 is a requirement
# about --from-stage, DSFSTG-1 a SPEC about it. Ids were positions (R-1, R-2,
# …): when a list grew, shrank or reordered, every id after the change named a
# different item, and the stages that held the old ids judged the wrong things
# (#1805 run 41582195372). Now an id never moves, a removed one never comes
# back, and a new one takes the number after its code's highest. Two stages'
# ids are never the same: on #1805 run 42293991602 a SPEC took a requirement's
# code, and the rule that kept them apart told design "use GUAR-1" and "GUAR is
# the requirements'" at once. The engine checks the rules; no model judges
# them. Nothing here names a code or a prefix.
#
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_ITEM_IDS_LOADED:-}" ]] && return 0
_ZBUILD_ITEM_IDS_LOADED=1

# Any id's form, with or without a prefix: what is read as an id. SPEC is the
# code of the old design ids (SPEC-1, …): still read everywhere, never written.
_ZB_ID_ANY_RE='^[A-Z][A-Z0-9]{2,5}-[0-9]+$'

# zb_id_new_form <id> <prefix> — rc 0 when <id> has the form a new id of the
# stage with <prefix> must have; BASH_REMATCH[1] is its code (the prefix in it),
# [2] its number.
zb_id_new_form() {
    [[ -n "${2:-}" && "${1:-}" =~ ^(${2}[A-Z][A-Z0-9]{2,3})-([1-9][0-9]*)$ ]]
}

# zb_ids_check_v <out> <prev_active> <prev_removed> <new_active> <new_removed>
#                <text> <prefix> [carry] [tried]
# Every rule an id list breaks, one entry each in array <out> ("<CODE> <id>
# [<detail>]"); empty when it keeps them all. The lists are space separated:
#   prev_active/prev_removed  the ids the last list had, and had removed
#   new_active/new_removed    the ids this list has, and says it removes
#   text                      the issue's own words: an id written there is a
#                             label of the issue's, never ours (#2035)
#   prefix                    the stage's id_prefix: every id it writes starts
#                             with it (#2482)
#   carry                     1 when the list itself must keep listing what was
#                             removed before (a design does; intake's engine
#                             keeps them for it)
#   tried                     ids a try of this run wrote that did not pass: a
#                             removal may name one (#2482)
# An earlier id not of the new form (R-1, SPEC-1, LOOP-1 from before #2482) is
# the old numbering: it is given a new id, and needs no REMOVED line.
zb_ids_check_v() {
    local -n _zic="$1"
    local pa=" $2 " pr=" $3 " na="$4" nr=" $5 " text="$6" px="$7" carry="${8:-0}" tr=" ${9:-} "
    local id code num seen=" " hi
    local -A _hi=() _k=()
    _zic=()
    for id in $2 $3; do
        zb_id_new_form "$id" "$px" || continue
        code="${BASH_REMATCH[1]}"; num="${BASH_REMATCH[2]}"
        (( num > ${_hi[$code]:-0} )) && _hi[$code]="$num"
    done
    # How many new ids each code takes: k new ones are exactly the k numbers
    # after its highest, in any order (distinct, so no gap is left).
    for id in $na; do
        [[ "$pa$pr" == *" $id "* ]] && continue
        zb_id_new_form "$id" "$px" && _k[${BASH_REMATCH[1]}]=$(( ${_k[${BASH_REMATCH[1]}]:-0} + 1 ))
    done
    for id in $na; do
        if [[ "$id" =~ ^SPEC-[0-9]+$ ]]; then _zic+=("ID_OLD_FORM $id $px"); continue; fi
        if ! zb_id_new_form "$id" "$px"; then
            # One that has the prefix is a bad id, not one without it (review on #2483).
            if [[ "$id" =~ $_ZB_ID_ANY_RE && "$id" != "$px"* ]]; then _zic+=("ID_NO_PREFIX $id $px"); else _zic+=("ID_BAD $id $px"); fi
            continue
        fi
        code="${BASH_REMATCH[1]}"; num="${BASH_REMATCH[2]}"
        [[ "$seen" == *" $id "* ]] && { _zic+=("ID_DUPLICATE $id"); continue; }
        seen+="$id "
        if [[ "$pr" == *" $id "* ]]; then _zic+=("ID_REUSED $id"); continue; fi
        if [[ "$pa" != *" $id "* ]]; then
            hi="${_hi[$code]:-0}"
            (( num > hi && num <= hi + ${_k[$code]:-1} )) || _zic+=("ID_NOT_AFTER_LAST $id $code-$((hi + 1))")
        fi
        [[ "$text" =~ (^|[^A-Za-z0-9])$id([^0-9]|$) ]] && _zic+=("ID_IN_ISSUE $id")
    done
    for id in $2; do
        zb_id_new_form "$id" "$px" || continue
        [[ "$seen" == *" $id "* || "$nr" == *" $id "* ]] || _zic+=("ID_DROPPED $id")
    done
    # A removal names an id that was there: an invented one would hold its
    # number forever (review #2463). One a failed try wrote was there (#2482).
    for id in $5; do
        [[ "$pa" == *" $id "* || "$pr" == *" $id "* || "$tr" == *" $id "* ]] || _zic+=("ID_REMOVED_UNKNOWN $id")
    done
    if [[ "$carry" == 1 ]]; then
        for id in $3; do
            [[ "$nr" == *" $id "* || "$seen" == *" $id "* ]] || _zic+=("ID_REMOVED_LOST $id")
        done
    fi
    return 0
}

# zb_id_prefixes_check <plugins_root> — every stage (a plugin of kind agent or
# tool) declares `id_prefix:`, two capital letters, its own (#2482, ADR-001):
# the ids a stage writes start with it, so no two stages' ids are the same. Each
# stage without one, with one of another form, or sharing one, is an `error`
# line; rc 1 when there is any. Read from the manifest index: no process.
zb_id_prefixes_check() {
    local root="$1" d m kind px rc=0
    local -a dirs=()
    local -A owner=()
    discover_plugins_into dirs "$root" || return 1
    for d in ${dirs[@]+"${dirs[@]}"}; do
        m="$d/manifest.yaml"
        yaml_get_v kind "$m" kind
        [[ "$kind" == agent || "$kind" == tool ]] || continue
        yaml_get_v px "$m" id_prefix
        if [[ -z "$px" ]]; then
            error "$m declares no id_prefix: — every stage declares its own, two capital letters (ADR-001)"; rc=1
        elif [[ ! "$px" =~ ^[A-Z][A-Z]$ ]]; then
            error "$m: id_prefix '$px' is not two capital letters (ADR-001)"; rc=1
        elif [[ -n "${owner[$px]:-}" ]]; then
            error "id_prefix '$px' is declared by both ${owner[$px]} and $m — each stage has its own (ADR-001)"; rc=1
        else
            owner[$px]="$m"
        fi
    done
    return "$rc"
}

# zb_id_plain <violation> <noun> — the sentence a model reads for one broken
# rule; <noun> is what the id names (requirement, SPEC). A form rule's
# violation carries the stage's prefix, so the sentence shows a real id.
zb_id_plain() {
    local v="$1" noun="$2" rest id det
    rest="${v#* }"; id="${rest%% *}"; det="${rest#"$id"}"; det="${det# }"
    case "$v" in
        ID_OLD_FORM*)  printf '%s uses the old numbering — give the %s an id that describes it: %s, then 3 or 4 capital letters or digits starting with a letter, a dash and a number (%sLOOP-1 for one about loop state); the old ids need no REMOVED line' "$id" "$noun" "$det" "$det" ;;
        ID_NO_PREFIX*) printf '%s does not start with %s — every %s id starts with %s, then 3 or 4 capital letters or digits that describe it, a dash and a number (%sLOOP-1); an id from before it had %s is the old numbering and needs no REMOVED line' "$id" "$det" "$noun" "$det" "$det" "$det" ;;
        ID_BAD*)       printf '%s is not an id — an id is %s, then 3 or 4 capital letters or digits starting with a letter, a dash and a number, such as %sLOOP-1' "$id" "$det" "$det" ;;
        ID_DUPLICATE*) printf '%s names two %ss — give each its own id' "$id" "$noun" ;;
        ID_REUSED*)    printf '%s was removed earlier and never comes back — give the %s a new id' "$id" "$noun" ;;
        ID_NOT_AFTER_LAST*) printf '%s is new, but its number is not the next after the highest that code has had, removed ones counted — use %s' "$id" "$det" ;;
        ID_REMOVED_UNKNOWN*) printf 'REMOVED: names %s, which the last list never had — remove only an id that was there' "$id" ;;
        ID_IN_ISSUE*)  printf '%s is written in the issue itself, where it means something else — choose another id' "$id" ;;
        ID_DROPPED*)   printf '%s was in the last list and is gone — keep it, or say why it goes on its own line: REMOVED: %s — <why>' "$id" "$id" ;;
        ID_REMOVED_LOST*) printf '%s was removed earlier — keep its REMOVED: line, so no later list uses it again' "$id" ;;
        *) printf '%s' "$v" ;;
    esac
}

# zb_id_prefix_v <var> <manifest> — the stage's id_prefix (ADR-001, #2482),
# read by the shell; empty when the manifest declares none.
zb_id_prefix_v() {
    local -n _zip="$1"; local _l
    _zip=""
    [[ -f "${2:-}" ]] || return 0
    while IFS= read -r _l || [[ -n "$_l" ]]; do
        [[ "$_l" =~ ^id_prefix:[[:space:]]*([A-Z]+) ]] && { _zip="${BASH_REMATCH[1]}"; return 0; }
    done < "$2"
}
