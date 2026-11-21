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

# _JUDGE_ITEM_TEXT: each item's text now (key → text), set by the check before
# it keeps its verdicts; judge_kept_put and judge_kept_put_all keep it with
# the verdict. _JUDGE_KEPT_TEXT: each item's text as last kept, read back by
# judge_kept_get_v and judge_kept_get_all_v; a record kept before #2579 has
# none.
declare -gA _JUDGE_ITEM_TEXT=() _JUDGE_KEPT_TEXT=()

# judge_item_was_v <var> <key> — <key>'s text when it was last answered, when
# its text now (_JUDGE_ITEM_TEXT) differs; empty when unchanged, or nothing
# was kept.
judge_item_was_v() {
    local -n _jiw="$1"; local _jiw_o="${_JUDGE_KEPT_TEXT[$2]:-}"
    _jiw=""
    [[ -n "$_jiw_o" && -n "${_JUDGE_ITEM_TEXT[$2]+x}" && "$_jiw_o" != "${_JUDGE_ITEM_TEXT[$2]}" ]] && _jiw="$_jiw_o"
    return 0
}

# judge_changed_entry_v <var> <label> <was> <now> — one changed item, as the
# check is shown it: each text's lines after the first indented.
judge_changed_entry_v() {
    local -n _jce="$1"
    _jce="- $2"$'\n'"  was: ${3//$'\n'/$'\n'    }"$'\n'"  now: ${4//$'\n'/$'\n'    }"$'\n'
}

# judge_changed_block_v <var> <entries> — what a check is shown of the items
# that changed since it last answered them; empty when none did.
judge_changed_block_v() {
    local -n _jcb="$1"; _jcb=""
    [[ -n "${2//[[:space:]]/}" ]] || return 0
    _jcb=$'\n''CHANGED SINCE IT WAS LAST ANSWERED — each item below is shown as it was when it was last answered and as it is now. Judge it as it is now. The part that is new must be shown done: "done before" cannot cover it, and an answer that only says it was done before does not hold for the new part.'$'\n'"$2"
}
