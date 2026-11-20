#!/usr/bin/env bash
# plugins/agent/review-lens/lib/items.sh — a lens keeps its verdict per finding
# area (#2574, ADR-072 §4 §5, ADR-038), as design's check keeps one per part.
#
# A lens kept one report for the whole change, with the answers to its
# findings in its fingerprint: any change or answer had it review everything
# again, and its findings flipped. A lens finding names the file it is about,
# and a file is what a change changes, so the item is each file of the change:
# its kept findings — or that it had none — stand while the file, and the
# files outside the change the call read, are as they were. What is not about
# a file of the change, with the report's score and questions, is one more
# item, `change`, asked whenever the lens is called. An answer to a finding
# has its file reviewed again, held to it (judge_kept_get_all_v with the pass
# word), only when the file's kept report found something; only the files
# whose report no longer holds are asked, in one call. Sourced by plugin.sh.
#
# Sourced library: inherits the caller's pipefail/errexit; do not set them here.

[[ -n "${_ZBUILD_REVIEW_LENS_ITEMS_LOADED:-}" ]] && return 0
_ZBUILD_REVIEW_LENS_ITEMS_LOADED=1

# _rl_finding_code_v <var> <lens> — the code a lens's findings' ids take
# (#2574, ADR-068 §5): the stage's prefix and three letters of the lens's
# name (RLSRE, RLSEC, RLCOR), so two lenses' ids are never the same.
_rl_finding_code_v() {
    local -n _rfc="$1"; local _rfc_t="${2^^}"
    _rfc_t="${_rfc_t//[^A-Z0-9]/}XXX"; _rfc_t="${_rfc_t:0:3}"
    [[ "$_rfc_t" =~ ^[A-Z] ]] || _rfc_t="L${_rfc_t:0:2}"
    zb_finding_code_v _rfc "$_RL_DIR/manifest.yaml" "$_rfc_t"
}

