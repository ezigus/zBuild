#!/usr/bin/env bash
# scripts/lib/stage-result.sh — the one writer of a stage's result (#2366,
# ADR-054 §6, result contract 3).
#
# Every stage gives the engine the same interface: one `outcome` from the
# engine's closed list (outcome_vocabulary), a `reason` an operator can read,
# and anything stage-specific under `data`. Stages and tests make results with
# this writer, so a result is always what the engine reads.
#
# Sourced library: no `set -euo pipefail`.

[[ -n "${_ZBUILD_STAGE_RESULT_LOADED:-}" ]] && return 0
_ZBUILD_STAGE_RESULT_LOADED=1

# Stage stubs source this on every dispatch: the shell finds the repo root
# (ADR-065 §5), no dirname.
_zb_sr_d="${BASH_SOURCE[0]%/*}"; [[ "$_zb_sr_d" == "${BASH_SOURCE[0]}" ]] && _zb_sr_d="."
_zb_sr_root="$(cd "$_zb_sr_d/../.." && pwd)"
# shellcheck source=../../core/pipeline/disposition.sh
source "$_zb_sr_root/core/pipeline/disposition.sh"
# shellcheck source=../../core/contract/version.sh
source "$_zb_sr_root/core/contract/version.sh"
unset _zb_sr_d _zb_sr_root

# _stage_result_json <outcome> <reason> [data-json] — the result object, or rc 1
# for an outcome off the list, an empty reason or data that is not an object.
_stage_result_json() {
    local outcome="${1-}" reason="${2-}" data="${3:-}"
    if ! outcome_is_valid "$outcome"; then
        printf 'stage_result: "%s" is not an outcome (%s)\n' "$outcome" "$(outcome_vocabulary)" >&2
        return 1
    fi
    [[ -n "$reason" ]] || { printf 'stage_result: a result needs a reason\n' >&2; return 1; }
    [[ -n "$data" ]] || data='{}'
    jq -nc --argjson c "$_ZBUILD_CONTRACT_V3" --arg o "$outcome" --arg r "$reason" --argjson d "$data" \
        'if ($d | type) != "object" then error("data must be an object") else . end
         | {result_contract: $c, outcome: $o, reason: $r}
         + (if $d == {} then {} else {data: $d} end)' 2>/dev/null
}

# stage_result_write <path> <outcome> <reason> [data-json]
# Writes the stage's result to <path>. rc 1 (nothing written) when the outcome
# is off the list, the reason is empty, or the data is not a JSON object.
stage_result_write() {
    local path="${1-}" json
    [[ -n "$path" ]] || { printf 'stage_result_write: no path\n' >&2; return 1; }
    json="$(_stage_result_json "${2-}" "${3-}" "${4:-}")" || return 1
    [[ -n "$json" ]] || { printf 'stage_result_write: data is not a JSON object\n' >&2; return 1; }
    if declare -F atomic_write >/dev/null 2>&1; then
        atomic_write "$path" <<< "$json"
    else
        printf '%s\n' "$json" > "$path"
    fi
}

# stage_result_add <path> <outcome> <reason>
# Adds the result fields to the JSON object already at <path> — for a stage
# whose output is itself its result (plan.json). Earlier result fields, of any
# contract, are replaced.
stage_result_add() {
    local path="${1-}" head merged
    [[ -s "$path" ]] || { printf 'stage_result_add: nothing at %s\n' "$path" >&2; return 1; }
    head="$(_stage_result_json "${2-}" "${3-}")" || return 1
    if ! jq -e 'type == "object"' "$path" >/dev/null 2>&1; then
        printf 'stage_result_add: %s is not a JSON object\n' "$path" >&2
        return 1
    fi
    merged="$(jq -c --argjson h "$head" \
        'del(.verdict, .disposition, .outcome, .result_contract, .reason) + $h' "$path")" \
        || { printf 'stage_result_add: could not add the result to %s\n' "$path" >&2; return 1; }
    if declare -F atomic_write >/dev/null 2>&1; then
        atomic_write "$path" <<< "$merged"
    else
        printf '%s\n' "$merged" > "$path"
    fi
}
