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
    # LEGACY FLAT PATH ONLY. Per-run state under runs/<id>/ moved to
    # _cleanup_scan_state_dirs (#1920), which reclaims the whole job folder
    # instead of the three JSON files inside it. Scanning both here would leave
    # two scanners deciding the same run — the drift #1682 exists to prevent.
    for f in "$state_dir"/pipeline-state*.json; do
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
# _cleanup_scan_branches <force_bool> [age_days]
# Prints: "<branch>\t<decision>\t<reason>"
# decision ∈ {prune, skip}
#
# age_days added alongside the issue-close clock. Before it, branches were the
# ONLY category with no age gate of any kind: a merged PR made a branch
# instantly prunable no matter how recent, and nothing else ever aged one out.
#
# A `zbuild/issue-*` branch holds the actual CODE for an issue, so it ages from
# the issue's close, not from last touch — the strongest case for the second
# clock. The merged-PR fast path is kept ahead of it: once the work is merged the
# branch is redundant regardless of whether the issue is still open, and that is
# the common case this command was written for.
_cleanup_scan_branches() {
    local force="$1"
    local age_days="${2:-}"
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
        # Issue-close clock. Only consulted when an age was asked for, so every
        # existing caller keeps its exact behaviour.
        if [[ "$age_days" =~ ^[0-9]+$ ]]; then
            local _b_mtime _b_age _b_dec
            _b_mtime="$(git log -1 --format='%ct' "$b" 2>/dev/null || echo 0)"
            [[ "$_b_mtime" =~ ^[0-9]+$ ]] || _b_mtime=0
            _b_age=$(( ( $(date +%s) - _b_mtime ) / 86400 ))
            _b_dec="$(_cleanup_issue_ref_decision "$b" "$age_days" "$_b_age")"
            if [[ "$_b_dec" == prune* ]]; then
                printf '%s\t%s\n' "$b" "$_b_dec"
                continue
            fi
            # A PROVABLY OPEN issue outranks --force. --force means "this branch
            # is dead even though no PR merged"; it does not mean "delete the
            # work branch of an issue I am still working on". Without this the
            # decision fell through to the force arm below and was emitted as
            # `prune  force`, which is precisely the mid-flight destruction the
            # issue clock exists to prevent.
            if [[ "$_b_dec" == *"is open"* ]]; then
                printf '%s\t%s (open issues outrank --force)\n' "$b" "$_b_dec"
                continue
            fi
            # Every other skip — unknown state, unreadable close date — is
            # fail-closed for the ordinary path but MUST yield to --force.
            # Making "I cannot tell" unforceable would leave anyone without
            # working `gh` unable to prune a branch at all, which is a worse
            # failure than the one being guarded against.
            if [[ "$force" != "true" ]]; then
                printf '%s\t%s\n' "$b" "$_b_dec"
                continue
            fi
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
        # INVERTED: the 3-field `<target>\t<decision>\t<reason>` shape is the
        # contract, and `state files` is the lone 2-field holdout. This used to
        # be an allowlist of kinds, which meant every scanner added after it
        # rendered its decision column as part of the reason string until someone
        # noticed and extended the list. Naming the exception instead makes a new
        # scanner correct by default.
        if [[ "$kind" != "state files" ]]; then
            decision="${rest%%$'\t'*}"
            reason="${rest#*$'\t'}"
            # Path-shaped targets routinely exceed 40 chars, which would push the
            # decision column out of alignment on every real invocation. Keep the
            # 60-wide column worktrees rendered with before they joined this
            # shared decision/reason format (#1634).
            local _w=40
            case "$kind" in
                worktrees|scratch|"orch pools"|cache|tmpdirs|"state dirs") _w=60 ;;
            esac
            printf '  %-*s  %-6s  %s\n' "$_w" "$target" "$decision" "$reason"
        else
            reason="$rest"
            printf '  %-60s  %s\n' "$target" "$reason"
        fi
    done <<<"$data"
}

