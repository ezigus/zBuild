#!/usr/bin/env bash
# Tests: scripts/release.sh apply paths — the #1490 branch → commit → PR → publish
# split — with mocked gh + git + ZBUILD_RELEASE_OUTDIR seams.
#
# PREPARE path (default apply, no --force, #1490):
#   SPEC-P1: bumps VERSION (sandbox) + CHANGELOG; does NOT dirty the tracked repo VERSION
#   SPEC-P2: creates a release/<version> branch and COMMITS the bump on it (git log)
#   SPEC-P3: does NOT tag and does NOT publish (git-tag log + gh log have no tag/release)
#   SPEC-P4: does NOT build a release tarball (that is the publish path's job)
#
# PUBLISH path (--force, #1490 — release.yml's post-merge publish job):
#   SPEC-1: calls build_release_tarball (tarball in ZBUILD_RELEASE_OUTDIR)
#   SPEC-2: creates the annotated git tag (via ZBUILD_GIT_TAG_CMD log)
#   SPEC-2b: PUSHES the tag to origin BEFORE `gh release create` (assert ORDER via shared log)
#   SPEC-3: invokes gh release create with tarball + SHA256SUMS + --notes-file
#
# DRY-RUN:
#   SPEC-4: --dry-run prints planned tarball/tag/publish lines; leaves logs empty
#   SPEC-6: --dry-run does not build a tarball
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "release.sh — prepare + publish split (branch → commit → PR → publish, #1490)"
setup_test_env "release-sh-apply"

# ── Shared test fixtures ──────────────────────────────────────────────────────
export ZBUILD_RELEASE_REPO="ezigus/zBuild"
export ZBUILD_VERSION_ANCHOR="1.0"
export ZBUILD_VERSION_RELEASE_COUNT="1"
export ZBUILD_RELEASE_SINCE="2026-07-04T00:00:00Z"
export ZBUILD_RELEASE_LAST_TAG="v1.0.0"

# Sandbox CHANGELOG so the apply path never touches the real repo CHANGELOG.
sandbox_changelog="$TEST_TEMP_DIR/CHANGELOG.md"
cp "$REPO_ROOT/CHANGELOG.md" "$sandbox_changelog"
export ZBUILD_RELEASE_CHANGELOG="$sandbox_changelog"

# Sandbox VERSION so the apply path never writes the tracked repo VERSION file.
export ZBUILD_RELEASE_VERSION_FILE="$TEST_TEMP_DIR/VERSION"

# Issue list: 5 in-window issues → D=5 → version 1.0.1.5, tag v1.0.1.5.
export MOCK_ISSUE_LIST_JSON="$TEST_TEMP_DIR/issues.json"
cat > "$MOCK_ISSUE_LIST_JSON" <<'EOF'
[
  {"number":101,"title":"add release notes generator","labels":[{"name":"enhancement"}],"closedAt":"2026-07-05T10:00:00Z"},
  {"number":102,"title":"fix torn-write","labels":[{"name":"bug"}],"closedAt":"2026-07-06T10:00:00Z"},
  {"number":103,"title":"update wiki","labels":[{"name":"documentation"}],"closedAt":"2026-07-07T10:00:00Z"},
  {"number":104,"title":"ADR-048","labels":[{"name":"adr"}],"closedAt":"2026-07-08T10:00:00Z"},
  {"number":105,"title":"redaction audit","labels":[{"name":"security"}],"closedAt":"2026-07-09T10:00:00Z"}
]
EOF
export MOCK_PR_LIST_JSON="$TEST_TEMP_DIR/prs.json"
printf '[]\n' > "$MOCK_PR_LIST_JSON"

# ── Shared ORDER log: both the git-tag mock and the gh mock append to it so the
#    test can assert the tag PUSH precedes `gh release create` across binaries. ─
ORDER_LOG="$TEST_TEMP_DIR/order.log"
export ORDER_LOG

