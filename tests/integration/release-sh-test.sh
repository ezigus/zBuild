#!/usr/bin/env bash
# Tests: scripts/release.sh + scripts/lib/release-notes.sh (REL-B, #874) with
# mocked gh + git seams.
#
# Behavioral coverage for the DoD:
# - --dry-run prints the right version + grouped, per-issue, linked notes and
#   MUTATES NOTHING (idempotent — a sandbox CHANGELOG is byte-identical after).
# - Notes cover every closed issue in the milestone, grouped feat/fix/docs/adr/safety.
# - First-release anchoring on v1.0.0 works; genesis (no tag) fallback works.
# - The plug-and-play versioning note is present (issue #874 requirement).
# - `zbuild release --dry-run` dispatch forwards to release.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "release.sh — per-issue notes + CHANGELOG generator (REL-B / #874)"
setup_test_env "release-sh"

# ─── Mock gh: serves closed issues + merged PRs from fixture env vars ────────
mock_binary "gh" '
GH_CALLS_LOG="${GH_CALLS_LOG:-'"$TEST_TEMP_DIR"'/gh-calls.log}"
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
    "repo view")  echo "ezigus/zBuild"; exit 0 ;;
    "issue list") _emit "${MOCK_ISSUE_LIST_JSON:-/dev/null}"; exit 0 ;;
    "pr list")    _emit "${MOCK_PR_LIST_JSON:-/dev/null}"; exit 0 ;;
    *) echo "[mock-gh] unhandled: $*" >&2; exit 1 ;;
esac
'

# Deterministic version + repo slug: use the REL-A env seams so no real git/tag
# history is needed. Anchor 1.0, release-count 1; D comes from the issue count.
export ZBUILD_RELEASE_REPO="ezigus/zBuild"
export ZBUILD_VERSION_ANCHOR="1.0"
export ZBUILD_VERSION_RELEASE_COUNT="1"

# Closed issues in the milestone: one per group (feat/fix/docs/adr/safety).
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

# ─── T1: first-release dry-run — version + grouped, linked, per-issue notes ──
export ZBUILD_RELEASE_LAST_TAG="v1.0.0"   # first-release anchor exists
out="$(bash "$REPO_ROOT/scripts/release.sh" --dry-run --milestone "Initiative 1.1" 2>&1)" \
    || { echo "$out"; assert_fail "release --dry-run exits 0"; exit 1; }
assert_pass "release --dry-run exits 0"

# D = 5 closed issues → version 1.0.1.5, tag v1.0.1.5
assert_contains "T1: planned version 1.0.1.5 (D=5 closed issues)" "$out" "planned version: 1.0.1.5"
assert_contains "T1: planned tag v1.0.1.5" "$out" "planned tag:     v1.0.1.5"
assert_contains "T1: anchors on first-release tag v1.0.0" "$out" "since tag:       v1.0.0"

# Every closed issue present + LINKED (per-issue notes).
for n in 101 102 103 104 105; do
    assert_contains "T1: issue #$n present" "$out" "#$n"
    assert_contains "T1: issue #$n linked" "$out" "/issues/$n)"
done
# Merged PR present + linked.
assert_contains "T1: PR #201 present" "$out" "#201"
assert_contains "T1: PR #201 linked to /pull/" "$out" "/pull/201)"

# Grouping headings.
assert_contains "T1: Features group" "$out" "### Features"
assert_contains "T1: Fixes group"    "$out" "### Fixes"
assert_contains "T1: Docs group"     "$out" "### Docs"
assert_contains "T1: Architecture group" "$out" "### Architecture"
assert_contains "T1: Safety group"   "$out" "### Safety"

# Plug-and-play requirement (#874): the note must convey swappable versioning.
assert_contains "T1: plug-and-play note present" "$out" "plug-and-play"
assert_contains "T1: note cites ADR-011/048" "$out" "ADR-011"
assert_contains "T1: note frames scheme as one example" "$out" "one example"

