#!/usr/bin/env bash
# tests/integration/release-sh-ship-idempotent-test.sh
# Acceptance tests for _release_ship idempotent re-run / resume detection (#1500).
#
# SPEC-13: PR-exists resume: exit 0; no checkout-b or pr-create; pr-checks→pr-merge→tag-a in order
# SPEC-14: Branch-exists-no-PR resume: exit 0; no checkout-b; pr-create appears
# SPEC-15: Preflight accepts HEAD on release/* branch (not only main)
# SPEC-16: Resume info log emitted when steps are skipped
# SPEC-17: Pre-stamped changelog: exactly one ## [<version>] section after a resume (#1601)
# SPEC-18: Pre-stamped changelog: no additional ## [ lines inserted
# SPEC-19: Pre-stamped-changelog resume exits 0
# SPEC-20: Guard fires audibly — logs the skip, suppresses the false "updated" line
# SPEC-21: Prose reference to a version does not suppress the prepend (anchored match)
# SPEC-22: Resume from main discards redundant stamps before the post-merge checkout
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
        if [[ "${2:-}" == "--" ]]; then printf "checkout-discard\n" >> "$ORDER_LOG"; fi
        if [[ "${2:-}" == "main" ]]; then printf "checkout-main\n" >> "$ORDER_LOG"; fi
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

if ! grep -q "branch-push" "$ORDER_LOG" 2>/dev/null; then
    assert_pass "[SPEC-14] branch-push NOT in ORDER_LOG (step 2 also skipped when branch already at origin)"
else
    assert_fail "[SPEC-14] branch-push must NOT appear when branch already at origin" \
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
if grep -q "resuming from step" <<< "$spec16_out"; then
    assert_pass "[SPEC-16] 'resuming from step' info log emitted when steps are skipped"
else
    assert_fail "[SPEC-16] 'resuming from step' must appear in output when steps are skipped" \
        "output: ${spec16_out}"
fi

# ── T5: Pre-stamped changelog idempotency — PR-exists resume (SPEC-17, SPEC-18) ─
# Pre-stamp sandbox_changelog with the version section that --ship would insert.
# Without the idempotency guard, a second run inserts a duplicate section — this
# is the root cause of the post-merge `git checkout main` failure (#1601).
_reset_logs
export MOCK_GIT_LSREMOTE_BRANCH_EXISTS=1
printf '[{"number":999,"url":"https://github.com/ezigus/zBuild/pull/999"}]\n' \
    > "$MOCK_PR_LIST_JSON"

# Baseline ## [ count in the freshly-reset changelog (before pre-stamping).
# NOTE: `grep -c` prints 0 AND exits 1 on no-match, so `|| echo 0` would emit "0\n0"
# and break the arithmetic below. Assign the fallback instead of echoing it.
_pre_stamp_section_count="$(grep -c '^## \[' "$sandbox_changelog" 2>/dev/null)" \
    || _pre_stamp_section_count=0

# Prepend the version header that _release_prepend_changelog would have written
# on the first run, simulating a resume where the section is already present.
# Mirrors the real header shape (version + em-dash date), not a synthetic suffix.
{ printf '## [1.0.1.5] — 2026-07-04\n\n### Added\n\n- pre-existing stamp from the first ship run\n\n'; cat "$sandbox_changelog"; } \
    > "$TEST_TEMP_DIR/changelog_prestamped.md"
cp "$TEST_TEMP_DIR/changelog_prestamped.md" "$sandbox_changelog"

spec1718_rc=0
spec1718_out="$(bash "$REPO_ROOT/scripts/release.sh" --ship --milestone "Initiative 1.1" 2>&1)" \
    || spec1718_rc=$?

_version_count="$(grep -c '^## \[1\.0\.1\.5\]' "$sandbox_changelog" 2>/dev/null)" \
    || _version_count=0
if [[ "$_version_count" -eq 1 ]]; then
    assert_pass "[SPEC-17] changelog has exactly one ## [1.0.1.5] entry after --ship resume re-run (no duplicate)"
else
    assert_fail "[SPEC-17] changelog must have exactly one ## [1.0.1.5] after resume re-run (found ${_version_count})" \
        "changelog head: $(head -20 "$sandbox_changelog" 2>/dev/null)"
fi

_after_section_count="$(grep -c '^## \[' "$sandbox_changelog" 2>/dev/null)" \
    || _after_section_count=0
if [[ "$_after_section_count" -eq $(( _pre_stamp_section_count + 1 )) ]]; then
    assert_pass "[SPEC-18] no additional ## [ lines inserted on idempotent resume"
