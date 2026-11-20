#!/usr/bin/env bash
# plugins/agent/test-author/lib/unasked.sh — test-author's own check refuses an
# assertion its branch added that names no SPEC and tests what no SPEC asks
# for (#2575, ADR-069). A test for a change nothing asks for pins that change.
#
# The lines are found by script: the lines this branch added to the test
# folders (zb_test_folder_branch_lines_v) that read as a check — a call named
# assert…, expect or refute, or a ✓/✗ mark — and carry no tag of a SPEC of this
# contract. Whether each tests something a SPEC asks for is judged by the
# assertion check's call (_sc_call), with every SPEC shown.
#
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_TA_UNASKED_LOADED:-}" ]] && return 0
_ZBUILD_TA_UNASKED_LOADED=1

# At most this many lines are judged in one try; the rest wait for the next.
_TA_UNASKED_MAX=30

# _ta_unasked_lines_v <array> <design> <repo> — "<file> line <n>: <text>" for
# each line this branch added to a test file that reads as a check and carries
# no tag of this contract.
_ta_unasked_lines_v() {
    local -n _tul="$1"; local design="$2" repo="$3" ids="" id tf issue="${ZBUILD_ISSUE:-}" line
    _tul=()
    while IFS= read -r id; do [[ -n "$id" ]] && ids+="${ids:+ }$id"; done \
        < <(acceptance_list_spec_ids "$design" 2>/dev/null || true)
    [[ -n "$ids" ]] || return 0
    [[ "$issue" =~ ^[1-9][0-9]*$ ]] || issue=""
    local -A _tsl=()
    if [[ "${_TA_BRANCH_LINES_REPO:-}" == "$repo" ]]; then
        for tf in "${!_TA_BRANCH_LINES[@]}"; do _tsl[$tf]="${_TA_BRANCH_LINES[$tf]}"; done
    else
        zb_test_folder_branch_lines_v _tsl "$repo"
    fi
    local -a order=(); local i
    for tf in "${!_tsl[@]}"; do
        i=${#order[@]}
        while (( i > 0 )) && [[ "${order[i-1]}" > "$tf" ]]; do order[i]="${order[i-1]}"; i=$((i - 1)); done
        order[i]="$tf"
    done
    local -a files=() lists=()
    for tf in ${order[@]+"${order[@]}"}; do
        [[ -f "$repo/$tf" ]] || continue
        files+=("$repo/$tf"); lists+=("$tf=${_tsl[$tf]}")
    done
    [[ ${#files[@]} -gt 0 ]] || return 0
    local joined; printf -v joined '%s\x1f' "${lists[@]}"
    # One awk over every file: the tag reader's own rule (_ta_tag_shape).
    while IFS= read -r line; do
        [[ -n "$line" ]] && (( ${#_tul[@]} < _TA_UNASKED_MAX )) && _tul+=("$line")
    done < <(LC_ALL=C awk -v ids="$ids" -v issue="$issue" -v root="$repo/" -v lists="$joined" -v ck="✓" -v cx="✗" '
        BEGIN {
            k = split(ids, a, " "); for (i = 1; i <= k; i++) ok[a[i]] = 1
            m = split(lists, L, "\037")
            for (i = 1; i <= m; i++) { p = index(L[i], "="); if (p) want[substr(L[i], 1, p - 1)] = " " substr(L[i], p + 1) " " }
        }
        function valid(c,    r) {
            if (c in ok) return 1
            if (issue != "" && index(c, "#" issue "/") == 1) { r = substr(c, length(issue) + 3); return (r in ok) }
            return 0
        }
        FNR == 1 { f = substr(FILENAME, length(root) + 1); w = want[f] }
        w !~ / all / && index(w, " " FNR " ") == 0 { next }
        /^[ \t]*(#|\/\/)/ { next }
        !/(^|[^A-Za-z0-9_])(assert[A-Za-z0-9_]*|expect|refute)([^A-Za-z0-9_]|$)/ && !index($0, ck) && !index($0, cx) { next }
        {
            rest = $0; tagged = 0
            while (match(rest, /\[[^][]*\]/)) {
                if (valid(substr(rest, RSTART + 1, RLENGTH - 2))) { tagged = 1; break }
                rest = substr(rest, RSTART + RLENGTH)
            }
            if (!tagged) { t = $0; sub(/^[ \t]+/, "", t); printf "%s line %d: %s\n", f, FNR, t }
        }' "${files[@]}" 2>/dev/null)
    return 0
}

# _ta_unasked_prompt <design> <lines_array> — the check's question: every SPEC,
# and the lines to judge.
_ta_unasked_prompt() {
    local design="$1"; local -n _tup="$2"; local sid blk l
    cat <<'EOF'
You are checking test lines this branch added that carry no requirement's tag.

## What you own
A test or an assertion must trace to a SPEC below: a test for a change no SPEC asks for pins that change. For EACH line listed under THE LINES, decide whether it is an assertion — a check that can fail — and if so whether it tests something one of the SPECs asks for. Open the test file to see what the line checks. Answer one line for each, starting with its file and line number exactly as listed:

<file> line <n>: asked | SPEC: <the identifier of the SPEC it tests>
<file> line <n>: not an assertion
<file> line <n>: unasked | WHY: <what it tests, and why no SPEC asks for it>

## What you judge against
THE SPECS:
EOF
    blk="$(extract_acceptance_block "$design" 2>/dev/null)" || blk=""
    while IFS= read -r sid; do
        [[ -n "$sid" ]] || continue
        _acceptance_spec_line "$blk" "$sid" && printf -- '- %s: %s\n' "$sid" "$_ACC_SPEC_TEXT"
    done < <(acceptance_list_spec_ids "$design" 2>/dev/null || true)
    printf '\nTHE LINES:\n'
    for l in "${_tup[@]}"; do printf -- '- %s\n' "$l"; done
    cat <<'EOF'

## What you must not do
- Judge what each test does, not the code it tests.
- Do not suggest a fix. Do not rewrite anything.
EOF
}

# _ta_unasked <design> <repo> <tier> — sets _TA_UNASKED_FINDINGS, one per line
# the check finds no SPEC asks for. A line with no usable answer is asked again
# once; one still unanswered, or a call that failed, leaves _TA_CORR_OUTCOME set
# as the assertion check's own failure does (#2062: no answer, no pass).
_ta_unasked() {
    local design="$1" repo="$2" tier="${3:-T2}" l key why task raw problem="" rc_file router_rc=0 tries=0
    local -a lines=() missing=()
    _TA_UNASKED_FINDINGS=()
    _ta_unasked_lines_v lines "$design" "$repo"
    [[ ${#lines[@]} -gt 0 ]] || return 0
    task="$(_ta_unasked_prompt "$design" lines)"
    rc_file="$(mktemp 2>/dev/null)" || rc_file=""
    [[ -n "$rc_file" ]] && printf '0' > "$rc_file"
    raw=""
    while (( tries < 2 )); do
        tries=$((tries + 1))
        if [[ -n "$problem" ]]; then raw="$(_sc_call "$tier" "$task" "$rc_file" "$problem" "$raw")"
        else raw="$(_sc_call "$tier" "$task" "$rc_file")"; fi
        zb_reply_join_v raw "$raw"
        _TA_UNASKED_FINDINGS=(); missing=()
        for l in "${lines[@]}"; do
            key="${l%%: *}"
            _ta_unasked_answer_v why "$raw" "$key"
            case "$why" in
                "") missing+=("$key") ;;
                ok) ;;
                *) _TA_UNASKED_FINDINGS+=("$key tests something no SPEC asks for ($why) — take it out: a test must trace to a SPEC, and a test for a change no SPEC asks for is not yours. If a SPEC does ask for it, tag the assertion with that SPEC") ;;
            esac
        done
        [[ ${#missing[@]} -eq 0 ]] && break
        problem="no usable answer for: ${missing[*]} — answer asked, not an assertion or unasked for each line, starting with its file and line number"
    done
    [[ -n "$rc_file" ]] && { router_rc="$(cat "$rc_file" 2>/dev/null || printf 0)"; rm -f "$rc_file"; }
    if [[ "$router_rc" =~ ^[1-9][0-9]*$ ]]; then
        local _rv _rr
        _router_rc_classify "$router_rc" _rv _rr 2>/dev/null || true
        # disposition-ok: the model router is not responding
        _TA_CORR_OUTCOME="$(router_reason_disposition "${_rr:-}" 2>/dev/null || true)"
        [[ -n "$_TA_CORR_OUTCOME" ]] || _TA_CORR_OUTCOME="unavailable"
    elif [[ ${#missing[@]} -gt 0 ]]; then
        _TA_CORR_OUTCOME=unusable
    fi
    return 0
}

# _ta_unasked_answer_v <var> <reply> <key> — the answer for one line: "ok"
# (asked, or not an assertion), the WHY of an unasked one, or empty (none).
_ta_unasked_answer_v() {
    local -n _tua="$1"; local l w
    _tua=""
    while IFS= read -r l; do
        l="${l#"${l%%[![:space:]*\`-]*}"}"; l="${l//\`/}"
        [[ "$l" == "$3:"* ]] || continue
        l="${l#"$3:"}"; l="${l#"${l%%[![:space:]]*}"}"
        case "$l" in
            asked*|"not an assertion"*) _tua=ok ;;
            unasked*)
                judge_reply_field_v w "$l" WHY
                _tua="${w:-no SPEC names it}" ;;
        esac
        [[ -n "$_tua" ]] && return 0
    done <<< "$2"
    return 0
}
