#!/usr/bin/env bash
# tests/integration/release-sh-ship-test.sh
# Acceptance tests for _release_ship and --ship flag in scripts/release.sh.
#
# SPEC-1:  --ship flag is recognized (exits 0, not "Unknown release flag")
# SPEC-2:  ship drives _release_prepare: release branch created then committed
# SPEC-3:  ship pushes release branch to origin (branch-push after checkout-b in ORDER_LOG)
# SPEC-4:  ship opens PR via ZBUILD_GH_PR_CMD (pr-create after branch-push in ORDER_LOG)
# SPEC-5:  ship waits for checks before merging (pr-checks after pr-create in ORDER_LOG)
# SPEC-6:  ship merges after checks pass (pr-merge after pr-checks in ORDER_LOG)
# SPEC-7:  ship publishes after merge (tag-a after pr-merge in ORDER_LOG)
# SPEC-8:  ship always runs the doc+coverage gate (never bypassed)
# SPEC-9:  version pinned — publish tag version equals prepare branch version (no drift)
# SPEC-10: failing checks causes abort before tag-a/release-create in ORDER_LOG
# SPEC-11: --ship --minor produces a minor version bump
# SPEC-12: --ship --major with milestone mock produces a major version bump
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "release.sh --ship: one-shot orchestration engine (SHIP-1)"
setup_test_env "release-sh-ship"

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

# Issue list: 5 in-window issues → D=5 → patch=1.0.1.5 / minor=1.1.0.0 / major=2.0.0.0
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

# ── Shared call logs per mock ──────────────────────────────────────────────
GH_CALLS_LOG="$TEST_TEMP_DIR/gh-calls.log"
GIT_CMD_LOG="$TEST_TEMP_DIR/git-cmd-calls.log"
GIT_TAG_LOG="$TEST_TEMP_DIR/git-tag-calls.log"
DOC_PUBLISH_LOG="$TEST_TEMP_DIR/doc-publish-calls.log"
DOC_STYLE_LOG="$TEST_TEMP_DIR/doc-style-calls.log"
export GH_CALLS_LOG GIT_CMD_LOG GIT_TAG_LOG DOC_PUBLISH_LOG DOC_STYLE_LOG

# ── mock-gh: covers ZBUILD_GH_PR_CMD + ZBUILD_GH_RELEASE_CMD + ZBUILD_GH_CMD ─
# Also placed on PATH as "gh" so the doc+coverage gate's unscoped `gh` calls hit it.
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
        [[ "${MOCK_PR_CHECKS_FAIL:-0}" == "1" ]] && exit 1
        exit 0 ;;
    "pr merge")       printf "pr-merge\n" >> "$ORDER_LOG"; exit 0 ;;
    "release view")   exit 1 ;;
    "release create") printf "release-create\n" >> "$ORDER_LOG"; exit 0 ;;
    "release delete") exit 0 ;;
    "api "*)          printf "[{\"title\":\"Initiative 2.0\",\"open_issues\":0}]\n"; exit 0 ;;
    *)                echo "[mock-gh] unhandled: $*" >&2; exit 0 ;;
esac
'
# Shadow PATH "gh" so gate calls (not via env seam) use the same mock.
ln -sf "$TEST_TEMP_DIR/bin/mock-gh" "$TEST_TEMP_DIR/bin/gh"
export ZBUILD_GH_PR_CMD="$TEST_TEMP_DIR/bin/mock-gh"
export ZBUILD_GH_RELEASE_CMD="$TEST_TEMP_DIR/bin/mock-gh"
export ZBUILD_GH_CMD="$TEST_TEMP_DIR/bin/mock-gh"

# ── mock-git (ZBUILD_GIT_CMD): handles ship's branch push + checkout/pull ────
mock_binary "mock-git" '
GIT_CMD_LOG="${GIT_CMD_LOG:-/tmp/git-cmd-calls.log}"
ORDER_LOG="${ORDER_LOG:-/dev/null}"
printf "git %s\n" "$*" >> "$GIT_CMD_LOG"
case "${1:-}" in
    diff)
        # Regression hook: when toggled, report a DIRTY tree the moment the
        # sandboxed VERSION file has been stamped. The clean-tree preflight must
        # therefore run BEFORE main() stamps VERSION, or --ship falsely aborts.
        if [[ "${MOCK_GIT_DIFF_DIRTY_IF_VERSION_STAMPED:-0}" == "1" \
              && -s "${ZBUILD_RELEASE_VERSION_FILE:-/dev/null}" ]]; then
            exit 1
        fi
        exit 0 ;;
    rev-parse)
        if [[ "${2:-}" == "--abbrev-ref" ]]; then echo "main"; fi
        exit 0 ;;
    checkout)
        if [[ "${2:-}" == "-b" ]]; then printf "checkout-b\n" >> "$ORDER_LOG"; fi
        exit 0 ;;
    push)      printf "branch-push\n" >> "$ORDER_LOG"; exit 0 ;;
    *)         exit 0 ;;