else
    assert_fail "[SPEC-18] ## [ count must be pre-stamp+1 after idempotent resume (pre-stamp=${_pre_stamp_section_count} after=${_after_section_count})" \
        "expected $(( _pre_stamp_section_count + 1 )) sections, got ${_after_section_count}"
fi

# rc was previously only interpolated into SPEC-18's message, never asserted — a
# non-zero resume could ship a false green. Assert it.
if [[ "$spec1718_rc" -eq 0 ]]; then
    assert_pass "[SPEC-19] --ship resume with a pre-stamped changelog exits 0 (merge→tag→publish completed)"
else
    assert_fail "[SPEC-19] --ship resume with a pre-stamped changelog must exit 0 (rc=${spec1718_rc})" \
        "output: ${spec1718_out}"
fi

# Guards against a vacuous SPEC-17: if the computed version ever drifted off
# 1.0.1.5 the guard would never fire, yet SPEC-17's literal count would still hold.
# Assert the skip actually happened, and that no false "updated" line was printed.
if grep -q "prepend skipped (idempotent re-run)" <<< "$spec1718_out" \
   && ! grep -q "CHANGELOG.md updated for" <<< "$spec1718_out"; then
    assert_pass "[SPEC-20] guard fired: 'prepend skipped' logged and no false 'CHANGELOG.md updated' line"
else
    assert_fail "[SPEC-20] resume must log the idempotent skip and must NOT claim 'CHANGELOG.md updated'" \
        "output: ${spec1718_out}"
fi

# ── T6: prose mention must NOT suppress a legitimate prepend (SPEC-21) ────────
# An unanchored substring guard false-positives on body prose that references a
# version, silently skipping the real section. The guard is anchored at line start.
_reset_logs
export MOCK_GIT_LSREMOTE_BRANCH_EXISTS=1
printf '[{"number":999,"url":"https://github.com/ezigus/zBuild/pull/999"}]\n' \
    > "$MOCK_PR_LIST_JSON"

{ printf -- '- backport note: see ## [1.0.1.5] for details\n\n'; cat "$sandbox_changelog"; } \
    > "$TEST_TEMP_DIR/changelog_prose.md"
cp "$TEST_TEMP_DIR/changelog_prose.md" "$sandbox_changelog"

spec21_rc=0
spec21_out="$(bash "$REPO_ROOT/scripts/release.sh" --ship --milestone "Initiative 1.1" 2>&1)" \
    || spec21_rc=$?

_prose_section_count="$(grep -c '^## \[1\.0\.1\.5\]' "$sandbox_changelog" 2>/dev/null)" \
    || _prose_section_count=0
if [[ "$spec21_rc" -eq 0 && "$_prose_section_count" -eq 1 ]]; then
    assert_pass "[SPEC-21] prose reference to ## [1.0.1.5] does not suppress the prepend (anchored match)"
else
    assert_fail "[SPEC-21] a prose-only mention must not skip the prepend (rc=${spec21_rc} sections=${_prose_section_count})" \
        "output: ${spec21_out}"
fi

# ── T7: resume from main discards redundant stamps before the merge sync (SPEC-22) ─
# HEAD is main (mock default) with no pre-stamped section, so the idempotency guard
# CANNOT fire and main()'s pre-split body dirties the tree. Step 6 must discard those
# redundant stamps before switching/pulling, or the post-merge sync fails (#1601).
_reset_logs
export MOCK_GIT_LSREMOTE_BRANCH_EXISTS=1
printf '[{"number":999,"url":"https://github.com/ezigus/zBuild/pull/999"}]\n' \
    > "$MOCK_PR_LIST_JSON"

spec22_rc=0
spec22_out="$(bash "$REPO_ROOT/scripts/release.sh" --ship --milestone "Initiative 1.1" 2>&1)" \
    || spec22_rc=$?

_cd_line="$(grep -n 'checkout-discard' "$ORDER_LOG" 2>/dev/null | head -1 | cut -d: -f1 || true)"
_cm_line="$(grep -n 'checkout-main' "$ORDER_LOG" 2>/dev/null | head -1 | cut -d: -f1 || true)"
if [[ "$spec22_rc" -eq 0 && -n "$_cd_line" && -n "$_cm_line" && "$_cd_line" -lt "$_cm_line" ]]; then
    assert_pass "[SPEC-22] resume-from-main discards redundant CHANGELOG/VERSION stamps before checkout main"
else
    assert_fail "[SPEC-22] checkout-discard must precede checkout-main on a resume (rc=${spec22_rc} discard=${_cd_line} main=${_cm_line})" \
        "ORDER_LOG: $(cat "$ORDER_LOG" 2>/dev/null || echo '<empty>')"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
