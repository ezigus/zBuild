#!/usr/bin/env bash
# Tests: review banner (#506) — operator-visible banner shows numstat-style
# summary, NOT the raw diff. The LLM (via -p prompt) STILL receives the
# full diff.
#
# This test boots a tiny git repo, stages a changed file, builds the
# fixture artifacts (plan, diff.patch, test-results), installs the mock
# claude with --record-prompt so we can recover the prompt the LLM saw,
# captures the stage_io banner to fd 3, and asserts:
#
#   * recorded LLM prompt contains the full `diff --git a/... b/...` body
#   * captured banner input contains `── changed files ──` heading
#   * captured banner input contains `+N -M path` line + `total:` footer
#   * captured banner input does NOT contain `diff --git`
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "review banner: numstat for operator, full diff for LLM (#506)"
setup_test_env "review-banner-506"

# ─── (1) Event bus init ─────────────────────────────────────────────────────
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

export ZBUILD_RUN_ID="review-banner-506-$$"

# ─── (2) Tiny git repo so `git diff --numstat` resolves ─────────────────────
REPO="$TEST_TEMP_DIR/repo"
mkdir -p "$REPO"
(
    cd "$REPO"
    git init -q -b main
    git config user.email "test@zbuild.local"
    git config user.name "Test"
    mkdir -p core
    printf 'a\n' > core/foo.sh
    git add core/foo.sh
    git commit -q -m "base"
    # Branch off and add a real change so the merge-base resolves to base,
    # and `git diff <merge-base> HEAD --numstat` has content.
    git checkout -q -b feat/work
    printf 'a\nb\nc\n' > core/foo.sh
    git add core/foo.sh
    git commit -q -m "work"
)

# ─── (3) Mock claude with prompt recorder ───────────────────────────────────
mkdir -p "$TEST_TEMP_DIR/bin"
export PATH="$TEST_TEMP_DIR/bin:$PATH"

REVIEW_CANNED="$TEST_TEMP_DIR/review-canned.json"
printf '%s\n' '{"verdict":"approve","confidence":0.9,"issues":[],"summary":"ok"}' > "$REVIEW_CANNED"
PROMPT_RECORD="$TEST_TEMP_DIR/llm-prompt.txt"
install_envelope_mock_claude --file "$REVIEW_CANNED" --record-prompt "$PROMPT_RECORD"

# ─── (4) Fixture artifacts ──────────────────────────────────────────────────
STATE_DIR="$TEST_TEMP_DIR/state"
ART="$STATE_DIR/artifacts"
mkdir -p "$ART"

cat > "$STATE_DIR/scope-manifest.md" <<'SCOPE'
+ core/
SCOPE

cat > "$ART/plan.json" <<'EOF'
{"schema_version":1,"goal":"banner","steps":[{"id":"s1","description":"d","files":["core/foo.sh"],"estimated_lines":2}]}
EOF

cat > "$ART/diff.patch" <<'EOF'
diff --git a/core/foo.sh b/core/foo.sh
index 7898192..422c2b7 100644
--- a/core/foo.sh
+++ b/core/foo.sh
@@ -1 +1,3 @@
 a
+b
+c
EOF

cat > "$ART/test-results.json" <<'EOF'
{"verdict":"pass","passed":1,"failed":0}
EOF

# ─── (5) Capture stage_io banner ────────────────────────────────────────────
export ZBUILD_CURRENT_STAGE=review
export _TPL_STAGE_IO_DESTS_review="stdout"
BANNER="$TEST_TEMP_DIR/review-banner.txt"
: > "$BANNER"
exec 3>"$BANNER"
export ZBUILD_STAGE_IO_FD=3

# shellcheck source=../../plugins/agent/review/plugin.sh
source "$REPO_ROOT/plugins/agent/review/plugin.sh"

# Run from inside the test repo so `git diff` resolves against the fixtures.
(
    cd "$REPO"
    set +e
    _review_run_inner \
        "$STATE_DIR/scope-manifest.md" \
        "$ART/plan.json" \
        "$ART/diff.patch" \
        "$ART/test-results.json" \
        "$ART/review.json" \
        "$ART" >/dev/null 2>&1
    echo $? > "$TEST_TEMP_DIR/inner-rc"
)
rc="$(cat "$TEST_TEMP_DIR/inner-rc")"

exec 3>&-
unset ZBUILD_STAGE_IO_FD ZBUILD_CURRENT_STAGE _TPL_STAGE_IO_DESTS_review

assert_eq "_review_run_inner rc=0" "0" "$rc"

# ─── (6) Banner assertions — INPUT section only ─────────────────────────────
banner_all="$(cat "$BANNER" 2>/dev/null || true)"
# Slice the input section (between "seq=N input" header and "seq=N output").
banner_input="$(printf '%s' "$banner_all" | sed -n '/seq=[0-9]* input /,/seq=[0-9]* output /p')"

print_test_section "operator banner INPUT body"
if grep -qF '── changed files ──' <<< "$banner_input"; then
    assert_pass "banner input contains '── changed files ──' heading"
else
    assert_fail "banner input missing heading" \
        "got: $(printf '%s' "$banner_input" | head -20)"
fi

if grep -qE '^\+[0-9]+ -[0-9]+  core/foo\.sh$' <<< "$banner_input"; then
    assert_pass "banner input contains '+N -M core/foo.sh' numstat line"
else
    assert_fail "banner input missing numstat line for core/foo.sh" \
        "got: $(printf '%s' "$banner_input")"
fi

if grep -qE '^total: [0-9]+ files, \+[0-9]+ -[0-9]+' <<< "$banner_input"; then
    assert_pass "banner input contains 'total:' footer"
else
    assert_fail "banner input missing total footer" \
        "got: $(printf '%s' "$banner_input")"
fi

if grep -qF 'diff --git' <<< "$banner_input"; then
    assert_fail "banner input leaked raw diff body (should be numstat only)" \
        "got: $(printf '%s' "$banner_input" | head -30)"
else
    assert_pass "banner input free of 'diff --git' (raw diff not leaked)"
fi

# ─── (7) LLM prompt assertions ──────────────────────────────────────────────
print_test_section "LLM prompt (recorded via -p) STILL receives full diff"
llm_prompt="$(cat "$PROMPT_RECORD" 2>/dev/null || true)"
if [[ -z "$llm_prompt" ]]; then
    assert_fail "LLM prompt recorder empty" "expected -p capture in $PROMPT_RECORD"
else
    if grep -qF 'diff --git a/core/foo.sh b/core/foo.sh' <<< "$llm_prompt"; then
        assert_pass "LLM prompt contains full 'diff --git a/... b/...' body"
    else
        assert_fail "LLM prompt missing full diff body" \
            "first 200 chars: $(printf '%s' "$llm_prompt" | head -c 200)"
    fi
    if grep -qF '+b' <<< "$llm_prompt"; then
        assert_pass "LLM prompt contains diff hunk additions"
    else
        assert_fail "LLM prompt missing diff hunk additions" "n/a"
    fi
fi

# ─── (8) Env var hygiene — unset after route returns ────────────────────────
print_test_section "ZBUILD_ROUTER_BANNER_INPUT_OVERRIDE unset after run"
if [[ -z "${ZBUILD_ROUTER_BANNER_INPUT_OVERRIDE:-}" ]]; then
    assert_pass "override env var restored to unset"
else
    assert_fail "override env var leaked: $ZBUILD_ROUTER_BANNER_INPUT_OVERRIDE" "n/a"
fi

cleanup_test_env
print_test_results