esac
'
export ZBUILD_GIT_CMD="$TEST_TEMP_DIR/bin/mock-git"

# ── mock-git-tag (ZBUILD_GIT_TAG_CMD): handles annotated tag + tag push ──────
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

# ── mock-doc-publish (ZBUILD_DOC_PUBLISH_CMD): regen + wiki stubs ────────────
mock_binary "mock-doc-publish" '
DOC_PUBLISH_LOG="${DOC_PUBLISH_LOG:-/tmp/doc-publish-calls.log}"
ORDER_LOG="${ORDER_LOG:-/dev/null}"
printf "doc-publish %s\n" "$*" >> "$DOC_PUBLISH_LOG"
if [[ "${1:-}" == "wiki" ]]; then printf "wiki\n" >> "$ORDER_LOG"; fi
exit 0
'
export ZBUILD_DOC_PUBLISH_CMD="$TEST_TEMP_DIR/bin/mock-doc-publish"

# ── mock-lint-doc-style (ZBUILD_DOC_STYLE_LINT): gate conformance stub ───────
mock_binary "mock-lint-doc-style" '
DOC_STYLE_LOG="${DOC_STYLE_LOG:-/tmp/doc-style-calls.log}"
printf "lint-doc-style\n" >> "$DOC_STYLE_LOG"
exit 0
'
export ZBUILD_DOC_STYLE_LINT="$TEST_TEMP_DIR/bin/mock-lint-doc-style"

# Outdir for tarball build (publish step).
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

# ── T1: happy path --patch (SPEC-1 through SPEC-9) ────────────────────────────
_reset_logs
unset MOCK_PR_CHECKS_FAIL 2>/dev/null || true
ship_out="$(bash "$REPO_ROOT/scripts/release.sh" --ship --milestone "Initiative 1.1" 2>&1)" \
    || { echo "$ship_out"; assert_fail "[SPEC-1] --ship exits 0"; exit 1; }
assert_pass "[SPEC-1] --ship flag recognized (exits 0, no 'Unknown release flag')"

# SPEC-2: _release_prepare ran — checkout -b and commit both in GIT_CMD_LOG
if grep -qF "checkout -b release/1.0.1.5" "$GIT_CMD_LOG" 2>/dev/null; then
    assert_pass "[SPEC-2] ship creates release/1.0.1.5 branch via _release_prepare"
else
    assert_fail "[SPEC-2] ship creates release/1.0.1.5 branch via _release_prepare" \
        "git-cmd log: $(cat "$GIT_CMD_LOG" 2>/dev/null || echo '<empty>')"
fi
if grep -qF "commit -m" "$GIT_CMD_LOG" 2>/dev/null; then
    assert_pass "[SPEC-2] _release_prepare commits the bump on the release branch"
else
    assert_fail "[SPEC-2] _release_prepare commits the bump on the release branch" \
        "git-cmd log: $(cat "$GIT_CMD_LOG" 2>/dev/null || echo '<empty>')"
fi

# SPEC-3: branch-push appears AFTER checkout-b in ORDER_LOG
_co_line="$(grep -n 'checkout-b' "$ORDER_LOG" 2>/dev/null | head -1 | cut -d: -f1 || true)"
_bp_line="$(grep -n 'branch-push' "$ORDER_LOG" 2>/dev/null | head -1 | cut -d: -f1 || true)"
if [[ -n "$_co_line" && -n "$_bp_line" && "$_co_line" -lt "$_bp_line" ]]; then
    assert_pass "[SPEC-3] ship pushes release branch after creating it (checkout-b before branch-push)"
else
    assert_fail "[SPEC-3] ship pushes release branch after creating it" \
        "ORDER_LOG: $(cat "$ORDER_LOG" 2>/dev/null || echo '<empty>') co=$_co_line bp=$_bp_line"
