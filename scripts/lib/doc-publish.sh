#!/usr/bin/env bash
# scripts/lib/doc-publish.sh — DOC-F (#1420): regenerate the generated wiki pages,
# refresh the README docs pointer, and publish docs/wiki/ to the GitHub .wiki.git repo.
#
# Sourced as a lib (functions below) or run via `zbuild docs publish`. The live
# .wiki.git push runs by-hand / in the release workflow; --dry-run plus the git
# seams (ZBUILD_WIKI_GIT_CMD, ZBUILD_WIKI_REMOTE) keep it hermetically testable.
#
# Functions:
#   doc_publish_regen <repo_root>              regenerate wiki + refresh README block
#   doc_publish_update_readme <repo_root>      idempotent README generated-docs block
#   doc_publish_wiki <repo_root> <ver> <dry>   clone .wiki.git, sync, commit, push
#   doc_publish_run [flags]                     orchestrate regen + wiki publish

[[ -n "${_ZBUILD_DOC_PUBLISH_LOADED:-}" ]] && return 0
_ZBUILD_DOC_PUBLISH_LOADED=1

_DP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
source "$_DP_DIR/helpers.sh"
# shellcheck source=doc-generate.sh
source "$_DP_DIR/doc-generate.sh"

# Markers delimiting the generated docs pointer block in README (replace-in-place).
_DP_README_BEGIN='<!-- BEGIN:generated-docs -->'
_DP_README_END='<!-- END:generated-docs -->'

# Resolve the wiki remote: explicit ZBUILD_WIKI_REMOTE → derive <repo>.wiki.git from origin.
_dp_wiki_remote() {
    local repo_root="$1"
    if [[ -n "${ZBUILD_WIKI_REMOTE:-}" ]]; then
        printf '%s\n' "$ZBUILD_WIKI_REMOTE"; return 0
    fi
    local origin
    origin="$("${ZBUILD_WIKI_GIT_CMD:-git}" -C "$repo_root" remote get-url origin 2>/dev/null || true)"
    [[ -n "$origin" ]] || { error "doc-publish: cannot resolve wiki remote (set ZBUILD_WIKI_REMOTE or add an origin remote)"; return 1; }
    printf '%s\n' "${origin%.git}.wiki.git"
}

# Idempotently (re)write the README generated-docs block: replace-in-place, else append.
doc_publish_update_readme() {
    local repo_root="${1:-$PWD}"
    local readme="$repo_root/README.md"
    [[ -f "$readme" ]] || { error "doc-publish: README.md not found at $readme"; return 1; }

    local n_plugins n_mechanics
    n_plugins="$(find "$repo_root/docs/wiki/plugins" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
    n_mechanics="$(find "$repo_root/docs/wiki/mechanics" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"

    local block
    block="$(cat <<EOF
$_DP_README_BEGIN
## Documentation

Full reference documentation is published to the [project wiki](../../wiki): a page for each of the $n_plugins plugins and $n_mechanics mechanics, plus the Installation, Getting Started, Configuration, and CLI Reference guides. These pages are generated from the plugin manifests and the mechanics registry, then republished on each release.
$_DP_README_END
EOF
)"

    if grep -qF "$_DP_README_BEGIN" "$readme"; then
        # Read the replacement block from a file — a multi-line value passed via
        # `awk -v` trips BSD awk ("newline in string"); the marker vars are single-line.
        local blockfile; blockfile="$(mktemp)"
        printf '%s\n' "$block" > "$blockfile"
        local rewritten
        rewritten="$(awk -v b="$_DP_README_BEGIN" -v e="$_DP_README_END" '
            FNR==NR { repl = repl $0 ORS; next }
            $0==b { printf "%s", repl; skip=1; next }
            skip && $0==e { skip=0; next }
            !skip { print }
        ' "$blockfile" "$readme")"
        rm -f "$blockfile"
        # _dgen_atomic_write (from doc-generate.sh, sourced at top) writes
        # atomically but leaves NO README.md.bak behind — the README block is
        # regenerable, so a rotated .bak is just untracked cruft (#1492).
        printf '%s\n' "$rewritten" | _dgen_atomic_write "$readme"
    else
        printf '\n%s\n' "$block" >> "$readme"
    fi
    return 0
}

