#!/usr/bin/env bash
# scripts/lib/private-paths.sh — the paths no stage sees, reads or writes
# (#2379, ADR-043, ADR-058).
#
# The list is the engine's own (config/private-paths.txt), plus what the
# template (`private_paths:`) and the repository (`.zbuild/private-paths`) add.
# Additions only: a line starting with `!` is ignored, so a repository cannot
# take an engine default away.
#
# Sourced library: no `set -euo pipefail`.

[[ -n "${_ZBUILD_PRIVATE_PATHS_LOADED:-}" ]] && return 0
_ZBUILD_PRIVATE_PATHS_LOADED=1

_ZBUILD_PRIVATE_PATHS_ROOT="$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; cd "../.." && pwd)"

# _private_paths_clean — one pattern per line: no comments, blanks or `!` lines.
_private_paths_clean() {
    sed -e 's/[[:space:]]*#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
        | /usr/bin/grep -v -e '^$' -e '^!' || true
}

# private_paths_list <repo_root> — every private pattern, one per line, the
# engine's first, each once.
private_paths_list() {
    local repo="${1:-${ZBUILD_REPO_ROOT:-}}" tpl="${_TPL_SOURCE_FILE:-}"
    {
        _private_paths_clean < "$_ZBUILD_PRIVATE_PATHS_ROOT/config/private-paths.txt"
        if [[ -n "$tpl" && -f "$tpl" ]]; then
            awk '/^private_paths:[[:space:]]*$/ { inb = 1; next }
                 inb && /^[^[:space:]#]/ { inb = 0 }
                 inb && /^[[:space:]]*-[[:space:]]+/ { l = $0; sub(/^[[:space:]]*-[[:space:]]+/, "", l); gsub(/["\047]/, "", l); print l }' \
                "$tpl" | _private_paths_clean
        fi
        if [[ -n "$repo" && -f "$repo/.zbuild/private-paths" ]]; then
            _private_paths_clean < "$repo/.zbuild/private-paths"
        fi
    } | awk '!seen[$0]++'
    return 0
}

# private_paths_deny_rules <repo_root> — the model-call permission rules for the
# list: reading and editing each private path is denied. A folder or a path is
# anchored at the repository root; a file name matches in any folder. (Measured
# on CLI 2.1.296: `Read(//abs/...)` refuses the Read tool and a Bash `cat`, and
# `**/*.pem` matches a file in any folder — see core/router/permissions.sh P10.)
private_paths_deny_rules() {
    local repo="${1:-${ZBUILD_REPO_ROOT:-}}" p target
    [[ -n "$repo" ]] || return 0
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        case "$p" in
            */) target="$repo/$p**" ;;
            */*) target="$repo/$p" ;;
            *)  target="$repo/**/$p" ;;
        esac
        printf 'Read(/%s)\nEdit(/%s)\n' "$target" "$target"
    done < <(private_paths_list "$repo")
}
