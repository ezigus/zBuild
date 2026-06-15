#!/usr/bin/env bash
# Integration: review LLM prompt is clean (Wave 16-B, #699)
#
# Drives _review_run_inner with a plan + diff + test-results.json whose fields
# are heavy with framework decoration (banner pairs, redaction-tag wrappers,
# ANSI, decorative separators, truncation footer). Asserts the composed LLM
# prompt that the (stubbed) router receives:
#   - contains the diff-stat summary block at the top
#   - contains genuine plan content (sanitizer doesn't strip real signal)
#   - does NOT contain any of the 5 decoration classes that #681 strips
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "integration: review prompt clean (#699)"
setup_test_env "review-prompt-clean"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR"

export _MOCK_ROUTE_CAPTURE="$TEST_TEMP_DIR/route-prompt.txt"

ARTIFACTS_DIR="$TEST_TEMP_DIR/state/artifacts"
mkdir -p "$ARTIFACTS_DIR"

PLAN_PATH="$ARTIFACTS_DIR/plan.json"
DIFF_PATH="$ARTIFACTS_DIR/diff.patch"
TEST_PATH="$ARTIFACTS_DIR/test-results.json"
REVIEW_PATH="$ARTIFACTS_DIR/review.json"
SCOPE_MANIFEST="$TEST_TEMP_DIR/state/scope-manifest.md"

# Scope manifest with one in-scope path.
cat > "$SCOPE_MANIFEST" <<'SCOPE'
+ core/
+ plugins/
SCOPE

# Plan: realistic JSON (no decoration; render_artifact flattens multi-line
# string fields so banner pairs inside JSON are unreachable by a line-based
# sanitizer anyway — see Wave 16-B notes). The plan branch of the sanitizer
# is exercised as defense-in-depth; real decoration risk lives in
# test-results.json's .test_output, covered below.
jq -n --arg goal "real goal line" \
    '{schema_version:1,title:"Wave 16-B prompt cleanliness",goal:$goal,steps:[{id:"s1",description:"x","files":["core/x.sh"],estimated_lines:1}],estimated_total_lines:1,notes:""}' \
    > "$PLAN_PATH"

# Diff patch: a small multi-file unified diff (so diff-stat has real input).
cat > "$DIFF_PATH" <<'EOF'
diff --git a/core/x.sh b/core/x.sh
--- a/core/x.sh
+++ b/core/x.sh
@@ -1,1 +1,3 @@
 keep
+addA
+addB
diff --git a/plugins/y/plugin.sh b/plugins/y/plugin.sh
--- a/plugins/y/plugin.sh
+++ b/plugins/y/plugin.sh
@@ -1,2 +1,1 @@
 keep
-removed
EOF

# Test results with a heavily-decorated test_output field.
NOISY_OUTPUT="$(printf '%s\n' \
    '══ test [command] seq=1 input ══' \
    'npm test' \
    '── end stage-io: test ✓ ──' \
    '══════════════════════════════════════════════════' \
    'PASS WidgetTest' \
    '  asserts: 3' \
    '  trace: <out-of-scope-context>/var/folders/q/widget.sh</out-of-scope-context>:7' \
    $'\x1b[38;2;74;222;128m✓\x1b[0m widget ok' \
    '──────────────────────────────────────────────────' \
    '↪ [42 more lines · full at /Users/x/test-results.json]')"
jq -n --arg out "$NOISY_OUTPUT" \
    '{schema_version:1,status:"passed",verdict:"pass",passed:1,failed:0,exit_code:0,test_output:$out}' \
    > "$TEST_PATH"

# shellcheck source=../../plugins/agent/review/plugin.sh
source "$REPO_ROOT/plugins/agent/review/plugin.sh"

# Stub redaction (pass-through) so the captured prompt is what review built.
# Stub router to capture the prompt and return a clean approve verdict.
apply_scope_redaction() {
    local in="$1" out="$2"
    cp "$in" "$out"
    return 0
}
route_to_model() {
    printf '%s' "$2" > "$_MOCK_ROUTE_CAPTURE"
    printf '%s' '{"verdict":"approve","confidence":0.9,"issues":[],"summary":"ok"}'
    return 0
}

