#!/usr/bin/env bash
# tests/integration/release-sh-cadence-test.sh
# Behavioral coverage for the cadence flags + VERSION stamp added by #1355 (REL-B1).
# The direct-apply publish path (tarball/tag/publish) is #1412's — covered by
# release-sh-test.sh; #1355's original PR-branch flow was superseded by #1412 and
# dropped, so no PR-workflow assertions live here.
#
# SPEC-1:  --patch dry-run prints "cadence: patch" + version 1.0.1.5
# SPEC-2:  --minor dry-run prints "cadence: minor" + version 1.1.0.0 (z reset to 0)
# SPEC-3:  --major dry-run prints "cadence: major" + version 2.0.0.0 (z reset to 0)
# SPEC-4:  combining two cadence flags exits rc=2
# SPEC-5:  non-dry-run writes the VERSION file (ZBUILD_RELEASE_VERSION_FILE seam)
# SPEC-6:  dry-run announces the planned VERSION stamp but MUTATES NOTHING
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

# ─── Base gh mock: serves the issue/PR data the notes generator reads ─────────
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
    *) echo "[mock-gh] unhandled: $*" >&2; exit 1 ;;
esac
'

# ─── Git mock: log calls and succeed. build_release_tarball probes `git config`
#     for the repo slug; the non-dry-run tag+publish self-skips under NO_GITHUB. ─
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
assert_contains "[SPEC-2] --minor version bumps B, resets z → 1.1.0.0" "$out_minor" "planned version: 1.1.0.0"

# ─── SPEC-3: --major dry-run prints cadence label + bumped version ────────────
out_major="$(bash "$REPO_ROOT/scripts/release.sh" --dry-run --major --milestone "Initiative 1.1" 2>&1)" \
    || { echo "$out_major"; assert_fail "[SPEC-3] --major dry-run exits 0"; exit 1; }
assert_contains "[SPEC-3] --major dry-run prints cadence: major" "$out_major" "cadence:         major"
assert_contains "[SPEC-3] --major version bumps A, resets z → 2.0.0.0" "$out_major" "planned version: 2.0.0.0"

# ─── SPEC-4: combining two cadence flags exits rc=2 ──────────────────────────
rc_two_flags=0
bash "$REPO_ROOT/scripts/release.sh" --patch --minor --dry-run 2>/dev/null || rc_two_flags=$?
assert_eq "[SPEC-4] --patch --minor exits rc=2" "2" "$rc_two_flags"

rc_two_flags2=0
bash "$REPO_ROOT/scripts/release.sh" --minor --major --dry-run 2>/dev/null || rc_two_flags2=$?
assert_eq "[SPEC-4] --minor --major exits rc=2" "2" "$rc_two_flags2"

# ─── SPEC-5: non-dry-run writes VERSION file ─────────────────────────────────
# ZBUILD_RELEASE_VERSION_FILE sandboxes the VERSION stamp; ZBUILD_RELEASE_CHANGELOG
# sandboxes the CHANGELOG prepend. --force skips the doc/coverage gate; the
# tag+publish step self-skips under NO_GITHUB=true (setup_test_env).
sandbox_version_file="$TEST_TEMP_DIR/sandbox-VERSION"
sandbox_changelog="$TEST_TEMP_DIR/sandbox-CHANGELOG.md"
cp "$REPO_ROOT/CHANGELOG.md" "$sandbox_changelog"

ZBUILD_RELEASE_VERSION_FILE="$sandbox_version_file" \
ZBUILD_RELEASE_CHANGELOG="$sandbox_changelog" \
    bash "$REPO_ROOT/scripts/release.sh" --patch --force --milestone "Initiative 1.1" >/dev/null 2>&1
assert_file_exists "[SPEC-5] VERSION file written by non-dry-run" "$sandbox_version_file"
written_version="$(<"$sandbox_version_file")"
assert_eq "[SPEC-5] VERSION file contains computed version 1.0.1.5" "1.0.1.5" "${written_version%$'\n'}"

# ─── SPEC-6: dry-run announces the planned VERSION stamp but MUTATES NOTHING ──
# The dry-run must report the version it WOULD stamp, and must NOT create the
# VERSION file (point the seam at a non-existent path and assert it stays absent).
dryrun_version_file="$TEST_TEMP_DIR/should-not-be-written-VERSION"
out_dry="$(ZBUILD_RELEASE_VERSION_FILE="$dryrun_version_file" \
    bash "$REPO_ROOT/scripts/release.sh" --dry-run --patch --milestone "Initiative 1.1" 2>&1)"
assert_contains "[SPEC-6] dry-run announces planned VERSION stamp ← 1.0.1.5" \
    "$out_dry" "planned version-stamp: VERSION ← 1.0.1.5"
if [[ -e "$dryrun_version_file" ]]; then
    assert_fail "[SPEC-6] dry-run must NOT write the VERSION file"
else
    assert_pass "[SPEC-6] dry-run leaves the VERSION file unwritten"
fi

# ─── SPEC-9: _release_on_merge_hook function defined in release.sh ────────────
if /usr/bin/grep -q '_release_on_merge_hook()' "$REPO_ROOT/scripts/release.sh"; then
    assert_pass "[SPEC-9] _release_on_merge_hook function defined in release.sh"
else
    assert_fail "[SPEC-9] _release_on_merge_hook function not found in release.sh"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