# ─── _cleanup_scan_worktrees <age_days> ──────────────────────────────────────
# Emit one decision per examined per-run worktree: "<path>\t<decision>\t<reason>",
# where <decision> is `prune` (reclaimable; reason carries branch + age) or `skip`
# (kept; reason names the guard that fired).
#
# #1634: reporting only the selected entries made a clean scan and a BROKEN scan
# indistinguishable — "no candidates because everything is protected" and "no
# candidates because the filter matched nothing" produced identical empty output.
# Four defects shipped behind that silence (path canonicalisation, run-id reuse,
# an ignored ZBUILD_WORKTREE_ROOT, an unconditional rmdir of the operator's root);
# none announced itself, because doing nothing looked exactly like success.
# Naming the guard that fired is what makes the difference visible.
#
# Callers that ACT on this must filter to `decision == prune` — see scripts/zbuild.
#
# Per-run worktrees (#888) are the largest artifact a run leaves — a full working
# tree each. Reuses the existing porcelain parsing and safety predicates in this
# file rather than adding a second worktree scanner.
#
# KEEPS (emits `skip`, never `prune`) a worktree that:
#   - belongs to the currently-active run ($ZBUILD_RUN_ID) — resume needs it;
#   - is newer than <age_days>;
#   - has uncommitted work, or sits on a detached HEAD carrying commits no ref
#     points at. Those are the two kinds of work a removal genuinely destroys,
#     and a pruner that can eat work is worse than none. Committed work on a
#     named branch is NOT in that set — see the note at the check itself.
# Worktrees outside the run root are not ours and are filtered silently.
_cleanup_scan_worktrees() {
    # 7, matching scripts/zbuild's cl_age_days. These two defaults are
    # INDEPENDENT — this scanner is called directly by tests and by the intake
    # diagnostic path, not only through the CLI — so both must move together.
    local age_days="${1:-7}"
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
        # Ours under either layout. Anything outside the zbuild run root is not
        # ours to examine, so it is filtered silently — no skip line. Every
        # worktree that IS ours produces a decision from here on (#1634).
        local _mine=0
        case "$wt" in "$run_root"/*/worktree) _mine=1 ;; esac
        [[ -n "$override_root" ]] && case "$wt" in "$override_root"/*) _mine=1 ;; esac
        [[ "$_mine" -eq 1 ]] || continue
        # Never the active run.
        if [[ -n "${ZBUILD_RUN_ID:-}" ]] \
           && { [[ "$wt" == "$run_root/${ZBUILD_RUN_ID}/worktree" ]] \
                || { [[ -n "$override_root" ]] && [[ "$wt" == "$override_root/${ZBUILD_RUN_ID}" ]]; }; }; then
            # Strip separators from the interpolated id: these lines are
            # tab-delimited and feed a delete path, so a run id carrying a tab
            # must not be able to shift a caller's field split.
            local _rid="${ZBUILD_RUN_ID//[$'\t\n']/ }"
            printf '%s\tskip\tactive run (ZBUILD_RUN_ID=%s)\n' "$wt" "$_rid"
            continue
        fi
        mtime="$(stat -c %Y "$wt" 2>/dev/null || stat -f %m "$wt" 2>/dev/null || echo 0)"
        [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
        if [[ "$mtime" -gt "$cutoff" ]]; then
            printf '%s\tskip\tnewer than %sd\n' "$wt" "$age_days"
            continue
        fi
        branch="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
        # Refuse anything holding work.
        if [[ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]]; then
            printf '%s\tskip\tuncommitted work\n' "$wt"
            continue
        fi
        # Committed work on a NAMED branch is not at risk here and must not block:
        # the ref lives in the repository, not in the worktree, so removing the
        # tree leaves the branch and every commit on it exactly where they were.
        # Gating on unpushed-ness (as this once did) made a branch that was never
        # pushed permanently unreclaimable — and a run that dies before its first
        # push is precisely the run whose tree needs reclaiming, so the guard
        # fired hardest on the only case that mattered (#1869).
        #
        # A DETACHED head is the real exception: commits made there are reachable
        # from no ref, so removing the tree strands them. Keep those.
        if [[ -z "$branch" || "$branch" == "HEAD" ]]; then
            local _unref
            _unref="$(git -C "$wt" rev-list --count HEAD --not --branches --tags --remotes 2>/dev/null || echo 0)"
            [[ "$_unref" =~ ^[0-9]+$ ]] || _unref=1   # unparseable → fail closed
            if [[ "$_unref" -gt 0 ]]; then
                printf '%s\tskip\tdetached commits reachable from no ref\n' "$wt"
                continue
            fi
        fi
        age_d=$(( (now - mtime) / 86400 ))
        printf '%s\tprune\tbranch=%s age=%sd\n' "$wt" "${branch:-<detached>}" "$age_d"
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
    # Resolved once: the co-located run root, used below to tell a per-run dir
    # (safe to rmdir when empty) from the operator's configured worktree root.
    local _run_root_l; _run_root_l="${ZBUILD_RUN_ROOT:-${HOME}/.zbuild}/runs"
    _run_root_l="$( (cd "$_run_root_l" 2>/dev/null && pwd -P) || printf '%s' "$_run_root_l" )"
    # The configured override root, resolved the same way _cleanup_scan_worktrees
    # resolves it. This is KNOWN, not inferred: no path-shape test can tell
    # $ZBUILD_WORKTREE_ROOT/<id> from <run_root>/<id>/worktree once the operator
    # points the override root inside the run root (e.g. ~/.zbuild/runs/wt), and
    # inferring there deletes the very directory they configured.
    local _ovr_root_l=""
    if declare -F zbuild_worktree_root >/dev/null 2>&1; then
        _ovr_root_l="$(zbuild_worktree_root 2>/dev/null || true)"
    else
        _ovr_root_l="${ZBUILD_WORKTREE_ROOT:-}"
    fi
    [[ -n "$_ovr_root_l" ]] && _ovr_root_l="$( (cd "$_ovr_root_l" 2>/dev/null && pwd -P) || printf '%s' "$_ovr_root_l" )"
    for wt in "$@"; do
        [[ -n "$wt" ]] || continue
        # Defence-in-depth: re-check for uncommitted work at delete-time, mirroring
        # _cleanup_apply_branch_plan. The scanner already excludes dirty worktrees,
        # but a race or a hand-crafted plan can bypass that. This pre-check only
        # buys the NAMED refusal message — `git worktree remove` runs WITHOUT
        # --force so git re-checks dirtiness itself at removal time. --force would
        # reopen a TOCTOU window: a concurrent write landing between the check and
        # the removal would be destroyed silently, which is the #1621 failure mode
        # this issue exists to prevent.
        if [[ -d "$wt" && -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]]; then
            printf 'cleanup: refusing to remove worktree with uncommitted work: %s\n' "$wt" >&2
            rc=1
            continue
        fi
        local err
        if ! err="$(git -C "$repo_root" worktree remove "$wt" 2>&1)"; then
            printf 'cleanup: could not remove worktree %s: %s\n' "$wt" "${err:-<no git output>}" >&2
            rc=1
            continue
        fi
        # Layout-aware: only rmdir the parent when it is a per-run dir under the
        # run root (co-located layout). In override layout the parent IS the
        # operator's configured root — never rmdir it. The old */worktree suffix
        # check fired on override paths with run_id='worktree', silently deleting
        # the configured root once the last worktree went.
        # $_run_root_l is loop-invariant — resolved once above, not per worktree.
        # If the run root does not resolve (never created), the raw string stays
        # and the comparison simply fails to match: the fail-safe direction, since
        # a missed rmdir leaves an empty dir behind while a wrong one deletes the
        # operator's configured root.
        local wt_parent; wt_parent="$(dirname "$wt")"
        local _wt_pc; _wt_pc="$( (cd "$wt_parent" 2>/dev/null && pwd -P) || printf '%s' "$wt_parent" )"
        if [[ -n "$_ovr_root_l" && "$_wt_pc" == "$_ovr_root_l" ]]; then
            : # the parent IS the operator's configured root — never rmdir it
        elif [[ "$(dirname "$_wt_pc")" == "$_run_root_l" ]]; then
            rmdir "$wt_parent" 2>/dev/null || true
        fi
    done
    git -C "$repo_root" worktree prune 2>/dev/null || true
    return $rc
}

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Issue-keyed retention — the second clock (#1632 policy, generalised)      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# One retention number, two clocks. Most targets age from their own last touch:
# they are garbage or regenerable. Three do not — `zbuild/issue-*` branches,
# `zbuild/state/issue-*` branches, and the plan-context cache are LIVE WORK for
# an open issue. A work branch holds unmerged code; the state branch and the
# context cache are the prior work ADR-050 feeds into the next run of that same
# issue. Ageing those from last touch destroys work mid-flight, so they age from
# the issue's CLOSE instead.

# ─── _cleanup_issue_from_ref <ref> ──────────────────────────────────────────
# Extract the issue number from a zbuild ref. Handles both shapes:
#   zbuild/issue-1809-some-slug   → 1809
#   zbuild/state/issue-1809       → 1809
# Prints nothing and returns 1 when the ref carries no issue number.
_cleanup_issue_from_ref() {
    local ref="${1:-}"
    [[ -n "$ref" ]] || return 1
    local n=""
    case "$ref" in
        zbuild/state/issue-*) n="${ref#zbuild/state/issue-}" ;;
        zbuild/issue-*)       n="${ref#zbuild/issue-}" ;;
        *) return 1 ;;
    esac
    n="${n%%-*}"
    [[ "$n" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$n"
}

# ─── _cleanup_issue_state <issue_number> ────────────────────────────────────
# Prints one of: open | closed | missing | unknown
#
# FAIL-CLOSED, exactly like _cleanup_has_merged_pr above: `gh` absent, an API
# error, or an unparseable answer all yield `unknown`, and every caller treats
# `unknown` as "keep". A reclaimer that cannot establish an issue's state must
# never be the thing that deletes a branch holding unmerged work.
#
# `missing` is distinct from `unknown` and is NOT fail-closed: the issue was
# looked up successfully and does not exist. #1632 settled that case — fall back
# to plain age.
_cleanup_issue_state() {
    local n="${1:-}"
    [[ "$n" =~ ^[0-9]+$ ]] || { printf 'unknown'; return 0; }
    command -v gh >/dev/null 2>&1 || { printf 'unknown'; return 0; }
    # ONE call, not two. Distinguishing "no such issue" from "could not ask"
    # needs the error text, and gh exits non-zero for both — but asking twice
    # doubles the API load AND can race, since a transient failure followed by a
    # permanent one (or the reverse) would classify off the second answer while
    # the first decided the rc. Capture stdout and stderr together instead: on
    # success the jq filter emits only the state, so there is nothing to confuse.
    local out rc=0
    out="$(gh issue view "$n" --json state --jq '.state' 2>&1)" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        case "$out" in
            *"not found"*|*"Not Found"*|*"Could not resolve"*) printf 'missing' ;;
            *) printf 'unknown' ;;
        esac
        return 0
    fi
    case "$out" in
        OPEN|open)     printf 'open' ;;
        CLOSED|closed) printf 'closed' ;;
        *)             printf 'unknown' ;;
    esac
}

