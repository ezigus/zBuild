#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  zBuild cleanup library — safety predicates + scanners (#570)             ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Public mini-library: four reusable safety predicates plus scanners/applier
# used by `zbuild cleanup` and any future caller (e.g. `zbuild worktree
# remove`, daemon idle-detection). Predicates are fail-CLOSED: when uncertain,
# they return "unsafe" so the caller skips deletion. See ADR pinning the
# contract.

[[ -n "${_ZBUILD_CLEANUP_LOADED:-}" ]] && return 0
_ZBUILD_CLEANUP_LOADED=1

# ─── Safety predicates ──────────────────────────────────────────────────────
# Contract: exit code only (0 = condition true, 1 = condition false).
# Predicates print nothing on stdout. Missing tools / errors => fail-closed
# (return 0 from is_current / dirty / unpushed; return 1 from has_merged_pr).

# _cleanup_is_current_branch <branch>
# True if the branch is the HEAD of any worktree of the current repo.
_cleanup_is_current_branch() {
    local b="$1"
    local head
    head="$(git symbolic-ref --short HEAD 2>/dev/null || true)"
    [[ "$head" == "$b" ]] && return 0
    # Scan worktrees: any worktree HEAD matching <b> counts as "current".
    local line
    while IFS= read -r line; do
        case "$line" in
            "branch refs/heads/$b") return 0 ;;
        esac
    done < <(git worktree list --porcelain 2>/dev/null || true)
    return 1
}

# _cleanup_has_uncommitted_work <branch>
# True if a worktree checking out <branch> has unstaged, staged, OR untracked
# changes. Fail-CLOSED: any error checking returns true (caller skips delete).
_cleanup_has_uncommitted_work() {
    local b="$1"
    # Locate worktree path for the branch (porcelain v1).
    local wt_path="" line cur_path=""
    while IFS= read -r line; do
        case "$line" in
            "worktree "*) cur_path="${line#worktree }" ;;
            "branch refs/heads/$b") wt_path="$cur_path"; break ;;
            "") cur_path="" ;;
        esac
    done < <(git worktree list --porcelain 2>/dev/null || true)
    # No worktree → branch cannot have uncommitted work.
    [[ -z "$wt_path" ]] && return 1
    [[ ! -d "$wt_path" ]] && return 0  # worktree path missing → fail-closed
    (
        cd "$wt_path" || exit 0
        git diff --quiet HEAD -- 2>/dev/null || exit 0
        git diff --cached --quiet 2>/dev/null || exit 0
        local untracked
        untracked="$(git ls-files --others --exclude-standard 2>/dev/null || echo "X")"
        [[ -n "$untracked" ]] && exit 0
        exit 1
    )
}

# _cleanup_has_unpushed_commits <branch>
# True if local branch is ahead of its upstream OR has no upstream configured.
# Fail-CLOSED: assume unpushed on any error.
_cleanup_has_unpushed_commits() {
    local b="$1"
    local upstream
    upstream="$(git rev-parse --abbrev-ref "$b@{upstream}" 2>/dev/null || true)"
    if [[ -z "$upstream" ]]; then
        return 0  # no upstream → treat as unpushed
    fi
    local ahead
    ahead="$(git rev-list --count "$upstream..$b" 2>/dev/null || echo "X")"
    if [[ "$ahead" == "X" ]]; then
        return 0  # error → fail-closed (unpushed)
    fi
    [[ "$ahead" -gt 0 ]] && return 0
    return 1
}

# _cleanup_has_merged_pr <branch>
# True if `gh` reports a merged PR with <branch> as head.
# Fail-CLOSED: gh missing / error / parse failure → return 1 (NOT merged →
# caller refuses to delete unless --force).
_cleanup_has_merged_pr() {
    local b="$1"
    command -v gh >/dev/null 2>&1 || return 1
    local out
    out="$(gh pr list --head "$b" --state merged --json number --jq 'length' 2>/dev/null || echo "X")"
    if [[ "$out" == "X" || -z "$out" ]]; then
        return 1
    fi
    [[ "$out" =~ ^[0-9]+$ ]] || return 1
    [[ "$out" -gt 0 ]] && return 0
    return 1
}

