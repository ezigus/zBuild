#!/usr/bin/env bash
# scripts/lib/stage-signal.sh — how a stage records being stopped by a signal
# (#2225 §2, ADR-054 §6a).
#
# One word for it, chosen here: `interrupted` (reason `signal_interrupt`) — an
# outside signal stopped the stage, and the engine retries. Plugins used to pick
# their own: #1837's intake wrote `broken` on SIGTERM, which halts the whole run.
# And each carried its own TERM/INT trap, some resetting the caller's handlers
# to the default instead of putting them back.
#
#   stage_signal_begin <callback>   around the work a signal may interrupt:
#                                   a TERM/INT runs <callback> "$STAGE_SIGNAL_DISPOSITION" "$STAGE_SIGNAL_REASON"
#   stage_signal_end                the caller's own TERM/INT handlers are back
#
# scripts/lib/lint-stage-signals.sh refuses a raw TERM/INT trap in plugins/.
[[ -n "${_ZBUILD_STAGE_SIGNAL_LOADED:-}" ]] && return 0
_ZBUILD_STAGE_SIGNAL_LOADED=1

STAGE_SIGNAL_DISPOSITION="interrupted"
STAGE_SIGNAL_REASON="signal_interrupt"
_ZB_SIGNAL_PREV=""
_ZB_SIGNAL_CB=""

stage_signal_begin() {
    _ZB_SIGNAL_CB="${1:?stage_signal_begin needs a callback}"
    _ZB_SIGNAL_PREV="$(trap -p TERM INT)"
    trap '_stage_signal_fire' TERM INT
}

_stage_signal_fire() {
    "$_ZB_SIGNAL_CB" "$STAGE_SIGNAL_DISPOSITION" "$STAGE_SIGNAL_REASON"
}

stage_signal_end() {
    trap - TERM INT
    [[ -n "$_ZB_SIGNAL_PREV" ]] && eval "$_ZB_SIGNAL_PREV"
    _ZB_SIGNAL_PREV=""; _ZB_SIGNAL_CB=""
    return 0
}
