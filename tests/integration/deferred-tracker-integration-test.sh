#!/usr/bin/env bash
# Tests: scripts/deferred-tracker.sh end-to-end with mocked gh CLI (#531).
#
# Behavioral coverage for ADR-020 acceptance criteria:
# - Zero candidates → no issue created (no noise)
# - Bot PRs skipped via author.type
# - Idempotency log written AFTER successful issue create (rollback safety)
# - Duplicate-issue guard: 0/1-clean/1-comments/>=2 distinct behaviors
# - gh issue create uses --body-file (shell-injection mitigation)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "deferred-tracker — integration (ADR-020 / #531)"
setup_test_env "deferred-tracker-integration"

export RUNNER_TEMP="$TEST_TEMP_DIR"
TEST_LOG="$TEST_TEMP_DIR/scanned-prs.md"

# ─── Mock gh: configurable via fixture env vars ─────────────────────────────
mock_binary "gh" '
GH_CALLS_LOG="${GH_CALLS_LOG:-/tmp/gh-calls.log}"
echo "gh $*" >> "$GH_CALLS_LOG"

# Extract --jq arg if present (for gh JSON output filtering)
jq_filter=""
for ((i=1; i<=$#; i++)); do
    if [[ "${!i}" == "--jq" ]]; then
        j=$((i+1))
        jq_filter="${!j}"
        break
    fi
done

_emit() {
    local src="$1"
    if [[ -n "$jq_filter" && -s "$src" ]]; then
        jq -r "$jq_filter" < "$src"
    else
        cat "$src"
    fi
}

case "${1:-} ${2:-}" in
    "repo view")
        echo "ezigus/zBuild"
        exit 0
        ;;
    "pr list")
        _emit "${MOCK_PR_LIST_JSON:-/dev/null}"
        exit 0
        ;;
    "issue list")
        _emit "${MOCK_ISSUE_LIST_JSON:-/dev/null}"
        exit 0
        ;;
    "issue view")
        _emit "${MOCK_ISSUE_VIEW_JSON:-/dev/null}"
        exit 0
        ;;
    "issue create")
        if [[ "${MOCK_ISSUE_CREATE_FAIL:-0}" == "1" ]]; then
            echo "create failed" >&2
            exit 1
        fi
        echo "https://github.com/ezigus/zBuild/issues/${MOCK_ISSUE_CREATE_NUM:-999}"
        exit 0
        ;;
    "issue close"|"issue comment")
        exit 0
        ;;
    *)
        echo "[mock-gh] unhandled: $*" >&2
        exit 1
        ;;
esac
'

# Common: empty log to start
cat > "$TEST_LOG" <<'EOF'
# Deferred-tracker scanned PRs

_Last updated: 2026-05-31T00:00:00Z_

| PR | Title | Scanned |
|---|---|---|
EOF

# ─── T1: Zero candidates → no issue created ──────────────────────────────────
export GH_CALLS_LOG="$TEST_TEMP_DIR/gh-calls-t1.log"
: > "$GH_CALLS_LOG"
export MOCK_PR_LIST_JSON="$TEST_TEMP_DIR/pr-clean.json"
cat > "$MOCK_PR_LIST_JSON" <<'EOF'
[{"number":100,"title":"clean PR","body":"Just a normal PR with no deferred work.","author":{"login":"ezigus","type":"User"},"mergedAt":"2026-05-31T10:00:00Z"}]
EOF
export MOCK_ISSUE_LIST_JSON="$TEST_TEMP_DIR/empty.json"
echo "[]" > "$MOCK_ISSUE_LIST_JSON"
rc=0
bash "$REPO_ROOT/scripts/deferred-tracker.sh" --apply --log "$TEST_LOG" >/dev/null 2>&1 || rc=$?
assert_eq "T1: zero candidates → exit 0" "0" "$rc"
issue_create_calls=$(grep -c "issue create" "$GH_CALLS_LOG" || true)
assert_eq "T1: zero candidates → no gh issue create call" "0" "$issue_create_calls"

