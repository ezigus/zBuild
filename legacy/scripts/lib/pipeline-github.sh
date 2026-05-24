# pipeline-github.sh — GitHub API helpers for pipeline (for sw-pipeline.sh)
# Source from sw-pipeline.sh. Requires get_stage_status, get_stage_timing, get_stage_description, format_duration, now_iso from state/helpers.
[[ -n "${_PIPELINE_GITHUB_LOADED:-}" ]] && return 0
_PIPELINE_GITHUB_LOADED=1

# Defaults for variables normally set by sw-pipeline.sh (safe under set -u).
NO_GITHUB="${NO_GITHUB:-false}"
GOAL="${GOAL:-}"
PIPELINE_NAME="${PIPELINE_NAME:-pipeline}"
PIPELINE_CONFIG="${PIPELINE_CONFIG:-}"
GIT_BRANCH="${GIT_BRANCH:-}"
PIPELINE_START_EPOCH="${PIPELINE_START_EPOCH:-}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-.claude/pipeline-artifacts}"
GH_AVAILABLE="${GH_AVAILABLE:-false}"
REPO_OWNER="${REPO_OWNER:-}"
REPO_NAME="${REPO_NAME:-}"
PROGRESS_COMMENT_ID="${PROGRESS_COMMENT_ID:-}"

# ─── Markdown Escaping ───────────────────────────────────────────────
# Escape markdown special characters to prevent injection
escape_markdown() {
    local text="$1"
    # Escape ], [, (, ), *, _, \, `, #, -, +, .
    # This prevents markdown syntax injection in GitHub comments
    echo "$text" | sed 's/\([\\`*_\[\]()#+\-\.!]\)/\\\1/g'
}

gh_init() {
    if [[ "$NO_GITHUB" == "true" ]]; then
        GH_AVAILABLE=false
        return
    fi

    if ! command -v gh >/dev/null 2>&1; then
        GH_AVAILABLE=false
        warn "gh CLI not found — GitHub integration disabled"
        return
    fi

    # Check if authenticated
    if ! gh auth status >/dev/null 2>&1; then
        GH_AVAILABLE=false
        warn "gh not authenticated — GitHub integration disabled"
        return
    fi

    # Detect repo owner/name from git remote
    local remote_url
    remote_url=$(git remote get-url origin 2>/dev/null || true)
    if [[ -n "$remote_url" ]]; then
        # Handle SSH: git@github.com:owner/repo.git
        # Handle HTTPS: https://github.com/owner/repo.git
        REPO_OWNER=$(echo "$remote_url" | sed -E 's#(.*github\.com[:/])([^/]+)/.*#\2#')
        REPO_NAME=$(echo "$remote_url" | sed -E 's#.*/([^/]+)(\.git)?$#\1#' | sed 's/\.git$//')
    fi

    if [[ -n "$REPO_OWNER" && -n "$REPO_NAME" ]]; then
        GH_AVAILABLE=true
        info "GitHub: ${DIM}${REPO_OWNER}/${REPO_NAME}${RESET}"
    else
        GH_AVAILABLE=false
        warn "Could not detect GitHub repo — GitHub integration disabled"
    fi
}

# Post or update a comment on a GitHub issue
# Usage: gh_comment_issue <issue_number> <body>
gh_comment_issue() {
    [[ "$GH_AVAILABLE" != "true" ]] && return 0
    local issue_num="$1" body="$2"
    _timeout 30 gh issue comment "$issue_num" --body "$body" 2>/dev/null || true
}

# Inner-stage event poster for compound_quality / build loop observability.
# Args: $1=scope (outer|inner), $2=stage, $3=event, $4=label
# Posts to GitHub issue if LOOP_INNER_STAGE_COMMENTS=github|both and CI_MODE and ISSUE_NUMBER set.
# Always emits JSONL via emit_event regardless of comment toggle.
_emit_inner_stage_event() {
    local _scope="${1:-inner}" _stage="${2:-build}" _event="${3:-status}" _label="${4:-}"
    local _marker="SHIPWRIGHT-STAGE: ${_scope}:${_stage}:${_event}"

    # Always emit JSONL (unconditional)
    type emit_event >/dev/null 2>&1 && \
        emit_event "loop.inner_stage" "scope=${_scope}" "stage=${_stage}" "event=${_event}" "label=${_label}"

    # Post to GitHub only if configured and context available
    local _comments_cfg="${LOOP_INNER_STAGE_COMMENTS:-off}"
    if [[ "$_comments_cfg" == "github" || "$_comments_cfg" == "both" ]]; then
        if [[ -n "${CI_MODE:-}" && -n "${ISSUE_NUMBER:-}" ]]; then
            local _body="<!-- ${_marker} -->"$'\n'"**[${_scope}/${_stage}]** ${_label:-${_event}}"
            type gh_comment_issue >/dev/null 2>&1 && \
                gh_comment_issue "${ISSUE_NUMBER}" "${_body}" 2>/dev/null || true
        fi
    fi
}