# ── Mock gh: handles issue/pr list calls AND release create/view ──────────────
GH_CALLS_LOG="$TEST_TEMP_DIR/gh-calls.log"
export GH_CALLS_LOG
mock_binary "gh" '
GH_CALLS_LOG="${GH_CALLS_LOG:-/tmp/gh-calls.log}"
ORDER_LOG="${ORDER_LOG:-/dev/null}"
printf "gh %s\n" "$*" >> "$GH_CALLS_LOG"

jq_filter=""
for ((i=1; i<=$#; i++)); do
    if [[ "${!i}" == "--jq" ]]; then j=$((i+1)); jq_filter="${!j}"; break; fi
done
_emit() {
    local src="$1"
    if [[ -n "$jq_filter" && -s "$src" ]]; then jq -r "$jq_filter" < "$src"; else cat "$src"; fi
}
case "${1:-} ${2:-}" in
    "repo view")      echo "ezigus/zBuild"; exit 0 ;;
    "issue list")     _emit "${MOCK_ISSUE_LIST_JSON:-/dev/null}"; exit 0 ;;
    "pr list")        _emit "${MOCK_PR_LIST_JSON:-/dev/null}"; exit 0 ;;
    "release view")   exit 1 ;;
    "release create") printf "gh-release-create\n" >> "$ORDER_LOG"; exit 0 ;;
    "release delete") exit 0 ;;
    *) echo "[mock-gh] unhandled: $*" >&2; exit 0 ;;
esac
'

# ── Mock git tag command via ZBUILD_GIT_TAG_CMD seam ─────────────────────────
# Logs EVERY invocation (tag -a, push, …); the push also records into ORDER_LOG.
GIT_TAG_LOG="$TEST_TEMP_DIR/git-tag-calls.log"
export GIT_TAG_LOG
mock_binary "mock-git-tag" '
GIT_TAG_LOG="${GIT_TAG_LOG:-/tmp/git-tag-calls.log}"
ORDER_LOG="${ORDER_LOG:-/dev/null}"
printf "git %s\n" "$*" >> "$GIT_TAG_LOG"
if [[ "${1:-}" == "tag" && "${2:-}" == "-l" ]]; then
    exit 0
fi
if [[ "${1:-}" == "push" ]]; then
    printf "git-tag-push\n" >> "$ORDER_LOG"
fi
exit 0
'
export ZBUILD_GIT_TAG_CMD="$TEST_TEMP_DIR/bin/mock-git-tag"

# ── Mock git command via ZBUILD_GIT_CMD seam (prepare-path branch + commit) ──
GIT_CMD_LOG="$TEST_TEMP_DIR/git-cmd-calls.log"
export GIT_CMD_LOG
mock_binary "mock-git" '
GIT_CMD_LOG="${GIT_CMD_LOG:-/tmp/git-cmd-calls.log}"
printf "git %s\n" "$*" >> "$GIT_CMD_LOG"
exit 0
'
export ZBUILD_GIT_CMD="$TEST_TEMP_DIR/bin/mock-git"

# ── Doc-publish seam: log-only stub to keep apply tests hermetic ─────────────
DOC_PUBLISH_LOG="$TEST_TEMP_DIR/doc-publish-calls.log"
export DOC_PUBLISH_LOG
mock_binary "mock-doc-publish" '
DOC_PUBLISH_LOG="${DOC_PUBLISH_LOG:-/tmp/doc-publish-calls.log}"
printf "doc-publish %s\n" "$*" >> "$DOC_PUBLISH_LOG"
exit 0
'
export ZBUILD_DOC_PUBLISH_CMD="$TEST_TEMP_DIR/bin/mock-doc-publish"

# ── Outdir seam ───────────────────────────────────────────────────────────────
APPLY_OUTDIR="$TEST_TEMP_DIR/release-out"
mkdir -p "$APPLY_OUTDIR"
export ZBUILD_RELEASE_OUTDIR="$APPLY_OUTDIR"

