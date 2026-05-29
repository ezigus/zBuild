#!/usr/bin/env bash
# Tests: plugins/agent/review — review stage agent plugin (issue #343)
# Verifies: init env, approve/request_changes/block verdicts, invalid verdict
# fallback, finalize, cleanup.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../scripts/lib/test-helpers.sh
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

# ─── Source plugin (also sources event-bus, redaction, router, helpers) ──────
# shellcheck source=../../../../plugins/agent/review/plugin.sh
source "$REPO_ROOT/plugins/agent/review/plugin.sh"

# ─── Real redaction chokepoint (issue #360) ───────────────────────────────────
# Previously this file stubbed apply_scope_redaction with `cp` passthrough,
# which meant a regression bypassing the chokepoint would still pass the test.
# Per ADR-004 the chokepoint is the single safety primitive between any
# zBuild plugin and an LLM call — it MUST run for real in tests.
#
# We use the shared fixture scope-manifest that allows only tests/, so the
# diff content (which references src/auth.sh) is guaranteed to be redacted
# and redactions>0 in the redaction.applied event. The assertion below
# verifies both that the event was emitted and that it represents real
# redaction work, not a passthrough.

# ─── Minimal fixture files ─────────────────────────────────────────────────────
FIXTURE_DIR="$TEST_TEMP_DIR/fixtures"
mkdir -p "$FIXTURE_DIR"

cat > "$FIXTURE_DIR/plan.json" <<'EOF'
{"goal":"Add user authentication","steps":["Create login endpoint","Add session handling"],"schema_version":1}
EOF

# Diff intentionally references src/auth.sh — paths OUTSIDE the scope manifest
# (which allows tests/ only) so the real chokepoint must redact them.
# ADR-018 (#470): review now renders the diff as markdown for the LLM, which
# wraps hunks in ```diff fences (preserved verbatim by ADR-004 redaction).
# Use a proper `diff --git` header so render_diff_md emits a `## a/src/...`
# heading OUTSIDE the fence — that heading still gets redacted, keeping the
# redactions>0 invariant intact.
cat > "$FIXTURE_DIR/diff.patch" <<'EOF'
diff --git a/src/auth.sh b/src/auth.sh
new file mode 100644
--- /dev/null
+++ b/src/auth.sh
@@ -0,0 +1,10 @@
+#!/usr/bin/env bash
+# Login endpoint at src/auth.sh
+login_user() {
+    local user="$1" pass="$2"
+    validate_credentials "$user" "$pass"
+}
EOF

# Use the shared fixture manifest: allows only tests/, so src/auth.sh redacts.
SCOPE_MANIFEST="$REPO_ROOT/tests/fixtures/redaction/scope-tests-only.md"

ARTIFACT_DIR="$TEST_TEMP_DIR/artifacts"
mkdir -p "$ARTIFACT_DIR"

# ─── Helper: install a mock claude binary returning canned JSON ───────────────
# route_to_model calls the claude binary internally; we mock it here.
# apply_scope_redaction mock above emits redaction.applied, satisfying the
# C6 precondition in route_to_model without needing ZBUILD_SCOPE_OVERRIDE.
_install_claude_mock() {
    local response_json="$1"
    local mock_stdout_file="$TEST_TEMP_DIR/mock-claude-stdout"
    printf '%s\n' "$response_json" > "$mock_stdout_file"
    cat > "$TEST_TEMP_DIR/bin/claude" <<MOCK
#!/usr/bin/env bash
cat "$mock_stdout_file"
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/claude"
}

# ─── Test 1: review_init sets env vars ───────────────────────────────────────
print_test_section "1. review_init sets env"
unset ZBUILD_PLUGIN ZBUILD_PLUGIN_KIND 2>/dev/null || true
review_init >/dev/null 2>&1
assert_eq "ZBUILD_PLUGIN=review after init" "review" "${ZBUILD_PLUGIN:-}"
assert_eq "ZBUILD_PLUGIN_KIND=agent after init" "agent" "${ZBUILD_PLUGIN_KIND:-}"

# ─── Test 2: approve verdict ───────────────────────────────────────────────────
print_test_section "2. approve verdict"
_install_claude_mock '{"verdict":"approve","confidence":0.95,"issues":[],"summary":"LGTM"}'

OUTPUT_APPROVE="$ARTIFACT_DIR/review-approve.json"
set +e
_review_run_inner \
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

