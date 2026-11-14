#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  zBuild compat — Bash 5+ floor; platform detection                       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# zBuild requires Bash 5+. No Bash 3.2 polyfills (cleared from legacy per
# the migration plan). This file is small on purpose; if it grows past ~50
# lines, that's a smell.

[[ -n "${_ZBUILD_COMPAT_LOADED:-}" ]] && return 0
_ZBUILD_COMPAT_LOADED=1

# ─── Bash version check ──────────────────────────────────────────────────────
_zbuild_check_bash() {
    if [[ -z "${BASH_VERSION:-}" ]]; then
        echo "ERROR: zBuild requires Bash. This shell is not Bash." >&2
        return 1
    fi
    local major="${BASH_VERSINFO[0]}"
    if (( major < 5 )); then
        echo "ERROR: zBuild requires Bash 5+. You have Bash $BASH_VERSION." >&2
        echo "On macOS: brew install bash; then add /opt/homebrew/bin/bash to /etc/shells." >&2
        return 1
    fi
    return 0
}
_zbuild_check_bash || return 1

# ─── Platform detection ─────────────────────────────────────────────────────
ZBUILD_OS="$(uname -s)"
case "$ZBUILD_OS" in
    Darwin)  ZBUILD_PLATFORM=macos ;;
    Linux)   ZBUILD_PLATFORM=linux ;;
    *)       ZBUILD_PLATFORM=unknown ;;
esac
export ZBUILD_OS ZBUILD_PLATFORM

# ─── flock availability (Linux native, macOS via brew) ──────────────────────
zbuild_has_flock() {
    command -v flock >/dev/null 2>&1
}

# ─── sed -i probe (GNU vs BSD), run once at load time ───────────────────────
# GNU sed accepts --version; BSD sed does not. Storing the flag array avoids
# re-probing on every zbuild_sed_inplace call and works regardless of
# $ZBUILD_PLATFORM (which may be overridden or absent in test environments).
declare -a _ZB_SED_INPLACE_ARGS
if sed --version >/dev/null 2>&1; then
    _ZB_SED_INPLACE_ARGS=(-i)
else
    _ZB_SED_INPLACE_ARGS=(-i '')
fi

zbuild_sed_inplace() {
    sed "${_ZB_SED_INPLACE_ARGS[@]}" "$@"
}