_reset_logs() {
    > "$GH_CALLS_LOG"
    > "$GIT_TAG_LOG"
    > "$GIT_CMD_LOG"
    > "$DOC_PUBLISH_LOG"
    > "$ORDER_LOG"
    cp "$REPO_ROOT/CHANGELOG.md" "$sandbox_changelog"
}

# ── TP: PREPARE path (default apply) — commit bump on a branch, NO tag/publish ─
_reset_logs
rm -f "$APPLY_OUTDIR/zbuild-v1.0.1.5.tar.gz"
real_version_before="$(cat "$REPO_ROOT/VERSION")"
prep_out="$(bash "$REPO_ROOT/scripts/release.sh" --milestone "Initiative 1.1" 2>&1)" \
    || { echo "$prep_out"; assert_fail "[SPEC-P1] prepare (default apply) release.sh exits 0"; exit 1; }
assert_pass "[SPEC-P1] prepare (default apply) release.sh exits 0"

# SPEC-P1: VERSION stamp went to sandbox; tracked repo VERSION untouched.
sandbox_version="$(cat "$TEST_TEMP_DIR/VERSION" 2>/dev/null || echo '<missing>')"
if [[ "$sandbox_version" == "1.0.1.5" ]]; then
    assert_pass "[SPEC-P1] prepare stamps VERSION to sandbox path (ZBUILD_RELEASE_VERSION_FILE)"
else
    assert_fail "[SPEC-P1] prepare stamps VERSION to sandbox path" "sandbox VERSION: $sandbox_version"
fi
real_version_after="$(cat "$REPO_ROOT/VERSION")"
if [[ "$real_version_after" == "$real_version_before" ]] && git -C "$REPO_ROOT" diff --quiet -- VERSION 2>/dev/null; then
    assert_pass "[SPEC-P1] prepare did not dirty the tracked VERSION file"
else
    assert_fail "[SPEC-P1] prepare must not write the tracked VERSION file" \
        "VERSION changed to: $(cat "$REPO_ROOT/VERSION")"
fi

# SPEC-P1: CHANGELOG (sandbox) was prepended.
if grep -qF "## [1.0.1.5]" "$sandbox_changelog" 2>/dev/null; then
    assert_pass "[SPEC-P1] prepare prepends the release section to the sandbox CHANGELOG"
else
    assert_fail "[SPEC-P1] prepare prepends the release section to the sandbox CHANGELOG"
fi

# SPEC-P2: prepare creates a release/<version> branch and commits the bump on it.
if grep -qF "checkout -b release/1.0.1.5" "$GIT_CMD_LOG" 2>/dev/null; then
    assert_pass "[SPEC-P2] prepare creates the release/1.0.1.5 branch"
else
    assert_fail "[SPEC-P2] prepare creates the release/1.0.1.5 branch" \
        "git-cmd log: $(cat "$GIT_CMD_LOG" 2>/dev/null || echo '<empty>')"
fi
if grep -qF "commit -m" "$GIT_CMD_LOG" 2>/dev/null; then
    assert_pass "[SPEC-P2] prepare commits the bump on the release branch"
else
    assert_fail "[SPEC-P2] prepare commits the bump on the release branch" \
        "git-cmd log: $(cat "$GIT_CMD_LOG" 2>/dev/null || echo '<empty>')"
fi
# The commit MUST come after the branch checkout (branch, THEN commit).
_co_line="$(grep -n 'checkout -b' "$GIT_CMD_LOG" 2>/dev/null | head -1 | cut -d: -f1 || true)"
_ci_line="$(grep -n 'commit -m'   "$GIT_CMD_LOG" 2>/dev/null | head -1 | cut -d: -f1 || true)"
if [[ -n "$_co_line" && -n "$_ci_line" && "$_co_line" -lt "$_ci_line" ]]; then
    assert_pass "[SPEC-P2] prepare checks out the branch BEFORE committing"
else
    assert_fail "[SPEC-P2] prepare checks out the branch BEFORE committing" \
        "checkout=$_co_line commit=$_ci_line"
fi

