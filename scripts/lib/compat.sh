#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  zBuild compat — Bash 5+ floor; platform detection                       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# zBuild requires Bash 5+. No Bash 3.2 polyfills (cleared from shipwright per
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

# ─── stat -c vs -f (GNU vs BSD) ─────────────────────────────────────────────
zbuild_stat_size() {
    if [[ "$ZBUILD_PLATFORM" == "macos" ]]; then
        stat -f '%z' "$1"
    else
        stat -c '%s' "$1"
    fi
}

# ─── sed -i differences ─────────────────────────────────────────────────────
zbuild_sed_inplace() {
    if [[ "$ZBUILD_PLATFORM" == "macos" ]]; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
}
