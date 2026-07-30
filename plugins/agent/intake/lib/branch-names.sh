#!/usr/bin/env bash
# plugins/agent/intake/lib/branch-names.sh — branch name derivation and validation

[[ -n "${_ZBUILD_INTAKE_BRANCH_NAMES_LOADED:-}" ]] && return 0
_ZBUILD_INTAKE_BRANCH_NAMES_LOADED=1

# ═══════════════════════════════════════════════════════════════════════════
# Issue #484 — Branch name helpers
# ═══════════════════════════════════════════════════════════════════════════

# _intake_derive_branch_name <issue> <title>
# Echoes a branch name of the form: zbuild/issue-<N>-<slug>
# Slug rules (POSIX-portable, mirrors legacy:83-86):
#   - lowercase
#   - non-alphanumeric → '-'
#   - collapse runs of '-'
#   - cut to 40 chars
#   - strip trailing '-'
#   - empty/punctuation-only title → slug "untitled"
_intake_derive_branch_name() {
    local issue="$1" title="$2"
    local slug
    # shellcheck disable=SC2001  # POSIX sed for portability over bash subst
    slug="$(printf '%s' "$title" \
        | tr '[:upper:]' '[:lower:]' \
        | sed 's/[^a-z0-9]/-/g' \
        | sed 's/--*/-/g' \
        | cut -c1-40)"
    slug="${slug#-}"
    slug="${slug%-}"
    [[ -z "$slug" ]] && slug="untitled"
    if [[ -n "$issue" && "$issue" != "0" ]]; then
        printf 'zbuild/issue-%s-%s\n' "$issue" "$slug"
    else
        # No issue context — still emit a deterministic branch name.
        printf 'zbuild/issue-0-%s\n' "$slug"
    fi
}

# _intake_validate_branch_name <name>
# Returns 0 if safe, 2 otherwise. Rejects empty/whitespace, leading '-',
# '..' anywhere (path traversal), and shell/refname metacharacters.
_intake_validate_branch_name() {
    local n="$1"
    [[ -z "${n//[[:space:]]/}" ]] && return 2
    [[ "$n" == -* ]] && return 2
    [[ "$n" == *..* ]] && return 2
    # Reject control chars, spaces, and git-forbidden refname chars.
    case "$n" in
        *' '*|*$'\t'*|*$'\n'*|*'~'*|*'^'*|*':'*|*'?'*|*'*'*|*'['*|*'\'*) return 2 ;;
    esac
    return 0
}
