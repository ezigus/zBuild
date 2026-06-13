#!/usr/bin/env bash
# scripts/lib/prompt-overrides.sh — per-repo prompt-override loader (ADR-032).
#
# zBuild ships 100% target-agnostic stage prompts; an operator tailors a stage
# for a specific TARGET repo by dropping `.zbuild/prompts/<stage>-overrides.md`
# into that repo. At prompt-build time an agent stage appends the override
# (after its core contract, before redaction) so the overlay can AUGMENT scope
# discovery / domain guidance without weakening the shipped charter. The override
# rides the same redaction chokepoint as the rest of the prompt — that is a
# PATH-SCOPE gate (out-of-scope file paths get OOS-wrapped), NOT a secret
# scrubber: an operator who puts secrets in their own override ships them, just
# as in any source file the model is allowed to read.
#
# Mirrors the per-repo template resolution precedent (ADR-016,
# core/pipeline/template-resolver.sh). Fail-OPEN: an override is additive
# guidance, never a safety gate, so absent/empty/unresolvable → empty, rc 0.

[[ -n "${_ZBUILD_PROMPT_OVERRIDES_LOADED:-}" ]] && return 0
_ZBUILD_PROMPT_OVERRIDES_LOADED=1

_PO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# scope_floor_denied: cheap string gate (absolute/../, legacy/, secrets).
# shellcheck source=./scope-governance.sh
source "$_PO_DIR/scope-governance.sh"

# Default soft cap on override size (bytes) — bounds prompt/token cost. The
# RUN_CAPTURED_CMD_MAX_BYTES precedent (helpers.sh) caps captured output the
# same way; an override that exceeds this is truncated with a visible marker.
: "${ZBUILD_PROMPT_OVERRIDE_MAX_BYTES:=32768}"

# load_prompt_override <stage> [repo_root]
#   Reads <repo_root>/.zbuild/prompts/<stage>-overrides.md and echoes its
#   content (truncated at the size cap), or nothing.
#   repo_root defaults to the TARGET repo (ZBUILD_REPO_ROOT → git toplevel →
#   pwd) — the same triplet design/build/test plugins already resolve.
#   Always rc 0 (fail-open). Refuses (→ empty) on: non-canonical stage,
#   floor-denied path, absent/empty file, or a symlink escaping the prompts dir.
load_prompt_override() {
    local stage="${1:-}"
    local repo_root="${2:-${ZBUILD_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"

    # Stage must be a canonical id with no path components (mirrors the
    # stage-shape guard in runner.sh). Blocks `../../etc/passwd`, `/etc/passwd`,
    # `design/../plan`, etc. at the source.
    [[ "$stage" =~ ^[a-z][a-z0-9_-]*$ ]] || return 0

    local rel=".zbuild/prompts/${stage}-overrides.md"
    # Belt-and-suspenders string floor (the stage regex already prevents escapes).
    scope_floor_denied "$rel" && return 0

    local override_file="$repo_root/$rel"
    # -f follows symlinks: a symlink to a nonexistent target is false here.
    [[ -f "$override_file" && -s "$override_file" ]] || return 0

    # Symlink containment: the override's REAL path must sit strictly under the
    # target repo's real .zbuild/prompts/. Bare `realpath` only (no GNU-only
    # -m/-e flags) so BSD and GNU agree. Canonicalizing both sides catches a
    # design-overrides.md symlinked out (→ /etc/passwd) AND a prompts/ dir that
    # is itself a symlink out — neither is caught by the string floor above.
    local real_root real_file expected_dir
    real_root="$(realpath "$repo_root" 2>/dev/null)" || return 0
    real_file="$(realpath "$override_file" 2>/dev/null)" || return 0
    expected_dir="$real_root/.zbuild/prompts"
    case "$real_file" in
        "$expected_dir"/*) : ;;
        *) return 0 ;;
    esac

    # Hardlink containment: realpath cannot see through a hardlink (it has no
    # link target), so a hardlink to an out-of-tree file passes the check above
    # and would leak that file's content. A legitimate override is never a
    # hardlink — refuse anything with link count > 1. (BSD stat -f %l / GNU -c %h.)
    local nlink
    nlink="$(stat -f '%l' "$real_file" 2>/dev/null || stat -c '%h' "$real_file" 2>/dev/null || echo 1)"
    [[ "$nlink" == "1" ]] || return 0

    # Sanitize the (operator-exportable) size cap: a non-numeric value would make
    # `(( size > $cap ))` resolve $cap as a variable name → 0 → truncate-to-empty.
    local max="$ZBUILD_PROMPT_OVERRIDE_MAX_BYTES"
    [[ "$max" =~ ^[0-9]+$ ]] || max=32768

    local size
    # BSD wc -c pads with leading spaces — strip to bare digits.
    size="$(wc -c < "$override_file" 2>/dev/null | tr -d '[:space:]')"
    [[ "$size" =~ ^[0-9]+$ ]] || size=0
    if (( size > max )); then
        head -c "$max" "$override_file"
        printf '\n[override truncated at %d bytes]\n' "$max"
        return 0
    fi
    cat "$override_file"
    return 0
}
