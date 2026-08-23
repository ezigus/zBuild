#!/usr/bin/env bash
# scripts/lib/identity.sh — the one derivation of "what is this run for?"
#
# Three questions, one answer each:
#   which repository?      zbuild_repo_id (flat key) / zbuild_repo_slug (path)
#   which issue or goal?   zbuild_scope_key, zbuild_goal_hash
#
# ADR-059 §6. This module owns identity and NOTHING else — no cache, no GC, no
# LLM, no writes. The only I/O is reading git config, which is what identity is
# derived from. That constraint is the point: before this existed, reusing a
# sha256 meant sourcing scripts/lib/plan-context.sh, which sources llm-agent.sh.
#
# The gate this file has to pass: it must be sourceable by scripts/lib/cleanup.sh
# and scripts/lib/worktree.sh with nothing from the plan stage coming along.
# Do not add a source line here.

# Idempotent source guard.
if [[ "${_ZBUILD_IDENTITY_LOADED:-}" == "1" ]]; then
    return 0
fi
_ZBUILD_IDENTITY_LOADED=1

# ─── zbuild_repo_id ──────────────────────────────────────────────────────────
# Stable hash identifying THIS repository, for use as a FLAT key — a memory
# namespace, a cost-ledger key, a cache directory segment. Normalises the
# canonical remote so the same repo cloned over ssh and https hashes alike:
# drop embedded credentials, strip one trailing .git, lowercase. Falls back to
# the toplevel path when there is no remote, so a local-only clone still has a
# home. Echoes the hash.
#
# Moved from plan_context_repo_id (#1052) unchanged — the output is byte-identical.
zbuild_repo_id() {
    local url normalized
    url="$(git config --get remote.origin.url 2>/dev/null || true)"
    if [[ -n "$url" ]]; then
        # Drop credentials in the userinfo@ portion of an https/ssh URL.
        normalized="$(printf '%s' "$url" | sed -E 's#^([a-zA-Z][a-zA-Z0-9+.-]*://)[^/@]*@#\1#')"
        # Strip a single trailing .git
        normalized="${normalized%.git}"
        # Lowercase the entire normalized URL (host case-insensitive; paths are
        # typically lowercase on the canonical remote — over-normalizing is
        # acceptable since this value only ever compares against itself).
        normalized="$(printf '%s' "$normalized" | tr '[:upper:]' '[:lower:]')"
    else
        normalized="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    fi
    printf '%s' "$normalized" | shasum -a 256 | cut -d' ' -f1
}

# ─── zbuild_repo_slug [repo_root] ────────────────────────────────────────────
# `owner/repo` for THIS repository, for use where a human has to read the
# result — a directory segment, a GitHub URL. Echoes nothing and returns 1 when
# the remote is absent or is not a recognisable GitHub remote; every caller
# already has a degraded path for that.
#
# WHY one parser: this was derived twice with two different ones —
# release-tarball.sh accepted any URL containing `github.com`, while
# design/plugin.sh matched exactly two literal prefixes and returned empty on
# anything else. A repo reachable by a form one accepted and the other did not
# got a release tarball and NO design blob URL, silently. This accepts every
# legitimate form the two missed between them, and rejects the host confusion
# the first one allowed.
zbuild_repo_slug() {
    local repo_root="${1:-}" url slug
    if [[ -n "$repo_root" ]]; then
        url="$(git -C "$repo_root" config --get remote.origin.url 2>/dev/null || true)"
    else
        url="$(git config --get remote.origin.url 2>/dev/null || true)"
    fi
    [[ -n "$url" ]] || return 1

    local rest hostpart host
    rest="${url%.git}"

    # Parse the HOST explicitly rather than pattern-stripping to it. The obvious
    # `${url#*github.com[:/]}` strips the SHORTEST matching prefix, and `*` will
    # happily match `git@not` — so `git@notgithub.com:evil/target` yields
    # `evil/target`, which `_release_repo` then hands to
    # `gh release download --repo`. release-tarball.sh shipped that hole; the
    # design stage's stricter literal-prefix `case` did not, and unifying on the
    # permissive parse would have spread it. Host EQUALITY is the check.

    # 1. Drop the scheme, if any. Absent one (scp-style `git@host:path`) the
    #    pattern does not match and this is a no-op.
    rest="${rest#*://}"
    # 2. Drop credentials, but ONLY when the `@` precedes the first `/` — an `@`
    #    inside the path is part of the path, not a userinfo delimiter.
    hostpart="${rest%%/*}"
    if [[ "$hostpart" == *@* ]]; then
        rest="${rest#*@}"
    fi
    # 3. Split the host off at the first `:` or `/` and require it to BE the
    #    host, not merely end with it. Hosts are case-insensitive.
    host="${rest%%[:/]*}"
    host="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"
    [[ "$host" == "github.com" ]] || return 1
    rest="${rest#"${rest%%[:/]*}"}"
    slug="${rest#[:/]}"

    # Shape check: exactly one slash, and neither half empty or path-unsafe.
    # This is the boundary where a remote URL becomes a directory name
    # (ADR-059 §5), so it is also the traversal guard.
    case "$slug" in
        */*/*|/*|*/) return 1 ;;
        */*)         : ;;
        *)           return 1 ;;
    esac
    case "$slug" in
        *..*|*$'\n'*) return 1 ;;
    esac

    printf '%s' "$slug"
}

# ─── zbuild_goal_hash <goal_text> ────────────────────────────────────────────
# Stable hash of the (pre-redaction) goal text. WHITESPACE-INSENSITIVE on
# purpose: an editor reflowing the goal must not change the key, or a resume
# silently misses and re-explores from scratch.
#
# Moved from plan_context_goal_hash (#1052) unchanged — byte-identical output.
zbuild_goal_hash() {
    printf '%s' "${1:-}" | tr -d '[:space:]' | shasum -a 256 | cut -d' ' -f1
}

# ─── zbuild_scope_key <issue> <fallback> ─────────────────────────────────────
# What this run is FOR: the issue number when there is one, else the caller's
# fallback (the plan stage passes its scope-manifest hash). Echoes the key.
#
# WHY a function and not an inline expression: this was `${ZBUILD_ISSUE_NUMBER:-$ref}`
# written once in plugins/agent/plan/plugin.sh and threaded through eleven call
# sites in that file, with the test re-deriving the fallback by hand. ADR-059 §1
# makes this a PATH segment, so it stops being one plugin's local variable.
#
# `:-` (not `:+`) deliberately: an unset AND an empty issue both fall back. The
# `--goal` sentinel is issue=0, which is NOT empty and would pass through — so
# callers must not pass 0 expecting the fallback. ADR-059 §5 retires that
# sentinel in favour of a goal hash; until then, guard at the call site.
zbuild_scope_key() {
    local issue="${1:-}" fallback="${2:-}" key
    key="${issue:-$fallback}"
    # Both empty is a CALLER bug, and echoing "" would hide it: the key is a
    # path segment, so an empty one collapses `<repo_id>/<key>/<hash>.json` into
    # `<repo_id>/<hash>.json`. Two issues with different goals but the same
    # goal_hash would then overwrite each other's cache entry — silently, and
    # with the wrong context resumed. Refuse instead.
    [[ -n "$key" ]] || return 1
    printf '%s' "$key"
}
