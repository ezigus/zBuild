#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  zBuild core/state/artifact-persist — durable prior-run artifact store     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Issue #1581. Generic, STAGE-AGNOSTIC persistence of a run's artifact area onto a
# SEPARATE state branch (`zbuild/state/issue-<N>`), so a later run of the same
# issue can pick prior work back up — locally or on a fresh CI runner where
# state/ is ephemeral. The store is a sibling branch that is NEVER part of the
# work branch's history, so it can never merge to main and never pollutes the PR
# diff (see #1581 design). This module knows nothing about individual stages or
# what any artifact means; it snapshots whatever files live in the artifact area.
#
# Sourced library: inherits caller's pipefail settings; do NOT add set -euo here.
# All operations are best-effort: a failure returns non-zero but never aborts the
# run (callers treat persistence as advisory).


# #2010: zbuild_engine_tmp names where engine code writes temp files.
# Lazy-sourced, same pattern lifecycle.sh uses for stage-scratch.sh: this
# file is sourced from several entry points and cannot assume helpers.sh
# arrived first. helpers.sh sources only compat.sh, so there is no cycle.
if ! declare -F zbuild_engine_tmp >/dev/null 2>&1; then
    # shellcheck source=../../scripts/lib/helpers.sh
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib" && pwd)/helpers.sh" 2>/dev/null || true
fi

[[ -n "${_ZBUILD_ARTIFACT_PERSIST_LOADED:-}" ]] && return 0
_ZBUILD_ARTIFACT_PERSIST_LOADED=1

# #1931: zbuild_run_key, for a --goal run's own state branch. Guarded — this
# file is sourced from contexts that may not have scripts/lib on hand.
_ZBUILD_AP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$_ZBUILD_AP_DIR/../../scripts/lib/identity.sh" ]]; then
    # shellcheck source=../../scripts/lib/identity.sh
    source "$_ZBUILD_AP_DIR/../../scripts/lib/identity.sh"
fi

# ─── Outcome channel (#1878) ─────────────────────────────────────────────────
# rc alone cannot distinguish "persisted", "nothing to persist" and "failed" —
# and it used to report the middle one as the first, so the runner emitted
# artifact.snapshot.saved for a snapshot that saved nothing. rc stays ∈ {0,1}
# (callers and existing tests depend on it); the detail rides these globals.
#
#   _ARTIFACT_PERSIST_LAST_STATUS  snapshot: saved | empty | unchanged | failed
#                                  restore:  restored | empty | failed
#   _ARTIFACT_PERSIST_LAST_REASON  on failed: the git op, its stderr, and the
#                                  resolved repo_root/git-dir (the two values a
#                                  silent failure used to hide)
#   _ARTIFACT_PERSIST_LAST_SKIPPED count of files skipped but not fatal
_ARTIFACT_PERSIST_LAST_STATUS=""
# #1921: WHERE a restore came from — "local" (refs/heads) or "remote"
# (refs/remotes/origin); empty for non-restore operations. "The branch exists"
# and "this run fetched it from origin" are different facts, and only the second
# answers whether a CI run started WARM. Without this the question can only be
# inferred from log lines.
_ARTIFACT_PERSIST_LAST_SOURCE=""
_ARTIFACT_PERSIST_LAST_REASON=""
_ARTIFACT_PERSIST_LAST_SKIPPED=0

# Reset the outcome channel. Called at the top of every public entry point so a
# caller can never read a stale status from a previous invocation.
_artifact_persist_reset_status() {
    _ARTIFACT_PERSIST_LAST_SOURCE=""
    _ARTIFACT_PERSIST_LAST_STATUS=""
    _ARTIFACT_PERSIST_LAST_REASON=""
    _ARTIFACT_PERSIST_LAST_SKIPPED=0
}

# ─── _artifact_persist_has_identity <issue> [goal] ───────────────────────────
# rc=0 when this run has an identity to persist UNDER — an issue number, or a
# goal (#1931). Replaces the `issue > 0` idiom, which predates goal identity and
# silently excluded every --goal run from the durable store.
#
# The guard must be the IDENTITY, not the issue number. Guarding on `issue > 0`
# and then deriving the branch means the derivation never runs for a goal run,
# so `zbuild/state/goal-<hash>` is computed correctly and never used — which is
# exactly the gap review found: the branch NAME was right and nothing pushed to
# it.
_artifact_persist_has_identity() {
    local issue="${1:-0}" goal="${2:-${ZBUILD_GOAL:-}}"
    [[ "$issue" =~ ^[0-9]+$ && "$issue" -gt 0 ]] && return 0
    [[ -n "${goal//[[:space:]]/}" ]] && declare -F zbuild_run_key >/dev/null 2>&1
}

