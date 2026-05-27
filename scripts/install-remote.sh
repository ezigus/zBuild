#!/usr/bin/env bash
# zBuild remote installer — https://github.com/ezigus/zBuild
# Usage: curl -sSfL https://raw.githubusercontent.com/ezigus/zBuild/main/scripts/install-remote.sh | bash
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RESET='\033[0m'
info()  { printf '%b\n' "${GREEN}[OK]${RESET} $*"; }
warn()  { printf '%b\n' "${YELLOW}[WARN]${RESET} $*" >&2; }
error() { printf '%b\n' "${RED}[FAIL]${RESET} $*" >&2; }
die()   { error "$*"; exit 1; }

# Bash 5+ check (must be first)
if [[ "${BASH_VERSINFO[0]:-0}" -lt 5 ]]; then
    die "zBuild requires Bash 5+. You have ${BASH_VERSION:-unknown}.
  macOS: brew install bash
  Linux: sudo apt install bash"
fi

# Prerequisite checks
MISSING=()
for bin in git jq curl; do
    if command -v "$bin" >/dev/null 2>&1; then
        info "found: $bin"
    else
        MISSING+=("$bin")
        error "missing: $bin"
    fi
done
# gh is optional but warn
if ! command -v gh >/dev/null 2>&1; then
    warn "gh not found — some zbuild features require it"
    warn "  macOS: brew install gh  |  Linux: sudo apt install gh"
fi

if [[ ${#MISSING[@]} -gt 0 ]]; then
    warn "Install missing tools then re-run:"
    warn "  macOS: brew install ${MISSING[*]}"
    warn "  Linux: sudo apt install ${MISSING[*]}"
    exit 1
fi

# Resolve latest release tag
REPO="${ZBUILD_REPO:-ezigus/zBuild}"
INSTALL_DIR="${ZBUILD_INSTALL_DIR:-$HOME/.zbuild}"
BIN_DIR="${ZBUILD_BIN_DIR:-$HOME/.local/bin}"

info "Fetching latest release from GitHub..."
TAG="$(curl -sSf "https://api.github.com/repos/${REPO}/releases/latest" | jq -r '.tag_name')"

if [[ -z "$TAG" || "$TAG" == "null" ]]; then
    die "Could not determine latest release tag. Check your network or GitHub API rate limit."
fi
info "Latest release: $TAG"

# Download tarball
TARBALL_URL="https://github.com/${REPO}/archive/refs/tags/${TAG}.tar.gz"
TMP_TARBALL="$(mktemp -t zbuild-install.XXXXXX).tar.gz"
trap 'rm -f "$TMP_TARBALL"' EXIT

info "Downloading $TARBALL_URL..."
curl -sSfL "$TARBALL_URL" -o "$TMP_TARBALL"

# Extract
mkdir -p "$INSTALL_DIR"
tar -xzf "$TMP_TARBALL" -C "$INSTALL_DIR" --strip-components=1
info "Extracted to $INSTALL_DIR"

# Symlink
mkdir -p "$BIN_DIR"
ln -sf "$INSTALL_DIR/scripts/zbuild" "$BIN_DIR/zbuild"
info "Symlinked: $BIN_DIR/zbuild"

# PATH advisory
if [[ ":${PATH}:" != *":${BIN_DIR}:"* ]]; then
    warn "$BIN_DIR is not on your PATH"
    printf '  Add to ~/.zshrc or ~/.bashrc:  export PATH="%s:$PATH"\n' "$BIN_DIR"
fi

# Doctor verification
info "Running zbuild doctor..."
"$BIN_DIR/zbuild" doctor 2>/dev/null || warn "zbuild doctor reported issues — run 'zbuild doctor' for details"

printf '\n'
info "Installation complete. Run: zbuild --help"
