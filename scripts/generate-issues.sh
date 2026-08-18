#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  zBuild issue generator                                                   ║
# ║  Reads .github/issues/keepers-manifest.yaml, creates labels + milestones  ║
# ║  + issues via gh. Idempotent: skips items that already exist by name.     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Usage:
#   scripts/generate-issues.sh [--dry-run] [--manifest <path>]
#
# Default manifest: .github/issues/keepers-manifest.yaml
#
# Prerequisites:
#   - gh CLI authenticated for ezigus/zBuild
#   - yq (https://github.com/mikefarah/yq) for YAML parsing
#   - jq for JSON munging

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"

DRY_RUN=0
UPDATE_EXISTING=0
RECONCILE_ONLY=0
MANIFEST="$REPO_ROOT/.github/issues/keepers-manifest.yaml"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --update-existing) UPDATE_EXISTING=1; shift ;;
        --reconcile)
            # Read-only: list live issues whose titles aren't in the manifest, and
            # manifest entries with state: closed whose live issue is still open.
            # Doesn't modify anything; informational diff between manifest + live.
            RECONCILE_ONLY=1; shift ;;
        --manifest) MANIFEST="$2"; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | head -30
            exit 0
            ;;
        *) error "Unknown arg: $1"; exit 2 ;;
    esac
done

if [[ ! -f "$MANIFEST" ]]; then
    error "Manifest not found: $MANIFEST"
    exit 2
fi

# ─── Prereqs ────────────────────────────────────────────────────────────────
for bin in gh yq jq; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        error "missing: $bin"
        echo "Install: brew install $bin" >&2
        exit 2
    fi
done

REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
info "target repo: $REPO"
info "manifest: $MANIFEST"
[[ "$DRY_RUN" -eq 1 ]] && warn "DRY RUN — no API calls will be made"

# ─── --reconcile: read-only diff between live + manifest ───────────────────
if [[ "$RECONCILE_ONLY" -eq 1 ]]; then
    info "reconcile mode — read-only diff"
    # Build set of manifest titles
    manifest_titles="$(yq -r '.issues[].title' "$MANIFEST" | sort)"
    # Build map of manifest title → state
    manifest_closed="$(yq -r '.issues[] | select(.state == "closed") | .title' "$MANIFEST" | sort)"
    live_open="$(gh issue list --state open --limit 500 --json title -q '.[].title' | sort)"
    live_closed="$(gh issue list --state closed --limit 500 --json title -q '.[].title' | sort)"
    live_all="$(printf '%s\n%s\n' "$live_open" "$live_closed" | sort -u)"

    echo
    info "Live issues without a manifest entry (operator-created / orphaned):"
    comm -23 <(echo "$live_all") <(echo "$manifest_titles") | sed 's/^/  - /'
    echo
    info "Manifest entries with state: closed but live issue still open (would close on --update-existing):"
    comm -12 <(echo "$manifest_closed") <(echo "$live_open") | sed 's/^/  - /'
    echo
    info "Manifest entries (state: open) whose live issue is closed (won't auto-reopen):"
    comm -12 <(echo "$manifest_titles" | comm -23 - <(echo "$manifest_closed")) <(echo "$live_closed") | sed 's/^/  - /'
    echo
    exit 0
fi

run_gh() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "  [dry-run] gh $*" >&2
        return 0
    fi
    gh "$@"
}

# ─── Labels ─────────────────────────────────────────────────────────────────
info "creating labels..."
existing_labels="$(gh label list --limit 200 --json name -q '.[].name' 2>/dev/null || true)"

label_count=$(yq '.labels | length' "$MANIFEST")
for i in $(seq 0 $((label_count - 1))); do
    name="$(yq ".labels[$i].name" "$MANIFEST")"
    color="$(yq ".labels[$i].color" "$MANIFEST")"
    desc="$(yq ".labels[$i].description" "$MANIFEST")"
    if grep -qx "$name" <<< "$existing_labels"; then
        echo "  ${DIM}skip label (exists): $name${RESET}"
    else
        run_gh label create "$name" --color "$color" --description "$desc" 2>/dev/null && \
            echo "  ${GREEN}+ label: $name${RESET}" || \
            warn "label create failed: $name"
    fi
done

# ─── Milestones ─────────────────────────────────────────────────────────────
info "creating milestones..."
existing_milestones="$(gh api "repos/$REPO/milestones?state=all" --jq '.[].title' 2>/dev/null || true)"

milestone_count=$(yq '.milestones | length' "$MANIFEST")
for i in $(seq 0 $((milestone_count - 1))); do
    title="$(yq ".milestones[$i].title" "$MANIFEST")"
    desc="$(yq ".milestones[$i].description" "$MANIFEST")"
    if grep -qFx "$title" <<< "$existing_milestones"; then
        echo "  ${DIM}skip milestone (exists): $title${RESET}"
    else
        if [[ "$DRY_RUN" -eq 1 ]]; then
            echo "  [dry-run] gh api repos/$REPO/milestones --method POST -f title=\"$title\" ..." >&2
        else
            gh api "repos/$REPO/milestones" --method POST \
                -f title="$title" \
                -f description="$desc" \
                >/dev/null 2>&1 && echo "  ${GREEN}+ milestone: $title${RESET}" || \
                warn "milestone create failed: $title"
        fi
    fi
done

# ─── Issues ─────────────────────────────────────────────────────────────────
info "creating issues..."
existing_titles="$(gh issue list --limit 500 --state all --json title -q '.[].title' 2>/dev/null || true)"

issue_count=$(yq '.issues | length' "$MANIFEST")
created=0
skipped=0

