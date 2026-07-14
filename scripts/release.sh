#!/usr/bin/env bash
# scripts/release.sh — the single release entry point (REL-B, #874).
#
# Computes the next version via the pluggable versioning backend
# (resolve_repo_version, ADR-011 / ADR-048), generates per-issue release notes,
# prepends them to CHANGELOG.md, and stamps VERSION.
# REL-D's weekly workflow and `zbuild release` (#1355) CALL this script —
# logic lives here once, never duplicated (DRY).
#
# #1490 — the ONE release flow is branch → commit → PR → publish, split into:
#   PREPARE (default apply, no --force): bump VERSION+CHANGELOG, regenerate docs,
#     then create a release/<version> branch and COMMIT the bump on it. Never
#     mutates the caller's current branch in place; never tags or publishes.
#     release.yml's open-release-pr job opens the PR from that branch.
#   PUBLISH (--force, release.yml's post-merge publish job): build the tarball,
#     tag the merged commit, PUSH the tag to origin BEFORE `gh release create`
#     (fixes "tag exists locally but not pushed"), publish the Release, push wiki.
#
# Flags:
#   --patch              Cadence: patch release (default). Bumps D (issues-since count).
#   --minor              Cadence: minor release. Bumps B component, resets C to 0.
#   --major              Cadence: major release. Bumps A component, resets B.C to 0.
#                        Exactly one cadence flag allowed; combining two exits rc=2.
#   --dry-run            Print the planned version/tag/notes/version-stamp; mutate NOTHING.
#   --force              Bypass release gates (for testing / manual cuts).
#   --milestone <m>      Scope notes to a GitHub milestone (else closed-since-tag).
#   --skip-if-no-issues  Exit 0 with a skip notice when no issues have closed since the
#                        last release tag (D=0). Used by the scheduled workflow to avoid
#                        cutting empty releases.
#   -h, --help           Usage.
#
# NOTE: tarball build, git tag, and GitHub publish run INLINE here (REL-C #875 /
# REL-D #877 seams: ZBUILD_GIT_TAG_CMD, ZBUILD_GH_RELEASE_CMD, signing files).
# The per-phase/cadence GATE stays a REL-D hook point, and `_release_on_merge_hook`
# is a forward stub for REL-D's on-merge automation (#877/#1357).
#
# ZBUILD_GH_PR_CMD (default: gh) — seam for all `gh pr` subcommands used by
# _release_ship (pr create, pr checks, pr merge). Parallel to ZBUILD_GH_RELEASE_CMD
# and ZBUILD_GH_CMD; a single mock binary covers all three in tests.
set -euo pipefail

RELEASE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# RELEASE_SCRIPT_DIR is used ONLY to source the libs below. The TARGET repo — the
# repository being released — is the CWD/worktree, NOT the install dir. zBuild is
# target-agnostic: `zbuild release` releases whatever repo you run it in, not its
# own source tree (#1487). Honor an explicit ZBUILD_REPO_ROOT, else the enclosing
# git worktree, else $PWD; export it so sourced libs + the doc-style gate agree.
REPO_ROOT="${ZBUILD_REPO_ROOT:-}"
if [[ -z "$REPO_ROOT" ]]; then
    # git may be mocked/absent (empty output, exit 0) — guard on empty, not just rc.
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
fi
[[ -n "$REPO_ROOT" ]] || REPO_ROOT="$PWD"
export ZBUILD_REPO_ROOT="$REPO_ROOT"

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
# shellcheck source=lib/doc-publish.sh
source "$RELEASE_SCRIPT_DIR/lib/doc-publish.sh"

