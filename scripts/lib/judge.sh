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

# _judge_emit <type> [k=v]... — an event, when the event bus is loaded (#2466).
_judge_emit() { declare -F eb_emit_event >/dev/null 2>&1 && eb_emit_event "$@" 2>/dev/null; return 0; }

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
    [[ -n "$_judge__sd" ]] || { _judge_emit judge.base.failed "reason=no_state_dir"; return 1; }
    declare -F zbuild_resolve_merge_base >/dev/null 2>&1 \
        || source "$_ZB_JUDGE_DIR/merge-base.sh" 2>/dev/null || return 1
    _judge__base="$(zbuild_resolve_merge_base "$_judge__repo")"
    [[ -n "$_judge__base" ]] || { _judge_emit judge.base.failed "reason=no_base_commit"; return 1; }
    _judge__dir="${_judge__sd%/}/base-code"
    if [[ -d "$_judge__dir" && -f "$_judge__dir.sha" && "$(<"$_judge__dir.sha")" == "$_judge__base" ]]; then
        _jbd="$_judge__dir"; return 0
    fi
    judge_base_release "$_judge__sd" "$_judge__repo" new_base
    mkdir -p "$_judge__sd" 2>/dev/null || return 1
    git -C "$_judge__repo" worktree add --detach "$_judge__dir" "$_judge__base" >/dev/null 2>&1 \
        || { _judge_emit judge.base.failed "reason=worktree_add_failed"; return 1; }
    declare -F _zbuild_worktree_apply_sparse >/dev/null 2>&1 \
        && { _zbuild_worktree_apply_sparse "$_judge__dir" "$_judge__repo" >/dev/null 2>&1 || true; }
    # Read-only: nothing that runs in this run may change the code it is judged
    # against. Its folders stay writable, so whatever reclaims the run folder can
    # still delete it.
    find "$_judge__dir" -type f -exec chmod a-w {} + 2>/dev/null || true
    printf '%s' "$_judge__base" > "$_judge__dir.sha"
    _judge_emit judge.base.created "base=$_judge__base" "path=$_judge__dir"
    _jbd="$_judge__dir"
}

