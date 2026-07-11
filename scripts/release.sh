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
        printf '\n----- release notes -----\n\n'
        printf '%s\n' "$notes"
        return 0
    fi

    # ── GATE HOOK (REL-C/REL-D): the per-phase/cadence release gate lands here.
    #    Until then --force is the only bypass and no gate blocks a manual cut.
    #    TODO(REL-D #877/#1357): consult the cadence/phase gate before mutating.
    if ! $force; then
        : # no gate yet — REL-B intentionally leaves this a clean hook point.
    fi

    # ── Prepend notes to CHANGELOG.md, preserving the Keep-a-Changelog header
    #    and the existing [1.0.0] section (never clobbered). Path overridable
    #    for tests via ZBUILD_RELEASE_CHANGELOG. ─────────────────────────────────
    local changelog="${ZBUILD_RELEASE_CHANGELOG:-$REPO_ROOT/CHANGELOG.md}"
    _release_prepend_changelog "$changelog" "$notes"
    success "CHANGELOG.md updated for ${version}"

    # ── TAG / TARBALL / PUBLISH HOOK (REL-C #875 / REL-D #877): not REL-B's job.
    #    TODO(REL-C): sign + build the release tarball here.
    #    TODO(REL-D): create the git tag ${tag} and publish the GitHub release.
    info "next: tag ${tag} + build/sign tarball (REL-C/REL-D) — not done by release.sh"
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
