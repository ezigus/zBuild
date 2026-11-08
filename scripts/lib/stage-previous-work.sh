#!/usr/bin/env bash
# scripts/lib/stage-previous-work.sh — the Previous work block of the engine's
# prompt contract (ADR-067 §8).
#
# Every stage receives the latest output of every stage that has run, its own
# included, whichever try or run wrote it (ADR-068 §8, ADR-050 §9). Sourced by
# scripts/lib/stage-prompt.sh, which defines the helpers used here
# (_sp_unit, stage_notes_path, the _ZB_SP_* bounds).
#
# Sourced library: inherits the caller's shell options; do NOT add set -euo.

[[ -n "${_ZBUILD_STAGE_PREVIOUS_WORK_LOADED:-}" ]] && return 0
_ZBUILD_STAGE_PREVIOUS_WORK_LOADED=1

# ─── What this issue's work has changed ─────────────────────────────────────
# shellcheck source=./merge-base.sh
source "$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; pwd)/merge-base.sh"

# _sp_work_changed_line <repo_root> — one line naming the files this
# issue's work has changed, against where its branch left the default branch,
# so a rerun still lists what earlier runs committed. Said once, at the top: it
# is the same for every stage. No default branch, or no readable repository: no
# line.
_sp_work_changed_line() {
    local repo_root="$1" base files line n=0 shown=""
    [[ -n "$repo_root" ]] || return 0
    base="$(zbuild_resolve_merge_base "$repo_root")"
    [[ -n "$base" ]] || return 0
    files="$(git -C "$repo_root" diff --name-only "$base" -- 2>/dev/null)" || return 0
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        n=$((n + 1))
        (( n <= 20 )) && shown+="${shown:+, }$line"
    done <<< "$files"
    if (( n == 0 )); then
        printf "Files this issue's work has changed so far: none.\n"
    else
        (( n > 20 )) && shown+=", … ($n in all)"
        printf "Files this issue's work has changed so far: %s\n" "$shown"
    fi
}

