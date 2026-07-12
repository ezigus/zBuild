#!/usr/bin/env bash
# scripts/release.sh — the single release entry point (REL-B, #874).
#
# Computes the next version via the pluggable versioning backend
# (resolve_repo_version, ADR-011 / ADR-048), generates per-issue release notes,
# and prepends them to CHANGELOG.md. REL-D's weekly workflow and `zbuild release`
# (#1355) CALL this script — logic lives here once, never duplicated (DRY).
#
# Flags:
#   --major, -x <n>   Override the major (A) component of the version.
#   --dry-run         Print the planned version/tag + notes; mutate NOTHING (idempotent).
#   --force           Bypass release gates (for testing / manual cuts).
#   --milestone <m>   Scope notes to a GitHub milestone (else closed-since-tag).
#   -h, --help        Usage.
#
# NOTE: the per-phase/cadence GATE and the actual tag/tarball/publish are REL-C
# (#875) and REL-D (#877/#1357). This script leaves clean hook points (see the
# TODO markers below); REL-B's job is notes + changelog + dry-run.
set -euo pipefail

RELEASE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$RELEASE_SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/helpers.sh
source "$RELEASE_SCRIPT_DIR/lib/helpers.sh"
# shellcheck source=lib/version.sh
source "$RELEASE_SCRIPT_DIR/lib/version.sh"
# shellcheck source=lib/release-notes.sh
source "$RELEASE_SCRIPT_DIR/lib/release-notes.sh"
# shellcheck source=lib/release-notes-coverage.sh
source "$RELEASE_SCRIPT_DIR/lib/release-notes-coverage.sh"
# shellcheck source=lib/release-tarball.sh
source "$RELEASE_SCRIPT_DIR/lib/release-tarball.sh"

release_usage() {
    cat <<'EOF'
zbuild release — cut a release: compute version, generate notes, update CHANGELOG.

Usage:
  release.sh [--dry-run] [--major N] [--force] [--milestone <name>]

Flags:
  --dry-run          Print the planned version, tag, and notes. Mutates nothing.
  --major, -x N      Override the major (A) component of the computed version.
  --force            Bypass release gates (testing / manual cuts).
  --milestone <name> Scope the notes to a GitHub milestone (default: closed-since-tag).
  -h, --help         Show this help.

Versioning is plug-and-play: the shipped A.B.C.D (initiative-count) scheme is one
example — swap in a versioning-backend plugin to version this repo any way you like
(ADR-011 / ADR-048). See `docs/adr/ADR-048-release-versioning-signing.md`.
EOF
}

