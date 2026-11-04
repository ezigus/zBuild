#!/usr/bin/env bash
# scripts/lib/judge.sh — how a judging call works (#2464, ADR-072).
#
# A judge reads the code itself, read-only, and the code from before the change
# is a copy it can open (§1 §2). Each complaint quotes the text it is about, and
# the quote is checked (§3). Its answers are kept while nothing it judged has
# changed, and judged again when a stage answers one of its findings with
# "nothing to do" (§4 §5).
#
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_JUDGE_LOADED:-}" ]] && return 0
_ZBUILD_JUDGE_LOADED=1
_ZB_JUDGE_DIR="${BASH_SOURCE[0]%/*}"

# ─── The code from before the change (§2) ───────────────────────────────────

# judge_base_dir_v <var> [repo_root] — the read-only copy of the base commit
# (the merge-base with the default branch), made the first time it is asked for
# and shared by the run: <state_dir>/base-code, outside the repository, on no
# branch. A new base commit gets a new copy. rc 1, <var> empty, when there is no
# run folder or no base commit.
judge_base_dir_v() {
    local -n _jbd="$1"
    local _judge__repo="${2:-${ZBUILD_REPO_ROOT:-$PWD}}" _judge__sd="${ZBUILD_STATE_DIR:-}" _judge__base="" _judge__dir
    _jbd=""
    [[ -n "$_judge__sd" ]] || return 1
    declare -F zbuild_resolve_merge_base >/dev/null 2>&1 \
        || source "$_ZB_JUDGE_DIR/merge-base.sh" 2>/dev/null || return 1
    _judge__base="$(zbuild_resolve_merge_base "$_judge__repo")"
    [[ -n "$_judge__base" ]] || return 1
    _judge__dir="${_judge__sd%/}/base-code"
    if [[ -d "$_judge__dir" && -f "$_judge__dir.sha" && "$(<"$_judge__dir.sha")" == "$_judge__base" ]]; then
        _jbd="$_judge__dir"; return 0
    fi
    judge_base_release "$_judge__sd" "$_judge__repo"
    mkdir -p "$_judge__sd" 2>/dev/null || return 1
    git -C "$_judge__repo" worktree add --detach "$_judge__dir" "$_judge__base" >/dev/null 2>&1 || return 1
    declare -F _zbuild_worktree_apply_sparse >/dev/null 2>&1 \
        && { _zbuild_worktree_apply_sparse "$_judge__dir" "$_judge__repo" >/dev/null 2>&1 || true; }
    # Read-only: nothing that runs in this run may change the code it is judged
    # against. Its folders stay writable, so whatever reclaims the run folder can
    # still delete it.
    find "$_judge__dir" -type f -exec chmod a-w {} + 2>/dev/null || true
    printf '%s' "$_judge__base" > "$_judge__dir.sha"
    _jbd="$_judge__dir"
}

# judge_base_release [state_dir] [repo_root] — remove the copy, and git's record
# of it. Teardown calls it on every exit path (ADR-054 §7).
judge_base_release() {
    local _judge__sd="${1:-${ZBUILD_STATE_DIR:-}}" _judge__repo="${2:-${ZBUILD_REPO_ROOT:-$PWD}}" _judge__dir
    [[ -n "$_judge__sd" ]] || return 0
    _judge__dir="${_judge__sd%/}/base-code"
    [[ -e "$_judge__dir.sha" ]] && rm -f "$_judge__dir.sha" 2>/dev/null
    [[ -e "$_judge__dir" ]] || return 0
    chmod -R u+w "$_judge__dir" 2>/dev/null || true
    git -C "$_judge__repo" worktree remove --force "$_judge__dir" >/dev/null 2>&1 \
        || { rm -rf -- "$_judge__dir" 2>/dev/null; git -C "$_judge__repo" worktree prune >/dev/null 2>&1; }
    return 0
}

# ─── Quotes (§3) ─────────────────────────────────────────────────────────────

# _judge_words_v <var> <text> — the text with every run of spacing one space.
_judge_words_v() {
    local -n _jwo="$1"; local -a _jww=()
    read -r -d '' -a _jww <<< "$2" || true
    _jwo="${_jww[*]}"
}