# ─── State-file scanner ─────────────────────────────────────────────────────
# _cleanup_scan_state_files <state_dir> <age_days> <force_bool>
# Prints one candidate per line: "<filepath>\t<reason>"
# Reason: "status=<s>;age=<days>d"
_cleanup_scan_state_files() {
    local state_dir="$1" age_days="$2" force="$3"
    [[ -d "$state_dir" ]] || return 0
    local now; now="$(date +%s)"
    local cutoff=$(( now - age_days * 86400 ))
    local f
    # #887: per-run state lives under runs/<id>/; scan those AND the legacy flat path.
    for f in "$state_dir"/runs/*/pipeline-state*.json "$state_dir"/pipeline-state*.json; do
        [[ -f "$f" ]] || continue
        # Skip .bak / .lock siblings (we never glob them anyway since pattern
        # ends in .json, but stay defensive).
        case "$f" in
            *.bak|*.lock) continue ;;
        esac
        local status
        status="$(jq -r '.status // ""' "$f" 2>/dev/null || echo "")"
        # in_progress NEVER pruned (even with --force) — running pipelines.
        [[ "$status" == "in_progress" ]] && continue
        # interrupted only with --force (preserves resume per ADR-018).
        if [[ "$status" == "interrupted" && "$force" != "true" ]]; then
            continue
        fi
        # Status must be in known terminal set OR force.
        case "$status" in
            complete|failed|aborted|interrupted) ;;
            *)
                [[ "$force" == "true" ]] || continue
                ;;
        esac
        # Age check (skip if newer than cutoff).
        # GNU stat first (Linux CI), then BSD (macOS dev). BSD stat -f doesn't
        # clean-fail on Linux — it returns garbage with rc=0, so trying it first
        # leaves non-numeric text in $mtime → arithmetic aborts under set -u.
        # (Codex P2 on #577 + Coverage CI failure.)
        local mtime
        mtime="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo "0")"
        [[ "$mtime" -gt "$cutoff" ]] && continue
        local age_d=$(( (now - mtime) / 86400 ))
        printf '%s\tstatus=%s;age=%sd\n' "$f" "$status" "$age_d"
    done
}

# ─── Branch scanner ─────────────────────────────────────────────────────────
# _cleanup_scan_branches <force_bool>
# Prints: "<branch>\t<decision>\t<reason>"
# decision ∈ {prune, skip}
_cleanup_scan_branches() {
    local force="$1"
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
    local b
    while IFS= read -r b; do
        b="${b## }"; b="${b#\* }"; b="${b## }"
        [[ -z "$b" ]] && continue
        [[ "$b" != zbuild/issue-* ]] && continue
        if _cleanup_is_current_branch "$b"; then
            printf '%s\tskip\tcurrent branch / active worktree\n' "$b"
            continue
        fi
        if _cleanup_has_uncommitted_work "$b"; then
            printf '%s\tskip\tuncommitted work in worktree\n' "$b"
            continue
        fi
        if _cleanup_has_unpushed_commits "$b"; then
            printf '%s\tskip\tunpushed commits / no upstream\n' "$b"
            continue
        fi
        if _cleanup_has_merged_pr "$b"; then
            printf '%s\tprune\tmerged PR\n' "$b"
            continue
        fi
        if [[ "$force" == "true" ]]; then
            printf '%s\tprune\tforce (clean, pushed, no merged PR)\n' "$b"
        else
            printf '%s\tskip\tno merged PR (use --force)\n' "$b"
        fi
    done < <(git branch --list 'zbuild/issue-*' --format '%(refname:short)' 2>/dev/null || true)
}

# ─── Apply plan ─────────────────────────────────────────────────────────────
# _cleanup_apply_plan <candidates_TSV> <dry_run_bool>
# candidates_TSV is the output of a scanner (one record per line).
# Returns 0 on success.
_cleanup_apply_plan() {
    local data="$1" dry_run="$2"
    [[ -z "$data" ]] && return 0
    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local target; target="${line%%$'\t'*}"
        if [[ "$dry_run" == "true" ]]; then
            continue
        fi
        if [[ -f "$target" ]]; then
            rm -f -- "$target" "$target.bak" "$target.lock" 2>/dev/null || true
        fi
    done <<<"$data"
}

# _cleanup_apply_branch_plan <branch_plan_TSV> <dry_run_bool>
# Each line: "<branch>\t<decision>\t<reason>". Deletes branches whose decision == prune.
_cleanup_apply_branch_plan() {
    local data="$1" dry_run="$2"
    [[ -z "$data" ]] && return 0
    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local b decision
        b="${line%%$'\t'*}"
        local rest="${line#*$'\t'}"
        decision="${rest%%$'\t'*}"
        [[ "$decision" != "prune" ]] && continue
        if [[ "$dry_run" == "true" ]]; then
            continue
        fi
        # Re-verify safety predicates immediately before delete (defence in depth).
        if _cleanup_is_current_branch "$b"; then continue; fi
        if _cleanup_has_uncommitted_work "$b"; then continue; fi
        if _cleanup_has_unpushed_commits "$b"; then continue; fi
        git branch -D "$b" >/dev/null 2>&1 || true
    done <<<"$data"
}

# ─── Active-run predicate (#594) ────────────────────────────────────────────
# _cleanup_is_active_run <run_id>
# True if any pipeline-state-*.json in $ZBUILD_STATE_DIR has matching .run_id
# AND .status == "in_progress". Fail-CLOSED: jq parse errors on a file we
# can't read are treated as "could be active" → return 0.
_cleanup_is_active_run() {
    local rid="$1"
    [[ -z "$rid" ]] && return 1
    local state_dir="${ZBUILD_STATE_DIR:-${ZBUILD_STATE_ROOT:-$HOME/.zbuild/state}}"
    [[ -d "$state_dir" ]] || return 1
    local f
    # #887: include per-run dirs (runs/<id>/) alongside the legacy flat path.
    for f in "$state_dir"/runs/*/pipeline-state*.json "$state_dir"/pipeline-state*.json; do
        [[ -f "$f" ]] || continue
        case "$f" in *.bak|*.lock) continue ;; esac
        local file_rid status
        # Single jq call, tolerate parse errors.
        if ! file_rid="$(jq -r '.run_id // ""' "$f" 2>/dev/null)"; then
            # jq couldn't parse. If filename hints at rid, fail-CLOSED.
            case "$f" in *"$rid"*) return 0 ;; esac
            continue
        fi
        [[ "$file_rid" != "$rid" ]] && continue
        status="$(jq -r '.status // ""' "$f" 2>/dev/null || echo "")"
        [[ "$status" == "in_progress" ]] && return 0
    done
    return 1
}