# _sp_no_output <result-text> — rc 0 when the result says the stage produced no
# output: a contract-2 `verdict: error`, or a contract-3 outcome that is neither
# pass nor fail (#2366: the stage did not finish).
_sp_no_output() {
    local c="${1-}"
    [[ "$c" =~ \"verdict\"[[:space:]]*:[[:space:]]*\"error\" ]] && return 0
    if [[ "$c" =~ \"outcome\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then
        [[ "${BASH_REMATCH[1]}" != pass && "${BASH_REMATCH[1]}" != fail ]] && return 0
    fi
    return 1
}

# _sp_last_good_attempt <state_dir> <stage> <primary-basename> [<required-basenames>]
# — the newest archived attempt of <stage> whose primary result is not an error
# and that wrote every output the stage marks `required: true` (one basename per
# line), i.e. the last attempt that produced its output
# (core/plugin-registry/attempt-archive.sh keeps a copy of every dispatch's
# outputs). Prints its directory; nothing when there is none.
_sp_last_good_attempt() {
    local base="$1/artifacts/attempts/${2//[^A-Za-z0-9_-]/_}" name="$3" req="${4:-}" d best="" content r ok
    [[ -d "$base" && -n "$name" ]] || return 0
    while IFS= read -r d; do
        [[ -s "$d/$name" ]] || continue
        content="$(<"$d/$name")"
        _sp_no_output "$content" && continue
        ok=1
        while IFS= read -r r; do
            [[ -z "$r" || -s "$d/$r" ]] || { ok=0; break; }
        done <<< "$req"
        (( ok )) || continue
        best="$d"
    done < <(find "$base" -mindepth 1 -maxdepth 1 -type d -name 'iter-*-attempt-*' 2>/dev/null \
                | awk -F'iter-|-attempt-' '{ printf "%09d %09d %s\n", $(NF-1), $NF, $0 }' \
                | LC_ALL=C sort | cut -d' ' -f3-)
    [[ -n "$best" ]] && printf '%s' "$best"
    return 0
}

# ─── Previous work ───────────────────────────────────────────────────────────
# _sp_manifest_roles <manifest> <state_dir> — one line per output that plays a
# role: "S<TAB>path" (summary: true), "E<TAB>path" (errors: true), "P<TAB>path"
# (primary: true), "R<TAB>path" (required: true), for every output that
# names a topic (ADR-071) "T<TAB>topic<TAB>id<TAB>path", and for every output
# that declares finding_topics (#2454) "F<TAB>words<TAB>id<TAB>path". Read once per manifest per run and kept under the run's
# runtime/ folder: the block is written at every dispatch, each dispatch is its
# own subshell, and the fork budget (ADR-065) counts every read.
_sp_manifest_roles() { local _smr; _sp_manifest_roles_v _smr "$1" "$2"; printf '%s' "$_smr"; }
# _sp_manifest_roles_v <var> <manifest> <state_dir> — the same lines into <var>,
# read in this shell: the block asks once for every earlier stage.
_sp_manifest_roles_v() {
    local -n _smrv="$1"
    local m="$2" state_dir="$3" c
    _smrv=""
    c="$state_dir/runtime/manifest-roles/${m//[^A-Za-z0-9._-]/_}"
    if [[ ! -e "$c" ]]; then
        [[ -d "${c%/*}" ]] || mkdir -p "${c%/*}" 2>/dev/null
        awk '
            function flush() {
                if (path != "") {
                    if (summ) print "S\t" path
                    if (err)  print "E\t" path
                    if (prim) print "P\t" path
                    if (req)  print "R\t" path
                    if (topic != "") print "T\t" topic "\t" id "\t" path
                    if (ft != "") print "F\t" ft "\t" id "\t" path
                }
                path = ""; id = ""; topic = ""; ft = ""; summ = 0; err = 0; prim = 0; req = 0
            }
            /^outputs:[[:space:]]*$/ { inb = 1; next }
            inb && /^[a-zA-Z_]/ { flush(); inb = 0 }
            inb && /^[[:space:]]*-[[:space:]]/ {
                flush(); i = $0; sub(/^[[:space:]]*-[[:space:]]*id:[[:space:]]*/, "", i)
                if (i != $0) { sub(/[[:space:]]*#.*/, "", i); gsub(/^["\047]|["\047]$/, "", i); id = i } }
            inb && /^[[:space:]]+path:[[:space:]]*/ {
                p = $0; sub(/^[[:space:]]+path:[[:space:]]*/, "", p); sub(/[[:space:]]*#.*/, "", p)
                gsub(/^["\047]|["\047]$/, "", p); path = p }
            inb && /^[[:space:]]+summary:[[:space:]]*true/ { summ = 1 }
            inb && /^[[:space:]]+errors:[[:space:]]*true/  { err = 1 }
            inb && /^[[:space:]]+primary:[[:space:]]*true/ { prim = 1 }
            inb && /^[[:space:]]+required:[[:space:]]*true/ { req = 1 }
            inb && /^[[:space:]]+id:[[:space:]]*/ {
                i = $0; sub(/^[[:space:]]+id:[[:space:]]*/, "", i); sub(/[[:space:]]*#.*/, "", i)
                gsub(/^["\047]|["\047]$/, "", i); id = i }
            inb && /^[[:space:]]+finding_topics:[[:space:]]*/ {
                f = $0; sub(/^[[:space:]]+finding_topics:[[:space:]]*/, "", f); sub(/[[:space:]]*#.*/, "", f); ft = f }
            inb && /^[[:space:]]+topic:[[:space:]]*/ {
                t = $0; sub(/^[[:space:]]+topic:[[:space:]]*/, "", t); sub(/[[:space:]]*#.*/, "", t)
                gsub(/^["\047]|["\047]$/, "", t); topic = t }
            END { flush() }' "$m" > "$c.$$" 2>/dev/null && mv -f "$c.$$" "$c" 2>/dev/null \
            || { rm -f "$c.$$" 2>/dev/null; return 0; }
    fi
    # As `$(<"$c")` gave it: the whole file, less its trailing newlines.
    IFS= read -r -d '' _smrv < "$c" || true
    while [[ "$_smrv" == *$'\n' ]]; do _smrv="${_smrv%$'\n'}"; done
}

# _sp_takes_v <var> <manifest> — the topics the stage's `takes:` names, as
# " ask change " (spaces around each), or "" when it declares none: a stage
# with no takes: is shown every stage's output (ADR-071). Each take is
# `- topic: <word>` with its `for:` (#2428); only the topic is read here.
_sp_takes_v() {
    local -n _stv="$1"
    local line in=0
    _stv=""
    [[ -n "${2:-}" && -r "$2" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^takes:[[:space:]]*$ ]]; then in=1; continue; fi
        (( in )) || continue
        [[ "$line" =~ ^[a-zA-Z_] ]] && break
        [[ "$line" =~ ^[[:space:]]*-[[:space:]]+topic:[[:space:]]*([^[:space:]#]+) ]] && _stv+=" ${BASH_REMATCH[1]}"
    done < "$2"
    [[ -n "$_stv" ]] && _stv+=" "
    return 0
}

# _sp_output_paths_v <array-var> <stage> <raw> <state_dir> — every path an
# output resolves to, in this shell (#2470, ADR-065 §5): one, or a map stage's
# one per element (#2480: every member's, not the first only).
_sp_output_paths_v() {
    local -n _sop="$1"; _sop=()
    local _sop_safe="${2//-/_}" _sop_raw="$3" _sop_x _sop_p
    local _sop_t="_TPL_STAGE_TYPE_$_sop_safe" _sop_as="_TPL_MAP_AS_$_sop_safe" _sop_el="_TPL_MAP_ELEMENTS_$_sop_safe"
    if [[ "${!_sop_t:-}" == map && -n "${!_sop_el:-}" ]]; then
        local -a _sop_e=()
        IFS=',' read -r -a _sop_e <<< "${!_sop_el}"
        local _sop_a="${!_sop_as:-}"
        for _sop_x in ${_sop_e[@]+"${_sop_e[@]}"}; do
            [[ -n "$_sop_x" ]] || continue
            _sop_p="$_sop_raw"; [[ -n "$_sop_a" ]] && _sop_p="${_sop_p//\$\{$_sop_a\}/$_sop_x}"
            _verdict_resolve_path_v _sop_p "$_sop_p" "$4"; _sop+=("$_sop_p")
        done
        return 0
    fi
    _verdict_resolve_path_v _sop_p "$_sop_raw" "$4"; _sop=("$_sop_p")
}

# _sp_read <file> <max> — the first <max> bytes of a file, without a fork.
_sp_read() { local c; [[ -r "$1" ]] || return 0; c="$(<"$1")"; printf '%s' "${c:0:$2}"; }

# _stage_block_previous_work <stage> <state_dir> <plugins_root> <index> <repo_root> [<manifest>]
# <manifest> is the stage's own (its takes:); without it, it is looked up.
_stage_block_previous_work() {
    local stage="$1" state_dir="$2" plugins_root="$3" index="$4" repo_root="$5" self_manifest="${6:-}"
    local state_file="$state_dir/pipeline-state.json"
    declare -F _inputs_build_producer_index >/dev/null 2>&1 \
        || source "$_ZBUILD_SP_ROOT/core/pipeline/input-resolve.sh"
    declare -F _zbuild_sanitize_for_llm >/dev/null 2>&1 \
        || source "$_ZBUILD_SP_ROOT/scripts/lib/test-output-sanitize.sh" 2>/dev/null || true
    _inputs_build_producer_index "$plugins_root" "$state_dir"
    # ADR-071: what the stage takes. Each output's topic is checked against it.
    local takes=""
    [[ -n "$self_manifest" ]] || _inputs_stage_manifest_v self_manifest "$stage" "$plugins_root" 2>/dev/null || true
    _sp_takes_v takes "$self_manifest"

    if [[ -n "$takes" ]]; then
        printf 'The latest output of every stage that has run, as far as it is about what\n'
        printf 'your job takes (%s), with where to find it. Use what your job needs.\n' "$(_sp_list_words "$takes")"
    else
        printf 'The latest output of every stage that has run, with where to find it. Use\n'
        printf 'what your job needs.\n'
    fi
    if [[ -z "$takes" || "$takes" == *" change "* ]]; then
        local changed; changed="$(_sp_work_changed_line "$repo_root")"
        [[ -n "$changed" ]] && printf '\n%s\n' "$changed"
    fi

    # Everything read once, in one jq (#2491, ADR-065 §5): the stages in the
    # order they first completed with their verdicts, then every output in the
    # index, by id.
    local -a order=() _pw_ins=()
    local -A verdicts=() outs=() seen=() outtext=() outpath=()
    local line k v id _pw_t
    local -a _pw_args=(--argjson st '[]')
    [[ -s "$state_file" ]] && _pw_args=(--slurpfile st "$state_file")
    if [[ -n "$index" && -s "$index" ]]; then _pw_args+=(--slurpfile ix "$index"); else _pw_args+=(--argjson ix '[]'); fi
    while IFS=$'\t' read -r _pw_t k v; do
        if [[ "$_pw_t" == I ]]; then _pw_ins+=("$k"$'\t'"$v"); continue; fi
        [[ -n "$k" && -z "${seen[$k]:-}" ]] || continue
        seen[$k]=1; order+=("$k"); verdicts[$k]="$v"
    done < <(jq -rn "${_pw_args[@]}" '(($st[0] // {}) as $r | ($r.stage_statuses // {}) | keys_unsorted[]
                    | "S\t\(.)\t\($r.stage_verdicts[.] // "")"),
                    (($ix[0].inputs // {}) | to_entries | sort_by(.key)[]
                    | "I\t\(.key)\t\(if (.value|type) == "array" then (.value | join("\u001f")) + "\u001f" else .value end)")' 2>/dev/null || true)
    while IFS= read -r k; do
        [[ -n "$k" && -z "${seen[$k]:-}" ]] || continue
        seen[$k]=1; order+=("$k")
    done < <(_inputs_flow_stages 2>/dev/null)
    if [[ ${#_pw_ins[@]} -gt 0 ]]; then
        local _pw_in
        for _pw_in in "${_pw_ins[@]}"; do
            id="${_pw_in%%$'\t'*}"; v="${_pw_in#*$'\t'}"
            [[ -n "$id" ]] || continue
            k="${_IR_PRODUCER[$id]:-}"; [[ -n "$k" ]] || continue
            outs[$k]+="$id "
            if [[ "$v" == *$'\x1f'* ]]; then
                # #2480: a map group's output, one file a member — each is
                # read for findings as a single file is (ADR-071 §2).
                outtext[$id]="- $id:"$'\n'; outpath[$id]=""
                local m; while IFS= read -r m; do
                    [[ -n "$m" ]] || continue
                    outtext[$id]+="    - $m"$'\n'; outpath[$id]+="$m"$'\n'
                done <<< "${v//$'\x1f'/$'\n'}"
            else
                outtext[$id]="- $id: $v"$'\n'
                outpath[$id]="$v"
            fi
        done
    fi

    local s manifest roles summ errp res req notes cutoff verdict own body any=0 raw content
    local -a summs=() prims=()
    local listed t_topic t_id t_path
    local -A topic_of=() allow_of=()
    for s in "${order[@]}"; do
        # Only a stage's own notes come back to it (ADR-067 §8); another
        # stage's notes are its working file, not its output.
        notes=""; cutoff=""
        if [[ "$s" == "$stage" ]]; then
            stage_notes_path_v notes "$state_dir" "$s"
            # #2443: the steps of its last call, if that call was cut off.
            stage_cutoff_path_v cutoff "$state_dir" "$s" 2>/dev/null || cutoff=""
        fi
        [[ -n "$notes" && -s "$notes" ]] || notes=""
        [[ -n "$cutoff" && -s "$cutoff" ]] || cutoff=""
        [[ -n "${outs[$s]:-}" || -n "$notes" || -n "$cutoff" ]] || continue
        _inputs_stage_manifest_v manifest "$s" "$plugins_root" 2>/dev/null || true
        summ=""; errp=""; res=""; req=""; roles=""; summs=(); prims=()
        topic_of=(); allow_of=()
        [[ -n "$manifest" ]] && _sp_manifest_roles_v roles "$manifest" "$state_dir"
        # ADR-071: an output is shown when the stage takes its topic (by id
        # for the listed paths, by manifest path for the summary, the errors
        # and the result). With no takes:, everything is.
        while IFS=$'\t' read -r k t_topic t_id t_path; do
            case "$k" in
                T) topic_of["id:$t_id"]="$t_topic"; topic_of["path:$t_path"]="$t_topic" ;;
                F) allow_of["id:$t_id"]="$t_topic"; allow_of["path:$t_path"]="$t_topic" ;;
            esac
        done <<< "$roles"
        local res_any="" res_topic="" res_allow=""
        while IFS=$'\t' read -r k raw; do
            [[ "$k" == [SEP] ]] || { [[ "$k" == R ]] && req+="${raw##*/}"$'\n'; continue; }
            # #2452: the primary result is read for its findings whatever its
            # topic; each finding goes by its own topic (§2).
            # #2480: a map group's is one file a member, each read.
            if [[ "$k" == P && -z "$res_any" ]]; then
                _sp_output_paths_v prims "$s" "$raw" "$state_dir"; res_any="${prims[0]:-}"
                res_topic="${topic_of["path:$raw"]:-none}"; res_allow="${allow_of["path:$raw"]:-}"
            fi
            [[ -z "$takes" || "$takes" == *" ${topic_of["path:$raw"]:-none} "* ]] || continue
            case "$k" in
                S) [[ -z "$summ" ]] && { _sp_output_paths_v summs "$s" "$raw" "$state_dir"; summ="${summs[0]:-}"; } ;;
                E) [[ -z "$errp" ]] && _verdict_resolve_path_v errp "$raw" "$state_dir" ;;
                P) [[ -z "$res" ]] && _verdict_resolve_path_v res "$raw" "$state_dir" ;;
            esac
        done <<< "$roles"
        listed=""; local -a found=() found_topic=() found_allow=()
        for id in ${outs[$s]:-}; do
            # Every JSON output is read for findings; only a taken one is listed.
            while IFS= read -r raw; do
                [[ "$raw" == *.json ]] && { found+=("$raw"); found_topic+=("${topic_of["id:$id"]:-none}"); found_allow+=("${allow_of["id:$id"]:-}"); }
            done <<< "${outpath[$id]:-}"
            [[ -z "$takes" || "$takes" == *" ${topic_of["id:$id"]:-none} "* ]] || continue
            listed+="${outtext[$id]}"
        done
        [[ "$res" == *.json && -s "$res" ]] || res=""
        [[ "$res_any" == *.json && -s "$res_any" ]] || res_any=""

        # ADR-071 §2, #2452: a finding is shown when the stage takes its own
        # topic, or — when it names none its output allows (finding_topics,
        # #2454) — its output's.
        body=""
        # A map group's results are each labelled by the member's file.
        local fp lbl more _fx _pnames=" "
        for fp in ${prims[@]+"${prims[@]}"}; do
            _pnames+="${fp##*/} "
            [[ "$fp" == *.json && -s "$fp" ]] && _sp_has_numbered "$(<"$fp")" || continue
            lbl="$s"; if (( ${#prims[@]} > 1 )); then lbl="${fp##*/}"; lbl="${lbl%.json}"; lbl="${lbl%-result}"; fi
            more="$(_sp_findings_for "$fp" "$s" "$lbl" "$res_topic" "$takes" "$res_allow")"
            [[ -n "$more" ]] && body+="${body:+$'\n'}$more"
        done
        # #2428 (ADR-071 §2): the findings of every other output, labelled by
        # the output's file — the name open_items_json gives them.
        for _fx in "${!found[@]}"; do
            fp="${found[$_fx]}"
            [[ "$_pnames" != *" ${fp##*/} "* && -s "$fp" ]] || continue
            _sp_has_numbered "$(<"$fp")" || continue
            lbl="${fp##*/}"; lbl="${lbl%.json}"; lbl="${lbl%-result}"
            more="$(_sp_findings_for "$fp" "$s" "$lbl" "${found_topic[$_fx]}" "$takes" "${found_allow[$_fx]}")"
            [[ -n "$more" ]] && body+="${body:+$'\n'}$more"
        done

        [[ -n "$listed" || -n "$summ" || -n "$errp" || -n "$res" || -n "$body" || ( "$s" == "$stage" && -n "$notes$cutoff" ) ]] || continue
        any=1
        verdict="${verdicts[$s]:-}"
        content=""; [[ -n "$res_any" && -r "$res_any" ]] && content="$(<"$res_any")"
        if [[ -z "$verdict" && -n "$content" && "$content" =~ \"(outcome|verdict)\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then
            verdict="${BASH_REMATCH[2]}"
        fi
        own=""; [[ "$s" == "$stage" ]] && own=" — your own"
        # #2470: the stage's own section, between marks the blocks writer takes
        # out for a judging call — a judge never sees its stage's earlier output.
        [[ -n "$own" && -n "${_ZB_SP_MARK_OWN:-}" ]] && printf '%s' "$_ZB_SP_SECT_BEGIN"
        printf '\n### %s (verdict: %s)%s\n' "$s" "${verdict:-unknown}" "$own"
        [[ -n "$listed" ]] && printf 'Outputs:\n%s' "$listed"
        [[ -n "$body" ]] && printf '\nFindings:\n%s\n' "$body"
        # #2480: every member's summary, each as a stage's is.
        local _sf
        for _sf in ${summs[@]+"${summs[@]}"}; do
            [[ -s "$_sf" ]] || continue
            body="$(<"$_sf")"
            local full=${#body}
            body="${body:0:$_ZB_SP_SUMMARY_MAX_BYTES}"
            # The sanitizer forks twice; run it only on text it would change.
            if [[ "$body" == *$'\e'* || "$body" == *"══"* || "$body" == *"──"* || "$body" == *"<out-of-scope-context>"* ]] \
                    && declare -F _zbuild_sanitize_for_llm >/dev/null 2>&1; then
                body="$(printf '%s' "$body" | _zbuild_sanitize_for_llm 2>/dev/null || printf '%s' "$body")"
            fi
            printf '\nSummary:\n%s\n' "$body"
            (( full > _ZB_SP_SUMMARY_MAX_BYTES )) \
                && printf '[… cut at %sB — read %s for the rest]\n' "$_ZB_SP_SUMMARY_MAX_BYTES" "$_sf"
        done
        case "$verdict" in
            fail|failed|error|broken|partial|mismatch)
                if [[ -n "$errp" && -s "$errp" ]]; then
                    body="$(<"$errp")"
                    (( ${#body} > _ZB_SP_ERRORS_MAX_BYTES )) && body="${body: -$_ZB_SP_ERRORS_MAX_BYTES}"
                    printf '\nErrors it hit (last %sB of %s):\n%s\n' "$_ZB_SP_ERRORS_MAX_BYTES" "$errp" "$body"
                fi ;;
        esac
        # An attempt that ended in error produced no output: show the last
        # output this stage did produce, from the attempt that wrote it.
        if [[ -n "$res" ]] && _sp_no_output "$content"; then
            local good f
            good="$(_sp_last_good_attempt "$state_dir" "$s" "${res##*/}" "$req")"
            if [[ -n "$good" ]]; then
                printf '\nIts last good output, from an earlier attempt:\n'
                for f in "$good"/*; do
                    [[ -f "$f" && "${f##*/}" != attempt.json ]] && printf -- '- %s\n' "$f"
                done
                if [[ -n "$summ" && -s "$good/${summ##*/}" ]]; then
                    printf '\nSummary of that output:\n%s\n' "$(_sp_read "$good/${summ##*/}" "$_ZB_SP_SUMMARY_MAX_BYTES")"
                fi
            fi
        fi
        # #2458: the stage's own notes and cut-off list, between marks the
        # blocks writer takes out — kept for a building call, dropped for a
        # fresh one (a judging call, a stage with no tools).
        [[ -n "$own" && -n "${_ZB_SP_MARK_OWN:-}" ]] && printf '%s' "$_ZB_SP_OWN_BEGIN"
        if [[ -n "$own" && -n "$notes" ]]; then
            printf '\nYour notes so far:\n%s\n' "$(_sp_read "$notes" "$_ZB_SP_NOTES_MAX_BYTES")"
        fi
        if [[ -n "$own" && -n "$cutoff" ]]; then
            printf '\nYour last call was cut off at its time limit before it finished. What it did, step by step, up to the cut-off:\n%s\n' \
                "$(_sp_read "$cutoff" "$_ZB_SP_NOTES_MAX_BYTES")"
        fi
        [[ -n "$own" && -n "${_ZB_SP_MARK_OWN:-}" ]] && printf '%s' "$_ZB_SP_OWN_END"
        [[ -n "$own" && -n "${_ZB_SP_MARK_OWN:-}" ]] && printf '%s' "$_ZB_SP_SECT_END"
    done
    [[ "$any" -eq 1 ]] || printf '\nNo stage has run before this one.\n'
    return 0
}

# _sp_has_numbered <json> — rc 0 when it holds a numbered finding, the only kind
# _sp_findings_for shows: a result with none is not handed to jq (#2480,
# ADR-065 §5: a lens's own result lists its findings unnumbered).
_sp_has_numbered() {
    [[ "$1" == *'"findings"'* && "$1" =~ \"n\"[[:space:]]*:[[:space:]]*[0-9] ]]
}

# _sp_findings_for <result.json> <stage> <label> <output-topic> <takes> <allowed>
# — one line per finding the stage is shown: its own topic when its output's
# finding_topics (<allowed>, "a b" or "none") lists it, else its output's, must
# be among <takes> (" a b ", "" = everything).
_sp_findings_for() {
    jq -r --arg s "$2" --arg l "$3" --arg ot "$4" --arg tk "$5" --arg al " ${6:-} " \
        '(.data.findings // [])[]?
         | select(type == "object" and (.n|type) == "number")
         | ((if (.topic | type) == "string" then .topic else "" end) as $t
            | if ($t != "" and ($al | contains(" " + $t + " "))) then $t else $ot end) as $eff
         | select($tk == "" or ($tk | contains(" " + $eff + " ")))
         # #2470: a finding that shows a SPEC whole keeps its lines, each
         # indented under the first.
         # ADR-071 §5: one that does not block is still shown, and marked.
         | "- \($l) finding \(.n) (opened by \($s)\(if .blocking == false then ", does not block" else "" end)): \(.text|tostring|gsub("\r"; "")|gsub("\n+$"; "")|gsub("\n"; "\n    "))"' "$1" 2>/dev/null || true
}

# _sp_list_words " a b c " — "a, b and c".
_sp_list_words() {
    local -a w; read -ra w <<< "$1"
    local n=${#w[@]}
    (( n <= 1 )) && { printf '%s' "${w[*]}"; return 0; }
    local IFS=','; local head="${w[*]:0:n-1}"
    printf '%s and %s' "${head//,/, }" "${w[n-1]}"
}
