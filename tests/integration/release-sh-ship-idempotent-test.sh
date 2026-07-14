#!/usr/bin/env bash
# tests/integration/release-sh-ship-idempotent-test.sh
# Acceptance tests for _release_ship idempotent re-run / resume detection (#1500).
#
# SPEC-13: PR-exists resume: exit 0; no checkout-b or pr-create; pr-checks→pr-merge→tag-a in order
# SPEC-14: Branch-exists-no-PR resume: exit 0; no checkout-b; pr-create appears
# SPEC-15: Preflight accepts HEAD on release/* branch (not only main)
# SPEC-16: Resume info log emitted when steps are skipped
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "release.sh --ship: idempotent re-run / resume detection (SHIP-3, #1500)"
setup_test_env "release-sh-ship-idempotent"

# ── Shared env seams: deterministic version + repo slug ──────────────────────
export ZBUILD_RELEASE_REPO="ezigus/zBuild"
export ZBUILD_VERSION_ANCHOR="1.0"
export ZBUILD_VERSION_RELEASE_COUNT="1"
export ZBUILD_RELEASE_SINCE="2026-07-04T00:00:00Z"
export ZBUILD_RELEASE_LAST_TAG="v1.0.0"

# Sandbox CHANGELOG and VERSION so ship tests never touch tracked files.
sandbox_changelog="$TEST_TEMP_DIR/CHANGELOG.md"
cp "$REPO_ROOT/CHANGELOG.md" "$sandbox_changelog"
export ZBUILD_RELEASE_CHANGELOG="$sandbox_changelog"
export ZBUILD_RELEASE_VERSION_FILE="$TEST_TEMP_DIR/VERSION"

# Issue list: 5 in-window issues → D=5 → patch=1.0.1.5
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

# ── Shared ORDER_LOG: all mocks append to one file for cross-binary ordering ─
ORDER_LOG="$TEST_TEMP_DIR/order.log"
export ORDER_LOG

GH_CALLS_LOG="$TEST_TEMP_DIR/gh-calls.log"
GIT_CMD_LOG="$TEST_TEMP_DIR/git-cmd-calls.log"
GIT_TAG_LOG="$TEST_TEMP_DIR/git-tag-calls.log"
DOC_PUBLISH_LOG="$TEST_TEMP_DIR/doc-publish-calls.log"
DOC_STYLE_LOG="$TEST_TEMP_DIR/doc-style-calls.log"
export GH_CALLS_LOG GIT_CMD_LOG GIT_TAG_LOG DOC_PUBLISH_LOG DOC_STYLE_LOG

# ── mock-gh ───────────────────────────────────────────────────────────────────
mock_binary "mock-gh" '
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
    "auth status")    exit 0 ;;
    "repo view")      echo "ezigus/zBuild"; exit 0 ;;
    "issue list")     _emit "${MOCK_ISSUE_LIST_JSON:-/dev/null}"; exit 0 ;;
    "pr list")        _emit "${MOCK_PR_LIST_JSON:-/dev/null}"; exit 0 ;;
    "pr create")      printf "pr-create\n" >> "$ORDER_LOG"; echo "https://github.com/ezigus/zBuild/pull/999"; exit 0 ;;
    "pr checks")
        printf "pr-checks\n" >> "$ORDER_LOG"
        exit 0 ;;
    "pr merge")       printf "pr-merge\n" >> "$ORDER_LOG"; exit 0 ;;
    "release view")   exit 1 ;;
    "release create") printf "release-create\n" >> "$ORDER_LOG"; exit 0 ;;
    "release delete") exit 0 ;;
    "api "*)          printf "[{\"title\":\"Initiative 2.0\",\"open_issues\":0}]\n"; exit 0 ;;
    *)                echo "[mock-gh] unhandled: $*" >&2; exit 0 ;;
esac
'
ln -sf "$TEST_TEMP_DIR/bin/mock-gh" "$TEST_TEMP_DIR/bin/gh"
export ZBUILD_GH_PR_CMD="$TEST_TEMP_DIR/bin/mock-gh"
export ZBUILD_GH_RELEASE_CMD="$TEST_TEMP_DIR/bin/mock-gh"
export ZBUILD_GH_CMD="$TEST_TEMP_DIR/bin/mock-gh"

# ── mock-git: handles ship branch ops + resume detection (ls-remote) ──────────
# MOCK_GIT_LSREMOTE_BRANCH_EXISTS=1 makes ls-remote emit a ref line (branch found).
# MOCK_GIT_HEAD_BRANCH overrides the current branch returned by rev-parse.
mock_binary "mock-git" '
GIT_CMD_LOG="${GIT_CMD_LOG:-/tmp/git-cmd-calls.log}"
ORDER_LOG="${ORDER_LOG:-/dev/null}"
printf "git %s\n" "$*" >> "$GIT_CMD_LOG"
case "${1:-}" in
    diff)       exit 0 ;;
    rev-parse)
        if [[ "${2:-}" == "--abbrev-ref" ]]; then
            echo "${MOCK_GIT_HEAD_BRANCH:-main}"
        fi
        exit 0 ;;
    ls-remote)
        if [[ "${MOCK_GIT_LSREMOTE_BRANCH_EXISTS:-0}" == "1" ]]; then
            echo "abc123def4567890  refs/heads/release/1.0.1.5"
        fi
        exit 0 ;;
    checkout)
        if [[ "${2:-}" == "-b" ]]; then printf "checkout-b\n" >> "$ORDER_LOG"; fi
        exit 0 ;;
    push)       printf "branch-push\n" >> "$ORDER_LOG"; exit 0 ;;
    *)          exit 0 ;;