release_usage() {
    cat <<'EOF'
zbuild release — cut a release: compute version, generate notes, update CHANGELOG,
stamp VERSION, build the tarball, tag, and publish the GitHub release.

Usage:
  release.sh [--dry-run] [--patch|--minor|--major] [--force] [--ship] [--milestone <name>]

Flags:
  --dry-run              Print the planned version, tag, notes, and version-stamp. Mutates nothing.
  --patch                Cadence: patch release (default). Bumps D (issues-since count).
  --minor                Cadence: minor release. Bumps B component, resets C to 0.
  --major                Cadence: major release. Bumps A component, resets B.C to 0.
  --force                Bypass release gates (testing / manual cuts).
  --ship                 Full one-shot: prepare → push → PR → checks-wait → merge → publish.
                         Always gated (incompatible with --force). Requires gh auth + clean tree
                         on main. ZBUILD_SHIP_CHECKS_TIMEOUT controls the checks-wait bound (default 1800s).
  --milestone <name>     Scope the notes to a GitHub milestone (default: closed-since-tag).
  --skip-if-no-issues    Exit 0 (skip) when no issues closed since last release (D=0).
  -h, --help             Show this help.

Versioning is plug-and-play: the shipped A.B.C.D (initiative-count) scheme is one
example — swap in a versioning-backend plugin to version this repo any way you like
(ADR-011 / ADR-048). See `docs/adr/ADR-048-release-versioning-signing.md`.
EOF
}

# _release_on_merge_hook <tag> — forward stub for REL-D's on-merge automation
# (#877/#1357). Tarball build, git tag, and publish now run inline in main();
# this remains a clean hook point for post-release steps (announce, close
# milestone, bump next cadence) that a future PR-merge workflow will wire in.
_release_on_merge_hook() {
    local tag="$1"
    # TODO(REL-D #877/#1357): post-release automation for ${tag}.
    :
}

