#!/usr/bin/env bash
# plugins/agent/test-author/lib/before-run.sh — test-author's own script runs
# the test files its model call created or changed on the code from before this
# change, and lists which requirements each test file already covers (#2445,
# ADR-068 §6).
#
# The model writes tests and runs nothing; whether a test fails where it must is
# measured here, never taken from the model. A [code] requirement's test must
# fail on that code; one that passes there, or a file that stops before its
# assertion runs, is a finding — and only findings send the model round again.
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
# every test file the contract names, taken before and after the model call.
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

# _ta_written_list <design_md> <repo> — for the prompt: each test file and the
# requirements of this contract whose tag it already holds.
_ta_written_list() {
    local design="$1" repo="$2" tf sid have
    while IFS= read -r tf; do
        [[ -n "$tf" ]] || continue
        have=""
        if [[ -f "$repo/$tf" ]]; then
            while IFS= read -r sid; do
                [[ -n "$sid" ]] || continue
                grep -qF -- "$(acceptance_spec_tag "$sid")" "$repo/$tf" 2>/dev/null && have+="${have:+, }$sid"
            done < <(acceptance_list_spec_ids "$design" 2>/dev/null || true)
        fi
        printf -- '- %s: %s\n' "$tf" "${have:-none yet}"
    done < <(acceptance_list_testfiles "$design" 2>/dev/null || true)
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
    _ta_testfile_sums_v after "$design" "$repo"
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
    local log rc sid st v
    local _nf
    for tf in "${changed[@]}"; do
        _nf=${#_TA_BEFORE_FINDINGS[@]}
        mkdir -p "$wt/$(dirname "$tf")"
        cp "$repo/$tf" "$wt/$tf" 2>/dev/null || continue
        log="$(mktemp "$(zbuild_engine_tmpdir)/zb-ta-run.XXXXXX")" || continue
        rc=0; _negctl_run "$wt/$tf" "$wt" "$log" || rc=$?
        while IFS= read -r sid; do
            [[ -n "$sid" ]] || continue
            grep -qxF -- "$tf" <<< "$(acceptance_list_testfiles_for_spec "$design" "$sid" 2>/dev/null)" || continue
            st="$(acceptance_spec_status "$design" "$sid" 2>/dev/null || true)"
            [[ "$st" == "done" ]] && continue
            v=0; _negctl_spec_log_check "$log" "$sid" || v=$?
            if [[ "$v" -eq 1 && "$st" != no-code ]]; then
                _TA_BEFORE_FINDINGS+=("$sid: $tf passes on the code from before this change — a requirement that needs code must have a test that fails there")
            elif [[ "$v" -eq 2 && "$rc" -ne 0 ]]; then
                _TA_BEFORE_FINDINGS+=("$sid: $tf stopped before $sid's assertion ran on the code from before this change (exit $rc): $(_ta_log_tail "$log")")
            elif [[ "$v" -eq 2 ]]; then
                _TA_BEFORE_FINDINGS+=("$sid: $tf holds no assertion tagged $(acceptance_spec_tag "$sid") that ran")
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