# ─── _cleanup_issue_closed_age_days <issue_number> ──────────────────────────
# Days since the issue closed, or empty when that cannot be established.
_cleanup_issue_closed_age_days() {
    local n="${1:-}"
    [[ "$n" =~ ^[0-9]+$ ]] || return 1
    command -v gh >/dev/null 2>&1 || return 1
    local closed_at
    closed_at="$(gh issue view "$n" --json closedAt --jq '.closedAt // empty' 2>/dev/null)" || return 1
    [[ -n "$closed_at" ]] || return 1
    # _zbuild_iso8601_to_epoch lives in core/state/resume.sh, which this library
    # does not source. Pull it in lazily; if it cannot be loaded, return 1 and let
    # the caller fail closed rather than hand-rolling a date parse here — GNU
    # `date -d` and BSD `date -j` disagree, and getting that wrong would silently
    # mis-age every issue-keyed target.
    if ! declare -F _zbuild_iso8601_to_epoch >/dev/null 2>&1; then
        local _cl_resume="${_CLEANUP_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/../../core/state/resume.sh"
        # shellcheck source=../../core/state/resume.sh
        [[ -f "$_cl_resume" ]] && source "$_cl_resume" 2>/dev/null || true
    fi
    declare -F _zbuild_iso8601_to_epoch >/dev/null 2>&1 || return 1
    local closed_epoch now
    closed_epoch="$(_zbuild_iso8601_to_epoch "$closed_at" 2>/dev/null || echo "")"
    [[ "$closed_epoch" =~ ^[0-9]+$ ]] || return 1
    now="$(date +%s)"
    printf '%s' $(( (now - closed_epoch) / 86400 ))
}

