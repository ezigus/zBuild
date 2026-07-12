#!/usr/bin/env bash
# tests/integration/release-sh-cadence-test.sh — SPEC-1 through SPEC-9
# Behavioral coverage for the cadence flags + PR workflow added by #1355 (REL-B1).
#
# SPEC-1:  --patch dry-run prints "cadence: patch"
# SPEC-2:  --minor dry-run prints "cadence: minor" + version 1.1.0.5
# SPEC-3:  --major dry-run prints "cadence: major" + version 2.0.0.5
# SPEC-4:  combining two cadence flags exits rc=2
# SPEC-5:  non-dry-run writes the VERSION file (ZBUILD_RELEASE_VERSION_FILE seam)
# SPEC-6:  non-dry-run calls gh pr create (mocked git + gh, no ZBUILD_RELEASE_NO_PUSH)
# SPEC-7:  PR title in gh pr create call contains "Release v..."
# SPEC-8:  dry-run prints "planned pr title: Release v..."
# SPEC-9:  _release_on_merge_hook function is defined in release.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "release.sh cadence flags + PR workflow (#1355 REL-B1)"
setup_test_env "release-sh-cadence"

# ─── Shared env seams: deterministic version + repo slug ─────────────────────
export ZBUILD_RELEASE_REPO="ezigus/zBuild"
export ZBUILD_VERSION_ANCHOR="1.0"
export ZBUILD_VERSION_RELEASE_COUNT="1"
export ZBUILD_RELEASE_SINCE="2026-07-04T00:00:00Z"
export ZBUILD_RELEASE_LAST_TAG="v1.0.0"

# 5 closed issues in-window → D=5 → patch=1.0.1.5, minor=1.1.0.5, major=2.0.0.5
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
cat > "$MOCK_PR_LIST_JSON" <<'EOF'
[
  {"number":201,"title":"feat: wire release subcommand","labels":[{"name":"enhancement"}],"mergedAt":"2026-07-06T11:00:00Z"}
]
EOF

# ─── Base gh mock: handles issue list / pr list / repo view / pr create ───────
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
    "issue list")  _emit "${MOCK_ISSUE_LIST_JSON:-/dev/null}"; exit 0 ;;
    "pr list")     _emit "${MOCK_PR_LIST_JSON:-/dev/null}"; exit 0 ;;
    "pr create")   echo "https://github.com/ezigus/zBuild/pull/999"; exit 0 ;;
    *) echo "[mock-gh] unhandled: $*" >&2; exit 1 ;;
esac
'

# ─── Git mock: log all calls and succeed (used for PR workflow SPECs) ─────────
mock_binary "git" '
GIT_CALLS_LOG="'"$TEST_TEMP_DIR"'/git-calls.log"
echo "git $*" >> "$GIT_CALLS_LOG"
exit 0
'

# ─── SPEC-1: --patch dry-run prints cadence label ────────────────────────────
out_patch="$(bash "$REPO_ROOT/scripts/release.sh" --dry-run --patch --milestone "Initiative 1.1" 2>&1)" \
    || { echo "$out_patch"; assert_fail "[SPEC-1] --patch dry-run exits 0"; exit 1; }
assert_contains "[SPEC-1] --patch dry-run prints cadence: patch" "$out_patch" "cadence:         patch"
assert_contains "[SPEC-1] --patch version is 1.0.1.5 (D=5)" "$out_patch" "planned version: 1.0.1.5"

# ─── SPEC-2: --minor dry-run prints cadence label + bumped version ────────────
out_minor="$(bash "$REPO_ROOT/scripts/release.sh" --dry-run --minor --milestone "Initiative 1.1" 2>&1)" \
    || { echo "$out_minor"; assert_fail "[SPEC-2] --minor dry-run exits 0"; exit 1; }
assert_contains "[SPEC-2] --minor dry-run prints cadence: minor" "$out_minor" "cadence:         minor"
assert_contains "[SPEC-2] --minor version bumps B → 1.1.0.5" "$out_minor" "planned version: 1.1.0.5"

# ─── SPEC-3: --major dry-run prints cadence label + bumped version ────────────
out_major="$(bash "$REPO_ROOT/scripts/release.sh" --dry-run --major --milestone "Initiative 1.1" 2>&1)" \
    || { echo "$out_major"; assert_fail "[SPEC-3] --major dry-run exits 0"; exit 1; }
assert_contains "[SPEC-3] --major dry-run prints cadence: major" "$out_major" "cadence:         major"
assert_contains "[SPEC-3] --major version bumps A → 2.0.0.5" "$out_major" "planned version: 2.0.0.5"

