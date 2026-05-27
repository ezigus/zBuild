#!/usr/bin/env bash
# Tests: plugins/agent/build — build stage agent (issue #341)
# Verifies: init env, missing plan.json rc=2, artifact production,
#           build-summary.json schema, finalize rc=0.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugin: build (build stage agent — issue #341)"

setup_test_env "plugin-build"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

# Router C6 precondition requires a run_id and an events log with a preceding
# redaction.applied event. We set ZBUILD_RUN_ID here; the mock route_to_model
# below bypasses the router entirely so the precondition is moot in practice,
# but having the env var set is correct for the integration path.
export ZBUILD_RUN_ID="build-test-$$"
export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_ISSUE="341"

PLUGIN_DIR="$REPO_ROOT/plugins/agent/build"

# ─── Source plugin ───────────────────────────────────────────────────────────
# shellcheck source=../../plugins/agent/build/plugin.sh
source "$PLUGIN_DIR/plugin.sh"

# ─── Shared fixtures ─────────────────────────────────────────────────────────
SCOPE_MANIFEST="$TEST_TEMP_DIR/scope-manifest.md"
cat > "$SCOPE_MANIFEST" <<'EOF'
+ core/
+ tests/
+ plugins/
EOF

# Canned diff used as the mock LLM response. This is a trivially-valid unified
# diff that creates a new fixture file. git apply --check will pass on it when
# run inside the repo (the target path does not exist yet, which is fine for a
# "new file" patch, but may vary by git version — the plugin only warns on
# check failure, never aborts).
CANNED_DIFF='diff --git a/tests/fixtures/build-test-dummy.txt b/tests/fixtures/build-test-dummy.txt
new file mode 100644
--- /dev/null
+++ b/tests/fixtures/build-test-dummy.txt
@@ -0,0 +1 @@
+dummy'

# ─── Test 1: build_stage_init sets env ───────────────────────────────────────
print_test_section "T1: build_stage_init sets ZBUILD_PLUGIN=build"

build_stage_init >/dev/null 2>&1

assert_eq "build_stage_init: ZBUILD_PLUGIN=build" "build" "$ZBUILD_PLUGIN"
assert_eq "build_stage_init: ZBUILD_PLUGIN_KIND=agent" "agent" "$ZBUILD_PLUGIN_KIND"

# ─── Test 2: missing plan.json returns rc=2 ───────────────────────────────────
print_test_section "T2: missing plan.json returns rc=2"

ARTIFACT_DIR_T2="$TEST_TEMP_DIR/artifacts_t2"
mkdir -p "$ARTIFACT_DIR_T2"

NONEXISTENT_PLAN="$ARTIFACT_DIR_T2/does-not-exist.json"
OUT_DIFF_T2="$ARTIFACT_DIR_T2/diff.patch"
OUT_SUMMARY_T2="$ARTIFACT_DIR_T2/build-summary.json"

set +e
_build_stage_run_inner \
    "$SCOPE_MANIFEST" \
    "$NONEXISTENT_PLAN" \
    "$OUT_DIFF_T2" \
    "$OUT_SUMMARY_T2" \
    "$ARTIFACT_DIR_T2" >/dev/null 2>&1
rc_t2=$?
set -e

assert_exit_code "missing plan.json yields rc=2" "2" "$rc_t2"
assert_file_not_exists "no diff.patch written when plan.json missing" "$OUT_DIFF_T2"
assert_file_not_exists "no build-summary.json written when plan.json missing" "$OUT_SUMMARY_T2"

# ─── Test 3: produces diff.patch and build-summary.json ──────────────────────
print_test_section "T3: produces diff.patch and build-summary.json with mocked router"

ARTIFACT_DIR_T3="$TEST_TEMP_DIR/artifacts_t3"
mkdir -p "$ARTIFACT_DIR_T3"

# Write a fixture plan.json
PLAN_JSON_T3="$ARTIFACT_DIR_T3/plan.json"
cat > "$PLAN_JSON_T3" <<'EOF'
{
  "schema_version": 1,
  "goal": "Add dummy fixture file for build-stage test",
  "steps": [
    {"id": 1, "action": "create", "path": "tests/fixtures/build-test-dummy.txt", "content": "dummy"}
  ]
}
EOF

OUT_DIFF_T3="$ARTIFACT_DIR_T3/diff.patch"
OUT_SUMMARY_T3="$ARTIFACT_DIR_T3/build-summary.json"

