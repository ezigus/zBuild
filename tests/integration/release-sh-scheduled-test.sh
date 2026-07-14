#!/usr/bin/env bash
# tests/integration/release-sh-scheduled-test.sh
# Behavioral coverage for the scheduled-release additions (REL-F #1357):
#   --skip-if-no-issues flag in release.sh and the scheduled workflow yml.
#
# SPEC-1: --skip-if-no-issues exits rc=0 when D=0 (no closed issues)
# SPEC-2: --skip-if-no-issues prints a structured skip notice when D=0
# SPEC-3: --skip-if-no-issues does NOT skip when D>0
# SPEC-4: --dry-run + --skip-if-no-issues with D=0: skip wins (exits 0, no planned-version output)
# SPEC-5: --dry-run + --skip-if-no-issues with D>0: dry-run executes (prints planned version)
# SPEC-6: --skip-if-no-issues with D>0 does NOT print the skip notice
# SPEC-7: scheduled workflow yml exists with a schedule cron trigger (Monday default)
# SPEC-8: scheduled workflow yml contains the fork guard for ezigus/zBuild
# SPEC-9:  cron converges on the shared flow — dispatches release.yml (#1491)
# SPEC-10: cron no longer cuts a release directly (no release.sh call) (#1491)
# SPEC-11: dispatch passes skip_if_no_issues=true + auto_merge=true (#1491)
# SPEC-12: release.yml accepts 'patch' cadence + a skip_if_no_issues input (#1491)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "release.sh --skip-if-no-issues + scheduled workflow (REL-F #1357)"
setup_test_env "release-sh-scheduled"

# ─── Shared env seams ─────────────────────────────────────────────────────────
export ZBUILD_RELEASE_REPO="ezigus/zBuild"
export ZBUILD_VERSION_ANCHOR="1.0"
export ZBUILD_VERSION_RELEASE_COUNT="1"
export ZBUILD_RELEASE_SINCE="2026-07-04T00:00:00Z"
export ZBUILD_RELEASE_LAST_TAG="v1.0.0"
# Suppress noisy stderr from the DOC-F dry-run preview added by #1466.
export ZBUILD_WIKI_REMOTE="https://example.com/fake.wiki.git"

# ─── Mock fixtures ────────────────────────────────────────────────────────────
EMPTY_ISSUES_JSON="$TEST_TEMP_DIR/empty-issues.json"
printf '[]' > "$EMPTY_ISSUES_JSON"

HAS_ISSUES_JSON="$TEST_TEMP_DIR/has-issues.json"
cat > "$HAS_ISSUES_JSON" <<'EOF'
[
  {"number":101,"title":"add scheduled release workflow","labels":[{"name":"enhancement"}],"closedAt":"2026-07-05T10:00:00Z"},
  {"number":102,"title":"add --skip-if-no-issues flag","labels":[{"name":"enhancement"}],"closedAt":"2026-07-06T10:00:00Z"},
  {"number":103,"title":"write REL-F integration tests","labels":[{"name":"testing"}],"closedAt":"2026-07-07T10:00:00Z"}
]
EOF

EMPTY_PRS_JSON="$TEST_TEMP_DIR/empty-prs.json"
printf '[]' > "$EMPTY_PRS_JSON"

# Build a gh mock that can serve either issue fixture via MOCK_ISSUE_LIST_JSON.
# The fixture path is baked at mock-creation time using the env at that point.
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
    "repo view")   echo "ezigus/zBuild"; exit 0 ;;
    "issue list")  _emit "${MOCK_ISSUE_LIST_JSON:-'"$EMPTY_ISSUES_JSON"'}"; exit 0 ;;
    "pr list")     _emit "${MOCK_PR_LIST_JSON:-'"$EMPTY_PRS_JSON"'}"; exit 0 ;;
    *) echo "[mock-gh] unhandled: $*" >&2; exit 1 ;;
esac
'

mock_binary "git" '
GIT_CALLS_LOG="'"$TEST_TEMP_DIR"'/git-calls.log"
echo "git $*" >> "$GIT_CALLS_LOG"
exit 0
'

# ─── SPEC-1: --skip-if-no-issues exits rc=0 when D=0 ─────────────────────────
rc_skip=0
out_skip="$(MOCK_ISSUE_LIST_JSON="$EMPTY_ISSUES_JSON" \
    bash "$REPO_ROOT/scripts/release.sh" --patch --skip-if-no-issues 2>&1)" \
    || rc_skip=$?