# ─── _cleanup_issue_ref_decision <ref> <age_days> <fallback_age_days> ───────
# The issue-close clock, as a decision string: "prune\t<reason>" or "skip\t<reason>".
# <fallback_age_days> is the target's own last-touch age, used only when the
# issue no longer exists.
_cleanup_issue_ref_decision() {
    local ref="$1" age_days="$2" fallback_age="${3:-}"
    local n
    if ! n="$(_cleanup_issue_from_ref "$ref")"; then
        printf 'skip\tno issue number in ref'
        return 0
    fi
    local st; st="$(_cleanup_issue_state "$n")"
    case "$st" in
        open)
            printf 'skip\tissue #%s is open' "$n"
            ;;
        unknown)
            printf 'skip\tissue #%s state unprovable (fail-closed)' "$n"
            ;;
        missing)
            # #1632: issue gone → plain age against the same number.
            if [[ "$fallback_age" =~ ^[0-9]+$ ]] && [[ "$fallback_age" -ge "$age_days" ]]; then
                printf 'prune\tissue #%s no longer exists, age %sd' "$n" "$fallback_age"
            else
                printf 'skip\tissue #%s no longer exists, newer than %sd' "$n" "$age_days"
            fi
            ;;
        closed)
            local cd; cd="$(_cleanup_issue_closed_age_days "$n" || true)"
            if [[ "$cd" =~ ^[0-9]+$ ]]; then
                if [[ "$cd" -ge "$age_days" ]]; then
                    printf 'prune\tissue #%s closed %sd ago' "$n" "$cd"
                else
                    printf 'skip\tissue #%s closed %sd ago (<%sd)' "$n" "$cd" "$age_days"
                fi
            else
                printf 'skip\tissue #%s closed, close date unreadable (fail-closed)' "$n"
            fi
            ;;
        *)
            printf 'skip\tissue #%s state unrecognised (fail-closed)' "$n"
            ;;
    esac
}

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  The four categories that had no reclaimer at all                          ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Every scanner below emits the 3-field shape `<target>\t<prune|skip>\t<reason>`
# and NAMES THE GUARD that fired on a skip. #1634: reporting only the selected
# entries made a clean scan and a broken scan indistinguishable — "nothing to do"
# and "the filter matched nothing" produced identical empty output, and four
# defects shipped behind that silence.