# judge_base_release [state_dir] [repo_root] [by] — remove the copy, and git's
# record of it. Teardown calls it on every exit path (ADR-054 §7); <by> says
# who, in the judge.base.released event (#2466).
judge_base_release() {
    local _judge__sd="${1:-${ZBUILD_STATE_DIR:-}}" _judge__repo="${2:-${ZBUILD_REPO_ROOT:-$PWD}}" _judge__dir _judge__by="${3:-teardown}"
    [[ -n "$_judge__sd" ]] || return 0
    _judge__dir="${_judge__sd%/}/base-code"
    [[ -e "$_judge__dir.sha" ]] && rm -f "$_judge__dir.sha" 2>/dev/null
    [[ -e "$_judge__dir" ]] || return 0
    chmod -R u+w "$_judge__dir" 2>/dev/null || true
    git -C "$_judge__repo" worktree remove --force "$_judge__dir" >/dev/null 2>&1 \
        || { rm -rf -- "$_judge__dir" 2>/dev/null; git -C "$_judge__repo" worktree prune >/dev/null 2>&1; }
    _judge_emit judge.base.released "path=$_judge__dir" "by=$_judge__by"
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
    local -n _jfp="$1"; local _jfp_c="" _jfp_n=""
    _jfp=""
    # A process substitution, not a temp file: one program, and nothing to remove
    # (review on #2465; ADR-065 §5 counts the rm a temp file needs).
    read -r _jfp_c _jfp_n < <(cksum <<< "$2" 2>/dev/null)
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

# _judge_check_name_v <var> <kept_file> — the check a kept file belongs to, as
# its events name it: design, test-author, issue-acceptance, lens-<id>.
_judge_check_name_v() { local -n _jcn="$1"; _jcn="${2##*/}"; _jcn="${_jcn%-judged.json}"; }

# judge_kept_get_v <var> <kept_file> <key> <fp> [disputed] — the payload kept
# for <key> when it was kept for fingerprint <fp> and every file it depended on
# is unchanged; empty otherwise. #2466: emits judge.kept.used when it is, and
# judge.kept.stale (why=fingerprint, disputed when [disputed] is 1, or file)
# when a kept answer exists but cannot be used.
judge_kept_get_v() {
    local -n _jkg="$1"; local _judge__kf="$2" _judge__key="$3" _judge__fp="$4" _judge__rec _judge__chk
    _jkg=""
    [[ -n "$_judge__fp" && -s "$_judge__kf" ]] || return 0
    _judge_check_name_v _judge__chk "$_judge__kf"
    _judge__rec="$(jq -r --arg k "$_judge__key" --arg fp "$_judge__fp" \
        '.[$k] // empty | ("X\t\(.fp)"), (select(.fp == $fp) | ((.files // {} | to_entries[] | "F\t\(.key)\t\(.value)"), "P\t\(.payload | @json)"))' \
        "$_judge__kf" 2>/dev/null)" || return 0
    [[ -n "$_judge__rec" ]] || return 0
    if [[ "$_judge__rec" != *$'\nP\t'* ]]; then
        local _judge__why=fingerprint; [[ "${5:-0}" == 1 ]] && _judge__why=disputed
        _judge_emit judge.kept.stale "check=$_judge__chk" "item=$_judge__key" "why=$_judge__why"
        return 0
    fi
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
        [[ "${_judge__now[${_judge__paths[_judge__i]}]:-absent}" == "${_judge__want[_judge__i]}" ]] && continue
        _judge_emit judge.kept.stale "check=$_judge__chk" "item=$_judge__key" "why=file"
        return 0
    done
    _jkg="$(jq -r '.' <<< "$_judge__payload" 2>/dev/null)" || _jkg=""
    [[ -n "$_jkg" ]] && _judge_emit judge.kept.used "check=$_judge__chk" "item=$_judge__key"
    return 0
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
    local _judge__chk; _judge_check_name_v _judge__chk "$_judge__kf"
    _judge_emit judge.kept.saved "check=$_judge__chk" "item=$_judge__key"
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
    _judge_check_name_v _jpo_j "$_jpo_kf"
    _judge_emit judge.kept.saved "check=$_jpo_j" "item=$_jpo_key"
    return 0
}

# judge_kept_get_all_v <out_assoc> <kept_file> <fps_assoc> [disputed_assoc] —
# every key of <fps_assoc> whose kept answer still holds, its payload into
# <out_assoc>: one read of the file, one hash of the files the answers depend
# on (#2470, ADR-072 §4 — a check that keeps an answer per SPEC). Emits
# judge.kept.used for each one used and judge.kept.stale for each one kept but
# not usable, why=fingerprint, disputed (when <disputed_assoc>[key] is set) or
# file.
judge_kept_get_all_v() {
    local -n _jga="$1" _jga_fp="$3"; local _jga_kf="$2" _jga_dn="${4:-_jga_nod}" _jga_chk
    local -A _jga_nod=()
    local -n _jga_d="$_jga_dn"
    _jga=()
    [[ -n "$_jga_kf" && -s "$_jga_kf" ]] || return 0
    _judge_check_name_v _jga_chk "$_jga_kf"
    local -A _jga_rfp=() _jga_rp=() _jga_rf=()
    local _jga_t _jga_k _jga_a _jga_b
    while IFS=$'\t' read -r _jga_t _jga_k _jga_a _jga_b; do
        case "$_jga_t" in
            X) _jga_rfp["$_jga_k"]="$_jga_a" ;;
            F) _jga_rf["$_jga_k"]+="$_jga_a"$'\t'"$_jga_b"$'\n' ;;
            P) _jga_rp["$_jga_k"]="$_jga_a" ;;
        esac
    done < <(jq -r 'to_entries[] | .key as $k | .value
        | ("X\t\($k)\t\(.fp)"),
          (.files // {} | to_entries[] | "F\t\($k)\t\(.key)\t\(.value)"),
          ("P\t\($k)\t\(.payload | tostring | gsub("\n"; "\u001e") | gsub("\t"; "\u001f"))")' "$_jga_kf" 2>/dev/null)
    local -a _jga_paths=()
    local _jga_l
    for _jga_k in "${!_jga_fp[@]}"; do
        [[ "${_jga_rfp[$_jga_k]:-}" == "${_jga_fp[$_jga_k]}" ]] || continue
        while IFS=$'\t' read -r _jga_a _jga_b; do [[ -n "$_jga_a" ]] && _jga_paths+=("$_jga_a"); done <<< "${_jga_rf[$_jga_k]:-}"
    done
    local -A _jga_now=()
    _judge_hashes_v _jga_now ${_jga_paths[@]+"${_jga_paths[@]}"}
    local _jga_ok _jga_why
    for _jga_k in "${!_jga_fp[@]}"; do
        [[ -n "${_jga_rfp[$_jga_k]+x}" ]] || continue
        if [[ "${_jga_rfp[$_jga_k]}" != "${_jga_fp[$_jga_k]}" ]]; then
            _jga_why=fingerprint
            [[ -n "${_jga_d[$_jga_k]:-}" ]] && _jga_why=disputed
            _judge_emit judge.kept.stale "check=$_jga_chk" "item=$_jga_k" "why=$_jga_why"
            continue
        fi
        _jga_ok=1
        while IFS=$'\t' read -r _jga_a _jga_b; do
            [[ -n "$_jga_a" ]] || continue
            [[ "${_jga_now[$_jga_a]:-absent}" == "$_jga_b" ]] || { _jga_ok=0; break; }
        done <<< "${_jga_rf[$_jga_k]:-}"
        if (( ! _jga_ok )); then
            _judge_emit judge.kept.stale "check=$_jga_chk" "item=$_jga_k" "why=file"
            continue
        fi
        _jga_l="${_jga_rp[$_jga_k]:-}"; _jga_l="${_jga_l//$'\x1e'/$'\n'}"; _jga_l="${_jga_l//$'\x1f'/$'\t'}"
        _jga["$_jga_k"]="$_jga_l"
        _judge_emit judge.kept.used "check=$_jga_chk" "item=$_jga_k"
    done
    return 0
}

# judge_kept_put_all <kept_file> <payload_assoc> <fp_assoc> <deps_assoc> — keep
# every key of <payload_assoc> under its fingerprint, with the hash of each file
# its <deps_assoc> entry names (one per line): one hash of all the files, one
# write (#2470). The file's other answers stay as they are.
judge_kept_put_all() {
    local _jpa_kf="$1"; local -n _jpa_p="$2" _jpa_fp="$3" _jpa_d="$4"
    [[ -n "$_jpa_kf" && ${#_jpa_p[@]} -gt 0 ]] || return 0
    local -a _jpa_all=(); local _jpa_k _jpa_f
    for _jpa_k in "${!_jpa_p[@]}"; do
        while IFS= read -r _jpa_f; do [[ -n "$_jpa_f" ]] && _jpa_all+=("$_jpa_f"); done <<< "${_jpa_d[$_jpa_k]:-}"
    done
    local -A _jpa_hs=()
    _judge_hashes_v _jpa_hs ${_jpa_all[@]+"${_jpa_all[@]}"}
    local _jpa_new="" _jpa_files _jpa_j _jpa_v _jpa_x _jpa_chk
    local -A _jpa_seen=()
    for _jpa_k in "${!_jpa_p[@]}"; do
        _jpa_files=""; _jpa_seen=()
        while IFS= read -r _jpa_f; do
            [[ -n "$_jpa_f" && -z "${_jpa_seen[$_jpa_f]+x}" ]] || continue
            _jpa_seen["$_jpa_f"]=1
            _judge_json_str_v _jpa_j "$_jpa_f"; _jpa_files+="${_jpa_files:+,}$_jpa_j:\"${_jpa_hs[$_jpa_f]:-absent}\""
        done <<< "${_jpa_d[$_jpa_k]:-}"
        _judge_json_str_v _jpa_j "$_jpa_k"; _judge_json_str_v _jpa_v "${_jpa_p[$_jpa_k]}"; _judge_json_str_v _jpa_x "${_jpa_fp[$_jpa_k]:-}"
        _jpa_new+="${_jpa_new:+,}$_jpa_j:{\"fp\":$_jpa_x,\"payload\":$_jpa_v,\"files\":{$_jpa_files}}"
    done
    [[ -d "${_jpa_kf%/*}" ]] || mkdir -p "${_jpa_kf%/*}" 2>/dev/null || true
    if [[ -s "$_jpa_kf" ]]; then
        local _jpa_cur; IFS= read -r -d '' _jpa_cur < "$_jpa_kf" || true
        jq -c --argjson n "{$_jpa_new}" '(if type == "object" then . else {} end) + $n' <<< "$_jpa_cur" > "$_jpa_kf" 2>/dev/null
    else
        printf '{%s}\n' "$_jpa_new" > "$_jpa_kf" 2>/dev/null
    fi
    _judge_check_name_v _jpa_chk "$_jpa_kf"
    for _jpa_k in "${!_jpa_p[@]}"; do _judge_emit judge.kept.saved "check=$_jpa_chk" "item=$_jpa_k"; done
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