# ─── Test 3: request_changes verdict ──────────────────────────────────────────
print_test_section "3. request_changes verdict"
_install_claude_mock '{"verdict":"request_changes","confidence":0.7,"issues":["test coverage low"],"summary":"needs work"}'

OUTPUT_RC="$ARTIFACT_DIR/review-rc.json"
set +e
_review_run_inner \
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

# ─── Test 4: block verdict ─────────────────────────────────────────────────────
print_test_section "4. block verdict"
_install_claude_mock '{"verdict":"block","confidence":0.99,"issues":["security hole"],"summary":"dangerous"}'

OUTPUT_BLOCK="$ARTIFACT_DIR/review-block.json"
set +e
_review_run_inner \
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

# ─── Test 5: invalid verdict → defaults to request_changes ────────────────────
print_test_section "5. invalid verdict -> defaults to request_changes"
_install_claude_mock '{"verdict":"garbage","confidence":0.5,"issues":[],"summary":"wat"}'

OUTPUT_INVALID="$ARTIFACT_DIR/review-invalid.json"
set +e
_review_run_inner \
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
# Issues list must contain a note about the invalid verdict
note_count="$(jq '[.issues[] | select(test("invalid verdict|garbage"; "i"))] | length' "$OUTPUT_INVALID" 2>/dev/null || echo 0)"
assert_gt "invalid verdict: note injected into issues" "$note_count" "0"

# ─── Test 6: review_finalize runs cleanly ────────────────────────────────────
print_test_section "6. review_finalize rc=0"
set +e
review_finalize >/dev/null 2>&1
rc=$?
set -e
assert_eq "finalize: rc=0" "0" "$rc"

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

# ─── Test 7: redaction chokepoint asserted (issue #360) ───────────────────────
# Per ADR-004 every LLM-bound prompt must pass through apply_scope_redaction.
# Verify the real chokepoint ran (not a passthrough stub) by asserting that
# at least one redaction.applied event exists in events.jsonl with
# redactions > 0 — proving the manifest was honored and out-of-scope paths
# (src/auth.sh in the diff fixture) were rewritten.
print_test_section "7. redaction.applied emitted with redactions>0 (chokepoint live)"

