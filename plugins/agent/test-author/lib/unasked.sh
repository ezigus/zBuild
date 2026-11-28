#!/usr/bin/env bash
# plugins/agent/test-author/lib/unasked.sh — test-author's own check refuses an
# assertion its branch added that names no SPEC and tests what neither a SPEC
# nor a design step asks for (#2575, ADR-069). A test for a change nothing asks
# for pins that change.
#
# The lines are found by script: the lines this branch added to the test
# folders (zb_test_folder_branch_lines_v) that read as a check — a call named
# assert… or refute…, an `expect` call, or a ✓/✗ mark — and carry no tag of a
# SPEC of this contract. A line the default branch already had, that only lost
# a tag (the stale-tag step), is not new and is not judged. Whether each line
# is asked for is judged by the assertion check's call (_sc_call), shown every
# SPEC and every design step, in chunks; every line is judged. Each answer is
# kept beside test-author's result, by file, line content and the SPECs and
# steps it was judged against, so a line is judged once.
#
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_TA_UNASKED_LOADED:-}" ]] && return 0
_ZBUILD_TA_UNASKED_LOADED=1
# shellcheck source=../../../../scripts/lib/digest.sh
source "${BASH_SOURCE[0]%/*}/../../../../scripts/lib/digest.sh"
# shellcheck source=../../../../scripts/lib/design-steps.sh
source "${BASH_SOURCE[0]%/*}/../../../../scripts/lib/design-steps.sh"
# shellcheck source=../../../../scripts/lib/trace.sh
source "${BASH_SOURCE[0]%/*}/../../../../scripts/lib/trace.sh"

# How many lines one call judges.
_TA_UNASKED_CHUNK=30
_TA_UNASKED_WHAT="the check that each untagged assertion traces to a SPEC or a design step"

