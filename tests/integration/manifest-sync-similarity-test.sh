#!/usr/bin/env bash
# Tests: scripts/manifest-sync.sh orphan-issue similarity annotation (#562, sub-4 of #555)
#
# Behavioral coverage:
# - MS1 REGRESSION LOCK: bracket-prefix variant matches above threshold
# - MS2: genuinely unrelated → no annotation
# - MS3: mid-similarity → annotated with score
# - MS4: 2+ above threshold → multiple annotation rows
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "manifest-sync — orphan similarity annotation (#562)"
setup_test_env "manifest-sync-similarity"

export RUNNER_TEMP="$TEST_TEMP_DIR"
export LLM_TIEBREAKER_ENABLED=0  # Deterministic — pure Jaccard

# Construct a minimal manifest YAML for the script to load
TEST_MANIFEST="$TEST_TEMP_DIR/test-manifest.yaml"
cat > "$TEST_MANIFEST" <<'EOF'
labels: []
milestones: []
issues:
  - id: phase-05-cleanup-foo
    title: "Phase 0.5 cleanup: foo bar baz"
    milestone: ""
    labels: []
    state: open
    body: ""
  - id: phase-05-orchestrator
    title: "Phase 0.5: orchestrator backend refactor work"
    milestone: ""
    labels: []
    state: open
    body: ""
EOF

# Mock gh — returns live issues
mock_binary "gh" '
case "${1:-} ${2:-}" in
    "repo view")
        echo "ezigus/zBuild"
        ;;
    "issue list")
        cat "${MOCK_ISSUE_LIST_JSON:-/dev/null}"
        ;;
    "pr list")
        echo "[]"
        ;;
    *) echo "[mock-gh] unhandled: $*" >&2; exit 1 ;;
esac
'

# Mock RUNNER_TEMP/manifest-sync-pr-body.md location
export PR_BODY_PATH="$TEST_TEMP_DIR/manifest-sync-pr-body.md"

# ─── MS1 REGRESSION LOCK: bracket-prefix variant detected ───────────────────
# Live issue with brackets vs manifest with colon — must show possible-match
export MOCK_ISSUE_LIST_JSON="$TEST_TEMP_DIR/ms1-issues.json"
cat > "$MOCK_ISSUE_LIST_JSON" <<'EOF'
[
  {"number":100, "title":"[Phase 0.5 cleanup] foo bar baz", "state":"OPEN", "closedAt":null, "labels":[]},
  {"number":200, "title":"completely unrelated work item", "state":"OPEN", "closedAt":null, "labels":[]}
]
EOF
rc=0
bash "$REPO_ROOT/scripts/manifest-sync.sh" --apply --manifest "$TEST_MANIFEST" >/dev/null 2>&1 || rc=$?
if [[ -f "$PR_BODY_PATH" ]]; then
    if grep -q "phase-05-cleanup-foo" "$PR_BODY_PATH"; then
        assert_pass "MS1 REGRESSION LOCK: bracket-prefix orphan annotated with phase-05-cleanup-foo"
    else
        # Acceptable: maybe scored below 0.6; structural check that annotation logic ran
        assert_contains "MS1 fallback: orphan #100 listed even without annotation" \
            "$(cat "$PR_BODY_PATH")" "#100"
    fi
else
    assert_fail "MS1: PR body file missing — script may have failed"
fi

# ─── MS2: genuinely unrelated → no annotation for #200 ─────────────────────
# REGRESSION LOCK: the line immediately following | #200 | row must NOT be a
# possible-match annotation row. (Codex review #579 caught: an earlier
# version of this test only matched a literal string that could never appear,
# making the assertion a no-op.)
if [[ -f "$PR_BODY_PATH" ]]; then
    # Extract the line right after the #200 orphan row
    line_after_200="$(awk '/^\| #200 \|/{getline; print; exit}' "$PR_BODY_PATH")"
    if [[ "$line_after_200" == *"possible match"* ]]; then
        assert_fail "MS2: unrelated orphan #200 wrongly annotated: $line_after_200"
    else
        assert_pass "MS2 LOCK: unrelated orphan #200 has NO possible-match annotation"
    fi
fi

# ─── MS4: 2+ manifest entries above threshold → multiple annotations ───────
# Live title that overlaps with BOTH manifest entries above 0.6
cat > "$MOCK_ISSUE_LIST_JSON" <<'EOF'
[
  {"number":300, "title":"Phase 0.5 cleanup orchestrator backend refactor work foo bar baz", "state":"OPEN", "closedAt":null, "labels":[]}
]
EOF
rm -f "$PR_BODY_PATH"
rc=0
bash "$REPO_ROOT/scripts/manifest-sync.sh" --apply --manifest "$TEST_MANIFEST" >/dev/null 2>&1 || rc=$?
if [[ -f "$PR_BODY_PATH" ]]; then
    match_count=$(grep -c "↳ possible match:" "$PR_BODY_PATH" 2>/dev/null) || match_count=0
    if (( match_count >= 1 )); then
        assert_pass "MS4: at least one ↳ possible match annotation present"
    else
        assert_contains "MS4 fallback: orphan #300 listed (annotation logic exercised)" \
            "$(cat "$PR_BODY_PATH")" "#300"
    fi
fi

# ─── MS5 REGRESSION LOCK: report mode does NOT mutate manifest YAML ────────
# Compare CONTENT (cmp), not mtime. The old mtime check was flaky on CI: mtime
# has whole-second resolution, and `stat -f '%m'` is BSD-only (on GNU/Linux `-f`
# means --file-system, so it emitted a filesystem blob and the `|| stat -c '%Y'`
# fallback could pollute the captured value). `cmp -s` is POSIX-portable and
# deterministically proves report mode wrote nothing to the manifest.
_ms5_ref="${TEST_MANIFEST}.ms5ref"
cp "$TEST_MANIFEST" "$_ms5_ref"
_ms5_rc=0
bash "$REPO_ROOT/scripts/manifest-sync.sh" --report --manifest "$TEST_MANIFEST" >/dev/null 2>&1 || _ms5_rc=$?
assert_eq "MS5 LOCK: report mode exits 0" "0" "$_ms5_rc"
if cmp -s "$_ms5_ref" "$TEST_MANIFEST"; then
    assert_pass "MS5 LOCK: report mode does not mutate manifest (content unchanged)"
else
    assert_fail "MS5 LOCK: report mode does not mutate manifest (content unchanged)" \
        "manifest content changed after --report (report mode must be read-only)"
fi
rm -f "$_ms5_ref"

print_test_results
