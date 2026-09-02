#!/usr/bin/env bash
# plugins/tool/pr-open/plugin.sh — PR Open Stage (ADR-013, issue #344)
# Opens a PR via `gh pr create`. No LLM. No redaction. T0 tool.
# Safety constraints:
#   - Non-draft by default; set _TPL_PR_DRAFT=true (pr_draft: true in template) for draft mode
#   - Refuses if review.json verdict == "block" (rc=2)
#   - Refuses if current branch is main or master (rc=2)
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_PR_OPEN_LOADED:-}" ]] && return 0
_ZBUILD_PR_OPEN_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
# shellcheck source=../../../scripts/lib/stage-summary.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/stage-summary.sh"
_PR_OPEN_DIR="$_ZBUILD_PLUGIN_DIR"
_PR_OPEN_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_PR_OPEN_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../../scripts/lib/git-remote.sh
source "$_PR_OPEN_ROOT/scripts/lib/git-remote.sh"
# #1265: merge-base resolver for the 0-commit preflight (halt before push/gh).
# shellcheck source=../../../scripts/lib/merge-base.sh
source "$_PR_OPEN_ROOT/scripts/lib/merge-base.sh"

# ─── pr_open_run ─────────────────────────────────────────────────────────────
# Entry point invoked by the pipeline runner.
# Args: $1 = stage_id, $2 = state_file
pr_open_run() {
    local stage_id="${1:-pr}"; : "$stage_id"  # consumed by pipeline runner; unused in body
    local state_file="${2:-}"

    if [[ -z "$state_file" ]]; then
        error "pr_open_run: state_file argument required"
        stage_summary_write "${ZBUILD_ARTIFACT_DIR:+$ZBUILD_ARTIFACT_DIR/pr-open-summary.md}" "pr-open" "error" \
            "the engine dispatched this stage with no state file, so it could not run" \
            "No work was attempted. This is an engine contract violation, not a fault in the change."
        return 2
    fi

    # #888: every other git-mutating stage resolves its tree from
    # ZBUILD_REPO_ROOT; pr-open was the one that did not, running bare
    # `git checkout` / push / `gh pr create` in $PWD. That is already wrong for
    # anyone who sets ZBUILD_REPO_ROOT today, and it is the failure that would
    # make per-run worktrees silently push the WRONG branch — the whole point of
    # the isolation. Anchor the stage to the target tree once, here, rather than
    # converting every call site to `git -C` and hoping none is missed later.
    #
    # Absolutise state_file BEFORE the cd: it may be passed relative, and every
    # later read of it (and of state_dir/artifacts_dir derived from it) would
    # otherwise resolve against the new working directory.
    if [[ "$state_file" != /* ]]; then
        # Check the subshell: this library has no `set -e`, so a failing `cd`
        # (directory not yet created) would leave state_file as "/<basename>" —
        # an accidental root-relative path, read and written silently in the
        # wrong place.
        local _abs_dir
        if ! _abs_dir="$(cd "$(dirname "$state_file")" 2>/dev/null && pwd)"; then
            error "pr_open_run: cannot resolve state_file directory: $(dirname "$state_file")"
            return 2
        fi
        state_file="$_abs_dir/$(basename "$state_file")"
    fi
    if [[ -n "${ZBUILD_REPO_ROOT:-}" ]]; then
        if [[ -d "$ZBUILD_REPO_ROOT" ]]; then
            cd "$ZBUILD_REPO_ROOT" || {
                error "pr_open_run: cannot cd to ZBUILD_REPO_ROOT=$ZBUILD_REPO_ROOT"
                return 2
            }
        else
            error "pr_open_run: ZBUILD_REPO_ROOT=$ZBUILD_REPO_ROOT is not a directory"
            return 2
        fi
    fi

    local state_dir; state_dir="$(dirname "$state_file")"
    local artifacts_dir="$state_dir/artifacts"
    local review_json_path="$artifacts_dir/review.json"
    local output_pr_result_json="$artifacts_dir/pr-result.json"

    # Read issue number from state file
    local issue_num
    issue_num="$(jq -r '.issue // "0"' "$state_file" 2>/dev/null || echo "0")"
    # Strip quotes if the value was stored as a string
    issue_num="${issue_num//\"/}"

    mkdir -p "$artifacts_dir"

    _pr_open_run_inner "$review_json_path" "$state_file" "$output_pr_result_json" "$issue_num"
}

# ─── _pr_open_render_advisory_section ────────────────────────────────────────
# Renders a markdown summary of review-report.json for the PR body.
# Absent file   -> "no advisory review ran"
# Unreadable    -> says so explicitly (never "no findings"; #1618)
# findings=[]   -> "no findings"
# otherwise     -> count/lens header + top-5 bullets sorted by severity
#                  + <details> block for any beyond the first five.
_pr_open_render_advisory_section() {
    local advisory_report="$1"
    if [[ ! -f "$advisory_report" ]]; then
        printf 'no advisory review ran'
        return 0
    fi

    # A report we cannot parse must not fall through to the "no findings"
    # wording: that claims a clean review we never actually read (#1618).
    local findings_count lenses_count
    if ! findings_count="$(jq -r '.findings | if type=="array" then length else "invalid" end' \
        "$advisory_report" 2>/dev/null)" || [[ ! "$findings_count" =~ ^[0-9]+$ ]]; then
        printf 'advisory review ran but its report could not be read - findings not rendered'
        return 0
    fi
    lenses_count="$(jq -r '.lenses | if type=="array" then length else 0 end' \
        "$advisory_report" 2>/dev/null || echo 0)"
    [[ "$lenses_count" =~ ^[0-9]+$ ]] || lenses_count=0

    if [[ "$findings_count" -eq 0 ]]; then
        printf 'no findings'
        return 0
    fi

    # Findings are LLM-authored free text rendered into a GitHub PR body: strip
    # ANSI, flatten control chars, and escape markdown/HTML metacharacters so a
    # finding cannot inject active markup. Messages are truncated to bound the
    # body size - GitHub rejects a create over ~65 KB.
    #
    # Only \ [ ] < > are escaped, deliberately. Those are the ones that inject:
    # escaping [ and ] already breaks "[text](url)" without touching the parens,
    # and escaping < > blocks raw HTML. Backticks, _ and * are left alone
    # because findings use them as prose formatting - escaping those too was
    # measured and turned every message into backslash noise.
    local _jq_defs='
        def esc: tostring
            | gsub("\\e\\[[0-9;?]*[A-Za-z~]"; "")
            | gsub("\\p{Cntrl}"; " ")
            | gsub("(?<c>[\\\\\\[\\]<>])"; "\\" + .c);
        def rank: (. // "" | ascii_downcase) as $s
            | {"critical":0,"high":1,"medium":2,"low":3}[$s] // 4;
        def loc: (.file | esc)
            + (if (.line | type) == "number" then ":\(.line)" else "" end);
        def msg: (.messages // [])
            | if length > 0 then
                  (.[0] | tostring
                    | if length > 300 then .[0:300] + "..." else . end
                    | esc)
              else "" end;
        def bullet: "- **[" + (.severity | esc) + "]** " + loc
            + (msg | if . == "" then "" else " - " + . end)
            + " _(" + ((.lenses // []) | map(esc) | join(", ")) + ")_";
        def sorted: [ .findings[] ] | sort_by(.severity | rank);
    '

    printf '%d finding(s) across %d lens(es)\n' "$findings_count" "$lenses_count"

    jq -r "$_jq_defs"' sorted | .[0:5][] | bullet' "$advisory_report" 2>/dev/null || true

    if [[ "$findings_count" -gt 5 ]]; then
        local rest_count=$(( findings_count - 5 ))
        printf '\n<details><summary>%d more finding(s)</summary>\n\n' "$rest_count"
        jq -r "$_jq_defs"' sorted | .[5:][] | bullet' "$advisory_report" 2>/dev/null || true
        printf '\n</details>'
    fi
}

# ─── _pr_open_run_inner ───────────────────────────────────────────────────────
# Inner logic, separated for testability.
# Args:
#   $1 = review_json_path
#   $2 = state_file
#   $3 = output_pr_result_json
#   $4 = issue_num
_pr_open_run_inner() {
    local review_json_path="$1"
    local state_file="$2"
    local output_pr_result_json="$3"
    local issue_num="$4"

    local artifacts_dir; artifacts_dir="$(dirname "$output_pr_result_json")"
    mkdir -p "$artifacts_dir"

    # Normalize to a strict JSON boolean literal: only "true" stays true; any
    # other value (unset, empty, or a bogus env-injected string that bypassed
    # the template validator) collapses to "false". Guarantees `--argjson draft`
    # and printf %s never receive non-boolean input.
    local _draft_bool="${_TPL_PR_DRAFT:-false}"
    [[ "$_draft_bool" == "true" ]] || _draft_bool="false"

    # ── Safety check 1: refuse if on main or master ──────────────────────────
    local current_branch
    current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"
    if [[ "$current_branch" == "main" || "$current_branch" == "master" ]]; then
        error "pr_open: refusing to open PR from branch '${current_branch}' — use a feature branch"
        stage_summary_write "$artifacts_dir/pr-open-summary.md" "pr-open" "error" \
            "refused to open a PR from ${current_branch}" \
            "No PR was opened; a PR from the trunk into itself is never correct."
        emit_event "plugin.result" "verdict=error" "plugin=pr-open" \
            "reason=branch_is_main" "branch=${current_branch}"
        jq -n \
            --arg branch "$current_branch" \
            --argjson draft "${_draft_bool}" \
            '{"schema_version":1,"status":"error","reason":("refusing to open PR from branch: "+$branch),"draft":$draft}' \
            > "$output_pr_result_json"
        return 2
    fi

    # ── Safety check 2/3: review verdict source (#1142, ADR-040) ─────────────
    # review.json = the BLOCKING-review model (standard.yaml): apply the verdict
    # guard below (refuse on block). If it is absent, fall back to the advisory
    # review-report.json (simple.yaml's review-aggregator — advisory lenses NEVER
    # block; convergence was already gated by the gate-aggregator's exit_when):
    # open the PR with no verdict guard. Fail-closed (ADR-001/#358) only when
    # NEITHER review signal exists.
    local advisory_report="$artifacts_dir/review-report.json"
    if [[ -f "$review_json_path" ]]; then
        local verdict
        verdict="$(jq -r '.verdict // ""' "$review_json_path" 2>/dev/null || echo "")"
        if [[ "$verdict" == "block" ]]; then
            error "pr_open: refusing to open PR — review verdict is 'block'"
            stage_summary_write "$artifacts_dir/pr-open-summary.md" "pr-open" "error" \
                "the review verdict blocks opening a PR" \
                "No PR was opened. The review stage judged the change not ready."
            emit_event "plugin.result" "verdict=error" "plugin=pr-open" \
                "reason=review_verdict_block" "verdict=${verdict}"
            jq -n \
                --argjson draft "${_draft_bool}" \
                '{"schema_version":1,"status":"blocked","reason":"review verdict is block","draft":$draft}' \
                > "$output_pr_result_json"
            return 2
        fi
    elif [[ -f "$advisory_report" ]]; then
        warn "pr_open: review.json absent — advisory-review mode (review-report.json present; ADR-040 lenses never block, #1142)"
    else
        error "pr_open: refusing to open PR — no review signal (neither review.json nor review-report.json; fail-closed per ADR-001)"
        stage_summary_write "$artifacts_dir/pr-open-summary.md" "pr-open" "error" \
            "no review signal was available to authorise a PR" \
            "No PR was opened. Fail-closed: absence of a review is not approval."
        emit_event "plugin.result" "verdict=error" "plugin=pr-open" \
            "reason=review_signal_missing" "path=${review_json_path}"
        jq -n \
            --argjson draft "${_draft_bool}" \
            '{"schema_version":1,"status":"blocked","reason":"no review signal — fail-closed per ADR-001","draft":$draft}' \
            > "$output_pr_result_json"
        return 2
    fi

    # ── Determine target branch ───────────────────────────────────────────────
    # Issue #484: prefer the branch recorded by intake (state.branch or
    # intake-branch.txt) so we use the slug-bearing name intake already
    # created. Fall back to the legacy zbuild/issue-N form so existing
    # state files without a .branch field still work (transitional).
    local target_branch=""
    target_branch="$(jq -r '.branch // empty' "$state_file" 2>/dev/null || true)"
    if [[ -z "$target_branch" || "$target_branch" == "null" ]]; then
        local _state_dir; _state_dir="$(dirname "$state_file")"
        if [[ -f "$_state_dir/intake-branch.txt" ]]; then
            target_branch="$(head -n1 "$_state_dir/intake-branch.txt" 2>/dev/null | tr -d '[:space:]' || true)"
        fi
    fi
    if [[ -z "$target_branch" ]]; then
        target_branch="zbuild/issue-${issue_num}"
        emit_event "plugin.pr_open.branch_fallback_used" \
            "plugin=pr-open" "branch=${target_branch}" "reason=no_state_branch"
    fi
    if [[ "$current_branch" != "$target_branch" ]]; then
        git checkout -b "$target_branch" 2>/dev/null || git checkout "$target_branch" 2>/dev/null || {
            error "pr_open: failed to create or switch to branch '${target_branch}'"
            stage_summary_write "$artifacts_dir/pr-open-summary.md" "pr-open" "error" \
                "could not check out the branch to open a PR from" \
                "No PR was opened."
            emit_event "plugin.result" "verdict=error" "plugin=pr-open" \
                "reason=branch_checkout_failed" "branch=${target_branch}"
            jq -n \
                --arg branch "$target_branch" \
                --argjson draft "${_draft_bool}" \
                '{"schema_version":1,"status":"error","reason":("failed to checkout branch: "+$branch),"draft":$draft}' \
                > "$output_pr_result_json"
            return 2
        }
    fi

    # ── #1265: 0-commit preflight (BEFORE push + gh pr create) ────────────────
    # If the branch has no commits ahead of the merge-base, there is nothing to
    # PR: pushing then `gh pr create` fails with "No commits between main and
    # branch" only AFTER a wasted push (the #1214 dogfood, ~38 min in). Halt
    # terminally here instead. Belt-and-suspenders for non-cycle paths + a clear
    # reason. Consistent with #1208: a legit empty_diff converge with 0 real
    # commits genuinely has nothing to ship, so halting is correct (not a regress).
    local _merge_base _ahead_count
    _merge_base="$(zbuild_resolve_merge_base 2>/dev/null || true)"
    if [[ -n "$_merge_base" ]]; then
        _ahead_count="$(git rev-list --count "${_merge_base}..HEAD" 2>/dev/null || echo -1)"
        if [[ "$_ahead_count" == "0" ]]; then
            # ADR-050 (#1581): local HEAD has nothing ahead of the merge-base.
            # Before refusing, check the REMOTE work branch — a prior run may have
            # committed + pushed the work while this run cold-started (e.g. intake
            # couldn't adopt the branch). If origin/<branch> carries commits, the
            # work IS shippable: zbuild_push_reconcile below no-ops when the remote
            # is strictly ahead (never clobbers), and the PR reuse/create still
            # opens/updates the PR against origin's tip. Only refuse when there is
            # genuinely nothing to ship anywhere (local AND remote both empty).
            local _remote_ahead="-1"
            if git rev-parse --verify --quiet "refs/remotes/origin/${target_branch}" >/dev/null 2>&1; then
                _remote_ahead="$(git rev-list --count "${_merge_base}..refs/remotes/origin/${target_branch}" 2>/dev/null || echo -1)"
            fi
            if [[ "$_remote_ahead" =~ ^[0-9]+$ && "$_remote_ahead" -gt 0 ]]; then
                warn "pr_open: local HEAD has no new commits, but origin/${target_branch} carries ${_remote_ahead} commit(s) — the work is already on origin; opening/updating the PR against it (not re-shipping, not overwriting)."
                emit_event "plugin.pr_open.preflight_remote_has_work" "plugin=pr-open" \
                    "branch=${target_branch}" "remote_ahead=${_remote_ahead}"
                # fall through to push (no-op on strictly-ahead remote) + PR reuse
            else
                error "pr_open: refusing to open PR — no commits between merge-base and '${current_branch}', and origin/${target_branch} has no prior work either (nothing to ship anywhere)"
                stage_summary_write "$artifacts_dir/pr-open-summary.md" "pr-open" "error" \
                    "there are no committed changes to open a PR for" \
                    "No PR was opened. The build stage produced no commit."
                emit_event "plugin.result" "verdict=error" "plugin=pr-open" \
                    "reason=no_committed_changes" "branch=${current_branch}"
                jq -n \
                    --argjson draft "${_draft_bool}" \
                    '{"schema_version":1,"status":"error","reason":"no committed changes on branch or origin","draft":$draft}' \
                    > "$output_pr_result_json"
                return 2
            fi
        fi
    fi

    # ── Push branch so gh pr create can find it ───────────────────────────────
    # zbuild_push_reconcile tolerates an already-pushed / diverged remote branch
    # (push / fast-forward / safe force-with-lease) and surfaces git's real
    # stderr in ZBUILD_PUSH_RECONCILE_ERR (Issue PR). It never force-pushes the
    # default branch — that plus the main/master refusal above is defense-in-depth.
    if ! zbuild_push_reconcile "$target_branch"; then
        error "pr_open: push reconcile failed for '${target_branch}': ${ZBUILD_PUSH_RECONCILE_ERR}"
        stage_summary_write "$artifacts_dir/pr-open-summary.md" "pr-open" "error" \
            "could not push the branch to the remote" \
            "No PR was opened."
        emit_event "plugin.result" "verdict=error" "plugin=pr-open" \
            "reason=branch_push_failed" "branch=${target_branch}"
        jq -n --arg branch "$target_branch" --arg detail "$ZBUILD_PUSH_RECONCILE_ERR" \
            --argjson draft "${_draft_bool}" \
            '{"schema_version":1,"status":"error","reason":("failed to push branch: "+$branch+": "+$detail),"draft":$draft}' \
            > "$output_pr_result_json"
        return 2
    fi

    # ── Open draft PR via gh ──────────────────────────────────────────────────
    local pr_title
    if [[ -n "$issue_num" && "$issue_num" != "0" ]]; then
        pr_title="zbuild: automated PR for issue #${issue_num}"
    else
        pr_title="zbuild: automated draft PR"
    fi

    # Build PR body from upstream artifacts (plan summary, review verdict, test results)
    local plan_summary="" review_verdict="" test_verdict=""
    if [[ -f "${artifacts_dir}/plan.json" ]]; then
        plan_summary="$(jq -r '.goal // ""' "${artifacts_dir}/plan.json" 2>/dev/null || true)"
    fi
    if [[ -f "$review_json_path" ]]; then
        review_verdict="$(jq -r '.verdict // ""' "$review_json_path" 2>/dev/null || true)"
    fi
    if [[ -f "${artifacts_dir}/test-results.json" ]]; then
        test_verdict="$(jq -r '.verdict // ""' "${artifacts_dir}/test-results.json" 2>/dev/null || true)"
    fi

    local advisory_section
    advisory_section="$(_pr_open_render_advisory_section "$advisory_report")"

    # The advisory block is followed by a BLANK line: it can end in a closing
    # </details>, and GitHub keeps consuming an HTML block until one appears —
    # without it the next line renders as raw HTML instead of markdown. It has
    # to be added here, not inside the renderer, because the command
    # substitution above strips every trailing newline the renderer emits.
    local pr_body
    if [[ -f "$review_json_path" ]]; then
        pr_body="$(printf '%s\n\n%s\n%s\n%s\n%s\n\n%s\n%s\n%s' \
            "${issue_num:+Closes #${issue_num}}" \
            "---" \
            "**Plan goal:** ${plan_summary:-N/A}" \
            "**Review verdict:** ${review_verdict:-N/A}" \
            "**Advisory review (non-blocking, ADR-040):** ${advisory_section}" \
            "**Test verdict:** ${test_verdict:-N/A}" \
            "" \
            "Generated by zBuild automation.")"
    else
        pr_body="$(printf '%s\n\n%s\n%s\n%s\n\n%s\n%s\n%s' \
            "${issue_num:+Closes #${issue_num}}" \
            "---" \
            "**Plan goal:** ${plan_summary:-N/A}" \
            "**Advisory review (non-blocking, ADR-040):** ${advisory_section}" \
            "**Test verdict:** ${test_verdict:-N/A}" \
            "" \
            "Generated by zBuild automation.")"
    fi

    local -a _gh_args=()
    [[ "${_draft_bool}" == "true" ]] && _gh_args+=("--draft")
    _gh_args+=(--title "$pr_title" --body "$pr_body")

    # ── Check for existing open PR on this branch ────────────────────────────────
    local existing_pr_number
    existing_pr_number="$(gh pr list --head "$target_branch" --state open --json number --jq '.[0].number' 2>/dev/null || echo "")"

    local gh_output pr_url pr_number
    if [[ -n "$existing_pr_number" ]]; then
        # PR already exists: update it instead of creating
        if ! gh_output="$(gh pr edit "$existing_pr_number" --title "$pr_title" --body "$pr_body" 2>&1)"; then
            error "pr_open: gh pr edit failed: $gh_output"
            stage_summary_write "$artifacts_dir/pr-open-summary.md" "pr-open" "error" \
                "could not update the existing PR" \
                "The PR exists but its body or title is not current."
            emit_event "plugin.result" "verdict=error" "plugin=pr-open" \
                "reason=gh_pr_edit_failed"
            jq -n \
                --arg reason "$gh_output" \
                --argjson draft "${_draft_bool}" \
                '{"schema_version":1,"status":"error","reason":$reason,"draft":$draft}' \
                > "$output_pr_result_json"
            return 2
        fi
        # Get PR URL from existing PR
        pr_url="$(gh pr view "$existing_pr_number" --json url --jq .url 2>/dev/null || echo "")"
        pr_number="$existing_pr_number"
    else
        # No existing PR: create a new one
        if ! gh_output="$(gh pr create "${_gh_args[@]}" 2>&1)"; then
            # Check if the failure was due to a race condition (PR created after list)
            if grep -qi "pull request already exists" <<< "$gh_output"; then
                # Retry detection in case PR was created between list and create
                existing_pr_number="$(gh pr list --head "$target_branch" --state open --json number --jq '.[0].number' 2>/dev/null || echo "")"
                if [[ -n "$existing_pr_number" ]]; then
                    # Re-update the PR and treat as updated
                    if ! gh_output="$(gh pr edit "$existing_pr_number" --title "$pr_title" --body "$pr_body" 2>&1)"; then
                        error "pr_open: gh pr edit (race recovery) failed: $gh_output"
                        stage_summary_write "$artifacts_dir/pr-open-summary.md" "pr-open" "error" \
                            "could not update the existing PR" \
                            "The PR exists but its body or title is not current."
                        emit_event "plugin.result" "verdict=error" "plugin=pr-open" \
                            "reason=gh_pr_edit_failed"
                        jq -n \
                            --arg reason "$gh_output" \
                            --argjson draft "${_draft_bool}" \
                            '{"schema_version":1,"status":"error","reason":$reason,"draft":$draft}' \
                            > "$output_pr_result_json"
                        return 2
                    fi
                    pr_url="$(gh pr view "$existing_pr_number" --json url --jq .url 2>/dev/null || echo "")"
                    pr_number="$existing_pr_number"
                else
                    error "pr_open: gh pr create failed and race recovery found no PR: $gh_output"
                    stage_summary_write "$artifacts_dir/pr-open-summary.md" "pr-open" "error" \
                        "could not create the PR" \
                        "No PR was opened."
                    emit_event "plugin.result" "verdict=error" "plugin=pr-open" \
                        "reason=gh_pr_create_failed"
                    jq -n \
                        --arg reason "$gh_output" \
                        --argjson draft "${_draft_bool}" \
                        '{"schema_version":1,"status":"error","reason":$reason,"draft":$draft}' \
                        > "$output_pr_result_json"
                    return 2
                fi
            else
                error "pr_open: gh pr create failed: $gh_output"
                stage_summary_write "$artifacts_dir/pr-open-summary.md" "pr-open" "error" \
                    "could not create the PR" \
                    "No PR was opened."
                emit_event "plugin.result" "verdict=error" "plugin=pr-open" \
                    "reason=gh_pr_create_failed"
                jq -n \
                    --arg reason "$gh_output" \
                    --argjson draft "${_draft_bool}" \
                    '{"schema_version":1,"status":"error","reason":$reason,"draft":$draft}' \
                    > "$output_pr_result_json"
                return 2
            fi
        else
            # New PR created successfully
            pr_url="$(printf '%s' "$gh_output" | grep -Eo 'https://github\.com/[^[:space:]]+' | tail -1 || echo "")"
            if [[ -z "$pr_url" ]]; then
                # gh sometimes outputs the URL as the entire stdout line
                pr_url="$(printf '%s' "$gh_output" | tail -1 | tr -d '[:space:]')"
            fi
            pr_number="$(printf '%s' "$pr_url" | grep -Eo '[0-9]+$' || echo "0")"
        fi
    fi

    # ── Determine PR status (opened vs updated) ───────────────────────────────
    local pr_status
    if [[ -n "$existing_pr_number" ]]; then
        pr_status="updated"
    else
        pr_status="opened"
    fi

    # ── Write pr-result.json ──────────────────────────────────────────────────
    # Write canonical pr-url.txt (ADR-013 artifact) and richer pr-result.json.
    # #507: pr-url.txt is the manifest-declared primary output — written via
    # atomic_write to satisfy the primary-output atomicity guard test.
    printf '%s\n' "$pr_url" | atomic_write "$(dirname "$output_pr_result_json")/pr-url.txt"

    jq -n \
        --argjson schema_version 1 \
        --arg status "$pr_status" \
        --arg pr_url "$pr_url" \
        --argjson pr_number "${pr_number:-0}" \
        --argjson draft "${_draft_bool}" \
        --arg branch "$target_branch" \
        --argjson issue "${issue_num:-0}" \
        '{schema_version: $schema_version, status: $status, pr_url: $pr_url,
          pr_number: $pr_number, draft: $draft, branch: $branch, issue: $issue}' \
        > "$output_pr_result_json"

    stage_summary_write "$artifacts_dir/pr-open-summary.md" "pr-open" "pass" \
        "opened PR ${pr_number}" \
        "$(printf -- '- pr: %s' "${pr_url}")"
    emit_event "plugin.result" "plugin=pr-open" \
        "stage=pr" "pr_url=${pr_url}" "pr_number=${pr_number}" "action=${pr_status}"
    return 0
}

# ─── pr_open_cleanup ─────────────────────────────────────────────────────────
