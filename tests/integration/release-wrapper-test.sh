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

# ─── Ship UX (SPEC-8 through SPEC-11): mock infrastructure ────────────────────
# SPEC-8 uses --ship --dry-run (no mutation; no PR/tag seams needed).
# SPEC-9/10/11 drive the full ship flow and need ship seams.

SHIP_CHANGELOG="$TEST_TEMP_DIR/ship-CHANGELOG.md"
cp "$REPO_ROOT/CHANGELOG.md" "$SHIP_CHANGELOG"
SHIP_VERSION_FILE="$TEST_TEMP_DIR/ship-VERSION"
SHIP_ORDER_LOG="$TEST_TEMP_DIR/ship-order.log"
SHIP_OUTDIR="$TEST_TEMP_DIR/ship-release-out"
mkdir -p "$SHIP_OUTDIR"
export SHIP_ORDER_LOG

# mock-git-ship: handles rev-parse → "main" and logs order events.
mock_binary "mock-git-ship" '
ORDER_LOG="${SHIP_ORDER_LOG:-/dev/null}"
case "${1:-}" in
    diff)       exit 0 ;;
    rev-parse)
        [[ "${2:-}" == "--show-toplevel" ]] && exit 0
        [[ "${2:-}" == "--abbrev-ref" ]] && echo "main"
        exit 0 ;;
    checkout)
        [[ "${2:-}" == "-b" ]] && printf "checkout-b\n" >> "$ORDER_LOG"
        exit 0 ;;
    push) printf "branch-push\n" >> "$ORDER_LOG"; exit 0 ;;
    *)    exit 0 ;;
esac
'

# mock-git-tag-ship: logs tag-a and tag-push events.
mock_binary "mock-git-tag-ship" '
ORDER_LOG="${SHIP_ORDER_LOG:-/dev/null}"
if [[ "${1:-}" == "tag" && "${2:-}" == "-l" ]]; then exit 0; fi
if [[ "${1:-}" == "tag" && "${2:-}" == "-a" ]]; then printf "tag-a\n" >> "$ORDER_LOG"; fi
if [[ "${1:-}" == "push" ]]; then printf "tag-push\n" >> "$ORDER_LOG"; fi
exit 0
'

# mock-gh-ship: covers all gh subcommands used by the ship flow.
mock_binary "mock-gh-ship" '
ORDER_LOG="${SHIP_ORDER_LOG:-/dev/null}"
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
    "pr checks")      printf "pr-checks\n" >> "$ORDER_LOG"; exit 0 ;;
    "pr merge")       printf "pr-merge\n" >> "$ORDER_LOG"; exit 0 ;;
    "release view")   exit 1 ;;
    "release create") printf "release-create\n" >> "$ORDER_LOG"; exit 0 ;;
    "release delete") exit 0 ;;
    "api "*)          printf "[{\"title\":\"Initiative 2.0\",\"open_issues\":0}]\n"; exit 0 ;;
    *)                echo "[mock-gh-ship] unhandled: $*" >&2; exit 0 ;;
esac
'

# mock-doc-publish-ship: stubs regen+wiki for the ship flow.
mock_binary "mock-doc-publish-ship" '
if [[ "${1:-}" == "wiki" ]]; then printf "wiki\n" >> "${SHIP_ORDER_LOG:-/dev/null}"; fi
exit 0
'

# mock-doc-style-ship: gate conformance stub (always passes).
mock_binary "mock-doc-style-ship" '
exit 0
'

# mock-confirm-y / mock-confirm-n: ZBUILD_SHIP_CONFIRM_CMD seam helpers.
mock_binary "mock-confirm-y" 'printf "y\n"'
mock_binary "mock-confirm-n" 'printf "n\n"'

_reset_ship_logs() {
    > "$SHIP_ORDER_LOG"
    cp "$REPO_ROOT/CHANGELOG.md" "$SHIP_CHANGELOG"
    printf '' > "$SHIP_VERSION_FILE"
}

# Export ship seam vars (used by SPEC-9/10/11; harmless for SPEC-8 dry-run).
export ZBUILD_RELEASE_CHANGELOG="$SHIP_CHANGELOG"
export ZBUILD_RELEASE_VERSION_FILE="$SHIP_VERSION_FILE"
export ZBUILD_RELEASE_OUTDIR="$SHIP_OUTDIR"
export ZBUILD_GIT_CMD="$TEST_TEMP_DIR/bin/mock-git-ship"
export ZBUILD_GIT_TAG_CMD="$TEST_TEMP_DIR/bin/mock-git-tag-ship"
export ZBUILD_GH_PR_CMD="$TEST_TEMP_DIR/bin/mock-gh-ship"
export ZBUILD_GH_RELEASE_CMD="$TEST_TEMP_DIR/bin/mock-gh-ship"
export ZBUILD_GH_CMD="$TEST_TEMP_DIR/bin/mock-gh-ship"
export ZBUILD_DOC_PUBLISH_CMD="$TEST_TEMP_DIR/bin/mock-doc-publish-ship"
export ZBUILD_DOC_STYLE_LINT="$TEST_TEMP_DIR/bin/mock-doc-style-ship"

