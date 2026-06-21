#!/usr/bin/env bash
# Tests: review judges the CUMULATIVE branch-vs-default-branch (merge-base) diff,
# not the per-run diff.patch (#896).
#
# Bug: build writes diff.patch as `git diff intake-baseline..HEAD`. When the
# implementation was committed BEFORE the run (re-dogfood) or build no-ops on a
# green resumed run, that diff is EMPTY — yet the branch genuinely contains the
# work. Pre-fix, review's LLM read the empty diff.patch and wrongly reported
# "nothing implemented", driving the build_test_cycle livelock. Fix: the review
# LLM diff source is the merge-base diff (the same basis the operator banner
# already uses).
#
# MB1: empty diff.patch + real branch commits → LLM prompt STILL contains the
#      branch diff (proves merge-base basis; FAILS on pre-fix code).
# MB2: no resolvable base (no main/origin/main, single commit) → falls back to
#      the diff.patch artifact (never crashes).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "review: judges cumulative merge-base diff, not empty diff.patch (#896)"
setup_test_env "review-merge-base-896"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_RUN_ID="review-merge-base-896-$$"

# Mock claude with prompt recorder.
mkdir -p "$TEST_TEMP_DIR/bin"
export PATH="$TEST_TEMP_DIR/bin:$PATH"
REVIEW_CANNED="$TEST_TEMP_DIR/review-canned.json"
printf '%s\n' '{"verdict":"approve","confidence":0.9,"issues":[],"summary":"ok"}' > "$REVIEW_CANNED"

# shellcheck source=../../plugins/agent/review/plugin.sh
source "$REPO_ROOT/plugins/agent/review/plugin.sh"

# ─── MB1: empty diff.patch, branch has commits vs main → LLM sees branch diff ─
print_test_section "MB1: empty diff.patch + branch commits → LLM judges merge-base diff"
REPO1="$TEST_TEMP_DIR/repo1"
mkdir -p "$REPO1"
(
    cd "$REPO1"
    git init -q -b main
    git config user.email "test@zbuild.local"; git config user.name "Test"
    mkdir -p core
    printf 'a\n' > core/foo.sh
    git add core/foo.sh; git commit -q -m "base"
    # Implementation committed on the branch BEFORE the run (re-dogfood case).
    git checkout -q -b feat/work
    printf 'a\nb\nc\n' > core/foo.sh
    git add core/foo.sh; git commit -q -m "work (pre-committed)"
)
ART1="$TEST_TEMP_DIR/state1/artifacts"; mkdir -p "$ART1"
cat > "$TEST_TEMP_DIR/state1/scope-manifest.md" <<'SCOPE'
+ core/
SCOPE
cat > "$ART1/plan.json" <<'EOF'
{"schema_version":1,"goal":"work","steps":[{"id":"s1","description":"d","files":["core/foo.sh"],"estimated_lines":2}]}
EOF
# diff.patch is EMPTY — the per-run diff is empty because the work was committed
# before intake / build no-op'd. This is the exact bug condition.
: > "$ART1/diff.patch"
cat > "$ART1/test-results.json" <<'EOF'
{"verdict":"pass","passed":1,"failed":0}
EOF
PROMPT1="$TEST_TEMP_DIR/llm-prompt-1.txt"
install_envelope_mock_claude --file "$REVIEW_CANNED" --record-prompt "$PROMPT1"
(
    cd "$REPO1"
    set +e
    _review_run_inner \
        "$TEST_TEMP_DIR/state1/scope-manifest.md" \
        "$ART1/plan.json" "$ART1/diff.patch" "$ART1/test-results.json" \
        "$ART1/review.json" "$ART1" >/dev/null 2>&1
    echo $? > "$TEST_TEMP_DIR/rc1"
)
assert_eq "MB1 _review_run_inner rc=0" "0" "$(cat "$TEST_TEMP_DIR/rc1")"
llm1="$(cat "$PROMPT1" 2>/dev/null || true)"
if grep -qF 'diff --git a/core/foo.sh b/core/foo.sh' <<< "$llm1"; then
    assert_pass "MB1 LLM prompt contains the branch diff despite EMPTY diff.patch"
else
    assert_fail "MB1 LLM prompt missing branch diff (judged empty per-run diff)" \
        "first 300: $(printf '%s' "$llm1" | head -c 300)"
fi
if grep -qF '+b' <<< "$llm1"; then
    assert_pass "MB1 LLM prompt contains the branch hunk additions"
else
    assert_fail "MB1 LLM prompt missing branch hunk additions" "n/a"
fi

# ─── MB2: no resolvable base → fall back to diff.patch (no crash) ────────────
print_test_section "MB2: no merge-base → falls back to diff.patch artifact"
REPO2="$TEST_TEMP_DIR/repo2"
mkdir -p "$REPO2"
(
    cd "$REPO2"
    # default branch 'work', single commit, no 'main'/'origin/main', no HEAD~1.
    git init -q -b work
    git config user.email "test@zbuild.local"; git config user.name "Test"
    mkdir -p core
    printf 'x\n' > core/bar.sh
    git add core/bar.sh; git commit -q -m "only"
)
ART2="$TEST_TEMP_DIR/state2/artifacts"; mkdir -p "$ART2"
cat > "$TEST_TEMP_DIR/state2/scope-manifest.md" <<'SCOPE'
+ core/
SCOPE
cat > "$ART2/plan.json" <<'EOF'
{"schema_version":1,"goal":"x","steps":[{"id":"s1","description":"d","files":["core/bar.sh"],"estimated_lines":1}]}
EOF
cat > "$ART2/diff.patch" <<'EOF'
diff --git a/core/bar.sh b/core/bar.sh
index 1111111..2222222 100644
--- a/core/bar.sh
+++ b/core/bar.sh
@@ -1 +1,2 @@
 x
+FALLBACK_MARKER
EOF
cat > "$ART2/test-results.json" <<'EOF'
{"verdict":"pass","passed":1,"failed":0}
EOF
PROMPT2="$TEST_TEMP_DIR/llm-prompt-2.txt"
install_envelope_mock_claude --file "$REVIEW_CANNED" --record-prompt "$PROMPT2"
(
    cd "$REPO2"
    set +e
    _review_run_inner \
        "$TEST_TEMP_DIR/state2/scope-manifest.md" \
        "$ART2/plan.json" "$ART2/diff.patch" "$ART2/test-results.json" \
        "$ART2/review.json" "$ART2" >/dev/null 2>&1
    echo $? > "$TEST_TEMP_DIR/rc2"
)
assert_eq "MB2 _review_run_inner rc=0 (fallback, no crash)" "0" "$(cat "$TEST_TEMP_DIR/rc2")"
llm2="$(cat "$PROMPT2" 2>/dev/null || true)"
if grep -qF 'FALLBACK_MARKER' <<< "$llm2"; then
    assert_pass "MB2 LLM prompt uses diff.patch content when no base resolves"
else
    assert_fail "MB2 LLM prompt missing diff.patch fallback content" \
        "first 300: $(printf '%s' "$llm2" | head -c 300)"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
