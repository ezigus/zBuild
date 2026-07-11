#!/usr/bin/env bash
# scripts/lib/release-notes.sh — per-issue release-notes generator (REL-B, #874).
#
# Deterministic (no LLM): gather the closed issues + merged PRs since the last
# release tag, group them (feat / fix / docs / adr / safety), link each, and
# render Keep-a-Changelog markdown. The release cutter (scripts/release.sh) uses
# these to prepend CHANGELOG.md and to supply D (issues-closed-since) to the
# versioning backend.
#
# Sourced library: inherits caller's pipefail; no set -euo pipefail here.

[[ -n "${_ZBUILD_RELEASE_NOTES_LOADED:-}" ]] && return 0
_ZBUILD_RELEASE_NOTES_LOADED=1

_ZBUILD_RELNOTES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./helpers.sh
source "$_ZBUILD_RELNOTES_DIR/helpers.sh"

# Repo slug for building GitHub links. Overridable for tests; else `gh repo view`.
_rn_repo_slug() {
    if [[ -n "${ZBUILD_RELEASE_REPO:-}" ]]; then
        printf '%s' "$ZBUILD_RELEASE_REPO"; return 0
    fi
    local slug=""
    if command -v gh >/dev/null 2>&1; then
        slug="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
        [[ -z "$slug" ]] && slug="$(gh repo view 2>/dev/null | head -1 || true)"
    fi
    printf '%s' "${slug:-ezigus/zBuild}"
}

# ─── release_notes_last_tag ─────────────────────────────────────────────────
# The tag we anchor "since last release" on. Prints the most recent release tag,
# or empty when the repo has no tags (genesis). Overridable via ZBUILD_RELEASE_LAST_TAG.
# First-release case: v1.0.0 already exists, so this returns it and we anchor there.
release_notes_last_tag() {
    # An explicitly DEFINED override wins — even when empty, which forces the
    # genesis (no-prior-tag) path. `${VAR+x}` distinguishes set-empty from unset.
    if [[ -n "${ZBUILD_RELEASE_LAST_TAG+x}" ]]; then
        printf '%s' "$ZBUILD_RELEASE_LAST_TAG"; return 0
    fi
    command -v git >/dev/null 2>&1 || { printf ''; return 0; }
    git rev-parse --git-dir >/dev/null 2>&1 || { printf ''; return 0; }
    # Newest tag by version order that looks like a release tag (vA.B.C or vA.B.C.D).
    git tag --sort=-version:refname 2>/dev/null \
        | grep -E '^v[0-9]+(\.[0-9]+){2,3}$' 2>/dev/null \
        | head -1 || true
}

# ─── _rn_classify <label_csv> <title> ───────────────────────────────────────
# Deterministic grouping. Labels win; title keywords are the fallback. Prints
# one of: safety feat fix docs adr other. "safety" is checked first so a
# security/redaction change is never mis-filed under feat.
_rn_classify() {
    local labels="$1" title="$2"
    local hay
    hay="$(printf '%s %s' "$labels" "$title" | tr '[:upper:]' '[:lower:]')"
    case "$hay" in
        *security*|*redaction*|*safety*|*vuln*)  printf 'safety' ;;
        *adr*|*architecture*)                    printf 'adr' ;;
        *docs*|*documentation*|*wiki*|*readme*)  printf 'docs' ;;
        *fix*|*bug*|*regression*|*patch*)        printf 'fix' ;;
        *feat*|*enhancement*|*add*)              printf 'feat' ;;
        *)                                       printf 'other' ;;
    esac
}

# ─── _rn_fetch_issues <milestone> <since_iso> ───────────────────────────────
# Emit TSV rows "number<TAB>title<TAB>labels_csv" for CLOSED issues. When a
# milestone is given, scope to it; else scope by closed-since date. Fully
# stubbable: the caller mocks `gh`. Never aborts pipefail on gh miss.
_rn_fetch_issues() {
    local milestone="$1" since="$2"
    command -v gh >/dev/null 2>&1 || return 0
    local json_fields="number,title,labels,closedAt"
    local jq_row='.[] | [(.number|tostring), .title, ([.labels[].name] | join(","))] | @tsv'
    local args=(issue list --state closed --limit 500 --json "$json_fields" --jq "$jq_row")
    [[ -n "$milestone" ]] && args+=(--milestone "$milestone")
    gh "${args[@]}" 2>/dev/null || true
}

