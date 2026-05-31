#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  zBuild manifest-sync — bidirectional drift detection (issue #227)        ║
# ║                                                                           ║
# ║  Catches drift between .github/issues/keepers-manifest.yaml and live      ║
# ║  GitHub issues, caused by humans closing/opening via the UI or merging    ║
# ║  PRs that auto-close issues.                                              ║
# ║                                                                           ║
# ║  Modes:                                                                   ║
# ║    --report (default)  read-only; print drift to stdout                   ║
# ║    --apply             edit manifest.yaml in place; produces a diff       ║
# ║                        suitable for a PR (caller invokes the PR action)   ║
# ║                                                                           ║
# ║  Triggers (when used in CI; see .github/workflows/manifest-sync.yml):     ║
# ║    schedule  — full daily pass (02:00 UTC)                                ║
# ║    push:main — catches drift immediately after any merge                  ║
# ║    (pull_request.closed + issues.closed removed — caused cascade loops)   ║
# ║                                                                           ║
# ║  Safety: never auto-closes live issues, never auto-reopens. Only ever     ║
# ║  edits the local manifest YAML and lets a human review the PR.            ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=lib/gh-automation.sh
source "$REPO_ROOT/scripts/lib/gh-automation.sh"

MODE="report"
MANIFEST="$REPO_ROOT/.github/issues/keepers-manifest.yaml"
ORPHAN_PRS_LOG="$REPO_ROOT/.github/issues/orphan-prs.md"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --report) MODE="report"; shift ;;
        --apply)  MODE="apply"; shift ;;
        --manifest) MANIFEST="$2"; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | head -25
            exit 0
            ;;
        *) error "Unknown arg: $1"; exit 2 ;;
    esac
done

for bin in gh yq jq; do
    command -v "$bin" >/dev/null 2>&1 || { error "missing: $bin"; exit 2; }
done

REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
info "manifest-sync mode: $MODE | repo: $REPO | manifest: $MANIFEST"

# ─── Build the data we need from both sides ────────────────────────────────
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

yq -o=json '.issues' "$MANIFEST" \
    | jq '[.[] | {title, state: (.state // "open"), id}]' > "$TMP/manifest-entries.json"

gh issue list --state all --limit 500 --json number,title,state,closedAt,labels \
    > "$TMP/live-issues.json"

gh pr list --state closed --limit 200 --json number,title,body,closedAt,mergedAt \
    > "$TMP/live-prs.json"

# ─── Drift detection ───────────────────────────────────────────────────────
DRIFT_FOUND=0

# 1. Manifest entry says state: open, but live issue is closed
#    → propose updating manifest to state: closed
declare -a TO_MARK_CLOSED=()
while IFS=$'\t' read -r m_title m_state m_id; do
    [[ "$m_state" != "open" ]] && continue
    # If multiple live issues share a title (e.g., title-rename dupes), prefer
    # the OPEN one — it's the canonical live entry. Only mark manifest as closed
    # when ALL live issues with the title are closed.
    open_count="$(jq --arg t "$m_title" '[.[] | select(.title == $t) | select(.state | ascii_downcase == "open")] | length' "$TMP/live-issues.json")"
    if [[ "$open_count" != "0" ]]; then
        continue
    fi
    # All matching live issues are closed → safe to mark manifest closed
    live_num="$(jq -r --arg t "$m_title" '[.[] | select(.title == $t)] | sort_by(.number) | last | .number' "$TMP/live-issues.json")"
    if [[ -n "$live_num" && "$live_num" != "null" ]]; then
        TO_MARK_CLOSED+=("$m_id|$live_num|$m_title")
    fi
done < <(jq -r '.[] | [.title, .state, .id] | @tsv' "$TMP/manifest-entries.json")