# Regenerate every wiki page (DOC-D --all) then refresh the README pointer block.
doc_publish_regen() {
    local repo_root="${1:-$PWD}"
    [[ -d "$repo_root" ]] || { error "doc-publish: repo_root not found: $repo_root"; return 1; }
    doc_generate_all \
        "$repo_root/plugins" \
        "$repo_root/config/mechanics.yaml" \
        "$repo_root/docs/wiki" \
        "$repo_root/docs/templates/doc-page.md" \
        || { error "doc-publish: doc_generate_all failed"; return 1; }
    doc_publish_update_readme "$repo_root" || return 1
    return 0
}

# Clone the wiki repo, sync docs/wiki/ (minus hash sidecars), commit, push; dry_run=true = plan only.
doc_publish_wiki() {
    local repo_root="${1:-$PWD}" version="${2:-}" dry_run="${3:-false}"
    [[ -d "$repo_root/docs/wiki" ]] || { error "doc-publish: docs/wiki not found under $repo_root"; return 1; }

    local remote; remote="$(_dp_wiki_remote "$repo_root")" || return 1
    local git="${ZBUILD_WIKI_GIT_CMD:-git}"

    if [[ "$dry_run" == "true" ]]; then
        local n; n="$(find "$repo_root/docs/wiki" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
        printf 'planned wiki: push %s page(s) from docs/wiki/ to %s\n' "$n" "$remote"
        return 0
    fi

    local work; work="$(mktemp -d)"
    # Empty wiki has no commits to clone — fall back to a fresh init pointed at the remote.
    if ! "$git" clone --depth 1 "$remote" "$work" >/dev/null 2>&1; then
        "$git" init -q "$work"
        "$git" -C "$work" remote add origin "$remote" 2>/dev/null || true
    fi

    if command -v rsync >/dev/null 2>&1; then
        rsync -a --delete --exclude '.git' --exclude '*.md.hash' "$repo_root/docs/wiki/" "$work/"
    else
        find "$work" -mindepth 1 -maxdepth 1 ! -name '.git' -exec rm -rf {} +
        cp -R "$repo_root/docs/wiki/." "$work/"
        find "$work" -name '*.md.hash' -delete
    fi

    "$git" -C "$work" add -A
    if "$git" -C "$work" diff --cached --quiet 2>/dev/null; then
        printf 'wiki: no changes to publish\n'
        rm -rf "$work"; return 0
    fi
    "$git" -C "$work" commit -q -m "docs: publish generated wiki${version:+ for $version}" \
        || { error "doc-publish: wiki commit failed"; rm -rf "$work"; return 1; }
    "$git" -C "$work" push origin HEAD >/dev/null 2>&1 \
        || { error "doc-publish: wiki push to $remote failed"; rm -rf "$work"; return 1; }
    success "doc-publish: wiki published to $remote"
    rm -rf "$work"
    return 0
}

# Orchestrate: [--dry-run] [--regen-only|--wiki-only] [--repo-root <p>] [--version <v>].
doc_publish_run() {
    local dry_run=false mode="all" repo_root="${ZBUILD_REPO_ROOT:-}" version="${ZBUILD_RELEASE_VERSION:-}"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)    dry_run=true; shift ;;
            --regen-only) mode="regen"; shift ;;
            --wiki-only)  mode="wiki"; shift ;;
            --repo-root)  repo_root="${2:-}"; shift 2 ;;
            --version)    version="${2:-}"; shift 2 ;;
            *) error "doc_publish_run: unknown argument: $1"; return 2 ;;
        esac
    done
    # Default to the CWD (the repo the operator runs in) — matching doc_generate_*'s
    # CWD-relative roots. NOT the install dir ($_DP_DIR/../..), which lacks docs/.
    [[ -n "$repo_root" ]] || repo_root="$PWD"
    repo_root="$(cd "$repo_root" && pwd)"

    if [[ "$mode" == "all" || "$mode" == "regen" ]]; then
        if [[ "$dry_run" == "true" ]]; then
            printf 'planned docs regen: doc_generate_all + README pointer refresh\n'
        else
            doc_publish_regen "$repo_root" || return 1
        fi
    fi
    if [[ "$mode" == "all" || "$mode" == "wiki" ]]; then
        doc_publish_wiki "$repo_root" "$version" "$dry_run" || return 1
    fi
    return 0
}
