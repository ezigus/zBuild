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

# _zb_ids_highest_v <assoc> <ids> <prefix> — each code's highest number among
# <ids> of the new form, into <assoc> (code → number). The one count both the
# id check and a stage's prompt read (#2550): the prompt states no rule of its
# own, so the two cannot disagree.
_zb_ids_highest_v() {
    local -n _zih="$1"; local id
    for id in $2; do
        zb_id_new_form "$id" "$3" || continue
        (( BASH_REMATCH[2] > ${_zih[${BASH_REMATCH[1]}]:-0} )) && _zih[${BASH_REMATCH[1]}]="${BASH_REMATCH[2]}"
    done
    return 0
}

# zb_test_tag_ids_v <out> <repo> <prefix> — the ids of stage <prefix> that
# other work tagged in the repository's test folders, as `[<id>]`: a tag is the
# id alone since #2520, so one another piece of work tagged is taken. Read from
# the commit this branch started from — a tag this branch added is its own
# (ADR-069 §11) — or, with none (the default branch itself), from the tree.
# Done once for a repository and kept for the rest of this shell (#2550).
_ZB_TAG_IDS_KEY="" _ZB_TAG_IDS=""
zb_test_tag_ids_v() {
    local -n _zti="$1"; local repo="$2" px="$3" globs="" t base=""
    if [[ "$_ZB_TAG_IDS_KEY" == "$repo|$px" ]]; then _zti="$_ZB_TAG_IDS"; return 0; fi
    _zti=""
    [[ -n "$repo" && -n "$px" ]] && declare -F zb_test_path_globs_v >/dev/null 2>&1 \
        && zb_test_path_globs_v globs "$repo"
    if [[ -n "$globs" ]]; then
        declare -F zbuild_resolve_merge_base_v >/dev/null 2>&1 \
            || source "${BASH_SOURCE[0]%/*}/merge-base.sh" 2>/dev/null || true
        declare -F zbuild_resolve_merge_base_v >/dev/null 2>&1 && zbuild_resolve_merge_base_v base "$repo"
        # read -a: the globs reach git as written, never expanded by the shell.
        local -a pats=() where=(--untracked); read -r -a pats <<< "$globs"
        [[ -n "$base" ]] && where=("$base")
        while IFS= read -r t; do
            t="${t#\[}"; t="${t%\]}"
            [[ -n "$t" && " $_zti " != *" $t "* ]] && _zti+="${_zti:+ }$t"
        done < <(git -C "$repo" grep -h -o -E "\[${px}[A-Z][A-Z0-9]{2,3}-[0-9]+\]" "${where[@]}" -- "${pats[@]}" 2>/dev/null)
    fi
    _ZB_TAG_IDS_KEY="$repo|$px" _ZB_TAG_IDS="$_zti"
    return 0
}