# SPEC-P3: prepare does NOT tag and does NOT publish.
if grep -qF "tag -a" "$GIT_TAG_LOG" 2>/dev/null; then
    assert_fail "[SPEC-P3] prepare must NOT create a git tag" \
        "git-tag log: $(cat "$GIT_TAG_LOG" 2>/dev/null || echo '<empty>')"
else
    assert_pass "[SPEC-P3] prepare does not create a git tag"
fi
if grep -qF "push" "$GIT_TAG_LOG" 2>/dev/null; then
    assert_fail "[SPEC-P3] prepare must NOT push a tag" \
        "git-tag log: $(cat "$GIT_TAG_LOG" 2>/dev/null || echo '<empty>')"
else
    assert_pass "[SPEC-P3] prepare does not push a tag"
fi
if grep -qF "release create" "$GH_CALLS_LOG" 2>/dev/null; then
    assert_fail "[SPEC-P3] prepare must NOT publish a GitHub Release" \
        "gh log: $(cat "$GH_CALLS_LOG" 2>/dev/null || echo '<empty>')"
else
    assert_pass "[SPEC-P3] prepare does not invoke gh release create"
fi

# SPEC-P4: prepare does NOT build a release tarball (publish path's job).
if [[ ! -f "$APPLY_OUTDIR/zbuild-v1.0.1.5.tar.gz" ]]; then
    assert_pass "[SPEC-P4] prepare does not build a tarball"
else
    assert_fail "[SPEC-P4] prepare must not build a tarball"
fi

# ── T1: PUBLISH path (--force) — tarball + tag + push + gh release create ──────
_reset_logs
rm -f "$APPLY_OUTDIR/zbuild-v1.0.1.5.tar.gz"
out="$(bash "$REPO_ROOT/scripts/release.sh" --force --milestone "Initiative 1.1" 2>&1)" \
    || { echo "$out"; assert_fail "[SPEC-1] publish (--force) release.sh exits 0"; exit 1; }
assert_pass "[SPEC-1] publish (--force) release.sh exits 0"

# SPEC-1: build_release_tarball ran — tarball in ZBUILD_RELEASE_OUTDIR
tarball_path="$APPLY_OUTDIR/zbuild-v1.0.1.5.tar.gz"
if [[ -f "$tarball_path" ]]; then
    assert_pass "[SPEC-1] build_release_tarball produced tarball in ZBUILD_RELEASE_OUTDIR"
else
    assert_fail "[SPEC-1] build_release_tarball produced tarball in ZBUILD_RELEASE_OUTDIR" \
        "expected: $tarball_path"
fi

# SPEC-2: git tag -a was called
if grep -qF "tag -a v1.0.1.5" "$GIT_TAG_LOG" 2>/dev/null; then
    assert_pass "[SPEC-2] annotated git tag v1.0.1.5 was created"
else
    assert_fail "[SPEC-2] annotated git tag v1.0.1.5 was created" \
        "git-tag log: $(cat "$GIT_TAG_LOG" 2>/dev/null || echo '<empty>')"
fi

# SPEC-2b: the tag was PUSHED, and the push happened BEFORE gh release create.
if grep -qF "push --force origin v1.0.1.5" "$GIT_TAG_LOG" 2>/dev/null; then
    assert_pass "[SPEC-2b] publish pushes the tag to origin (before publishing)"
else
    assert_fail "[SPEC-2b] publish pushes the tag to origin" \
        "git-tag log: $(cat "$GIT_TAG_LOG" 2>/dev/null || echo '<empty>')"
fi
# ORDER_LOG records cross-binary order: the git-tag mock appends 'git-tag-push'
# on push, the gh mock appends 'gh-release-create' on create. The push line MUST
# precede the create line — proving push-before-publish, the #1490 fix.
_push_line="$(grep -n 'git-tag-push' "$ORDER_LOG" 2>/dev/null | head -1 | cut -d: -f1 || true)"
_create_line="$(grep -n 'gh-release-create' "$ORDER_LOG" 2>/dev/null | head -1 | cut -d: -f1 || true)"
if [[ -n "$_push_line" && -n "$_create_line" && "$_push_line" -lt "$_create_line" ]]; then
    assert_pass "[SPEC-2b] tag push precedes gh release create (push-before-publish)"
