#!/usr/bin/env bash
# scripts/lib/stage-requires.sh — a stage runs only when the earlier stages it
# requires passed (#2611, ADR-068 §3). The template names them (`requires:`,
# template_stage_requires); the runner asks stage_requires_gate before each
# top-level unit. A stage whose requires were met is told so
# (ZBUILD_STAGE_REQUIRES_MET=yes): pr-open and merge refuse without it, so a PR
# never opens on a run that did not pass what its template asks (ADR-001).
#
# Sourced library: no set -euo pipefail.
[[ -n "${_ZBUILD_STAGE_REQUIRES_LOADED:-}" ]] && return 0
_ZBUILD_STAGE_REQUIRES_LOADED=1

# stage_requires_gate <state_file> <stage> — rc 0 when every stage <stage>
# requires is complete with a pass (or no verdict), exporting
# ZBUILD_STAGE_REQUIRES_MET=yes when it requires any; rc 1 when one is not,
# with _STAGE_REQUIRES_UNMET naming each (space-separated). A stage that
# requires nothing is never told it was met.
_STAGE_REQUIRES_UNMET=""
stage_requires_gate() {
    local sf="$1" names v="_TPL_STAGE_REQUIRES_${2//-/_}"
    unset ZBUILD_STAGE_REQUIRES_MET
    _STAGE_REQUIRES_UNMET=""
    names="${!v:-}"   # template_stage_requires, without a process per unit
    [[ -n "${names// /}" ]] || return 0
    # Fail closed: no state, or one jq cannot read, meets nothing.
    if [[ ! -s "$sf" ]] || ! _STAGE_REQUIRES_UNMET="$(jq -r --arg n "$names" '
        . as $s | [($n | split(" ") | map(select(length > 0)))[]
        | select((($s.stage_statuses // {})[.] // "") != "complete"
                 or ((($s.stage_verdicts // {})[.] // "pass") | IN("pass", "complete") | not))]
        | join(" ")' "$sf" 2>/dev/null)"; then
        _STAGE_REQUIRES_UNMET="$names"
    fi
    [[ -z "$_STAGE_REQUIRES_UNMET" ]] || return 1
    export ZBUILD_STAGE_REQUIRES_MET=yes
    return 0
}