# Stash-message prefix gate — single source of truth (#752 discipline).
# Scanner, applier, and restore all match against THIS prefix.
ZBUILD_APPLYCHECK_PREFIX="zb-applycheck-"

# ─── Stash scanner (#594) ───────────────────────────────────────────────────
# _cleanup_scan_stashes <force_bool> <age_hours>
# Emits: "stash@{N}\t<decision>\t<reason>"
# decision ∈ {prune, skip}; reason includes message + run_id + reason text.
# ONLY considers stashes whose message starts with $ZBUILD_APPLYCHECK_PREFIX.
_cleanup_scan_stashes() {
    local force="$1" age_hours="$2"
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
    local now; now="$(date +%s)"
    local cutoff=$(( now - age_hours * 3600 ))
    local line
    # Use NUL-safe iteration; %gd=stash ref, %ct=committer ts, %s=subject.
    while IFS=$'\t' read -r ref ts subject; do
        [[ -z "$ref" ]] && continue
        # Strip "On <branch>: " prefix that git stash injects automatically when
        # the user did not pass -m. We seed with -m so subject == message.
        local msg="${subject#On *: }"
        msg="${msg#WIP on *: }"
        case "$msg" in
            "$ZBUILD_APPLYCHECK_PREFIX"*) ;;
            *) continue ;;  # never even mention non-prefix stashes
        esac
        # Extract run_id = trailing digits after final '-'.
        local rid="${msg##*-}"
        [[ "$rid" =~ ^[0-9]+$ ]] || rid=""
        # Active-run check (fail-CLOSED).
        if [[ -n "$rid" ]] && _cleanup_is_active_run "$rid"; then
            printf '%s\tskip\tactive run_id=%s msg=%s\n' "$ref" "$rid" "$msg"
            continue
        fi
        # Age check.
        if [[ "$ts" =~ ^[0-9]+$ && "$ts" -gt "$cutoff" ]]; then
            printf '%s\tskip\tnewer than %sh msg=%s\n' "$ref" "$age_hours" "$msg"
            continue
        fi
        # Note: --force is not required for stashes; the prefix + age + active
        # gates already encode safety. Force just suppresses age (caller can
        # pass age_hours=0). We still distinguish reasons for traceability.
        printf '%s\tprune\tzb-applycheck stash age_ok rid=%s msg=%s\n' "$ref" "${rid:-?}" "$msg"
    done < <(git stash list --format='%gd	%ct	%s' 2>/dev/null || true)
    _ZBUILD_UNUSED="$force"  # acknowledge param (reserved for future gating)
    unset _ZBUILD_UNUSED
}