else
    assert_fail "[SPEC-2b] tag push must precede gh release create" \
        "order log: $(cat "$ORDER_LOG" 2>/dev/null || echo '<empty>') push=$_push_line create=$_create_line"
fi

# SPEC-3: gh release create was called with the expected artifacts
if grep -qF "release create" "$GH_CALLS_LOG" 2>/dev/null; then
    assert_pass "[SPEC-3] gh release create was invoked"
else
    assert_fail "[SPEC-3] gh release create was invoked" \
        "gh log: $(cat "$GH_CALLS_LOG" 2>/dev/null || echo '<empty>')"
fi
if grep -q "release create.*zbuild-v1.0.1.5" "$GH_CALLS_LOG" 2>/dev/null; then
    assert_pass "[SPEC-3] gh release create includes the tarball"
else
    assert_fail "[SPEC-3] gh release create includes the tarball" \
        "gh log: $(cat "$GH_CALLS_LOG" 2>/dev/null || echo '<empty>')"
fi
if grep -q "release create.*SHA256SUMS" "$GH_CALLS_LOG" 2>/dev/null; then
    assert_pass "[SPEC-3] gh release create includes SHA256SUMS"
else
    assert_fail "[SPEC-3] gh release create includes SHA256SUMS" \
        "gh log: $(cat "$GH_CALLS_LOG" 2>/dev/null || echo '<empty>')"
fi
if grep -q "release create.*--notes-file" "$GH_CALLS_LOG" 2>/dev/null; then
    assert_pass "[SPEC-3] gh release create uses --notes-file"
else
    assert_fail "[SPEC-3] gh release create uses --notes-file" \
        "gh log: $(cat "$GH_CALLS_LOG" 2>/dev/null || echo '<empty>')"
fi

assert_contains "[SPEC-5] --force logs gate bypass" "$out" "skipping"

# ── T2: --dry-run prints planned lines; logs empty; no new tarball ────────────
rm -f "$APPLY_OUTDIR/zbuild-v1.0.1.5.tar.gz"
_reset_logs
dry_out="$(bash "$REPO_ROOT/scripts/release.sh" --dry-run --milestone "Initiative 1.1" 2>&1)" \
    || { echo "$dry_out"; assert_fail "[SPEC-4] --dry-run exits 0"; exit 1; }
assert_pass "[SPEC-4] --dry-run exits 0"

assert_contains "[SPEC-4] dry-run prints planned tarball line"  "$dry_out" "planned tarball:"
assert_contains "[SPEC-4] dry-run prints planned tag line"      "$dry_out" "planned tag:"
assert_contains "[SPEC-4] dry-run prints planned publish line"  "$dry_out" "planned publish:"

if grep -qF "tag -a" "$GIT_TAG_LOG" 2>/dev/null; then
    assert_fail "[SPEC-4] --dry-run must not create a git tag"
else
    assert_pass "[SPEC-4] --dry-run leaves git-tag log empty"
fi
if grep -qF "checkout -b" "$GIT_CMD_LOG" 2>/dev/null; then
    assert_fail "[SPEC-4] --dry-run must not create a release branch"
else
    assert_pass "[SPEC-4] --dry-run leaves git-cmd log empty (no branch)"
fi
if grep -qF "release create" "$GH_CALLS_LOG" 2>/dev/null; then
    assert_fail "[SPEC-4] --dry-run must not invoke gh release create"
else
    assert_pass "[SPEC-4] --dry-run does not invoke gh release create"
fi

if [[ ! -f "$APPLY_OUTDIR/zbuild-v1.0.1.5.tar.gz" ]]; then
    assert_pass "[SPEC-6] --dry-run does not build a tarball in outdir"
else
    assert_fail "[SPEC-6] --dry-run must not build a tarball in outdir"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