# ─── _rn_fetch_prs <since_iso> ──────────────────────────────────────────────
# Emit TSV rows "number<TAB>title<TAB>labels_csv" for MERGED PRs since <since>.
_rn_fetch_prs() {
    local since="$1"
    command -v gh >/dev/null 2>&1 || return 0
    gh pr list --state merged --limit 500 \
        --json number,title,labels,mergedAt \
        --jq '.[] | [(.number|tostring), .title, ([.labels[].name] | join(","))] | @tsv' \
        2>/dev/null || true
}

# ─── release_notes_issue_count <milestone> <since_iso> ──────────────────────
# D for the versioning backend: number of closed issues since the anchor.
# Prints an integer (0 when none / gh unavailable).
release_notes_issue_count() {
    local milestone="$1" since="$2" n
    n="$(_rn_fetch_issues "$milestone" "$since" | grep -c . || true)"
    printf '%s' "${n:-0}"
}

# ─── release_notes_generate <version> <milestone> <since_iso> [date] ────────
# Render the full release-notes markdown block for <version>. Groups closed
# issues + merged PRs, links each to GitHub, and includes the plug-and-play
# versioning note (issue #874 requirement — ADR-011 / ADR-048). Deterministic.
release_notes_generate() {
    local version="$1" milestone="$2" since="$3" date="${4:-$(date -u +%Y-%m-%d)}"
    local slug; slug="$(_rn_repo_slug)"

    # Collect rows into per-group buffers. Bash 3.2-safe (no assoc arrays).
    # Buffers are mutated in-place by _rn_append_row (same-shell function call).
    local feat="" fix="" docs="" adr="" safety="" other=""
    local num title labels
    while IFS=$'\t' read -r num title labels; do
        [[ -z "$num" ]] && continue
        _rn_append_row "$num" "$title" "$labels" "$slug" "issues"
    done < <(_rn_fetch_issues "$milestone" "$since")
    while IFS=$'\t' read -r num title labels; do
        [[ -z "$num" ]] && continue
        _rn_append_row "$num" "$title" "$labels" "$slug" "pull"
    done < <(_rn_fetch_prs "$since")

    # Header.
    printf '## [%s] — %s\n\n' "$version" "$date"
    # Plug-and-play note (#874 requirement): the shipped A.B.C.D scheme is just
    # ONE example; the versioning backend is swappable (ADR-011 / ADR-048).
    printf '%s\n\n' "$(release_notes_versioning_note)"

    _rn_emit_group "Features"      "feat"   "$feat"
    _rn_emit_group "Fixes"         "fix"    "$fix"
    _rn_emit_group "Docs"          "docs"   "$docs"
    _rn_emit_group "Architecture"  "adr"    "$adr"
    _rn_emit_group "Safety"        "safety" "$safety"
    _rn_emit_group "Other"         "other"  "$other"

    printf '[%s]: https://github.com/%s/releases/tag/v%s\n' "$version" "$slug" "$version"
}

# _rn_append_row — classify one row and append a linked bullet to the right buffer.
# Mutates the caller's group buffers (feat/fix/docs/adr/safety/other) via nameref-free
# convention: it runs in the same shell as release_notes_generate.
_rn_append_row() {
    local num="$1" title="$2" labels="$3" slug="$4" kind="$5"
    local g bullet
    g="$(_rn_classify "$labels" "$title")"
    # Each entry LINKED to its issue/PR (#874: per-issue, each linked).
    bullet="$(printf -- '- %s ([#%s](https://github.com/%s/%s/%s))' "$title" "$num" "$slug" "$kind" "$num")"
    case "$g" in
        feat)   feat="${feat}${bullet}"$'\n' ;;
        fix)    fix="${fix}${bullet}"$'\n' ;;
        docs)   docs="${docs}${bullet}"$'\n' ;;
        adr)    adr="${adr}${bullet}"$'\n' ;;
        safety) safety="${safety}${bullet}"$'\n' ;;
        *)      other="${other}${bullet}"$'\n' ;;
    esac
}

# _rn_emit_group <heading> <slug> <buffer> — print a "### heading" section iff non-empty.
_rn_emit_group() {
    local heading="$1" _slug="$2" buf="$3"
    [[ -z "$buf" ]] && return 0
    printf '### %s\n\n' "$heading"
    printf '%s\n' "$buf"
}

# The plug-and-play versioning note (issue #874, per-maintainer requirement).
# Kept as a single function so release.sh + CHANGELOG header stay DRY.
release_notes_versioning_note() {
    cat <<'EOF'
> **Versioning is plug-and-play.** The `A.B.C.D` (`initiative-count`) scheme
> shown here is just one example — the versioning backend is a swappable plugin
> (ADR-011 / ADR-048). Drop in a different `versioning-backend` to version this
> repo any way you like, with zero engine changes.
EOF
}