# ─── _cleanup_scan_scratch <age_days> ───────────────────────────────────────
# Per-stage scratch under <state_root>/runs/<run_id>/scratch (ADR-058).
#
# The single largest consumer on disk and, until now, reclaimed by nothing: the
# test stage rsyncs a full repo copy per stage, and #1918 moved that inside the
# job folder where it accumulates. Throwaway by definition — ADR-058 says nothing
# in scratch is ever an output — so this ages from last touch, not from an issue.
_cleanup_scan_scratch() {
    local age_days="${1:-7}"
    local now; now="$(date +%s)"
    local cutoff=$(( now - age_days * 86400 ))
    local root="${ZBUILD_STATE_ROOT:-${HOME}/.zbuild/state}/runs"
    [[ -d "$root" ]] || return 0
    local d rid scratch mtime age_d
    for d in "$root"/*; do
        [[ -d "$d" ]] || continue
        scratch="$d/scratch"
        [[ -d "$scratch" ]] || continue
        rid="$(basename "$d")"
        if _cleanup_is_active_run "$rid"; then
            printf '%s\tskip\tactive run\n' "$scratch"
            continue
        fi
        mtime="$(stat -c %Y "$scratch" 2>/dev/null || stat -f %m "$scratch" 2>/dev/null || echo 0)"
        [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
        age_d=$(( (now - mtime) / 86400 ))
        if [[ "$mtime" -gt "$cutoff" ]]; then
            printf '%s\tskip\tnewer than %sd (age %sd)\n' "$scratch" "$age_days" "$age_d"
            continue
        fi
        printf '%s\tprune\trun=%s age=%sd\n' "$scratch" "$rid" "$age_d"
    done
}

# ─── _cleanup_scan_state_dirs <state_dir> <age_days> <force_bool> ───────────
# The job folder itself — <state_dir>/runs/<run_id>/ (ADR-058 §1).
#
# `--state-dirs` deleted three JSON files per run and left the directory holding
# them standing, so artifacts/, events.jsonl, stage-io/, orch/, runtime/ and
# (since #1918) scratch/ accumulated forever. #1927 reclaimed the scratch INSIDE
# a job folder; this reclaims the folder. Applied with _cleanup_apply_dir_plan
# rooted at <state_dir>/runs, which refuses any target not strictly inside it.
#
# LAST-TOUCH CLOCK, deliberately, not the issue clock. The issue clock (#1632,
# generalised by #1927) is for targets the NEXT run of an issue reads back: a
# work branch's unmerged code, ADR-050's state branch, the plan-context cache.
# A terminal job folder is read by a human diagnosing one failure, and by
# `zbuild resume` for a run that stopped mid-flight — the first is what retention
# serves, the second is what the `interrupted` guard below preserves. Nothing
# reads a terminal run's folder to start the next one, so keying it to the issue
# would buy no safety and cost one `gh` call per run dir.
#
# DIRECTORY-DRIVEN, not glob-driven. Iterating runs/* rather than
# runs/*/pipeline-state*.json is what lets a run dir with no state file be
# REPORTED instead of being invisible to the scan (#1634).
_cleanup_scan_state_dirs() {
    local state_dir="$1" age_days="${2:-7}" force="${3:-false}"
    [[ -d "$state_dir" ]] || return 0
    local root="$state_dir/runs"
    [[ -d "$root" ]] || return 0
    local now; now="$(date +%s)"
    local cutoff=$(( now - age_days * 86400 ))
    local d rid f c status mtime age_d
    for d in "$root"/*; do
        [[ -d "$d" ]] || continue
        rid="$(basename "$d")"
        # Live run — never pruned, not even with --force.
        if _cleanup_is_active_run "$rid"; then
            printf '%s\tskip\tactive run\n' "$d"
            continue
        fi
        if [[ -n "${ZBUILD_RUN_ID:-}" && "$rid" == "${ZBUILD_RUN_ID}" ]]; then
            printf '%s\tskip\tcurrent run (ZBUILD_RUN_ID)\n' "$d"
            continue
        fi
        f=""
        for c in "$d"/pipeline-state*.json; do
            [[ -f "$c" ]] || continue
            case "$c" in *.bak|*.lock) continue ;; esac
            f="$c"; break
        done
        status=""
        [[ -n "$f" ]] && status="$(jq -r '.status // ""' "$f" 2>/dev/null || echo "")"
        # _cleanup_is_active_run reads $ZBUILD_STATE_DIR, which need not be the
        # <state_dir> argument. Re-check in_progress against the file actually
        # found here so a mismatched pair cannot let a live run through.
        if [[ "$status" == "in_progress" ]]; then
            printf '%s\tskip\tstatus=in_progress (live)\n' "$d"
            continue
        fi
        if [[ "$status" == "interrupted" && "$force" != "true" ]]; then
            printf '%s\tskip\tinterrupted — resume preserved (ADR-018); --force to prune\n' "$d"
            continue
        fi
        case "$status" in
            complete|failed|aborted|interrupted) ;;
            "")
                if [[ "$force" != "true" ]]; then
                    printf '%s\tskip\tno pipeline-state.json (fail-closed); --force to prune\n' "$d"
                    continue
                fi
                ;;
            *)
                if [[ "$force" != "true" ]]; then
                    printf '%s\tskip\tstatus=%s unrecognised (fail-closed); --force to prune\n' "$d" "$status"
                    continue
                fi
                ;;
        esac
        # Age from the state file when there is one, the dir otherwise. GNU stat
        # first (Linux CI), then BSD (macOS dev) — BSD stat -f returns garbage
        # with rc=0 on Linux, so trying it first leaves non-numeric text behind.
        if [[ -n "$f" ]]; then
            mtime="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)"
        else
            mtime="$(stat -c %Y "$d" 2>/dev/null || stat -f %m "$d" 2>/dev/null || echo 0)"
        fi
        # FAIL-CLOSED on an unreadable mtime, unlike the #1927 scanners that
        # default it to 0. Those reclaim throwaway or regenerable trees; this one
        # rm -rf's a run's whole evidence record, and an epoch fallback reads as
        # "infinitely old" — turning a degraded stat into an unconditional prune.
        if ! [[ "$mtime" =~ ^[1-9][0-9]*$ ]]; then
            printf '%s\tskip\tmtime unreadable (fail-closed)\n' "$d"
            continue
        fi
        age_d=$(( (now - mtime) / 86400 ))
        if [[ "$mtime" -gt "$cutoff" ]]; then
            printf '%s\tskip\tnewer than %sd (age %sd)\n' "$d" "$age_days" "$age_d"
            continue
        fi
        printf '%s\tprune\trun=%s status=%s age=%sd\n' "$d" "$rid" "${status:-none}" "$age_d"
    done
}

# ─── _cleanup_scan_state_branches <age_days> ────────────────────────────────
# zbuild/state/issue-* — ADR-050 prior-work snapshots. Nothing has ever pruned
# these: _cleanup_scan_branches filters strictly on `zbuild/issue-*`, so the
# state namespace was never even considered (#1632).
#
# Issue-close clock: a state branch for an OPEN issue is the prior work the next
# run of that issue reuses. Deleting it mid-issue is the one outcome this branch
# exists to prevent.
_cleanup_scan_state_branches() {
    local age_days="${1:-7}"
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
    local now; now="$(date +%s)"
    local b mtime age_d dec
    while IFS= read -r b; do
        [[ -n "$b" ]] || continue
        if _cleanup_is_current_branch "$b"; then
            printf '%s\tskip\tcurrent branch / active worktree\n' "$b"
            continue
        fi
        mtime="$(git log -1 --format='%ct' "$b" 2>/dev/null || echo 0)"
        [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
        age_d=$(( (now - mtime) / 86400 ))
        dec="$(_cleanup_issue_ref_decision "$b" "$age_days" "$age_d")"
        printf '%s\t%s\n' "$b" "$dec"
    done < <(git branch --list 'zbuild/state/issue-*' --format '%(refname:short)' 2>/dev/null || true)
}

# ─── _cleanup_scan_orch_pools <age_hours> ───────────────────────────────────
# ${TMPDIR}/zbuild-runs/<run_id>/ — orchestrator slot pools (#898).
#
# ADR-035:44-45 deliberately EXCLUDED these from ZBUILD_TMPDIR_PATTERNS, on the
# reasoning that orch_shutdown reaps them. That holds for a run that exits
# normally and fails for every run that does not — a killed run leaves its pool
# behind and nothing has ever collected it. ADR-035 is amended alongside this.
#
# Nested one level deeper than the flat patterns, which is why the single-level
# glob could never have reached them even if they were listed.
_cleanup_scan_orch_pools() {
    local age_hours="${1:-1}"
    local now; now="$(date +%s)"
    local cutoff=$(( now - age_hours * 3600 ))
    local root="${TMPDIR:-/tmp}"; root="${root%/}/zbuild-runs"
    [[ -d "$root" ]] || return 0
    local d rid mtime age_h
    for d in "$root"/*; do
        [[ -d "$d" ]] || continue
        rid="$(basename "$d")"
        if _cleanup_is_active_run "$rid"; then
            printf '%s\tskip\tactive run\n' "$d"
            continue
        fi
        mtime="$(stat -c %Y "$d" 2>/dev/null || stat -f %m "$d" 2>/dev/null || echo 0)"
        [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
        age_h=$(( (now - mtime) / 3600 ))
        if [[ "$mtime" -gt "$cutoff" ]]; then
            printf '%s\tskip\tnewer than %sh (age %sh)\n' "$d" "$age_hours" "$age_h"
            continue
        fi
        printf '%s\tprune\trun=%s age=%sh\n' "$d" "$rid" "$age_h"
    done
}

# ─── _cleanup_scan_cache <age_days> ─────────────────────────────────────────
# ~/.zbuild/cache/<key> — the ADR-011 cache backend. Content-addressed and
# regenerable by construction: cache_pull prints CACHE_MISS and returns 0, so a
# miss is a normal outcome and deleting an entry costs a recomputation, nothing
# more. ADR-011 defines no retention at all today.
#
# The MEMORY store is deliberately absent from this file and must stay absent —
# it is agnostic to the issues it supports and is never reclaimed.
_cleanup_scan_cache() {
    local age_days="${1:-7}"
    local now; now="$(date +%s)"
    local cutoff=$(( now - age_days * 86400 ))
    local root="${ZBUILD_CACHE_DIR:-${HOME}/.zbuild/cache}"
    root="${root%/}"
    [[ -d "$root" ]] || return 0
    local d mtime age_d
    for d in "$root"/*; do
        [[ -e "$d" ]] || continue
        case "$(basename "$d")" in *.tmp) continue ;; esac
        mtime="$(stat -c %Y "$d" 2>/dev/null || stat -f %m "$d" 2>/dev/null || echo 0)"
        [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
        age_d=$(( (now - mtime) / 86400 ))
        if [[ "$mtime" -gt "$cutoff" ]]; then
            printf '%s\tskip\tnewer than %sd (age %sd)\n' "$d" "$age_days" "$age_d"
            continue
        fi
        printf '%s\tprune\tage=%sd\n' "$d" "$age_d"
    done
}

# ─── _cleanup_apply_dir_plan <plan_TSV> <dry_run_bool> <root_prefix> ────────
# Shared applier for the directory-shaped scanners above (scratch, orch pools,
# cache). Re-validates that every target still sits under the expected root at
# DELETE time — same defence-in-depth discipline as the tmpdir and stash
# appliers, and the reason a scanner bug cannot become an `rm -rf` outside the
# store. Refuses a bare root.
_cleanup_apply_dir_plan() {
    local data="$1" dry_run="$2" root="$3"
    [[ -z "$data" ]] && return 0
    [[ -n "$root" ]] || return 1
    root="${root%/}"
    local line target
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        [[ "$line" == *$'\t'prune$'\t'* ]] || continue
        target="${line%%$'\t'*}"
        [[ "$dry_run" == "true" ]] && continue
        # Strictly INSIDE the root, never equal to it.
        [[ "$target" == "$root"/?* ]] || continue
        [[ -d "$target" ]] || continue
        rm -rf -- "$target" 2>/dev/null || true
    done <<<"$data"
    return 0
}