if [[ ${#TO_MARK_CLOSED[@]} -gt 0 ]]; then
    DRIFT_FOUND=1
    info "Manifest entries to mark closed (live is closed; manifest says open):"
    for entry in "${TO_MARK_CLOSED[@]}"; do
        IFS='|' read -r mid lnum title <<< "$entry"
        echo "  - manifest id=$mid (issue #$lnum): $title"
    done
fi

# 2. Live issues that don't exist in the manifest
declare -a ORPHAN_ISSUES=()
while IFS=$'\t' read -r live_num live_title live_state; do
    in_manifest="$(jq -r --arg t "$live_title" '.[] | select(.title == $t) | .id' "$TMP/manifest-entries.json" | head -1)"
    if [[ -z "$in_manifest" ]]; then
        ORPHAN_ISSUES+=("$live_num|$live_state|$live_title")
    fi
done < <(jq -r '.[] | [.number, .title, .state] | @tsv' "$TMP/live-issues.json")

if [[ ${#ORPHAN_ISSUES[@]} -gt 0 ]]; then
    DRIFT_FOUND=1
    info "Live issues without manifest entries (operator-created / orphaned):"
    for entry in "${ORPHAN_ISSUES[@]}"; do
        IFS='|' read -r num state title <<< "$entry"
        echo "  - #$num ($state): $title"
    done
fi

# 3. Merged PRs without referenced issues
#    Find PRs that don't mention "Closes #" / "Fixes #" / "Resolves #"
declare -a ORPHAN_PRS=()
while IFS=$'\t' read -r pr_num pr_title pr_body; do
    if [[ -z "$pr_body" || "$pr_body" == "null" ]]; then
        pr_body=""
    fi
    if ! echo "$pr_body" | grep -qiE '(closes|fixes|resolves)[ ]+#[0-9]+'; then
        if gha_is_already_scanned "$pr_num" "$ORPHAN_PRS_LOG"; then
            continue
        fi
        ORPHAN_PRS+=("$pr_num|$pr_title")
    fi
done < <(jq -r '.[] | select(.mergedAt != null) | [.number, .title, .body] | @tsv' "$TMP/live-prs.json" | head -30)

if [[ ${#ORPHAN_PRS[@]} -gt 0 ]]; then
    DRIFT_FOUND=1
    info "Merged PRs not linked to any issue (rolling 30-PR window):"
    for entry in "${ORPHAN_PRS[@]}"; do
        IFS='|' read -r num title <<< "$entry"
        echo "  - PR #$num: $title"
    done
fi

# ─── Report mode: stop here ────────────────────────────────────────────────
if [[ "$MODE" == "report" ]]; then
    if [[ "$DRIFT_FOUND" -eq 0 ]]; then
        success "no drift detected"
        exit 0
    fi
    warn "drift detected (read-only mode; no changes made)"
    exit 0
fi

# ─── Apply mode: edit manifest + write orphan log ─────────────────────────
if [[ "$DRIFT_FOUND" -eq 0 ]]; then
    success "no drift; nothing to apply"
    exit 0
fi

CHANGES_MADE=0

# Require RUNNER_TEMP (set by GitHub Actions); fail fast for local debugging clarity.
if [[ -z "${RUNNER_TEMP:-}" ]]; then
    warn "RUNNER_TEMP is unset — writing PR body to /tmp (workflow body-path step will not find it outside CI)"
    RUNNER_TEMP="/tmp"
fi
PR_BODY_FILE="${RUNNER_TEMP}/manifest-sync-pr-body.md"

# Escape pipe characters and strip newlines in table cell content.
_escape_cell() { printf '%s' "$1" | tr -d '\n\r' | sed 's/|/\\|/g'; }

# Build PR body with actual drift details; placeholders replaced by workflow
{
    echo "Auto-detected drift between \`.github/issues/keepers-manifest.yaml\` and the live repo state."
    echo ""
    echo "**Trigger:** \`%%TRIGGER%%\`  **Run:** %%RUN_ID%%"
    echo ""

    echo "## Issues marked closed (${#TO_MARK_CLOSED[@]})"
    echo ""
    if [[ ${#TO_MARK_CLOSED[@]} -gt 0 ]]; then
        echo "| Manifest ID | Issue | Title |"
        echo "|---|---|---|"
        for entry in "${TO_MARK_CLOSED[@]}"; do
            IFS='|' read -r mid lnum title <<< "$entry"
            echo "| \`$(_escape_cell "$mid")\` | #$lnum | $(_escape_cell "$title") |"
        done
    else
        echo "None."
    fi
    echo ""

    echo "## Orphan PRs detected (${#ORPHAN_PRS[@]})"
    echo ""
    if [[ ${#ORPHAN_PRS[@]} -gt 0 ]]; then
        echo "| PR | Title |"
        echo "|---|---|"
        for entry in "${ORPHAN_PRS[@]}"; do
            IFS='|' read -r num title <<< "$entry"
            echo "| #$num | $(_escape_cell "$title") |"
        done
    else
        echo "None."
    fi
    echo ""

    echo "## Orphan issues — not auto-added (${#ORPHAN_ISSUES[@]})"
    echo ""
    if [[ ${#ORPHAN_ISSUES[@]} -gt 0 ]]; then
        echo "These live issues have no manifest entry. Human judgment required before adding."
        echo ""
        echo "| Issue | State | Title |"
        echo "|---|---|---|"
        for entry in "${ORPHAN_ISSUES[@]}"; do
            IFS='|' read -r num state title <<< "$entry"
            echo "| #$num | $state | $(_escape_cell "$title") |"
        done
    else
        echo "None."
    fi
    echo ""

    echo "## What this PR does NOT do"
    echo ""
    echo "- Does NOT auto-add live-only issues to the manifest."
    echo "- Does NOT close any live GitHub issues."
    echo "- Does NOT reopen anything."
    echo ""
    echo "Safe to merge if the changes look right."
} > "$PR_BODY_FILE"

# Apply: mark manifest entries closed where live is closed
for entry in "${TO_MARK_CLOSED[@]}"; do
    IFS='|' read -r mid lnum title <<< "$entry"
    # Use yq to find the entry by id and add state: closed
    # Idempotent: skip if already closed
    current_state="$(yq -r ".issues[] | select(.id == \"$mid\") | .state // \"open\"" "$MANIFEST")"
    if [[ "$current_state" == "closed" ]]; then
        continue
    fi
    closed_at="$(jq -r --arg t "$title" '.[] | select(.title == $t) | .closedAt' "$TMP/live-issues.json" | head -1)"
    reason="Closed via GitHub (live state: closed at $closed_at). Recorded by manifest-sync."
    yq -i "(.issues[] | select(.id == \"$mid\")).state = \"closed\"" "$MANIFEST"
    yq -i "(.issues[] | select(.id == \"$mid\")).closed_reason = \"$reason\"" "$MANIFEST"
    success "  manifest: marked id=$mid (issue #$lnum) state: closed"
    CHANGES_MADE=$((CHANGES_MADE + 1))
done

_manifest_sync_orphan_log_header() {
    local path="$1" timestamp="$2"
    cat > "$path" <<HDR
# Orphan PRs — merged without linking to an issue

Auto-maintained by \`scripts/manifest-sync.sh\`. Each entry below is a PR that
merged without referencing an issue via \`Closes #N\` / \`Fixes #N\` / \`Resolves #N\`.

_Last updated: ${timestamp}_

| PR | Title | First seen |
|---|---|---|
HDR
}

# Apply: append orphan PRs to log
if [[ ${#ORPHAN_PRS[@]} -gt 0 ]]; then
    today="$(date -u +%Y-%m-%d)"
    before_count=0
    [[ -f "$ORPHAN_PRS_LOG" ]] && before_count=$(grep -cE '^\| #[0-9]+ \|' "$ORPHAN_PRS_LOG" || true)
    gha_append_scanned_log "$ORPHAN_PRS_LOG" \
        "_manifest_sync_orphan_log_header" "$today" \
        "${ORPHAN_PRS[@]}"
    after_count=$(grep -cE '^\| #[0-9]+ \|' "$ORPHAN_PRS_LOG" || true)
    added=$((after_count - before_count))
    if (( added > 0 )); then
        success "  orphan log: appended $added PR row(s)"
        CHANGES_MADE=$((CHANGES_MADE + added))
    fi
fi

# Note: orphan ISSUES (live but not in manifest) are surfaced but NOT
# auto-added to the manifest — that requires human judgment on title,
# labels, milestone, body. Operator reviews the report output.
if [[ ${#ORPHAN_ISSUES[@]} -gt 0 ]]; then
    warn "${#ORPHAN_ISSUES[@]} orphan issues NOT auto-added to manifest (require human review)"
fi

info "summary: $CHANGES_MADE manifest/log changes applied"

# Exit non-zero in apply mode if changes were made — signals caller
# (the workflow) that a PR should be opened. Use explicit if to avoid
# set -e + && || gotcha.
if [[ "$CHANGES_MADE" -gt 0 ]]; then
    exit 10
fi
exit 0