esac
'
export ZBUILD_GIT_CMD="$TEST_TEMP_DIR/bin/mock-git"

# ── mock-git-tag ──────────────────────────────────────────────────────────────
mock_binary "mock-git-tag" '
GIT_TAG_LOG="${GIT_TAG_LOG:-/tmp/git-tag-calls.log}"
ORDER_LOG="${ORDER_LOG:-/dev/null}"
printf "git %s\n" "$*" >> "$GIT_TAG_LOG"
if [[ "${1:-}" == "tag" && "${2:-}" == "-l" ]]; then exit 0; fi
if [[ "${1:-}" == "tag" && "${2:-}" == "-a" ]]; then printf "tag-a\n" >> "$ORDER_LOG"; fi
if [[ "${1:-}" == "push" ]]; then printf "tag-push\n" >> "$ORDER_LOG"; fi
exit 0
'
export ZBUILD_GIT_TAG_CMD="$TEST_TEMP_DIR/bin/mock-git-tag"

# ── mock-doc-publish ─────────────────────────────────────────────────────────
mock_binary "mock-doc-publish" '
DOC_PUBLISH_LOG="${DOC_PUBLISH_LOG:-/tmp/doc-publish-calls.log}"
ORDER_LOG="${ORDER_LOG:-/dev/null}"
printf "doc-publish %s\n" "$*" >> "$DOC_PUBLISH_LOG"
if [[ "${1:-}" == "wiki" ]]; then printf "wiki\n" >> "$ORDER_LOG"; fi
exit 0
'
export ZBUILD_DOC_PUBLISH_CMD="$TEST_TEMP_DIR/bin/mock-doc-publish"

# ── mock-lint-doc-style ───────────────────────────────────────────────────────
mock_binary "mock-lint-doc-style" '
DOC_STYLE_LOG="${DOC_STYLE_LOG:-/tmp/doc-style-calls.log}"
printf "lint-doc-style\n" >> "$DOC_STYLE_LOG"
exit 0
'
export ZBUILD_DOC_STYLE_LINT="$TEST_TEMP_DIR/bin/mock-lint-doc-style"

# Auto-answer 'y' for all tests via the ZBUILD_SHIP_CONFIRM_ANSWER string seam.
export ZBUILD_SHIP_CONFIRM_ANSWER="y"

SHIP_OUTDIR="$TEST_TEMP_DIR/release-out"
mkdir -p "$SHIP_OUTDIR"
export ZBUILD_RELEASE_OUTDIR="$SHIP_OUTDIR"

_reset_logs() {
    > "$GH_CALLS_LOG"
    > "$GIT_CMD_LOG"
    > "$GIT_TAG_LOG"
    > "$DOC_PUBLISH_LOG"
    > "$DOC_STYLE_LOG"
    > "$ORDER_LOG"
    cp "$REPO_ROOT/CHANGELOG.md" "$sandbox_changelog"
    > "$ZBUILD_RELEASE_VERSION_FILE"
}

# ── T1: PR-exists resume path (SPEC-13) ──────────────────────────────────────
# Remote branch + open PR exist → steps 1-3 skipped, step 4+ run normally.
_reset_logs
export MOCK_GIT_LSREMOTE_BRANCH_EXISTS=1
printf '[{"number":999,"url":"https://github.com/ezigus/zBuild/pull/999"}]\n' \
    > "$MOCK_PR_LIST_JSON"

spec13_rc=0
spec13_out="$(bash "$REPO_ROOT/scripts/release.sh" --ship --milestone "Initiative 1.1" 2>&1)" \
    || spec13_rc=$?

if [[ "$spec13_rc" -eq 0 ]]; then
    assert_pass "[SPEC-13] --ship exits 0 when resuming from existing open PR"
else
    assert_fail "[SPEC-13] --ship must exit 0 when resuming from existing open PR (rc=${spec13_rc})" \
        "output: ${spec13_out}"
fi

if ! grep -q "checkout-b" "$ORDER_LOG" 2>/dev/null; then
    assert_pass "[SPEC-13] checkout-b NOT in ORDER_LOG (prepare step skipped on PR-exists resume)"
else
    assert_fail "[SPEC-13] checkout-b must NOT appear when PR already exists" \
        "ORDER_LOG: $(cat "$ORDER_LOG" 2>/dev/null || echo '<empty>')"
fi

