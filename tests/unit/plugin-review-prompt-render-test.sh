#!/usr/bin/env bash
# Tests: review plugin assembles prompt with rendered markdown plan+diff (#470)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "review plugin prompt rendering (#470)"
setup_test_env "plugin-review-render"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR"

export _MOCK_ROUTE_CAPTURE="$TEST_TEMP_DIR/route-prompt.txt"

# shellcheck source=../../plugins/agent/review/plugin.sh
source "$REPO_ROOT/plugins/agent/review/plugin.sh"

# Override after source so we shadow the real route_to_model.
route_to_model() {
    printf '%s' "$2" > "$_MOCK_ROUTE_CAPTURE"
    # Return an approve verdict so review_run finishes cleanly.
    printf '%s' '{"verdict":"approve","confidence":0.9,"issues":[],"summary":"ok"}'
    return 0
}
apply_scope_redaction() {
    local in="$1" out="$2"
    cp "$in" "$out"
    return 0
}

artifact_dir="$TEST_TEMP_DIR/state/artifacts"
mkdir -p "$artifact_dir"
plan_path="$artifact_dir/plan.json"
diff_path="$artifact_dir/diff.patch"
test_path="$artifact_dir/test-results.json"
review_path="$artifact_dir/review.json"

cat > "$plan_path" <<'EOF'
{
  "title": "Review test",
  "goal": "Check review prompt markdown",
  "steps": [{"id":1,"description":"do","files":["x.sh"]}]
}
EOF

cat > "$diff_path" <<'EOF'
diff --git a/x.sh b/x.sh
--- a/x.sh
+++ b/x.sh
@@ -1,1 +1,1 @@
-a
+b
EOF

cat > "$test_path" <<'EOF'
{"status":"passed","passed":3,"failed":0}
EOF

scope_manifest="$TEST_TEMP_DIR/state/scope-manifest.md"
touch "$scope_manifest"

# #896: review now derives the LLM diff from the cwd repo's merge-base. This test
# verifies rendering of the FIXTURE diff.patch, so run it from a non-git dir where
# merge-base does not resolve → review falls back to the fixture diff.patch. (In an
# ambient git checkout, merge-base would otherwise yield the real repo diff.)
cd "$TEST_TEMP_DIR"

set +e
_review_run_inner \
    "$scope_manifest" \
    "$plan_path" \
    "$diff_path" \
    "$test_path" \
    "$review_path" \
    "$artifact_dir" >/dev/null 2>&1
rc=$?
set -e

# ─── IR1: review inner rc=0 with mocked router ───────────────────────────────
assert_eq "IR1 review inner rc=0" "0" "$rc"

captured="$(cat "$_MOCK_ROUTE_CAPTURE" 2>/dev/null || echo '')"

# ─── IR2: prompt contains markdown plan + diff sections ─────────────────────
assert_contains "IR2 plan rendered as markdown" "$captured" "# Plan: Review test"
assert_contains "IR2 diff rendered with file heading" "$captured" "## a/x.sh"

# ─── IR3: raw JSON does NOT leak into the prompt ────────────────────────────
if grep -qF '"title": "Review test"' <<< "$captured"; then
    assert_fail "IR3 raw plan JSON not in prompt" "raw plan JSON leaked"
else
    assert_pass "IR3 raw plan JSON not in prompt"
fi
# Wave 16-B (#699): test results are now spliced as a structured summary
# (verdict/passed/failed[/exit_code][/output]) extracted from the JSON via jq,
# not as the raw JSON envelope. Assert the summary fields appear.
assert_contains "IR3 test results summary verdict line" "$captured" "verdict: passed"
assert_contains "IR3 test results summary passed count" "$captured" "passed: 3"
assert_contains "IR3 test results summary failed count" "$captured" "failed: 0"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
