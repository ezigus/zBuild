#!/usr/bin/env bash
# scripts/lib/stage-budget-note.sh — the limits a model stage runs under, stated
# to the model (#2252, the budget-note half of #2222; ADR-063 §1).
#
# A model that does not know its deadline works until it is killed, and a
# killed call returns nothing. The numbers come from the values the router
# enforces for the dispatched stage (_route_resolve_timeout /
# _route_resolve_max_turns, core/router/route.sh) — never a second copy.
#
#   stage_budget_note <what-to-finish>   prints the note, or nothing when
#                                        neither limit can be resolved
#
# Sourced library: inherits the caller's settings.
[[ -n "${_ZBUILD_STAGE_BUDGET_NOTE_LOADED:-}" ]] && return 0
_ZBUILD_STAGE_BUDGET_NOTE_LOADED=1

stage_budget_note() {
    local what="${1:-your answer}" secs="" turns=""
    declare -F _route_resolve_timeout >/dev/null 2>&1 && secs="$(_route_resolve_timeout 2>/dev/null || true)"
    declare -F _route_resolve_max_turns >/dev/null 2>&1 && turns="$(_route_resolve_max_turns 2>/dev/null || true)"
    if [[ "$turns" =~ ^[0-9]+$ ]] && (( turns > 0 )); then
        cat <<EOF
TURN BUDGET (read this — you have a BOUNDED tool-call budget):
- You have about ${turns} tool-call turns. Read what you need once, then write ${what}.
EOF
    fi
    if [[ "$secs" =~ ^[0-9]+$ ]] && (( secs > 0 )); then
        cat <<EOF
WALL CLOCK BUDGET (read this — the stage has a hard OS wall-clock timeout):
- You have ${secs} seconds in total. Estimate elapsed time from your tool calls and finish ${what} before ~$(( secs * 70 / 100 ))s.
- A partial answer that names its gaps beats being stopped with nothing: a call that runs out of time returns no output at all.
EOF
    fi
}