# _rl_changed_files_v <array> <change_text> <patch_body> — the files of the
# change, as zbuild_change_files_v lists them (`<status><TAB><path>`), or, with
# no starting commit, as the round's patch names them.
_rl_changed_files_v() {
    local -n _rcf="$1"; local l
    _rcf=()
    while IFS= read -r l; do
        [[ "$l" =~ ^[AMDTRC]$'\t'(.+)$ ]] && _rcf+=("${BASH_REMATCH[1]}")
    done <<< "${2:-}"
    [[ ${#_rcf[@]} -gt 0 ]] && return 0
    while IFS= read -r l; do
        [[ "$l" == "diff --git a/"* && "$l" == *" b/"* ]] && _rcf+=("${l##* b/}")
    done <<< "${3:-}"
    return 0
}

# _rl_area_of_v <var> <finding text> — the file a lens finding, as the lens
# routes it, is about: `<lens> lens, <severity>: <message> (<file>…`.
_rl_area_of_v() {
    local -n _rao="$1"; _rao=""
    [[ "$2" =~ \(([^\ \(\):\;\"]+)(:\ \"|\;\ happens\ when) ]] && _rao="${BASH_REMATCH[1]}"
    return 0
}

# _rl_items_prepare <kept_file> <engine> <base> <whole> <answers> <af_assoc> —
# the items and their kept reports: _RL_IT_FPS (item → fingerprint: a file's
# is the lens's prompt without the change and the file's name; `change`'s is
# the whole change), _RL_IT_DFP (item → the answers to its findings, by
# fingerprint), _RL_IT_KEPT (JSON object: each kept item's report) and
# _RL_IT_WANT (the items to ask, `change` among them when any is). Reads
# _RL_IT_FILES.
declare -gA _RL_IT_FPS=() _RL_IT_DFP=()
_RL_IT_KEPT="{}" _RL_IT_WANT=""
_rl_items_prepare() {
    local kf="$1" eng="$2" base="$3" whole="$4" ans="$5" f fp it a k kj
    local -n _rip_af="$6"
    _RL_IT_FPS=() _RL_IT_DFP=() _RL_IT_KEPT="{}" _RL_IT_WANT=""
    for f in ${_RL_IT_FILES[@]+"${_RL_IT_FILES[@]}"}; do
        judge_fp_v fp "$eng"$'\n'file$'\n'"$f"$'\n'"$base"; _RL_IT_FPS["$f"]="$fp"
    done
    judge_fp_v fp "$eng"$'\n'change$'\n'"$whole"; _RL_IT_FPS[change]="$fp"
    # shellcheck disable=SC2034  # earlier and why are filled by name
    local -A disp=() kept=() earlier=() why=()
    while IFS= read -r a; do
        k="${a%%:*}"; [[ -n "$k" && -n "${_rip_af[$k]+x}" ]] || continue
        _rl_area_of_v it "${_rip_af[$k]%%$'\x1f'*}"
        [[ -n "$it" && -n "${_RL_IT_FPS[$it]+x}" ]] || it=change
        disp["$it"]+="$a"$'\n'
    done <<< "$ans"
    for it in "${!disp[@]}"; do judge_fp_v fp "${disp[$it]}"; _RL_IT_DFP["$it"]="$fp"; done
    judge_kept_get_all_v kept "$kf" _RL_IT_FPS _RL_IT_DFP earlier "clean" why
    local body=""
    for it in ${_RL_IT_FILES[@]+"${_RL_IT_FILES[@]}"} change; do
        if [[ -n "${kept[$it]+x}" && "${kept[$it]}" == *$'\n'* ]]; then
            _judge_json_str_v kj "$it"; body+=",$kj:${kept[$it]#*$'\n'}"
        else
            _RL_IT_WANT+=" $it"
        fi
    done
    _RL_IT_KEPT="{${body#,}}"
    [[ -n "$_RL_IT_WANT" && " $_RL_IT_WANT " != *" change "* ]] && _RL_IT_WANT+=" change"
    return 0
}

# _rl_items_only_v <var> — what a call that asks only some files is told; empty
# when every file is asked.
_rl_items_only_v() {
    local -n _rio="$1"; local f list="" all=1
    _rio=""
    for f in ${_RL_IT_FILES[@]+"${_RL_IT_FILES[@]}"}; do
        if [[ " $_RL_IT_WANT " == *" $f "* ]]; then list+="- $f"$'\n'; else all=0; fi
    done
    (( all )) && return 0
    _rio=$'\n\n'"THIS TIME, REVIEW ONLY THESE FILES OF THE CHANGE — every other file keeps the findings you gave it before; report nothing about them:"$'\n'"${list:-(none: report only what is not in a file of the change)}"
}

# _rl_items_assemble_v <var> — the report from the kept items alone: every
# file's findings, and `change`'s findings, score and questions. One jq.
_rl_items_assemble_v() {
    local -n _ria="$1"
    _ria="$(jq -nc --argjson k "$_RL_IT_KEPT" '($k.change // {}) as $c
        | $c + {findings: ([$k | to_entries[] | select(.key != "change") | .value[]?] + ($c.findings // []))}' 2>/dev/null)" || _ria=""
}

# The jq the lens's normalization runs first (#2574): with $called 1 or 2, the
# report is the kept files' findings and the reply's — for the files asked,
# and what is in no file of the change; a finding about another file is set
# aside. `P<TAB><item><TAB><report>` lines follow for each item asked
# ($called 1: a reply kept whole).
# shellcheck disable=SC2016  # jq text, not shell
_RL_ITEMS_JQ='def fileof: (if type == "object" then (.file // "unknown") else "unknown" end | tostring);
  . as $r
  | (if $called == 0 then {r: $r, p: []} else
      ($asked | map(select(. != "change"))) as $af
      | [($r.findings // [])[] | select(fileof as $f | ($af | index($f)) != null or ($files | index($f)) == null)] as $take
      | [$files[] as $f | select(($af | index($f)) == null) | ($kept[$f] // [])[]] as $keep
      | {r: ($r + {findings: ($keep + $take)}),
         p: (if $called != 1 then [] else
              [($af[] as $f | "P\t\($f)\t" + ([$take[] | select(fileof == $f)] | tojson)),
               ("P\tchange\t" + (($r | del(.findings)) + {findings: [$take[] | select(fileof as $f | ($files | index($f)) == null)]} | tojson))] end)} end) as $z
  | $z.r as $report'

# _rl_json_list_v <var> <item>... — the items as a JSON array, by the shell.
_rl_json_list_v() {
    local -n _rjl="$1"; shift; local _rjl_x _rjl_j _rjl_o=""
    for _rjl_x in "$@"; do [[ -n "$_rjl_x" ]] || continue; _judge_json_str_v _rjl_j "$_rjl_x"; _rjl_o+="${_rjl_o:+,}$_rjl_j"; done
    _rjl="[$_rjl_o]"
}

# _rl_items_keep <kept_file> <items_out> <repo> [opened]... — keep each item the
# call was asked about (the `P` lines _RL_ITEMS_JQ gives): its report, with a
# verdict line judge_refused reads (clean, or found), under its fingerprint
# and the answers it heard; a file depends on itself, the files outside the
# change the call read, and the files its findings quote.
_rl_items_keep() {
    local kf="$1" out="$2" repo="$3" l t it j q; shift 3
    # shellcheck disable=SC2034  # putfp is filled and read by name
    local -A put=() putfp=() deps=()
    local opened=""; for l in "$@"; do opened+="$l"$'\n'; done
    while IFS=$'\t' read -r t it j; do
        [[ "$t" == P && -n "$it" && -n "${_RL_IT_FPS[$it]+x}" ]] || continue
        if [[ "$j" == "[]" || "$j" == *'"findings":[]'* ]]; then put["$it"]="clean: no finding"$'\n'"$j"
        else put["$it"]="found: findings"$'\n'"$j"; fi
        judge_kept_fp_v "putfp[$it]" "${_RL_IT_FPS[$it]}" "${_RL_IT_DFP[$it]:-}"
        deps["$it"]="$opened"; [[ "$it" == change ]] || deps["$it"]+="$repo/$it"$'\n'
        # The files its findings quote.
        while [[ "$j" =~ \"file\":\"([^\"]+)\" ]]; do
            q="${BASH_REMATCH[1]}"; j="${j/"\"file\":\"$q\""/}"
            [[ "$q" == unknown || "$q" == /* || "$q" == *..* ]] || deps["$it"]+="$repo/$q"$'\n'
        done
    done <<< "$out"
    # shellcheck disable=SC2034  # read by judge_kept_put_all through their names
    [[ ${#put[@]} -gt 0 ]] && judge_kept_put_all "$kf" put putfp deps
    return 0
}
