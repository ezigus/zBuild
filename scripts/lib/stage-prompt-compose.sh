#!/usr/bin/env bash
# scripts/lib/stage-prompt-compose.sh — a stage's prompt composed from its three
# parts and the engine's three blocks, in the contract order, and the check that
# a prompt has them (ADR-067 §8). Sourced by stage-prompt.sh, whose constants
# (the part and block headings) it reads.
#
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_STAGE_PROMPT_COMPOSE_LOADED:-}" ]] && return 0
_ZBUILD_STAGE_PROMPT_COMPOSE_LOADED=1

# ─── stage_prompt_compose [--fresh] <out> <own> <judge> <limits> ─────────────
# The stage's three parts (files) and the engine's three blocks
# ($ZBUILD_STAGE_BLOCKS), in the contract order. rc 1, and <out> untouched,
# when a block or a part is missing or empty.
stage_prompt_compose() {
    # #2458: --fresh — a judging call: Previous work without the stage's notes,
    # and the rules without a notes file or the confirm rule.
    local _v=""; [[ "${1:-}" == --fresh ]] && { _v="-fresh"; shift; }
    local out="$1" own="$2" judge="$3" limits="$4" dir="${ZBUILD_STAGE_BLOCKS:-}" f
    for f in "$dir/from-repo.md" "$dir/previous-work$_v.md" "$dir/rules$_v.md"; do
        if [[ -z "$dir" || ! -s "$f" ]]; then
            printf 'stage_prompt_compose: the engine block %s is missing — not composing a prompt without it\n' "$f" >&2
            return 1
        fi
    done
    # #2470: every section read by the shell, not a cat each (ADR-065 §5).
    local _sp_o="" _sp_j="" _sp_l="" _sp_r="" _sp_p="" _sp_u=""
    [[ -s "$own" ]] && { IFS= read -r -d '' _sp_o < "$own" || true; }
    [[ -s "$judge" ]] && { IFS= read -r -d '' _sp_j < "$judge" || true; }
    [[ -s "$limits" ]] && { IFS= read -r -d '' _sp_l < "$limits" || true; }
    f=""
    [[ -n "${_sp_o//[[:space:]]/}" ]] || f="$own"
    [[ -n "$f" || -n "${_sp_j//[[:space:]]/}" ]] || f="$judge"
    [[ -n "$f" || -n "${_sp_l//[[:space:]]/}" ]] || f="$limits"
    if [[ -n "$f" ]]; then
        printf 'stage_prompt_compose: the stage part %s is empty\n' "$f" >&2
        return 1
    fi
    IFS= read -r -d '' _sp_r < "$dir/from-repo.md" || true
    IFS= read -r -d '' _sp_p < "$dir/previous-work$_v.md" || true
    IFS= read -r -d '' _sp_u < "$dir/rules$_v.md" || true
    printf '%s\n\n%s\n%s\n\n%s\n%s\n\n%s\n%s\n\n%s\n%s\n\n%s\n%s\n\n%s' \
        "$_ZB_SP_REPO" "$_sp_r" "$_ZB_SP_OWN" "$_sp_o" "$_ZB_SP_JUDGE" "$_sp_j" \
        "$_ZB_SP_PREV" "$_sp_p" "$_ZB_SP_LIMITS" "$_sp_l" "$_ZB_SP_RULES" "$_sp_u" \
        > "$out.tmp" 2>/dev/null && mv -f "$out.tmp" "$out" 2>/dev/null && return 0
    rm -f "$out.tmp" 2>/dev/null
    return 1
}

# stage_prompt_compose_text [--fresh] <own> <judge> <limits> — the same, from strings, on
# stdout. For a stage that builds its prompt in variables.
stage_prompt_compose_text() {
    local -a _fr=(); [[ "${1:-}" == --fresh ]] && { _fr=(--fresh); shift; }
    local t; t="$(mktemp -d "${TMPDIR:-/tmp}/zb-sp.XXXXXX")" || return 1
    printf '%s\n' "$1" > "$t/own"; printf '%s\n' "$2" > "$t/judge"; printf '%s\n' "$3" > "$t/limits"
    local rc=0
    stage_prompt_compose "${_fr[@]+"${_fr[@]}"}" "$t/out" "$t/own" "$t/judge" "$t/limits" || rc=$?
    local _sp_out=""
    [[ "$rc" -eq 0 ]] && { IFS= read -r -d '' _sp_out < "$t/out" || true; printf '%s' "$_sp_out"; }
    rm -rf "${t:?}"
    return "$rc"
}

