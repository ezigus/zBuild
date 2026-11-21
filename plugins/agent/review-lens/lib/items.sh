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

# _rl_lens_tags_check <lens>... — rc 1, with an error naming them, when two
# lenses' findings would take the same code (review on #2574): their ids
# would be the same.
_rl_lens_tags_check() {
    local l c rc=0; local -A seen=()
    for l in "$@"; do
        _rl_finding_code_v c "$l"
        if [[ -n "${seen[$c]:-}" ]]; then
            error "the ${seen[$c]} and $l lenses' findings would both take the code $c — rename one (#2574)"; rc=1
        else seen["$c"]="$l"; fi
    done
    return "$rc"
}

# _rl_run_lens_tags_ok <out> — rc 1, the lens's result written misconfigured,
# when two of the run's lenses (its map group's elements) share a code.
_rl_run_lens_tags_ok() {
    local mv="_TPL_MAP_ELEMENTS_${ZBUILD_CURRENT_STAGE:-none}"; mv="${mv//[^A-Za-z0-9_]/_}"
    [[ -n "${!mv:-}" ]] || return 0
    # shellcheck disable=SC2086  # the elements are words, one a lens
    _rl_lens_tags_check ${!mv//,/ } && return 0
    _review_lens_write_result "$1" misconfigured "two lenses' findings would take the same code"
    return 1
}

# _rl_changed_files_v <array> <change_fp> <patch_body> — the files of the
# change, from the change's raw diff (zbuild_change_files_v's fingerprint:
# the starting commit, then `:<modes> <old blob> <new blob> <status><TAB><path>`,
# a renamed file `R<score><TAB><old><TAB><new>`), or, with no starting commit,
# as the round's patch names them. A renamed file is listed by its new path;
# _RL_IT_RENAMED[new] = its old path.
declare -gA _RL_IT_RENAMED=()
_rl_changed_files_v() {
    local -n _rcf="$1"; local l p
    _rcf=(); _RL_IT_RENAMED=()
    while IFS= read -r l; do
        [[ "$l" =~ ^:[0-7]+\ [0-7]+\ ([0-9a-f]+)\ ([0-9a-f]+)\ ([A-Z])[0-9]*$'\t'(.+)$ ]] || continue
        p="${BASH_REMATCH[4]}"; _rcf+=("${p##*$'\t'}")
        [[ "${BASH_REMATCH[3]}" == R ]] && _RL_IT_RENAMED["${p##*$'\t'}"]="${p%%$'\t'*}"
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

# _rl_items_prepare <kept_file> <engine> <base> <answers> <af_assoc> — the
# items and their kept reports: _RL_IT_FPS (item → fingerprint: what the lens
# was shown but the change — its prompt without the change, and the commit the
# change starts from — and the item's name; one checksum for them all, ADR-065
# §5), _RL_IT_DFP (item → the answers to its findings, by fingerprint),
# _RL_IT_KEPT (JSON object: each kept item's report) and _RL_IT_WANT (the items
# to ask, `change` among them when any is). Reads _RL_IT_FILES. A file's
# content is in its own kept report's files; `change` depends on every file of
# the change (_rl_items_keep).
declare -gA _RL_IT_FPS=() _RL_IT_DFP=()
_RL_IT_KEPT="{}" _RL_IT_WANT="" _RL_IT_NOTES="" _RL_IT_HELD=""
_rl_items_prepare() {
    local kf="$1" eng="$2" base="$3" ans="$4" f fp it a k kj
    local -n _rip_af="$5"
    _RL_IT_FPS=() _RL_IT_DFP=() _RL_IT_KEPT="{}" _RL_IT_WANT=""
    judge_fp_v fp "$eng"$'\n'"$base"
    for f in ${_RL_IT_FILES[@]+"${_RL_IT_FILES[@]}"}; do _RL_IT_FPS["$f"]="$fp:file:$f"; done
    _RL_IT_FPS[change]="$fp:change"
    # shellcheck disable=SC2034  # earlier and why are filled by name
    local -A disp=() kept=() earlier=() why=()
    while IFS= read -r a; do
        k="${a%%:*}"; [[ -n "$k" && -n "${_rip_af[$k]+x}" ]] || continue
        _rl_area_of_v it "${_rip_af[$k]%%$'\x1f'*}"
        [[ -n "$it" && -n "${_RL_IT_FPS[$it]+x}" ]] || it=change
        disp["$it"]+="$a"$'\n'
    done <<< "$ans"
    for it in "${!disp[@]}"; do judge_fp_v fp "${disp[$it]}"; _RL_IT_DFP["$it"]="$fp"; done
    _rl_items_carry_renames "$kf" "${ZBUILD_REPO_ROOT:-$PWD}"
    judge_kept_get_all_v kept "$kf" _RL_IT_FPS _RL_IT_DFP earlier "clean" why
    # #2574 (ADR-072 §5): a file a stage handed on waits, its findings standing;
    # one back from the stage it was handed to is reviewed again.
    # shellcheck disable=SC2034  # keyit is read by name
    local -A keyit=(); local hl=""
    # shellcheck disable=SC2034  # keyit is read by name
    for k in "${!_rip_af[@]}"; do _rl_area_of_v it "${_rip_af[$k]%%$'\x1f'*}"; [[ -n "${_RL_IT_FPS[$it]+x}" ]] && keyit["$k"]="$it"; done
    judge_handoff_check "$kf" "$ans" keyit kept earlier ${_RL_IT_FILES[@]+"${_RL_IT_FILES[@]}"}
    _RL_IT_NOTES="" _RL_IT_HELD=""
    for it in "${!_JUDGE_HANDOFF_WAIT[@]}"; do judge_handoff_waiting_v k "${_JUDGE_HANDOFF_WAIT[$it]}"; _RL_IT_NOTES+="- $it: $k"$'\n'; done
    for it in "${!_JUDGE_HANDOFF_BACK[@]}"; do judge_held_entry_v k "$it" "${_JUDGE_HANDOFF_BACK[$it]}"; hl+="$k"; done
    [[ -n "$hl" ]] && judge_held_block_v _RL_IT_HELD "$hl"
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

# _rl_items_carry_renames <kept_file> <repo> — a renamed file takes over the
# report kept under its old path (review on #2574): the record moves to the new
# path, its file with it, so it holds while the file's content is the content
# it was judged on. One jq, only when a renamed file has no report of its own.
_rl_items_carry_renames() {
    local kf="$1" repo="$2" n o body="" pairs=""
    [[ ${#_RL_IT_RENAMED[@]} -gt 0 && -s "$kf" ]] || return 0
    IFS= read -r -d '' body < "$kf" || true
    for n in "${!_RL_IT_RENAMED[@]}"; do
        o="${_RL_IT_RENAMED[$n]}"
        [[ "$body" == *"\"$o\":"* && "$body" != *"\"$n\":"* ]] && pairs+="$o"$'\t'"$n"$'\n'
    done
    [[ -n "$pairs" ]] || return 0
    jq -c --arg p "$pairs" --arg r "$repo/" '. as $d
        | reduce ($p | split("\n")[] | select(length > 0) | split("\t")) as $x ($d;
            if .[$x[0]] then .[$x[1]] = (.[$x[0]]
                | (.fp | tostring) as $f | ($f | index(":file:" + $x[0])) as $i
                | .fp = (if $i then $f[:$i] + ":file:" + $x[1] + $f[($i + 6 + ($x[0] | length)):] else $f end)
                | .files |= with_entries(if .key == ($r + $x[0]) then .key = ($r + $x[1]) else . end)) else . end)' \
        <<< "$body" > "$kf.tmp" 2>/dev/null && mv -f "$kf.tmp" "$kf" 2>/dev/null
    [[ -e "$kf.tmp" ]] && rm -f "$kf.tmp" 2>/dev/null
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
        # Review on #2574: what the call read, the other changed files among
        # them; a report that found something, or `change`, depends on every
        # file of the change — files work together.
        deps["$it"]="$opened"
        if [[ "$it" == change || "${put[$it]}" == found:* ]]; then
            for q in ${_RL_IT_FILES[@]+"${_RL_IT_FILES[@]}"}; do deps["$it"]+="$repo/$q"$'\n'; done
        fi
        [[ "$it" == change ]] || deps["$it"]+="$repo/$it"$'\n'
        # The files its findings quote.
        while [[ "$j" =~ \"file\":\"([^\"]+)\" ]]; do
            q="${BASH_REMATCH[1]}"; j="${j/"\"file\":\"$q\""/}"
            [[ "$q" == unknown || "$q" == /* || "$q" == *..* ]] || deps["$it"]+="$repo/$q"$'\n'
        done
    done <<< "$out"
    # shellcheck disable=SC2034  # read by judge_kept_put_all through their names
    [[ ${#put[@]} -gt 0 ]] && judge_kept_put_all "$kf" put putfp deps
    judge_handoff_done "$kf"
    return 0
}
