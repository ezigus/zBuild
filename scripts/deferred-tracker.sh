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
    # Pipe is our candidate field separator; substituting with `/` keeps the
    # excerpt readable while preventing `IFS='|' read` from miscounting fields
    # (Codex review #573 caught this — markdown tables and "A | B"-style
    # text in PR bodies would split the excerpt across fields).
    text="${text//\|/\/}"
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
    while IFS='|' read -r pr_num phrase excerpt annotation; do
        [[ -z "$pr_num" ]] && continue
        local hint=""
        [[ -n "$annotation" ]] && hint=" ${annotation}"
        cat <<EOF
- [ ] PR #${pr_num} — \`${phrase}\`${hint}
  \`\`\`
  ${excerpt}
  \`\`\`

EOF
    done
    cat <<EOF

_To dismiss: check the box. To file: open an issue and link it here._
EOF
}

# Renders the "what / why / where from" section appended to an existing
# triage issue body (ADR-020 v2 update-in-place).
format_update_section() {
    local timestamp="$1"
    local run_id="${2:-local}"
    local since="${3:-bootstrap}"
    local count="$4"
    cat <<EOF


---

## Update — ${timestamp}

**What's added:** ${count} new candidate(s) surfaced this run.

**Why:** Recurring scan (run ${run_id}) over PRs merged since ${since}.

**Where from:**

EOF
    while IFS='|' read -r pr_num phrase excerpt annotation; do
        [[ -z "$pr_num" ]] && continue
        local hint=""
        [[ -n "$annotation" ]] && hint=" ${annotation}"
        cat <<EOF
- [ ] PR #${pr_num} — \`${phrase}\`${hint}
  \`\`\`
  ${excerpt}
  \`\`\`

EOF
    done
}

# Keeps the most recent ${UPDATE_SECTION_RETAIN:-10} update sections in
# the body file. Drops oldest first. Maintains stable header.
rotate_update_sections() {
    local body_file="$1"
    local max_keep="${UPDATE_SECTION_RETAIN:-10}"
    local count
    count="$(grep -cE '^## Update — ' "$body_file" 2>/dev/null || echo 0)"
    (( count <= max_keep )) && return 0
    local drop=$((count - max_keep))
    local tmp
    tmp="$(mktemp)"
    awk -v drop="$drop" '
        BEGIN { update_seen = 0; suppress = 0 }
        /^## Update — / {
            update_seen++
            if (update_seen <= drop) {
                suppress = 1
                next
            }
            suppress = 0
        }
        /^---$/ && suppress { next }
        !suppress { print }
    ' "$body_file" > "$tmp"
    mv "$tmp" "$body_file"
}

# Edits an existing triage issue body with a new update section appended.
# Uses SHA256 fingerprint race-detection: if body changed between fetch and
# edit, abort cleanly (operator may have edited in parallel).
update_existing_triage_issue() {
    local issue_num="$1"
    local section_file="$2"
    local body_before body_after sha_before sha_after composed
    body_before="$(mktemp)"
    composed="$(mktemp)"
    body_after="$(mktemp)"
    if ! gh issue view "$issue_num" --json body --jq '.body' > "$body_before" 2>/dev/null; then
        rm -f "$body_before" "$composed" "$body_after"
        return 2
    fi
    sha_before="$(shasum -a 256 "$body_before" 2>/dev/null | awk '{print $1}')"
    cat "$body_before" "$section_file" > "$composed"
    rotate_update_sections "$composed"
    # Re-fetch immediately before edit to detect human-edit race.
    if ! gh issue view "$issue_num" --json body --jq '.body' > "$body_after" 2>/dev/null; then
        rm -f "$body_before" "$composed" "$body_after"
        return 2
    fi
    sha_after="$(shasum -a 256 "$body_after" 2>/dev/null | awk '{print $1}')"
    if [[ "$sha_before" != "$sha_after" ]]; then
        warn "update_existing_triage_issue: body changed between fetch and edit; skipping"
        rm -f "$body_before" "$composed" "$body_after"
        return 3   # Distinct rc for "race detected, abort cleanly"
    fi
    if ! gh issue edit "$issue_num" --body-file "$composed" >/dev/null 2>&1; then
        rm -f "$body_before" "$composed" "$body_after"
        return 2
    fi
    rm -f "$body_before" "$composed" "$body_after"
    return 0
}

# For each candidate, scans open issues for content similarity and appends
# a "[possible dup: #N (sim 0.XX)]" annotation if any score >= the threshold.
# Borderline Jaccard scores (0.20-0.40) get LLM tiebreaker per sub-6.
annotate_candidates_with_dups() {
    local -a candidates_in=("$@")
    local annotation_threshold="${DEFERRED_SIMILARITY_THRESHOLD:-0.35}"
    local llm_lo="${DEFERRED_LLM_LOWER:-0.20}"
    local llm_hi="${DEFERRED_LLM_UPPER:-0.40}"
    local cache_dir="${RUNNER_TEMP:-/tmp}"
    local open_issues_json="${cache_dir}/deferred-tracker-open-issues.json"
    if ! gh issue list --state open --limit 200 --json number,title,body > "$open_issues_json" 2>/dev/null; then
        printf '[]' > "$open_issues_json"
    fi
    local candidate
    for candidate in "${candidates_in[@]}"; do
        local _num _phrase _excerpt
        IFS='|' read -r _num _phrase _excerpt <<< "$candidate"
        local hints=""
        local count_hints=0
        local issue_json
        while IFS= read -r issue_json; do
            [[ -z "$issue_json" ]] && continue
            local oid title body haystack score marker refined refined_score
            oid="$(printf '%s' "$issue_json" | jq -r '.number // empty')"
            [[ -z "$oid" ]] && continue
            title="$(printf '%s' "$issue_json" | jq -r '.title // ""')"
            body="$(printf '%s' "$issue_json" | jq -r '.body // ""')"
            haystack="${title} ${body}"
            score="$(gha_compute_similarity "$_excerpt" "$haystack")"
            marker=""
            if awk -v s="$score" -v lo="$llm_lo" -v hi="$llm_hi" 'BEGIN{exit !(s>=lo && s<hi)}'; then
                refined="$(gha_compute_similarity_llm "$_excerpt" "$haystack" "$score" 2>/dev/null || printf '%s|_LLM_FAILED_NETWORK' "$score")"
                refined_score="${refined%%|*}"
                marker="${refined##*|}"
                score="$refined_score"
            fi
            if awk -v s="$score" -v t="$annotation_threshold" 'BEGIN{exit !(s>=t)}'; then
                count_hints=$((count_hints + 1))
                (( count_hints > 3 )) && continue
                local llm_note=""
                if [[ "$marker" != "" && "$marker" != "_LLM_OK" ]]; then
                    llm_note=" — $(gha_llm_marker_to_annotation "$marker")"
                fi
                local printable_score
                printable_score="$(printf '%.2f' "$score")"
                if [[ -z "$hints" ]]; then
                    hints="[possible dup: #${oid} (sim ${printable_score}${llm_note})]"
                else
                    hints="${hints} [possible dup: #${oid} (sim ${printable_score}${llm_note})]"
                fi
            fi
        done < <(jq -c '.[]' "$open_issues_json" 2>/dev/null || true)
        printf '%s|%s\n' "$candidate" "$hints"
    done
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

    # ─── Annotate candidates with possible-dup hints (ADR-020 v2) ────────────
    if [[ ${#candidates[@]} -gt 0 ]]; then
        local annotated=()
        local _annot_line
        while IFS= read -r _annot_line; do
            [[ -n "$_annot_line" ]] && annotated+=("$_annot_line")
        done < <(annotate_candidates_with_dups "${candidates[@]}")
        if [[ ${#annotated[@]} -gt 0 ]]; then
            candidates=("${annotated[@]}")
        fi
    fi

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
                # Comment-append preserves checked boxes (ADR-020 v1 contract).
                action=append
                target="${open_issues[0]}"
            else
                # Edit body in place (ADR-020 v2): preserves issue # / URL / history.
                action=update
                target="${open_issues[0]}"
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

        if [[ "$action" == "update" && $part -eq 1 ]]; then
            # Build a stand-alone update section (no header, no footer) for
            # appending to the existing body.
            local section_file="${RUNNER_TEMP:-/tmp}/deferred-tracker-update-section.md"
            printf '%s\n' "${part_candidates[@]}" \
                | format_update_section "$timestamp" "${GITHUB_RUN_ID:-local}" "${since:-bootstrap-window}" "${#part_candidates[@]}" \
                > "$section_file"
            local update_rc=0
            update_existing_triage_issue "$target" "$section_file" || update_rc=$?
            if [[ "$update_rc" == "3" ]]; then
                # Race detected: skip cleanly, log NOT updated, exit 0
                warn "deferred-tracker: triage issue body changed during update; will retry next run"
                exit 0
            elif [[ "$update_rc" != "0" ]]; then
                error "gh issue edit failed; log NOT updated"
                exit 2
            fi
        else
            printf '%s\n' "${part_candidates[@]}" | format_issue_body "$timestamp" "${GITHUB_RUN_ID:-local}" "${since:-bootstrap-window}" > "$body_file"
            if [[ "$action" == "create" || $part -gt 1 ]]; then
                create_triage_issue "$body_file" "$title" || {
                    error "gh issue create failed; log NOT updated"
                    exit 2
                }
            elif [[ "$action" == "append" ]]; then
                append_to_existing_issue "$target" "$body_file" || {
                    error "gh issue comment failed; log NOT updated"
                    exit 2
                }
            fi
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
                cat <<'USAGE'
deferred-tracker — surface deferred-work mentions in merged PR bodies.

What it does:
  Scans recently merged PRs (rolling window) for ADR-020 signal phrases
  ("separate issue", "follow-up", "deferred to", "out of scope", etc.) and
  files / updates a consolidated triage GitHub issue labelled
  deferred-candidate. Each candidate gets a sanitized excerpt plus
  possible-dup hints against open issues.

When to use it:
  Runs automatically 3× daily via .github/workflows/deferred-tracker.yml.
  Manual local invocation is useful for debugging, validating credentials,
  or testing scanner changes before pushing.

Invocation styles:
  Invoke directly:    bash scripts/deferred-tracker.sh [flags]
  Invoke via zbuild:  zbuild deferred tracker [flags]

Modes:
  --report (default)   Read-only. Prints candidates to stdout; no issue
                       created, no log written.
  --apply              Creates / updates / appends the triage issue per the
                       duplicate-guard state machine; appends to scanned log
                       only on successful issue write.

Flags:
  --log <path>         Override scanned-PRs log location. Path-traversal guard
                       rejects '..' segments.
  -h, --help           Show this help.

Duplicate-issue state machine (--apply):
  0 open                    → create new
  1 open + no engagement    → EDIT existing body in place (preserves URL/history)
  1 open + comments/boxes   → append as comment (preserves checked boxes)
  2+ open                   → fail loud, touch .deferred-drift sentinel, exit 2

LLM tiebreaker (fail-open):
  Borderline Jaccard scores (0.20-0.40) route through an LLM verifier. On
  failure the original score is kept with annotation like
  "(sim 0.30 — LLM verification unavailable: ...)" — operator reads as
  "Jaccard-only, treat with caution."

Examples:
  bash scripts/deferred-tracker.sh --report
  zbuild deferred tracker --apply

See also:
  docs/adr/ADR-020-deferred-tracker.md
  scripts/deferred-backfill.sh   (one-shot historical scan)
  scripts/manifest-sync.sh       (sibling drift scanner)
  Issues: #531 (v1), #555 (v2 dup-hints), #560 (sub-2 update-in-place), #563 (fuzzy auto-write)
USAGE
                exit 0
                ;;
            *) error "Unknown arg: $1"; exit 2 ;;
        esac
    done
    main
fi
