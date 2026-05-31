#!/usr/bin/env bash
# Surfaces deferred-work mentions in merged PR bodies. See ADR-020 / issue #531.
# Modes: --report (read-only) | --apply (create/append triage issue + log).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=lib/gh-automation.sh
source "$REPO_ROOT/scripts/lib/gh-automation.sh"

# ─── Constants (ADR-020 locked v1) ───────────────────────────────────────────
# Signal phrases — case-insensitive, word-boundary anchored. Excludes "phase \d+"
# because review found too many false positives ("phase 1 of the rollout").
SIGNAL_PHRASES=(
    "separate issue"
    "follow-up"
    "follow up"
    "deferred to"
    "out of scope"
    "not in scope"
    "file separately"
    "future issue"
    "separate PR"
    "tracked separately"
    "won't fix here"
    "left as exercise"
    "TODO(followup)"
    "stretch goal"
    "nice-to-have"
    "punt"
)

LABEL_TRIAGE="deferred-candidate"
LABEL_AUTOMATED="automated"
EXCERPT_MAX=200
PAGINATION_LIMIT=25
LOG_PATH_DEFAULT="$REPO_ROOT/.github/issues/deferred-scanned-prs.md"
DRIFT_SENTINEL="$REPO_ROOT/.deferred-drift"
# Bootstrap = first-ever run with empty log. 200 default; override via env for
# larger repos / one-off rescans (issue #540 review feedback — 30 was too small).
BOOTSTRAP_WINDOW_PRS="${DEFERRED_TRACKER_BOOTSTRAP_PRS:-200}"
# Incremental window cap when a since-anchor exists.
INCREMENTAL_FETCH_LIMIT="${DEFERRED_TRACKER_FETCH_LIMIT:-200}"

match_signal_phrases() {
    local body="$1"
    local phrase lower_body
    lower_body="$(printf '%s' "$body" | tr '[:upper:]' '[:lower:]')"
    for phrase in "${SIGNAL_PHRASES[@]}"; do
        local lower_phrase escaped_phrase
        lower_phrase="$(printf '%s' "$phrase" | tr '[:upper:]' '[:lower:]')"
        # Escape regex metacharacters in the phrase so e.g. "todo(followup)"
        # matches literally instead of being parsed as a capture group.
        escaped_phrase="$(printf '%s' "$lower_phrase" | sed 's/[][().*+?{}|^$\\]/\\&/g')"
        # Past-tense guard: skip if phrase appears only after past-tense markers
        if printf '%s' "$lower_body" | grep -qE "(already|was|has been|have been) [a-z ]*${escaped_phrase}"; then
            # Tolerate when present-tense usage also exists in same body
            local total_hits past_hits
            total_hits="$(printf '%s' "$lower_body" | grep -oE "(^|[^a-z0-9])${escaped_phrase}([^a-z0-9]|$)" | wc -l | tr -d ' ')"
            past_hits="$(printf '%s' "$lower_body" | grep -oE "(already|was|has been|have been) [a-z ]*${escaped_phrase}" | wc -l | tr -d ' ')"
            if [[ "$total_hits" -le "$past_hits" ]]; then
                continue
            fi
        fi
        # Word-boundary check
        if printf '%s' "$lower_body" | grep -qE "(^|[^a-z0-9])${escaped_phrase}([^a-z0-9]|$)"; then
            printf '%s\n' "$phrase"
        fi
    done
}

# Uses author.type field, not name-substring (spoofing-resistant per ADR-020).
is_bot_author() {
    local author_json="$1"
    local author_type
    author_type="$(printf '%s' "$author_json" | jq -r '.type // "Unknown"' 2>/dev/null)"
    case "$author_type" in
        Bot|App) return 0 ;;
        *) return 1 ;;
    esac
}

read_scanned_prs() {
    local log_path="$1"
    [[ -f "$log_path" ]] || return 0
    # Match lines like: | #123 | title | date |
    grep -oE '^\| #[0-9]+ \|' "$log_path" 2>/dev/null \
        | grep -oE '[0-9]+' \
        || true
}

