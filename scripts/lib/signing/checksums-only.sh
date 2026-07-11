#!/usr/bin/env bash
# scripts/lib/signing/checksums-only.sh
# Default built-in signing strategy (ADR-011 `signing` backend, #875 REL-C).
#
# The signing SCHEME is pluggable data, not baked into core: the release cutter
# reads the selected `signing` backend (`zbuild_config_get_backend signing`) and
# dispatches to its strategy. This DEFAULT built-in strategy is `checksums-only`:
# it produces a SHA256SUMS integrity manifest and refuses a tampered artifact on
# verify. It carries NO cryptographic signature — a repo owner who needs one
# selects a future `cosign`/`gpg` backend (same contract, drops in with zero
# pipeline rework).
#
# Stable backend contract (every signing backend must expose these two):
#   <backend>_sign   <tarball> <outdir>   → emit SHA256SUMS (+ signature) in outdir
#   <backend>_verify <tarball> <sumsfile> → rc 0 iff the tarball matches; non-zero
#                                            (refuse) on any mismatch/tamper.
#
# Sourced library: inherits caller's pipefail; no set -euo pipefail here.

[[ -n "${_ZBUILD_SIGNING_CHECKSUMS_ONLY_LOADED:-}" ]] && return 0
_ZBUILD_SIGNING_CHECKSUMS_ONLY_LOADED=1

# Emit a fail-loud message to stderr (uses helpers' `error` when available).
_cs_err() {
    if declare -F error >/dev/null 2>&1; then error "$*"; else echo "$*" >&2; fi
}

# ─── _cs_sha256 <file> ───────────────────────────────────────────────────────
# Portable SHA-256: Linux ships `sha256sum`, macOS ships `shasum -a 256`. Prints
# just the lowercase hex digest (no filename). Fails loud (rc=1) if neither tool
# exists or the file is unreadable.
_cs_sha256() {
    local file="${1-}"
    if [[ -z "$file" || ! -f "$file" ]]; then
        _cs_err "checksums-only: file not found for hashing: ${file:-<none>}"
        return 1
    fi
    local out
    if command -v sha256sum >/dev/null 2>&1; then
        out="$(sha256sum -- "$file")" || return 1
    elif command -v shasum >/dev/null 2>&1; then
        out="$(shasum -a 256 -- "$file")" || return 1
    else
        _cs_err "checksums-only: no sha256sum or shasum available"
        return 1
    fi
    # Both tools print "<digest>  <name>"; keep the digest only.
    printf '%s' "${out%% *}"
}

# ─── checksums-only_sign <tarball> <outdir> ──────────────────────────────────
# Write "<digest>  <basename>" for <tarball> to <outdir>/SHA256SUMS. The manifest
# stores only the BASENAME so it verifies regardless of where the tarball is
# downloaded to. Prints the SHA256SUMS path on stdout. No crypto signature.
checksums-only_sign() {
    local tarball="${1-}" outdir="${2-}"
    if [[ -z "$tarball" || ! -f "$tarball" ]]; then
        _cs_err "checksums-only_sign: tarball not found: ${tarball:-<none>}"
        return 1
    fi
    if [[ -z "$outdir" ]]; then
        _cs_err "checksums-only_sign: outdir required"
        return 1
    fi
    mkdir -p "$outdir" || return 1

    local digest base sums
    digest="$(_cs_sha256 "$tarball")" || return 1
    base="$(basename -- "$tarball")"
    sums="$outdir/SHA256SUMS"
    # Two-space separator = the canonical GNU coreutils "binary" form both
    # sha256sum -c and shasum -c accept.
    printf '%s  %s\n' "$digest" "$base" > "$sums" || return 1
    printf '%s\n' "$sums"
}

# ─── checksums-only_verify <tarball> <sumsfile> ──────────────────────────────
# Return 0 iff <tarball>'s digest matches its basename's entry in <sumsfile>.
# Any mismatch, missing entry, or missing file → non-zero (REFUSE). This is the
# tamper gate the upgrade path calls BEFORE applying an artifact.
checksums-only_verify() {
    local tarball="${1-}" sumsfile="${2-}"
    if [[ -z "$tarball" || ! -f "$tarball" ]]; then
        _cs_err "checksums-only_verify: tarball not found: ${tarball:-<none>}"
        return 1
    fi
    if [[ -z "$sumsfile" || ! -f "$sumsfile" ]]; then
        _cs_err "checksums-only_verify: SHA256SUMS not found: ${sumsfile:-<none>}"
        return 1
    fi

    local base expected actual
    base="$(basename -- "$tarball")"
    # Pull the expected digest for THIS basename out of the manifest (a manifest
    # may list several artifacts). No entry → refuse.
    expected="$(awk -v f="$base" '$2 == f { print $1; exit }' "$sumsfile")"
    if [[ -z "$expected" ]]; then
        _cs_err "checksums-only_verify: no SHA256SUMS entry for $base — refusing"
        return 1
    fi
    actual="$(_cs_sha256 "$tarball")" || return 1
    if [[ "$actual" != "$expected" ]]; then
        _cs_err "checksums-only_verify: SHA256 mismatch for $base (tamper?) — refusing"
        return 1
    fi
    return 0
}
