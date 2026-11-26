#!/usr/bin/env bash
# scripts/lib/digest.sh — a fingerprint of a text or a file. A small one (up to
# _ZB_DIGEST_SHELL_MAX bytes, which is what the engine digests on almost every
# dispatch: an acceptance block, a step list, notes) is taken by the shell — no
# program runs (ADR-065 §5): FNV-1a, 32 bits, over the bytes, "<8 hex>-<bytes>".
# A larger one is taken by one cksum, "ck<sum>-<bytes>": the shell's loop costs
# about 6 µs a byte, too slow past a few tens of KB. It tells versions apart; it
# is no defence against someone forging a match.
#
# Source-only; no `set -e` at top level (would mutate caller options).

[[ -n "${_ZBUILD_DIGEST_LOADED:-}" ]] && return 0
_ZBUILD_DIGEST_LOADED=1

_ZB_DIGEST_SHELL_MAX="${ZBUILD_DIGEST_SHELL_MAX:-16384}"

# _zb_fnv_v <hash_var> <text> — fold <text>'s bytes into the hash in <hash_var>,
# 256 bytes at a time read by offset (a byte picked out of a long string costs
# as much as the string is long).
_zb_fnv_v() {
    local -n _zfh="$1"; local LC_ALL=C _zf_c _zf_i _zf_j _zf_n=${#2} _zf_m _zf_o
    for (( _zf_i = 0; _zf_i < _zf_n; _zf_i += 256 )); do
        _zf_c="${2:_zf_i:256}"; _zf_m=${#_zf_c}
        for (( _zf_j = 0; _zf_j < _zf_m; _zf_j++ )); do
            printf -v _zf_o '%d' "'${_zf_c:_zf_j:1}"
            (( _zfh = ((_zfh ^ (_zf_o & 255)) * 16777619) & 0xFFFFFFFF ))
        done
    done
}

# zb_digest_v <var> <text> — the fingerprint of <text>.
zb_digest_v() {
    local LC_ALL=C _zd_h=2166136261 _zd_c _zd_n
    if (( ${#2} > _ZB_DIGEST_SHELL_MAX )); then
        read -r _zd_c _zd_n < <(cksum <<< "$2")
        printf -v "$1" 'ck%s-%s' "$_zd_c" "$_zd_n"; return 0
    fi
    _zb_fnv_v _zd_h "$2"
    printf -v "$1" '%08x-%d' "$_zd_h" "${#2}"
}

# zb_parts_digest_v <var> <array> — the fingerprint of text that held a NUL
# between each part of <array> (a shell string cannot hold one). Past
# _ZB_DIGEST_SHELL_MAX bytes, one cksum over those bytes, as zb_digest_v and
# zb_file_digest_v do (#2615): the same digest as a file that holds them.
zb_parts_digest_v() {
    local -n _zpd_a="$2"; local LC_ALL=C _zpd_h=2166136261 _zpd_n=0 _zpd_i _zpd_c _zpd_t
    _zpd_t=$(( ${#_zpd_a[@]} > 0 ? ${#_zpd_a[@]} - 1 : 0 ))
    for (( _zpd_i = 0; _zpd_i < ${#_zpd_a[@]}; _zpd_i++ )); do _zpd_t=$(( _zpd_t + ${#_zpd_a[_zpd_i]} )); done
    if (( _zpd_t > _ZB_DIGEST_SHELL_MAX )); then
        read -r _zpd_c _zpd_n < <(cksum < <(
            printf '%s' "${_zpd_a[0]}"
            for (( _zpd_i = 1; _zpd_i < ${#_zpd_a[@]}; _zpd_i++ )); do printf '\0%s' "${_zpd_a[_zpd_i]}"; done))
        printf -v "$1" 'ck%s-%s' "$_zpd_c" "$_zpd_n"; return 0
    fi
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
# included: read in its NUL-separated parts, each NUL counted; a NUL as the
# very last byte cannot be told from none. A file past _ZB_DIGEST_SHELL_MAX
# bytes is summed by one cksum over the file itself. "absent" for a file that
# is not there.
zb_file_digest_v() {
    local LC_ALL=C _zfd_t=0 _zfd_p _zfd_c _zfd_n
    local -a _zfd_parts=()
    if [[ ! -f "$2" || ! -r "$2" ]]; then printf -v "$1" '%s' absent; return 0; fi
    mapfile -d '' _zfd_parts < "$2"
    for _zfd_p in ${_zfd_parts[@]+"${_zfd_parts[@]}"}; do _zfd_t=$(( _zfd_t + ${#_zfd_p} )); done
    if (( _zfd_t > _ZB_DIGEST_SHELL_MAX )); then
        read -r _zfd_c _zfd_n < <(cksum < "$2")
        printf -v "$1" 'ck%s-%s' "$_zfd_c" "$_zfd_n"; return 0
    fi
    zb_parts_digest_v "$1" _zfd_parts
}
