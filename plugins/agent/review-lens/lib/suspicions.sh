#!/usr/bin/env bash
# plugins/agent/review-lens/lib/suspicions.sh — a suspicion sends the change
# round once a run (#2630, ADR-040 §3). A suspicion is the line it is about —
# its file and quote, not its words: reworded, it is the same one. The lens
# keeps which it sent in its own result (`sent_suspicions`), each run adding to
# the last, so a round between with none, and the same one later, never send
# it round again. A result from before the run started (ZBUILD_RUN_START_MARKER)
# does not count; with no marker every round counts it new, bounded by the
# loop's rounds.
#
# Sourced library: inherits the caller's pipefail/errexit; do not set them here.

[[ -n "${_ZBUILD_RL_SUSPICIONS_LOADED:-}" ]] && return 0
_ZBUILD_RL_SUSPICIONS_LOADED=1

# _rl_suspicions_sent_v <var> <result_json> — the keys (`<file>|<quote>`) the
# lens's result from earlier in this run says it sent, as a JSON array; `[]`
# when there is none, it is from an earlier run, or there is no marker. One jq,
# only when the result holds any.
_rl_suspicions_sent_v() {
    local -n _rlss="$1"; local f="$2" m="${ZBUILD_RUN_START_MARKER:-}" s="" j
    _rlss="[]"
    [[ -n "$m" && -e "$m" && -s "$f" && ! "$m" -nt "$f" ]] || return 0
    IFS= read -r -d '' s < "$f" || true
    [[ "$s" == *'"sent_suspicions"'* ]] || return 0
    j="$(jq -c '[.sent_suspicions[]? | strings]' "$f" 2>/dev/null)" || return 0
    [[ "$j" == "["*"]" ]] && _rlss="$j"
    return 0
}

# _rl_suspicions_keep_v <var> <normalized_json> <sent_json> — the lens's result
# with the keys it has now sent added (`sent_suspicions`), by the shell.
_rl_suspicions_keep_v() {
    local -n _rlsk="$1"; local n="$2" k="${3:-[]}"
    _rlsk="$n"
    [[ "$k" == "["*"]" && "$k" != "[]" && "$n" == *"}" ]] || return 0
    _rlsk="${n%\}},\"sent_suspicions\":$k}"
}
