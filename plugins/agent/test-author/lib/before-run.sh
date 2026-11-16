#!/usr/bin/env bash
# plugins/agent/test-author/lib/before-run.sh — test-author's own script runs
# the test files its model call created or changed on the code from before this
# change, and lists which requirements each test file already covers (#2445,
# ADR-068 §6).
#
# The model writes tests and runs nothing but a test file of its own it is told
# fails (#2506); whether a test fails where it must is measured here, never
# taken from the model. A [code] requirement's test must
# fail on that code; one that passes there, or a file whose output holds no
# line tagged for its SPEC, is a finding — and only findings send the model
# round again. #2554 (ADR-069): it reads only the tag contract, never a file's
# exit code (a test file exits with its count of failures, not "stopped").
#
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_TA_BEFORE_RUN_LOADED:-}" ]] && return 0
_ZBUILD_TA_BEFORE_RUN_LOADED=1

# #2010: zbuild_engine_tmpdir names where engine code writes temp files.
if ! declare -F zbuild_engine_tmpdir >/dev/null 2>&1; then
    # shellcheck source=../../../../scripts/lib/helpers.sh
    source "$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; pwd)/../../../../scripts/lib/helpers.sh"
fi

# _ta_testfile_sums_v <var> <design_md> <repo> — "<file>\t<cksum|absent>" for
# every test file holding a SPEC's tag (#2508: found by tag, never named by
# design), taken before and after the model call.
_ta_testfile_sums_v() {
    local -n _tts="$1"; _tts=""
    local tf sum
    while IFS= read -r tf; do
        # Only a path inside the repository is ever summed, copied or run
        # (review on #2446): the same rule design's checks apply.
        [[ -n "$tf" && "$tf" != /* && "/$tf/" != *"/../"* ]] || continue
        if [[ -f "$3/$tf" ]]; then sum="$(cksum 2>/dev/null < "$3/$tf" || printf 'absent')"; else sum="absent"; fi
        _tts+="$tf"$'\t'"$sum"$'\n'
    done < <(acceptance_list_testfiles "$2" 2>/dev/null || true)
}

# _ta_written_list <design_md> <repo> [needed ids] — for the prompt: each test
# file and the requirements of this contract whose tag it already holds, then
# the needed ones no file holds yet (#2506: a gap shown only by its absence
# was missed).
_ta_written_list() {
    local design="$1" repo="$2" tf sid have found=" " missing=""
    while IFS= read -r tf; do
        [[ -n "$tf" && "$tf" != /* && "/$tf/" != *"/../"* ]] || continue
        have=""
        if [[ -f "$repo/$tf" ]]; then
            while IFS= read -r sid; do
                [[ -n "$sid" ]] || continue
                local -a _brt=(); acceptance_spec_tags_v _brt "$sid"
                grep -qF "${_brt[@]/#/-e}" "$repo/$tf" 2>/dev/null && { have+="${have:+, }$sid"; found+="$sid "; }
            done < <(acceptance_list_spec_ids "$design" 2>/dev/null || true)
        fi
        printf -- '- %s: %s\n' "$tf" "${have:-none yet}"
    done < <(acceptance_list_testfiles "$design" 2>/dev/null || true)
    for sid in ${3:-}; do
        [[ "$found" == *" $sid "* ]] || missing+="${missing:+, }$sid"
    done
    printf 'Not written yet: %s\n' "${missing:-none}"
}

# _ta_before_run <design_md> <repo> <sums_before> — sets _TA_BEFORE_FINDINGS:
# what running the changed test files on the code from before this change found.
# A file the last round found something in is run again even if the call left
# it as it was: an open finding is not closed by silence.
_TA_BEFORE_OPEN=""
_ta_before_run() {
    local design="$1" repo="$2" before="$3"
    _TA_BEFORE_FINDINGS=()
    local after tf sum was
    local -a changed=()
    local -A _brf=()
    _ta_testfile_sums_v after "$design" "$repo"
    acceptance_spec_files_v _brf "$design" "$repo"
    while IFS=$'\t' read -r tf sum; do
        [[ -n "$tf" && "$sum" != absent ]] || continue
        was=""
        while IFS=$'\t' read -r _bf _bs; do [[ "$_bf" == "$tf" ]] && { was="$_bs"; break; }; done <<< "$before"
        if [[ "$sum" != "$was" || $'\n'"$_TA_BEFORE_OPEN" == *$'\n'"$tf"$'\n'* ]]; then changed+=("$tf"); fi
    done <<< "$after"
    _TA_BEFORE_OPEN=""
    [[ ${#changed[@]} -gt 0 ]] || return 0

    local base; base="$(zbuild_resolve_merge_base "$repo" 2>/dev/null || true)"
    [[ -n "$base" ]] || return 0
    local wt; wt="$(mktemp -d "$(zbuild_engine_tmpdir)/zb-ta-before.XXXXXX")" || return 0
    if ! git -C "$repo" worktree add --detach "$wt" "$base" >/dev/null 2>&1; then
        rm -rf "${wt:?}"; return 0
    fi
    local log sid st v
    local _nf
    for tf in "${changed[@]}"; do
        _nf=${#_TA_BEFORE_FINDINGS[@]}
        mkdir -p "$wt/$(dirname "$tf")"
        cp "$repo/$tf" "$wt/$tf" 2>/dev/null || continue
        log="$(mktemp "$(zbuild_engine_tmpdir)/zb-ta-run.XXXXXX")" || continue
        _negctl_run "$wt/$tf" "$wt" "$log" || true
        while IFS= read -r sid; do
            [[ -n "$sid" ]] || continue
            [[ " ${_brf[$sid]:-} " == *" $tf "* ]] || continue
            st="$(acceptance_spec_status "$design" "$sid" 2>/dev/null || true)"
            v=0; _negctl_spec_log_check "$log" "$sid" || v=$?
            if [[ "$v" -eq 0 && "$st" == "done" ]]; then
                # #2517: the old code is said to do it, so its test passes there.
                _TA_BEFORE_FINDINGS+=("$sid: $tf fails on the code from before this change, which the design says already does this — the test or the [done] is wrong")
            elif [[ "$v" -eq 1 && "$st" != no-code && "$st" != "done" ]]; then
                _TA_BEFORE_FINDINGS+=("$sid: $tf passes on the code from before this change — a requirement that needs code must have a test that fails there")
            elif [[ "$v" -eq 2 ]]; then
                _TA_BEFORE_FINDINGS+=("$sid: no line tagged $(acceptance_spec_tag "$sid") appeared in $tf's output on the code from before this change: $(_ta_log_tail "$log")")
            fi
        done < <(acceptance_list_spec_ids "$design" 2>/dev/null || true)
        rm -f "$log"
        (( ${#_TA_BEFORE_FINDINGS[@]} > _nf )) && _TA_BEFORE_OPEN+="$tf"$'\n'
    done
    git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1 || true
    rm -rf "${wt:?}" 2>/dev/null || true
    return 0
}

# _ta_log_tail <log> — the last lines of a run, on one line, for a finding.
_ta_log_tail() {
    local t; t="$(LC_ALL=C sed -E $'s/\x1b\\[[0-9;?]*[a-zA-Z~]//g' "$1" 2>/dev/null | tail -n 3)"
    t="${t//$'\n'/ | }"
    printf '%s' "${t:0:300}"
}

# _ta_tag_shape <design_md> <repo> — sets _TA_TAG_FINDINGS (#2554, ADR-036): on
# the lines this branch added to its test files (ADR-069 §11, the same lines
# the stale-tag step reads), text shaped like a tag for more than one SPEC —
# `[DSCLA-1/5]`, `[DSCLA-1, DSCLA-5]` — and two tags side by side in one label.
# Text that only mentions an id (`[[ $id == X-1 ]]`, `'\[X-1\]'`, JSON) is not
# shaped like a tag and is left alone. At most 10 findings, then a count.
_ta_tag_shape() {
    local design="$1" repo="$2" ids="" id issue="${ZBUILD_ISSUE:-}" tf line n=0 extra=0
    _TA_TAG_FINDINGS=()
    while IFS= read -r id; do [[ -n "$id" ]] && ids+="${ids:+ }$id"; done \
        < <(acceptance_list_spec_ids "$design" 2>/dev/null || true)
    [[ -n "$ids" ]] || return 0
    # The tag reader's own rule: this issue's [#<n>/<id>] only for a real issue.
    [[ "$issue" =~ ^[1-9][0-9]*$ ]] || issue=""
    local -A _tsl=()
    if [[ "${_TA_BRANCH_LINES_REPO:-}" == "$repo" ]]; then
        for tf in "${!_TA_BRANCH_LINES[@]}"; do _tsl[$tf]="${_TA_BRANCH_LINES[$tf]}"; done
    else
        zb_test_folder_branch_lines_v _tsl "$repo"
    fi
    # The files in a fixed order, so the findings are the same each try.
    local -a order=(); local i
    for tf in "${!_tsl[@]}"; do
        i=${#order[@]}
        while (( i > 0 )) && [[ "${order[i-1]}" > "$tf" ]]; do order[i]="${order[i-1]}"; i=$((i - 1)); done
        order[i]="$tf"
    done
    for tf in ${order[@]+"${order[@]}"}; do
        [[ -f "$repo/$tf" ]] || continue
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            if (( n < 10 )); then _TA_TAG_FINDINGS+=("$line"); n=$((n + 1)); else extra=$((extra + 1)); fi
        done < <(LC_ALL=C awk -v ids="$ids" -v issue="$issue" -v f="$tf" -v lines=" ${_tsl[$tf]} " '
            BEGIN {
                all = (lines ~ / all /)
                k = split(ids, a, " ")
                for (i = 1; i <= k; i++) { ok[a[i]] = 1; alt = alt (alt ? "|" : "") a[i] }
                bad = "^(#[0-9]+/)?(" alt ")[/, ][A-Za-z0-9#/, -]*$"
            }
            function valid(c,    r) {
                if (c in ok) return 1
                if (issue != "" && index(c, "#" issue "/") == 1) { r = substr(c, length(issue) + 3); return (r in ok) }
                return 0
            }
            !all && index(lines, " " FNR " ") == 0 { next }
            {
                rest = $0; prev = ""
                while (match(rest, /\[[^][]*\]/)) {
                    t = substr(rest, RSTART, RLENGTH); c = substr(t, 2, RLENGTH - 2)
                    v = valid(c); side = (substr(rest, 1, RSTART - 1) ~ /^[ \t]*$/)
                    if (v && prev != "" && side)
                        printf "%s line %d holds two tags (%s, %s) — one tag per line: write the assertion once for each SPEC\n", f, FNR, prev, t
                    if (!v && c ~ bad)
                        printf "%s line %d: %s is not a tag — a tag names one SPEC: [<id>]. An assertion that proves two SPECs is written twice, one line per SPEC, each with its own tag\n", f, FNR, t
                    prev = v ? t : ""
                    rest = substr(rest, RSTART + RLENGTH)
                }
            }' "$repo/$tf" 2>/dev/null)
    done
    (( extra > 0 )) && _TA_TAG_FINDINGS+=("and $extra more lines like these in the test files — fix each the same way")
    return 0
}