main() {
    local dry_run=false force=false major_override="" milestone=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)       dry_run=true; shift ;;
            --force)         force=true; shift ;;
            --major|-x)
                [[ -z "${2:-}" ]] && { error "--major requires a value"; release_usage; exit 2; }
                case "$2" in ''|*[!0-9]*) error "--major must be a non-negative integer, got: $2"; exit 2 ;; esac
                major_override="$2"; shift 2 ;;
            --milestone)
                [[ -z "${2:-}" ]] && { error "--milestone requires a value"; release_usage; exit 2; }
                milestone="$2"; shift 2 ;;
            -h|--help)       release_usage; exit 0 ;;
            *)               error "Unknown release flag: $1"; release_usage; exit 2 ;;
        esac
    done

    # ── Anchor: the tag we generate notes "since". v1.0.0 exists → first release
    #    anchors on it; genesis fallback when the repo has no tags at all. ──────
    local last_tag; last_tag="$(release_notes_last_tag)"
    # The closed-since cutoff (ISO-8601): the anchor tag's commit date. This is a
    # real filter — issues/PRs closed/merged before it are excluded from the notes
    # AND the D count. Overridable for tests via ZBUILD_RELEASE_SINCE.
    local since=""
    if [[ -n "${ZBUILD_RELEASE_SINCE+x}" ]]; then
        since="$ZBUILD_RELEASE_SINCE"
    elif [[ -n "$last_tag" ]]; then
        since="$(git log -1 --format=%cI "$last_tag" 2>/dev/null || true)"
    fi

    # ── D (issues closed since anchor) feeds the versioning backend. ──────────
    local issues_since; issues_since="$(release_notes_issue_count "$milestone" "$since")"

    # ── Compute the next version via the pluggable backend (ADR-011/048). We
    #    supply D through the backend's documented env seam; the backend gathers
    #    A.B + C itself. --major overrides A post-hoc. ─────────────────────────
    local version
    version="$(ZBUILD_VERSION_ISSUES_SINCE="$issues_since" resolve_repo_version)" || {
        error "release: could not resolve version via versioning backend"
        exit 1
    }
    if [[ -n "$major_override" ]]; then
        # Replace the A component only; keep B.C.D from the backend.
        version="${major_override}.${version#*.}"
    fi
    local tag="v${version}"

    # ── Generate the per-issue release notes for this version. ────────────────
    local notes; notes="$(release_notes_generate "$version" "$milestone" "$since")"

    # ── DOC-REGEN + GATE STEP (REL-E #876) ────────────────────────────────────
    # Before a release is cut, docs must ship atomically and conform, and the
    # notes must cover every closed issue. This runs the doc-style gate (#1406's
    # lint-doc-style.sh — a regenerated page without a newcomer opening fails the
    # release) AND the per-issue coverage gate (an issue closed in this window
    # but absent from the notes fails the release). Both are objective, no-LLM,
    # and MUTATE NOTHING — so they run under --dry-run too (gate, don't cut).
    #
    # The actual per-leaf / per-mechanic user-doc GENERATION is delegated to
    # #1356 (docs-automation, Wishlist); REL-E provides the GATE + the wiring so
    # REL-D (#877) can regenerate + gate + land docs in the release PR. --force
    # bypasses the gate for testing / manual cuts.
    if ! $force; then
        if ! release_docs_and_coverage_gate "$milestone" "$since" "$notes"; then
            error "release: doc/coverage gate FAILED — refusing to cut the release (use --force to bypass for testing)."
            exit 1
        fi
    else
        info "release: --force set — skipping doc-style + coverage gate."
    fi

    if $dry_run; then
        info "release (dry-run) — nothing will be mutated"
        printf 'planned version: %s\n' "$version"
        printf 'planned tag:     %s\n' "$tag"
        if [[ -n "$last_tag" ]]; then
            printf 'since tag:       %s\n' "$last_tag"
        else
            printf 'since tag:       (genesis — no prior tag)\n'
        fi
        printf 'milestone:       %s\n' "${milestone:-<closed-since-tag>}"
        local _dry_outdir="${ZBUILD_RELEASE_OUTDIR:-<tmpdir>}"
        printf 'planned tarball: %s/zbuild-%s.tar.gz\n' "$_dry_outdir" "$version"
        printf 'planned tag:     git tag -a %s -m "Release %s"\n' "$tag" "$version"
        printf 'planned publish: gh release create %s <tarball> <SHA256SUMS> --title "zbuild %s" --notes <notes>\n' "$tag" "$tag"
        printf '\n----- release notes -----\n\n'
        printf '%s\n' "$notes"
        return 0
    fi

    # ── GATE HOOK (REL-C/REL-D): the doc-style + notes-coverage gate (REL-E
    #    #876) already ran above and fails closed. The per-phase/cadence release
    #    gate still lands here for REL-D.
    #    TODO(REL-D #877/#1357): consult the cadence/phase gate before mutating.
    if ! $force; then
        : # cadence/phase gate is REL-D's — REL-B/E leave this a clean hook point.
    fi

    # ── Prepend notes to CHANGELOG.md, preserving the Keep-a-Changelog header
    #    and the existing [1.0.0] section (never clobbered). Path overridable
    #    for tests via ZBUILD_RELEASE_CHANGELOG. ─────────────────────────────────
    local changelog="${ZBUILD_RELEASE_CHANGELOG:-$REPO_ROOT/CHANGELOG.md}"
    _release_prepend_changelog "$changelog" "$notes"
    success "CHANGELOG.md updated for ${version}"

    # ── BUILD THE RELEASE TARBALL (REL-C #875) ────────────────────────────────
    local outdir
    if [[ -n "${ZBUILD_RELEASE_OUTDIR:-}" ]]; then
        outdir="$ZBUILD_RELEASE_OUTDIR"
    else
        outdir="$(mktemp -d)"
    fi
    local tarball
    tarball="$(build_release_tarball "$REPO_ROOT" "$version" "$outdir")" || {
        error "release: tarball build failed"
        exit 1
    }
    success "tarball built: $tarball"

    # ── CREATE THE ANNOTATED GIT TAG (REL-D #877) ─────────────────────────────
    # Idempotency: skip re-tagging when the tag already exists and --force is not set.
    local git_tag_cmd="${ZBUILD_GIT_TAG_CMD:-git}"
    if $git_tag_cmd tag -l "$tag" 2>/dev/null | grep -qF "$tag"; then
        if $force; then
            info "release: tag $tag already exists — --force set, re-tagging"
            $git_tag_cmd tag -d "$tag" 2>/dev/null || true
        else
            info "release: tag $tag already exists — skipping re-tag (safe re-run)"
        fi
    fi
    if ! $git_tag_cmd tag -l "$tag" 2>/dev/null | grep -qF "$tag"; then
        $git_tag_cmd tag -a "$tag" -m "Release $version" || {
            error "release: git tag $tag failed"
            exit 1
        }
        success "git tag created: $tag"
    fi
    if declare -F emit_event >/dev/null 2>&1; then
        emit_event "release.tagged" "tag=$tag" "version=$version" || true
    fi

    # ── PUBLISH THE GITHUB RELEASE (REL-D #877) ───────────────────────────────
    local gh_cmd="${ZBUILD_GH_RELEASE_CMD:-gh}"
    # Idempotency: skip if the release already exists and --force is not set.
    local sums_file="$outdir/SHA256SUMS"
    local release_exists=false
    if $gh_cmd release view "$tag" >/dev/null 2>&1; then
        release_exists=true
    fi
    if $release_exists && ! $force; then
        info "release: GitHub Release $tag already exists — skipping (safe re-run)"
    else
        # Write notes to a temp file to avoid shell-quoting issues with multi-line content.
        local notes_file; notes_file="$(mktemp)"
        printf '%s\n' "$notes" > "$notes_file"
        local -a gh_args=("$tag" "$tarball" "$sums_file"
            "--title" "zbuild $tag"
            "--notes-file" "$notes_file")
        # Attach any .asc or .sig signature file from the signing backend.
        local sig_file=""
        for sig_file in "$outdir/"*.asc "$outdir/"*.sig; do
            [[ -f "$sig_file" ]] && gh_args+=("$sig_file")
        done
        if $release_exists && $force; then
            info "release: GitHub Release $tag already exists — --force set, deleting and recreating"
            $gh_cmd release delete "$tag" --yes 2>/dev/null || true
        fi
        $gh_cmd release create "${gh_args[@]}" || {
            rm -f "$notes_file"
            error "release: gh release create failed for $tag"
            exit 1
        }
        rm -f "$notes_file"
        success "GitHub Release published: $tag"
    fi
    if declare -F emit_event >/dev/null 2>&1; then
        emit_event "release.published" "tag=$tag" "version=$version" || true
    fi
}

# _release_prepend_changelog <changelog_path> <notes> — insert <notes> above the
# first "## [" release section, keeping the file header intact. Atomic write.
_release_prepend_changelog() {
    local path="$1" notes="$2"
    if [[ ! -f "$path" ]]; then
        error "release: CHANGELOG.md not found at $path"
        exit 1
    fi
    # Create the temp file in the SAME directory as the target so the final `mv`
    # is a rename within one filesystem (atomic). A temp under $TMPDIR could be a
    # different mount → mv degrades to copy+unlink, which is not atomic.
    local dir; dir="$(cd "$(dirname "$path")" && pwd)"
    local tmp; tmp="$(mktemp "${dir}/.changelog.XXXXXX")"
    local inserted=false line
    while IFS= read -r line || [[ -n "$line" ]]; do
        if ! $inserted && [[ "$line" == '## ['* ]]; then
            printf '%s\n\n' "$notes" >> "$tmp"
            inserted=true
        fi
        printf '%s\n' "$line" >> "$tmp"
    done < "$path"
    # No existing release section (unlikely — [1.0.0] ships): append at end.
    if ! $inserted; then
        printf '\n%s\n' "$notes" >> "$tmp"
    fi
    mv "$tmp" "$path"
}

main "$@"
