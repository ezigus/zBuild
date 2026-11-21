#!/usr/bin/env bash
# scripts/lib/judge-changed.sh — a changed item is judged as a change (#2579,
# ADR-072 §4). Every check that keeps a verdict per item keeps the item's text
# with it; when the item's text has changed since, the check is shown the text
# then and now, and told the new part must be shown done. On #1764 run
# 44863026881 a step gained a clause, build answered "done before", and the
# check — shown only the new text — accepted it. Sourced by judge.sh.
#
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_JUDGE_CHANGED_LOADED:-}" ]] && return 0
_ZBUILD_JUDGE_CHANGED_LOADED=1

# A check passes each item's text now to judge_kept_put_all by name (its
# [text_assoc]), or to judge_kept_put as _JUDGE_KEEP_TEXT on the call; it is
# kept with the verdict. _JUDGE_KEPT_TEXT: each item's text as last kept, read
# back by judge_kept_get_v and judge_kept_get_all_v; a record kept before
# #2579 has none.
declare -gA _JUDGE_KEPT_TEXT=()
_JUDGE_CHANGED_MAX=1000

# judge_item_was_v <var> <key> <now> [now_assoc] — <key>'s text when it was
# last answered, when <now> differs; empty when unchanged or nothing was kept.
# Items keyed by position (build's step-N) move: an item whose text now is one
# kept under any key moved, and so did the item kept under <key> when its text
# is that of another item now (<now_assoc>, key → text) — neither is changed.
judge_item_was_v() {
    local -n _jiw="$1"; local _jiw_o="${_JUDGE_KEPT_TEXT[$2]:-}" _jiw_k
    _jiw=""
    [[ -n "$_jiw_o" && "$_jiw_o" != "$3" ]] || return 0
    for _jiw_k in "${!_JUDGE_KEPT_TEXT[@]}"; do [[ "${_JUDGE_KEPT_TEXT[$_jiw_k]}" == "$3" ]] && return 0; done
    if [[ -n "${4:-}" ]]; then
        local -n _jiw_n="$4"
        for _jiw_k in "${!_jiw_n[@]}"; do [[ "${_jiw_n[$_jiw_k]}" == "$_jiw_o" ]] && return 0; done
    fi
    _jiw="$_jiw_o"
}

# judge_changed_entry_v <var> <label> <was> <now> — one changed item, as the
# check is shown it: each side capped (_JUDGE_CHANGED_MAX), its lines after the
# first indented.
judge_changed_entry_v() {
    local -n _jce="$1"; local _jce_w="$3" _jce_n="$4"
    (( ${#_jce_w} > _JUDGE_CHANGED_MAX )) && _jce_w="${_jce_w:0:_JUDGE_CHANGED_MAX}…"
    (( ${#_jce_n} > _JUDGE_CHANGED_MAX )) && _jce_n="${_jce_n:0:_JUDGE_CHANGED_MAX}…"
    _jce="- $2"$'\n'"  was: ${_jce_w//$'\n'/$'\n'    }"$'\n'"  now: ${_jce_n//$'\n'/$'\n'    }"$'\n'
}

# judge_changed_block_v <var> <entries> — what a check is shown of the items
# that changed since it last answered them; empty when none did.
judge_changed_block_v() {
    local -n _jcb="$1"; _jcb=""
    [[ -n "${2//[[:space:]]/}" ]] || return 0
    _jcb=$'\n''CHANGED SINCE IT WAS LAST ANSWERED — each item below is shown as it was when it was last answered and as it is now. Judge it as it is now. The part that is new must be shown done: "done before" cannot cover it, and an answer that only says it was done before does not hold for the new part.'$'\n'"$2"
}