# Pre-build template body (keeper issues without explicit body)
render_keeper_body() {
    local idx="$1"
    local spec_cite legacy_cite behavior plugin_kind
    spec_cite="$(yq ".issues[$idx].spec_cite // \"\"" "$MANIFEST")"
    legacy_cite="$(yq ".issues[$idx].legacy_cite // \"\"" "$MANIFEST")"
    behavior="$(yq ".issues[$idx].behavior // \"\"" "$MANIFEST")"
    plugin_kind="$(yq ".issues[$idx].plugin_kind // \"\"" "$MANIFEST")"
    cat <<EOF
## Spec citation

$spec_cite

## Legacy citation

\`$legacy_cite\`

## Behavior (what to do)

$behavior

## Plugin kind

\`$plugin_kind\`

## 5-test trial

- [ ] New code preserves behavior (regression test against legacy citation)
- [ ] Regression test exists (path documented in PR)
- [ ] Legacy file:line citation discoverable in new tree
- [ ] Mapping-table landing in KEEPERS §H matches actual code location
- [ ] Removing the new implementation reproduces the original symptom

## Pruning step

- [ ] \`git rm\` legacy source once 5-test trial passes
- [ ] Create \`legacy/migrated/<keeper-id>.md\` tombstone
EOF
    # Optional body_suffix appended after the keeper template (for cross-refs)
    local suffix; suffix="$(yq ".issues[$idx].body_suffix // \"\"" "$MANIFEST")"
    if [[ -n "$suffix" && "$suffix" != "null" ]]; then
        echo
        echo "---"
        echo
        echo "$suffix"
    fi
}

for i in $(seq 0 $((issue_count - 1))); do
    # id is in the manifest for cross-issue references; not used by gh CLI directly
    title="$(yq ".issues[$i].title" "$MANIFEST")"
    milestone="$(yq ".issues[$i].milestone" "$MANIFEST")"
    state="$(yq ".issues[$i].state // \"open\"" "$MANIFEST")"

    # Labels: array → comma-joined
    labels_json="$(yq -o=json ".issues[$i].labels" "$MANIFEST")"
    labels_csv="$(echo "$labels_json" | jq -r 'join(",")')"

    # Body: explicit > template-rendered
    body="$(yq ".issues[$i].body // \"\"" "$MANIFEST")"
    if [[ -z "$body" || "$body" == "null" ]]; then
        body="$(render_keeper_body "$i")"
    fi

    if grep -qFx "$title" <<< "$existing_titles"; then
        if [[ "$UPDATE_EXISTING" -eq 1 ]]; then
            # Find the issue number
            issue_num="$(gh issue list --state all --limit 500 --json number,title \
                | jq -r --arg t "$title" '.[] | select(.title == $t) | .number' \
                | head -1)"
            if [[ -z "$issue_num" ]]; then
                warn "couldn't resolve issue number for: $title"
                continue
            fi

            # Check live state vs manifest state
            live_state="$(gh issue view "$issue_num" --json state -q .state 2>/dev/null | tr '[:upper:]' '[:lower:]')"
            manifest_state="$state"

            # Close if manifest says closed AND live is open (manifest is source of truth)
            if [[ "$manifest_state" == "closed" && "$live_state" == "open" ]]; then
                close_reason="$(yq ".issues[$i].closed_reason // \"Closed per manifest declaration.\"" "$MANIFEST")"
                if [[ "$DRY_RUN" -eq 1 ]]; then
                    echo "  [dry-run] gh issue close $issue_num --comment <reason>" >&2
                else
                    gh issue close "$issue_num" --comment "$close_reason" >/dev/null 2>&1 && \
                        echo "  ${YELLOW}× closed #$issue_num per manifest: $title${RESET}" || \
                        warn "close failed: #$issue_num $title"
                fi
                skipped=$((skipped + 1))
                continue
            fi

            # NOTE: We deliberately do NOT auto-reopen issues that the manifest says
            # are open but live state is closed. Operator might have closed manually
            # for a reason. --reconcile surfaces this for review.

            # Update body
            if [[ "$DRY_RUN" -eq 1 ]]; then
                echo "  [dry-run] gh issue edit $issue_num --body <new>" >&2
            else
                gh issue edit "$issue_num" --body "$body" >/dev/null 2>&1 && \
                    echo "  ${BLUE}~ updated #$issue_num: $title${RESET}" || \
                    warn "update failed: #$issue_num $title"
            fi
            skipped=$((skipped + 1))
            continue
        fi
        echo "  ${DIM}skip issue (exists): $title${RESET}"
        skipped=$((skipped + 1))
        continue
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "  [dry-run] gh issue create --title \"$title\" --label \"$labels_csv\" --milestone \"$milestone\" ($state)" >&2
        created=$((created + 1))
        continue
    fi

    # Create issue
    issue_url="$(gh issue create \
        --title "$title" \
        --body "$body" \
        --label "$labels_csv" \
        --milestone "$milestone" 2>/dev/null || echo "")"

    if [[ -z "$issue_url" ]]; then
        warn "issue create failed: $title"
        continue
    fi

    issue_num="$(echo "$issue_url" | grep -oE '[0-9]+$' || true)"
    echo "  ${GREEN}+ issue #$issue_num: $title${RESET}"
    created=$((created + 1))

    # Close if marked as closed
    if [[ "$state" == "closed" ]]; then
        gh issue close "$issue_num" >/dev/null 2>&1 || true
        echo "    ${DIM}closed (already done)${RESET}"
    fi
done

echo
info "summary"
echo "  created: $created"
echo "  skipped (already existed): $skipped"
echo "  total in manifest: $issue_count"

[[ "$DRY_RUN" -eq 1 ]] && warn "this was a dry run; no changes were made"