# ─── SPEC-4: combining two cadence flags exits rc=2 ──────────────────────────
rc_two_flags=0
bash "$REPO_ROOT/scripts/release.sh" --patch --minor --dry-run 2>/dev/null || rc_two_flags=$?
assert_eq "[SPEC-4] --patch --minor exits rc=2" "2" "$rc_two_flags"

rc_two_flags2=0
bash "$REPO_ROOT/scripts/release.sh" --minor --major --dry-run 2>/dev/null || rc_two_flags2=$?
assert_eq "[SPEC-4] --minor --major exits rc=2" "2" "$rc_two_flags2"

# ─── SPEC-5: non-dry-run writes VERSION file ─────────────────────────────────
# Use ZBUILD_RELEASE_NO_PUSH to skip git push + gh pr create.
# Use ZBUILD_RELEASE_VERSION_FILE to sandbox the VERSION write.
# Use ZBUILD_RELEASE_CHANGELOG to sandbox the CHANGELOG write.
sandbox_version_file="$TEST_TEMP_DIR/sandbox-VERSION"
sandbox_changelog="$TEST_TEMP_DIR/sandbox-CHANGELOG.md"
cp "$REPO_ROOT/CHANGELOG.md" "$sandbox_changelog"

ZBUILD_RELEASE_NO_PUSH=1 \
ZBUILD_RELEASE_VERSION_FILE="$sandbox_version_file" \
ZBUILD_RELEASE_CHANGELOG="$sandbox_changelog" \
    bash "$REPO_ROOT/scripts/release.sh" --patch --force --milestone "Initiative 1.1" >/dev/null 2>&1
assert_file_exists "[SPEC-5] VERSION file written by non-dry-run" "$sandbox_version_file"
written_version="$(<"$sandbox_version_file")"
assert_eq "[SPEC-5] VERSION file contains computed version 1.0.1.5" "1.0.1.5" "${written_version%$'\n'}"

# ─── SPEC-6/7: non-dry-run calls gh pr create with expected title ─────────────
# Mock git + gh already installed. Run without ZBUILD_RELEASE_NO_PUSH.
sandbox_version_file2="$TEST_TEMP_DIR/sandbox-VERSION-2"
sandbox_changelog2="$TEST_TEMP_DIR/sandbox-CHANGELOG-2.md"
cp "$REPO_ROOT/CHANGELOG.md" "$sandbox_changelog2"
rm -f "$TEST_TEMP_DIR/gh-calls.log"

ZBUILD_RELEASE_VERSION_FILE="$sandbox_version_file2" \
ZBUILD_RELEASE_CHANGELOG="$sandbox_changelog2" \
    bash "$REPO_ROOT/scripts/release.sh" --patch --force --milestone "Initiative 1.1" >/dev/null 2>&1

gh_log="$TEST_TEMP_DIR/gh-calls.log"
if [[ -f "$gh_log" ]] && /usr/bin/grep -q "pr create" "$gh_log"; then
    assert_pass "[SPEC-6] non-dry-run calls gh pr create"
else
    assert_fail "[SPEC-6] non-dry-run did not call gh pr create" "log: $(cat "$gh_log" 2>/dev/null || echo '(empty)')"
fi

if [[ -f "$gh_log" ]] && /usr/bin/grep -q "Release v1.0.1.5" "$gh_log"; then
    assert_pass "[SPEC-7] PR title contains Release v1.0.1.5"
else
    assert_fail "[SPEC-7] PR title missing 'Release v1.0.1.5'" "log: $(cat "$gh_log" 2>/dev/null || echo '(empty)')"
fi

# ─── SPEC-8: dry-run prints planned pr title ─────────────────────────────────
out_dry="$(bash "$REPO_ROOT/scripts/release.sh" --dry-run --patch --milestone "Initiative 1.1" 2>&1)"
assert_contains "[SPEC-8] dry-run prints 'planned pr title: Release v1.0.1.5'" \
    "$out_dry" "planned pr title: Release v1.0.1.5"

# ─── SPEC-9: _release_on_merge_hook function defined in release.sh ────────────
if /usr/bin/grep -q '_release_on_merge_hook()' "$REPO_ROOT/scripts/release.sh"; then
    assert_pass "[SPEC-9] _release_on_merge_hook function defined in release.sh"
else
    assert_fail "[SPEC-9] _release_on_merge_hook function not found in release.sh"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