# ─── Tmpdir patterns — single source of truth (#752) ────────────────────────
# Both the scanner and the applier read THIS array; never inline the globs
# anywhere else. The list drifted twice when it lived in two places (#628
# added zb-loop-iters.* scanner-only; #749 added zb-test-auto.*/zb-test.*
# scanner-only), each time making `--apply` a silent no-op for the new
# patterns while dry-run looked correct.
# Pattern provenance: zb-applycheck-* (apply-check stashes/dirs),
# zbuild-test-stage.* (plugins/tool/test), zb-loop-iters.* (Pattern-2 loop
# per-iter dirs, reaped here if something bypasses the RETURN trap),
# zb-test-auto.* (test-helpers.sh auto-init), zb-test.* (setup_test_env
# default name), zbuild-ephemeral-events.* (event-bus per-process default for
# UNPINNED ad-hoc invocations — #run-hygiene). #628 dropped pipeline-runner.*
# — nothing ever creates it.
# (#898: orch pool dirs now live under ${TMPDIR}/zbuild-runs/<run_id>/ and are
# reaped by orch_shutdown — same as the pre-#898 flat zbuild-pool-* dirs, they
# are intentionally NOT in this single-level scanner's pattern list.)
ZBUILD_TMPDIR_PATTERNS=(
    "zb-applycheck-*"
    "zbuild-test-stage.*"
    "zb-loop-iters.*"
    "zb-test-auto.*"
    "zb-test.*"
    "zbuild-ephemeral-events.*"
)