# ─── T2: Bot-authored PR skipped ─────────────────────────────────────────────
export GH_CALLS_LOG="$TEST_TEMP_DIR/gh-calls-t2.log"
: > "$GH_CALLS_LOG"
cat > "$MOCK_PR_LIST_JSON" <<'EOF'
[{"number":200,"title":"bot PR","body":"This needs a separate issue for the refactor.","author":{"login":"dependabot[bot]","type":"Bot"},"mergedAt":"2026-05-31T10:00:00Z"}]
EOF
rc=0
bash "$REPO_ROOT/scripts/deferred-tracker.sh" --apply --log "$TEST_LOG" >/dev/null 2>&1 || rc=$?
assert_eq "T2: bot PR skipped → exit 0" "0" "$rc"
issue_create_calls=$(grep -c "issue create" "$GH_CALLS_LOG" || true)
assert_eq "T2: bot PR skipped → no gh issue create call" "0" "$issue_create_calls"

# Reset log
cat > "$TEST_LOG" <<'EOF'
# Deferred-tracker scanned PRs

_Last updated: 2026-05-31T00:00:00Z_

| PR | Title | Scanned |
|---|---|---|
EOF

# ─── T3: Candidates + zero open issues → create new triage issue ────────────
export GH_CALLS_LOG="$TEST_TEMP_DIR/gh-calls-t3.log"
: > "$GH_CALLS_LOG"
cat > "$MOCK_PR_LIST_JSON" <<'EOF'
[{"number":300,"title":"with deferred","body":"Needs a follow-up for the refactor work.","author":{"login":"ezigus","type":"User"},"mergedAt":"2026-05-31T10:00:00Z"}]
EOF
echo "[]" > "$MOCK_ISSUE_LIST_JSON"
export MOCK_ISSUE_CREATE_NUM="555"
rc=0
bash "$REPO_ROOT/scripts/deferred-tracker.sh" --apply --log "$TEST_LOG" >/dev/null 2>&1 || rc=$?
assert_eq "T3: candidates + 0 issues → exit 10 (changes applied)" "10" "$rc"
issue_create_calls=$(grep -c "issue create" "$GH_CALLS_LOG" || true)
assert_eq "T3: one gh issue create call observed" "1" "$issue_create_calls"

# CRITICAL: --body-file used, not --body "$var"
body_file_calls=$(grep -c -- "--body-file" "$GH_CALLS_LOG" || true)
assert_gt "T3 REGRESSION: --body-file flag used (shell-injection mitigation)" "$body_file_calls" "0"

# Log written after successful create
if grep -qE "^\| #300 \|" "$TEST_LOG"; then
    assert_pass "T3: log updated after successful create"
else
    assert_fail "T3: log NOT updated after create"
fi

# Reset
cat > "$TEST_LOG" <<'EOF'
# Deferred-tracker scanned PRs

_Last updated: 2026-05-31T00:00:00Z_

| PR | Title | Scanned |
|---|---|---|
EOF

# ─── T4: REGRESSION LOCK — gh issue create fails → log NOT updated ──────────
export GH_CALLS_LOG="$TEST_TEMP_DIR/gh-calls-t4.log"
: > "$GH_CALLS_LOG"
cat > "$MOCK_PR_LIST_JSON" <<'EOF'
[{"number":400,"title":"new pr","body":"Out of scope for this milestone.","author":{"login":"ezigus","type":"User"},"mergedAt":"2026-05-31T10:00:00Z"}]
EOF
echo "[]" > "$MOCK_ISSUE_LIST_JSON"
export MOCK_ISSUE_CREATE_FAIL=1
rc=0
bash "$REPO_ROOT/scripts/deferred-tracker.sh" --apply --log "$TEST_LOG" >/dev/null 2>&1 || rc=$?
assert_eq "T4: create failed → exit 2" "2" "$rc"
if grep -qE "^\| #400 \|" "$TEST_LOG"; then
    assert_fail "T4 REGRESSION: log was updated despite create failure"
else
    assert_pass "T4 REGRESSION: log NOT updated when create failed (rollback safe)"
fi
unset MOCK_ISSUE_CREATE_FAIL

# Reset
cat > "$TEST_LOG" <<'EOF'
# Deferred-tracker scanned PRs

_Last updated: 2026-05-31T00:00:00Z_

