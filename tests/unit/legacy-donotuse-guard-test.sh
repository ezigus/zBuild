#!/usr/bin/env bash
# Guard: the frozen upstream tree lives at legacy-DoNotUse/ and nothing points at its old
# path (ADR-002 amendment 2026-10-09).
#
# [ADR-002/PATH]      there is no directory named "legacy" at the repo root, and git tracks
#                     nothing under it
# [ADR-002/NO-TOMB]   the frozen tree has no migrated directory — there are no tombstones;
#                     a keeper's replacement lands with a `git rm` and nothing else is written
# [ADR-002/NO-REFS]   no tracked file outside the frozen tree names the old path. ADRs and the
#                     dated audits under docs/audits/ are exempt: they keep history as written.
#
# The old path is spelled `legacy[/]` in the patterns below so this file does not match itself.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "the frozen tree is legacy-DoNotUse/, with no tombstones and no old-path references (ADR-002)"

# ── PATH ─────────────────────────────────────────────────────────────────────
_old_tracked="$(git -C "$REPO_ROOT" ls-files -- 'legacy' 2>/dev/null || true)"
if [[ ! -e "$REPO_ROOT/legacy" && -z "$_old_tracked" ]]; then
    assert_pass "[ADR-002/PATH] no legacy directory at the repo root"
else
    assert_fail "[ADR-002/PATH] the frozen tree must live at legacy-DoNotUse/, not at the repo root's legacy" \
        "on disk: $([[ -e "$REPO_ROOT/legacy" ]] && echo yes || echo no); tracked: ${_old_tracked:0:200}"
fi

# ── NO-TOMB ──────────────────────────────────────────────────────────────────
_tomb_dir="legacy-DoNotUse"/migrated   # spelled apart so the NO-REFS scan below skips this line
_tomb_tracked="$(git -C "$REPO_ROOT" ls-files -- "$_tomb_dir" 2>/dev/null || true)"
if [[ ! -e "$REPO_ROOT/$_tomb_dir" && -z "$_tomb_tracked" ]]; then
    assert_pass "[ADR-002/NO-TOMB] $_tomb_dir does not exist"
else
    assert_fail "[ADR-002/NO-TOMB] there are no tombstones: $_tomb_dir must not exist" \
        "${_tomb_tracked:0:400}"
fi

# ── NO-REFS ──────────────────────────────────────────────────────────────────
# A path token: the old directory name not glued to a longer name on its left
# (so `.shipwright-legacy/` and `app-legacy/` are not it), followed by a slash.
_old_path_re='(^|[^A-Za-z0-9_.-])legacy[/]'
_tomb_re='legacy-DoNotUse[/]migrated'
_offenders=""
while IFS= read -r -d '' _f; do
    case "$_f" in
        legacy-DoNotUse/*|docs/adr/*|docs/audits/*) continue ;;
    esac
    [[ -f "$REPO_ROOT/$_f" ]] || continue   # a sparse worktree lists files it left out
    _hits="$(/usr/bin/grep -nIE -e "$_old_path_re" -e "$_tomb_re" "$REPO_ROOT/$_f" 2>/dev/null || true)"
    [[ -n "$_hits" ]] || continue
    while IFS= read -r _h; do
        _offenders+="$_f:${_h:0:160}"$'\n'
    done <<< "$_hits"
done < <(git -C "$REPO_ROOT" ls-files -z 2>/dev/null)

if [[ -z "$_offenders" ]]; then
    assert_pass "[ADR-002/NO-REFS] no tracked file outside the frozen tree names the old path or a tombstone"
else
    assert_fail "[ADR-002/NO-REFS] these lines still name the old legacy path or a tombstone" \
        "${_offenders:0:4000}"
fi

print_test_results
