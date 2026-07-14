#!/usr/bin/env bash
# tests/integration/release-sh-major-guardrails-test.sh
# Behavioral coverage for the --major release guardrails: initiative↔milestone binding.
#
# SPEC-1 [change]: --major --dry-run prints "releasing Initiative 2.0"
# SPEC-2 [change]: --major --dry-run exits rc=1 when milestone has open issues
# SPEC-3 [change]: --major --dry-run exits rc=1 when no matching milestone found
# SPEC-4 [guard]:  --minor --dry-run exits 0 and does NOT print "releasing Initiative"
# SPEC-5 [guard]:  --major --force --dry-run exits 0 (guardrails bypassed by --force)
# SPEC-6 [change]: preflight error message names the blocked milestone title
# SPEC-7 [change]: ZBUILD_GH_CMD seam is invoked for the milestone API call
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "release.sh major-release guardrails — initiative↔milestone binding"
setup_test_env "release-sh-major-guardrails"

# ─── Shared env seams: deterministic version + repo slug ─────────────────────
export ZBUILD_RELEASE_REPO="ezigus/zBuild"
export ZBUILD_VERSION_ANCHOR="1.0"
export ZBUILD_VERSION_RELEASE_COUNT="1"
export ZBUILD_RELEASE_SINCE="2026-07-04T00:00:00Z"
export ZBUILD_RELEASE_LAST_TAG="v1.0.0"
# Suppress noisy stderr from the DOC-F dry-run preview when wiki remote is absent.
export ZBUILD_WIKI_REMOTE="https://example.com/fake.wiki.git"

# With anchor=1.0 and --major, version bumps to 2.0.0.0 → initiative "2.0".
# D=5 closed issues in-window (used by versioning backend + notes generator).
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

# MOCK_MILESTONE_JSON controls what the mock returns for `gh api repos/.../milestones`.
# Default: a passing milestone. Tests override this per-invocation.
export MOCK_MILESTONE_JSON='[{"title":"Initiative 2.0","open_issues":0}]'

# ─── Base gh mock: handles issue list, pr list, repo view, and milestones API ─
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
    "repo view")    echo "ezigus/zBuild"; exit 0 ;;
    "issue list")   _emit "${MOCK_ISSUE_LIST_JSON:-/dev/null}"; exit 0 ;;
    "pr list")      _emit "${MOCK_PR_LIST_JSON:-/dev/null}"; exit 0 ;;
    "api "*)        printf '"'"'%s\n'"'"' "${MOCK_MILESTONE_JSON:-[]}"; exit 0 ;;
    *) echo "[mock-gh] unhandled: $*" >&2; exit 1 ;;
esac
'

# Mock git: no-op (avoids real git ops; tag+publish auto-skips under NO_GITHUB=true).
mock_binary "git" '
echo "git $*" >> "'"$TEST_TEMP_DIR"'/git-calls.log"
exit 0
'

# ─── SPEC-1: --major --dry-run prints "releasing Initiative 2.0" ─────────────
# anchor=1.0 + --major → post-bump version 2.0.0.0 → initiative "2.0".
# Fails at baseline: no preflight exists, so no "releasing Initiative" message.
out_spec1="$(MOCK_MILESTONE_JSON='[{"title":"Initiative 2.0","open_issues":0}]' \
    bash "$REPO_ROOT/scripts/release.sh" --dry-run --major 2>&1)" \
    || { echo "$out_spec1"; assert_fail "[SPEC-1] --major --dry-run exits 0 with good milestone"; exit 1; }
assert_contains "[SPEC-1] --major --dry-run prints releasing Initiative 2.0" \
    "$out_spec1" "releasing Initiative 2.0"
assert_contains "[SPEC-1] --major --dry-run prints planned version 2.0.0.0" \
    "$out_spec1" "planned version: 2.0.0.0"

# ─── SPEC-2: --major --dry-run exits rc=1 when milestone has open issues ──────
# Fails at baseline: no preflight — --major always exits 0 regardless of milestone.
rc_spec2=0
MOCK_MILESTONE_JSON='[{"title":"Initiative 2.0","open_issues":3}]' \
    bash "$REPO_ROOT/scripts/release.sh" --dry-run --major 2>/dev/null || rc_spec2=$?
