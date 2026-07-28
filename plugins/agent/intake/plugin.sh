#!/usr/bin/env bash
# plugins/agent/intake — Phase 0.5 stub (issue #85)
# Captures goal, sanitizes sentinels, reads platforms.json, writes
# state/scope-manifest.md + state/intake.md. No LLM call this phase.

[[ -n "${_ZBUILD_INTAKE_LOADED:-}" ]] && return 0
_ZBUILD_INTAKE_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
_INTAKE_DIR="$_ZBUILD_PLUGIN_DIR"
_INTAKE_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_INTAKE_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../../core/output/stage-io.sh
source "$_INTAKE_ROOT/core/output/stage-io.sh"
# #888: per-run worktree isolation (zbuild_worktree_enabled / _prepare).
# shellcheck source=../../../scripts/lib/worktree.sh
source "$_INTAKE_ROOT/scripts/lib/worktree.sh"

# ─── Goal sanitization (ported verbatim from legacy/scripts/lib/goal-sanitize.sh)
# Bash 3.2 safe: %% operator only, no regex, no associative arrays.
_intake_strip_synthesized() {
    local _s="$1"

    # Strip prefix form first (KNOWN FIX prepended with blank line after)
    if [[ "$_s" == "KNOWN FIX (from past success):"* ]]; then
        _s="${_s#*$'\n\n'}"
    fi

    # Strip all suffix sentinels
    _s="${_s%%$'\n\n## Plan Summary'*}"
    _s="${_s%%$'\n\n## Key Design Decisions'*}"
    _s="${_s%%$'\n\nIMPORTANT (TDD mode)'*}"
    _s="${_s%%$'\n\nHistorical context'*}"
    _s="${_s%%$'\n\nDiscoveries from'*}"
    _s="${_s%%$'\n\nFile hotspots'*}"
    _s="${_s%%$'\n\nActive security alerts'*}"
    _s="${_s%%$'\n\nCoverage baseline'*}"
    _s="${_s%%$'\n\n## Skill Guidance'*}"
    _s="${_s%%$'\n\n## Historical Build Context'*}"
    _s="${_s%%$'\n\nBLOCKING ISSUES'*}"
    _s="${_s%%$'\n\nIMPORTANT — Previous build'*}"
    _s="${_s%%$'\n\nIMPORTANT — Code review'*}"
    _s="${_s%%$'\n\nIMPORTANT — Architecture'*}"
    _s="${_s%%$'\n\nIMPORTANT — Compound quality'*}"
    _s="${_s%%$'\n\nHUMAN FEEDBACK'*}"
    _s="${_s%%$'\n\n## Previous Session Context'*}"
    _s="${_s%%$'\n\nWARNING: Memory system'*}"

    printf '%s' "$_s"
}

# ─── Closed-issue gate (ADR-015 #456) ───────────────────────────────────────
# Refuse pipeline runs against CLOSED GitHub issues unless the operator
# explicitly overrides via ZBUILD_ALLOW_CLOSED_ISSUE=1 (strict =1, no =true,
# matching the ZBUILD_SCOPE_OVERRIDE convention at core/router/route.sh).
#
# Returns:
#   0 — OPEN, or gh state-check failed (fall through to existing #421 path),
#       or override set
#   2 — CLOSED and no override
_intake_check_issue_state() {
    local issue="$1"
    [[ -z "$issue" || "$issue" == "0" ]] && return 0

    # Save/restore errexit so callers running with `set -e` aren't broken
    # if gh exits non-zero.
    local state_pair="" gh_rc=0 _had_errexit=0
    [[ $- == *e* ]] && _had_errexit=1
    set +e
    state_pair="$(gh issue view "$issue" --json state,stateReason \
        --jq '(.state // "") + "|" + (.stateReason // "")' 2>/dev/null)"
    gh_rc=$?
    [[ $_had_errexit -eq 1 ]] && set -e

    # gh failure or empty: don't block; fall through to the title+body fetch
    # which has its own graceful fallback (#421). Test: T_456_i.
    [[ $gh_rc -ne 0 || -z "$state_pair" ]] && return 0

    local state state_reason
    state="${state_pair%%|*}"
    state_reason="${state_pair#*|}"
    # If no '|' was in the pair (jq returned just one half) treat as empty.
    [[ "$state_reason" == "$state_pair" ]] && state_reason=""

    [[ "$state" != "CLOSED" ]] && return 0

    # CLOSED — check override (strict =1 per ZBUILD_SCOPE_OVERRIDE convention).
    if [[ "${ZBUILD_ALLOW_CLOSED_ISSUE:-0}" == "1" ]]; then
        warn "intake: issue #${issue} is CLOSED (reason: ${state_reason:-<not specified>}); proceeding due to ZBUILD_ALLOW_CLOSED_ISSUE=1"
        emit_event "intake.override.closed_issue_allowed" \
            "plugin=intake" \
            "issue=${issue}" \
            "state=CLOSED" \
            "state_reason=${state_reason:-}"
        return 0
    fi

    # Refuse — derive issue URL when possible; if `gh repo view` fails,
    # omit the URL rather than emit a malformed token. Test: T_456_j.
    local repo_slug="" url_suffix=""
    local _h2=0
    [[ $- == *e* ]] && _h2=1
    set +e
    repo_slug="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)"
    [[ $? -ne 0 ]] && repo_slug=""
    [[ $_h2 -eq 1 ]] && set -e
    [[ -n "$repo_slug" ]] && url_suffix=" (https://github.com/${repo_slug}/issues/${issue})"

    error "intake: refusing to build closed issue #${issue}${url_suffix}: state=CLOSED reason=${state_reason:-<not specified>}. Set ZBUILD_ALLOW_CLOSED_ISSUE=1 to override."
    emit_event "intake.refused.issue_closed" \
        "plugin=intake" \
        "issue=${issue}" \
        "state=CLOSED" \
        "state_reason=${state_reason:-}" \
        "repo=${repo_slug:-}"
    return 2
}

