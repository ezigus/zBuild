#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  zBuild installer                                                         ║
# ║  Prereq checks + symlink bin/zbuild onto PATH                            ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/helpers.sh
source "$SCRIPT_DIR/scripts/lib/helpers.sh"

info "zBuild installer"

# ─── Prereqs ────────────────────────────────────────────────────────────────
check_bin() {
    local bin="$1"
    if command -v "$bin" >/dev/null 2>&1; then
        success "found: $bin"
    else
        error "missing: $bin"
        return 1
    fi
}

prereqs_ok=true
for bin in bash git jq gh; do
    check_bin "$bin" || prereqs_ok=false
done

if [[ "$prereqs_ok" != "true" ]]; then
    error "Install missing prerequisites and re-run ./install.sh"
    echo
    echo "  macOS:   brew install bash git jq gh"
    echo "  Linux:   sudo apt install bash git jq gh   # or your distro's package manager"
    exit 1
fi

# Bash 5 check (compat.sh already enforces; this is a friendly version)
if (( BASH_VERSINFO[0] < 5 )); then
    error "zBuild requires Bash 5+. You have Bash $BASH_VERSION."
    echo "  macOS: brew install bash; then add /opt/homebrew/bin/bash to /etc/shells."
    exit 1
fi
success "bash version: $BASH_VERSION"

# ─── Install via symlink (dev) or npm (production) ──────────────────────────
TARGET_DIR="${ZBUILD_INSTALL_DIR:-$HOME/.local/bin}"
mkdir -p "$TARGET_DIR"

ln -sf "$SCRIPT_DIR/scripts/zbuild" "$TARGET_DIR/zbuild"
ln -sf "$SCRIPT_DIR/scripts/zbuild" "$TARGET_DIR/zb"
success "symlinked: $TARGET_DIR/zbuild and $TARGET_DIR/zb → $SCRIPT_DIR/scripts/zbuild"

# ─── PATH check ─────────────────────────────────────────────────────────────
if [[ ":$PATH:" != *":$TARGET_DIR:"* ]]; then
    warn "$TARGET_DIR is not on your PATH"
    echo "Add this to your shell rc:"
    echo "  export PATH=\"$TARGET_DIR:\$PATH\""
fi

# ─── Smoke test ─────────────────────────────────────────────────────────────
if "$SCRIPT_DIR/scripts/zbuild" --version >/dev/null; then
    success "zbuild --version works"
else
    error "zbuild --version failed"
    exit 1
fi

echo
info "Installation complete. Try: zbuild --help"