| PR | Title | Scanned |
|---|---|---|
EOF

# ─── T5: Already-scanned PR is skipped ───────────────────────────────────────
export GH_CALLS_LOG="$TEST_TEMP_DIR/gh-calls-t5.log"
: > "$GH_CALLS_LOG"
echo "| #500 | already scanned | 2026-05-30 |" >> "$TEST_LOG"
cat > "$MOCK_PR_LIST_JSON" <<'EOF'
[{"number":500,"title":"already","body":"Out of scope work.","author":{"login":"ezigus","type":"User"},"mergedAt":"2026-05-30T10:00:00Z"}]
EOF
echo "[]" > "$MOCK_ISSUE_LIST_JSON"
rc=0
bash "$REPO_ROOT/scripts/deferred-tracker.sh" --apply --log "$TEST_LOG" >/dev/null 2>&1 || rc=$?
assert_eq "T5: only-already-scanned PR → exit 0" "0" "$rc"
issue_create_calls=$(grep -c "issue create" "$GH_CALLS_LOG" || true)
assert_eq "T5: no issue created for re-scanned PR" "0" "$issue_create_calls"

# ─── T6: Report mode does not mutate ─────────────────────────────────────────
# Reset log
cat > "$TEST_LOG" <<'EOF'
# Deferred-tracker scanned PRs

_Last updated: 2026-05-31T00:00:00Z_

| PR | Title | Scanned |
|---|---|---|
EOF
export GH_CALLS_LOG="$TEST_TEMP_DIR/gh-calls-t6.log"
: > "$GH_CALLS_LOG"
cat > "$MOCK_PR_LIST_JSON" <<'EOF'
[{"number":600,"title":"report mode","body":"Needs a separate issue.","author":{"login":"ezigus","type":"User"},"mergedAt":"2026-05-31T10:00:00Z"}]
EOF
log_mtime_before=$(stat -f '%m' "$TEST_LOG" 2>/dev/null || stat -c '%Y' "$TEST_LOG")
rc=0
bash "$REPO_ROOT/scripts/deferred-tracker.sh" --report --log "$TEST_LOG" >/dev/null 2>&1 || rc=$?
log_mtime_after=$(stat -f '%m' "$TEST_LOG" 2>/dev/null || stat -c '%Y' "$TEST_LOG")
assert_eq "T6: report mode → exit 0" "0" "$rc"
assert_eq "T6: report mode does not mutate log" "$log_mtime_before" "$log_mtime_after"
issue_create_calls=$(grep -c "issue create" "$GH_CALLS_LOG" || true)
assert_eq "T6: report mode does not create issue" "0" "$issue_create_calls"

# ─── T7: Workflow file has concurrency guard ─────────────────────────────────
workflow_file="$REPO_ROOT/.github/workflows/deferred-tracker.yml"
assert_contains "T7: workflow has concurrency group" "$(cat "$workflow_file")" "concurrency:"
assert_contains "T7: workflow has fork guard" "$(cat "$workflow_file")" "github.repository =="

# Reset log for T8+
cat > "$TEST_LOG" <<'EOF'
# Deferred-tracker scanned PRs

_Last updated: 2026-05-31T00:00:00Z_

| PR | Title | Scanned |
|---|---|---|
EOF

# ─── T8: Duplicate guard — 1 open issue with NO human comments → close+create
export GH_CALLS_LOG="$TEST_TEMP_DIR/gh-calls-t8.log"
: > "$GH_CALLS_LOG"
cat > "$MOCK_PR_LIST_JSON" <<'EOF'
[{"number":800,"title":"new","body":"This needs a separate issue.","author":{"login":"ezigus","type":"User"},"mergedAt":"2026-05-31T10:00:00Z"}]
EOF
# Existing open issue with no comments
cat > "$MOCK_ISSUE_LIST_JSON" <<'EOF'
[{"number":100}]
EOF
export MOCK_ISSUE_VIEW_JSON="$TEST_TEMP_DIR/issue-view-clean.json"
cat > "$MOCK_ISSUE_VIEW_JSON" <<'EOF'
{"body":"## Deferred work candidates","comments":[]}
EOF
rc=0
bash "$REPO_ROOT/scripts/deferred-tracker.sh" --apply --log "$TEST_LOG" >/dev/null 2>&1 || rc=$?
assert_eq "T8: 1 open clean → exit 10" "10" "$rc"
close_calls=$(grep -c "issue close" "$GH_CALLS_LOG" || true)
create_calls=$(grep -c "issue create" "$GH_CALLS_LOG" || true)
assert_eq "T8: close called once" "1" "$close_calls"
assert_eq "T8: create called once" "1" "$create_calls"