# ═══════════════════════════════════════════════════════════════════════════
# Issue #484 — Feature branch creation (fail-closed)
#
# Mirrors legacy/scripts/lib/pipeline-stages-intake.sh:66-94 BUT replaces
# the `git checkout || true` silent-failure pattern with strict error
# classification + named refusal events. Branch format diverges from
# legacy's `feature/slug-N` per stakeholder decision: `zbuild/issue-N-slug`
# (issue number BEFORE slug).
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

# _intake_check_preflight
# Validates the working-tree state before any branch op. Emits a refusal
# event on failure and returns 2; returns 0 if all clear.
_intake_check_preflight() {
    # 1) git binary present
    if ! command -v git >/dev/null 2>&1; then
        error "intake_branch: git not found in PATH"
        emit_event "intake.refused.git_unavailable" \
            "plugin=intake" "reason=git_not_found"
        return 2
    fi
    # 2) inside a git repo
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        error "intake_branch: not inside a git repository"
        emit_event "intake.refused.git_unavailable" \
            "plugin=intake" "reason=not_a_git_repo"
        return 2
    fi
    # 3) repo not mid-rebase/bisect/merge
    local git_dir
    git_dir="$(git rev-parse --git-dir 2>/dev/null)"
    local mid_state=""
    if [[ -d "$git_dir/rebase-merge" || -d "$git_dir/rebase-apply" ]]; then
        mid_state="rebase"
    elif [[ -f "$git_dir/MERGE_HEAD" ]]; then
        mid_state="merge"
    elif [[ -f "$git_dir/BISECT_LOG" ]]; then
        mid_state="bisect"
    fi
    if [[ -n "$mid_state" ]]; then
        error "intake_branch: refusing — repository is mid-${mid_state}"
        emit_event "intake.refused.repo_state" \
            "plugin=intake" "reason=repo_state_${mid_state}"
        return 2
    fi
    # 4) dirty working tree (unless override). Use `git status --porcelain` —
    #    non-empty output means tracked changes or untracked files exist.
    if [[ "${ZBUILD_INTAKE_ALLOW_DIRTY:-0}" != "1" ]]; then
        local dirty
        dirty="$(git status --porcelain 2>/dev/null)"
        if [[ -n "$dirty" ]]; then
            error "intake_branch: refusing — working tree is dirty (set ZBUILD_INTAKE_ALLOW_DIRTY=1 to override)"
            emit_event "intake.refused.dirty_tree" \
                "plugin=intake" "reason=working_tree_dirty"
            return 2
        fi
    fi
    return 0
}

