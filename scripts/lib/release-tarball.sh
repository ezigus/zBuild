#!/usr/bin/env bash
# scripts/lib/release-tarball.sh — release-artifact builder + signing seam (#875).
#
# Builds the versioned install-payload tarball `zbuild-vA.B.C.D.tar.gz` (the exact
# set install.sh copies: scripts/ core/ plugins/ config/ .github/issues/ install.sh
# + VERSION) then hands it to the SELECTED `signing` backend (ADR-011) to emit a
# SHA256SUMS integrity manifest (+ a crypto signature when a crypto backend is
# configured). The default built-in backend is `checksums-only`.
#
# STANDALONE by design: REL-B's scripts/release.sh does not exist on every base.
# release.sh integrates by sourcing this file and calling, after it resolves the
# version and stages the tree:
#     build_release_tarball "<repo_root>" "<version>" "<outdir>"
# (wired at merge / REL-D). This module has no dependency on release.sh.
#
# Sourced library: inherits caller's pipefail; no set -euo pipefail here.

[[ -n "${_ZBUILD_RELEASE_TARBALL_LOADED:-}" ]] && return 0
_ZBUILD_RELEASE_TARBALL_LOADED=1

_ZBUILD_RELEASE_TARBALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Emit a fail-loud message to stderr (uses helpers' `error` when available).
_rt_err() {
    if declare -F error >/dev/null 2>&1; then error "$*"; else echo "$*" >&2; fi
}

# The install payload set — MUST stay in lockstep with install.sh's copy list.
# (scripts/ core/ plugins/ config/ .github/issues/ install.sh + VERSION.)
_ZBUILD_RELEASE_PAYLOAD=(scripts core plugins config .github/issues install.sh VERSION)

# ─── _release_resolve_signing_backend ────────────────────────────────────────
# Select the `signing` backend, source its strategy INTO THE CALLER'S SCOPE, and
# confirm it exposes the contract (<backend>_sign / <backend>_verify). Fails loud
# (rc=1) on an unknown/absent configured backend, mirroring ADR-011
# `backend.missing`. Sets `_release_signing_backend` (the resolved name) for the
# caller — deliberately NOT via stdout/`$(...)`, because a command-substitution
# subshell would `source` the strategy into a subshell and its functions would
# not survive to the caller (the dispatch site). Callers must declare
# `_release_signing_backend` local.
_release_resolve_signing_backend() {
    local backend=""
    if declare -F zbuild_config_get_backend >/dev/null 2>&1; then
        backend="$(zbuild_config_get_backend "signing" 2>/dev/null)" || true
    fi
    backend="${backend:-checksums-only}"

    if [[ "$backend" == "checksums-only" ]]; then
        # shellcheck source=signing/checksums-only.sh
        source "$_ZBUILD_RELEASE_TARBALL_DIR/signing/checksums-only.sh"
    else
        # Non-default: locate the plugin via the registry (signing-backend role).
        local plugin_dir=""
        if declare -F find_plugin_for_role >/dev/null 2>&1; then
            plugin_dir="$(find_plugin_for_role "signing-backend" "$backend" 2>/dev/null)" || true
        fi
        if [[ -n "$plugin_dir" && -f "${plugin_dir}/plugin.sh" ]]; then
            # shellcheck disable=SC1090
            source "${plugin_dir}/plugin.sh"
        else
            _rt_err "backend.missing: signing=${backend} configured but plugin not found"
            if declare -F emit_event >/dev/null 2>&1; then
                emit_event "backend.missing" "role=signing-backend" "requested=$backend" || true
            fi
            return 1
        fi
    fi

    if ! declare -F "${backend}_sign" >/dev/null 2>&1 \
        || ! declare -F "${backend}_verify" >/dev/null 2>&1; then
        _rt_err "signing backend '${backend}' must define ${backend}_sign and ${backend}_verify"
        return 1
    fi
    _release_signing_backend="$backend"
}

# ─── build_release_tarball <repo_root> <version> <outdir> ────────────────────
# Build zbuild-v<version>.tar.gz of the install payload set from <repo_root> into
# <outdir>, deterministically (sorted members; pinned mtime/owner where tar
# supports it), then dispatch to the selected signing backend to emit SHA256SUMS
# (+ signature for a crypto backend). Prints the tarball path on stdout.
build_release_tarball() {
    local repo_root="${1-}" version="${2-}" outdir="${3-}"
    if [[ -z "$repo_root" || ! -d "$repo_root" ]]; then
        _rt_err "build_release_tarball: repo_root not found: ${repo_root:-<none>}"
        return 1
    fi
    if [[ -z "$version" ]]; then
        _rt_err "build_release_tarball: version required (A.B.C.D)"
        return 1
    fi
    if [[ -z "$outdir" ]]; then
        _rt_err "build_release_tarball: outdir required"
        return 1
    fi
    mkdir -p "$outdir" || return 1

    # Collect the payload members that actually exist. .github/issues/ and VERSION
    # are optional (install.sh treats .github/issues as best-effort); scripts/
    # core/ plugins/ config/ are mandatory.
    local m members=()
    for m in "${_ZBUILD_RELEASE_PAYLOAD[@]}"; do
        if [[ -e "$repo_root/$m" ]]; then
            members+=("$m")
        else
            case "$m" in
                scripts|core|plugins|config)
                    _rt_err "build_release_tarball: required payload member missing: $m"
                    return 1 ;;
                *) : ;;  # optional member absent — skip
            esac
        fi
    done

    local tarball="$outdir/zbuild-v${version}.tar.gz"

    # Determinism: sort members, and where GNU tar is present pin owner/mtime/order
    # so identical inputs yield an identical archive. macOS/BSD tar lacks these
    # flags — we degrade to a plain sorted archive (still stable member order).
    local sorted
    sorted="$(printf '%s\n' "${members[@]}" | LC_ALL=C sort)"

    local -a tar_common=(-C "$repo_root")
    if tar --sort=name --version >/dev/null 2>&1; then
        # GNU tar: fully reproducible.
        # shellcheck disable=SC2086
        tar "${tar_common[@]}" \
            --sort=name \
            --mtime='UTC 2020-01-01' \
            --owner=0 --group=0 --numeric-owner \
            -czf "$tarball" $sorted || { _rt_err "build_release_tarball: tar failed"; return 1; }
    else
        # BSD/macOS tar: sorted member list still gives a stable ordering.
        # shellcheck disable=SC2086
        tar "${tar_common[@]}" -czf "$tarball" $sorted \
            || { _rt_err "build_release_tarball: tar failed"; return 1; }
    fi

    # Dispatch to the selected signing backend to emit SHA256SUMS (+ signature).
    # Source into THIS scope (not a subshell) so the backend's functions are live.
    local _release_signing_backend=""
    _release_resolve_signing_backend || return 1
    "${_release_signing_backend}_sign" "$tarball" "$outdir" >/dev/null || {
        _rt_err "build_release_tarball: signing backend '${_release_signing_backend}' failed to sign"
        return 1
    }

    printf '%s\n' "$tarball"
}