# zb_ids_highest_line_v <out> <prev_active> <prev_removed> <prefix> <noun> [used] —
# the line a stage's prompt gives its model for numbering new ids (#2550,
# ADR-069 §1): each code's highest number in the last list, removed ones
# counted, and in [used] (ids tagged in the tests) — what zb_ids_check_v holds a
# new id to.
zb_ids_highest_line_v() {
    local -n _zhl="$1"; local -A _h=(); local c list="" i j t
    local -a codes=()
    _zb_ids_highest_v _h "$2 $3 ${6:-}" "$4"
    # In order, sorted in the shell: no process (ADR-065).
    codes=("${!_h[@]}")
    for (( i = 1; i < ${#codes[@]}; i++ )); do
        t="${codes[i]}"; j=$i
        while (( j > 0 )) && [[ "${codes[j-1]}" > "$t" ]]; do codes[j]="${codes[j-1]}"; j=$(( j - 1 )); done
        codes[j]="$t"
    done
    for c in ${codes[@]+"${codes[@]}"}; do list+="${list:+, }$c ${_h[$c]}"; done
    if [[ -z "$list" ]]; then
        _zhl="No $5 id is taken yet: every code starts at 1 (${4}LOOP-1)."
    else
        local _in=""; [[ -n "${6:-}" ]] && _in=", and in the repository's tests"
        _zhl="The highest number each code has had, removed ones counted$_in: $list. A new $5 with one of these codes takes the next number; a new code starts at 1."
    fi
    return 0
}

# zb_ids_check_v <out> <prev_active> <prev_removed> <new_active> <new_removed>
#                <text> <prefix> [carry] [tried] [used]
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
#   used                      ids already tagged in the repository's tests
#                             (zb_test_tag_ids_v): taken, so a new id is past
#                             them (#2550)
# An earlier id not of the new form (R-1, SPEC-1, LOOP-1 from before #2482) is
# the old numbering: it is given a new id, and needs no REMOVED line.
zb_ids_check_v() {
    local -n _zic="$1"
    local pa=" $2 " pr=" $3 " na="$4" nr=" $5 " text="$6" px="$7" carry="${8:-0}" tr=" ${9:-} "
    local id code num seen=" " hi
    local -A _hi=() _k=()
    _zic=()
    _zb_ids_highest_v _hi "$2 $3 ${10:-}" "$px"
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

# ─── Finding ids (#2574, ADR-068 §5) ─────────────────────────────────────────
# A finding has an id in the same scheme: its stage's prefix and a code of its
# own (<prefix>FND, or a tag a stage with several checks gives each, such as a
# lens), a dash and a number. Answers named a finding by its place in the list
# ("design finding 2"); the list changes between tries, so an answer could
# attach to another finding. The same finding — the same text — keeps its id;
# a new one takes the number after the highest its code has had, removed ones
# counted, so a removed id never comes back. What each code has given is kept
# beside the stage's outputs, in finding-ids-<code>.json: the stage's own
# record, read and written by the shell (no program, ADR-065 §5); the numbering
# is done in the one jq the writer already runs.

# zb_finding_code_v <var> <manifest> [tag] — the code a stage's findings take:
# its id_prefix and <tag> (FND when none); empty when it declares no prefix.
zb_finding_code_v() {
    local -n _zfc="$1"; local _zfc_p=""
    zb_id_prefix_v _zfc_p "${2:-}"
    _zfc=""; [[ -n "$_zfc_p" ]] && _zfc="$_zfc_p${3:-FND}"
    return 0
}

# zb_findings_reg_v <var> <dir> <code> — the record of the ids <code> has
# given, as JSON text ("{}" when there is none); rc 1 when <dir> or <code> is
# missing or the code is not of the id form.
zb_findings_reg_v() {
    local -n _zfr="$1"; _zfr="{}"
    [[ -n "${2:-}" && "${3:-}" =~ ^[A-Z][A-Z0-9]{2,23}$ ]] || return 1
    [[ -s "$2/finding-ids-$3.json" ]] && { IFS= read -r -d '' _zfr < "$2/finding-ids-$3.json" || true; }
    return 0
}

# zb_findings_reg_put <dir> <code> <json> — keep the record, written whole
# (atomic_write); one that cannot be written leaves the event
# finding_ids.write_failed, and the next numbering starts from the last record
# kept. A record cut short is read as none (fromjson below), never as an error.
zb_findings_reg_put() {
    [[ -n "${1:-}" && "${2:-}" =~ ^[A-Z][A-Z0-9]{2,23}$ && "${3:-}" == "{"* ]] || return 0
    local _zfp_ok=1
    if declare -F atomic_write >/dev/null 2>&1; then
        atomic_write "$1/finding-ids-$2.json" <<< "$3" 2>/dev/null || _zfp_ok=0
    else
        printf '%s\n' "$3" > "$1/finding-ids-$2.json" 2>/dev/null || _zfp_ok=0
    fi
    (( _zfp_ok )) && return 0
    declare -F eb_emit_event >/dev/null 2>&1 && eb_emit_event finding_ids.write_failed "code=$2" "dir=$1" >/dev/null 2>&1
    return 0
}

# The jq that gives each finding of an array its id: zb_fids($reg; $code) takes
# the record as text and gives {out: <findings with .id>, r: <the record>}. A
# text that comes twice in one list takes a new id the second time.
# shellcheck disable=SC2016  # jq text, not shell
_ZB_FINDING_IDS_JQ='def zb_fids($reg; $code):
  (($reg | try fromjson catch {}) | if type == "object" then . else {} end) as $r0
  | reduce .[] as $f ({r: {highest: ($r0.highest // 0), ids: ($r0.ids // {})}, out: [], used: {}};
      (($f | if type == "object" then .text else . end) | tostring) as $t
      | (.r.ids[$t] // null) as $have
      | if $have != null and (.used[$have] | not) then .out += [$f + {id: $have}] | .used[$have] = true
        else (.r.highest + 1) as $n | "\($code)-\($n)" as $id
          | .r.highest = $n | (if .r.ids[$t] == null then .r.ids[$t] = $id else . end)
          | .out += [$f + {id: $id}] | .used[$id] = true end);'