# ─── Tmpdir scanner (#594) ──────────────────────────────────────────────────
# _cleanup_scan_zbuild_tmpdirs <age_hours>
# Globs ${TMPDIR:-/tmp} for ZBUILD_TMPDIR_PATTERNS entries older than cutoff.
# Emits: "<path>\tprune\t<reason>".
_cleanup_scan_zbuild_tmpdirs() {
    local age_hours="$1"
    local now; now="$(date +%s)"
    local cutoff=$(( now - age_hours * 3600 ))
    local tmpd="${TMPDIR:-/tmp}"
    tmpd="${tmpd%/}"
    [[ -d "$tmpd" ]] || return 0
    local pattern path mtime age_h
    for pattern in "${ZBUILD_TMPDIR_PATTERNS[@]}"; do
        for path in "$tmpd"/$pattern; do
            [[ -e "$path" ]] || continue
            mtime="$(stat -c %Y "$path" 2>/dev/null || stat -f %m "$path" 2>/dev/null || echo "0")"
            [[ "$mtime" =~ ^[0-9]+$ ]] || continue
            [[ "$mtime" -gt "$cutoff" ]] && continue
            age_h=$(( (now - mtime) / 3600 ))
            printf '%s\tprune\tpattern=%s age=%sh\n' "$path" "$pattern" "$age_h"
        done
    done
}

# ─── Tmpdir applier (#752) ──────────────────────────────────────────────────
# _cleanup_apply_tmpdir_plan <plan_TSV> <dry_run_bool>
# Re-validates each target's basename against ZBUILD_TMPDIR_PATTERNS at
# delete-time (defence in depth, same discipline as the stash applier) —
# but against the SAME array the scanner used, so the validation can never
# drift out of sync with the scan.
_cleanup_apply_tmpdir_plan() {
    local data="$1" dry_run="$2"
    [[ "$dry_run" == "true" ]] && return 0
    [[ -z "$data" ]] && return 0
    local line target base pattern matched
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        target="${line%%$'\t'*}"
        [[ -d "$target" ]] || continue
        base="${target##*/}"
        matched="false"
        for pattern in "${ZBUILD_TMPDIR_PATTERNS[@]}"; do
            # shellcheck disable=SC2254  # unquoted expansion IS the glob match
            case "$base" in
                $pattern) matched="true"; break ;;
            esac
        done
        [[ "$matched" == "true" ]] || continue
        rm -rf -- "$target" 2>/dev/null || true
    done <<<"$data"
}

# ─── Stash applier (#594) ───────────────────────────────────────────────────
# _cleanup_apply_stash_plan <plan_TSV> <dry_run_bool>
# Drops in reverse stash-index order so dropping doesn't shift remaining refs.
# Re-verifies the prefix at drop-time (defence in depth).
_cleanup_apply_stash_plan() {
    local data="$1" dry_run="$2"
    [[ -z "$data" ]] && return 0
    # Collect prune indices.
    local lines=() line ref decision rest
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        ref="${line%%$'\t'*}"
        rest="${line#*$'\t'}"
        decision="${rest%%$'\t'*}"
        [[ "$decision" != "prune" ]] && continue
        lines+=("$ref")
    done <<<"$data"
    [[ "$dry_run" == "true" ]] && return 0
    # Sort descending by index N inside stash@{N}.
    local sorted
    sorted="$(printf '%s\n' "${lines[@]}" | awk -F'[{}]' '{print $2"\t"$0}' | sort -rn | cut -f2)"
    while IFS= read -r ref; do
        [[ -z "$ref" ]] && continue
        # Re-verify the prefix immediately before drop.
        local subject
        subject="$(git stash list --format='%gd	%s' 2>/dev/null | awk -F'\t' -v r="$ref" '$1==r{print $2}')"
        local msg="${subject#On *: }"; msg="${msg#WIP on *: }"
        case "$msg" in "$ZBUILD_APPLYCHECK_PREFIX"*) ;; *) continue ;; esac
        git stash drop -q "$ref" >/dev/null 2>&1 || true
    done <<<"$sorted"
}

