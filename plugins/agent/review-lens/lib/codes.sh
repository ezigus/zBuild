#!/usr/bin/env bash
# plugins/agent/review-lens/lib/codes.sh — the code a lens's findings' ids
# take (#2574, ADR-068 §5). Sourced by plugin.sh.
#
# A lens keeps no verdict and holds no pass (#2584, ADR-072 §4 §5, amended
# 2026-11-22): every round reviews the whole change.
#
# Sourced library: inherits the caller's pipefail/errexit; do not set them here.

[[ -n "${_ZBUILD_REVIEW_LENS_CODES_LOADED:-}" ]] && return 0
_ZBUILD_REVIEW_LENS_CODES_LOADED=1

# _rl_finding_code_v <var> <lens> — the code a lens's findings' ids take
# (#2574, ADR-068 §5): the stage's prefix and the lens's whole name, its
# letters and digits in upper case (RLSRE, RLREDTEAM, RLCORRECTNESS), so two
# lenses' codes are never the same (second review on #2574: by construction).
_rl_finding_code_v() {
    local -n _rfc="$1"; local _rfc_t="${2^^}"
    _rfc_t="${_rfc_t//[^A-Z0-9]/}"
    [[ "$_rfc_t" =~ ^[A-Z] ]] || _rfc_t="L$_rfc_t"
    zb_finding_code_v _rfc "$_RL_DIR/manifest.yaml" "$_rfc_t"
}

# _rl_lens_code_ok_v <var> <lens> <out> — the lens's code (_rl_finding_code_v),
# and rc 1, its result written misconfigured, when it cannot be one of its own:
# it is longer than a code may be, or another lens of the run (its map group's
# elements) takes the same one (`red-team` and `red_team`). No program.
_rl_lens_code_ok_v() {
    local -n _rlc="$1"; local lens="$2" out="$3" mv e c why=""
    _rl_finding_code_v _rlc "$lens"
    (( ${#_rlc} <= 24 )) || why="the $lens lens's name is too long for its findings' code ($_rlc)"
    mv="_TPL_MAP_ELEMENTS_${ZBUILD_CURRENT_STAGE:-none}"; mv="${mv//[^A-Za-z0-9_]/_}"
    local els="${!mv:-}"
    for e in ${els//,/ }; do
        [[ -z "$why" && "$e" != "$lens" ]] || continue
        _rl_finding_code_v c "$e"; [[ "$c" == "$_rlc" ]] && why="the $lens and $e lenses' findings would both take the code $_rlc"
    done
    [[ -z "$why" ]] && return 0
    error "$why — rename one (#2574)"
    _review_lens_write_result "$out" misconfigured "$why"
    return 1
}