# _intake_checkout_branch <branch>
# Idempotent checkout with error classification. Emits:
#   - intake.branch.noop      (already on target)
#   - intake.branch.reused    (local branch existed)
#   - intake.branch.adopted   (remote branch fetched and checked out)
#   - intake.branch.created   (new local branch)
#   - intake.error            (checkout/fetch failures)
# Sets _INTAKE_BRANCH_OUTCOME to one of: noop|reused|adopted|created
_intake_checkout_branch() {
    local target="$1"
    _INTAKE_BRANCH_OUTCOME=""

    # Validate up front so callers don't have to.
    if ! _intake_validate_branch_name "$target"; then
        error "intake_branch: invalid branch name: '$target'"
        emit_event "intake.refused.invalid_branch_name" \
            "plugin=intake" "branch=$target" "reason=invalid_branch_name"
        return 2
    fi

    # Capture current state for event payloads.
    local current previous_head base_sha
    current="$(git symbolic-ref --short HEAD 2>/dev/null || true)"
    previous_head="${current:-detached}"
    base_sha="$(git rev-parse HEAD 2>/dev/null || echo unknown)"

    # Detached HEAD info event (non-fatal — we branch from current commit).
    if [[ -z "$current" ]]; then
        emit_event "intake.branch.from_detached" \
            "plugin=intake" "base=$base_sha" "target=$target"
    fi

    # Already on target → no-op.
    if [[ -n "$current" && "$current" == "$target" ]]; then
        emit_event "intake.branch.noop" \
            "plugin=intake" "branch=$target" "base=$base_sha"
        _INTAKE_BRANCH_OUTCOME="noop"
        return 0
    fi

    # Does local branch exist?
    if git show-ref --verify --quiet "refs/heads/$target"; then
        if ! git checkout "$target" >/dev/null 2>&1; then
            error "intake_branch: checkout of existing branch '$target' failed"
            emit_event "intake.error" \
                "plugin=intake" "branch=$target" "reason=checkout_failed"
            return 2
        fi
        # Verify post-checkout
        local after
        after="$(git symbolic-ref --short HEAD 2>/dev/null || true)"
        if [[ "$after" != "$target" ]]; then
            error "intake_branch: post-checkout HEAD mismatch (expected '$target', got '$after')"
            emit_event "intake.error" \
                "plugin=intake" "branch=$target" "reason=post_checkout_mismatch"
            return 2
        fi
        local ahead_count
        ahead_count="$(git rev-list --count "main..$target" 2>/dev/null || echo 0)"
        emit_event "intake.branch.reused" \
            "plugin=intake" "branch=$target" "base=$base_sha" \
            "previous_head=$previous_head" "ahead_count=$ahead_count"
        _INTAKE_BRANCH_OUTCOME="reused"
        return 0
    fi

    # Local branch absent — does it exist on remote? Adopt it.
    # `git show-ref` won't list remote refs unless we look at remotes/.
    if git show-ref --verify --quiet "refs/remotes/origin/$target"; then
        # Fetch the remote branch as a local tracking branch.
        if ! git fetch origin "$target:$target" >/dev/null 2>&1; then
            error "intake_branch: failed to fetch remote branch '$target'"
            emit_event "intake.error" \
                "plugin=intake" "branch=$target" "reason=fetch_failed"
            return 2
        fi
        # Checkout the newly fetched branch.
        if ! git checkout "$target" >/dev/null 2>&1; then
            error "intake_branch: checkout of fetched branch '$target' failed"
            emit_event "intake.error" \
                "plugin=intake" "branch=$target" "reason=checkout_failed"
            return 2
        fi
        # Verify post-checkout.
        local after
        after="$(git symbolic-ref --short HEAD 2>/dev/null || true)"
        if [[ "$after" != "$target" ]]; then
            error "intake_branch: post-checkout HEAD mismatch (expected '$target', got '$after')"
            emit_event "intake.error" \
                "plugin=intake" "branch=$target" "reason=post_checkout_mismatch"
            return 2
        fi
        local ahead_count
        ahead_count="$(git rev-list --count "main..$target" 2>/dev/null || echo 0)"
        emit_event "intake.branch.adopted" \
            "plugin=intake" "branch=$target" "base=$base_sha" \
            "previous_head=$previous_head" "ahead_count=$ahead_count" "source=remote"
        _INTAKE_BRANCH_OUTCOME="adopted"
        return 0
    fi

    # Create new branch.
    if ! git checkout -b "$target" >/dev/null 2>&1; then
        error "intake_branch: 'git checkout -b $target' failed"
        emit_event "intake.error" \
            "plugin=intake" "branch=$target" "reason=branch_create_failed"
        return 2
    fi
    # Verify post-checkout.
    local after
    after="$(git symbolic-ref --short HEAD 2>/dev/null || true)"
    if [[ "$after" != "$target" ]]; then
        error "intake_branch: post-create HEAD mismatch (expected '$target', got '$after')"
        emit_event "intake.error" \
            "plugin=intake" "branch=$target" "reason=post_create_mismatch"
        return 2
    fi
    emit_event "intake.branch.created" \
        "plugin=intake" "branch=$target" "base=$base_sha" \
        "previous_head=$previous_head"
    _INTAKE_BRANCH_OUTCOME="created"
    return 0
}