main() {
    local dry_run=false force=false ship=false cadence="" milestone="" skip_if_no_issues=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)  dry_run=true; shift ;;
            --force)    force=true; shift ;;
            --ship)     ship=true; shift ;;
            --skip-if-no-issues) skip_if_no_issues=true; shift ;;
            --patch)
                [[ -n "$cadence" ]] && { error "Only one cadence flag allowed (--patch, --minor, --major)"; exit 2; }
                cadence="patch"; shift ;;
            --minor)
                [[ -n "$cadence" ]] && { error "Only one cadence flag allowed (--patch, --minor, --major)"; exit 2; }
                cadence="minor"; shift ;;
            --major)
                [[ -n "$cadence" ]] && { error "Only one cadence flag allowed (--patch, --minor, --major)"; exit 2; }
                cadence="major"; shift ;;
            --milestone)
                [[ -z "${2:-}" ]] && { error "--milestone requires a value"; release_usage; exit 2; }
                milestone="$2"; shift 2 ;;
            -h|--help)  release_usage; exit 0 ;;
            *)          error "Unknown release flag: $1"; release_usage; exit 2 ;;
        esac
    done
    if $ship && $force; then
        error "release: --ship and --force are mutually exclusive (--ship is always gated)"
        release_usage; exit 2
    fi
    cadence="${cadence:-patch}"
    export ZBUILD_VERSION_CADENCE="$cadence"

    # Operate on the target repo: the git/gh + CWD-relative ops below (tag lookup,
    # notes, the version backend's `git tag` scan) must act on the repo being
    # released, not wherever the installed script lives (#1487).
    cd "$REPO_ROOT" || { error "release: cannot cd to target repo: $REPO_ROOT"; exit 1; }

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

    # ── Skip gate: --skip-if-no-issues exits 0 when D=0 (no closed issues). ──
    # The scheduled workflow always passes this flag so empty weeks produce no
    # release instead of a zero-D version stamp. Guard NUMERICALLY: an empty or
    # non-numeric count is INDETERMINATE (e.g. a gh/network failure), NOT zero —
    # treating it as zero would false-skip a real release, and a bare `-eq` on a
    # non-integer would crash. Only a clean integer 0 triggers the skip; anything
    # unparseable fails loud so the scheduled run surfaces the problem.
    if $skip_if_no_issues; then
        if [[ ! "$issues_since" =~ ^[0-9]+$ ]]; then
            error "release: --skip-if-no-issues — indeterminate issue count ('${issues_since}'); refusing to skip or cut (check gh/network)"
            exit 1
        fi
        if (( issues_since == 0 )); then
            info "release: skip — no issues closed since last release (--skip-if-no-issues)"
            exit 0
        fi
    fi

    # ── Compute the next version via the pluggable backend (ADR-011/048). We
    #    supply D through the backend's documented env seam and the cadence via
    #    ZBUILD_VERSION_CADENCE; the backend handles the bump logic. ───────────
    local version
    version="$(ZBUILD_VERSION_ISSUES_SINCE="$issues_since" resolve_repo_version)" || {
        error "release: could not resolve version via versioning backend"
        exit 1
    }
    local tag="v${version}"

    # ── Major release preflight: milestone must exist and be fully closed. ────
    # Runs under --dry-run (it is a gate, not a mutation). --force bypasses it.
    if [[ "$cadence" == "major" ]] && ! $force; then
        _release_major_preflight "$version"
    elif [[ "$cadence" == "major" ]] && $force; then
        warn "release: major preflight BYPASSED via --force — milestone/open-issue gate not enforced for ${tag}"
    fi

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
        printf 'cadence:         %s\n' "$cadence"
        if [[ -n "$last_tag" ]]; then
            printf 'since tag:       %s\n' "$last_tag"
        else
            printf 'since tag:       (genesis — no prior tag)\n'
        fi
        printf 'milestone:       %s\n' "${milestone:-<closed-since-tag>}"
        local _dry_outdir="${ZBUILD_RELEASE_OUTDIR:-<tmpdir>}"
        printf 'planned version-stamp: VERSION ← %s\n' "$version"
        printf 'planned tarball: %s/zbuild-%s.tar.gz\n' "$_dry_outdir" "$version"
        printf 'planned tag:     git tag -a %s -m "Release %s"\n' "$tag" "$version"
        printf 'planned publish: gh release create %s <tarball> <SHA256SUMS> --title "zbuild %s" --notes <notes>\n' "$tag" "$tag"
        printf '\n----- release notes -----\n\n'
        printf '%s\n' "$notes"
        # DOC-F preview: print planned doc-regen + wiki-push without mutating anything.
        # || true: a missing ZBUILD_WIKI_REMOTE / origin is surfaced to stderr but does
        # not abort the dry-run; tests set ZBUILD_WIKI_REMOTE for hermeticity.
        printf '\n'
        doc_publish_run --dry-run --repo-root "$REPO_ROOT" || true
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

    # ── Stamp VERSION file (overridable for tests via ZBUILD_RELEASE_VERSION_FILE) ──
    #    Stamp BEFORE building the tarball so the packaged VERSION matches the cut.
    local version_file="${ZBUILD_RELEASE_VERSION_FILE:-$REPO_ROOT/VERSION}"
    printf '%s\n' "$version" > "$version_file"
    success "VERSION updated to ${version}"

    # ── SHIP: one-shot orchestration (--ship). ────────────────────────────────
    # Full prepare→push→PR→checks-wait→merge→publish sequence as a single pinned,
    # gated command. Version/tag/notes are already computed above — _release_ship
    # never recomputes them (ZBUILD_GH_PR_CMD seam covers all gh pr subcommands).
    if $ship; then
        _release_ship "$version" "$tag" "$notes" "$changelog" "$version_file"
        return 0
    fi

    # ── SPLIT: prepare (default apply) vs publish (--force). ──────────────────
    # #1490: the ONE release flow is branch → commit → PR → publish. The bump we
    # just wrote must NOT tag or publish on the default path — it lands on a
    # release branch for a PR. Only --force (release.yml's post-merge publish job,
    # running on the already-merged tree) tags the merged commit, PUSHES the tag,
    # then publishes the GitHub Release.
    if ! $force; then
        _release_prepare "$version" "$changelog" "$version_file"
    else
        _release_publish "$version" "$tag" "$notes"
    fi
}

