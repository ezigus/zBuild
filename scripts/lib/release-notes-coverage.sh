#!/usr/bin/env bash
# scripts/lib/release-notes-coverage.sh — the per-issue release-notes COVERAGE
# gate + the doc-conformance gate (REL-E, #876; sub of release EPIC #872).
#
# WHY this exists: a release ships docs + notes atomically (issue #876 DoD).
# Two mechanical, objective, no-LLM gates protect that promise and FAIL CLOSED:
#
#   1. release_notes_coverage_check — set-difference gate. Every issue CLOSED in
#      the release window (milestone, or closed-since-tag) MUST be referenced in
#      the generated notes. A missing issue means the notes silently dropped
#      shipped work; we name the gap and exit non-zero.
#
#   2. release_docs_style_check — structural doc gate. Reuses #1406's
#      scripts/lib/lint-doc-style.sh: every regenerated/updated user page must
#      open with a plain-language newcomer sentence (DOC-STYLE.md rule 1/5).
#      A page lacking one fails the release.
#
# DRY: the closed-issue enumeration reuses REL-B's _rn_fetch_issues (same gh
# seam + since_iso window as the notes generator, so the "covered" set and the
# "expected" set are computed from ONE source). The doc gate shells out to the
# existing lint-doc-style.sh rather than re-implementing the newcomer-opening
# rule. No model calls; both gates are deterministic.
#
# SCOPE (REL-E): this file is the GATE + WIRING. The actual per-leaf / per-mechanic
# user-doc GENERATION (regenerating docs/wiki/plugins/*.md, mechanics/*.md, the
# ARCHITECTURE/KEEPERS refresh, ADR index) is delegated to #1356 (docs-automation,
# Wishlist). REL-E ensures the release flow REFUSES when notes miss an issue or a
# doc page is non-conforming; it does NOT build generators.
#
# Sourced library: inherits the caller's pipefail; no `set -euo pipefail` here.

[[ -n "${_ZBUILD_RELEASE_NOTES_COVERAGE_LOADED:-}" ]] && return 0
_ZBUILD_RELEASE_NOTES_COVERAGE_LOADED=1

_ZBUILD_RELNOTES_COV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./helpers.sh
source "$_ZBUILD_RELNOTES_COV_DIR/helpers.sh"
# shellcheck source=./release-notes.sh
source "$_ZBUILD_RELNOTES_COV_DIR/release-notes.sh"

# ─── release_notes_coverage_check <milestone> <since_iso> <notes> ───────────
# The per-issue coverage gate. Enumerate the CLOSED issues in the release window
# (reusing REL-B's _rn_fetch_issues — same milestone + since_iso as the notes),
# then verify each issue number is REFERENCED in <notes> (as a GitHub issue link
# `/issues/<N>)`, exactly how release_notes_generate links each entry).
#
# Prints the missing issue numbers (one per line, `missing: #<N> — <title>`) to
# stderr and a summary. Returns:
#   0 — every closed issue in the window is covered (or the window is empty)
#   1 — at least one closed issue is absent from the notes (names each gap)
release_notes_coverage_check() {
    local milestone="$1" since="$2" notes="$3"
    local num title _labels
    local missing=0 total=0

    while IFS=$'\t' read -r num title _labels; do
        [[ -z "$num" ]] && continue
        total=$((total + 1))
        # A closed issue is "covered" iff its issue link appears in the notes.
        # release_notes_generate emits `([#N](https://…/issues/N))`, so matching
        # the `/issues/N)` suffix is exact and avoids a substring false-match
        # (e.g. #12 matching inside #123).
        if [[ "$notes" != *"/issues/${num})"* ]]; then
            printf 'coverage: missing #%s — %s\n' "$num" "$title" >&2
            missing=$((missing + 1))
        fi
    done < <(_rn_fetch_issues "$milestone" "$since")

    if [[ "$missing" -gt 0 ]]; then
        printf '\nrelease-notes-coverage: %d of %d closed issue(s) NOT referenced in the release notes. Every issue closed in this release window must appear (linked) in the notes so shipped work is never dropped silently.\n' \
            "$missing" "$total" >&2
        return 1
    fi

    printf 'release-notes-coverage: OK — all %d closed issue(s) in the release window are referenced in the notes.\n' "$total"
    return 0
}

# ─── release_docs_style_check ───────────────────────────────────────────────
# The doc-conformance gate: run #1406's lint-doc-style.sh so regenerated/updated
# user docs conform to DOC-STYLE.md (newcomer opening). A page lacking a plain-
# language opening fails the release. Reused, not re-implemented.
#
# Overridable for tests via ZBUILD_DOC_STYLE_LINT (path to an alternate checker).
# Returns the checker's exit code (0 conforming, non-zero on any violation).
release_docs_style_check() {
    local lint="${ZBUILD_DOC_STYLE_LINT:-$_ZBUILD_RELNOTES_COV_DIR/lint-doc-style.sh}"
    if [[ ! -f "$lint" ]]; then
        error "release-docs: doc-style checker not found at $lint"
        return 1
    fi
    bash "$lint"
}

# ─── release_docs_and_coverage_gate <milestone> <since_iso> <notes> ─────────
# The single seam REL-D (#877 PR mechanics) invokes and scripts/release.sh wires
# in before a release is cut. Runs BOTH gates and fails closed on either:
#   (a) doc-style conformance (release_docs_style_check), then
#   (b) per-issue coverage (release_notes_coverage_check).
#
# The doc-regen step itself (regenerating the pages) is #1356's job; this gate is
# the objective check that whatever docs land conform + the notes cover every
# issue. Mutates NOTHING — safe under --dry-run. Returns 0 only when both pass.
release_docs_and_coverage_gate() {
    local milestone="$1" since="$2" notes="$3"
    local rc=0

    info "release-gate: checking doc-style conformance (DOC-STYLE.md / #1406)…"
    if ! release_docs_style_check; then
        error "release-gate: doc-style check FAILED — a regenerated/updated page lacks a newcomer opening. Fix the page (docs/DOC-STYLE.md) before cutting the release."
        rc=1
    fi

    info "release-gate: checking per-issue notes coverage…"
    if ! release_notes_coverage_check "$milestone" "$since" "$notes"; then
        error "release-gate: notes-coverage check FAILED — an issue closed in this release window is missing from the notes."
        rc=1
    fi

    return "$rc"
}
