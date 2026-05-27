#!/usr/bin/env bash
# Tests: plugins/agent/review — review stage agent plugin (issue #343)
# Verifies: init env, approve/request_changes/block verdicts, invalid verdict
# fallback, finalize, cleanup.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugin: review (issue #343)"

setup_test_env "plugin-review"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"

# Wire run_id so the router C6 precondition can be bypassed via mock.
export ZBUILD_RUN_ID="review-test-$$"

mkdir -p "$TEST_TEMP_DIR/bin"
export PATH="$TEST_TEMP_DIR/bin:$PATH"

# ─── Source plugin (also sources event-bus, redaction, router, helpers) ─────
# shellcheck source=../../plugins/agent/review/plugin.sh
source "$REPO_ROOT/plugins/agent/review/plugin.sh"

# ─── Mock apply_scope_redaction as a passthrough ─────────────────────────────
# Overrides the real chokepoint so tests don't need a real scope manifest.
# Must be defined after sourcing plugin.sh (which sources scope-redaction.sh).
apply_scope_redaction() {
    local input="$1"
    local output="$2"
    # Remaining args (manifest, allowlist, cycle_id) ignored in mock.
    cp "$input" "$output"
    emit_event "redaction.applied" "input=$input" "output=$output" \
        "size_before=0" "size_after=0" "redactions=0" "scope_hash=mock"
    return 0
}

# ─── Minimal fixture files ────────────────────────────────────────────────────
FIXTURE_DIR="$TEST_TEMP_DIR/fixtures"
mkdir -p "$FIXTURE_DIR"

cat > "$FIXTURE_DIR/plan.json" <<'EOF'
{"goal":"Add user authentication","steps":["Create login endpoint","Add session handling"],"schema_version":1}
EOF

cat > "$FIXTURE_DIR/diff.patch" <<'EOF'
--- a/src/auth.sh
+++ b/src/auth.sh
@@ -0,0 +1,10 @@
+#!/usr/bin/env bash
+# Login endpoint
+login_user() {
+    local user="$1" pass="$2"
+    validate_credentials "$user" "$pass"
+}
EOF

SCOPE_MANIFEST="$TEST_TEMP_DIR/scope.md"
printf '+ src/\n+ tests/\n' > "$SCOPE_MANIFEST"

ARTIFACT_DIR="$TEST_TEMP_DIR/artifacts"
mkdir -p "$ARTIFACT_DIR"

# ─── Helper: write a mock route_to_model that emits a canned LLM response ────
# We mock the claude binary (route_to_model calls it internally) and set
# ZBUILD_SCOPE_OVERRIDE + token so --skip-precondition works; here we instead
# mock apply_scope_redaction above to emit redaction.applied, which satisfies
# the C6 precondition check in route_to_model.
_install_claude_mock() {
    local response_json="$1"
    cat > "$TEST_TEMP_DIR/bin/claude" <<MOCK
#!/usr/bin/env bash
printf '%s\n' '${response_json}'
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/claude"
}

# ─── Test 1: review_stage_init sets env vars ─────────────────────────────────
print_test_section "1. review_stage_init sets env"
unset ZBUILD_PLUGIN ZBUILD_PLUGIN_KIND 2>/dev/null || true
review_stage_init >/dev/null 2>&1
assert_eq "ZBUILD_PLUGIN=review after init" "review" "${ZBUILD_PLUGIN:-}"
assert_eq "ZBUILD_PLUGIN_KIND=agent after init" "agent" "${ZBUILD_PLUGIN_KIND:-}"

# ─── Test 2: approve verdict ──────────────────────────────────────────────────
print_test_section "2. approve verdict"
APPROVE_RESPONSE='{"verdict":"approve","confidence":0.95,"issues":[],"summary":"LGTM"}'
_install_claude_mock "$APPROVE_RESPONSE"

OUTPUT_APPROVE="$ARTIFACT_DIR/review-approve.json"
set +e
_review_stage_run_inner \
    "$SCOPE_MANIFEST" \
    "$FIXTURE_DIR/plan.json" \
    "$FIXTURE_DIR/diff.patch" \
    "$FIXTURE_DIR/test-results.json" \
    "$OUTPUT_APPROVE" \
    "$ARTIFACT_DIR" >/dev/null 2>&1
rc=$?
set -e

assert_eq "approve: rc=0" "0" "$rc"
assert_file_exists "approve: review.json created" "$OUTPUT_APPROVE"
v="$(jq -r '.verdict' "$OUTPUT_APPROVE")"
assert_eq "approve: verdict=approve" "approve" "$v"
sv="$(jq -r '.schema_version' "$OUTPUT_APPROVE")"
assert_eq "approve: schema_version=1" "1" "$sv"
conf="$(jq -r '.confidence' "$OUTPUT_APPROVE")"
assert_eq "approve: confidence=0.95" "0.95" "$conf"