# _ta_unasked_untag_v <var> <text> [any] — <text> without its tags of this
# contract (_TA_UQ_IDS " a b ", and the issue in _TA_UQ_ISSUE) — with [any],
# without any tag-shaped text, as the stale-tag step takes one off — its
# spaces squeezed.
_ta_unasked_untag_v() {
    local -n _tuu="$1"; local _t="$2" _out="" _c _w _m
    while [[ "$_t" =~ \[([^][]*)\] ]]; do
        _c="${BASH_REMATCH[1]}"; _m="${BASH_REMATCH[0]}"; _out+="${_t%%"$_m"*}"
        _t="${_t#*"$_m"}"
        [[ -n "$_TA_UQ_ISSUE" && "$_c" == "#$_TA_UQ_ISSUE/"* ]] && _c="${_c#"#$_TA_UQ_ISSUE/"}"
        if [[ -n "${3:-}" ]]; then
            [[ "$_c" =~ ^(#[0-9]+/)?(${_ACCEPTANCE_ID_ERE})$ ]] || _out+="$_m"
        else
            [[ "$_TA_UQ_IDS" == *" $_c "* ]] || _out+="$_m"
        fi
    done
    _out+="$_t"
    read -ra _w <<< "$_out"; _tuu="${_w[*]}"
}

# _ta_unasked_is_check <line> — rc 0 when the line reads as a check.
_ta_unasked_is_check() {
    local l="$1"
    [[ "$l" =~ ^[[:space:]]*(#|//) ]] && return 1
    [[ "$l" =~ (^|[^A-Za-z0-9_\$])(assert|refute)[A-Za-z0-9_]*([[:space:]\(]|$) ]] && return 0
    [[ "$l" =~ (^|[^A-Za-z0-9_\$])expect[[:space:]]*\( ]] && return 0
    [[ "$l" =~ (^|[\;\&\|\{[:space:]])expect[[:space:]]+[^=[:space:]] ]] && return 0
    [[ "$l" == *✓* || "$l" == *✗* ]]
}

# _ta_unasked_lines_v <array> <design> <repo> — "<file> line <n>: <text>" for
# each line this branch added to a test file that reads as a check and carries
# no tag of this contract, files in order.
_ta_unasked_lines_v() {
    local -n _tul="$1"; local design="$2" repo="$3" id tf i n l u
    local -a w=()
    _tul=()
    _TA_UQ_IDS=" "; _TA_UQ_ISSUE="${ZBUILD_ISSUE:-}"
    while IFS= read -r id; do [[ -n "$id" ]] && _TA_UQ_IDS+="$id "; done \
        < <(acceptance_list_spec_ids "$design" 2>/dev/null || true)
    [[ "$_TA_UQ_IDS" != " " ]] || return 0
    [[ "$_TA_UQ_ISSUE" =~ ^[1-9][0-9]*$ ]] || _TA_UQ_ISSUE=""
    local -A _tsl=() _trm=() _gone=()
    # The diff the stale-tag step read, when it read this repository's.
    if [[ "${_TA_BRANCH_LINES_REPO:-}" == "$repo" ]]; then
        for tf in "${!_TA_BRANCH_LINES[@]}"; do _tsl[$tf]="${_TA_BRANCH_LINES[$tf]}"; done
        for tf in "${!_TA_BRANCH_REMOVED[@]}"; do _trm[$tf]="${_TA_BRANCH_REMOVED[$tf]}"; done
    else
        zb_test_folder_branch_lines_v _tsl "$repo" _trm
    fi
    local -a order=() _tu_fl=() rm=()
    for tf in "${!_tsl[@]}"; do
        i=${#order[@]}
        while (( i > 0 )) && [[ "${order[i-1]}" > "$tf" ]]; do order[i]="${order[i-1]}"; i=$((i - 1)); done
        order[i]="$tf"
    done
    for tf in ${order[@]+"${order[@]}"}; do
        [[ -f "$repo/$tf" ]] || continue
        _gone=()
        IFS=$'\x1e' read -ra rm <<< "${_trm[$tf]:-}"
        for l in ${rm[@]+"${rm[@]}"}; do _ta_unasked_untag_v u "$l" any; u="${u//[[:space:]]/}"; [[ -n "$u" ]] && _gone[$u]=1; done
        mapfile -t _tu_fl < "$repo/$tf"
        for (( n = 1; n <= ${#_tu_fl[@]}; n++ )); do
            [[ "${_tsl[$tf]}" == all || " ${_tsl[$tf]} " == *" $n "* ]] || continue
            l="${_tu_fl[n-1]}"
            _ta_unasked_is_check "$l" || continue
            _ta_unasked_untag_v u "$l"
            read -ra w <<< "$l"
            [[ "$u" == "${w[*]}" ]] || continue       # it carries a tag: it names a SPEC
            # The default branch had it, tagged (spaces aside: a tag took one).
            [[ -n "${_gone[${u//[[:space:]]/}]+x}" ]] && continue
            l="${l#"${l%%[![:space:]]*}"}"
            _tul+=("$tf line $n: $l")
        done
    done
    return 0
}

# _ta_unasked_context_v <var> <design> — every SPEC, then every step numbered,
# as the check is shown them.
_ta_unasked_context_v() {
    local -n _tuc="$1"; local design="$2" blk sid s i=0
    local -a steps=()
    _tuc="THE SPECS:"$'\n'
    blk="$(extract_acceptance_block "$design" 2>/dev/null)" || blk=""
    while IFS= read -r sid; do
        [[ -n "$sid" ]] || continue
        _acceptance_spec_line "$blk" "$sid" && _tuc+="- $sid: $_ACC_SPEC_TEXT"$'\n'
    done < <(acceptance_list_spec_ids "$design" 2>/dev/null || true)
    zb_design_step_lines_v steps "$design"
    _tuc+=$'\n'"THE DESIGN'S STEPS:"$'\n'
    [[ ${#steps[@]} -gt 0 ]] || _tuc+="(none)"$'\n'
    # #2590: each step by its own number (2.1), as build's check names it; the
    # numbers are what an answer's STEP must be one of.
    _TA_UQ_LABELS=" "
    for s in ${steps[@]+"${steps[@]}"}; do
        i=$((i + 1)); _tuc+="${_ZB_STEP_LABELS[i-1]:-$i}. $s"$'\n'; _TA_UQ_LABELS+="${_ZB_STEP_LABELS[i-1]:-$i} "
    done
}

# _ta_unasked_finding_v <var> <file line n> <why> — the finding for a line the
# check judged unasked, in the shared rule's words (#2629, ADR-075 §3).
_ta_unasked_finding_v() {
    local -n _tuaf="$1"; local _m
    zb_trace_finding_v _m "$2 ($3)" "SPEC or design step" "design"
    _tuaf="$_m. If a SPEC does ask for it, tag the assertion with that SPEC"
}

# _ta_unasked_prompt <context> <lines_array> — the check's question.
_ta_unasked_prompt() {
    local -n _tup="$2"; local l _trace=""
    zb_trace_rule_v _trace "a SPEC or a design step's change" "design"
    cat <<'EOF'
You are checking test lines this branch added that carry no requirement's tag.

## What you own
EOF
    printf '%s A test for a change nothing asks for pins that change.' "$_trace"
    cat <<'EOF'
 For EACH line listed under THE LINES, decide whether it is an assertion — a check that can fail — and if so what asks for what it tests. A line changed for what a design step changes is asked for by that step. A line in a helper that a tagged assertion calls traces to that assertion's SPEC. A line that only checks that a tagged test's own setup happened — it fails when that test's scenario did not take place, such as "the stage started before the signal" — is part of that test: it is asked for by that test's SPEC. Open the test file to see what the line checks. Answer one list item for each, starting with its file and line number exactly as listed:

- <file> line <n>: asked | SPEC: <the identifier of the SPEC it tests>
- <file> line <n>: asked | STEP: <the number of the step whose change it tests>
- <file> line <n>: not an assertion
- <file> line <n>: unasked | WHY: <what it tests, and why no SPEC and no step asks for it>

## What you judge against
EOF
    printf '%s\nTHE LINES:\n' "$1"
    for l in "${_tup[@]}"; do printf -- '- %s\n' "$l"; done
    cat <<'EOF'

## What you must not do
- Judge what each test does, not the code it tests.
- Do not suggest a fix. Do not rewrite anything.
EOF
}

# _ta_unasked <design> <repo> <tier> [artifact_dir] — sets _TA_UNASKED_FINDINGS,
# one per line the check finds nothing asks for. A line with no usable answer
# is asked again once; any still unanswered, or a call that failed, set
# _TA_CORR_OUTCOME and _TA_CORR_WHAT (this check, and how many lines were left):
# no answer, no pass (#2062).
_ta_unasked() {
    local design="$1" repo="$2" tier="${3:-T2}" art="${4:-}" l key why ctx cfp lfp kf="" k v w
    local -a lines=() todo=() chunk=() missing=() left=()
    local -A kept=() now=()
    _TA_UNASKED_FINDINGS=()
    _ta_unasked_lines_v lines "$design" "$repo"
    [[ ${#lines[@]} -gt 0 ]] || return 0
    _ta_unasked_context_v ctx "$design"; zb_digest_v cfp "$ctx"
    [[ -n "$art" ]] && kf="${art%/}/test-author-unasked.tsv"
    # Only a line found asked (or no assertion) is kept: an unasked one is
    # judged again on every try.
    local old=""
    if [[ -n "$kf" && -s "$kf" ]]; then
        IFS= read -r -d '' old < "$kf" || true
        while IFS=$'\t' read -r k v w; do [[ -n "$k" && "$v" == ok ]] && kept[$k]="$v"$'\t'"$w"; done <<< "$old"
    fi
    # The key: the file, the line's content and what it is judged against.
    local -A keyof=()
    for l in "${lines[@]}"; do
        zb_digest_v lfp "${l#*: }"
        key="${l%% line *}"$'\x1f'"$lfp"$'\x1f'"$cfp"; keyof[$l]="$key"
        [[ -n "${kept[$key]+x}" ]] && now[$key]="${kept[$key]}" || todo+=("$l")
    done
    local rc_file="" router_rc=0 i raw problem
    if [[ ${#todo[@]} -gt 0 ]]; then
        rc_file="$(mktemp 2>/dev/null)" || rc_file=""
        [[ -n "$rc_file" ]] && printf '0' > "$rc_file"
    fi
    for (( i = 0; i < ${#todo[@]}; i += _TA_UNASKED_CHUNK )); do
        chunk=("${todo[@]:i:_TA_UNASKED_CHUNK}"); problem=""; raw=""
        local _try
        for _try in 1 2; do  # asked again once
            if [[ -n "$problem" ]]; then raw="$(_sc_call "$tier" "$(_ta_unasked_prompt "$ctx" chunk)" "$rc_file" "$problem" "$raw")"
            else raw="$(_sc_call "$tier" "$(_ta_unasked_prompt "$ctx" chunk)" "$rc_file")"; fi
            zb_reply_join_v raw "$raw"
            missing=()
            for l in "${chunk[@]}"; do
                [[ -n "${now[${keyof[$l]}]+x}" ]] && continue
                _ta_unasked_answer_v why "$raw" "${l%%: *}"
                if [[ -z "$why" ]]; then missing+=("${l%%: *}")
                else now[${keyof[$l]}]="$why"$'\t'; fi
            done
            [[ ${#missing[@]} -eq 0 ]] && break
            problem="no usable answer for: ${missing[*]} — answer asked, not an assertion or unasked for each line, one list item each, starting with its file and line number"
        done
        left+=(${missing[@]+"${missing[@]}"})
    done
    [[ -n "$rc_file" ]] && { router_rc="$(cat "$rc_file" 2>/dev/null || printf 0)"; rm -f "$rc_file"; }
    # The answers for the lines there now, kept for the next try.
    # Rewritten only when it changes, in the lines' order (the same each try).
    if [[ -n "$kf" ]]; then
        local out=""
        for l in "${lines[@]}"; do
            key="${keyof[$l]}"
            [[ "${now[$key]:-}" == ok$'\t'* ]] && out+="$key"$'\t'"${now[$key]}"$'\n'
        done
        [[ "$out" == "$old" ]] || { printf '%s' "$out" > "$kf.tmp.$$" 2>/dev/null && mv -f "$kf.tmp.$$" "$kf" 2>/dev/null || rm -f "$kf.tmp.$$" 2>/dev/null; }
    fi
    for l in "${lines[@]}"; do
        v="${now[${keyof[$l]}]:-}"; v="${v%$'\t'}"
        [[ -n "$v" && "$v" != ok ]] || continue
        local _ta_f=""; _ta_unasked_finding_v _ta_f "${l%%: *}" "$v"
        _TA_UNASKED_FINDINGS+=("$_ta_f")
    done
    if [[ "$router_rc" =~ ^[1-9][0-9]*$ ]]; then
        local _rv _rr
        _router_rc_classify "$router_rc" _rv _rr 2>/dev/null || true
        # disposition-ok: the model router is not responding
        _TA_CORR_OUTCOME="$(router_reason_disposition "${_rr:-}" 2>/dev/null || true)"
        [[ -n "$_TA_CORR_OUTCOME" ]] || _TA_CORR_OUTCOME="unavailable"
        _TA_CORR_WHAT="$_TA_UNASKED_WHAT"
    elif [[ ${#left[@]} -gt 0 ]]; then
        _TA_CORR_OUTCOME=unusable
        _TA_CORR_WHAT="$_TA_UNASKED_WHAT (${#left[@]} line(s) left unjudged: ${left[*]:0:3})"
    fi
    return 0
}

# _ta_unasked_answer_v <var> <reply> <key> — the answer for one line: "ok"
# (asked, or not an assertion), the WHY of an unasked one, or empty (none). An
# asked answer must name a SPEC of this contract or a step that is there.
_ta_unasked_answer_v() {
    local -n _tua="$1"; local l w
    _tua=""
    while IFS= read -r l; do
        l="${l#"${l%%[![:space:]*\`-]*}"}"; l="${l//\`/}"
        [[ "$l" == "$3:"* ]] || continue
        l="${l#"$3:"}"; l="${l#"${l%%[![:space:]]*}"}"
        case "$l" in
            "not an assertion"*) _tua=ok ;;
            asked*)
                if [[ "$l" =~ \|[[:space:]]*STEP:[[:space:]]*([0-9]+(\.[0-9]+)?) ]]; then
                    [[ "${_TA_UQ_LABELS:- }" == *" ${BASH_REMATCH[1]} "* ]] && _tua=ok
                elif [[ "$l" =~ \|[[:space:]]*SPEC:[[:space:]]*([^][[:space:]|]+) ]]; then
                    [[ "$_TA_UQ_IDS" == *" ${BASH_REMATCH[1]} "* ]] && _tua=ok
                fi ;;
            unasked*)
                judge_reply_field_v w "$l" WHY
                _tua="${w:-nothing names it}" ;;
        esac
        [[ -n "$_tua" ]] && return 0
    done <<< "$2"
    return 0
}