assert_eq "[SPEC-1] --skip-if-no-issues exits rc=0 when D=0" "0" "$rc_skip"

# ─── SPEC-2: --skip-if-no-issues prints a structured skip notice when D=0 ─────
assert_contains "[SPEC-2] --skip-if-no-issues prints skip notice when D=0" \
    "$out_skip" "no issues closed since last release"

# ─── SPEC-3: --skip-if-no-issues does NOT skip when D>0 ──────────────────────
# --force skips the doc/coverage gate; NO_GITHUB=true (from setup_test_env)
# skips git tag + publish. The VERSION file being written proves we didn't exit
# at the skip gate.
sandbox_version_file="$TEST_TEMP_DIR/sandbox-VERSION-spec3"
sandbox_changelog="$TEST_TEMP_DIR/sandbox-CHANGELOG-spec3.md"
cp "$REPO_ROOT/CHANGELOG.md" "$sandbox_changelog"

rc_no_skip=0
out_no_skip="$(MOCK_ISSUE_LIST_JSON="$HAS_ISSUES_JSON" \
    ZBUILD_RELEASE_VERSION_FILE="$sandbox_version_file" \
    ZBUILD_RELEASE_CHANGELOG="$sandbox_changelog" \
    bash "$REPO_ROOT/scripts/release.sh" --patch --skip-if-no-issues --force 2>&1)" \
    || rc_no_skip=$?
assert_eq "[SPEC-3] --skip-if-no-issues does NOT skip when D>0 (rc=0)" "0" "$rc_no_skip"
assert_file_exists "[SPEC-3] VERSION file written — release proceeded, not skipped" \
    "$sandbox_version_file"

# ─── SPEC-4: --dry-run + --skip-if-no-issues with D=0: skip wins ─────────────
rc_dry_skip=0
out_dry_skip="$(MOCK_ISSUE_LIST_JSON="$EMPTY_ISSUES_JSON" \
    bash "$REPO_ROOT/scripts/release.sh" --dry-run --patch --skip-if-no-issues 2>&1)" \
    || rc_dry_skip=$?
assert_eq "[SPEC-4] dry-run + --skip-if-no-issues D=0: exits rc=0 (skip wins)" "0" "$rc_dry_skip"
assert_contains "[SPEC-4] dry-run + --skip-if-no-issues D=0: prints skip notice" \
    "$out_dry_skip" "no issues closed since last release"
if grep -q "planned version:" <<< "$out_dry_skip"; then
    assert_fail "[SPEC-4] dry-run + --skip-if-no-issues D=0: must NOT print 'planned version'"
else
    assert_pass "[SPEC-4] dry-run + --skip-if-no-issues D=0: 'planned version' absent (skip gate fired first)"
fi

# ─── SPEC-5: --dry-run + --skip-if-no-issues with D>0: dry-run executes ───────
rc_dry_run=0
out_dry_run="$(MOCK_ISSUE_LIST_JSON="$HAS_ISSUES_JSON" \
    bash "$REPO_ROOT/scripts/release.sh" --dry-run --patch --skip-if-no-issues 2>&1)" \
    || rc_dry_run=$?
assert_eq "[SPEC-5] dry-run + --skip-if-no-issues D>0: exits rc=0" "0" "$rc_dry_run"
assert_contains "[SPEC-5] dry-run + --skip-if-no-issues D>0: prints planned version" \
    "$out_dry_run" "planned version:"

# ─── SPEC-6: --skip-if-no-issues with D>0 does NOT print the skip notice ──────
# Match the exact skip-notice phrase; avoid false-positive on "--skip-if-no-issues"
# appearing in issue titles inside the release notes.
if grep -qi "skip — no issues\|no issues closed since last release" <<< "$out_dry_run"; then
    assert_fail "[SPEC-6] D>0: must NOT print the skip-if-no-issues notice"
else
    assert_pass "[SPEC-6] D>0: skip notice absent (only fires when D=0)"
fi

# ─── SPEC-7: scheduled workflow yml exists with a schedule/cron trigger ────────
WORKFLOW_YML="$REPO_ROOT/.github/workflows/zbuild-release-scheduled.yml"
if [[ -f "$WORKFLOW_YML" ]]; then
    assert_pass "[SPEC-7] zbuild-release-scheduled.yml exists"
