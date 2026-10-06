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
    local rec
    rec="$(jq -c --arg r "${ZBUILD_RUN_ID}" --arg c "${ZBUILD_CYCLE_ID:-}" \
            --arg i "${ZBUILD_CYCLE_ITER:-0}" \
            '.round // empty | select(.run_id == $r and .cycle_id == $c and .iter == $i)' \
            "$summary_json" 2>/dev/null || true)"
    [[ -n "$rec" ]] || return 0
    local base passes iters
    base="$(jq -r '.base // ""' <<< "$rec" 2>/dev/null || true)"
    passes="$(jq -r '.passes // 0' <<< "$rec" 2>/dev/null || echo 0)"
    iters="$(jq -r '.iterations // 0' <<< "$rec" 2>/dev/null || echo 0)"
    [[ "$passes" =~ ^[0-9]+$ && "$iters" =~ ^[0-9]+$ ]] || return 0
    [[ -n "$base" ]] && git -C "$repo_root" merge-base --is-ancestor "$base" HEAD 2>/dev/null || return 0
    _BUILD_ROUND_BASE="$base"
    _BUILD_ROUND_PASSES=$(( passes + 1 ))
    _BUILD_ROUND_PRIOR_ITERS="$iters"
}

# _build_round_widen <repo_root>
# Folds what earlier passes of the round committed into this pass's stats.
# Reads and sets the caller's files_changed_json / lines_added / lines_removed /
# files_changed_count (dynamic scope). A first pass is left exactly as it was.
_build_round_widen() {
    local repo_root="$1" head
    head="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || true)"
    [[ -n "$_BUILD_ROUND_BASE" && -n "$head" && "$head" != "$_BUILD_ROUND_BASE" ]] || return 0
    local committed numstat a r _p add=0 rem=0
    committed="$(git -C "$repo_root" diff --name-only "$_BUILD_ROUND_BASE" HEAD 2>/dev/null || true)"
    [[ -n "$committed" ]] || return 0
    numstat="$(git -C "$repo_root" diff --numstat "$_BUILD_ROUND_BASE" HEAD 2>/dev/null || true)"
    while IFS=$'\t' read -r a r _p; do
        [[ "$a" =~ ^[0-9]+$ ]] && add=$(( add + a ))
        [[ "$r" =~ ^[0-9]+$ ]] && rem=$(( rem + r ))
    done <<< "$numstat"
    files_changed_json="$(jq -c --arg c "$committed" \
        '(. + ($c | split("\n") | map(select(length > 0)))) | unique' \
        <<< "${files_changed_json:-[]}" 2>/dev/null || printf '%s' "${files_changed_json:-[]}")"
    # shellcheck disable=SC2034  # the caller's local, set via dynamic scope
    files_changed_count="$(jq 'length' <<< "$files_changed_json" 2>/dev/null || echo 0)"
    lines_added=$(( ${lines_added:-0} + add ))
    lines_removed=$(( ${lines_removed:-0} + rem ))
}

# _build_round_total_iterations <this_pass_iterations>
_build_round_total_iterations() {
    local n="${1:-0}"; [[ "$n" =~ ^[0-9]+$ ]] || n=0
    printf '%s' "$(( _BUILD_ROUND_PRIOR_ITERS + n ))"
}

# _build_round_record <summary_json> <this_pass_iterations>
# Stamps the round onto the result this pass wrote, so the next pass of the
# same round continues it. Fail-open: bookkeeping never changes the verdict.
_build_round_record() {
    local summary_json="$1" total
    [[ -s "$summary_json" ]] || return 0
    total="$(_build_round_total_iterations "${2:-0}")"
    local out
    out="$(jq -c --arg r "${ZBUILD_RUN_ID:-}" --arg c "${ZBUILD_CYCLE_ID:-}" \
            --arg i "${ZBUILD_CYCLE_ITER:-0}" --arg b "$_BUILD_ROUND_BASE" \
            --argjson p "$_BUILD_ROUND_PASSES" --argjson n "$total" \
            '. + {passes: $p, round: {run_id: $r, cycle_id: $c, iter: $i, base: $b,
                                     passes: $p, iterations: $n}}' \
            "$summary_json" 2>/dev/null || true)"
    [[ -n "$out" ]] || return 0
    atomic_write "$summary_json" <<< "$out" 2>/dev/null || true
}
