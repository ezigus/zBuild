#!/usr/bin/env bash
# tests/integration/release-wrapper-test.sh — #1466
# Behavioral coverage for `zbuild release [--dry-run] [--major]`:
#   SPEC-1 [change]: zbuild release --dry-run injects --minor → cadence: minor
#   SPEC-2 [change]: zbuild release --dry-run --major shows doc/wiki plan (doc_publish_run load-bearing)
#   SPEC-3 [guard]:  --dry-run does not mutate CHANGELOG
#   SPEC-4 [change]: --dry-run prints "planned docs regen:" (doc_publish_run call in release.sh)
#   SPEC-5 [change]: --dry-run prints "planned wiki:" (doc_publish_run call in release.sh)
#   SPEC-6 [guard]:  zbuild release --dry-run exits 0
#   SPEC-7 [guard]:  dispatch reaches release.sh (planned version: in output)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "zbuild release wrapper + --dry-run DOC-F preview (#1466)"
setup_test_env "release-wrapper"

# ─── Mock gh: serves closed issues + merged PRs ──────────────────────────────
mock_binary "gh" '
GH_CALLS_LOG="'"$TEST_TEMP_DIR"'/gh-calls.log"
echo "gh $*" >> "$GH_CALLS_LOG"

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
    "api "*)          printf "[{\"title\":\"Initiative 2.0\",\"open_issues\":0}]\n"; exit 0 ;;
    *) echo "[mock-gh] unhandled: $*" >&2; exit 0 ;;
esac
'

# Mock git: no-op (avoids calling real git for tag/remote operations).
mock_binary "git" '
GIT_CALLS_LOG="'"$TEST_TEMP_DIR"'/git-calls.log"
echo "git $*" >> "$GIT_CALLS_LOG"
exit 0
'

# ─── Shared env seams ─────────────────────────────────────────────────────────
export ZBUILD_RELEASE_REPO="ezigus/zBuild"
export ZBUILD_VERSION_ANCHOR="1.0"
export ZBUILD_VERSION_RELEASE_COUNT="1"
export ZBUILD_RELEASE_SINCE="2026-07-04T00:00:00Z"
export ZBUILD_RELEASE_LAST_TAG="v1.0.0"
# Deterministic wiki remote (bypasses git remote get-url origin in _dp_wiki_remote).
export ZBUILD_WIKI_REMOTE="https://example.com/fake.wiki.git"

# 5 closed issues in-window → D=5; with minor cadence → version 1.1.0.0.
export MOCK_ISSUE_LIST_JSON="$TEST_TEMP_DIR/issues.json"
cat > "$MOCK_ISSUE_LIST_JSON" <<'EOF'
[
  {"number":101,"title":"add release notes generator","labels":[{"name":"enhancement"}],"closedAt":"2026-07-05T10:00:00Z"},
  {"number":102,"title":"fix torn-write in changelog prepend","labels":[{"name":"bug"}],"closedAt":"2026-07-06T10:00:00Z"},
  {"number":103,"title":"update wiki release model","labels":[{"name":"documentation"}],"closedAt":"2026-07-07T10:00:00Z"},
  {"number":104,"title":"ADR-048 versioning decision","labels":[{"name":"adr"}],"closedAt":"2026-07-08T10:00:00Z"},
  {"number":105,"title":"redaction chokepoint audit","labels":[{"name":"security"}],"closedAt":"2026-07-09T10:00:00Z"}
]
EOF
export MOCK_PR_LIST_JSON="$TEST_TEMP_DIR/prs.json"
printf '[]' > "$MOCK_PR_LIST_JSON"

# ─── Main dry-run (no explicit cadence flag — wrapper must inject --minor) ────
out="$(bash "$REPO_ROOT/scripts/zbuild" release --dry-run --milestone "Initiative 1.1" 2>&1)" \
    || { echo "$out"; assert_fail "zbuild release --dry-run exits 0"; exit 1; }

# ─── SPEC-1 [change]: wrapper injects --minor → cadence: minor ────────────────
# Fails at baseline: without the wrapper injection release.sh defaults to patch.
assert_contains "[SPEC-1] zbuild release --dry-run prints cadence: minor (wrapper injection)" \
    "$out" "cadence:         minor"

# ─── SPEC-4 [change]: doc_publish_run --dry-run → planned docs regen line ─────
# Fails at baseline: release.sh --dry-run block did not call doc_publish_run.
assert_contains "[SPEC-4] --dry-run prints planned docs regen line (doc_publish_run load-bearing)" \
    "$out" "planned docs regen:"

# ─── SPEC-5 [change]: doc_publish_run --dry-run → planned wiki push line ──────
# Fails at baseline: release.sh --dry-run block did not call doc_publish_run.
assert_contains "[SPEC-5] --dry-run prints planned wiki push line (doc_publish_run load-bearing)" \
    "$out" "planned wiki:"

# ─── SPEC-6 [guard]: zbuild release --dry-run exits 0 ────────────────────────
# Already captured (the subshell would have exited above on non-zero).
assert_pass "[SPEC-6] zbuild release --dry-run exits 0"

# ─── SPEC-7 [guard]: dispatch reaches release.sh (version info in output) ─────
# With minor cadence and D=5 the version is 1.1.0.0 (B bumped, C/D reset).
assert_contains "[SPEC-7] dispatch reaches release.sh (planned version: present)" \
    "$out" "planned version: 1.1.0.0"

# ─── SPEC-3 [guard]: dry-run does not mutate CHANGELOG ───────────────────────
sandbox_cl="$TEST_TEMP_DIR/CHANGELOG-spec3.md"
cp "$REPO_ROOT/CHANGELOG.md" "$sandbox_cl"
before_hash="$(shasum -a 256 "$sandbox_cl" | awk '{print $1}')"
ZBUILD_RELEASE_CHANGELOG="$sandbox_cl" \
    bash "$REPO_ROOT/scripts/zbuild" release --dry-run --milestone "Initiative 1.1" \
    >/dev/null 2>&1
after_hash="$(shasum -a 256 "$sandbox_cl" | awk '{print $1}')"
assert_eq "[SPEC-3] zbuild release --dry-run does not mutate CHANGELOG (byte-identical)" \
    "$before_hash" "$after_hash"

# ─── SPEC-2 [change]: --major run also shows doc/wiki plan ────────────────────
# Fails at baseline: release.sh --dry-run block did not call doc_publish_run.
# (cadence: major itself passes at baseline since --major is forwarded verbatim.)
out_major="$(bash "$REPO_ROOT/scripts/zbuild" release --dry-run --major \
    --milestone "Initiative 1.1" 2>&1)" \
    || { echo "$out_major"; assert_fail "[SPEC-2] zbuild release --dry-run --major exits 0"; exit 1; }
assert_contains "[SPEC-2] --major dry-run prints cadence: major" \
    "$out_major" "cadence:         major"
assert_contains "[SPEC-2] --major dry-run shows doc/wiki plan (doc_publish_run load-bearing)" \
    "$out_major" "planned docs regen:"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