# stage_prompt_compose_parts [--fresh] <text> — the same, from the stage's text written
# under its three headings ("## What you own", "## What you judge against",
# "## What you must not do"), on stdout. Text before the first heading is part
# of What you own. The judged material may itself hold such a heading, so a
# part runs from the FIRST "own", to the first "judge" after it, to the LAST
# "must not do". rc 1 when a part is missing.
stage_prompt_compose_parts() {
    local -a _fr=(); [[ "${1:-}" == --fresh ]] && { _fr=(--fresh); shift; }
    local text="$1" t
    t="$(mktemp -d "${TMPDIR:-/tmp}/zb-sp.XXXXXX")" || return 1
    printf '%s\n' "$text" | awk -v o="$_ZB_SP_OWN" -v j="$_ZB_SP_JUDGE" -v l="$_ZB_SP_LIMITS" -v d="$t" '
        { line[NR] = $0 }
        $0 == o && !oi { oi = NR }
        $0 == j && oi && !ji { ji = NR }
        $0 == l && ji { li = NR }
        END {
            if (!oi || !ji || !li) exit 1
            for (i = 1; i < oi; i++) print line[i] > (d "/own")
            for (i = oi + 1; i < ji; i++) print line[i] > (d "/own")
            for (i = ji + 1; i < li; i++) print line[i] > (d "/judge")
            for (i = li + 1; i <= NR; i++) print line[i] > (d "/limits")
        }' || { rm -rf "${t:?}"; printf 'stage_prompt_compose_parts: the stage text is missing one of its three parts\n' >&2; return 1; }
    local rc=0
    stage_prompt_compose "${_fr[@]+"${_fr[@]}"}" "$t/out" "$t/own" "$t/judge" "$t/limits" || rc=$?
    local _sp_out=""
    [[ "$rc" -eq 0 ]] && { IFS= read -r -d '' _sp_out < "$t/out" || true; printf '%s' "$_sp_out"; }
    rm -rf "${t:?}"
    return "$rc"
}

# stage_prompt_reask <prompt> <what-was-wrong> <reply> — the same prompt asked
# again, with what was wrong with the reply and the reply itself (ADR-060 §6):
# the model fixes what is named instead of starting over blind.
stage_prompt_reask() {
    local reply="$3"
    if (( ${#reply} > _ZB_SP_REPLY_MAX_BYTES )); then
        reply="${reply:0:_ZB_SP_REPLY_MAX_BYTES}"$'\n[… the rest of your reply is cut]'
    fi
    printf '%s\n\n%s\n\n%s\n\n%s\n\n%s\n%s\n%s\n' "$1" "$_ZB_SP_REASK" \
        "Your reply could not be used: $2" \
        "Answer again, in the form asked for above, and fix what is named. Do not do the work again: what your reply says stands, only its form was wrong." \
        "Your reply was:" '<<<' "$reply"
    printf '>>>\n'
}

# stage_prompt_check <file> — rc 0 when the six sections appear in the contract
# order: the first line is "From the repo", and each later section follows the
# one before it.
stage_prompt_check() {
    local f="$1"
    [[ -s "$f" ]] || return 1
    local _sp_first=""; IFS= read -r _sp_first < "$f" || true
    [[ "$_sp_first" == "$_ZB_SP_REPO" ]] || return 1
    awk -v h1="$_ZB_SP_OWN" -v h2="$_ZB_SP_JUDGE" -v h3="$_ZB_SP_PREV" \
        -v h4="$_ZB_SP_LIMITS" -v h5="$_ZB_SP_RULES" '
        BEGIN { want[1]=h1; want[2]=h2; want[3]=h3; want[4]=h4; want[5]=h5; n=1 }
        n <= 5 && $0 == want[n] { n++ }
        END { exit(n == 6 ? 0 : 1) }' "$f"
}