# ─── verify_release_tarball <tarball> <sumsfile> ─────────────────────────────
# Verify a (downloaded) tarball against SHA256SUMS via the selected signing
# backend. rc 0 iff it matches; non-zero (REFUSE) on any tamper/mismatch. The
# upgrade path calls this BEFORE applying an artifact.
verify_release_tarball() {
    local tarball="${1-}" sumsfile="${2-}"
    local _release_signing_backend=""
    _release_resolve_signing_backend || return 1
    "${_release_signing_backend}_verify" "$tarball" "$sumsfile"
}

# ─── _release_fetch_by_tag <tag> <destdir> ──────────────────────────────────
# Download zbuild-<tag>.tar.gz + SHA256SUMS for a GitHub Release <tag> into
# <destdir>. Network is behind a SEAM so tests never hit the wire:
#   * ZBUILD_RELEASE_FETCH_CMD — a command run as `<cmd> <tag> <destdir>` that
#     must place both assets in <destdir> (used by tests / custom mirrors).
#   * ZBUILD_RELEASE_LOCAL_DIR — a local directory holding the two assets; they
#     are copied out (used by tests and air-gapped mirrors).
#   * default: `gh release download <tag>` (repo inferred from cwd/GH_REPO).
# Prints nothing; rc 0 iff both assets landed in <destdir>.
_release_fetch_by_tag() {
    local tag="${1-}" destdir="${2-}"
    if [[ -z "$tag" || -z "$destdir" ]]; then
        _rt_err "_release_fetch_by_tag: tag and destdir required"
        return 1
    fi
    mkdir -p "$destdir" || return 1
    local tarname="zbuild-${tag}.tar.gz"

    if [[ -n "${ZBUILD_RELEASE_FETCH_CMD:-}" ]]; then
        # shellcheck disable=SC2086
        ${ZBUILD_RELEASE_FETCH_CMD} "$tag" "$destdir" || {
            _rt_err "_release_fetch_by_tag: fetch command failed for $tag"; return 1; }
    elif [[ -n "${ZBUILD_RELEASE_LOCAL_DIR:-}" ]]; then
        cp "$ZBUILD_RELEASE_LOCAL_DIR/$tarname"  "$destdir/$tarname"  || return 1
        cp "$ZBUILD_RELEASE_LOCAL_DIR/SHA256SUMS" "$destdir/SHA256SUMS" || return 1
    else
        if ! command -v gh >/dev/null 2>&1; then
            _rt_err "_release_fetch_by_tag: gh CLI not found (or set ZBUILD_RELEASE_LOCAL_DIR)"
            return 1
        fi
        gh release download "$tag" \
            --pattern "$tarname" --pattern "SHA256SUMS" \
            --dir "$destdir" --clobber || {
            _rt_err "_release_fetch_by_tag: gh release download failed for $tag"; return 1; }
    fi

    if [[ ! -f "$destdir/$tarname" || ! -f "$destdir/SHA256SUMS" ]]; then
        _rt_err "_release_fetch_by_tag: missing $tarname or SHA256SUMS after fetch"
        return 1
    fi
    return 0
}

# ─── fetch_verified_release <tag> <destdir> ──────────────────────────────────
# Fetch a release by tag, then VERIFY the tarball against SHA256SUMS (checksum,
# plus signature when a crypto backend is configured) BEFORE the caller applies
# anything. On success prints the verified tarball's path on stdout (rc 0). On
# ANY fetch or verify failure → non-zero and prints NOTHING (the artifact is left
# in <destdir> unverified; the caller MUST NOT apply it). Verify-before-apply is
# enforced here so no caller can apply an unverified artifact.
fetch_verified_release() {
    local tag="${1-}" destdir="${2-}"
    if [[ -z "$tag" || -z "$destdir" ]]; then
        _rt_err "fetch_verified_release: tag and destdir required"
        return 1
    fi
    _release_fetch_by_tag "$tag" "$destdir" || return 1

    local tarball="$destdir/zbuild-${tag}.tar.gz"
    local sumsfile="$destdir/SHA256SUMS"
    if ! verify_release_tarball "$tarball" "$sumsfile"; then
        _rt_err "fetch_verified_release: verification FAILED for $tag — refusing to apply"
        return 1
    fi
    printf '%s\n' "$tarball"
}