# Post a progress-tracking comment and save its ID for later updates
# Usage: gh_post_progress <issue_number> <body>
gh_post_progress() {
    [[ "$GH_AVAILABLE" != "true" ]] && return 0
    local issue_num="$1" body="$2"
    local result
    result=$(_timeout 30 gh api "repos/${REPO_OWNER}/${REPO_NAME}/issues/${issue_num}/comments" \
        -f body="$body" --jq '.id' 2>/dev/null) || true
    if [[ -n "$result" && "$result" != "null" ]]; then
        PROGRESS_COMMENT_ID="$result"
        # Persist to disk so nested contexts and shell restarts can restore it.
        # M2: atomic tmp+mv write prevents concurrent readers from seeing truncated content.
        if [[ -n "${ARTIFACTS_DIR:-}" ]]; then
            mkdir -p "$ARTIFACTS_DIR" 2>/dev/null || true
            local _id_tmp
            _id_tmp=$(mktemp "${ARTIFACTS_DIR}/progress-comment.id.XXXXXX" 2>/dev/null) || _id_tmp="${ARTIFACTS_DIR}/progress-comment.id.tmp.$$"
            printf '%s\n' "$result" > "$_id_tmp" && mv "$_id_tmp" "${ARTIFACTS_DIR}/progress-comment.id" || rm -f "$_id_tmp"
        fi
    fi
}

# Update an existing progress comment by ID
# Usage: gh_update_progress <body>
gh_update_progress() {
    [[ "$GH_AVAILABLE" != "true" ]] && return 0
    # Restore from disk if env var was lost (shell restart / nested context)
    if [[ -z "${PROGRESS_COMMENT_ID:-}" && -n "${ARTIFACTS_DIR:-}" ]]; then
        local _saved_id
        _saved_id=$(cat "${ARTIFACTS_DIR}/progress-comment.id" 2>/dev/null | tr -d '[:space:]' || true)
        if [[ -n "$_saved_id" ]]; then
            PROGRESS_COMMENT_ID="$_saved_id"
            warn "heartbeat: restored PROGRESS_COMMENT_ID=${PROGRESS_COMMENT_ID} from disk" 2>/dev/null || true
        fi
    fi
    [[ -z "${PROGRESS_COMMENT_ID:-}" ]] && return 0
    local body="$1"
    _timeout 30 gh api "repos/${REPO_OWNER}/${REPO_NAME}/issues/comments/${PROGRESS_COMMENT_ID}" \
        -X PATCH -f body="$body" >/dev/null 2>&1 || true
}

# Ensure origin/<base> ref is available with enough history for merge-base.
# Handles shallow clones (.git/shallow), missing fetch, network-less local runs.
# Idempotent — fast path when ref already present and repo is not shallow.
# NOTE: --unshallow is the correct primitive; --depth=1 makes things WORSE.
_ensure_base_branch_ref() {
    local base="${1:-${BASE_BRANCH:-main}}"
    local git_dir
    git_dir="$(git rev-parse --git-dir 2>/dev/null)" || return 1
    if git rev-parse --verify --quiet "origin/${base}" >/dev/null 2>&1 \
       && [[ ! -f "${git_dir}/shallow" ]]; then
        return 0
    fi
    GIT_TERMINAL_PROMPT=0 git fetch origin "${base}" --unshallow --quiet 2>/dev/null \
        || GIT_TERMINAL_PROMPT=0 git fetch origin "${base}" --quiet 2>/dev/null \
        || true
    if git rev-parse --verify --quiet "origin/${base}" >/dev/null 2>&1; then
        type emit_event >/dev/null 2>&1 && emit_event "git.base_ref_ensured" "branch=${base}"
        return 0
    fi
    type emit_event >/dev/null 2>&1 && emit_event "git.base_ref_unavailable" "branch=${base}"
    return 1
}

# Add labels to an issue or PR
# Usage: gh_add_labels <issue_number> <label1,label2,...>
gh_add_labels() {
    [[ "$GH_AVAILABLE" != "true" ]] && return 0
    local issue_num="$1" labels="$2"
    [[ -z "$labels" ]] && return 0
    _timeout 30 gh issue edit "$issue_num" --add-label "$labels" 2>/dev/null || true
}

