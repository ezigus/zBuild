#!/usr/bin/env bash
# tests/integration/release-orchestrates-docs-test.sh — DOC-F orchestration:
# release.sh invokes doc_publish_regen (build-content) + doc_publish_wiki (publish)
# as part of the full (non-dry-run) release pipeline.
#
# SPEC-1: non-dry-run release invokes doc_publish_regen (ZBUILD_DOC_PUBLISH_CMD sentinel)
# SPEC-2: non-dry-run release invokes wiki-push (git clone/commit/push in GIT_LOG)
# SPEC-3: regen log precedes wiki log (lifecycle ordering)
# SPEC-4: --force full run also orchestrates both doc ops
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "release.sh — orchestrates doc regen + wiki publish (DOC-F / #1467)"
setup_test_env "release-orchestrates-docs"
export REPO_ROOT

# ── Shared fixtures ────────────────────────────────────────────────────────────
export ZBUILD_RELEASE_REPO="ezigus/zBuild"
export ZBUILD_VERSION_ANCHOR="1.0"
export ZBUILD_VERSION_RELEASE_COUNT="1"
export ZBUILD_RELEASE_SINCE="2026-07-04T00:00:00Z"
export ZBUILD_RELEASE_LAST_TAG="v1.0.0"

sandbox_changelog="$TEST_TEMP_DIR/CHANGELOG.md"
cp "$REPO_ROOT/CHANGELOG.md" "$sandbox_changelog"
export ZBUILD_RELEASE_CHANGELOG="$sandbox_changelog"

# The non-dry-run path stamps VERSION; redirect it to the sandbox so the live
# release under test does not mutate the real repo-root VERSION file.
export ZBUILD_RELEASE_VERSION_FILE="$TEST_TEMP_DIR/VERSION"

export MOCK_ISSUE_LIST_JSON="$TEST_TEMP_DIR/issues.json"
cat > "$MOCK_ISSUE_LIST_JSON" <<'EOF'
[
  {"number":101,"title":"add release notes generator","labels":[{"name":"enhancement"}],"closedAt":"2026-07-05T10:00:00Z"}
]
EOF
export MOCK_PR_LIST_JSON="$TEST_TEMP_DIR/prs.json"
printf '[]\n' > "$MOCK_PR_LIST_JSON"

# ── Mock gh ────────────────────────────────────────────────────────────────────
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

# ── Mock git tag ───────────────────────────────────────────────────────────────
GIT_TAG_LOG="$TEST_TEMP_DIR/git-tag-calls.log"
export GIT_TAG_LOG
mock_binary "mock-git-tag" '
GIT_TAG_LOG="${GIT_TAG_LOG:-/tmp/git-tag-calls.log}"
printf "git %s\n" "$*" >> "$GIT_TAG_LOG"
if [[ "${1:-}" == "tag" && "${2:-}" == "-l" ]]; then
    exit 0
fi
exit 0
'
export ZBUILD_GIT_TAG_CMD="$TEST_TEMP_DIR/bin/mock-git-tag"

# ── Release outdir ─────────────────────────────────────────────────────────────
APPLY_OUTDIR="$TEST_TEMP_DIR/release-out"
mkdir -p "$APPLY_OUTDIR"
export ZBUILD_RELEASE_OUTDIR="$APPLY_OUTDIR"

# ── ZBUILD_DOC_PUBLISH_CMD stub ────────────────────────────────────────────────
# For regen: touches REGEN_SENTINEL + logs to CMD_LOG.
# For wiki: writes simulated git ops to GIT_LOG + logs to CMD_LOG.
# CMD_LOG line order is used to verify lifecycle ordering (SPEC-3).
CMD_LOG="$TEST_TEMP_DIR/cmd.log"
GIT_LOG="$TEST_TEMP_DIR/git.log"
REGEN_SENTINEL="$TEST_TEMP_DIR/regen.sentinel"
export CMD_LOG GIT_LOG REGEN_SENTINEL
mock_binary "mock-doc-publish" '
CMD_LOG="${CMD_LOG:-/dev/null}"
GIT_LOG="${GIT_LOG:-/dev/null}"
REGEN_SENTINEL="${REGEN_SENTINEL:-/tmp/regen.sentinel}"
subcmd="${1:-}"; shift || true
printf "doc-publish %s\n" "$subcmd" >> "$CMD_LOG"
case "$subcmd" in
    regen)
        touch "$REGEN_SENTINEL"
        ;;
    wiki)
        printf "git clone <remote>\n" >> "$GIT_LOG"
        printf "git -C <work> add -A\n" >> "$GIT_LOG"
        printf "git -C <work> commit -q -m docs: publish\n" >> "$GIT_LOG"
        printf "git -C <work> push origin HEAD\n" >> "$GIT_LOG"
        ;;
    *)
        printf "mock-doc-publish: unknown subcmd: %s\n" "$subcmd" >&2; exit 1 ;;
esac
exit 0
'
export ZBUILD_DOC_PUBLISH_CMD="$TEST_TEMP_DIR/bin/mock-doc-publish"

_reset_logs() {
    > "$CMD_LOG"
    > "$GIT_LOG"
    > "$GH_CALLS_LOG"
    > "$GIT_TAG_LOG"
    rm -f "$REGEN_SENTINEL"
    cp "$REPO_ROOT/CHANGELOG.md" "$sandbox_changelog"
}