# _release_prepare <version> <changelog_path> <version_file> — the PREPARE path
# (#1490). Regenerate docs, then create a release/<version> branch and commit the
# bump (VERSION + CHANGELOG + regenerated docs) ON THAT BRANCH — never mutating
# the caller's current branch in place, never tagging or publishing. Leaves the
# branch ready for `gh pr create` (release.yml opens the PR; the publish job runs
# on merge). Git operations go through ZBUILD_GIT_CMD (default git) so tests mock
# them; ZBUILD_RELEASE_NO_PUSH=1 skips the branch/commit for changelog-only tests.
_release_prepare() {
    local version="$1" changelog="$2" version_file="$3"
    local tag="v${version}"

    # ── DOC REGEN: regenerate wiki pages so they ride the release PR. ─────────
    # Runs on the prepare path so the regenerated docs are committed on the
    # release branch alongside VERSION+CHANGELOG.
    if [[ -n "${ZBUILD_DOC_PUBLISH_CMD:-}" ]]; then
        "$ZBUILD_DOC_PUBLISH_CMD" regen "$REPO_ROOT" || { error "release: doc_publish_regen failed"; exit 1; }
    else
        doc_publish_regen "$REPO_ROOT" || { error "release: doc_publish_regen failed"; exit 1; }
    fi

    # ZBUILD_RELEASE_NO_PUSH: changelog/version-only tests bump the files but do
    # not want the branch/commit machinery. NO_GITHUB without a ZBUILD_GIT_CMD
    # seam likewise skips real git in minimal test contexts.
    if [[ "${ZBUILD_RELEASE_NO_PUSH:-}" == "1" ]]; then
        info "release: ZBUILD_RELEASE_NO_PUSH=1 — bump written, skipping release-branch commit"
        return 0
    fi
    if [[ "${NO_GITHUB:-}" == "true" && -z "${ZBUILD_GIT_CMD:-}" ]]; then
        info "release: NO_GITHUB=true (no ZBUILD_GIT_CMD) — bump written, skipping release-branch commit"
        return 0
    fi

    local git_cmd="${ZBUILD_GIT_CMD:-git}"
    # Branch name: release/<version> by default; overridable for a date-stamped
    # release/auto-YYYYMMDD name via ZBUILD_RELEASE_BRANCH.
    local branch="${ZBUILD_RELEASE_BRANCH:-release/${version}}"

    $git_cmd checkout -b "$branch" || {
        error "release: could not create release branch $branch"
        exit 1
    }
    # Stage ONLY the release artifacts (VERSION + CHANGELOG + regenerated docs) —
    # never a blanket `git add -A`, which could sweep in unrelated worktree state.
    $git_cmd add "$version_file" "$changelog" || true
    # Regenerated docs (may not exist in minimal test contexts — best-effort add).
    $git_cmd add "$REPO_ROOT/docs/wiki" "$REPO_ROOT/README.md" 2>/dev/null || true
    $git_cmd commit -m "chore: release ${tag} — bump VERSION + CHANGELOG + regenerated docs" || {
        error "release: could not commit release bump on $branch"
        exit 1
    }
    success "release: bump committed on branch $branch (ready for PR)"
    if declare -F emit_event >/dev/null 2>&1; then
        emit_event "release.prepared" "tag=$tag" "version=$version" "branch=$branch" || true
    fi
}