# ─── Test 3: request_changes verdict ─────────────────────────────────────────
print_test_section "3. request_changes verdict"
RC_RESPONSE='{"verdict":"request_changes","confidence":0.7,"issues":["test coverage low"],"summary":"needs work"}'
_install_claude_mock "$RC_RESPONSE"

OUTPUT_RC="$ARTIFACT_DIR/review-rc.json"
set +e
_review_stage_run_inner \
    "$SCOPE_MANIFEST" \
    "$FIXTURE_DIR/plan.json" \
    "$FIXTURE_DIR/diff.patch" \
    "$FIXTURE_DIR/test-results.json" \
    "$OUTPUT_RC" \
    "$ARTIFACT_DIR" >/dev/null 2>&1
rc=$?
set -e

assert_eq "request_changes: rc=0" "0" "$rc"
assert_file_exists "request_changes: review.json created" "$OUTPUT_RC"
v="$(jq -r '.verdict' "$OUTPUT_RC")"
assert_eq "request_changes: verdict=request_changes" "request_changes" "$v"
ic="$(jq '.issues | length' "$OUTPUT_RC")"
assert_eq "request_changes: issues count=1" "1" "$ic"

# ─── Test 4: block verdict ────────────────────────────────────────────────────
print_test_section "4. block verdict"
BLOCK_RESPONSE='{"verdict":"block","confidence":0.99,"issues":["security hole"],"summary":"dangerous"}'
_install_claude_mock "$BLOCK_RESPONSE"

OUTPUT_BLOCK="$ARTIFACT_DIR/review-block.json"
set +e
_review_stage_run_inner \
    "$SCOPE_MANIFEST" \
    "$FIXTURE_DIR/plan.json" \
    "$FIXTURE_DIR/diff.patch" \
    "$FIXTURE_DIR/test-results.json" \
    "$OUTPUT_BLOCK" \
    "$ARTIFACT_DIR" >/dev/null 2>&1
rc=$?
set -e

assert_eq "block: rc=0" "0" "$rc"
assert_file_exists "block: review.json created" "$OUTPUT_BLOCK"
v="$(jq -r '.verdict' "$OUTPUT_BLOCK")"
assert_eq "block: verdict=block" "block" "$v"

# ─── Test 5: invalid verdict → defaults to request_changes ───────────────────
print_test_section "5. invalid verdict → defaults to request_changes"
INVALID_RESPONSE='{"verdict":"garbage","confidence":0.5,"issues":[],"summary":"wat"}'
_install_claude_mock "$INVALID_RESPONSE"

OUTPUT_INVALID="$ARTIFACT_DIR/review-invalid.json"
set +e
_review_stage_run_inner \
    "$SCOPE_MANIFEST" \
    "$FIXTURE_DIR/plan.json" \
    "$FIXTURE_DIR/diff.patch" \
    "$FIXTURE_DIR/test-results.json" \
    "$OUTPUT_INVALID" \
    "$ARTIFACT_DIR" >/dev/null 2>&1
rc=$?
set -e

assert_eq "invalid verdict: rc=0" "0" "$rc"
assert_file_exists "invalid verdict: review.json created" "$OUTPUT_INVALID"
v="$(jq -r '.verdict' "$OUTPUT_INVALID")"
assert_eq "invalid verdict: defaults to request_changes" "request_changes" "$v"
# Issues list should contain a note about the invalid verdict
note_count="$(jq '[.issues[] | select(test("invalid verdict|garbage"; "i"))] | length' "$OUTPUT_INVALID" 2>/dev/null || echo 0)"
assert_gt "invalid verdict: note injected into issues" "$note_count" "0"

# ─── Test 6: review_stage_finalize runs cleanly ───────────────────────────────
print_test_section "6. review_stage_finalize rc=0"
set +e
review_stage_finalize >/dev/null 2>&1
rc=$?
set -e
assert_eq "finalize: rc=0" "0" "$rc"

# Verify finalize event emitted
if [[ -f "$ZBUILD_EVENTS_JSONL" ]]; then
    fin_count="$(grep -c '"plugin.finalize.complete"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || echo 0)"
    if [[ "$fin_count" -ge 1 ]]; then
        assert_pass "finalize: plugin.finalize.complete event emitted"
    else
        assert_fail "finalize: expected plugin.finalize.complete in event log"
    fi
else
    assert_fail "finalize: events.jsonl not found"
fi

# ─── Bonus: review_stage_cleanup runs cleanly ────────────────────────────────
print_test_section "cleanup: rc=0"
set +e
review_stage_cleanup >/dev/null 2>&1
rc=$?
set -e
assert_eq "cleanup: rc=0" "0" "$rc"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
