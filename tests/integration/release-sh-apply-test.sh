#!/usr/bin/env bash
# Tests: scripts/release.sh apply path (REL-D, #877) — tarball build, git tag,
# GitHub Release publish — with mocked gh + git + ZBUILD_RELEASE_OUTDIR seams.
#
# SPEC-1: non-dry-run calls build_release_tarball (tarball in ZBUILD_RELEASE_OUTDIR)
# SPEC-2: non-dry-run creates the annotated git tag (via ZBUILD_GIT_TAG_CMD log)
# SPEC-3: non-dry-run invokes gh release create with tarball + SHA256SUMS + --notes-file
# SPEC-4: --dry-run prints planned tarball/tag/publish lines; leaves git-tag log empty
# SPEC-5: --force bypasses gate and still executes the full apply path
# SPEC-6: --dry-run does not build a tarball (outdir has no new tarball after dry-run)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "release.sh — apply path: tarball + tag + gh publish (REL-D / #877)"
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

# ── Mock gh: handles issue/pr list calls AND release create/view ──────────────
GH_CALLS_LOG="$TEST_TEMP_DIR/gh-calls.log"
export GH_CALLS_LOG
mock_binary "gh" '
GH_CALLS_LOG="${GH_CALLS_LOG:-/tmp/gh-calls.log}"
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
    "release create") exit 0 ;;
    "release delete") exit 0 ;;
    *) echo "[mock-gh] unhandled: $*" >&2; exit 0 ;;
esac
'

# ── Mock git tag command via ZBUILD_GIT_TAG_CMD seam ─────────────────────────
GIT_TAG_LOG="$TEST_TEMP_DIR/git-tag-calls.log"
export GIT_TAG_LOG
mock_binary "mock-git-tag" '
GIT_TAG_LOG="${GIT_TAG_LOG:-/tmp/git-tag-calls.log}"
printf "git %s\n" "$*" >> "$GIT_TAG_LOG"
# tag -l <tag>: print nothing (tag does not yet exist)
if [[ "${1:-}" == "tag" && "${2:-}" == "-l" ]]; then
    exit 0
fi
exit 0
'
export ZBUILD_GIT_TAG_CMD="$TEST_TEMP_DIR/bin/mock-git-tag"

# ── Outdir seam ───────────────────────────────────────────────────────────────
APPLY_OUTDIR="$TEST_TEMP_DIR/release-out"
mkdir -p "$APPLY_OUTDIR"
export ZBUILD_RELEASE_OUTDIR="$APPLY_OUTDIR"

_reset_logs() {
    > "$GH_CALLS_LOG"
    > "$GIT_TAG_LOG"
    cp "$REPO_ROOT/CHANGELOG.md" "$sandbox_changelog"
}

# ── T1: non-dry-run calls build_release_tarball + git tag + gh release create ──
_reset_logs
out="$(bash "$REPO_ROOT/scripts/release.sh" --milestone "Initiative 1.1" 2>&1)" \
    || { echo "$out"; assert_fail "[SPEC-1] non-dry-run release.sh exits 0"; exit 1; }
assert_pass "[SPEC-1] non-dry-run release.sh exits 0"

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

# SPEC-3: gh release create was called
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

# ── T2: --dry-run prints planned lines; git-tag log empty; no new tarball ─────
# Remove tarball so we can detect if build_release_tarball runs under dry-run.
rm -f "$APPLY_OUTDIR/zbuild-v1.0.1.5.tar.gz"
_reset_logs
dry_out="$(bash "$REPO_ROOT/scripts/release.sh" --dry-run --milestone "Initiative 1.1" 2>&1)" \
    || { echo "$dry_out"; assert_fail "[SPEC-4] --dry-run exits 0"; exit 1; }
assert_pass "[SPEC-4] --dry-run exits 0"

# SPEC-4: dry-run prints the three planned mutation lines
assert_contains "[SPEC-4] dry-run prints planned tarball line"  "$dry_out" "planned tarball:"
assert_contains "[SPEC-4] dry-run prints planned tag line"      "$dry_out" "planned tag:"
assert_contains "[SPEC-4] dry-run prints planned publish line"  "$dry_out" "planned publish:"

# SPEC-4: dry-run must not create a git tag
if grep -qF "tag -a" "$GIT_TAG_LOG" 2>/dev/null; then
    assert_fail "[SPEC-4] --dry-run must not create a git tag"
else
    assert_pass "[SPEC-4] --dry-run leaves git-tag log empty"
fi

# SPEC-4: dry-run must not invoke gh release create
if grep -qF "release create" "$GH_CALLS_LOG" 2>/dev/null; then
    assert_fail "[SPEC-4] --dry-run must not invoke gh release create"
else
    assert_pass "[SPEC-4] --dry-run does not invoke gh release create"
fi

# SPEC-6: dry-run does not build a tarball
if [[ ! -f "$APPLY_OUTDIR/zbuild-v1.0.1.5.tar.gz" ]]; then
    assert_pass "[SPEC-6] --dry-run does not build a tarball in outdir"
else
    assert_fail "[SPEC-6] --dry-run must not build a tarball in outdir"
fi

# ── T3: --force bypasses gate and still executes the full apply path ──────────
# Restore outdir for the apply path.
mkdir -p "$APPLY_OUTDIR"
_reset_logs
force_out="$(bash "$REPO_ROOT/scripts/release.sh" --force --milestone "Initiative 1.1" 2>&1)" \
    || { echo "$force_out"; assert_fail "[SPEC-5] --force release exits 0"; exit 1; }
assert_pass "[SPEC-5] --force release exits 0"

assert_contains "[SPEC-5] --force logs gate bypass" "$force_out" "skipping"

if grep -qF "tag -a v1.0.1.5" "$GIT_TAG_LOG" 2>/dev/null; then
    assert_pass "[SPEC-5] --force still creates the annotated git tag"
else
    assert_fail "[SPEC-5] --force still creates the annotated git tag" \
        "git-tag log: $(cat "$GIT_TAG_LOG" 2>/dev/null || echo '<empty>')"
fi
if grep -qF "release create" "$GH_CALLS_LOG" 2>/dev/null; then
    assert_pass "[SPEC-5] --force still invokes gh release create"
else
    assert_fail "[SPEC-5] --force still invokes gh release create" \
        "gh log: $(cat "$GH_CALLS_LOG" 2>/dev/null || echo '<empty>')"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