fi

# SPEC-4: pr-create appears AFTER branch-push in ORDER_LOG
_pc_line="$(grep -n 'pr-create' "$ORDER_LOG" 2>/dev/null | head -1 | cut -d: -f1 || true)"
if [[ -n "$_bp_line" && -n "$_pc_line" && "$_bp_line" -lt "$_pc_line" ]]; then
    assert_pass "[SPEC-4] ship opens PR after pushing branch (branch-push before pr-create)"
else
    assert_fail "[SPEC-4] ship opens PR after pushing branch" \
        "ORDER_LOG: $(cat "$ORDER_LOG" 2>/dev/null || echo '<empty>') bp=$_bp_line pc=$_pc_line"
fi

# SPEC-5: pr-checks appears AFTER pr-create in ORDER_LOG
_pch_line="$(grep -n 'pr-checks' "$ORDER_LOG" 2>/dev/null | head -1 | cut -d: -f1 || true)"
if [[ -n "$_pc_line" && -n "$_pch_line" && "$_pc_line" -lt "$_pch_line" ]]; then
    assert_pass "[SPEC-5] ship waits for checks after opening PR (pr-create before pr-checks)"
else
    assert_fail "[SPEC-5] ship waits for checks after opening PR" \
        "ORDER_LOG: $(cat "$ORDER_LOG" 2>/dev/null || echo '<empty>') pc=$_pc_line pch=$_pch_line"
fi

# SPEC-6: pr-merge appears AFTER pr-checks in ORDER_LOG
_pm_line="$(grep -n 'pr-merge' "$ORDER_LOG" 2>/dev/null | head -1 | cut -d: -f1 || true)"
if [[ -n "$_pch_line" && -n "$_pm_line" && "$_pch_line" -lt "$_pm_line" ]]; then
    assert_pass "[SPEC-6] ship merges after checks pass (pr-checks before pr-merge)"
else
    assert_fail "[SPEC-6] ship merges after checks pass" \
        "ORDER_LOG: $(cat "$ORDER_LOG" 2>/dev/null || echo '<empty>') pch=$_pch_line pm=$_pm_line"
fi

# SPEC-7: tag-a appears AFTER pr-merge in ORDER_LOG (publish runs post-merge)
_ta_line="$(grep -n 'tag-a' "$ORDER_LOG" 2>/dev/null | head -1 | cut -d: -f1 || true)"
if [[ -n "$_pm_line" && -n "$_ta_line" && "$_pm_line" -lt "$_ta_line" ]]; then
    assert_pass "[SPEC-7] ship publishes after merge (pr-merge before tag-a)"
else
    assert_fail "[SPEC-7] ship publishes after merge" \
        "ORDER_LOG: $(cat "$ORDER_LOG" 2>/dev/null || echo '<empty>') pm=$_pm_line ta=$_ta_line"
fi

# SPEC-8: gate ran — mock-lint-doc-style was called (not bypassed in ship mode)
if grep -q "lint-doc-style" "$DOC_STYLE_LOG" 2>/dev/null; then
    assert_pass "[SPEC-8] doc+coverage gate runs in ship mode (lint-doc-style called)"
else
    assert_fail "[SPEC-8] doc+coverage gate runs in ship mode (lint-doc-style called)" \
        "doc-style log: $(cat "$DOC_STYLE_LOG" 2>/dev/null || echo '<empty>')"
fi

# SPEC-9: version pinned — branch version matches tag version (no drift)
_branch_ver="$(grep 'checkout -b' "$GIT_CMD_LOG" 2>/dev/null | head -1 | sed 's|.*release/||' || true)"
_tag_ver="$(grep 'tag -a' "$GIT_TAG_LOG" 2>/dev/null | head -1 | awk '{print $4}' | sed 's/^v//' || true)"
if [[ -n "$_branch_ver" && -n "$_tag_ver" && "$_branch_ver" == "$_tag_ver" ]]; then
    assert_pass "[SPEC-9] version pinned: prepare branch version (${_branch_ver}) equals publish tag version (${_tag_ver})"
else
    assert_fail "[SPEC-9] version pinned: branch version '${_branch_ver}' must equal tag version '${_tag_ver}'"
fi