# Remove a label from an issue
# Usage: gh_remove_label <issue_number> <label>
gh_remove_label() {
    [[ "$GH_AVAILABLE" != "true" ]] && return 0
    local issue_num="$1" label="$2"
    _timeout 30 gh issue edit "$issue_num" --remove-label "$label" 2>/dev/null || true
}

# Self-assign an issue
# Usage: gh_assign_self <issue_number>
gh_assign_self() {
    [[ "$GH_AVAILABLE" != "true" ]] && return 0
    local issue_num="$1"
    _timeout 30 gh issue edit "$issue_num" --add-assignee "@me" 2>/dev/null || true
}

# Get full issue metadata as JSON
# Usage: gh_get_issue_meta <issue_number>
gh_get_issue_meta() {
    [[ "$GH_AVAILABLE" != "true" ]] && return 0
    local issue_num="$1"
    _timeout 30 gh issue view "$issue_num" --json title,body,labels,milestone,assignees,comments,number,state 2>/dev/null || true
}

# Build a progress table for GitHub comment
# Usage: gh_build_progress_body
gh_build_progress_body() {
    local escaped_goal
    escaped_goal=$(escape_markdown "${GOAL}")

    local body="## 🤖 Pipeline Progress — \`${PIPELINE_NAME}\`

**Delivering:** ${escaped_goal}

| Stage | Status | Duration | |
|-------|--------|----------|-|"

    local stages
    stages=$(jq -c '.stages[]' "$PIPELINE_CONFIG" 2>/dev/null)
    while IFS= read -r -u 3 stage; do
        local id enabled
        id=$(echo "$stage" | jq -r '.id')
        enabled=$(echo "$stage" | jq -r '.enabled')

        if [[ "$enabled" != "true" ]]; then
            body="${body}
| ${id} | ⏭️ skipped | — | |"
            continue
        fi

        local sstatus
        sstatus=$(get_stage_status "$id")
        local duration
        duration=$(get_stage_timing "$id")

        local icon detail_col
        case "$sstatus" in
            complete)  icon="✅"; detail_col="" ;;
            running)   icon="🔄"; detail_col=$(get_stage_description "$id") ;;
            failed)    icon="❌"; detail_col="" ;;
            *)         icon="⬜"; detail_col=$(get_stage_description "$id") ;;
        esac

        body="${body}
| ${id} | ${icon} ${sstatus:-pending} | ${duration:-—} | ${detail_col} |"
    done 3<<< "$stages"

    body="${body}

**Branch:** \`${GIT_BRANCH}\`"

    [[ -n "${GITHUB_ISSUE:-}" ]] && body="${body}
**Issue:** ${GITHUB_ISSUE}"

    local total_dur=""
    if [[ -n "$PIPELINE_START_EPOCH" ]]; then
        total_dur=$(format_duration $(( $(now_epoch) - PIPELINE_START_EPOCH )))
        body="${body}
**Elapsed:** ${total_dur}"
    fi

    # Artifacts section
    local artifacts=""
    [[ -f "$ARTIFACTS_DIR/plan.md" ]] && artifacts="${artifacts}[Plan](.claude/pipeline-artifacts/plan.md)"
    [[ -f "$ARTIFACTS_DIR/design.md" ]] && { [[ -n "$artifacts" ]] && artifacts="${artifacts} · "; artifacts="${artifacts}[Design](.claude/pipeline-artifacts/design.md)"; }
    [[ -n "${PR_NUMBER:-}" ]] && { [[ -n "$artifacts" ]] && artifacts="${artifacts} · "; artifacts="${artifacts}PR #${PR_NUMBER}"; }
    [[ -n "$artifacts" ]] && body="${body}

📎 **Artifacts:** ${artifacts}"

    body="${body}

---
_Updated: $(now_iso) · shipwright pipeline_"
    echo "$body"
}

# Push a page to the GitHub wiki
# Usage: gh_wiki_page <title> <content>
gh_wiki_page() {
    local title="$1" content="$2"
    $GH_AVAILABLE || return 0
    $NO_GITHUB && return 0
    local wiki_dir="$ARTIFACTS_DIR/wiki"
    if [[ ! -d "$wiki_dir" ]]; then
        git clone "https://github.com/${REPO_OWNER}/${REPO_NAME}.wiki.git" "$wiki_dir" 2>/dev/null || {
            info "Wiki not initialized — skipping wiki update"
            return 0
        }
    fi
    echo "$content" > "$wiki_dir/${title}.md"
    ( cd "$wiki_dir" && git add -A && git commit -m "Pipeline: update $title" && git push ) 2>/dev/null || true
}

# ─── Auto-Detection ─────────────────────────────────────────────────────────

# Detect the test command from project files