# _intake_create_workspace_branch <state_dir> <issue> <title>
# Top-level orchestrator: env override > preflight > derive > checkout >
# state writes. Returns 0 on success, 2 on any refusal/error.
_intake_create_workspace_branch() {
    local state_dir="$1" issue="$2" title="$3"

    # Env override (with deprecated WORKSPACE_BRANCH alias).
    local override="${ZBUILD_WORKSPACE_BRANCH:-}"
    if [[ -z "$override" && -n "${WORKSPACE_BRANCH:-}" ]]; then
        warn "intake_branch: WORKSPACE_BRANCH is deprecated; use ZBUILD_WORKSPACE_BRANCH"
        override="$WORKSPACE_BRANCH"
    fi

    # CI mode: refuse if no override.
    local ci_mode=0
    if [[ "${CI:-false}" == "true" || "${CI_MODE:-false}" == "true" ]]; then
        ci_mode=1
    fi
    if [[ $ci_mode -eq 1 && -z "$override" ]]; then
        error "intake_branch: CI mode requires ZBUILD_WORKSPACE_BRANCH to be set"
        emit_event "intake.refused.invalid_branch_name" \
            "plugin=intake" "reason=ci_workspace_branch_unset"
        return 2
    fi

    # Preflight (git binary, repo state, dirty tree).
    _intake_check_preflight || return 2

    local target
    if [[ -n "$override" ]]; then
        if ! _intake_validate_branch_name "$override"; then
            error "intake_branch: ZBUILD_WORKSPACE_BRANCH='$override' is invalid"
            emit_event "intake.refused.invalid_branch_name" \
                "plugin=intake" "branch=$override" "reason=env_override_invalid"
            return 2
        fi
        target="$override"
    else
        target="$(_intake_derive_branch_name "$issue" "$title")"
    fi

    # ── #888: work in a per-run worktree so concurrent runs stop racing one
    #    working tree's .git/index and refs. Default-on; ZBUILD_NO_WORKTREE=1 opts
    #    out. The worktree is created DETACHED and the existing checkout below
    #    runs inside it — that keeps intake's four branch paths (create /
    #    reuse-local / adopt-remote / noop) as the single source of truth instead
    #    of duplicating branch selection into the worktree helper.
    #
    #    Ordering matters: the dirty-tree preflight above deliberately still runs
    #    against the MAIN tree, before this cd. With a worktree the main tree is
    #    untouched so that check is arguably unnecessary friction, but keeping it
    #    means worktree-mode is not quietly more permissive than in-place mode.
    #    Worktree isolation is a PER-RUN concept, so it requires a run id. With
    #    ZBUILD_RUN_ID unset every invocation would share one path (the earlier
    #    `${ZBUILD_RUN_ID:-manual}` default did exactly that) — the second run
    #    finds the worktree on the first run's branch and fails. A shared worktree
    #    is worse than none, so fall back to in-place instead. The runner always
    #    exports ZBUILD_RUN_ID (core/pipeline/runner.sh:1189); direct callers and
    #    unit tests that do not are the case this covers.
    if declare -F zbuild_worktree_enabled >/dev/null 2>&1 && zbuild_worktree_enabled \
       && [[ -n "${ZBUILD_RUN_ID:-}" ]]; then
        # ONE call. stderr is deliberately NOT captured — the helper's messages
        # (branch held elsewhere, git's own refusal) belong in the run log where a
        # reader will see them, not swallowed into a variable.
        local _wt_path=""
        _wt_path="$(zbuild_worktree_prepare "$ZBUILD_RUN_ID" "$target")" || _wt_path=""
        if [[ -z "$_wt_path" ]]; then
            error "intake_branch: could not prepare the per-run worktree (see above)"
            emit_event "intake.refused.worktree_prepare_failed" \
                "plugin=intake" "branch=$target" "run_id=$ZBUILD_RUN_ID"
            return 2
        fi
        cd "$_wt_path" || {
            error "intake_branch: cannot cd into worktree $_wt_path"
            return 2
        }
        # Downstream stages resolve their tree from ZBUILD_REPO_ROOT; pr-open was
        # anchored to it in the same issue so the PR pushes from here, not $PWD.
        export ZBUILD_REPO_ROOT="$_wt_path"
        printf '%s\n' "$_wt_path" | atomic_write "$state_dir/intake-worktree.txt"
        emit_event "intake.worktree.entered" \
            "plugin=intake" "branch=$target" "worktree=$_wt_path" \
            "run_id=$ZBUILD_RUN_ID"
    fi

    _intake_checkout_branch "$target" || return 2

    # State writes — atomic single-line file + optional pipeline-state JSON
    # field (only when the state JSON exists and the helper is loaded).
    printf '%s\n' "$target" | atomic_write "$state_dir/intake-branch.txt"

    # Wave 8 #614: record post-checkout HEAD as the "intake baseline".
    # Build plugin + router loop read this back when assembling iter prompts
    # so the LLM can see commits already on the branch ("already done"
    # recognition). Bare SHA, no trailing newline — printf '%s', not 'echo'.
    local _baseline_sha
    _baseline_sha="$(git rev-parse HEAD 2>/dev/null || true)"
    if [[ -n "$_baseline_sha" ]]; then
        printf '%s' "$_baseline_sha" > "$state_dir/intake-baseline-ref.txt"
        emit_event "intake.baseline.captured" \
            "plugin=intake" "sha=$_baseline_sha"
    fi

    # #1265: snapshot the PRE-EXISTING untracked set at run-start. The build's
    # scope-census baselines against this so a stray file left in the working
    # tree by a PRIOR run (present at intake, NOT created by THIS run) is never
    # false-flagged as build-created out-of-scope collateral (ADR-030). NUL-
    # delimited so paths with spaces/newlines survive. Unconditional — captured
    # even under ZBUILD_INTAKE_ALLOW_DIRTY (the dogfood path where strays enter).
    local _untracked_baseline="$state_dir/intake-untracked-baseline.txt"
    if git ls-files --others --exclude-standard -z > "$_untracked_baseline" 2>/dev/null; then
        local _untracked_count
        _untracked_count="$(tr -cd '\0' < "$_untracked_baseline" | wc -c | tr -d ' ')"
        emit_event "intake.untracked_baseline.captured" \
            "plugin=intake" "count=${_untracked_count:-0}"
    fi

    local pipeline_state="$state_dir/pipeline-state.json"
    if [[ -f "$pipeline_state" ]] && declare -F _set_pipeline_branch >/dev/null 2>&1; then
        _set_pipeline_branch "$pipeline_state" "$target" 2>/dev/null || \
            warn "intake_branch: failed to record .branch in pipeline-state.json (non-fatal)"
    fi

    return 0
}