assert_eq "[SPEC-2] --major --dry-run exits rc=1 when milestone has open issues" "1" "$rc_spec2"

# ─── SPEC-3: --major --dry-run exits rc=1 when no matching milestone found ────
# Fails at baseline: no preflight — --major always exits 0 regardless of milestones.
rc_spec3=0
MOCK_MILESTONE_JSON='[]' \
    bash "$REPO_ROOT/scripts/release.sh" --dry-run --major 2>/dev/null || rc_spec3=$?
assert_eq "[SPEC-3] --major --dry-run exits rc=1 when no matching milestone" "1" "$rc_spec3"

# ─── SPEC-4: --minor --dry-run exits 0 and does NOT print "releasing Initiative" ─
# Guard: --minor must never trigger the major guardrails.
out_spec4="$(bash "$REPO_ROOT/scripts/release.sh" --dry-run --minor 2>&1)" \
    || { echo "$out_spec4"; assert_fail "[SPEC-4] --minor --dry-run exits 0"; exit 1; }
if [[ "$out_spec4" == *"releasing Initiative"* ]]; then
    assert_fail "[SPEC-4] --minor --dry-run must NOT print 'releasing Initiative'"
else
    assert_pass "[SPEC-4] --minor --dry-run does not print 'releasing Initiative' (guardrails not triggered)"
fi

# ─── SPEC-5: --major --force --dry-run exits 0 (guardrails bypassed by --force) ─
# Guard: --force must bypass the preflight even when the milestone mock would fail.
rc_spec5=0
MOCK_MILESTONE_JSON='[]' \
out_spec5="$(bash "$REPO_ROOT/scripts/release.sh" --dry-run --major --force 2>&1)" \
    || rc_spec5=$?
assert_eq "[SPEC-5] --major --force --dry-run exits 0 bypassing milestone guardrail" "0" "$rc_spec5"

# ─── SPEC-6: preflight error message names the blocked milestone title ────────
# Fails at baseline: no preflight — no "Initiative 2.0" appears in any error output.
out_spec6="$(MOCK_MILESTONE_JSON='[{"title":"Initiative 2.0","open_issues":2}]' \
    bash "$REPO_ROOT/scripts/release.sh" --dry-run --major 2>&1 || true)"
assert_contains "[SPEC-6] preflight error names the blocked milestone 'Initiative 2.0'" \
    "$out_spec6" "Initiative 2.0"

# ─── SPEC-7: ZBUILD_GH_CMD seam is invoked for the milestone API call ─────────
# Fails at baseline: no preflight, so the seam is never called for an API call.
custom_gh_log="$TEST_TEMP_DIR/custom-gh-calls.log"
: > "$custom_gh_log"
mock_binary "custom-gh" '
CUSTOM_GH_LOG="'"$TEST_TEMP_DIR"'/custom-gh-calls.log"
echo "custom-gh $*" >> "$CUSTOM_GH_LOG"
case "${1:-} ${2:-}" in
    "repo view")  echo "ezigus/zBuild"; exit 0 ;;
    "issue list") cat "${MOCK_ISSUE_LIST_JSON:-/dev/null}"; exit 0 ;;
    "pr list")    printf "[]"; exit 0 ;;
    "api "*)      printf "[{\"title\":\"Initiative 2.0\",\"open_issues\":0}]\n"; exit 0 ;;
    *) echo "[custom-gh] unhandled: $*" >&2; exit 1 ;;
esac
'
ZBUILD_GH_CMD="$TEST_TEMP_DIR/bin/custom-gh" \
    bash "$REPO_ROOT/scripts/release.sh" --dry-run --major 2>/dev/null || true
if /usr/bin/grep -q "custom-gh api " "$custom_gh_log" 2>/dev/null; then
    assert_pass "[SPEC-7] ZBUILD_GH_CMD seam: custom gh cmd invoked for milestone API call"
else
    assert_fail "[SPEC-7] ZBUILD_GH_CMD seam: custom gh cmd NOT invoked for milestone API call"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