# ── T0: PREPARE (default apply, #1490) regenerates docs but does NOT push wiki ─
# The wiki push is a PUBLISH-only op (--force); the default apply is the prepare
# path (branch + commit + regen) that opens the release PR — no wiki push yet.
print_test_section "SPEC-0: prepare (default apply) regens docs but does NOT push wiki"
_reset_logs
prep_out="$(bash "$REPO_ROOT/scripts/release.sh" --milestone "Initiative 1.1" 2>&1)" \
    || { printf '%s\n' "$prep_out"; assert_fail "[SPEC-0] prepare release.sh exits 0"; exit 1; }
if [[ -f "$REGEN_SENTINEL" ]]; then
    assert_pass "[SPEC-0] prepare invokes doc_publish_regen (sentinel present)"
else
    assert_fail "[SPEC-0] prepare invokes doc_publish_regen (sentinel present)" \
        "CMD_LOG: $(cat "$CMD_LOG" 2>/dev/null || echo '<empty>')"
fi
if grep -qF "push" "$GIT_LOG" 2>/dev/null; then
    assert_fail "[SPEC-0] prepare must NOT push the wiki (publish-only op)" \
        "GIT_LOG: $(cat "$GIT_LOG" 2>/dev/null || echo '<empty>')"
else
    assert_pass "[SPEC-0] prepare does not push the wiki"
fi

# ── T1: PUBLISH (--force) invokes regen (SPEC-1) + wiki (SPEC-2) in order (SPEC-3)
print_test_section "SPEC-1+2+3: publish (--force) release invokes regen then wiki"
_reset_logs
out="$(bash "$REPO_ROOT/scripts/release.sh" --force --milestone "Initiative 1.1" 2>&1)" \
    || { printf '%s\n' "$out"; assert_fail "[SPEC-1] publish (--force) release.sh exits 0"; exit 1; }

# SPEC-1: regen sentinel was written
if [[ -f "$REGEN_SENTINEL" ]]; then
    assert_pass "[SPEC-1] doc_publish_regen was invoked (sentinel present)"
else
    assert_fail "[SPEC-1] doc_publish_regen was invoked (sentinel present)" \
        "regen sentinel not found; CMD_LOG: $(cat "$CMD_LOG" 2>/dev/null || echo '<empty>')"
fi

# SPEC-2: git clone/commit/push recorded in GIT_LOG (wiki-push invoked)
if grep -qF "clone" "$GIT_LOG" 2>/dev/null \
        && grep -qF "commit" "$GIT_LOG" 2>/dev/null \
        && grep -qF "push" "$GIT_LOG" 2>/dev/null; then
    assert_pass "[SPEC-2] wiki-push invoked (git clone/commit/push in GIT_LOG)"
else
    assert_fail "[SPEC-2] wiki-push invoked (git clone/commit/push in GIT_LOG)" \
        "GIT_LOG: $(cat "$GIT_LOG" 2>/dev/null || echo '<empty>')"
fi

# SPEC-3: regen log line precedes wiki log line in CMD_LOG
_regen_line="$(grep -n 'regen' "$CMD_LOG" 2>/dev/null | head -1 | cut -d: -f1 || true)"
_wiki_line="$(grep -n 'wiki' "$CMD_LOG" 2>/dev/null | head -1 | cut -d: -f1 || true)"
if [[ -n "$_regen_line" && -n "$_wiki_line" && "$_regen_line" -lt "$_wiki_line" ]]; then
    assert_pass "[SPEC-3] regen log precedes wiki log (lifecycle ordering)"
else
    assert_fail "[SPEC-3] regen log precedes wiki log (lifecycle ordering)" \
        "regen_line=${_regen_line:-<missing>} wiki_line=${_wiki_line:-<missing>} CMD_LOG: $(cat "$CMD_LOG" 2>/dev/null || echo '<empty>')"
fi

# ── T2: --force run also orchestrates both doc ops (SPEC-4) ───────────────────
print_test_section "SPEC-4: --force run also orchestrates regen + wiki"
_reset_logs
mkdir -p "$APPLY_OUTDIR"
force_out="$(bash "$REPO_ROOT/scripts/release.sh" --force --milestone "Initiative 1.1" 2>&1)" \
    || { printf '%s\n' "$force_out"; assert_fail "[SPEC-4] --force release.sh exits 0"; exit 1; }

if [[ -f "$REGEN_SENTINEL" ]]; then
    assert_pass "[SPEC-4] --force: doc_publish_regen was invoked (sentinel present)"
else
    assert_fail "[SPEC-4] --force: doc_publish_regen was invoked (sentinel present)" \
        "CMD_LOG: $(cat "$CMD_LOG" 2>/dev/null || echo '<empty>')"
fi
if grep -qF "push" "$GIT_LOG" 2>/dev/null; then
    assert_pass "[SPEC-4] --force: wiki-push was invoked (push in GIT_LOG)"
else
    assert_fail "[SPEC-4] --force: wiki-push was invoked (push in GIT_LOG)" \
        "GIT_LOG: $(cat "$GIT_LOG" 2>/dev/null || echo '<empty>')"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