# _judge_holds <text> <quote> — rc 0 when <text> holds <quote>, spacing aside.
_judge_holds() {
    local _jh_t _jh_q
    _judge_words_v _jh_t "$1"; _judge_words_v _jh_q "$2"
    [[ -n "$_jh_q" && " $_jh_t " == *"$_jh_q"* ]]
}

# judge_quote_check_v <why_var> <quote> <own_words> <repo> [base_dir] — rc 0
# when <quote> is really there: `"text"` in the item's own words, or
# `file:"text"` in that file in the repository or in the code from before the
# change. Otherwise rc 1 and <why_var> says what is wrong, to follow "<id>'s
# quote " in a re-ask.
judge_quote_check_v() {
    local -n _jqw="$1"
    local _judge__q="$2" _judge__own="$3" _judge__repo="${4:+${4%/}}" _judge__base="${5:+${5%/}}" _judge__path _judge__txt _judge__f _judge__seen=0
    _jqw=""
    _judge__q="${_judge__q#"${_judge__q%%[![:space:]]*}"}"; _judge__q="${_judge__q%"${_judge__q##*[![:space:]]}"}"
    if [[ "$_judge__q" =~ ^\"(.*)\"$ ]]; then
        _judge__txt="${BASH_REMATCH[1]}"
        _judge_holds "$_judge__own" "$_judge__txt" && return 0
        _jqw="is not in the item's _judge__own words: \"$_judge__txt\""
        return 1
    fi
    if [[ ! "$_judge__q" =~ ^([^\"]+):\"(.*)\"$ ]]; then
        _jqw="is not a quote: write \"<the exact words>\" or <file>:\"<its exact text>\""
        return 1
    fi
    _judge__path="${BASH_REMATCH[1]}"; _judge__txt="${BASH_REMATCH[2]}"
    case "$_judge__path" in
        "$_judge__repo"/*) _judge__path="${_judge__path#"$_judge__repo"/}" ;;
        "${_judge__base:-/nonexistent}"/*) _judge__path="${_judge__path#"$_judge__base"/}" ;;
        /*) _jqw="names $_judge__path, which is not a file of the repository"; return 1 ;;
    esac
    if [[ "/$_judge__path/" == *"/../"* ]]; then
        _jqw="names $_judge__path, which is not a file of the repository"; return 1
    fi
    for _judge__f in "$_judge__repo/$_judge__path" ${_judge__base:+"$_judge__base/$_judge__path"}; do
        [[ -f "$_judge__f" ]] || continue
        _judge__seen=1
        _judge_holds "$(<"$_judge__f")" "$_judge__txt" && return 0
    done
    if (( _judge__seen )); then
        _jqw="is not in $_judge__path: \"$_judge__txt\""
    else
        _jqw="names $_judge__path, which is not a file of the repository"
    fi
    return 1
}

# judge_quote_path_v <var> <quote> <repo> [base] — the repository path a
# `file:"text"` quote names, for the files a kept answer depends on; empty for
# a quote of the item's own words.
judge_quote_path_v() {
    local -n _jqp="$1"; local _judge__repo="${3:+${3%/}}" _judge__base="${4:+${4%/}}"
    _jqp=""
    [[ "$2" =~ ^[[:space:]]*([^\"[:space:]][^\"]*):\" ]] || return 0
    _jqp="${BASH_REMATCH[1]}"
    _jqp="${_jqp#"$_judge__repo"/}"; [[ -n "$_judge__base" ]] && _jqp="${_jqp#"$_judge__base"/}"
    return 0
}

# ─── Answers to a check's findings (§5, ADR-068 §6) ──────────────────────────

# zb_answers_collect_v <array_var> <reply> — the reply's `ANSWER <stage>
# finding <n>: …` lines, without the word ANSWER, added to the array; a finding
# answered twice keeps its latest answer.
zb_answers_collect_v() {
    local -n _zac="$1"
    local _zb_ans_line _zb_ans_a _zb_ans_k _zb_ans_i _joined _zb_ans_re='^[[:space:]>*`_-]*ANSWER[[:space:]]+(.+[[:space:]]finding[[:space:]]+[0-9]+[[:space:]]*:.*)$'
    declare -F zb_reply_join_v >/dev/null 2>&1 || source "$_ZB_JUDGE_DIR/reply-units.sh" 2>/dev/null || true
    zb_reply_join_v _joined "${2:-}"
    while IFS= read -r _zb_ans_line; do
        [[ "$_zb_ans_line" =~ $_zb_ans_re ]] || continue
        _zb_ans_a="${BASH_REMATCH[1]}"
        while [[ "$_zb_ans_a" == *[[:space:]] ]]; do _zb_ans_a="${_zb_ans_a%[[:space:]]}"; done
        _zb_ans_k="${_zb_ans_a%%:*}"
        for _zb_ans_i in "${!_zac[@]}"; do
            [[ "${_zac[_zb_ans_i]%%:*}" == "$_zb_ans_k" ]] && unset '_zac[_zb_ans_i]'
        done
        _zac=(${_zac[@]+"${_zac[@]}"})
        _zac+=("$_zb_ans_a")
    done <<< "$_joined"
    return 0
}

# judge_answers_to <artifact_dir> <label>... — every "nothing to do" answer a
# stage keeps in its result (data.answers) to a finding labelled <label>, one
# per line. A "done" answer changed something, so what is judged changed too.
judge_answers_to() { local _jat=""; judge_answers_to_v _jat "$@"; [[ -n "$_jat" ]] && printf '%s\n' "$_jat"; return 0; }
# judge_answers_to_v <var> <artifact_dir> <label>... — the same into <var>.
judge_answers_to_v() {
    local -n _jatv="$1"; shift
    _jatv=""
    local dir="${1:+${1%/}}"; shift
    [[ -d "$dir" && $# -gt 0 ]] || return 0
    local re="" l
    for l in "$@"; do re+="${re:+|}${l//[^A-Za-z0-9_-]/.}"; done
    local -a files=()
    local f _jat_body
    for f in "$dir"/*.json; do
        [[ -f "$f" ]] || continue
        # read, not $(<): no process for a file with no answers (ADR-065 §5).
        _jat_body=""; IFS= read -r -d '' _jat_body < "$f" || true
        [[ "$_jat_body" == *'"answers"'* ]] && files+=("$f")
    done
    [[ ${#files[@]} -gt 0 ]] || return 0
    _jatv="$(jq -r --arg re "^($re) finding [0-9]+[[:space:]]*:[[:space:]]*nothing to do" \
        '(.data.answers // [])[]? | strings | select(test($re))' "${files[@]}" 2>/dev/null)" || true
}

# ─── Kept answers (§4) ───────────────────────────────────────────────────────

# judge_engine_v <var> — the engine a verdict was given under: an answer from
# another engine is not kept.
judge_engine_v() {
    local -n _jev="$1"
    _jev="${_RUNNER_ENGINE_SHA:-}"
    [[ -n "$_jev" ]] && return 0
    # Read by the shell, not jq: a stage in its own process has the state file.
    local _jev_s=""
    [[ -n "${ZBUILD_STATE_DIR:-}" && -f "$ZBUILD_STATE_DIR/pipeline-state.json" ]] \
        && { IFS= read -r -d '' _jev_s < "$ZBUILD_STATE_DIR/pipeline-state.json" || true; }
    [[ "$_jev_s" =~ \"engine_sha\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]] && _jev="${BASH_REMATCH[1]}"
    : "${_jev:=unknown}"
    _RUNNER_ENGINE_SHA="$_jev"
}

# judge_fp_v <var> <text> — the fingerprint of what a judge was shown: its
# checksum and its length in bytes (cksum), which two different texts share by
# chance about once in four billion.
judge_fp_v() {
    local -n _jfp="$1"
    # Through a file, not $( ): one program, no copy of the shell (ADR-065 §5).
    local _jfp_f="${ZBUILD_STAGE_SCRATCH:-${TMPDIR:-/tmp}}/zb-judge-fp.$BASHPID" _jfp_c="" _jfp_n=""
    _jfp=""
    cksum <<< "$2" > "$_jfp_f" 2>/dev/null && read -r _jfp_c _jfp_n < "$_jfp_f"
    rm -f "$_jfp_f" 2>/dev/null
    [[ -n "$_jfp_c" ]] && _jfp="$_jfp_c-$_jfp_n"
    return 0
}

# _judge_hashes_v <assoc_var> <path>... — each path's content hash, `absent`
# for a missing one, in one git call. A directory (a judge searched it) is the
# commit's tree of it, so a commit that changes a file in it changes its hash;
# one outside any repository can never be known unchanged (review on #2465).
_judge_hashes_v() {
    local -n _jhs="$1"; shift
    local -a __judge_have=() __judge_hs=()
    local __judge_p __judge_i
    local __judge_t
    for __judge_p in "$@"; do
        [[ -n "$__judge_p" ]] || continue
        if [[ -f "$__judge_p" ]]; then __judge_have+=("$__judge_p")
        elif [[ -d "$__judge_p" ]]; then
            __judge_t="$(git -C "$__judge_p" rev-parse HEAD:./ 2>/dev/null)" || __judge_t=""
            _jhs["$__judge_p"]="tree:${__judge_t:-unknown-$RANDOM$RANDOM}"
        else _jhs["$__judge_p"]=absent; fi
    done
    [[ ${#__judge_have[@]} -gt 0 ]] || return 0
    mapfile -t __judge_hs < <(git hash-object -- "${__judge_have[@]}" 2>/dev/null)
    for __judge_i in "${!__judge_have[@]}"; do _jhs["${__judge_have[__judge_i]}"]="${__judge_hs[__judge_i]:-absent}"; done
}

# judge_kept_get_v <var> <kept_file> <key> <fp> — the payload kept for <key>
# when it was kept for fingerprint <fp> and every file it depended on is
# unchanged; empty otherwise.
judge_kept_get_v() {
    local -n _jkg="$1"; local _judge__kf="$2" _judge__key="$3" _judge__fp="$4" _judge__rec
    _jkg=""
    [[ -n "$_judge__fp" && -s "$_judge__kf" ]] || return 0
    _judge__rec="$(jq -r --arg k "$_judge__key" --arg fp "$_judge__fp" \
        '.[$k] // empty | select(.fp == $fp) | ((.files // {} | to_entries[] | "F\t\(.key)\t\(.value)"), "P\t\(.payload | @json)")' \
        "$_judge__kf" 2>/dev/null)" || return 0
    [[ -n "$_judge__rec" ]] || return 0
    local _judge__kind _judge__a _judge__b _judge__payload=""
    local -a _judge__paths=() _judge__want=()
    while IFS=$'\t' read -r _judge__kind _judge__a _judge__b; do
        case "$_judge__kind" in
            F) _judge__paths+=("$_judge__a"); _judge__want+=("$_judge__b") ;;
            P) _judge__payload="$_judge__a" ;;
        esac
    done <<< "$_judge__rec"
    local -A _judge__now=()
    _judge_hashes_v _judge__now ${_judge__paths[@]+"${_judge__paths[@]}"}
    local _judge__i
    for _judge__i in "${!_judge__paths[@]}"; do
        [[ "${_judge__now[${_judge__paths[_judge__i]}]:-absent}" == "${_judge__want[_judge__i]}" ]] || return 0
    done
    _jkg="$(jq -r '.' <<< "$_judge__payload" 2>/dev/null)" || _jkg=""
}

# judge_kept_put <kept_file> <key> <fp> <payload> [file]... — keep <payload> for
# <key> under fingerprint <fp>, with the hash of each file it depends on.
judge_kept_put() {
    local _judge__kf="$1" _judge__key="$2" _judge__fp="$3" _judge__payload="$4"; shift 4
    [[ -n "$_judge__kf" && -n "$_judge__fp" ]] || return 0
    local -A _judge__hs=()
    _judge_hashes_v _judge__hs "$@"
    local _judge__p _judge__pairs=""
    for _judge__p in "${!_judge__hs[@]}"; do _judge__pairs+="$_judge__p"$'\t'"${_judge__hs[$_judge__p]}"$'\n'; done
    local _judge__cur="{}"
    [[ -s "$_judge__kf" ]] && _judge__cur="$(<"$_judge__kf")"
    [[ -d "${_judge__kf%/*}" ]] || mkdir -p "${_judge__kf%/*}" 2>/dev/null || true
    jq -c --arg k "$_judge__key" --arg fp "$_judge__fp" --arg p "$_judge__payload" --arg pairs "$_judge__pairs" \
        '(if type == "object" then . else {} end)
         + {($k): {fp: $fp, payload: $p,
                   files: ([$pairs | split("\n")[] | select(length > 0) | split("\t") | {(.[0]): .[1]}] | add // {})}}' \
        <<< "$_judge__cur" > "$_judge__kf" 2>/dev/null
    # The old content was read first; a write cut short only costs a fresh judgement.
    return 0
}

# _judge_json_str_v <var> <text> — <text> as a JSON string, by the shell.
_judge_json_str_v() {
    local -n _jjs="$1"; local LC_ALL=C _jjs_s="$2"
    _jjs_s="${_jjs_s//\\/\\\\}"; _jjs_s="${_jjs_s//\"/\\\"}"
    _jjs_s="${_jjs_s//$'\n'/\\n}"; _jjs_s="${_jjs_s//$'\r'/\\r}"; _jjs_s="${_jjs_s//$'\t'/\\t}"
    _jjs_s="${_jjs_s//[$'\001'-$'\010'$'\013'$'\014'$'\016'-$'\037']/ }"
    _jjs="\"$_jjs_s\""
}

# judge_kept_put_one <kept_file> <key> <fp> <payload> [file]... — the same as
# judge_kept_put for a check that keeps one answer: the file holds only it, and
# the shell writes it (ADR-065 §5: no program on every judging call).
judge_kept_put_one() {
    local _jpo_kf="$1" _jpo_key="$2" _jpo_fp="$3" _jpo_p="$4"; shift 4
    [[ -n "$_jpo_kf" && -n "$_jpo_fp" ]] || return 0
    local -A _jpo_hs=()
    _judge_hashes_v _jpo_hs "$@"
    local _jpo_k _jpo_v _jpo_files="" _jpo_j
    for _jpo_k in "${!_jpo_hs[@]}"; do
        _judge_json_str_v _jpo_j "$_jpo_k"; _jpo_files+="${_jpo_files:+,}$_jpo_j:\"${_jpo_hs[$_jpo_k]}\""
    done
    _judge_json_str_v _jpo_k "$_jpo_key"; _judge_json_str_v _jpo_v "$_jpo_p"; _judge_json_str_v _jpo_j "$_jpo_fp"
    [[ -d "${_jpo_kf%/*}" ]] || mkdir -p "${_jpo_kf%/*}" 2>/dev/null || true
    printf '{%s:{"fp":%s,"payload":%s,"files":{%s}}}\n' "$_jpo_k" "$_jpo_j" "$_jpo_v" "$_jpo_files" > "$_jpo_kf" 2>/dev/null
    return 0
}

# judge_opened_v <array_var> <opened_file> <repo> — the files a judging call
# opened (the router lists them, ZBUILD_ROUTER_OPENED_FILE), each once.
judge_opened_v() {
    local -n _jop="$1"; local _judge__f="$2" _judge__l _judge__s
    [[ -s "$_judge__f" ]] || return 0
    while IFS= read -r _judge__l; do
        [[ -n "$_judge__l" ]] || continue
        for _judge__s in ${_jop[@]+"${_jop[@]}"}; do [[ "$_judge__s" == "$_judge__l" ]] && continue 2; done
        _jop+=("$_judge__l")
    done < "$_judge__f"
}

# judge_disputes_block <answers> — what a judge is shown when a stage answers
# one of its findings with "nothing to do".
judge_disputes_block() {
    [[ -n "${1//[[:space:]]/}" ]] || return 0
    printf '\nANSWERS TO YOUR EARLIER FINDINGS — a stage that had to act on these says each is wrong, and why. Judge each again with its answer in mind: keep a finding only when you can quote what shows it still holds.\n'
    local l
    while IFS= read -r l; do [[ -n "$l" ]] && printf -- '- %s\n' "$l"; done <<< "$1"
}
