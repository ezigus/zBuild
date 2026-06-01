#!/usr/bin/env bash
# One-shot historical scan for deferred-work mentions across the full repo
# history. Output to terminal; operator picks candidates to file via --file.
# See issue #541.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# Source deferred-tracker for the signal matcher — BASH_SOURCE guard at line 420
# prevents main() from running. Reuse the SAME phrase list so the two scanners
# stay in lockstep on what counts as a deferred-work mention.
# shellcheck source=./deferred-tracker.sh
source "$REPO_ROOT/scripts/deferred-tracker.sh"

PRESENTED_LOG_DEFAULT="$REPO_ROOT/.github/issues/deferred-backfill-presented.md"
BACKFILL_LABEL="deferred-backfill"
BULK_FILE_CAP=10

# ─── Index spec parsing: "1,3-5,7" → "1 3 4 5 7" (sorted, deduped) ──────────
parse_index_spec() {
    local spec="$1"
    [[ -n "$spec" ]] || { error "empty index spec"; return 2; }
    local parts=() out=()
    IFS=',' read -ra parts <<< "$spec"
    local p start end i
    for p in "${parts[@]}"; do
        p="${p// /}"
        case "$p" in
            "")
                error "invalid index spec: $spec"; return 2 ;;
            *-*)
                start="${p%-*}"; end="${p#*-}"
                [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ ]] || {
                    error "invalid range '$p' in '$spec'"; return 2
                }
                (( start > end )) && { error "reverse range '$p'"; return 2; }
                for ((i=start; i<=end; i++)); do out+=("$i"); done ;;
            *)
                [[ "$p" =~ ^[0-9]+$ ]] || { error "invalid index '$p'"; return 2; }
                out+=("$p") ;;
        esac
    done
    printf '%s\n' "${out[@]}" | sort -nu | tr '\n' ' ' | sed 's/ $//'
}

# Annotate a candidate with possible-duplicate hints via Jaccard similarity
# on title + body (ADR-020 v2 / sub-3 of #555). Annotation only — never filters.
# Borderline scores (0.20-0.40) routed through gha_compute_similarity_llm.
# Returns up to 3 hints like "#42 (sim 0.55) #99 (sim 0.38 — LLM verification unavailable: credentials not configured)".
annotate_possible_dup() {
    local excerpt="$1"
    local issues_jsonl="$2"   # path to JSONL: each line is `{number, title, body}`
    # No-open-issues path — emit the "no match (no open issues)" signal so
    # operators see that the comparison ran (#596 D).
    if [[ ! -s "$issues_jsonl" ]]; then
        printf 'no match (no open issues)'
        return 0
    fi
    local annotation_threshold="${DEFERRED_SIMILARITY_THRESHOLD:-0.35}"
    local llm_lo="${DEFERRED_LLM_LOWER:-0.20}"
    local llm_hi="${DEFERRED_LLM_UPPER:-0.40}"
    # Collect ALL matches as "score|hint" lines; sort by score descending; take
    # top 3 (Codex review #578 caught: first-3-found is not top-3-by-score).
    local matches=""
    # Track best-seen score AND issue-counter so we can distinguish "issues
    # exist but all scored 0.00" from "no issues fetched at all" (Codex #598).
    local best_score="-1.00" best_issue=""
    local seen_issue_count=0
    local issue_json
    while IFS= read -r issue_json; do
        [[ -z "$issue_json" ]] && continue
        local oid title body haystack score marker
        oid="$(printf '%s' "$issue_json" | jq -r '.number // empty')"
        [[ -z "$oid" ]] && continue
        seen_issue_count=$((seen_issue_count + 1))
        title="$(printf '%s' "$issue_json" | jq -r '.title // ""')"
        body="$(printf '%s' "$issue_json" | jq -r '.body // ""')"
        haystack="${title} ${body}"
        score="$(gha_compute_similarity "$excerpt" "$haystack" 2>/dev/null || printf '0.00')"
        marker=""
        if awk -v s="$score" -v lo="$llm_lo" -v hi="$llm_hi" 'BEGIN{exit !(s>=lo && s<hi)}'; then
            local refined
            refined="$(gha_compute_similarity_llm "$excerpt" "$haystack" "$score" 2>/dev/null || printf '%s|_LLM_FAILED_NETWORK' "$score")"
            score="${refined%%|*}"
            marker="${refined##*|}"
        fi
        # `>=` (not `>`) so the first issue always seeds best_issue even when
        # the score is 0.00 (Codex #598 — without this, all-zero scores
        # produced a misleading "no open issues" output).
        if awk -v s="$score" -v b="$best_score" 'BEGIN{exit !(s>=b)}'; then
            best_score="$score"
            best_issue="$oid"
        fi
        if awk -v s="$score" -v t="$annotation_threshold" 'BEGIN{exit !(s>=t)}'; then
            local printable llm_note=""
            printable="$(printf '%.2f' "$score")"
            if [[ -n "$marker" && "$marker" != "_LLM_OK" ]]; then
                llm_note=" — $(gha_llm_marker_to_annotation "$marker")"
            fi
            matches+="${printable} #${oid} (sim ${printable}${llm_note})"$'\n'
        fi
    done < "$issues_jsonl"
    if [[ -n "$matches" ]]; then
        printf '%s' "$matches" | sort -t' ' -k1,1nr | head -n 3 | cut -d' ' -f2- | tr '\n' ' ' | sed 's/ *$//'
        return 0
    fi
    # "no open issues" only when the loop actually saw no issues with a
    # numeric id. Otherwise we have at least one comparison to report.
    if (( seen_issue_count == 0 )); then
        printf 'no match (no open issues)'
    else
        local pb; pb="$(printf '%.2f' "$best_score")"
        printf 'no match (best: %s vs #%s)' "$pb" "$best_issue"
    fi
}