# #896: review derives the LLM diff (and the diff-stat header) from the cwd repo's
# merge-base. This test asserts on the FIXTURE diff.patch, so run from a non-git dir
# where merge-base does not resolve → review falls back to the fixture diff.patch.
cd "$TEST_TEMP_DIR"

set +e
_review_run_inner \
    "$SCOPE_MANIFEST" \
    "$PLAN_PATH" \
    "$DIFF_PATH" \
    "$TEST_PATH" \
    "$REVIEW_PATH" \
    "$ARTIFACTS_DIR" >/dev/null 2>&1
rc=$?
set -e

assert_eq "review inner rc=0" "0" "$rc"
assert_file_exists "prompt captured by stubbed router" "$_MOCK_ROUTE_CAPTURE"

prompt="$(cat "$_MOCK_ROUTE_CAPTURE")"

# ─── 1. diff-stat block is at the top (before plan/diff content) ─────────────
print_test_section "1. diff-stat summary at top"

# Header line should be present.
if grep -qE '^## Changed files \(2 total, \+[0-9]+ -[0-9]+\)' <<< "$prompt"; then
    assert_pass "diff-stat header present with 2 files"
else
    assert_fail "diff-stat header present with 2 files" "no header matched"
fi

# Both changed paths should appear in the stat block listing.
assert_contains "core/x.sh listed in diff-stat" "$prompt" "core/x.sh"
assert_contains "plugins/y/plugin.sh listed in diff-stat" "$prompt" "plugins/y/plugin.sh"

# diff-stat should appear BEFORE the "Plan:" splice header.
stat_line=$(grep -n '^## Changed files' <<< "$prompt" | head -n 1 | cut -d: -f1)
plan_line=$(grep -n '^Plan:' <<< "$prompt" | head -n 1 | cut -d: -f1)
if [[ -n "$stat_line" && -n "$plan_line" && "$stat_line" -lt "$plan_line" ]]; then
    assert_pass "diff-stat appears before Plan section"
else
    assert_fail "diff-stat appears before Plan section" \
        "stat_line=$stat_line plan_line=$plan_line"
fi

# ─── 2. Real content preserved (sanitizer doesn't strip signal) ──────────────
print_test_section "2. real content preserved"

assert_contains "plan title visible (real signal)" "$prompt" "Wave 16-B prompt cleanliness"
assert_contains "real goal line preserved" "$prompt" "real goal line"
assert_contains "test PASS line preserved" "$prompt" "PASS WidgetTest"
# Wrapper stripped → bare path remains.
assert_contains "bare path preserved after wrapper strip" "$prompt" "/var/folders/q/widget.sh:7"
assert_contains "✓ mark preserved (post-ANSI-strip)" "$prompt" "✓ widget ok"

# ─── 3. Decoration stripped from every source field ──────────────────────────
# The hardcoded review_instructions block legitimately mentions
# `<out-of-scope-context>` as instructional text describing the redactor's
# marker; assertions below look at the SPLICED portion only (everything from
# the diff-stat header onward), so the instructional text is excluded.
print_test_section "3. decoration stripped"

splice_start=$(grep -n '^## Changed files' <<< "$prompt" | head -n 1 | cut -d: -f1)
spliced="$(tail -n +"$splice_start" <<< "$prompt")"

if grep -qF '<out-of-scope-context>' <<< "$spliced"; then
    assert_fail "no redaction-tag wrappers (in spliced content)" "still present"
else
    assert_pass "no redaction-tag wrappers (in spliced content)"
fi

if grep -qF '══' <<< "$spliced"; then
    assert_fail "no heavy banner / separator chars" "still present"
else
    assert_pass "no heavy banner / separator chars"
fi

if grep -qF '──' <<< "$spliced"; then
    assert_fail "no light banner / separator chars" "still present"
else
    assert_pass "no light banner / separator chars"
fi

if printf '%s' "$prompt" | grep -qE $'\x1b\\['; then
    assert_fail "no ANSI CSI sequences" "still present"
else
    assert_pass "no ANSI CSI sequences"
fi

if grep -qF 'more lines · full at' <<< "$spliced"; then
    assert_fail "no truncation footer" "still present"
else
    assert_pass "no truncation footer"
fi

cleanup_test_env
print_test_results
