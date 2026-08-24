#!/usr/bin/env bash
# plugins/agent/intake/lib/branch-names.sh — branch name derivation and validation

[[ -n "${_ZBUILD_INTAKE_BRANCH_NAMES_LOADED:-}" ]] && return 0
_ZBUILD_INTAKE_BRANCH_NAMES_LOADED=1

# #1931: zbuild_run_key / zbuild_goal_key. Guarded rather than unconditional —
# this lib is sourced by tests that do not set up a plugin root, and a goal run
# without the module still gets the old deterministic name.
_ZBUILD_BRANCH_NAMES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$_ZBUILD_BRANCH_NAMES_DIR/../../../../scripts/lib/identity.sh" ]]; then
    # shellcheck source=../../../../scripts/lib/identity.sh
    source "$_ZBUILD_BRANCH_NAMES_DIR/../../../../scripts/lib/identity.sh"
fi

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
        return 0
    fi
    # #1931: no issue. `zbuild/issue-0-<slug>` was deterministic but not
    # DISTINCT — every goal run in history shared the `issue-0` key, and under
    # ADR-059's issue-keyed layout that means one worktree and one artifacts dir
    # for unrelated goals. Worse, zbuild_worktree_acquire creates-or-REUSES, so
    # it would hand the second goal run the first one's tree with the first
    # one's branch checked out (#1640's defect class).
    #
    # The goal text is the only identity a goal run has, so key on it.
    # zbuild_run_key returns `goal-<12 hex>`; the slug stays for readability.
    # ZBUILD_GOAL ONLY — never the title. A title is not a goal: a run invoked
    # without --goal has no goal text, and falling back to its title would
    # MANUFACTURE an identity for a run that has none. That contradicts this
    # change's own rule (no issue AND no goal ⇒ no identity ⇒ keep the old
    # shape), and `plugins/agent/intake/tests/intake-branch-test.sh` caught it:
    # `_intake_derive_branch_name 0 "something"` must still be
    # `zbuild/issue-0-something`. The runner exports ZBUILD_GOAL for every real
    # --goal run, so it is the whole signal.
    local key=""
    if [[ -n "${ZBUILD_GOAL:-}" ]] && declare -F zbuild_run_key >/dev/null 2>&1; then
        key="$(zbuild_run_key "0" "$ZBUILD_GOAL" 2>/dev/null || true)"
    fi
    if [[ -n "$key" ]]; then
        printf 'zbuild/%s-%s\n' "$key" "$slug"
    else
        # No goal text either. Nothing distinguishes this run from any other, so
        # the old shape is still the honest answer — there is no identity to
        # encode, and inventing one would key unrelated work together.
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
