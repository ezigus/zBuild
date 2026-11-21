#!/usr/bin/env bash
# scripts/lib/judge-handoff.sh — a part a stage hands to another stage waits
# for it (#2574, ADR-072 §5). Sourced by judge-held.sh; every check uses it.
#
# When a stage answers a check's finding `not mine`, and an output of that
# stage on a findings topic carries the finding, the part the finding is about
# is not judged again until a stage of this run that takes that topic has run:
# on #1764 run 44782866204 build's tries 2 and 3 were asked about a step it had
# handed to test-author, and refused again, while test-author had not run.
#   - Only a stage of this run is a receiver (the run's stage list); with none,
#     nothing waits.
#   - A part waits at most _JUDGE_HANDOFF_MAX times; then it is judged. A part
#     judged when it came back is not handed on again by the reply judged with
#     it: a new judgement comes between two hand-offs.
#   - On the loop's last round nothing waits: the part is judged.
# The hand-off is the check's own record beside its kept answers
# (<kept file>-handed-<item>, and -handoffs-<item> for the count); whether the
# receiver has run since is read from the engine's records of when each stage
# last started (runtime/dispatched/<stage>), compared by the shell (-nt).
#
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_JUDGE_HANDOFF_LOADED:-}" ]] && return 0
_ZBUILD_JUDGE_HANDOFF_LOADED=1

_JUDGE_HANDOFF_MAX=2