if [[ -f "$ZBUILD_EVENTS_JSONL" ]]; then
    red_events="$(jq -c 'select(.type == "redaction.applied")' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
    red_count="$(printf '%s\n' "$red_events" | grep -c . || true)"
    if [[ "$red_count" -ge 1 ]]; then
        assert_pass "redaction.applied event present ($red_count occurrences)"
    else
        assert_fail "no redaction.applied event in events.jsonl — chokepoint bypassed?"
    fi

    # At least one event must have redactions>0 (i.e. real work, not passthrough)
    max_red="$(jq -r 'select(.type == "redaction.applied") | .data.redactions // "0"' \
        "$ZBUILD_EVENTS_JSONL" 2>/dev/null \
        | awk 'BEGIN{m=0} { if ($1+0 > m) m = $1+0 } END{print m}')"
    if [[ "${max_red:-0}" -gt 0 ]]; then
        assert_pass "redaction.applied: max redactions=$max_red (>0, manifest enforced)"
    else
        assert_fail "redaction.applied present but redactions=0 — passthrough stub regression?"
    fi

    # scope_hash must be a real SHA-256 digest (64-char lowercase hex), not the
    # literal "mock" sentinel from the old stub, and not missing/null/empty.
    # A stale stub that emits any non-"mock" placeholder would otherwise slip
    # past a simple inequality check (Copilot review on PR #376).
    bad_hashes="$(jq -c '
        select(.type == "redaction.applied") |
        select((.data.scope_hash // "") | test("^[a-f0-9]{64}$") | not) |
        .data.scope_hash // "<missing>"
    ' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
    if [[ -z "$bad_hashes" ]]; then
        assert_pass "redaction.applied scope_hash is a valid SHA-256 (64 lowercase hex chars)"
    else
        bad_count="$(printf '%s\n' "$bad_hashes" | grep -c . || true)"
        assert_fail "redaction.applied has $bad_count non-SHA256 scope_hash value(s): $bad_hashes"
    fi
else
    assert_fail "redaction chokepoint: events.jsonl not found"
fi

# ─── Bonus: review_cleanup runs cleanly ──────────────────────────────────────
print_test_section "cleanup: rc=0"
set +e
review_cleanup >/dev/null 2>&1
rc=$?
set -e
assert_eq "cleanup: rc=0" "0" "$rc"

# ─── Test 8: prompt hygiene + ADR-018 tool-use invitation (#469) ─────────────
print_test_section "8. prompt invites Read, forbids Edit/Write/Bash (#469)"

# File-based capture: route_to_model runs inside $() in _review_run_inner,
# so variable-based capture is lost to the subshell — use a file.
_CAPTURED_REVIEW_PROMPT="$TEST_TEMP_DIR/captured-review-prompt.txt"
: > "$_CAPTURED_REVIEW_PROMPT"

# Shadow route_to_model to capture prompt arg and return a canned approve verdict
route_to_model() {
    printf '%s' "${2:-}" > "$_CAPTURED_REVIEW_PROMPT"
    printf '%s\n' '{"verdict":"approve","confidence":0.9,"issues":[],"summary":"ok"}'
    return 0
}

OUTPUT_HYGIENE="$ARTIFACT_DIR/review-hygiene.json"
set +e
_review_run_inner \
    "$SCOPE_MANIFEST" \
    "$FIXTURE_DIR/plan.json" \
    "$FIXTURE_DIR/diff.patch" \
    "$FIXTURE_DIR/test-results.json" \
    "$OUTPUT_HYGIENE" \
    "$ARTIFACT_DIR" >/dev/null 2>&1
rc=$?
set -e

assert_eq "hygiene: rc=0" "0" "$rc"

captured_prompt="$(cat "$_CAPTURED_REVIEW_PROMPT")"

# Kept hygiene tokens
if echo "$captured_prompt" | grep -q "no markdown code fences"; then
    assert_pass "prompt contains 'no markdown code fences'"
else
    assert_fail "prompt missing 'no markdown code fences'" "got: $(echo "$captured_prompt" | head -5)"
fi

if echo "$captured_prompt" | grep -qi "SINGLE JSON object"; then
    assert_pass "prompt contains 'SINGLE JSON object'"
else
    assert_fail "prompt missing 'SINGLE JSON object'" "got: $(echo "$captured_prompt" | head -5)"
fi

# NEGATIVE: the #462 "no tool calls" prohibition is lifted under ADR-018.
if echo "$captured_prompt" | grep -q "no tool calls"; then
    assert_fail "prompt still contains 'no tool calls' — should be lifted under ADR-018"
else
    assert_pass "prompt no longer forbids tool calls outright"
fi

if echo "$captured_prompt" | grep -qi "no tool-use"; then
    assert_fail "prompt still says 'no tool-use' — should be lifted under ADR-018"
else
    assert_pass "prompt does not say 'no tool-use'"
fi

# POSITIVE: invitation + the Read tool named
if echo "$captured_prompt" | grep -qi "MAY use the Read tool"; then
    assert_pass "prompt invites Read tool ('MAY use the Read tool')"
else
    assert_fail "prompt missing 'MAY use the Read tool' invitation"
fi

if echo "$captured_prompt" | grep -q "Read"; then
    assert_pass "prompt names the Read tool"
else
    assert_fail "prompt does not name Read"
fi

# POSITIVE: forbid Edit/Write/Bash explicitly
if echo "$captured_prompt" | grep -q "Edit" && \
   echo "$captured_prompt" | grep -q "Write" && \
   echo "$captured_prompt" | grep -q "Bash"; then
    assert_pass "prompt forbids Edit/Write/Bash"
else
    assert_fail "prompt does not explicitly forbid Edit/Write/Bash"
fi

# POSITIVE: <out-of-scope-context> marker awareness
if echo "$captured_prompt" | grep -q "out-of-scope-context"; then
    assert_pass "prompt mentions <out-of-scope-context> marker"
else
    assert_fail "prompt does not mention <out-of-scope-context> markers"
fi

# ─── Test 9: prompt declares read scope discipline (#469) ────────────────────
print_test_section "9. prompt declares scope-bounded reads (#469)"

if echo "$captured_prompt" | grep -qi "scope manifest"; then
    assert_pass "prompt mentions scope manifest"
else
    assert_fail "prompt does not mention scope manifest"
fi

# Read scope is explicitly limited to paths in the diff or scope manifest
if echo "$captured_prompt" | grep -qi "paths in the diff"; then
    assert_pass "prompt limits reads to paths in the diff or manifest"
else
    assert_fail "prompt does not constrain read paths"
fi

# ─── Test 10: happy-path verdict round-trip regression (#469) ────────────────
print_test_section "10. happy-path verdict round-trip (#469)"

# Same shadow route_to_model is in effect (returns valid approve JSON).
OUTPUT_HAPPY="$ARTIFACT_DIR/review-happy.json"
set +e
_review_run_inner \
    "$SCOPE_MANIFEST" \
    "$FIXTURE_DIR/plan.json" \
    "$FIXTURE_DIR/diff.patch" \
    "$FIXTURE_DIR/test-results.json" \
    "$OUTPUT_HAPPY" \
    "$ARTIFACT_DIR" >/dev/null 2>&1
rc=$?
set -e
assert_eq "happy-path: rc=0" "0" "$rc"
assert_file_exists "happy-path: review.json created" "$OUTPUT_HAPPY"
v="$(jq -r '.verdict' "$OUTPUT_HAPPY")"
assert_eq "happy-path: verdict=approve" "approve" "$v"

# ─── Test 11: audit enabled — out-of-scope Read emits violation (#469) ───────
print_test_section "11. audit mode emits review.scope.violation for out-of-scope Read (#469)"

# Truncate events log so we can count violations from this test only.
EVENTS_SNAPSHOT_LINES_T11="$(wc -l < "$ZBUILD_EVENTS_JSONL" 2>/dev/null || echo 0)"

# Shadow route_to_model: behave like the router would in JSON mode — unwrap
# .result and (critically) write tool_uses[] to ZBUILD_ROUTER_TOOL_USES_FILE.
route_to_model() {
    local envelope='{"type":"result","subtype":"success","result":"{\"verdict\":\"approve\",\"confidence\":0.9,\"issues\":[],\"summary\":\"ok\"}","tool_uses":[{"name":"Read","input":{"file_path":"src/auth.sh"}},{"name":"Read","input":{"file_path":"tests/foo.sh"}}]}'
    local tu='[{"name":"Read","input":{"file_path":"src/auth.sh"}},{"name":"Read","input":{"file_path":"tests/foo.sh"}}]'
    if [[ -n "${ZBUILD_ROUTER_TOOL_USES_FILE:-}" ]]; then
        printf '%s\n' "$tu" > "$ZBUILD_ROUTER_TOOL_USES_FILE"
    fi
    # Plugin parses bare JSON verdict — return the unwrapped .result text.
    printf '%s\n' "$(printf '%s' "$envelope" | jq -r '.result')"
    return 0
}

OUTPUT_AUDIT="$ARTIFACT_DIR/review-audit.json"
set +e
ZBUILD_REVIEW_AUDIT_TOOL_USE=1 \
_review_run_inner \
    "$SCOPE_MANIFEST" \
    "$FIXTURE_DIR/plan.json" \
    "$FIXTURE_DIR/diff.patch" \
    "$FIXTURE_DIR/test-results.json" \
    "$OUTPUT_AUDIT" \
    "$ARTIFACT_DIR" >/dev/null 2>&1
rc=$?
set -e

assert_eq "audit: rc=0" "0" "$rc"
assert_file_exists "audit: review.json still written" "$OUTPUT_AUDIT"
v="$(jq -r '.verdict' "$OUTPUT_AUDIT")"
assert_eq "audit: verdict round-trips approve (warn-only)" "approve" "$v"

# Violations recorded only for events appended after the pre-test snapshot.
NEW_EVENTS_T11="$(tail -n +$((EVENTS_SNAPSHOT_LINES_T11 + 1)) "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"

violations_src="$(printf '%s\n' "$NEW_EVENTS_T11" \
    | jq -c 'select(.type == "review.scope.violation") | select(.data.path == "src/auth.sh")' 2>/dev/null \
    | grep -c . || true)"
if [[ "${violations_src:-0}" -ge 1 ]]; then
    assert_pass "audit: review.scope.violation emitted for src/auth.sh"
else
    assert_fail "audit: expected review.scope.violation for src/auth.sh"
fi

violations_tests="$(printf '%s\n' "$NEW_EVENTS_T11" \
    | jq -c 'select(.type == "review.scope.violation") | select(.data.path == "tests/foo.sh")' 2>/dev/null \
    | grep -c . || true)"
if [[ "${violations_tests:-0}" -eq 0 ]]; then
    assert_pass "audit: NO violation for in-scope tests/foo.sh"
else
    assert_fail "audit: false-positive violation for in-scope tests/foo.sh"
fi

# ─── Test 11b: audit disabled (default) — no audit event ─────────────────────
print_test_section "11b. audit disabled by default — no audit event (#469)"

EVENTS_SNAPSHOT_LINES_T11B="$(wc -l < "$ZBUILD_EVENTS_JSONL" 2>/dev/null || echo 0)"

# Bare-JSON return path (no envelope, no side-channel write)
route_to_model() {
    printf '%s\n' '{"verdict":"approve","confidence":0.9,"issues":[],"summary":"ok"}'
    return 0
}

OUTPUT_AUDIT_OFF="$ARTIFACT_DIR/review-audit-off.json"
unset ZBUILD_REVIEW_AUDIT_TOOL_USE 2>/dev/null || true
set +e
_review_run_inner \
    "$SCOPE_MANIFEST" \
    "$FIXTURE_DIR/plan.json" \
    "$FIXTURE_DIR/diff.patch" \
    "$FIXTURE_DIR/test-results.json" \
    "$OUTPUT_AUDIT_OFF" \
    "$ARTIFACT_DIR" >/dev/null 2>&1
rc=$?
set -e

assert_eq "audit-off: rc=0" "0" "$rc"
v="$(jq -r '.verdict' "$OUTPUT_AUDIT_OFF")"
assert_eq "audit-off: verdict round-trips" "approve" "$v"

NEW_EVENTS_T11B="$(tail -n +$((EVENTS_SNAPSHOT_LINES_T11B + 1)) "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
audit_events_off="$(printf '%s\n' "$NEW_EVENTS_T11B" \
    | jq -c 'select(.type == "review.scope.violation")' 2>/dev/null \
    | grep -c . || true)"
if [[ "${audit_events_off:-0}" -eq 0 ]]; then
    assert_pass "audit-off: zero review.scope.violation events"
else
    assert_fail "audit-off: $audit_events_off review.scope.violation events emitted unexpectedly"
fi

# ─── Test 12: subprocess-boundary mock claude (#469) ─────────────────────────
# Real mock claude binary on PATH emits a full JSON envelope; the router
# (sourced inside the plugin) unwraps it and writes tool_uses[] to the
# side-channel file. This locks the contract across the actual subprocess
# boundary that route_to_model crosses in production.
print_test_section "12. subprocess-boundary: envelope mode round-trip (#469)"

# Reset router-internal guard so route_to_model goes through the real path
# (we previously shadowed it as a shell function in tests 8/10/11/11b).
# Bash `unset -f` removes the function entirely; re-source route.sh to
# restore the real definition (with guard unset first to bypass the
# idempotency check).
unset -f route_to_model 2>/dev/null || true
unset _ZBUILD_ROUTER_LOADED
# shellcheck source=../../../../core/router/route.sh
source "$REPO_ROOT/core/router/route.sh"

# Mock claude that emits the full result envelope (matches --output-format json)
cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
# Mock: always emit a result envelope regardless of args.
cat <<'JSON'
{"type":"result","subtype":"success","result":"{\"verdict\":\"approve\",\"confidence\":0.88,\"issues\":[],\"summary\":\"sub-boundary ok\"}","usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"tool_uses":[{"name":"Read","input":{"file_path":"src/auth.sh"}}]}
JSON
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"

EVENTS_SNAPSHOT_LINES_T12="$(wc -l < "$ZBUILD_EVENTS_JSONL" 2>/dev/null || echo 0)"

OUTPUT_T12="$ARTIFACT_DIR/review-t12.json"
set +e
ZBUILD_REVIEW_AUDIT_TOOL_USE=1 \
_review_run_inner \
    "$SCOPE_MANIFEST" \
    "$FIXTURE_DIR/plan.json" \
    "$FIXTURE_DIR/diff.patch" \
    "$FIXTURE_DIR/test-results.json" \
    "$OUTPUT_T12" \
    "$ARTIFACT_DIR" >/dev/null 2>&1
rc=$?
set -e

assert_eq "sub-boundary: rc=0" "0" "$rc"
assert_file_exists "sub-boundary: review.json written" "$OUTPUT_T12"
v="$(jq -r '.verdict' "$OUTPUT_T12")"
assert_eq "sub-boundary: verdict round-trips" "approve" "$v"

NEW_EVENTS_T12="$(tail -n +$((EVENTS_SNAPSHOT_LINES_T12 + 1)) "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
sub_viol="$(printf '%s\n' "$NEW_EVENTS_T12" \
    | jq -c 'select(.type == "review.scope.violation") | select(.data.path == "src/auth.sh")' 2>/dev/null \
    | grep -c . || true)"
if [[ "${sub_viol:-0}" -ge 1 ]]; then
    assert_pass "sub-boundary: violation emitted via real envelope unwrap path"
else
    assert_fail "sub-boundary: expected violation event for src/auth.sh"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
