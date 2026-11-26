#!/usr/bin/env bash
# scripts/lib/stage-stop-word.sh — the word a run ends on when a stage stopped
# it, cleaned (#2582, ADR-054 §6). Moved from runner.sh (#2611): a loop member
# that stops the run is named with it too, and a word is never left uncleaned.
#
# Sourced library: no set -euo pipefail.
[[ -n "${_ZBUILD_STAGE_STOP_WORD_LOADED:-}" ]] && return 0
_ZBUILD_STAGE_STOP_WORD_LOADED=1
_ZB_SSW_DIR="${BASH_SOURCE[0]%/*}"   # no process at load (ADR-065 §5)

# ─── _runner_stage_stop_word_v <var> <stage> <reason> (#2582) ────────────────
# The word a run ends on when a stage stopped it (ADR-054 §6): the stage and its
# own reason, `stage_stopped:<stage>:<reason>` — one line, capped, as the abort
# sentinel and the events hold it. run_end_words says it in words. The reason
# leaves the machine (the events, the state, the comments), so it is cleaned
# first: credentials masked (secret-patterns.sh), private paths taken out (the
# scope redactor); one that cannot be cleaned is not shown.
_runner_stage_stop_word_v() {
    local -n _rssw="$1"; local _rssw_r="${3:-}" _rssw_in _rssw_out _rssw_c=""
    _rssw_r="${_rssw_r//[$'\n\r\t']/ }"
    if [[ -n "$_rssw_r" ]]; then
        declare -F zbuild_mask_secrets_v >/dev/null 2>&1 \
            || source "$_ZB_SSW_DIR/secret-patterns.sh" 2>/dev/null || true
        declare -F apply_scope_redaction >/dev/null 2>&1 \
            || source "$_ZB_SSW_DIR/../../core/redaction/scope-redaction.sh" 2>/dev/null || true
        if declare -F zbuild_mask_secrets_v >/dev/null 2>&1 && declare -F apply_scope_redaction >/dev/null 2>&1 \
           && _rssw_in="$(mktemp "${TMPDIR:-/tmp}/zb-stop-in.XXXXXX")"; then
            _rssw_out="$_rssw_in.out"
            zbuild_mask_secrets_v _rssw_r "$_rssw_r"
            printf '%s\n' "$_rssw_r" > "$_rssw_in"
            apply_scope_redaction "$_rssw_in" "$_rssw_out" "" "" 0 >/dev/null 2>&1 \
                && IFS= read -r _rssw_c < "$_rssw_out"
            rm -f "$_rssw_in" "$_rssw_out"
        fi
        _rssw_r="${_rssw_c:-its reason could not be cleaned, so it is not shown}"
    fi
    (( ${#_rssw_r} > 300 )) && _rssw_r="${_rssw_r:0:300}…"
    _rssw="stage_stopped:${2:-a stage}:${_rssw_r:-it gave no reason}"
}