# ── T4: failing checks abort before publish (SPEC-10) ────────────────────────
_reset_logs
export MOCK_PR_CHECKS_FAIL=1
fail_rc=0
bash "$REPO_ROOT/scripts/release.sh" --ship --milestone "Initiative 1.1" >/dev/null 2>&1 \
    || fail_rc=$?
unset MOCK_PR_CHECKS_FAIL

if [[ "$fail_rc" -ne 0 ]]; then
    assert_pass "[SPEC-10] failing checks causes non-zero exit (rc=${fail_rc})"
else
    assert_fail "[SPEC-10] failing checks must cause non-zero exit" "got rc=0"
fi
if ! grep -q "tag-a" "$ORDER_LOG" 2>/dev/null; then
    assert_pass "[SPEC-10] no tag-a in ORDER_LOG when checks fail (publish aborted)"
else
    assert_fail "[SPEC-10] tag-a must NOT appear when checks fail" \
        "ORDER_LOG: $(cat "$ORDER_LOG" 2>/dev/null || echo '<empty>')"
fi
if ! grep -q "release-create" "$ORDER_LOG" 2>/dev/null; then
    assert_pass "[SPEC-10] no release-create in ORDER_LOG when checks fail"
else
    assert_fail "[SPEC-10] release-create must NOT appear when checks fail" \
        "ORDER_LOG: $(cat "$ORDER_LOG" 2>/dev/null || echo '<empty>')"
fi

# ── T5: --minor cadence (SPEC-11) ────────────────────────────────────────────
_reset_logs
minor_out="$(bash "$REPO_ROOT/scripts/release.sh" --ship --minor --milestone "Initiative 1.1" 2>&1)" \
    || { echo "$minor_out"; assert_fail "[SPEC-11] --ship --minor exits 0"; exit 1; }
if grep -qF "checkout -b release/1.1.0.0" "$GIT_CMD_LOG" 2>/dev/null; then
    assert_pass "[SPEC-11] --ship --minor produces minor version bump (branch release/1.1.0.0)"
else
    assert_fail "[SPEC-11] --ship --minor must produce branch release/1.1.0.0" \
        "git-cmd log: $(cat "$GIT_CMD_LOG" 2>/dev/null || echo '<empty>')"
fi

# ── T6: --major cadence with milestone mock (SPEC-12) ────────────────────────
_reset_logs
major_out="$(bash "$REPO_ROOT/scripts/release.sh" --ship --major --milestone "Initiative 2.0" 2>&1)" \
    || { echo "$major_out"; assert_fail "[SPEC-12] --ship --major exits 0"; exit 1; }
if grep -qF "checkout -b release/2.0.0.0" "$GIT_CMD_LOG" 2>/dev/null; then
    assert_pass "[SPEC-12] --ship --major with milestone mock produces major version bump (branch release/2.0.0.0)"
else
    assert_fail "[SPEC-12] --ship --major must produce branch release/2.0.0.0" \
        "git-cmd log: $(cat "$GIT_CMD_LOG" 2>/dev/null || echo '<empty>')"
fi

# ── T7: preflight clean-tree check runs BEFORE the VERSION/CHANGELOG stamp ────
# Regression for the dirty-tree ordering bug (#1498 review, HIGH): main() stamps
# VERSION before invoking _release_ship, so if the clean-tree preflight ran AFTER
# the stamp it would always observe a dirty tree and --ship could never proceed in
# a real repo (where VERSION is tracked). The diff mock reports "dirty" the instant
# the sandboxed VERSION file is stamped; ship must still succeed — proving the
# preflight runs before the stamp.
_reset_logs
unset MOCK_PR_CHECKS_FAIL 2>/dev/null || true
export MOCK_GIT_DIFF_DIRTY_IF_VERSION_STAMPED=1
order_rc=0
order_out="$(bash "$REPO_ROOT/scripts/release.sh" --ship --milestone "Initiative 1.1" 2>&1)" \
    || order_rc=$?
unset MOCK_GIT_DIFF_DIRTY_IF_VERSION_STAMPED
if [[ "$order_rc" -eq 0 ]]; then
    assert_pass "[ship-preflight-order] clean-tree preflight runs before the VERSION stamp (ship not falsely aborted as dirty)"
else
    assert_fail "[ship-preflight-order] preflight must run before the VERSION stamp" \
        "got rc=${order_rc} (falsely 'dirty'): ${order_out}"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