# _release_publish <version> <tag> <notes> — the PUBLISH path (--force, #1490).
# Runs post-merge on the already-merged tree (release.yml publish job). Builds the
# tarball, creates the annotated tag on the CURRENT (merged) commit, PUSHES the
# tag to origin BEFORE `gh release create` (fixes the "tag exists locally but not
# pushed" failure), publishes the GitHub Release, then pushes the wiki. NO_GITHUB
# without a ZBUILD_GIT_TAG_CMD seam skips tag+publish in minimal test contexts.
_release_publish() {
    local version="$1" tag="$2" notes="$3"

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

    # ── CREATE + PUSH THE ANNOTATED GIT TAG (REL-D #877 / #1490) ──────────────
    # NO_GITHUB=true (set by setup_test_env) + no ZBUILD_GIT_TAG_CMD seam → skip
    # to prevent real git tag creation in minimal test contexts. Tests that DO
    # mock git tag set ZBUILD_GIT_TAG_CMD.
    local git_tag_cmd="${ZBUILD_GIT_TAG_CMD:-git}"
    local _skip_publish=false
    if [[ "${NO_GITHUB:-}" == "true" && -z "${ZBUILD_GIT_TAG_CMD:-}" ]]; then
        info "release: NO_GITHUB=true (no ZBUILD_GIT_TAG_CMD) — skipping git tag + publish"
        _skip_publish=true
    else
        # --force always re-tags: the merged commit is the release commit.
        if $git_tag_cmd tag -l "$tag" 2>/dev/null | grep -qF "$tag"; then
            info "release: tag $tag already exists — --force set, re-tagging"
            $git_tag_cmd tag -d "$tag" 2>/dev/null || true
        fi
        $git_tag_cmd tag -a "$tag" -m "Release $version" || {
            error "release: git tag $tag failed"
            exit 1
        }
        success "git tag created: $tag"
        # #1490: PUSH THE TAG TO ORIGIN *BEFORE* `gh release create`. gh refuses
        # to create a release for a tag that exists only locally — the root-cause
        # failure this issue fixes. --force overwrites a stale remote tag.
        $git_tag_cmd push --force origin "$tag" || {
            error "release: could not push tag $tag to origin"
            exit 1
        }
        success "git tag pushed to origin: $tag"
        if declare -F emit_event >/dev/null 2>&1; then
            emit_event "release.tagged" "tag=$tag" "version=$version" || true
        fi
        # ── DOC REGEN (build-content phase): regenerate wiki pages after VERSION stamp ──
        if [[ -n "${ZBUILD_DOC_PUBLISH_CMD:-}" ]]; then
            "$ZBUILD_DOC_PUBLISH_CMD" regen "$REPO_ROOT" || { error "release: doc_publish_regen failed"; exit 1; }
        else
            doc_publish_regen "$REPO_ROOT" || { error "release: doc_publish_regen failed"; exit 1; }
        fi
    fi

    # ── PUBLISH THE GITHUB RELEASE (REL-D #877) ───────────────────────────────
    local gh_cmd="${ZBUILD_GH_RELEASE_CMD:-gh}"
    if $_skip_publish; then
        : # gate-focused test context without a gh release mock — skip publish
    else
        local sums_file="$outdir/SHA256SUMS"
        local release_exists=false
        if $gh_cmd release view "$tag" >/dev/null 2>&1; then
            release_exists=true
        fi
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
        if $release_exists; then
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
        # ── DOC WIKI (publish phase): push generated wiki pages to .wiki.git ──────
        if [[ -n "${ZBUILD_DOC_PUBLISH_CMD:-}" ]]; then
            "$ZBUILD_DOC_PUBLISH_CMD" wiki "$REPO_ROOT" "$version" || { error "release: doc_publish_wiki failed"; exit 1; }
        else
            doc_publish_wiki "$REPO_ROOT" "$version" "false" || { error "release: doc_publish_wiki failed"; exit 1; }
        fi
        if declare -F emit_event >/dev/null 2>&1; then
            emit_event "release.published" "tag=$tag" "version=$version" || true
        fi
    fi
}

# _release_ship <version> <tag> <notes> <changelog> <version_file>
# The SHIP path (--ship): one-shot prepare→push→PR→checks-wait→merge→publish.
# All locals are pinned from main() — never recomputed here. Always gated (--force
# is disallowed at arg-parse). Seams: ZBUILD_GH_PR_CMD (default: gh) for all gh pr
# subcommands; ZBUILD_GIT_CMD (default: git) for branch push + checkout/pull;
# ZBUILD_SHIP_CHECKS_TIMEOUT (default: 1800) bounds the checks-wait step.
_release_ship() {
    local version="$1" tag="$2" notes="$3" changelog="$4" version_file="$5"
    local gh_pr_cmd="${ZBUILD_GH_PR_CMD:-gh}"
    local git_cmd="${ZBUILD_GIT_CMD:-git}"
    local checks_timeout="${ZBUILD_SHIP_CHECKS_TIMEOUT:-1800}"

    # ── Preflight ─────────────────────────────────────────────────────────────
    if ! $gh_pr_cmd auth status >/dev/null 2>&1; then
        error "release --ship: gh auth check failed — run 'gh auth login' first"
        exit 1
    fi
    if ! $git_cmd diff --quiet 2>/dev/null || ! $git_cmd diff --cached --quiet 2>/dev/null; then
        error "release --ship: working tree is dirty — commit or stash changes first"
        exit 1
    fi
    local current_branch
    current_branch="$($git_cmd rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
    if [[ "$current_branch" != "main" ]]; then
        error "release --ship: HEAD is on '${current_branch}', not 'main' — switch to main first"
        exit 1
    fi

    # ── Step 1: prepare (branch + commit) ─────────────────────────────────────
    _release_prepare "$version" "$changelog" "$version_file"

    # ── Step 2: push release branch to origin ─────────────────────────────────
    local branch="${ZBUILD_RELEASE_BRANCH:-release/${version}}"
    $git_cmd push origin "$branch" || {
        error "release --ship: could not push branch $branch to origin"
        exit 1
    }
    success "release --ship: branch $branch pushed to origin"

    # ── Step 3: gh pr create ──────────────────────────────────────────────────
    $gh_pr_cmd pr create \
        --title "chore: release ${tag}" \
        --body "$notes" \
        --base main \
        --head "$branch" || {
        error "release --ship: gh pr create failed"
        exit 1
    }
    success "release --ship: PR created for ${tag}"

    # ── Step 4: checks-wait (bounded by ZBUILD_SHIP_CHECKS_TIMEOUT) ──────────
    # timeout strips the bound in the test mock; in production it kills the
    # gh process if checks don't complete within the deadline.
    if ! timeout "$checks_timeout" "$gh_pr_cmd" pr checks --watch --fail-fast; then
        error "release --ship: PR checks failed or timed out (${checks_timeout}s) — NOT merging or publishing (PR left open)"
        exit 1
    fi
    success "release --ship: PR checks passed"

    # ── Step 5: gh pr merge --squash ─────────────────────────────────────────
    $gh_pr_cmd pr merge "$branch" --squash || {
        error "release --ship: gh pr merge --squash failed"
        exit 1
    }
    success "release --ship: PR merged"

    # ── Step 6: sync to merged HEAD ──────────────────────────────────────────
    $git_cmd checkout main || {
        error "release --ship: could not switch to main after merge"
        exit 1
    }
    $git_cmd pull || {
        error "release --ship: could not pull main after merge"
        exit 1
    }
    success "release --ship: main updated to merged HEAD"

    # ── Step 7: publish (tag + push tag + gh release + wiki) ─────────────────
    _release_publish "$version" "$tag" "$notes"
}