else
    assert_fail "[SPEC-7] zbuild-release-scheduled.yml not found"
fi

if /usr/bin/grep -q "schedule:" "$WORKFLOW_YML" && /usr/bin/grep -q "cron:" "$WORKFLOW_YML"; then
    assert_pass "[SPEC-7] workflow yml contains schedule/cron trigger"
else
    assert_fail "[SPEC-7] workflow yml missing schedule/cron trigger"
fi

# Day-of-week=1 (Monday) must appear as the 5th field in the cron string
if /usr/bin/grep -E "cron:.*\* 1['\"]" "$WORKFLOW_YML" >/dev/null 2>&1; then
    assert_pass "[SPEC-7] workflow defaults to Monday (DOW=1) in cron expression"
else
    assert_fail "[SPEC-7] workflow cron does not default to Monday (DOW=1)"
fi

# ─── SPEC-8: scheduled workflow yml contains the fork guard ───────────────────
if /usr/bin/grep -q "ezigus/zBuild" "$WORKFLOW_YML"; then
    assert_pass "[SPEC-8] workflow yml contains fork guard referencing ezigus/zBuild"
else
    assert_fail "[SPEC-8] workflow yml missing fork guard (github.repository == 'ezigus/zBuild')"
fi

# ─── SPEC-9: cron CONVERGES on the shared flow — dispatches release.yml (#1491) ─
# The weekly cron must trigger the ONE shared branch→PR→publish flow, not a
# separate direct cut. Assert it dispatches release.yml via `gh workflow run`.
if /usr/bin/grep -Eq "gh workflow run[[:space:]]+release\.yml" "$WORKFLOW_YML"; then
    assert_pass "[SPEC-9] scheduled workflow dispatches the shared release.yml flow"
else
    assert_fail "[SPEC-9] scheduled workflow does not dispatch release.yml (gh workflow run release.yml)"
fi

# ─── SPEC-10: cron NO LONGER cuts a release directly (#1491) ──────────────────
# The old divergence was `bash scripts/release.sh --patch …` in the job itself
# (tags+publishes with no PR, drops the VERSION commit). That direct call must be
# gone — the flow is owned by release.yml now.
if /usr/bin/grep -Eq "release\.sh" "$WORKFLOW_YML"; then
    assert_fail "[SPEC-10] scheduled workflow still calls release.sh directly (must dispatch release.yml instead)"
else
    assert_pass "[SPEC-10] scheduled workflow no longer cuts a release directly (no release.sh call)"
fi

# ─── SPEC-11: cron dispatch preserves the empty-week no-op + auto-merge (#1491) ─
# skip_if_no_issues=true keeps empty weeks a no-op through the shared flow;
# auto_merge=true lets the Release PR merge on green so publish runs on merge.
if /usr/bin/grep -q "skip_if_no_issues=true" "$WORKFLOW_YML"; then
    assert_pass "[SPEC-11a] dispatch passes skip_if_no_issues=true (empty weeks no-op)"
else
    assert_fail "[SPEC-11a] dispatch missing skip_if_no_issues=true (empty weeks would cut a PR)"
fi
if /usr/bin/grep -q "auto_merge=true" "$WORKFLOW_YML"; then
    assert_pass "[SPEC-11b] dispatch passes auto_merge=true (PR merges on green → publish)"
else
    assert_fail "[SPEC-11b] dispatch missing auto_merge=true (Release PR would stall unmerged)"
fi

# ─── SPEC-12: release.yml accepts 'patch' cadence + a skip_if_no_issues input ──
# The cron cuts patch releases and needs the skip passthrough, so the shared flow
# must accept both — otherwise the dispatch above is rejected at the enum.
RELEASE_YML="$REPO_ROOT/.github/workflows/release.yml"
if /usr/bin/grep -Eq "^[[:space:]]*-[[:space:]]*patch[[:space:]]*$" "$RELEASE_YML"; then
    assert_pass "[SPEC-12a] release.yml cadence enum includes 'patch'"
else
    assert_fail "[SPEC-12a] release.yml cadence enum missing 'patch' (cron dispatch would be rejected)"
fi
if /usr/bin/grep -q "skip_if_no_issues:" "$RELEASE_YML"; then
    assert_pass "[SPEC-12b] release.yml declares the skip_if_no_issues input"
else
    assert_fail "[SPEC-12b] release.yml missing skip_if_no_issues input"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
