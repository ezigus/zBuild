#!/usr/bin/env bash
# plugins/agent/build/lib/round.sh — the stage's round: every pass the engine
# dispatches build within one cycle iteration (#2323, ADR-054 §5 amendment).
#
# The engine re-dispatches a stage whose disposition is retryable (ADR-054 §6a).
# Each dispatch is a fresh plugin run that writes its result to the same fixed
# path, so without this the result described only the LAST pass: #2032 run
# 37289606005 committed one file on pass 1 and reported "changed 0 file(s)"
# after pass 2 changed nothing. The round is carried in build's own primary
# output (`.round`), keyed by run, cycle and iteration, and starts from the HEAD
# the round's first pass started on.
# Sourced by plugin.sh after shared libs (event-bus.sh, etc.) are loaded.

[[ -n "${_ZBUILD_BUILD_ROUND_LOADED:-}" ]] && return 0
_ZBUILD_BUILD_ROUND_LOADED=1

_BUILD_ROUND_BASE=""
_BUILD_ROUND_PASSES=1
_BUILD_ROUND_PRIOR_ITERS=0

# _build_round_open <summary_json> <repo_root>
# Called before this pass writes anything. Continues the round recorded in the
# existing summary when it is this run's, this cycle's and this iteration's and
# its base is still behind HEAD; otherwise opens a new round at HEAD.
_build_round_open() {
    local summary_json="$1" repo_root="$2"
    _BUILD_ROUND_BASE="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || true)"
    _BUILD_ROUND_PASSES=1
    _BUILD_ROUND_PRIOR_ITERS=0
    [[ -n "${ZBUILD_RUN_ID:-}" && -s "$summary_json" ]] || return 0
    # A first pass has no round on record: tell that in bash, with no process
    # (ADR-065 fork budget), before asking jq for the three fields at once.
    local _sj=""; IFS= read -r -d '' _sj < "$summary_json" || true
    [[ "$_sj" == *'"round"'* ]] || return 0
    local base passes iters
    IFS=$'\t' read -r base passes iters < <(jq -r --arg r "${ZBUILD_RUN_ID}" \
            --arg c "${ZBUILD_CYCLE_ID:-}" --arg i "${ZBUILD_CYCLE_ITER:-0}" \
            '.round // empty | select(.run_id == $r and .cycle_id == $c and .iter == $i)
             | [(.base // ""), (.passes // 0), (.iterations // 0)] | @tsv' \
            "$summary_json" 2>/dev/null || true) || true   # no match: read hits EOF (rc 1) under set -e
    [[ "$passes" =~ ^[0-9]+$ && "$iters" =~ ^[0-9]+$ ]] || return 0
    { [[ -n "$base" ]] && git -C "$repo_root" merge-base --is-ancestor "$base" HEAD 2>/dev/null; } || return 0
    _BUILD_ROUND_BASE="$base"
    _BUILD_ROUND_PASSES=$(( passes + 1 ))
    _BUILD_ROUND_PRIOR_ITERS="$iters"
}

# _build_round_widen <repo_root>
# Folds what earlier passes of the round committed into this pass's stats.
# Reads and sets the caller's files_changed_json / lines_added / lines_removed /
# files_changed_count (dynamic scope). A first pass is left exactly as it was.
_build_round_widen() {
    local repo_root="$1"
    # A first pass is the whole round: the caller's figures already cover it.
    [[ -n "$_BUILD_ROUND_BASE" && "$_BUILD_ROUND_PASSES" -gt 1 ]] || return 0
    # One git call gives the paths and the line counts; empty means the round's
    # earlier passes committed nothing (or this is its first pass).
    local numstat a r p add=0 rem=0 paths=""
    numstat="$(git -C "$repo_root" diff --numstat --no-renames "$_BUILD_ROUND_BASE" HEAD 2>/dev/null || true)"
    [[ -n "$numstat" ]] || return 0
    while IFS=$'\t' read -r a r p; do
        [[ -n "$p" ]] || continue
        [[ "$a" =~ ^[0-9]+$ ]] && add=$(( add + a ))
        [[ "$r" =~ ^[0-9]+$ ]] && rem=$(( rem + r ))
        paths+="$p"$'\n'
    done <<< "$numstat"
    local both
    both="$(jq -r --arg c "$paths" \
        '((. + ($c | split("\n") | map(select(length > 0)))) | unique) as $u
         | ($u | length | tostring) + "\t" + ($u | tojson)' \
        <<< "${files_changed_json:-[]}" 2>/dev/null || true)"
    if [[ -n "$both" ]]; then
        # shellcheck disable=SC2034  # the caller's locals, set via dynamic scope
        files_changed_count="${both%%$'\t'*}"
        files_changed_json="${both#*$'\t'}"
    fi
    lines_added=$(( ${lines_added:-0} + add ))
    lines_removed=$(( ${lines_removed:-0} + rem ))
}

# _build_round_total_iterations <this_pass_iterations>
_build_round_total_iterations() {
    local n="${1:-0}"; [[ "$n" =~ ^[0-9]+$ ]] || n=0
    printf '%s' "$(( _BUILD_ROUND_PRIOR_ITERS + n ))"
}

# _build_round_json <this_pass_iterations> — the round as a JSON object, built in
# bash with no process (ADR-065 fork budget): the summary writer folds it into its
# own single write. Its values are ids, numbers and a commit hash; anything else
# gives `null`, and the round simply starts over next pass.
_build_round_json() {
    local total r="${ZBUILD_RUN_ID:-}" c="${ZBUILD_CYCLE_ID:-}" i="${ZBUILD_CYCLE_ITER:-0}"
    total="$(( _BUILD_ROUND_PRIOR_ITERS + ${1:-0} ))"
    local re='^[A-Za-z0-9._:-]*$'
    if [[ "$r" =~ $re && "$c" =~ $re && "$i" =~ $re && "$_BUILD_ROUND_BASE" =~ $re ]]; then
        printf '{"run_id":"%s","cycle_id":"%s","iter":"%s","base":"%s","passes":%d,"iterations":%d}' \
            "$r" "$c" "$i" "$_BUILD_ROUND_BASE" "$_BUILD_ROUND_PASSES" "$total"
    else
        printf 'null'
    fi
}