# Anchors "since last run" to max(mergedAt) from log so missed runs don't
# lose PRs outside wall-clock window (ADR-020 §Time anchoring).
compute_since_anchor() {
    local log_path="$1"
    [[ -f "$log_path" ]] || { printf ''; return 0; }
    # Extract mergedAt timestamps from log; column 4 in our table format
    awk -F'|' '/^\| #[0-9]+ \|/ { gsub(/^ +| +$/, "", $4); print $4 }' "$log_path" \
        | sort -r \
        | head -n 1 \
        || printf ''
}

is_already_scanned() { gha_is_already_scanned "$@"; }

# ReDoS guard: cap input length and bound surrounding-context match to 120 chars
# each side instead of unbounded `[^.!?]*` (review finding, ADR-020 §Mitigations).
extract_excerpt() {
    local body="$1"
    local phrase="$2"
    body="${body:0:8192}"
    printf '%s' "$body" \
        | tr '\n' ' ' \
        | grep -ioE ".{0,120}${phrase}.{0,120}" \
        | head -n 1 \
        | sed 's/^ *//; s/ *$//' \
        || printf '%s' "$phrase"
}

# Escapes auto-close (#), mention (@), and code-fence (`) injection vectors.
sanitize_excerpt() {
    local text="$1"
    text="$(printf '%s' "$text" | tr '\n\r\t' '   ')"
    text="${text//\#/\\#}"
    text="${text//\@/\\@}"
    # Backtick escape blocks code-fence breakout (ADR-020 §Markdown-injection).
    text="${text//\`/\'}"
    if [[ ${#text} -gt $EXCERPT_MAX ]]; then
        text="${text:0:$EXCERPT_MAX}..."
    fi
    printf '%s' "$text"
}

format_triage_title() {
    local timestamp="$1"
    printf '[deferred-tracker][automated] Candidates — %s' "$timestamp"
}

format_issue_body() {
    local timestamp="$1"
    local run_id="${2:-local}"
    local since="${3:-bootstrap}"
    cat <<EOF
## Deferred work candidates — ${timestamp}

_Auto-generated by \`.github/workflows/deferred-tracker.yml\` · Run: ${run_id}_

Found in PRs merged since ${since}.

EOF
    while IFS='|' read -r pr_num phrase excerpt; do
        [[ -z "$pr_num" ]] && continue
        cat <<EOF
- [ ] PR #${pr_num} — \`${phrase}\`
  \`\`\`
  ${excerpt}
  \`\`\`

EOF
    done
    cat <<EOF

_To dismiss: check the box. To file: open an issue and link it here._
EOF
}

find_open_triage_issues() {
    gh issue list --label "$LABEL_TRIAGE" --state open --json number --jq '.[].number' 2>/dev/null \
        || true
}

# Detects human engagement on the triage issue (checked boxes or non-bot
# comments). Uses author.__typename rather than name-substring to stay
# spoofing-resistant per ADR-020 §Bot-author skip.
has_human_comments() {
    local issue_num="$1"
    local body comments
    body="$(gh issue view "$issue_num" --json body --jq '.body' 2>/dev/null || printf '')"
    if printf '%s' "$body" | grep -qE '^[[:space:]]*- \[x\]'; then
        return 0
    fi
    comments="$(gh issue view "$issue_num" --json comments \
        --jq '.comments[] | select((.author.__typename // "User") != "Bot") | .id' \
        2>/dev/null || printf '')"
    [[ -n "$comments" ]]
}

close_previous_triage_issue() {
    local issue_num="$1"
    gh issue close "$issue_num" \
        --comment "Superseded by new deferred-tracker run. Candidates not yet triaged carry over via the next issue." \
        >/dev/null 2>&1
}

# CRITICAL: --body-file, never --body "$var" (shell-injection mitigation).
create_triage_issue() {
    local body_file="$1"
    local title="$2"
    local url num
    url="$(gh issue create \
        --title "$title" \
        --label "$LABEL_TRIAGE" \
        --label "$LABEL_AUTOMATED" \
        --body-file "$body_file")" || return 1
    num="$(printf '%s' "$url" | grep -oE '[0-9]+$')"
    [[ -n "$num" ]] || return 1
    printf '%s\n' "$num"
}

append_to_existing_issue() {
    local issue_num="$1"
    local body_file="$2"
    gh issue comment "$issue_num" --body-file "$body_file" >/dev/null 2>&1
}

_deferred_tracker_log_header() {
    local path="$1" timestamp="$2"
    cat > "$path" <<HDR
# Deferred-tracker scanned PRs

Auto-maintained by \`scripts/deferred-tracker.sh\`. Each entry is a merged PR
that the deferred-tracker has scanned — listed whether or not a candidate was
found. Once a PR appears here, it is never re-scanned.

_Last updated: ${timestamp}_

| PR | Title | Scanned |
|---|---|---|
HDR
}

# Called ONLY after successful issue creation (ADR-020 §Idempotency rollback).
append_to_log() {
    local log_path="$1"
    shift
    local today
    today="$(date -u +%Y-%m-%d)"
    gha_append_scanned_log "$log_path" "_deferred_tracker_log_header" "$today" "$@"
}

# ─── Main flow (skipped when sourced for tests) ──────────────────────────────
main() {
    local mode="${MODE:-report}"
    local log_path="${LOG_PATH:-$LOG_PATH_DEFAULT}"
    local action="" target=""

    # Path-traversal guard: reject `..` segments in the log path.
    case "$log_path" in
        *..*) error "--log must not contain '..' segments: $log_path"; exit 2 ;;
    esac

    for bin in gh jq; do
        command -v "$bin" >/dev/null 2>&1 || { error "missing: $bin"; exit 2; }
    done

    local since search_q
    since="$(compute_since_anchor "$log_path")"
    if [[ -z "$since" ]]; then
        # Bootstrap window — last N merged PRs
        search_q="is:pr is:merged"
        info "deferred-tracker: bootstrap mode (last $BOOTSTRAP_WINDOW_PRS merged PRs)"
    else
        search_q="is:pr is:merged merged:>=$since"
        info "deferred-tracker: scanning PRs merged since $since"
    fi

    local prs_json="${RUNNER_TEMP:-/tmp}/deferred-tracker-prs.json"
    local fetch_limit="$INCREMENTAL_FETCH_LIMIT"
    [[ -z "$since" ]] && fetch_limit="$BOOTSTRAP_WINDOW_PRS"
    gh pr list --state closed --search "$search_q" \
        --limit "$fetch_limit" \
        --json number,title,body,author,mergedAt \
        > "$prs_json"

    # ─── Detection loop ──────────────────────────────────────────────────────
    local candidates=()
    local log_entries=()
    local pr_count=0
    # @tsv literalizes newlines as `\n`; iterate via jq -c per-PR JSON instead
    # so multi-line bodies survive intact (review finding).
    local pr_json
    while IFS= read -r pr_json; do
        [[ -z "$pr_json" ]] && continue
        local num title body author_json
        num="$(printf '%s' "$pr_json" | jq -r '.number // empty')"
        [[ -z "$num" ]] && continue
        title="$(printf '%s' "$pr_json" | jq -r '.title // ""')"
        body="$(printf '%s' "$pr_json" | jq -r '.body // ""')"
        author_json="$(printf '%s' "$pr_json" | jq -c '.author // {}')"
        pr_count=$((pr_count + 1))

        if is_bot_author "$author_json"; then
            continue
        fi
        if is_already_scanned "$num" "$log_path"; then
            continue
        fi

        log_entries+=("${num}|${title}")

        local matched
        matched="$(match_signal_phrases "$body")"
        [[ -z "$matched" ]] && continue
        while IFS= read -r phrase; do
            [[ -z "$phrase" ]] && continue
            local excerpt clean
            excerpt="$(extract_excerpt "$body" "$phrase")"
            clean="$(sanitize_excerpt "$excerpt")"
            candidates+=("${num}|${phrase}|${clean}")
        done <<< "$matched"
    done < <(jq -c '.[]' "$prs_json")

    info "scanned $pr_count PRs; found ${#candidates[@]} candidates"

    # ─── Report mode short-circuit ───────────────────────────────────────────
    if [[ "$mode" == "report" ]]; then
        if [[ ${#candidates[@]} -eq 0 ]]; then
            success "no candidates"
            exit 0
        fi
        printf '\n--- Candidates ---\n'
        printf '%s\n' "${candidates[@]}"
        exit 0
    fi

    # ─── No candidates → exit clean, no issue ────────────────────────────────
    if [[ ${#candidates[@]} -eq 0 ]]; then
        success "no candidates; no issue created"
        # Still record scanned PRs so we don't keep re-checking the same window
        if [[ ${#log_entries[@]} -gt 0 ]]; then
            append_to_log "$log_path" "${log_entries[@]}"
        fi
        exit 0
    fi

    # ─── Duplicate-issue guard state machine ─────────────────────────────────
    local open_issues=()
    local _issue_num
    while IFS= read -r _issue_num; do
        [[ -z "$_issue_num" ]] && continue
        open_issues+=("$_issue_num")
    done < <(find_open_triage_issues)

    case "${#open_issues[@]}" in
        0) action=create ;;
        1)
            if has_human_comments "${open_issues[0]}"; then
                action=append
                target="${open_issues[0]}"
            else
                close_previous_triage_issue "${open_issues[0]}"
                action=create
            fi
            ;;
        *)
            error "multiple open ${LABEL_TRIAGE} issues: ${open_issues[*]}"
            touch "$DRIFT_SENTINEL"
            exit 2
            ;;
    esac

    # ─── Build body ──────────────────────────────────────────────────────────
    local timestamp body_file
    timestamp="$(date -u +%Y-%m-%d\ %H:%M\ UTC)"
    body_file="${RUNNER_TEMP:-/tmp}/deferred-tracker-body.md"

    # Pagination: split if more than PAGINATION_LIMIT
    local total=${#candidates[@]}
    local parts=$(( (total + PAGINATION_LIMIT - 1) / PAGINATION_LIMIT ))
    local part=1
    local idx=0

    while (( idx < total )); do
        local part_suffix=""
        local title
        if (( parts > 1 )); then
            part_suffix=" (Part ${part}/${parts})"
        fi
        title="$(format_triage_title "$timestamp")${part_suffix}"

        local part_candidates=()
        local end=$((idx + PAGINATION_LIMIT))
        (( end > total )) && end=$total
        local i
        for ((i=idx; i<end; i++)); do
            part_candidates+=("${candidates[$i]}")
        done
        idx=$end

        printf '%s\n' "${part_candidates[@]}" | format_issue_body "$timestamp" "${GITHUB_RUN_ID:-local}" "${since:-bootstrap-window}" > "$body_file"

        if [[ "$action" == "create" || $part -gt 1 ]]; then
            create_triage_issue "$body_file" "$title" || {
                error "gh issue create failed; log NOT updated"
                exit 2
            }
        else
            append_to_existing_issue "$target" "$body_file" || {
                error "gh issue comment failed; log NOT updated"
                exit 2
            }
        fi

        part=$((part + 1))
    done

    # ─── Log AFTER successful issue creation (rollback safety) ───────────────
    if [[ ${#log_entries[@]} -gt 0 ]]; then
        append_to_log "$log_path" "${log_entries[@]}"
    fi

    success "deferred-tracker: ${#candidates[@]} candidates surfaced; ${pr_count} PRs scanned"
    exit 10
}

# ─── Arg parsing (only when not sourced) ─────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    MODE="report"
    LOG_PATH="$LOG_PATH_DEFAULT"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --report) MODE="report"; shift ;;
            --apply)  MODE="apply"; shift ;;
            --log)    LOG_PATH="$2"; shift 2 ;;
            -h|--help)
                grep '^#' "$0" | head -25
                exit 0
                ;;
            *) error "Unknown arg: $1"; exit 2 ;;
        esac
    done
    main
fi