# _release_major_preflight <version> — pre-flight checks for a major release.
# Extracts the initiative (A.B) from the post-bump version, prints the label,
# then verifies via ZBUILD_GH_CMD (default: gh) that the GitHub milestone titled
# "Initiative A.B" exists and has zero open issues. Fails rc=1 on either check.
# Runs under --dry-run (it is a gate, not a mutation). --force bypasses it.
_release_major_preflight() {
    local version="$1"
    local initiative; initiative="$(printf '%s' "$version" | cut -d. -f1,2)"
    local label="Initiative ${initiative}"
    local gh_cmd="${ZBUILD_GH_CMD:-gh}"

    info "release: major — releasing ${label}"

    local repo="${ZBUILD_RELEASE_REPO:-}"
    if [[ -z "$repo" ]]; then
        repo="$($gh_cmd repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
    fi
    if [[ -z "$repo" ]]; then
        error "release: major preflight — cannot determine repo slug; set ZBUILD_RELEASE_REPO"
        exit 1
    fi
    # Validate the slug before it reaches the API path — a value with '../' segments
    # could redirect the milestone query to an unintended endpoint.
    if [[ ! "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
        error "release: major preflight — refusing malformed repo slug '${repo}' (expected owner/name)"
        exit 1
    fi

    local api_out
    api_out="$($gh_cmd api "repos/${repo}/milestones?state=all" 2>/dev/null || true)"

    local milestone_json
    # Pass the title via --arg (never interpolate into the jq program — a title with a
    # quote/backslash would break the filter or inject jq); take the FIRST match so
    # duplicate milestones don't concatenate into an unparseable multi-object blob.
    milestone_json="$(printf '%s' "$api_out" \
        | jq -c --arg title "$label" '[.[] | select(.title == $title)][0] // empty' 2>/dev/null || true)"

    if [[ -z "$milestone_json" ]]; then
        error "release: major preflight FAILED — no GitHub milestone titled '${label}' found. Create and fully close the milestone before cutting a major release."
        exit 1
    fi

    local open_issues
    open_issues="$(printf '%s' "$milestone_json" | jq -r '.open_issues' 2>/dev/null || echo "")"

    if [[ -z "$open_issues" || ! "$open_issues" =~ ^[0-9]+$ ]]; then
        error "release: major preflight — could not read open_issues from milestone '${label}'"
        exit 1
    fi

    if (( open_issues > 0 )); then
        error "release: major preflight FAILED — milestone '${label}' has ${open_issues} open issue(s). Close all issues before cutting a major release."
        exit 1
    fi

    info "release: major preflight passed — '${label}' exists with all issues closed"
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
