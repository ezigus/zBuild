#!/usr/bin/env bash
# scripts/lib/abort-propagation.sh — ADR-025 abort-propagation contract (Wave 15-B, #684)
#
# An abort is RECORDED once, as a word, and every dispatcher asks for it at the
# same two points in its loop (#1850, ADR-054 §4 — no rc carries the reason):
#
#   loop {
#       _zbuild_check_abort || return 1             # pre-flight
#       dispatch_child
#       _zbuild_propagate_abort $? || return 1      # post-flight
#   }
#
# Words: sigint | sigterm | cycle_abort | llm_unavailable | llm_rate_limited |
# scope_too_large. The first recorded abort wins.
#
# Two channels hold the word: `_ZB_ABORT_REASON` in this process, and the
# sentinel file ${ZBUILD_STATE_DIR}/.abort.signal, which crosses subshells and
# `_zbuild_make_fresh_shell` env scrubs (ADR-024) where a variable does not.
# An EMPTY sentinel reads as `sigint` — what arming wrote before it took a word.
#
# Sourced library: no `set -euo pipefail` (would mutate caller options).

[[ -n "${_ZBUILD_ABORT_PROP_LOADED:-}" ]] && return 0
_ZBUILD_ABORT_PROP_LOADED=1

# Empty when ZBUILD_STATE_DIR is unset: the helpers then keep the word in-process
# only, rather than fabricate a path under cwd.
_zbuild_abort_sentinel_path() {
    if [[ -n "${ZBUILD_STATE_DIR:-}" ]]; then
        printf '%s/.abort.signal' "$ZBUILD_STATE_DIR"
    fi
}

_zbuild_abort_reason() {
    if [[ -n "${_ZB_ABORT_REASON:-}" ]]; then
        printf '%s' "$_ZB_ABORT_REASON"
        return 0
    fi
    local _sentinel _word=""
    _sentinel="$(_zbuild_abort_sentinel_path)"
    [[ -n "$_sentinel" && -e "$_sentinel" ]] || return 0
    IFS= read -r _word 2>/dev/null < "$_sentinel" || true
    printf '%s' "${_word:-sigint}"
}

# Best-effort: a failed sentinel write must not fail a signal trap — the
# in-process word still holds the abort.
_zbuild_arm_abort_sentinel() {
    local _word="${1:-sigint}" _sentinel _dir _prior
    _prior="$(_zbuild_abort_reason)"
    if [[ -n "$_prior" ]]; then
        _ZB_ABORT_REASON="$_prior"
        return 0
    fi
    _ZB_ABORT_REASON="$_word"
    _sentinel="$(_zbuild_abort_sentinel_path)"
    [[ -z "$_sentinel" ]] && return 0
    _dir="$(dirname "$_sentinel")"
    [[ -d "$_dir" ]] || mkdir -p "$_dir" 2>/dev/null || return 0
    printf '%s\n' "$_word" > "$_sentinel" 2>/dev/null || true
    return 0
}

# Called by the runner's EXIT trap and by --resume, so a later run in the same
# state dir does not see a stale abort.
_zbuild_disarm_abort_sentinel() {
    local _sentinel
    unset _ZB_ABORT_REASON
    _sentinel="$(_zbuild_abort_sentinel_path)"
    [[ -z "$_sentinel" ]] && return 0
    [[ -e "$_sentinel" ]] && rm -f "$_sentinel" 2>/dev/null || true
    return 0
}

# Returns 1 so a caller can write `_zbuild_abort <word>; return` or `|| return 1`.
_zbuild_abort() {
    _zbuild_arm_abort_sentinel "${1:-sigint}"
    return 1
}

_zbuild_check_abort() {
    [[ -n "$(_zbuild_abort_reason)" ]] && return 1
    return 0
}

# 1 only when the child failed AND an abort is recorded: an ordinary failure is
# the caller's to handle, and a child that succeeded is not an abort.
_zbuild_propagate_abort() {
    [[ "${1:-0}" == "0" ]] && return 0
    _zbuild_check_abort
}