# ─── Stash restore (#594) ───────────────────────────────────────────────────
# _cleanup_restore_stash <index>
# Validates that stash@{N} exists AND its message has zb-applycheck-* prefix,
# then `git stash pop stash@{N}`. Returns nonzero on validation failure or pop
# failure (and in pop-failure case, leaves the stash in place per safety).
_cleanup_restore_stash() {
    local idx="$1"
    [[ "$idx" =~ ^[0-9]+$ ]] || { error "restore-stash: index must be a non-negative integer (got: $idx)"; return 2; }
    local ref="stash@{$idx}"
    local subject
    subject="$(git stash list --format='%gd	%s' 2>/dev/null | awk -F'\t' -v r="$ref" '$1==r{print $2}')"
    if [[ -z "$subject" ]]; then
        error "restore-stash: no such stash $ref"
        return 2
    fi
    local msg="${subject#On *: }"; msg="${msg#WIP on *: }"
    case "$msg" in
        "$ZBUILD_APPLYCHECK_PREFIX"*) ;;
        *)
            error "restore-stash: $ref is not a ${ZBUILD_APPLYCHECK_PREFIX}* stash (msg: $msg)"
            return 2
            ;;
    esac
    if ! git stash pop "$ref" >/dev/null 2>&1; then
        error "restore-stash: git stash pop $ref failed; stash left in place"
        return 1
    fi
    return 0
}

# ─── Renderer ───────────────────────────────────────────────────────────────
# _cleanup_render_plan <kind> <data> <dry_run> <quiet>
_cleanup_render_plan() {
    local kind="$1" data="$2" dry_run="$3" quiet="$4"
    [[ "$quiet" == "true" ]] && return 0
    local header_action="WOULD"
    [[ "$dry_run" != "true" ]] && header_action="WILL"
    if [[ -z "$data" ]]; then
        info "$kind: nothing to clean"
        return 0
    fi
    info "$kind ($header_action):"
    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local target rest decision reason
        target="${line%%$'\t'*}"
        rest="${line#*$'\t'}"
        if [[ "$kind" == "branches" || "$kind" == "stashes" || "$kind" == "tmpdirs" ]]; then
            decision="${rest%%$'\t'*}"
            reason="${rest#*$'\t'}"
            printf '  %-40s  %-6s  %s\n' "$target" "$decision" "$reason"
        else
            reason="$rest"
            printf '  %-60s  %s\n' "$target" "$reason"
        fi
    done <<<"$data"
}