# Reset log
cat > "$TEST_LOG" <<'EOF'
# Deferred-tracker scanned PRs

_Last updated: 2026-05-31T00:00:00Z_

| PR | Title | Scanned |
|---|---|---|
EOF

# ─── T9: Duplicate guard — 1 open with HUMAN comment → append, no create ────
export GH_CALLS_LOG="$TEST_TEMP_DIR/gh-calls-t9.log"
: > "$GH_CALLS_LOG"
cat > "$MOCK_PR_LIST_JSON" <<'EOF'
[{"number":900,"title":"new","body":"This is out of scope.","author":{"login":"ezigus","type":"User"},"mergedAt":"2026-05-31T10:00:00Z"}]
EOF
cat > "$MOCK_ISSUE_LIST_JSON" <<'EOF'
[{"number":100}]
EOF
# Human comment present
cat > "$MOCK_ISSUE_VIEW_JSON" <<'EOF'
{"body":"## Deferred work","comments":[{"id":"c1","author":{"login":"ezigus","__typename":"User"}}]}
EOF
rc=0
bash "$REPO_ROOT/scripts/deferred-tracker.sh" --apply --log "$TEST_LOG" >/dev/null 2>&1 || rc=$?
assert_eq "T9: 1 open + human → exit 10" "10" "$rc"
close_calls=$(grep -c "issue close" "$GH_CALLS_LOG" || true)
create_calls=$(grep -c "issue create" "$GH_CALLS_LOG" || true)
comment_calls=$(grep -c "issue comment" "$GH_CALLS_LOG" || true)
assert_eq "T9 REGRESSION: NO close (human discussion preserved)" "0" "$close_calls"
assert_eq "T9 REGRESSION: NO create (append instead)" "0" "$create_calls"
assert_gt "T9: comment append called" "$comment_calls" "0"

# Reset log
cat > "$TEST_LOG" <<'EOF'
# Deferred-tracker scanned PRs

_Last updated: 2026-05-31T00:00:00Z_

| PR | Title | Scanned |
|---|---|---|
EOF

# ─── T10: Duplicate guard — >=2 open issues → fail loud + sentinel ──────────
export GH_CALLS_LOG="$TEST_TEMP_DIR/gh-calls-t10.log"
: > "$GH_CALLS_LOG"
cat > "$MOCK_PR_LIST_JSON" <<'EOF'
[{"number":1000,"title":"new","body":"This is a follow-up.","author":{"login":"ezigus","type":"User"},"mergedAt":"2026-05-31T10:00:00Z"}]
EOF
cat > "$MOCK_ISSUE_LIST_JSON" <<'EOF'
[{"number":100},{"number":200}]
EOF
# Delete any prior sentinel
rm -f "$REPO_ROOT/.deferred-drift"
rc=0
bash "$REPO_ROOT/scripts/deferred-tracker.sh" --apply --log "$TEST_LOG" >/dev/null 2>&1 || rc=$?
assert_eq "T10 REGRESSION: >=2 open → exit 2 (fail loud)" "2" "$rc"
if [[ -f "$REPO_ROOT/.deferred-drift" ]]; then
    assert_pass "T10: .deferred-drift sentinel written"
else
    assert_fail "T10: .deferred-drift sentinel missing"
fi
rm -f "$REPO_ROOT/.deferred-drift"
create_calls=$(grep -c "issue create" "$GH_CALLS_LOG" || true)
assert_eq "T10: no issue created on multi-open" "0" "$create_calls"

# Reset log
cat > "$TEST_LOG" <<'EOF'
# Deferred-tracker scanned PRs

_Last updated: 2026-05-31T00:00:00Z_

