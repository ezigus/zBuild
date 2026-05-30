#!/usr/bin/env bash
# Integration test (#483): producer-side banner rendering across the
# subprocess boundary. Plan and review must opt into the renderer registry
# such that the stage-io OUTPUT banner shows rendered markdown instead of
# raw JSON when the real claude stub is on PATH.
#
# This test exercises:
#   - real route_to_model (no shadow)
#   - real capture_stage_io
#   - real install_envelope_mock_claude binary on PATH
#   - real render_artifact dispatch through the registry
# and captures fd 3 (ZBUILD_STAGE_IO_FD) to assert the banner content.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "agent-stage banner: rendered markdown across subprocess boundary (#483)"

setup_test_env "agent-banner-rendered-md"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

export ZBUILD_RUN_ID="banner-md-test-$$"
mkdir -p "$TEST_TEMP_DIR/bin"
export PATH="$TEST_TEMP_DIR/bin:$PATH"

STATE_DIR="$TEST_TEMP_DIR/state"
STATE_FILE="$STATE_DIR/pipeline-state.json"
ARTIFACTS_DIR="$STATE_DIR/artifacts"
mkdir -p "$STATE_DIR" "$ARTIFACTS_DIR"
echo '{"schema_version":1,"run_id":"banner-md-test","issue":"999","stage_statuses":{}}' > "$STATE_FILE"

cat > "$STATE_DIR/scope-manifest.md" <<'SCOPE'
+ core/
+ plugins/
SCOPE

# ─── Plan banner test ───────────────────────────────────────────────────────
print_test_section "plan stage OUTPUT banner renders via render_plan_md (#483)"

PLAN_CANNED="$TEST_TEMP_DIR/plan-canned.json"
printf '%s\n' '{"schema_version":1,"title":"Boundary Plan","goal":"render across exec","steps":[{"id":"step-1","description":"d","files":["core/foo.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}' > "$PLAN_CANNED"
install_envelope_mock_claude --file "$PLAN_CANNED"

# Enable stage-io capture for the plan stage (stdout dest).
export ZBUILD_CURRENT_STAGE=plan
export _TPL_STAGE_IO_DESTS_plan="stdout"
PLAN_BANNER="$TEST_TEMP_DIR/plan-banner.txt"
: > "$PLAN_BANNER"
exec 3>"$PLAN_BANNER"
export ZBUILD_STAGE_IO_FD=3

# shellcheck source=../../plugins/agent/plan/plugin.sh
source "$REPO_ROOT/plugins/agent/plan/plugin.sh"

export ZBUILD_GOAL="banner integration test"
export ZBUILD_ISSUE=999

set +e
plan_run "plan" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e

exec 3>&-
unset ZBUILD_STAGE_IO_FD ZBUILD_CURRENT_STAGE _TPL_STAGE_IO_DESTS_plan

assert_eq "plan_run rc=0 with banner capture on" "0" "$rc"

plan_banner_content="$(cat "$PLAN_BANNER" 2>/dev/null || true)"
if printf '%s' "$plan_banner_content" | grep -qF "# Plan: Boundary Plan"; then
    assert_pass "plan banner contains rendered markdown heading across subprocess"
else
    assert_fail "plan banner missing markdown heading across subprocess" \
        "got: $(printf '%s' "$plan_banner_content" | head -40)"
fi

plan_output_section="$(printf '%s' "$plan_banner_content" | sed -n '/── output ──/,/── end stage-io/p')"
if printf '%s' "$plan_output_section" | grep -qF '"title":"Boundary Plan"'; then
    assert_fail "plan banner raw JSON leaked into output section" \
        "got: $(printf '%s' "$plan_output_section" | head -20)"
else
    assert_pass "plan banner output section free of raw JSON"
fi

# ─── Review banner test ─────────────────────────────────────────────────────
print_test_section "review stage OUTPUT banner renders via render_review_md (#483)"

# Reset events log for clean review run
: > "$ZBUILD_EVENTS_JSONL"

REVIEW_CANNED="$TEST_TEMP_DIR/review-canned.json"
printf '%s\n' '{"verdict":"approve","confidence":0.92,"issues":[],"summary":"banner integration ok"}' > "$REVIEW_CANNED"
install_envelope_mock_claude --file "$REVIEW_CANNED"

# Fixture inputs for review
REV_FIX="$TEST_TEMP_DIR/review-fixtures"
mkdir -p "$REV_FIX"
cat > "$REV_FIX/plan.json" <<'EOF'
{"schema_version":1,"goal":"banner","steps":[{"id":"step-1","description":"d","files":["core/foo.sh"],"estimated_lines":1}]}
EOF
cat > "$REV_FIX/diff.patch" <<'EOF'
diff --git a/core/foo.sh b/core/foo.sh
new file mode 100644
--- /dev/null
+++ b/core/foo.sh
@@ -0,0 +1,1 @@
+echo hi
EOF
cat > "$REV_FIX/test-results.json" <<'EOF'
{"passed":1,"failed":0}
EOF

export ZBUILD_CURRENT_STAGE=review
export _TPL_STAGE_IO_DESTS_review="stdout"
REVIEW_BANNER="$TEST_TEMP_DIR/review-banner.txt"
: > "$REVIEW_BANNER"
exec 3>"$REVIEW_BANNER"
export ZBUILD_STAGE_IO_FD=3

# shellcheck source=../../plugins/agent/review/plugin.sh
source "$REPO_ROOT/plugins/agent/review/plugin.sh"

REV_OUT="$REV_FIX/review.json"
set +e
_review_run_inner \
    "$STATE_DIR/scope-manifest.md" \
    "$REV_FIX/plan.json" \
    "$REV_FIX/diff.patch" \
    "$REV_FIX/test-results.json" \
    "$REV_OUT" \
    "$REV_FIX" >/dev/null 2>&1
rc=$?
set -e

exec 3>&-
unset ZBUILD_STAGE_IO_FD ZBUILD_CURRENT_STAGE _TPL_STAGE_IO_DESTS_review

assert_eq "_review_run_inner rc=0 with banner capture on" "0" "$rc"

review_banner_content="$(cat "$REVIEW_BANNER" 2>/dev/null || true)"
if printf '%s' "$review_banner_content" | grep -qF "# Review"; then
    assert_pass "review banner contains rendered markdown heading across subprocess"
else
    assert_fail "review banner missing markdown heading across subprocess" \
        "got: $(printf '%s' "$review_banner_content" | head -40)"
fi
if printf '%s' "$review_banner_content" | grep -qF "**Verdict:** approve"; then
    assert_pass "review banner contains Verdict field"
else
    assert_fail "review banner missing Verdict field" \
        "got: $(printf '%s' "$review_banner_content" | head -40)"
fi

review_output_section="$(printf '%s' "$review_banner_content" | sed -n '/── output ──/,/── end stage-io/p')"
if printf '%s' "$review_output_section" | grep -qF '"verdict":"approve"'; then
    assert_fail "review banner raw JSON leaked into output section" \
        "got: $(printf '%s' "$review_output_section" | head -20)"
else
    assert_pass "review banner output section free of raw JSON"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