# ─── _cleanup_scan_worktrees <age_days> ──────────────────────────────────────
# Emit reclaimable per-run worktrees, one per line: "<path>\t<branch>\t<age_days>".
#
# Per-run worktrees (#888) are the largest artifact a run leaves — a full working
# tree each. Reuses the existing porcelain parsing and safety predicates in this
# file rather than adding a second worktree scanner.
#
# KEEPS (never emits) a worktree that:
#   - belongs to the currently-active run ($ZBUILD_RUN_ID) — resume needs it;
#   - is newer than <age_days>;
#   - has uncommitted work, or commits not yet pushed. Reclaiming either would
#     destroy work, and a pruner that can eat work is worse than none.
_cleanup_scan_worktrees() {
    local age_days="${1:-14}"
    local now; now="$(date +%s)"
    local cutoff=$(( now - age_days * 86400 ))
    # MUST be called from inside the target repository: the git invocations below
    # operate on $PWD. A caller in the wrong directory gets an empty scan with no
    # error — the same silent-no-op shape as the canonicalisation bug. Resolve the
    # repo once and use -C everywhere rather than relying on the caller's cwd.
    local repo_root
    if ! repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
        printf '_cleanup_scan_worktrees: not inside a git repository\n' >&2
        return 2
    fi

    # BOTH layouts, because zbuild_worktree_path supports both:
    #   co-located (default): <run_root>/<run_id>/worktree
    #   override:             $ZBUILD_WORKTREE_ROOT/<run_id>   (no /worktree suffix)
    # Matching only the first made cleanup a silent no-op for override installs.
    local run_root="${ZBUILD_RUN_ROOT:-${HOME}/.zbuild}/runs"
    local override_root=""
    if declare -F zbuild_worktree_root >/dev/null 2>&1; then
        override_root="$(zbuild_worktree_root 2>/dev/null || true)"
    else
        override_root="${ZBUILD_WORKTREE_ROOT:-}"
    fi
    [[ -d "$run_root" || -n "$override_root" ]] || return 0
    # CANONICALISE. `git worktree list` reports resolved paths (/private/tmp/... on
    # macOS, where /tmp and /var are symlinks), so comparing against an unresolved
    # run root silently matches nothing and the scanner reports no candidates —
    # a pruner that appears to work and reclaims nothing.
    run_root="$( (cd "$run_root" 2>/dev/null && pwd -P) || printf '%s' "$run_root" )"
    [[ -n "$override_root" ]] && override_root="$( (cd "$override_root" 2>/dev/null && pwd -P) || printf '%s' "$override_root" )"

    local wt branch mtime age_d
    while IFS= read -r wt; do
        [[ -n "$wt" && -d "$wt" ]] || continue
        # Ours under either layout.
        local _mine=0
        case "$wt" in "$run_root"/*/worktree) _mine=1 ;; esac
        [[ -n "$override_root" ]] && case "$wt" in "$override_root"/*) _mine=1 ;; esac
        [[ "$_mine" -eq 1 ]] || continue
        # Never the active run.
        if [[ -n "${ZBUILD_RUN_ID:-}" ]] \
           && { [[ "$wt" == "$run_root/${ZBUILD_RUN_ID}/worktree" ]] \
                || { [[ -n "$override_root" ]] && [[ "$wt" == "$override_root/${ZBUILD_RUN_ID}" ]]; }; }; then
            continue
        fi
        mtime="$(stat -c %Y "$wt" 2>/dev/null || stat -f %m "$wt" 2>/dev/null || echo 0)"
        [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
        [[ "$mtime" -gt "$cutoff" ]] && continue
        branch="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
        # Refuse anything holding work.
        if [[ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]]; then
            continue
        fi
        if [[ -n "$branch" && "$branch" != "HEAD" ]] \
           && declare -F _cleanup_has_unpushed_commits >/dev/null 2>&1 \
           && _cleanup_has_unpushed_commits "$branch"; then
            continue
        fi
        age_d=$(( (now - mtime) / 86400 ))
        printf '%s\t%s\t%s\n' "$wt" "${branch:-<detached>}" "$age_d"
    done < <(git -C "$repo_root" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}')
}

# ─── _cleanup_apply_worktree_plan <path>... ──────────────────────────────────
# Remove each worktree, then its now-empty run dir. `git worktree remove` is used
# (not rm -rf) so git's administrative entry under .git/worktrees goes too;
# rm -rf alone would leave a registration that `git worktree list` still reports.
# MUST be called from inside the target repository (see _cleanup_scan_worktrees):
# `git worktree remove`/`prune` act on the repo resolved from $PWD.
_cleanup_apply_worktree_plan() {
    local wt rc=0
    local repo_root
    if ! repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
        printf '_cleanup_apply_worktree_plan: not inside a git repository\n' >&2
        return 2
    fi
    for wt in "$@"; do
        [[ -n "$wt" ]] || continue
        local err
        if ! err="$(git -C "$repo_root" worktree remove --force "$wt" 2>&1)"; then
            printf 'cleanup: could not remove worktree %s: %s\n' "$wt" "${err:-<no git output>}" >&2
            rc=1
            continue
        fi
        # Layout-aware. Co-located ($wt = <run_root>/<id>/worktree): the parent IS
        # the per-run dir, so removing it when empty is correct. Override layout
        # ($wt = $ZBUILD_WORKTREE_ROOT/<id>): the parent is the operator's
        # CONFIGURED ROOT — rmdir'ing that would silently delete their directory
        # once the last worktree went, and `|| true` would hide it.
        case "$wt" in
            */worktree) rmdir "$(dirname "$wt")" 2>/dev/null || true ;;
        esac
    done
    git -C "$repo_root" worktree prune 2>/dev/null || true
    return $rc
}