| PR | Title | Scanned |
|---|---|---|
EOF

# ─── T11: Pagination — 30 candidates → 2 issues with Part 1/2 + Part 2/2 ────
export GH_CALLS_LOG="$TEST_TEMP_DIR/gh-calls-t11.log"
: > "$GH_CALLS_LOG"
# Build 30 PRs each with a deferred-work phrase
{
    printf '['
    for i in $(seq 1100 1129); do
        [[ $i -gt 1100 ]] && printf ','
        printf '{"number":%d,"title":"pr%d","body":"Needs a separate issue.","author":{"login":"ezigus","type":"User"},"mergedAt":"2026-05-31T10:00:00Z"}' "$i" "$i"
    done
    printf ']'
} > "$MOCK_PR_LIST_JSON"
echo "[]" > "$MOCK_ISSUE_LIST_JSON"
rc=0
bash "$REPO_ROOT/scripts/deferred-tracker.sh" --apply --log "$TEST_LOG" >/dev/null 2>&1 || rc=$?
assert_eq "T11: 30 candidates → exit 10" "10" "$rc"
create_calls=$(grep -c "issue create" "$GH_CALLS_LOG" || true)
assert_eq "T11: pagination → 2 issues created (Part 1/2 + Part 2/2)" "2" "$create_calls"

# Reset
cat > "$TEST_LOG" <<'EOF'
# Deferred-tracker scanned PRs

_Last updated: 2026-05-31T00:00:00Z_

| PR | Title | Scanned |
|---|---|---|
EOF

# ─── T12: Multi-candidate per PR (one body with 2 phrases) ──────────────────
export GH_CALLS_LOG="$TEST_TEMP_DIR/gh-calls-t12.log"
: > "$GH_CALLS_LOG"
cat > "$MOCK_PR_LIST_JSON" <<'EOF'
[{"number":1200,"title":"multi","body":"This needs a separate issue and a follow-up.","author":{"login":"ezigus","type":"User"},"mergedAt":"2026-05-31T10:00:00Z"}]
EOF
echo "[]" > "$MOCK_ISSUE_LIST_JSON"
rc=0
bash "$REPO_ROOT/scripts/deferred-tracker.sh" --apply --log "$TEST_LOG" >/dev/null 2>&1 || rc=$?
assert_eq "T12: multi-phrase PR → exit 10" "10" "$rc"
# Both phrases should land in candidates → 1 issue with multiple checklist items
create_calls=$(grep -c "issue create" "$GH_CALLS_LOG" || true)
assert_eq "T12: still one issue created (not two)" "1" "$create_calls"

# ─── T13: Path-traversal guard rejects '..' in --log ─────────────────────────
rc=0
bash "$REPO_ROOT/scripts/deferred-tracker.sh" --apply --log "$TEST_TEMP_DIR/../bad.md" >/dev/null 2>&1 || rc=$?
assert_eq "T13 REGRESSION: path with '..' rejected" "2" "$rc"

# ─── T14: Multi-line PR body excerpt extracted correctly (TSV bug fix) ──────
# Reset log
cat > "$TEST_LOG" <<'EOF'
# Deferred-tracker scanned PRs

_Last updated: 2026-05-31T00:00:00Z_

| PR | Title | Scanned |
|---|---|---|
EOF
export GH_CALLS_LOG="$TEST_TEMP_DIR/gh-calls-t14.log"
: > "$GH_CALLS_LOG"
cat > "$MOCK_PR_LIST_JSON" <<'EOF'
[{"number":1400,"title":"multiline","body":"## Summary\n\nFirst line of description.\n\nSecond paragraph that needs a separate issue for the follow-up work.","author":{"login":"ezigus","type":"User"},"mergedAt":"2026-05-31T10:00:00Z"}]
EOF
echo "[]" > "$MOCK_ISSUE_LIST_JSON"
rc=0
bash "$REPO_ROOT/scripts/deferred-tracker.sh" --apply --log "$TEST_LOG" >/dev/null 2>&1 || rc=$?
assert_eq "T14 REGRESSION: multi-line body parsed (TSV fix) → exit 10" "10" "$rc"

print_test_results
