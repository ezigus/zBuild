#!/usr/bin/env bash
# scripts/lib/digest.sh — a fingerprint of a text or a file, computed by the
# shell: no program runs (ADR-065 §5). FNV-1a, 32 bits, over the bytes, with the
# byte count: "<8 hex digits>-<bytes>". It tells versions apart; it is no
# defence against someone forging a match.
#
# Source-only; no `set -e` at top level (would mutate caller options).

[[ -n "${_ZBUILD_DIGEST_LOADED:-}" ]] && return 0
_ZBUILD_DIGEST_LOADED=1

# _zb_fnv_v <hash_var> <text> — fold <text>'s bytes into the hash in <hash_var>.
# Taken 256 bytes at a time: a byte picked out of a long string costs as much
# as the string is long.
_zb_fnv_v() {
    local -n _zfh="$1"; local LC_ALL=C _zf_r="$2" _zf_c _zf_i _zf_n _zf_o
    while [[ -n "$_zf_r" ]]; do
        _zf_c="${_zf_r:0:256}"; _zf_r="${_zf_r:256}"; _zf_n=${#_zf_c}
        for (( _zf_i = 0; _zf_i < _zf_n; _zf_i++ )); do
            printf -v _zf_o '%d' "'${_zf_c:_zf_i:1}"
            (( _zfh = ((_zfh ^ (_zf_o & 255)) * 16777619) & 0xFFFFFFFF ))
        done
    done
}

# zb_digest_v <var> <text> — the fingerprint of <text>.
zb_digest_v() {
    local _zd_h=2166136261 _zd_n; local LC_ALL=C
    _zb_fnv_v _zd_h "$2"
    _zd_n=${#2}
    printf -v "$1" '%08x-%d' "$_zd_h" "$_zd_n"
}

# zb_parts_digest_v <var> <array> — the fingerprint of text that held a NUL
# between each part of <array> (a shell string cannot hold one).
zb_parts_digest_v() {
    local -n _zpd_a="$2"; local _zpd_h=2166136261 _zpd_n=0 _zpd_i; local LC_ALL=C
    for (( _zpd_i = 0; _zpd_i < ${#_zpd_a[@]}; _zpd_i++ )); do
        if (( _zpd_i > 0 )); then
            (( _zpd_h = (_zpd_h * 16777619) & 0xFFFFFFFF )); _zpd_n=$(( _zpd_n + 1 ))
        fi
        _zb_fnv_v _zpd_h "${_zpd_a[_zpd_i]}"
        _zpd_n=$(( _zpd_n + ${#_zpd_a[_zpd_i]} ))
    done
    printf -v "$1" '%08x-%d' "$_zpd_h" "$_zpd_n"
}

# zb_file_digest_v <var> <path> — the fingerprint of a file's bytes, NULs
# included: the file is read in its NUL-separated parts, and each NUL counts.
# "absent" for a file that is not there.
zb_file_digest_v() {
    local -a _zfd_parts=()
    if [[ ! -f "$2" || ! -r "$2" ]]; then printf -v "$1" '%s' absent; return 0; fi
    mapfile -d '' _zfd_parts < "$2"
    zb_parts_digest_v "$1" _zfd_parts
}