is_in_presented_log() {
    local pr_num="$1" phrase="$2" log="$3"
    [[ -f "$log" ]] || return 1
    # Match exact PR+phrase combination — phrase may contain regex metachars
    local phrase_esc
    phrase_esc="$(printf '%s' "$phrase" | sed 's/[][().*+?{}|^$\\]/\\&/g')"
    grep -qE "^\| #${pr_num} \| ${phrase_esc} \|" "$log"
}

append_presented_log() {
    local log="$1" pr_num="$2" phrase="$3"
    local now today
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    today="$(date -u +%Y-%m-%d)"
    if [[ ! -f "$log" ]]; then
        mkdir -p "$(dirname "$log")"
        cat > "$log" <<HDR
# Deferred-backfill presented candidates

Auto-maintained by \`scripts/deferred-backfill.sh\`. Each entry is a (PR, phrase)
pair that the backfill has presented to the operator at least once. Re-runs skip
these unless \`--include-presented\` is passed.

_Last updated: ${now}_

| PR | Phrase | Presented |
|---|---|---|
HDR
    else
        zbuild_sed_inplace "s|^_Last updated:.*|_Last updated: ${now}_|" "$log"
    fi
    printf '| #%s | %s | %s |\n' "$pr_num" "$phrase" "$today" >> "$log"
}

# ─── Bulk-file with confirmation, capped at BULK_FILE_CAP ───────────────────
bulk_file_selected() {
    local indices=("$@")
    local count=${#indices[@]}
    if (( count > BULK_FILE_CAP )); then
        error "refusing to file $count issues at once (cap: $BULK_FILE_CAP)"
        error "re-run with smaller --file batches"
        return 2
    fi
    info "Will create $count issues:"
    local i
    for i in "${indices[@]}"; do
        local idx_line
        idx_line="${CANDIDATE_LINES[$((i-1))]:-}"
        [[ -z "$idx_line" ]] && { error "index $i out of range"; return 2; }
        printf '  %d. %s\n' "$i" "$(printf '%s' "$idx_line" | cut -d'|' -f2-)"
    done
    printf '\nProceed? [y/N] '
    local reply
    read -r reply
    [[ "$reply" =~ ^[Yy]$ ]] || { info "aborted"; return 0; }

    for i in "${indices[@]}"; do
        local line pr_num phrase excerpt
        line="${CANDIDATE_LINES[$((i-1))]}"
        IFS='|' read -r pr_num phrase excerpt <<< "$line"
        local body_file
        body_file="$(mktemp)"
        cat > "$body_file" <<EOF
## Source

PR #${pr_num} — deferred-work mention matched by \`${phrase}\`.

## Excerpt

\`\`\`
${excerpt}
\`\`\`

_Auto-filed via \`scripts/deferred-backfill.sh --file\` (issue #541)._
EOF
        # Title = first 80 chars of excerpt, sanitized
        local title
        title="$(printf '%s' "$excerpt" | tr -d '\n' | sed 's/  */ /g' | cut -c 1-80)"
        gh issue create \
            --title "[backfill] ${title}" \
            --label "$BACKFILL_LABEL" \
            --label "automated" \
            --body-file "$body_file" \
            > /dev/null || { error "gh issue create failed for index $i"; rm -f "$body_file"; return 2; }
        rm -f "$body_file"
        success "filed index $i"
    done
}

# ─── Main ──────────────────────────────────────────────────────────────────
main_backfill() {
    local mode="report"
    local file_spec=""
    local include_presented=0
    local presented_log="$PRESENTED_LOG_DEFAULT"
    local pr_limit=1000

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --report) mode="report"; shift ;;
            --file) mode="file"; file_spec="$2"; shift 2 ;;
            --include-presented) include_presented=1; shift ;;
            --presented-log) presented_log="$2"; shift 2 ;;
            --limit) pr_limit="$2"; shift 2 ;;
            -h|--help)
                cat <<USAGE
deferred-backfill — one-shot historical scan for deferred-work mentions.

What it does:
  Walks all merged PRs (default last 1000) and matches the ADR-020 signal-phrase
  list ("separate issue", "follow-up", "deferred to", "out of scope",
  "TODO(followup)", etc.). Prints a numbered list of candidates with sanitized
  excerpts and possible-dup hints; operator selects indices to bulk-file as
  deferred-backfill-labelled issues.

When to use it:
  Manual one-shot: backfill triage after enabling the tracker, or to sweep a
  long history window the recurring tracker won't revisit. Not scheduled in CI
  (see .github/workflows/deferred-tracker.yml for the recurring scanner).

Invocation styles:
  Invoke directly:    bash scripts/deferred-backfill.sh [flags]
  Invoke via zbuild:  zbuild deferred backfill [flags]

Modes:
  --report (default)   Scan history; print numbered candidates to stdout.
  --file <indices>     After scan, bulk-create issues for selected indices
                       (e.g. "1,3-5,7"); y/N confirmation required; capped at
                       ${BULK_FILE_CAP} per invocation.

Flags:
  --include-presented      Re-show candidates already in the presented log
                           (default: skip them).
  --presented-log <path>   Override presented-candidates log location.
  --limit <N>              Cap the merged-PR fetch (default 1000).
  -h, --help               Show this help.

LLM tiebreaker (fail-open):
  Possible-dup hints with Jaccard scores 0.20-0.40 are routed through the LLM
  verifier. On network/credential failure the annotation reads
  "(sim 0.30 — LLM verification unavailable: ...)" — Jaccard-only hint, not an
  LLM-confirmed match. Workflow continues; nothing silently fails.

Examples:
  bash scripts/deferred-backfill.sh --report --limit 500
  zbuild deferred backfill --file 1,3-5

See also:
  docs/adr/ADR-020-deferred-tracker.md
  scripts/deferred-tracker.sh   (recurring incremental scanner)
  scripts/manifest-sync.sh      (sibling drift scanner)
  Issues: #541 (this script), #555 (dup-hint v2), #561/#578 (sub-3 + Codex top-3 fix)
USAGE
                return 0 ;;
            *) error "unknown arg: $1"; return 2 ;;
        esac
    done

    for bin in gh jq; do
        command -v "$bin" >/dev/null 2>&1 || { error "missing: $bin"; return 2; }
    done

    info "fetching merged PRs (limit $pr_limit)..."
    local prs_json="${RUNNER_TEMP:-/tmp}/deferred-backfill-prs.json"
    gh pr list --state closed --search "is:pr is:merged" \
        --limit "$pr_limit" \
        --json number,title,body,author,mergedAt \
        > "$prs_json"
    local pr_count
    pr_count="$(jq 'length' "$prs_json")"
    info "fetched $pr_count merged PRs"

    info "fetching open issue titles (for dup annotation)..."
    local issues_jsonl="${RUNNER_TEMP:-/tmp}/deferred-backfill-issues.jsonl"
    # Annotation-only: if the list fails, degrade gracefully (no annotations)
    # rather than abort the whole scan. Fetches body too so similarity helper
    # can match on content, not just titles (sub-3 of #555).
    gh issue list --state open --limit 1000 --json number,title,body \
        --jq '.[] | @json' > "$issues_jsonl" 2>/dev/null \
        || { warn "open-issue fetch failed; annotations disabled"; : > "$issues_jsonl"; }

    # CANDIDATE_LINES is global so bulk_file_selected can index into it
    CANDIDATE_LINES=()
    local skipped_already_presented=0

    local pr_json num title body author_json
    while IFS= read -r pr_json; do
        [[ -z "$pr_json" ]] && continue
        num="$(printf '%s' "$pr_json" | jq -r '.number // empty')"
        [[ -z "$num" ]] && continue
        title="$(printf '%s' "$pr_json" | jq -r '.title // ""')"
        body="$(printf '%s' "$pr_json" | jq -r '.body // ""')"
        author_json="$(printf '%s' "$pr_json" | jq -c '.author // {}')"
        is_bot_author "$author_json" && continue

        local matched
        matched="$(match_signal_phrases "$body")"
        [[ -z "$matched" ]] && continue
        while IFS= read -r phrase; do
            [[ -z "$phrase" ]] && continue
            if (( include_presented == 0 )) && is_in_presented_log "$num" "$phrase" "$presented_log"; then
                skipped_already_presented=$((skipped_already_presented + 1))
                continue
            fi
            local excerpt clean
            # Same defensive pattern as annotate_possible_dup — never abort
            # the scan mid-PR on a helper non-zero exit.
            excerpt="$(extract_excerpt "$body" "$phrase" 2>/dev/null || printf '%s' "$phrase")"
            clean="$(sanitize_excerpt "$excerpt" 2>/dev/null || printf '%s' "$excerpt")"
            CANDIDATE_LINES+=("${num}|${phrase}|${clean}")
        done <<< "$matched"
    done < <(jq -c '.[]' "$prs_json")

    local total=${#CANDIDATE_LINES[@]}
    info "found $total candidates (skipped $skipped_already_presented previously presented)"

    if (( total == 0 )); then
        success "no candidates"
        return 0
    fi

    # Print numbered list. Use echo for excerpt to avoid printf's % interpretation
    # on PR-body content the operator hasn't sanitized for printf.
    echo
    echo "── Deferred-work candidates ──"
    local idx=1 line pr_num phrase excerpt dup_hint label
    for line in "${CANDIDATE_LINES[@]}"; do
        IFS='|' read -r pr_num phrase excerpt <<< "$line"
        dup_hint="$(annotate_possible_dup "$excerpt" "$issues_jsonl" 2>/dev/null || true)"
        # annotate_possible_dup now always returns a non-empty string — either
        # a top-3 match hint or a "no match (...)" signal (#596 D). Match-vs-
        # no-match is distinguished by the leading word so we render the
        # right header label.
        if [[ "$dup_hint" == "no match"* ]]; then
            label="$dup_hint"
        else
            label="possible dup: $dup_hint"
        fi
        echo "${idx}. PR #${pr_num} [${phrase}] — ${label}"
        echo "     ${excerpt}"
        echo                              # blank line between candidates (#596 A)
        idx=$((idx + 1))
    done
    echo
    echo "─────────────────────────────"
    info "use --file <indices> to bulk-create issues (e.g. --file 1,3-5)"

    if [[ "$mode" == "file" ]]; then
        local expanded
        expanded="$(parse_index_spec "$file_spec")" || return 2
        # shellcheck disable=SC2086  # intentional word splitting
        bulk_file_selected $expanded || return 2
        # Mark filed candidates as presented
        # shellcheck disable=SC2086
        for i in $expanded; do
            local cline=${CANDIDATE_LINES[$((i-1))]:-}
            [[ -z "$cline" ]] && continue
            local p ph
            IFS='|' read -r p ph _ <<< "$cline"
            append_presented_log "$presented_log" "$p" "$ph"
        done
    fi

    return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main_backfill "$@"
fi
