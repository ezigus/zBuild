#!/usr/bin/env bash
# plugins/agent/review-lens/lib/result.sh — the result a lens that reviewed
# nothing writes, the notes it saved, and its signal handler (ADR-055 §3, ADR-063 §3).
# Split from plugin.sh (#2571: under 500 lines); its callers are there.
#
# Sourced library: inherits the caller's pipefail/errexit; do not set them here.

[[ -n "${_ZBUILD_REVIEW_LENS_RESULT_LOADED:-}" ]] && return 0
_ZBUILD_REVIEW_LENS_RESULT_LOADED=1

# ─── _review_lens_write_result <out> <verdict> <disposition> <reason> ────────
# Write a v2-compliant lens result file atomically. The output path is derived
# entirely from the $out parameter (no literal artifact filename strings inside).
# Called on every terminal exit path (degrade + success) so the file is always
# on disk — ADR-055 §3. Verdict appears here as a jq field, not a coercion token.
# _review_lens_saved_notes <artifact_dir> — what this lens saved as it went
# (#2270), capped; empty when nothing was saved. A call cut off by time, turns
# or a signal returns nothing; this is all it leaves.
_review_lens_saved_notes() {
    local cp
    declare -F stage_notes_path >/dev/null 2>&1 || return 0
    # The lens's notes file (ADR-067 §8), found in the artifacts folder it was
    # given, whatever that folder is called.
    cp="$(stage_notes_path "/_rl_sd" "${ZBUILD_CURRENT_STAGE:-review_lenses}")"
    cp="${1%/}/${cp#/_rl_sd/artifacts/}"
    [[ -s "$cp" ]] || return 0
    head -c 4000 "$cp" 2>/dev/null || true
}

# #2366 (contract 3): a lens that reviewed nothing — score 0, no findings — with
# the outcome saying how it ended; any partial notes under data.
_review_lens_write_result() {
    local out="$1" outcome="$2" reason="$3" notes="${4:-}"
    local _base _name
    _base="$(basename "$out")"
    _name="${_base%.json}"; _name="${_name#lens-}"
    # Built beside the result and written to it ONCE: a signal that reaches the
    # trap and the rc=130 branch must still leave exactly one write (#2165).
    local _tmp="${out%/*}/.review-lens-result.$BASHPID.tmp"
    # #2571 (ADR-038): a lens that ends before its call judged them keeps the
    # questions it carried.
    jq -nc \
        --arg n "$_name" \
        --arg pn "$notes" \
        --argjson u "${_RL_UQ_JSON:-[]}" \
        '{schema_version:1, name:$n, score:0, findings:[]}
         + (if $pn != "" or ($u | length) > 0 then {data:((if $pn != "" then {partial_notes:$pn} else {} end)
             + (if ($u | length) > 0 then {unclear:$u} else {} end))} else {} end)' > "$_tmp" 2>/dev/null \
        && stage_result_add "$_tmp" "$outcome" "$reason" 2>/dev/null \
        && atomic_write "$out" 2>/dev/null < "$_tmp"
    rm -f "$_tmp" 2>/dev/null || true
}

# ─── _review_lens_interrupt_handler ──────────────────────────────────────────
# Trap handler for SIGTERM/SIGINT: write disposition:interrupted and propagate.
# Reads $_rl_out_ref (set by _review_lens_run_inner before trap registration)
# so it can be invoked directly in tests for SIGTERM simulation (SPEC-13).
_review_lens_interrupt_handler() {
    _review_lens_write_result "${_rl_out_ref:-}" \
        "${1:-$STAGE_SIGNAL_DISPOSITION}" "${2:-$STAGE_SIGNAL_REASON}" \
        "$(_review_lens_saved_notes "${_rl_out_ref%/*}")"
    # Ctrl-C reaches the whole process group: this trap fires AND the router
    # subshell returns 130. Record the write so the rc=130 branch skips its own.
    _rl_interrupted=1
}