# _judge_run_stages_v <array> — the stages of this run, in order: the resolved
# template flow (_TPL_STAGES, or ZBUILD_INPUTS_FLOW in a stage's own process).
_judge_run_stages_v() {
    local -n _jrs="$1"; _jrs=()
    if declare -p _TPL_STAGES >/dev/null 2>&1 && [[ ${#_TPL_STAGES[@]} -gt 0 ]]; then _jrs=("${_TPL_STAGES[@]}")
    else read -r -a _jrs <<< "${ZBUILD_INPUTS_FLOW:-}"; fi
    return 0
}

# _judge_stage_manifest_v <var> <stage> <plugins_root> — a stage's manifest: as
# the engine binds it (_inputs_stage_manifest_v) when loaded, else the plugin
# of that id.
_judge_stage_manifest_v() {
    local -n _jsm="$1"; local _jsm_f; _jsm=""
    if declare -F _inputs_stage_manifest_v >/dev/null 2>&1 && _inputs_stage_manifest_v _jsm "$2" "$3" 2>/dev/null && [[ -n "$_jsm" ]]; then return 0; fi
    for _jsm_f in "$3"/*/"$2"/manifest.yaml; do [[ -f "$_jsm_f" ]] && { _jsm="$_jsm_f"; return 0; }; done
    return 0
}

# _judge_manifest_takes_v <var> <manifest> — " <topic> … " a manifest takes.
_judge_manifest_takes_v() {
    local -n _jmt="$1"; local l in=0; _jmt=" "
    [[ -f "$2" ]] || return 0
    while IFS= read -r l || [[ -n "$l" ]]; do
        if [[ "$l" =~ ^takes:[[:space:]]*$ ]]; then in=1; continue; fi
        (( in )) || continue
        [[ "$l" =~ ^[a-zA-Z_] ]] && break
        [[ "$l" =~ ^[[:space:]]*-[[:space:]]+topic:[[:space:]]*([^[:space:]#]+) ]] && _jmt+="${BASH_REMATCH[1]} "
    done < "$2"
    return 0
}

# _judge_manifest_outputs_v <array> <manifest> <artifact_dir> — each output on a
# findings topic, "<topic><TAB><resolved path>".
_judge_manifest_outputs_v() {
    local -n _jmo="$1"; local mf="$2" ad="${3%/}" l in=0 topic="" path=""
    _jmo=()
    [[ -s "$mf" ]] || return 0
    _jmo_take() {
        path="${path//\"/}"; path="${path//\'/}"; path="${path//\$\{artifact_dir\}/$ad}"
        [[ "$topic" == *-findings && "$path" == *.json ]] && _jmo+=("$topic"$'\t'"$path")
        topic="" path=""
    }
    while IFS= read -r l || [[ -n "$l" ]]; do
        if [[ "$l" =~ ^outputs:[[:space:]]*$ ]]; then in=1; continue; fi
        (( in )) || continue
        if [[ "$l" =~ ^[A-Za-z_] ]]; then _jmo_take; in=0; break; fi
        [[ "$l" =~ ^[[:space:]]*-[[:space:]] ]] && _jmo_take
        [[ "$l" =~ (^|[[:space:]-])topic:[[:space:]]*([^[:space:]#]+) ]] && topic="${BASH_REMATCH[2]}"
        [[ "$l" =~ (^|[[:space:]-])path:[[:space:]]*([^[:space:]#]+) ]] && path="${BASH_REMATCH[2]}"
    done < "$mf"
    (( in )) && _jmo_take
    unset -f _jmo_take
    return 0
}

# judge_handoff_receivers_v <var> <manifest> <artifact_dir> <key> — the stages
# of this run the finding <key> (an id, or `<label> finding <n>`) is handed to:
# those that take the topic of an output of the answering stage (its
# <manifest>) that carries <key>. Space separated; empty when none.
judge_handoff_receivers_v() {
    local -n _jhr="$1"; local mf="$2" ad="${3%/}" key="$4" o body s m tk t root
    local -a outs=() topics=() stages=()
    _jhr=""
    [[ -s "$mf" && -n "$key" && -n "$ad" ]] || return 0
    local kre="(^|[^A-Za-z0-9_-])${key//[^A-Za-z0-9 _-]/.}([^0-9]|$)"
    _judge_manifest_outputs_v outs "$mf" "$ad"
    for o in ${outs[@]+"${outs[@]}"}; do
        [[ -s "${o#*$'\t'}" ]] || continue
        body=""; IFS= read -r -d '' body < "${o#*$'\t'}" || true
        [[ "$body" =~ $kre ]] && topics+=("${o%%$'\t'*}")
    done
    [[ ${#topics[@]} -gt 0 ]] || return 0
    _judge_run_stages_v stages
    root="${mf%/manifest.yaml}"; root="${root%/*}"; root="${root%/*}"
    for s in ${stages[@]+"${stages[@]}"}; do
        _judge_stage_manifest_v m "$s" "$root"
        [[ -n "$m" && "$m" -ef "$mf" ]] && continue
        _judge_manifest_takes_v tk "$m"
        for t in "${topics[@]}"; do [[ "$tk" == *" $t "* ]] && { _jhr+="${_jhr:+ }$s"; break; }; done
    done
    return 0
}

# judge_output_manifest_v <var> <result_file> — the manifest of the stage of
# this run that writes <result_file> (an output of its, by file name).
judge_output_manifest_v() {
    local -n _jom="$1"; local s m root="${ZBUILD_PLUGINS_ROOT:-${_ZB_JUDGE_DIR:-${BASH_SOURCE[0]%/*}}/../../plugins}" o
    local -a stages=() outs=()
    _jom=""
    _judge_run_stages_v stages
    local l b="/${1##*/}"
    for s in ${stages[@]+"${stages[@]}"}; do
        _judge_stage_manifest_v m "$s" "$root"
        [[ -f "$m" ]] || continue
        while IFS= read -r l || [[ -n "$l" ]]; do
            [[ "$l" =~ (^|[[:space:]-])path:[[:space:]]*[\"\']?([^\"\'[:space:]#]+) && "${BASH_REMATCH[2]}" == *"$b" ]] && { _jom="$m"; return 0; }
        done < "$m"
    done
    return 0
}

# _judge_handoff_paths <marker_var> <count_var> <kept_file> <item>
_judge_handoff_paths() {
    local -n _jhp="$1" _jhc="$2"; local k="${4//[^A-Za-z0-9._-]/_}"
    _jhp="${3%.json}-handed-$k"; _jhc="${3%.json}-handoffs-$k"
}

# judge_handoff_put <kept_file> <item> <receivers> <answer> [finding] — record
# that the part <item> was handed to <receivers> now, with the answer and the
# finding it answered; rc 1 (nothing recorded) when it may not wait: it has
# waited _JUDGE_HANDOFF_MAX times, it was judged on coming back in this call,
# or it is the loop's last round. Nothing is recorded with no receiver, no run
# state to say when stages ran (ZBUILD_STATE_DIR), or no kept file's folder.
declare -gA _JUDGE_HANDOFF_JUDGED=()
judge_handoff_put() {
    local p c n=0
    [[ -n "${1:-}" && -n "${2:-}" && -n "${3:-}" && -n "${ZBUILD_STATE_DIR:-}" ]] || return 1
    _judge_handoff_paths p c "$1" "$2"
    [[ -d "${p%/*}" ]] || return 1
    [[ -n "${_JUDGE_HANDOFF_JUDGED[$1|$2]+x}" ]] && return 1
    judge_handoff_last_round && return 1
    [[ -s "$c" ]] && { IFS= read -r n < "$c" || true; }
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    (( n >= _JUDGE_HANDOFF_MAX )) && { _judge_emit judge.handoff.capped "item=$2" "times=$n"; return 1; }
    printf '%s\n%s\n%s\n' "$3" "${4//$'\n'/ }" "${5//$'\n'/$'\x1e'}" > "$p" 2>/dev/null || return 1
    printf '%s\n' "$(( n + 1 ))" > "$c" 2>/dev/null || true
    _judge_emit judge.handoff.waiting "item=$2" "to=$3"
    return 0
}

# judge_handoff_last_round — rc 0 on the loop's last round (ZBUILD_CYCLE_ITER
# is ZBUILD_CYCLE_MAX_ITER): nothing waits then.
judge_handoff_last_round() {
    [[ "${ZBUILD_CYCLE_ITER:-}" =~ ^[0-9]+$ && "${ZBUILD_CYCLE_MAX_ITER:-}" =~ ^[0-9]+$ ]] || return 1
    (( ZBUILD_CYCLE_ITER >= ZBUILD_CYCLE_MAX_ITER ))
}

# judge_handoff_state_v <var> <kept_file> <item> — how the part <item> stands:
# empty (not handed on), `waiting` (no receiver has run since, and it is not
# the last round), or `back` (one has, or it is the last round: judge it again,
# held to the finding and the answer). Sets _JUDGE_HANDOFF_TO,
# _JUDGE_HANDOFF_ANSWER and _JUDGE_HANDOFF_FINDING (lines joined by a record
# separator).
_JUDGE_HANDOFF_TO="" _JUDGE_HANDOFF_ANSWER="" _JUDGE_HANDOFF_FINDING=""
judge_handoff_state_v() {
    local -n _jhs="$1"; local p c r sd="${ZBUILD_STATE_DIR:-}"
    _jhs=""; _JUDGE_HANDOFF_TO="" _JUDGE_HANDOFF_ANSWER="" _JUDGE_HANDOFF_FINDING=""
    [[ -n "$sd" && -n "${2:-}" ]] || return 0
    _judge_handoff_paths p c "$2" "$3"
    [[ -s "$p" ]] || return 0
    { IFS= read -r _JUDGE_HANDOFF_TO; IFS= read -r _JUDGE_HANDOFF_ANSWER; IFS= read -r _JUDGE_HANDOFF_FINDING; } < "$p"
    [[ -n "$_JUDGE_HANDOFF_TO" ]] || return 0
    _jhs=waiting
    judge_handoff_last_round && { _jhs=back; return 0; }
    for r in $_JUDGE_HANDOFF_TO; do
        [[ -e "$sd/runtime/dispatched/$r" && "$sd/runtime/dispatched/$r" -nt "$p" ]] && { _jhs=back; break; }
    done
    return 0
}

# judge_handoff_clear <kept_file> <item> — the part was judged on coming back:
# its hand-off is over, and the reply judged with it hands nothing on.
judge_handoff_clear() {
    local p c; _judge_handoff_paths p c "$1" "$2"
    _JUDGE_HANDOFF_JUDGED["$1|$2"]=1
    [[ -e "$p" ]] || return 0
    rm -f "$p" 2>/dev/null || true
    _judge_emit judge.handoff.back "item=$2"
    return 0
}

# judge_handoff_waiting_v <var> <receivers> — what a part that waits is shown as.
judge_handoff_waiting_v() {
    local -n _jhw="$1"; local _jhw_r="${2// / or }"
    _jhw="handed to ${_jhw_r:-another stage}, waiting"
}

# judge_handoff_check <kept_file> <answers> <items_assoc> <kept_assoc>
#                     <earlier_assoc> <item>... — for a check that keeps a verdict per item
# (#2574): records each `not mine` answer of <answers> ("<key>: <answer>", one
# a line) whose answering stage's output carries its finding — the answering
# stage is the one whose result the answer is in (_JUDGE_ANSWER_FROM, from
# judge_answers_to_v) — for each item <items_assoc>[key] names (space
# separated; the finding's text is _JUDGE_ANSWER_FINDING[key] or the item's).
# Then each item that waits keeps its last verdict, kept or not, unasked; each
# that is back is judged again, its kept verdict moved to <earlier_assoc>.
# Sets _JUDGE_HANDOFF_WAIT (item → receivers) and _JUDGE_HANDOFF_BACK (item →
# finding<US>answer). Every <item> of the check is looked at, answered now or
# not. No program: the manifests are read by the shell.
declare -gA _JUDGE_HANDOFF_WAIT=() _JUDGE_HANDOFF_BACK=()
judge_handoff_check() {
    local kf="$1" ans="$2" a k kd it rcv mf st
    local -n _jhk_items="$3" _jhk_kept="$4" _jhk_earl="$5"; shift 5
    _JUDGE_HANDOFF_WAIT=() _JUDGE_HANDOFF_BACK=()
    [[ -n "$kf" && -n "${ZBUILD_STATE_DIR:-}" ]] || return 0
    while IFS= read -r a; do
        [[ -n "$a" ]] || continue
        k="${a%%:*}"; zb_answer_kind_v kd "$a"; [[ "$kd" == "not mine" && -n "${_jhk_items[$k]:-}" ]] || continue
        mf=""; [[ -n "${_JUDGE_ANSWER_FROM[$k]:-}" ]] && judge_output_manifest_v mf "${_JUDGE_ANSWER_FROM[$k]}"
        [[ -n "$mf" ]] || continue
        judge_handoff_receivers_v rcv "$mf" "${_JUDGE_ANSWER_FROM[$k]%/*}" "$k"
        [[ -n "$rcv" ]] || continue
        for it in ${_jhk_items[$k]}; do
            judge_handoff_state_v st "$kf" "$it"; [[ "$st" == back ]] && continue
            judge_handoff_put "$kf" "$it" "$rcv" "${a#*: }" "${_JUDGE_ANSWER_FINDING[$k]:-}" || true
        done
    done <<< "$ans"
    for it in "$@"; do
        judge_handoff_state_v st "$kf" "$it"
        case "$st" in
            waiting)
                _JUDGE_HANDOFF_WAIT["$it"]="$_JUDGE_HANDOFF_TO"
                [[ -z "${_jhk_kept[$it]+x}" && -n "${_jhk_earl[$it]+x}" ]] && _jhk_kept["$it"]="${_jhk_earl[$it]}" ;;
            back)
                _JUDGE_HANDOFF_BACK["$it"]="${_JUDGE_HANDOFF_FINDING}"$'\x1f'"$_JUDGE_HANDOFF_ANSWER"
                [[ -n "${_jhk_kept[$it]+x}" ]] && { _jhk_earl["$it"]="${_jhk_kept[$it]}"; unset "_jhk_kept[$it]"; } ;;
        esac
    done
    return 0
}

# judge_handoff_done <kept_file> — every item that came back has been judged.
judge_handoff_done() {
    local it
    for it in "${!_JUDGE_HANDOFF_BACK[@]}"; do judge_handoff_clear "$1" "$it"; done
    return 0
}