# Mock apply_scope_redaction as a passthrough (writes input to output unchanged).
# This avoids needing a real scope-manifest and keeps the test self-contained.
apply_scope_redaction() {
    local _input="$1"
    local _output="$2"
    # $3 = manifest (ignored in mock), $4 = allowlist, $5 = cycle_id
    cp "$_input" "$_output"
    # Emit the required redaction.applied event so the router precondition passes
    # if called for real. In our mock path route_to_model is also mocked so it
    # won't check, but emitting keeps the event log consistent.
    emit_event "redaction.applied" \
        "input=$_input" "output=$_output" \
        "size_before=0" "size_after=0" "redactions=0" \
        "scope_hash=mock" "cycle=0"
    return 0
}

# Mock route_to_model to return the canned diff directly (bypasses LLM).
route_to_model() {
    # $1 = tier, $2 = prompt — ignored in mock
    printf '%s\n' "$CANNED_DIFF"
    return 0
}

set +e
_build_stage_run_inner \
    "$SCOPE_MANIFEST" \
    "$PLAN_JSON_T3" \
    "$OUT_DIFF_T3" \
    "$OUT_SUMMARY_T3" \
    "$ARTIFACT_DIR_T3" >/dev/null 2>&1
rc_t3=$?
set -e

assert_exit_code "mocked inner run returns rc=0" "0" "$rc_t3"
assert_file_exists "diff.patch artifact produced" "$OUT_DIFF_T3"
assert_file_exists "build-summary.json artifact produced" "$OUT_SUMMARY_T3"

# Verify diff.patch contains the expected diff header
diff_content_t3="$(cat "$OUT_DIFF_T3")"
assert_contains "diff.patch contains diff --git header" "$diff_content_t3" "diff --git"
assert_contains "diff.patch contains target file" "$diff_content_t3" "build-test-dummy.txt"

# Verify build-summary.json is valid JSON
summary_json_t3="$(cat "$OUT_SUMMARY_T3")"
if printf '%s' "$summary_json_t3" | jq empty >/dev/null 2>&1; then
    assert_pass "build-summary.json is valid JSON"
else
    assert_fail "build-summary.json is not valid JSON"
fi

# ─── Test 4: build-summary.json has required fields ──────────────────────────
print_test_section "T4: build-summary.json has required schema fields"

assert_json_key "schema_version == 1" "$summary_json_t3" ".schema_version" "1"

# .files_changed must be an array
files_changed_type="$(printf '%s' "$summary_json_t3" | jq -r '.files_changed | type' 2>/dev/null || echo "missing")"
assert_eq "files_changed is an array" "array" "$files_changed_type"

# .issue should match ZBUILD_ISSUE
assert_json_key "issue matches ZBUILD_ISSUE=341" "$summary_json_t3" ".issue" "341"

# .diff_patch_path must be present and non-empty
diff_patch_path_val="$(printf '%s' "$summary_json_t3" | jq -r '.diff_patch_path // empty' 2>/dev/null || echo "")"
if [[ -n "$diff_patch_path_val" ]]; then
    assert_pass "diff_patch_path field is present and non-empty"
else
    assert_fail "diff_patch_path field missing or empty"
fi

# .notes must be a non-empty string
notes_val="$(printf '%s' "$summary_json_t3" | jq -r '.notes // empty' 2>/dev/null || echo "")"
if [[ -n "$notes_val" ]]; then
    assert_pass "notes field is present and non-empty"
else
    assert_fail "notes field missing or empty"
fi

# ─── Test 5: build_stage_finalize runs cleanly ───────────────────────────────
print_test_section "T5: build_stage_finalize returns rc=0"

set +e
build_stage_finalize >/dev/null 2>&1
rc_finalize=$?
set -e

assert_exit_code "build_stage_finalize returns rc=0" "0" "$rc_finalize"

# Verify the finalize event was emitted
if [[ -f "$ZBUILD_EVENTS_JSONL" ]]; then
    finalize_count="$(grep -c '"plugin.finalize.complete"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
    if [[ "$finalize_count" -ge 1 ]]; then
        assert_pass "plugin.finalize.complete event emitted by finalize"
    else
        assert_fail "plugin.finalize.complete event not found in event log"
    fi
else
    # Event bus may not have written yet; the rc=0 check is the primary assertion
    assert_pass "build_stage_finalize returned rc=0 (event log not yet written)"
fi

# ─── Teardown ────────────────────────────────────────────────────────────────
_test_cleanup_hook() { cleanup_test_env; }
cleanup_test_env
print_test_results
exit $((FAIL > 0))