# ─── _artifact_persist_branch <issue> ───────────────────────────────────────
# The state branch name for an issue. Sibling to the work branch; never merged.
# #1931: takes the goal text as an optional second argument so a `--goal` run
# gets its own durable branch instead of sharing `issue-0` with every other one.
# Callers that pass only an issue are unchanged.
_artifact_persist_branch() {
    local issue="${1:-0}" goal="${2:-${ZBUILD_GOAL:-}}"
    if [[ "$issue" =~ ^[0-9]+$ && "$issue" -gt 0 ]]; then
        printf 'zbuild/state/issue-%s' "$issue"
        return 0
    fi
    local key=""
    if declare -F zbuild_run_key >/dev/null 2>&1; then
        key="$(zbuild_run_key "$issue" "$goal" 2>/dev/null || true)"
    fi
    if [[ -n "$key" ]]; then
        printf 'zbuild/state/%s' "$key"
    else
        # Unchanged fallback: no issue and no goal is no identity.
        printf 'zbuild/state/issue-%s' "$issue"
    fi
}
# ─── _artifact_persist_git_dir <repo_root> ───────────────────────────────────
# Resolve the git dir to use for plumbing. NOT "$repo_root/.git": in a linked
# worktree that path is a FILE (`gitdir: …/.git/worktrees/<name>`), and while git
# does follow the pointer, it resolves to the PER-WORKTREE git dir. Objects are
# shared, so blobs and trees are safe — but refs are not: `update-ref
# refs/heads/zbuild/state/issue-N` would land in that worktree's ref view rather
# than the shared store, so the next run would not find the state branch.
# --git-common-dir returns the shared dir for both a main tree and a worktree.
_artifact_persist_git_dir() {
    local repo_root="${1:-}"
    local d
    d="$(git -C "$repo_root" rev-parse --git-common-dir 2>/dev/null)" || { printf '%s/.git' "$repo_root"; return 0; }
    # --git-common-dir may be relative to repo_root (commonly ".git").
    case "$d" in
        /*) printf '%s' "$d" ;;
        *)  printf '%s/%s' "$repo_root" "$d" ;;
    esac
}


# ─── _artifact_persist_snapshot <state_dir> <issue> [repo_root] ─────────────
# Commit the current artifact area onto the state branch WITHOUT touching the
# working tree or the real index (uses a throwaway GIT_INDEX_FILE + plumbing).
# Snapshots state/artifacts/** plus a few top-level state docs if present.
# Returns 0 on success (or clean no-op when there is nothing to snapshot), 1 on
# any git failure. Never disturbs the caller's checkout.
_artifact_persist_snapshot() {
    _artifact_persist_reset_status
    local state_dir="$1" issue="${2:-0}" repo_root="${3:-$(git rev-parse --show-toplevel 2>/dev/null)}"
    # #1921: "amend" replaces the branch tip instead of committing on top of it.
    # persist must snapshot twice — the first snapshot cannot contain the result
    # file that describes it — and a second commit whose only delta is a status
    # file is the commit spam ADR-050 §4 rules out. Callers pass this ONLY when
    # they created the current tip themselves this invocation; amending a tip
    # written by someone else would discard a legitimate boundary snapshot.
    local mode="${4:-}"
    # Resolve the SHARED git dir before the guard uses it. The guard previously
    # tested `-d "$repo_root/.git"`, which is FALSE in a linked worktree (.git is
    # a file there), so persistence would silently no-op inside a worktree.
    local _gd=""
    [[ -n "$repo_root" ]] && _gd="$(_artifact_persist_git_dir "$repo_root")"
    # #1878: this is NOT "nothing to do" — it means we could not resolve a repo to
    # persist INTO, which is a real failure the caller must be able to see. It
    # used to `return 0`, which the runner reported as a successful snapshot.
    if [[ -z "$repo_root" || ! -d "$_gd" ]]; then
        _ARTIFACT_PERSIST_LAST_STATUS="failed"
        _ARTIFACT_PERSIST_LAST_REASON="unresolvable repo: repo_root=[${repo_root:-<empty>}] git_dir=[${_gd:-<empty>}] cwd=[$PWD]"
        return 1
    fi
    local art_dir="$state_dir/artifacts"
    if [[ ! -d "$art_dir" ]]; then
        _ARTIFACT_PERSIST_LAST_STATUS="empty"
        _ARTIFACT_PERSIST_LAST_REASON="no artifact dir at $art_dir"
        return 0
    fi

    local branch; branch="$(_artifact_persist_branch "$issue")"
    # A NON-existent path: git initializes a fresh index there. A pre-created
    # empty file (plain mktemp) is rejected as "index file smaller than expected".
    local tmp_index
    if ! tmp_index="$(mktemp -u "$(zbuild_engine_tmp)/zbuild-persist-idx.XXXXXX")"; then
        _ARTIFACT_PERSIST_LAST_STATUS="failed"
        _ARTIFACT_PERSIST_LAST_REASON="mktemp for throwaway index failed (TMPDIR=${TMPDIR:-/tmp})"
        return 1
    fi

    # Build a tree from the artifact files under a stable prefix (artifacts/…),
    # plus a couple of top-level state docs, in a throwaway index.
    #
    # #1878: SKIP a file we cannot stage, do not abort the snapshot. This loop
    # used to `break` on the first failure, discarding every artifact already
    # staged — while the `extra` loop below has always skipped-and-continued. A
    # file that vanished mid-scan (the artifact area has live writers) or is
    # unreadable must cost us that one file, not the whole snapshot.
    local added=0 skipped=0 f rel blob first_skip=""
    while IFS= read -r -d '' f; do
        rel="artifacts/${f#"$art_dir"/}"
        if ! blob="$(GIT_DIR="$_gd" git hash-object -w "$f" 2>/dev/null)"; then
            skipped=$((skipped + 1)); [[ -z "$first_skip" ]] && first_skip="$rel (hash-object)"
            continue
        fi
        if ! GIT_INDEX_FILE="$tmp_index" GIT_DIR="$_gd" \
                git update-index --add --cacheinfo "100644,$blob,$rel" 2>/dev/null; then
            skipped=$((skipped + 1)); [[ -z "$first_skip" ]] && first_skip="$rel (update-index)"
            continue
        fi
        added=$((added + 1))
    done < <(find "$art_dir" -type f -print0 2>/dev/null)

    # Include a handful of top-level state docs when present (scope manifest etc.).
    local extra
    for extra in scope-manifest.md intake.md; do
        [[ -f "$state_dir/$extra" ]] || continue
        if ! blob="$(GIT_DIR="$_gd" git hash-object -w "$state_dir/$extra" 2>/dev/null)"; then
            skipped=$((skipped + 1)); [[ -z "$first_skip" ]] && first_skip="$extra (hash-object)"
            continue
        fi
        # #1878: was `|| true` followed by an unconditional added++ — it counted a
        # doc that update-index had just REFUSED, inflating `added` and letting a
        # snapshot claim it staged something it had not.
        if ! GIT_INDEX_FILE="$tmp_index" GIT_DIR="$_gd" \
                git update-index --add --cacheinfo "100644,$blob,$extra" 2>/dev/null; then
            skipped=$((skipped + 1)); [[ -z "$first_skip" ]] && first_skip="$extra (update-index)"
            continue
        fi
        added=$((added + 1))
    done

    _ARTIFACT_PERSIST_LAST_SKIPPED="$skipped"

    # Nothing staged at all. If files were SKIPPED that is a failure (we had work
    # and lost it); if there were simply no files, it is an honest empty.
    if [[ "$added" -eq 0 ]]; then
        rm -f "$tmp_index"
        if [[ "$skipped" -gt 0 ]]; then
            _ARTIFACT_PERSIST_LAST_STATUS="failed"
            _ARTIFACT_PERSIST_LAST_REASON="all $skipped file(s) unstageable, first: $first_skip"
            return 1
        fi
        _ARTIFACT_PERSIST_LAST_STATUS="empty"
        _ARTIFACT_PERSIST_LAST_REASON="no files under $art_dir"
        return 0
    fi

    # #1878: capture stderr from the terminal ops. They used to be 2>/dev/null
    # followed by a bare `return 1`, so a failure named itself and destroyed its
    # own explanation — the #1631 anti-pattern, and the reason this defect went
    # undiagnosed for the life of the feature.
    local tree parent commit err
    if ! tree="$(GIT_INDEX_FILE="$tmp_index" GIT_DIR="$_gd" git write-tree 2>"$tmp_index.err")"; then
        err="$(cat "$tmp_index.err" 2>/dev/null | tr '\n' ' ')"
        rm -f "$tmp_index" "$tmp_index.err"
        _ARTIFACT_PERSIST_LAST_STATUS="failed"
        _ARTIFACT_PERSIST_LAST_REASON="git write-tree failed: ${err:-<no stderr>} (git_dir=$_gd)"
        return 1
    fi
    rm -f "$tmp_index" "$tmp_index.err"

    local tip; tip="$(GIT_DIR="$_gd" git rev-parse -q --verify "refs/heads/$branch" 2>/dev/null || true)"

    # Unchanged is judged against the TIP in both modes: it asks "does the branch
    # already say this?", which amending does not change.
    if [[ -n "$tip" ]]; then
        local tip_tree; tip_tree="$(GIT_DIR="$_gd" git rev-parse -q --verify "$tip^{tree}" 2>/dev/null || true)"
        if [[ "$tip_tree" == "$tree" ]]; then
            _ARTIFACT_PERSIST_LAST_STATUS="unchanged"
            _ARTIFACT_PERSIST_LAST_REASON="tree identical to $branch tip"
            return 0
        fi
    fi

    if [[ "$mode" == "amend" && -n "$tip" ]]; then
        # Parent is the tip's parent, so the new commit REPLACES the tip. Empty
        # when the tip is a root commit, which correctly yields a new root.
        parent="$(GIT_DIR="$_gd" git rev-parse -q --verify "${tip}^" 2>/dev/null || true)"
    else
        parent="$tip"
    fi

    local msg="zbuild: persist artifacts for #$issue [skip ci]"
    # PR #1880 review: guard the mktemp. An unguarded one leaves _ct_err empty,
    # `2>""` then fails to open, and commit-tree fails for the WRONG reason with
    # no captured stderr — a silent failure inside the code whose whole purpose is
    # to stop silent failures. /dev/null is the honest fallback: we lose the
    # stderr detail but still report the real git failure.
    local _ct_err; _ct_err="$(mktemp -u "$(zbuild_engine_tmp)/zbuild-persist-err.XXXXXX" 2>/dev/null)" || _ct_err="/dev/null"
    [[ -n "$_ct_err" ]] || _ct_err="/dev/null"
    if [[ -n "$parent" ]]; then
        commit="$(GIT_DIR="$_gd" git commit-tree "$tree" -p "$parent" -m "$msg" 2>"$_ct_err")" || commit=""
    else
        commit="$(GIT_DIR="$_gd" git commit-tree "$tree" -m "$msg" 2>"$_ct_err")" || commit=""
    fi
    if [[ -z "$commit" ]]; then
        err="$(cat "$_ct_err" 2>/dev/null | tr '\n' ' ')"
        rm -f "$_ct_err"
        _ARTIFACT_PERSIST_LAST_STATUS="failed"
        # A missing committer identity lands here — the most likely cause on a
        # fresh runner, and previously indistinguishable from every other failure.
        _ARTIFACT_PERSIST_LAST_REASON="git commit-tree failed: ${err:-<no stderr>} (git_dir=$_gd)"
        return 1
    fi
    rm -f "$_ct_err"

    # PR #1880 review: guarded (see the _ct_err note above).
    local _ur_err; _ur_err="$(mktemp -u "$(zbuild_engine_tmp)/zbuild-persist-err.XXXXXX" 2>/dev/null)" || _ur_err="/dev/null"
    [[ -n "$_ur_err" ]] || _ur_err="/dev/null"
    if ! GIT_DIR="$_gd" git update-ref "refs/heads/$branch" "$commit" 2>"$_ur_err"; then
        err="$(cat "$_ur_err" 2>/dev/null | tr '\n' ' ')"
        rm -f "$_ur_err"
        _ARTIFACT_PERSIST_LAST_STATUS="failed"
        _ARTIFACT_PERSIST_LAST_REASON="git update-ref $branch failed: ${err:-<no stderr>} (git_dir=$_gd)"
        return 1
    fi
    rm -f "$_ur_err"

    _ARTIFACT_PERSIST_LAST_STATUS="saved"
    _ARTIFACT_PERSIST_LAST_REASON="staged $added file(s), skipped $skipped"
    return 0
}

# ─── _artifact_persist_adopt_remote <issue> [repo_root] (#1921) ─────────────
# Point the LOCAL `refs/heads/<branch>` at the fetched remote-tracking ref, but
# ONLY when the local ref does not already exist.
#
# WHY: `_hydrate_fetch` updates `refs/remotes/origin/<branch>` and deliberately
# never touches `refs/heads`. On a CI runner refs/heads therefore never exists —
# so `_artifact_persist_snapshot` finds no parent (:229) and ROOTS a new history,
# and the `--force` push then orphans everything already on origin. The branch
# could never accumulate in CI, the `unchanged` short-circuit could never fire,
# and two concurrent runs could clobber each other with no common ancestor.
#
# ABSENT-ONLY IS THE POINT, not a micro-optimisation. hydrate's manifest states
# the invariant: a LOCAL snapshot wins on read when both exist, because it may
# carry work an earlier push never delivered. Adopting unconditionally would
# discard exactly that work.
_artifact_persist_adopt_remote() {
    _artifact_persist_reset_status
    local issue="${1:-0}" repo_root="${2:-$(git rev-parse --show-toplevel 2>/dev/null)}"

    _artifact_persist_has_identity "$issue" || {
        _ARTIFACT_PERSIST_LAST_STATUS="empty"
        _ARTIFACT_PERSIST_LAST_REASON="no identity to adopt under"
        return 0
    }

    local _gd=""
    [[ -n "$repo_root" ]] && _gd="$(_artifact_persist_git_dir "$repo_root")"
    if [[ -z "$repo_root" || ! -d "$_gd" ]]; then
        _ARTIFACT_PERSIST_LAST_STATUS="failed"
        _ARTIFACT_PERSIST_LAST_REASON="unresolvable repo: repo_root=[${repo_root:-<empty>}] git_dir=[${_gd:-<empty>}]"
        return 1
    fi

    local branch; branch="$(_artifact_persist_branch "$issue")"

    if GIT_DIR="$_gd" git rev-parse -q --verify "refs/heads/$branch" >/dev/null 2>&1; then
        _ARTIFACT_PERSIST_LAST_STATUS="kept"
        _ARTIFACT_PERSIST_LAST_REASON="local $branch already exists — left untouched"
        return 0
    fi

    local remote_tip
    if ! remote_tip="$(GIT_DIR="$_gd" git rev-parse -q --verify "refs/remotes/origin/$branch" 2>/dev/null)" \
            || [[ -z "$remote_tip" ]]; then
        _ARTIFACT_PERSIST_LAST_STATUS="empty"
        _ARTIFACT_PERSIST_LAST_REASON="no refs/remotes/origin/$branch to adopt (first run)"
        return 0
    fi

    local _ar_err; _ar_err="$(mktemp -u "$(zbuild_engine_tmp)/zbuild-adopt-err.XXXXXX" 2>/dev/null)" || _ar_err="/dev/null"
    [[ -n "$_ar_err" ]] || _ar_err="/dev/null"
    if ! GIT_DIR="$_gd" git update-ref "refs/heads/$branch" "$remote_tip" 2>"$_ar_err"; then
        local err; err="$(cat "$_ar_err" 2>/dev/null | tr '\n' ' ')"
        [[ "$_ar_err" != "/dev/null" ]] && rm -f "$_ar_err"
        _ARTIFACT_PERSIST_LAST_STATUS="failed"
        _ARTIFACT_PERSIST_LAST_REASON="git update-ref $branch failed: ${err:-<no stderr>} (git_dir=$_gd)"
        return 1
    fi
    [[ "$_ar_err" != "/dev/null" ]] && rm -f "$_ar_err"
    _ARTIFACT_PERSIST_LAST_STATUS="adopted"
    _ARTIFACT_PERSIST_LAST_REASON="adopted origin/$branch as the local snapshot parent"
    return 0
}

# ─── _artifact_persist_push <issue> [repo_root] (#1071) ─────────────────────
# Push `zbuild/state/issue-<N>` to origin.
#
# WHY THIS DID NOT EXIST: this file has never contained a `git push`. It writes
# a LOCAL ref with plumbing and reads `refs/remotes/origin/<branch>` only as a
# restore fallback. The only state-branch push in the repository is a shell
# block inside `.github/workflows/zbuild-pipeline.yml`, which no local run
# executes — so ADR-050 §4's "push the state branch once at the end, pass or
# fail" was true of CI and of nothing else. #1921 measured the consequence.
#
# BEST-EFFORT BY CONTRACT. A failed push degrades to "state is local only",
# which is today's behaviour for every local run — so the fallback is already
# proven in production. It sets status/reason for the caller to REPORT; a silent
# failure here is precisely how #1921 went unnoticed for the life of the
# feature.
#
# `--force` matches the existing CI push: the state branch is a snapshot, not a
# history, and a snapshot that refuses to advance because it is not a
# fast-forward is a snapshot nobody can use. The concurrency hazard that creates
# is #1764's, and it is answered by ADR-059 §4's per-issue admission lock — not
# by making this a non-force push, which would simply fail instead.
_artifact_persist_push() {
    _artifact_persist_reset_status
    local issue="${1:-0}" repo_root="${2:-$(git rev-parse --show-toplevel 2>/dev/null)}"
    _artifact_persist_has_identity "$issue" || {
        _ARTIFACT_PERSIST_LAST_STATUS="empty"
        _ARTIFACT_PERSIST_LAST_REASON="no identity to push under (issue=${issue:-<empty>}, no goal)"
        return 0
    }
    local _gd=""
    [[ -n "$repo_root" ]] && _gd="$(_artifact_persist_git_dir "$repo_root")"
    if [[ -z "$repo_root" || ! -d "$_gd" ]]; then
        _ARTIFACT_PERSIST_LAST_STATUS="failed"
        _ARTIFACT_PERSIST_LAST_REASON="unresolvable repo: repo_root=[${repo_root:-<empty>}] git_dir=[${_gd:-<empty>}]"
        return 1
    fi

    local branch; branch="$(_artifact_persist_branch "$issue")"
    if ! GIT_DIR="$_gd" git rev-parse -q --verify "refs/heads/$branch" >/dev/null 2>&1; then
        _ARTIFACT_PERSIST_LAST_STATUS="empty"
        _ARTIFACT_PERSIST_LAST_REASON="no local branch $branch to push (nothing was snapshotted)"
        return 0
    fi
    if ! GIT_DIR="$_gd" git remote get-url origin >/dev/null 2>&1; then
        _ARTIFACT_PERSIST_LAST_STATUS="empty"
        _ARTIFACT_PERSIST_LAST_REASON="no origin remote configured"
        return 0
    fi

    local _p_err; _p_err="$(mktemp "$(zbuild_engine_tmp)/zbuild-push-err.XXXXXX" 2>/dev/null || printf '')"
    if GIT_DIR="$_gd" git push --force origin \
            "refs/heads/$branch:refs/heads/$branch" 2>"${_p_err:-/dev/null}"; then
        _ARTIFACT_PERSIST_LAST_STATUS="saved"
        _ARTIFACT_PERSIST_LAST_REASON="pushed $branch to origin"
        [[ -n "$_p_err" ]] && rm -f "$_p_err"
        return 0
    fi
    local err=""; [[ -n "$_p_err" ]] && err="$(tr '\n' ' ' < "$_p_err" 2>/dev/null | cut -c1-300)"
    [[ -n "$_p_err" ]] && rm -f "$_p_err"
    _ARTIFACT_PERSIST_LAST_STATUS="failed"
    _ARTIFACT_PERSIST_LAST_REASON="git push $branch failed: ${err:-<no stderr>}"
    return 1
}

# ─── _artifact_persist_restore <issue> <restored_dir> [repo_root] ───────────
# Extract the tip of the state branch into <restored_dir> (created if absent).
# Prefers a local refs/heads/<branch>; falls back to refs/remotes/origin/<branch>
# when only the fetched remote ref is present (CI). No-op (rc 0, empty dir) when
# no state branch exists. Never touches the working tree.
_artifact_persist_restore() {
    _artifact_persist_reset_status
    local issue="${1:-0}" restored_dir="$2" repo_root="${3:-$(git rev-parse --show-toplevel 2>/dev/null)}"
    # Resolve the SHARED git dir (see _artifact_persist_git_dir). Two reasons:
    #   1. refs must be read from the shared store, not a per-worktree view;
    #   2. the old guard tested `-d "$repo_root/.git"`, which is FALSE in a linked
    #      worktree because .git is a file there — restore would silently no-op and
    #      prior artifacts would never come back, with no error to notice.
    local _gd=""
    [[ -n "$repo_root" ]] && _gd="$(_artifact_persist_git_dir "$repo_root")"
    [[ -z "$restored_dir" ]] && { _ARTIFACT_PERSIST_LAST_STATUS="failed"
        _ARTIFACT_PERSIST_LAST_REASON="no restored_dir given"; return 2; }
    if [[ -z "$repo_root" || ! -d "$_gd" ]]; then
        _ARTIFACT_PERSIST_LAST_STATUS="failed"
        _ARTIFACT_PERSIST_LAST_REASON="unresolvable repo: repo_root=[${repo_root:-<empty>}] git_dir=[${_gd:-<empty>}] cwd=[$PWD]"
        return 1
    fi

    local branch; branch="$(_artifact_persist_branch "$issue")"
    local ref=""
    if GIT_DIR="$_gd" git rev-parse -q --verify "refs/heads/$branch" >/dev/null 2>&1; then
        ref="refs/heads/$branch"
        _ARTIFACT_PERSIST_LAST_SOURCE="local"
    elif GIT_DIR="$_gd" git rev-parse -q --verify "refs/remotes/origin/$branch" >/dev/null 2>&1; then
        ref="refs/remotes/origin/$branch"
        _ARTIFACT_PERSIST_LAST_SOURCE="remote"
    else
        # A first-ever run for this issue. Genuinely nothing to restore — the one
        # early return here that is NOT a failure.
        _ARTIFACT_PERSIST_LAST_STATUS="empty"
        _ARTIFACT_PERSIST_LAST_REASON="no $branch locally or on origin (first run)"
        return 0
    fi

    if ! mkdir -p "$restored_dir"; then
        _ARTIFACT_PERSIST_LAST_STATUS="failed"
        _ARTIFACT_PERSIST_LAST_REASON="mkdir -p $restored_dir failed"
        return 1
    fi
    # git archive streams the tree; tar unpacks it, no checkout / index change.
    # #1878: PIPESTATUS, not the pipeline rc — a failing `git archive` piped into
    # a happy `tar` yields rc=0, so a broken restore reported success.
    # PR #1880 review: guarded (see the _ct_err note above).
    local _ar_err; _ar_err="$(mktemp -u "$(zbuild_engine_tmp)/zbuild-restore-err.XXXXXX" 2>/dev/null)" || _ar_err="/dev/null"
    [[ -n "$_ar_err" ]] || _ar_err="/dev/null"
    GIT_DIR="$_gd" git archive "$ref" 2>"$_ar_err" | tar -x -C "$restored_dir" 2>>"$_ar_err"
    local _st=("${PIPESTATUS[@]}")
    if [[ "${_st[0]}" -ne 0 || "${_st[1]}" -ne 0 ]]; then
        local err; err="$(cat "$_ar_err" 2>/dev/null | tr '\n' ' ')"
        rm -f "$_ar_err"
        _ARTIFACT_PERSIST_LAST_STATUS="failed"
        _ARTIFACT_PERSIST_LAST_REASON="restore of $ref failed (archive rc=${_st[0]} tar rc=${_st[1]}): ${err:-<no stderr>}"
        return 1
    fi
    rm -f "$_ar_err"
    # PR #1880 review: "restored", NOT "saved". The same channel carries both
    # operations' outcomes, so reusing "saved" would let a caller checking
    # `== "saved"` to confirm a SNAPSHOT be satisfied by a restore that happened
    # to run first — the restore runs once at startup, before any snapshot.
    _ARTIFACT_PERSIST_LAST_STATUS="restored"
    _ARTIFACT_PERSIST_LAST_REASON="restored from $ref"
    return 0
}