# ─── init ────────────────────────────────────────────────────────────────────
intake_init() {
    export ZBUILD_PLUGIN="intake"
    export ZBUILD_PLUGIN_KIND="agent"
    emit_event "plugin.init.start" "plugin=intake"
    return 0
}

# ─── run ─────────────────────────────────────────────────────────────────────
# Args: $1 = stage_id, $2 = state_file
# Reads: ZBUILD_GOAL (env), ZBUILD_ISSUE (env, optional)
# Writes: $(dirname $state_file)/scope-manifest.md
#         $(dirname $state_file)/intake.md
intake_run() {
    local goal="${ZBUILD_GOAL:-}"
    local issue="${ZBUILD_ISSUE:-0}"

    # Support --issue mode: when goal text is absent, derive it from the issue number.
    # Runner exports ZBUILD_GOAL="" in --issue runs, so we fall back rather than hard-fail.
    if [[ -z "$goal" ]]; then
        if [[ -n "$issue" && "$issue" != "0" ]]; then
            # ADR-015 #456: refuse closed issues before fetching body.
            local _state_rc=0
            _intake_check_issue_state "$issue" || _state_rc=$?
            if [[ $_state_rc -ne 0 ]]; then
                return $_state_rc
            fi

            # Fetch real title + body from GitHub so the plan stage has context.
            # --jq emits "title\n\nbody" (title-only when body is null/empty).
            # gh failure or empty result → fall back to placeholder + warn so
            # offline/CI runs without auth still complete.
            #
            # Save/restore errexit via $- so callers running with `set +e`
            # don't get -e flipped back on as a side effect.
            local fetched="" gh_rc=0 _had_errexit=0
            [[ $- == *e* ]] && _had_errexit=1
            set +e
            # #491: do NOT redirect run_captured_command's stderr — the
            # command-kind stage-io input banner writes to fd 2 (default
            # ZBUILD_STAGE_IO_FD) and 2>/dev/null would swallow it, breaking
            # the ADR-015 §v4 input-before-action ordering contract.
            fetched="$(run_captured_command intake gh issue view "$issue" \
                --json title,body \
                --jq '(.title // "") as $t
                      | (.body  // "") as $b
                      | if ($t | length) == 0 then ""
                        elif ($b | length) == 0 then $t
                        else $t + "\n\n" + $b
                        end')"
            gh_rc=$?
            [[ $_had_errexit -eq 1 ]] && set -e
            if [[ $gh_rc -eq 0 && -n "$fetched" ]]; then
                goal="$fetched"
            else
                warn "intake_run: gh issue view #${issue} failed (rc=${gh_rc}); using placeholder"
                goal="GitHub issue #${issue}"
            fi
        else
            error "intake_run: ZBUILD_GOAL is required (or pass --issue <N>)"
            return 2
        fi
    fi

    local state_file="${2:-}"
    if [[ -z "$state_file" ]]; then
        error "intake_run: state_file argument required"
        return 2
    fi
    local state_dir; state_dir="$(dirname "$state_file")"

    local sanitized
    sanitized="$(_intake_strip_synthesized "$goal")"
    if [[ -z "$sanitized" ]]; then
        error "intake_run: goal empty after sentinel sanitization"
        return 2
    fi

    # Read detected platforms (written by core/detect/platforms.sh before intake runs)
    local platforms=()
    while IFS= read -r p; do
        [[ -n "$p" ]] && platforms+=("$p")
    done < <(jq -r '.detected[]' "$state_dir/platforms.json" 2>/dev/null || true)
    [[ ${#platforms[@]} -eq 0 ]] && platforms=("generic")

    # Build scope-manifest: one "+ <platform>/" line per platform.
    # Validate platform IDs to ^[a-z0-9_-]+$ before writing — platform values
    # come from plugin manifests / .zbuild/platforms.json and are not fully
    # trusted; malicious values could expand the redaction allowlist via path
    # injection. Use printf '%s' (not '%b') to prevent backslash interpretation.
    {
        local p
        for p in "${platforms[@]}"; do
            if [[ "$p" == "generic" ]]; then
                printf '+ ./\n'
            elif [[ "$p" =~ ^[a-z0-9_-]+$ ]]; then
                printf '+ %s/\n' "$p"
            else
                warn "intake_run: skipping invalid platform id: $p"
            fi
        done
    } | atomic_write "$state_dir/scope-manifest.md"
    printf '%s\n' "$sanitized"   | atomic_write "$state_dir/intake.md"

    # Issue #484: derive title from first line of sanitized goal for branch slug.
    # Mirrors legacy's `slug=$(echo "$GOAL" | tr ... | sed ... | cut ...)`,
    # but we use the title line (first \n-terminated chunk) so multi-line
    # issue bodies don't bloat the slug. The 40-char cut in _intake_derive
    # provides the same bound legacy:84 used.
    local _title_line
    _title_line="${sanitized%%$'\n'*}"

    # Load state_helpers if available so _set_pipeline_branch can record the
    # branch on the pipeline-state.json. Defer-loaded to avoid hard coupling.
    if ! declare -F _set_pipeline_branch >/dev/null 2>&1; then
        # shellcheck source=../../../core/pipeline/state_helpers.sh
        [[ -f "$_INTAKE_ROOT/core/pipeline/state_helpers.sh" ]] && \
            source "$_INTAKE_ROOT/core/pipeline/state_helpers.sh" 2>/dev/null || true
    fi

    # Branch creation is fail-CLOSED — any refusal propagates as rc=2 so
    # the pipeline halts before downstream stages corrupt main/HEAD. Tests
    # that don't exercise the real git path set ZBUILD_INTAKE_SKIP_BRANCH=1.
    if [[ "${ZBUILD_INTAKE_SKIP_BRANCH:-0}" != "1" ]]; then
        local _branch_rc=0
        _intake_create_workspace_branch "$state_dir" "$issue" "$_title_line" \
            || _branch_rc=$?
        if [[ $_branch_rc -ne 0 ]]; then
            return $_branch_rc
        fi
    fi

    emit_event "plugin.run.complete" "plugin=intake" \
        "goal_len=${#sanitized}" \
        "platform_count=${#platforms[@]}"
    return 0
}

# ─── finalize ────────────────────────────────────────────────────────────────
intake_finalize() {
    emit_event "plugin.finalize.complete" "plugin=intake"
    return 0
}