# ─── SPEC-8: --ship --dry-run prints ship plan lines, exits 0, no gh pr create ──
# [change]: fails at baseline — --ship --dry-run showed no ship plan before SHIP-2.
_reset_ship_logs
ship_dry_out="$(bash "$REPO_ROOT/scripts/zbuild" release --ship --dry-run \
    --milestone "Initiative 1.1" 2>&1)" \
    || { echo "$ship_dry_out"; assert_fail "[SPEC-8] --ship --dry-run exits 0"; }
assert_pass "[SPEC-8] --ship --dry-run exits 0"
assert_contains "[SPEC-8] --ship --dry-run prints [1/7] step label" \
    "$ship_dry_out" "[1/7]"
assert_contains "[SPEC-8] --ship --dry-run prints planned version" \
    "$ship_dry_out" "planned version:"
if ! grep -q "pr-create" "$SHIP_ORDER_LOG" 2>/dev/null; then
    assert_pass "[SPEC-8] --ship --dry-run does not call gh pr create (no mutation)"
else
    assert_fail "[SPEC-8] --ship --dry-run must NOT call gh pr create" \
        "SHIP_ORDER_LOG: $(cat "$SHIP_ORDER_LOG" 2>/dev/null || echo '<empty>')"
fi
if ! grep -q "tag-a" "$SHIP_ORDER_LOG" 2>/dev/null; then
    assert_pass "[SPEC-8] --ship --dry-run does not create git tag (no mutation)"
else
    assert_fail "[SPEC-8] --ship --dry-run must NOT create git tag" \
        "SHIP_ORDER_LOG: $(cat "$SHIP_ORDER_LOG" 2>/dev/null || echo '<empty>')"
fi

# ─── SPEC-9 + SPEC-11: --ship --yes drives through to publish; banners present ──
# SPEC-9 [change]: fails at baseline — --yes was an unknown flag before SHIP-2.
# SPEC-11 [change]: fails at baseline — per-phase banners did not exist before SHIP-2.
# Use ZBUILD_SHIP_CONFIRM_CMD=mock-confirm-n to verify --yes bypasses the gate.
_reset_ship_logs
export ZBUILD_SHIP_CONFIRM_CMD="$TEST_TEMP_DIR/bin/mock-confirm-n"
yes_out="$(bash "$REPO_ROOT/scripts/zbuild" release --ship --yes \
    --milestone "Initiative 1.1" 2>&1)" \
    || { echo "$yes_out"; assert_fail "[SPEC-9] --ship --yes exits 0"; }
unset ZBUILD_SHIP_CONFIRM_CMD
assert_pass "[SPEC-9] --ship --yes exits 0 (confirm gate bypassed)"
if grep -q "tag-a" "$SHIP_ORDER_LOG" 2>/dev/null; then
    assert_pass "[SPEC-9] --ship --yes drives through to publish (tag-a in ORDER_LOG)"
else
    assert_fail "[SPEC-9] --ship --yes must drive through to publish (tag-a missing)" \
        "SHIP_ORDER_LOG: $(cat "$SHIP_ORDER_LOG" 2>/dev/null || echo '<empty>')"
fi
assert_contains "[SPEC-11] --ship output has [1/7] banner" "$yes_out" "[1/7]"
assert_contains "[SPEC-11] --ship output has [4/7] banner" "$yes_out" "[4/7]"
assert_contains "[SPEC-11] --ship output has [7/7] banner" "$yes_out" "[7/7]"

# ─── SPEC-10: --ship with confirm returning 'n' aborts before merge+publish ─────
# [change]: fails at baseline — no confirm gate existed before SHIP-2; ship always
# proceeded to merge+publish regardless of any input.
_reset_ship_logs
export ZBUILD_SHIP_CONFIRM_CMD="$TEST_TEMP_DIR/bin/mock-confirm-n"
confirm_rc=0
bash "$REPO_ROOT/scripts/zbuild" release --ship \
    --milestone "Initiative 1.1" >/dev/null 2>&1 || confirm_rc=$?
unset ZBUILD_SHIP_CONFIRM_CMD
if [[ "$confirm_rc" -ne 0 ]]; then
    assert_pass "[SPEC-10] --ship with confirm 'n' exits non-zero (aborted at confirm gate)"
else
    assert_fail "[SPEC-10] --ship with confirm 'n' must exit non-zero" "got rc=0"
fi
if ! grep -q "tag-a" "$SHIP_ORDER_LOG" 2>/dev/null; then
    assert_pass "[SPEC-10] no tag-a in ORDER_LOG when confirm returns n"
else
    assert_fail "[SPEC-10] tag-a must NOT appear when confirm returns n" \
        "SHIP_ORDER_LOG: $(cat "$SHIP_ORDER_LOG" 2>/dev/null || echo '<empty>')"
fi
if ! grep -q "release-create" "$SHIP_ORDER_LOG" 2>/dev/null; then
    assert_pass "[SPEC-10] no release-create in ORDER_LOG when confirm returns n"
else
    assert_fail "[SPEC-10] release-create must NOT appear when confirm returns n" \
        "SHIP_ORDER_LOG: $(cat "$SHIP_ORDER_LOG" 2>/dev/null || echo '<empty>')"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