# ─── T2: --dry-run mutates nothing (CHANGELOG byte-identical) ────────────────
sandbox_changelog="$TEST_TEMP_DIR/CHANGELOG.md"
cp "$REPO_ROOT/CHANGELOG.md" "$sandbox_changelog"
before="$(shasum -a 256 "$sandbox_changelog" | awk '{print $1}')"
bash "$REPO_ROOT/scripts/release.sh" --dry-run --milestone "Initiative 1.1" >/dev/null 2>&1
after="$(shasum -a 256 "$sandbox_changelog" | awk '{print $1}')"
assert_eq "T2: --dry-run does not mutate CHANGELOG" "$before" "$after"
# Also confirm the real repo CHANGELOG untouched by dry-run.
real_before="$(shasum -a 256 "$REPO_ROOT/CHANGELOG.md" | awk '{print $1}')"
bash "$REPO_ROOT/scripts/release.sh" --dry-run >/dev/null 2>&1
real_after="$(shasum -a 256 "$REPO_ROOT/CHANGELOG.md" | awk '{print $1}')"
assert_eq "T2: --dry-run leaves repo CHANGELOG untouched" "$real_before" "$real_after"

# ─── T3: idempotent — two dry-runs produce identical output ─────────────────
out_a="$(bash "$REPO_ROOT/scripts/release.sh" --dry-run --milestone "Initiative 1.1" 2>&1)"
out_b="$(bash "$REPO_ROOT/scripts/release.sh" --dry-run --milestone "Initiative 1.1" 2>&1)"
assert_eq "T3: dry-run is idempotent" "$out_a" "$out_b"

# ─── T4: genesis fallback — no prior tag ─────────────────────────────────────
export ZBUILD_RELEASE_LAST_TAG=""   # simulate a repo with no tags at all
out_gen="$(bash "$REPO_ROOT/scripts/release.sh" --dry-run --milestone "Initiative 1.1" 2>&1)" \
    || { echo "$out_gen"; assert_fail "genesis dry-run exits 0"; exit 1; }
assert_contains "T4: genesis path notes no prior tag" "$out_gen" "genesis"
assert_contains "T4: genesis still computes a version" "$out_gen" "planned version: 1.0.1.5"
export ZBUILD_RELEASE_LAST_TAG="v1.0.0"

# ─── T5: --major overrides A component ───────────────────────────────────────
out_major="$(bash "$REPO_ROOT/scripts/release.sh" --dry-run --major 2 --milestone "Initiative 1.1" 2>&1)"
assert_contains "T5: --major 2 overrides A → 2.0.1.5" "$out_major" "planned version: 2.0.1.5"

# ─── T6: CHANGELOG prepend (non-dry-run) preserves [1.0.0] section ──────────
# Point release.sh at a sandbox CHANGELOG via the ZBUILD_RELEASE_CHANGELOG seam
# so the real repo CHANGELOG is never touched.
sandbox_cl="$TEST_TEMP_DIR/CHANGELOG-t6.md"
cp "$REPO_ROOT/CHANGELOG.md" "$sandbox_cl"
ZBUILD_RELEASE_CHANGELOG="$sandbox_cl" \
    bash "$REPO_ROOT/scripts/release.sh" --milestone "Initiative 1.1" >/dev/null 2>&1
new_changelog="$(cat "$sandbox_cl")"
assert_contains "T6: prepend keeps [1.0.0] section" "$new_changelog" "## [1.0.0]"
assert_contains "T6: prepend adds [1.0.1.5] section" "$new_changelog" "## [1.0.1.5]"
assert_contains "T6: Keep-a-Changelog header preserved" "$new_changelog" "Keep a Changelog"
# New section is ABOVE the old one.
new_line="$(grep -n '## \[1.0.1.5\]' <<<"$new_changelog" | head -1 | cut -d: -f1)"
old_line="$(grep -n '## \[1.0.0\]'   <<<"$new_changelog" | head -1 | cut -d: -f1)"
if [[ -n "$new_line" && -n "$old_line" && "$new_line" -lt "$old_line" ]]; then
    assert_pass "T6: new release section prepended above [1.0.0]"
else
    assert_fail "T6: new section not above [1.0.0] (new=$new_line old=$old_line)"
fi

# ─── T7: `zbuild release --dry-run` dispatch forwards to release.sh ──────────
out_cli="$(bash "$REPO_ROOT/scripts/zbuild" release --dry-run --milestone "Initiative 1.1" 2>&1)" \
    || { echo "$out_cli"; assert_fail "zbuild release --dry-run exits 0"; exit 1; }
assert_contains "T7: zbuild release dispatch works" "$out_cli" "planned version: 1.0.1.5"

# ─── T8: usage lists the release subcommand ─────────────────────────────────
help_out="$(bash "$REPO_ROOT/scripts/zbuild" --help 2>&1)"
assert_contains "T8: --help documents release" "$help_out" "release"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