if ! grep -q "pr-create" "$ORDER_LOG" 2>/dev/null; then
    assert_pass "[SPEC-13] pr-create NOT in ORDER_LOG (step 3 skipped on PR-exists resume)"
else
    assert_fail "[SPEC-13] pr-create must NOT appear when PR already exists" \
        "ORDER_LOG: $(cat "$ORDER_LOG" 2>/dev/null || echo '<empty>')"
fi

_pch_line="$(grep -n 'pr-checks' "$ORDER_LOG" 2>/dev/null | head -1 | cut -d: -f1 || true)"
_pm_line="$(grep -n 'pr-merge' "$ORDER_LOG" 2>/dev/null | head -1 | cut -d: -f1 || true)"
_ta_line="$(grep -n 'tag-a' "$ORDER_LOG" 2>/dev/null | head -1 | cut -d: -f1 || true)"
if [[ -n "$_pch_line" && -n "$_pm_line" && -n "$_ta_line" \
      && "$_pch_line" -lt "$_pm_line" && "$_pm_line" -lt "$_ta_line" ]]; then
    assert_pass "[SPEC-13] pr-checks → pr-merge → tag-a in order on PR-exists resume"
else
    assert_fail "[SPEC-13] pr-checks → pr-merge → tag-a must appear in order on PR-exists resume" \
        "ORDER_LOG: $(cat "$ORDER_LOG" 2>/dev/null || echo '<empty>') pch=$_pch_line pm=$_pm_line ta=$_ta_line"
fi

# ── T2: Branch-exists-no-PR resume path (SPEC-14) ────────────────────────────
# Remote branch exists but no open PR → step 1-2 skipped, step 3+ run.
_reset_logs
export MOCK_GIT_LSREMOTE_BRANCH_EXISTS=1
printf '[]\n' > "$MOCK_PR_LIST_JSON"

spec14_rc=0
spec14_out="$(bash "$REPO_ROOT/scripts/release.sh" --ship --milestone "Initiative 1.1" 2>&1)" \
    || spec14_rc=$?

if [[ "$spec14_rc" -eq 0 ]]; then
    assert_pass "[SPEC-14] --ship exits 0 when branch exists at origin but no open PR"
else
    assert_fail "[SPEC-14] --ship must exit 0 when branch at origin, no PR (rc=${spec14_rc})" \
        "output: ${spec14_out}"
fi

if ! grep -q "checkout-b" "$ORDER_LOG" 2>/dev/null; then
    assert_pass "[SPEC-14] checkout-b NOT in ORDER_LOG (prepare skipped when branch already at origin)"
else
    assert_fail "[SPEC-14] checkout-b must NOT appear when branch already at origin" \
        "ORDER_LOG: $(cat "$ORDER_LOG" 2>/dev/null || echo '<empty>')"
fi

if grep -q "pr-create" "$ORDER_LOG" 2>/dev/null; then
    assert_pass "[SPEC-14] pr-create APPEARS in ORDER_LOG (PR creation runs in branch-resume path)"
else
    assert_fail "[SPEC-14] pr-create must appear when no open PR exists in branch-resume path" \
        "ORDER_LOG: $(cat "$ORDER_LOG" 2>/dev/null || echo '<empty>')"
fi

# ── T3: Preflight accepts HEAD on release/* branch (SPEC-15) ─────────────────
# Without the preflight relaxation, HEAD on release/1.0.1.5 would abort --ship.
_reset_logs
export MOCK_GIT_LSREMOTE_BRANCH_EXISTS=0
export MOCK_GIT_HEAD_BRANCH="release/1.0.1.5"
printf '[]\n' > "$MOCK_PR_LIST_JSON"

spec15_rc=0
spec15_out="$(bash "$REPO_ROOT/scripts/release.sh" --ship --milestone "Initiative 1.1" 2>&1)" \
    || spec15_rc=$?

if [[ "$spec15_rc" -eq 0 ]]; then
    assert_pass "[SPEC-15] --ship preflight accepts HEAD on release/* branch (not only main)"
else
    assert_fail "[SPEC-15] preflight must accept HEAD on release/* (rc=${spec15_rc})" \
        "output: ${spec15_out}"
fi
unset MOCK_GIT_HEAD_BRANCH

# ── T4: Resume info log emitted when skipping steps (SPEC-16) ────────────────
_reset_logs
export MOCK_GIT_LSREMOTE_BRANCH_EXISTS=1
printf '[{"number":888,"url":"https://github.com/ezigus/zBuild/pull/888"}]\n' \
    > "$MOCK_PR_LIST_JSON"

spec16_out="$(bash "$REPO_ROOT/scripts/release.sh" --ship --milestone "Initiative 1.1" 2>&1)"
if printf '%s' "$spec16_out" | grep -q "resuming from step"; then
    assert_pass "[SPEC-16] 'resuming from step' info log emitted when steps are skipped"
else
    assert_fail "[SPEC-16] 'resuming from step' must appear in output when steps are skipped" \
        "output: ${spec16_out}"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
