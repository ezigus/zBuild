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

# #939 hermeticity: stub the merge-base diff source so the review prompt uses the
# test's fixture diff, not the real working-dir branch-vs-main diff. Without this
# a branch with many changed files (e.g. the #939 rename) splices the actual repo
# diff into the prompt and the redaction-count assertion sees unexpected content.
# See the matching note in tests/integration/review-issue-dod-awareness-test.sh.
zbuild_resolve_merge_base() { printf ''; }

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
# ADR-043: redaction is now owned by route_to_model, which reads the manifest
# from ZBUILD_SCOPE_MANIFEST (the runner exports it per-stage). Export it here so
# the router performs REAL redaction (redactions>0) on the review prompt — the
# plugin no longer calls apply_scope_redaction itself.
export ZBUILD_SCOPE_MANIFEST="$SCOPE_MANIFEST"

ARTIFACT_DIR="$TEST_TEMP_DIR/artifacts"
mkdir -p "$ARTIFACT_DIR"

# ─── Helper: install a passing test-results.json fixture (#485) ──────────────
# Without this fixture, _review_derive_test_status returns "unknown" and the
# review plugin coerces approve → request_changes (fail-closed contract,
# ADR-019). Tests that assert a non-`request_changes` outcome must call this
# helper FIRST. Tests asserting request_changes/block already get the right
# verdict either way.
_install_passing_test_results() {
    cat > "$FIXTURE_DIR/test-results.json" <<'EOF'
{"schema_version":1,"verdict":"pass","exit_code":0,"passed":5,"failed":0,"test_output":"5 passed","diff_applied":true,"test_cmd":"true"}
EOF
}
_remove_test_results() {
    rm -f "$FIXTURE_DIR/test-results.json"
}

# ─── Helper: install a mock claude binary returning canned JSON ───────────────
# route_to_model calls the claude binary internally; we mock it here.
# apply_scope_redaction mock above emits redaction.applied, satisfying the
# C6 precondition in route_to_model without needing ZBUILD_SCOPE_OVERRIDE.
_install_claude_mock() {
    local response_json="$1"
    local mock_stdout_file="$TEST_TEMP_DIR/mock-claude-stdout"
    printf '%s\n' "$response_json" > "$mock_stdout_file"
    # #476: delegate to the shared envelope-aware helper. Wraps payload in
    # the result envelope when invoked with --output-format json (which review
    # now does unconditionally — ADR-018 decision #8); otherwise raw text.
    install_envelope_mock_claude --file "$mock_stdout_file"
}

# ─── Test 1: review_init sets env vars ───────────────────────────────────────
print_test_section "1. review_init sets env"
unset ZBUILD_PLUGIN ZBUILD_PLUGIN_KIND 2>/dev/null || true
review_init >/dev/null 2>&1
assert_eq "ZBUILD_PLUGIN=review after init" "review" "${ZBUILD_PLUGIN:-}"
assert_eq "ZBUILD_PLUGIN_KIND=agent after init" "agent" "${ZBUILD_PLUGIN_KIND:-}"

# ─── Test 2: approve verdict ───────────────────────────────────────────────────
print_test_section "2. approve verdict"
_install_passing_test_results
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

# ─── Test 4b (#478): prose-prefixed JSON survives via parser-side helper ────
# Envelope mode (#476) separates reasoning *turns* from the final turn but
# the model can still emit prose INSIDE the final assistant message before
# its JSON. extract_first_json_object slices the LAST top-level balanced
# object out. Without the helper, this exact dogfood shape produced a
# defaulted request_changes verdict.
print_test_section "4b. #478: prose-prefixed JSON parsed correctly"
_install_passing_test_results
_install_claude_mock 'Now I have a complete picture.

{"verdict":"approve","confidence":0.9,"issues":[],"summary":"prose-prefix ok"}'

OUTPUT_PROSE="$ARTIFACT_DIR/review-prose-478.json"
set +e
_review_run_inner \
    "$SCOPE_MANIFEST" \
    "$FIXTURE_DIR/plan.json" \
    "$FIXTURE_DIR/diff.patch" \
    "$FIXTURE_DIR/test-results.json" \
    "$OUTPUT_PROSE" \
    "$ARTIFACT_DIR" >/dev/null 2>&1
rc=$?
set -e
assert_eq "#478: prose-prefixed rc=0" "0" "$rc"
assert_file_exists "#478: review.json written despite prose preface" "$OUTPUT_PROSE"
v_478="$(jq -r '.verdict' "$OUTPUT_PROSE" 2>/dev/null || echo missing)"
assert_eq "#478: verdict extracted from prose-prefixed payload" "approve" "$v_478"

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
_install_passing_test_results

# File-based capture: route_to_model runs inside $() in _review_run_inner,
# so variable-based capture is lost to the subshell — use a file.
_CAPTURED_REVIEW_PROMPT="$TEST_TEMP_DIR/captured-review-prompt.txt"
: > "$_CAPTURED_REVIEW_PROMPT"

# Shadow route_to_model to capture prompt arg and return a canned approve verdict
# Also capture ZBUILD_ROUTER_JSON_OUTPUT state for the #476 envelope-mode invariant.
_CAPTURED_REVIEW_ENVELOPE="$TEST_TEMP_DIR/captured-review-envelope.txt"
_CAPTURED_REVIEW_ARTIFACT="$TEST_TEMP_DIR/captured-review-artifact.txt"
: > "$_CAPTURED_REVIEW_ENVELOPE"
: > "$_CAPTURED_REVIEW_ARTIFACT"
route_to_model() {
    printf '%s' "${2:-}" > "$_CAPTURED_REVIEW_PROMPT"
    printf '%s' "${ZBUILD_ROUTER_JSON_OUTPUT:-unset}" > "$_CAPTURED_REVIEW_ENVELOPE"
    # #483: capture artifact-id env so we can assert review tagged the capture.
    printf '%s' "${ZBUILD_ROUTER_ARTIFACT_ID:-unset}" > "$_CAPTURED_REVIEW_ARTIFACT"
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

# #476: envelope-mode invariant on review's default path
captured_review_envelope="$(cat "$_CAPTURED_REVIEW_ENVELOPE")"
assert_eq "review exports ZBUILD_ROUTER_JSON_OUTPUT=1 on default path (#476)" \
    "1" "$captured_review_envelope"

# #483: artifact-id tag is producer-side renderer dispatch
captured_review_artifact="$(cat "$_CAPTURED_REVIEW_ARTIFACT")"
assert_eq "review exports ZBUILD_ROUTER_ARTIFACT_ID=review around route_to_model (#483)" \
    "review" "$captured_review_artifact"

captured_prompt="$(cat "$_CAPTURED_REVIEW_PROMPT")"

# Kept hygiene tokens (ADR-028 canonical phrasing).
if echo "$captured_prompt" | grep -q "NO markdown code fences"; then
    assert_pass "prompt contains 'NO markdown code fences'"
else
    assert_fail "prompt missing 'NO markdown code fences'" "got: $(echo "$captured_prompt" | head -5)"
fi

if echo "$captured_prompt" | grep -q "EXACTLY ONE JSON object"; then
    assert_pass "prompt contains 'EXACTLY ONE JSON object'"
else
    assert_fail "prompt missing 'EXACTLY ONE JSON object'" "got: $(echo "$captured_prompt" | head -5)"
fi

# #944: prompt REQUIRES schema_version:1 in the model's output so the recovery
# gate (_review_envelope_schema_ok requires .schema_version==1) can disambiguate
# the real envelope from a brace-bearing postamble. The prior "implicit (1)"
# wording told the model to omit it, which made recovery inert for review.
if echo "$captured_prompt" | grep -q "schema_version.*MUST be present"; then
    assert_pass "#944: review prompt requires schema_version:1 (aligns with recovery gate)"
else
    assert_fail "#944: review prompt must require schema_version:1" "got: $(echo "$captured_prompt" | grep -i schema_version | head -3)"
fi
if echo "$captured_prompt" | grep -qi "schema_version.*implicit"; then
    assert_fail "#944: review prompt still says schema_version is 'implicit' (contradicts the gate)"
else
    assert_pass "#944: review prompt no longer calls schema_version 'implicit'"
fi

# #478: prompt hardening — explicit "first character MUST be {" rule (canonical phrasing).
if echo "$captured_prompt" | grep -qF 'first output character MUST be `{`'; then
    assert_pass "#478: review prompt demands first output character '{'"
else
    assert_fail "#478: review prompt missing 'first character MUST be {' rule"
fi
if echo "$captured_prompt" | grep -qF "NO prose before, after, or around the JSON envelope"; then
    assert_pass "#478: review prompt forbids prose around envelope"
else
    assert_fail "#478: review prompt missing prose prohibition"
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
_install_passing_test_results

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
_install_passing_test_results

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
_install_passing_test_results

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
_install_passing_test_results

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

# ─── Test 13: #485 — passing test-results lets approve survive ───────────────
print_test_section "13. #485: test_status=passed → approve survives"

# Reset to function shadow returning approve (test 11b/12 may have changed it).
unset -f route_to_model 2>/dev/null || true
unset _ZBUILD_ROUTER_LOADED
# shellcheck source=../../../../core/router/route.sh
source "$REPO_ROOT/core/router/route.sh"

_install_passing_test_results
_install_claude_mock '{"verdict":"approve","confidence":0.9,"issues":[],"summary":"all good"}'

OUTPUT_T13="$ARTIFACT_DIR/review-485-t13.json"
EVENTS_SNAPSHOT_T13="$(wc -l < "$ZBUILD_EVENTS_JSONL" 2>/dev/null || echo 0)"
set +e
_review_run_inner \
    "$SCOPE_MANIFEST" \
    "$FIXTURE_DIR/plan.json" \
    "$FIXTURE_DIR/diff.patch" \
    "$FIXTURE_DIR/test-results.json" \
    "$OUTPUT_T13" \
    "$ARTIFACT_DIR" >/dev/null 2>&1
rc=$?
set -e
assert_eq "#485 t13: rc=0" "0" "$rc"
v="$(jq -r '.verdict' "$OUTPUT_T13")"
assert_eq "#485 t13: verdict stays approve when tests pass" "approve" "$v"
NEW_T13="$(tail -n +$((EVENTS_SNAPSHOT_T13 + 1)) "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
coerce_t13="$(printf '%s\n' "$NEW_T13" | jq -c 'select(.type == "review.test_status.coerced")' 2>/dev/null | grep -c . || true)"
if [[ "${coerce_t13:-0}" -eq 0 ]]; then
    assert_pass "#485 t13: no coercion event when tests pass"
else
    assert_fail "#485 t13: unexpected coercion event ($coerce_t13)"
fi

# ─── Test 14: #485 — missing test-results.json + approve → coerced ───────────
print_test_section "14. #485: missing test-results + approve → request_changes"
_remove_test_results
_install_claude_mock '{"verdict":"approve","confidence":0.95,"issues":[],"summary":"LGTM"}'

OUTPUT_T14="$ARTIFACT_DIR/review-485-t14.json"
EVENTS_SNAPSHOT_T14="$(wc -l < "$ZBUILD_EVENTS_JSONL" 2>/dev/null || echo 0)"
set +e
_review_run_inner \
    "$SCOPE_MANIFEST" \
    "$FIXTURE_DIR/plan.json" \
    "$FIXTURE_DIR/diff.patch" \
    "$FIXTURE_DIR/test-results.json" \
    "$OUTPUT_T14" \
    "$ARTIFACT_DIR" >/dev/null 2>&1
rc=$?
set -e
assert_eq "#485 t14: rc=0" "0" "$rc"
v="$(jq -r '.verdict' "$OUTPUT_T14")"
assert_eq "#485 t14: approve coerced to request_changes" "request_changes" "$v"
NEW_T14="$(tail -n +$((EVENTS_SNAPSHOT_T14 + 1)) "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
coerce_t14="$(printf '%s\n' "$NEW_T14" | jq -c 'select(.type == "review.test_status.coerced")' 2>/dev/null | grep -c . || true)"
if [[ "${coerce_t14:-0}" -ge 1 ]]; then
    assert_pass "#485 t14: review.test_status.coerced event emitted"
else
    assert_fail "#485 t14: missing coercion event"
fi
ts_t14="$(printf '%s\n' "$NEW_T14" | jq -r 'select(.type == "review.test_status.coerced") | .data.test_status' 2>/dev/null | head -1)"
assert_eq "#485 t14: test_status=unknown" "unknown" "$ts_t14"
# Issues list includes the synthetic coercion note.
note_t14="$(jq '[.issues[] | select(test("coerced to request_changes"; "i"))] | length' "$OUTPUT_T14")"
assert_gt "#485 t14: coercion note injected into issues" "$note_t14" "0"

# ─── Test 15a: #485 — verdict=fail + LLM approve → coerced ───────────────────
print_test_section "15a. #485: tests failed + LLM approve → request_changes"
cat > "$FIXTURE_DIR/test-results.json" <<'EOF'
{"schema_version":1,"verdict":"fail","exit_code":1,"passed":2,"failed":3,"test_output":"2 passed, 3 failed","diff_applied":true,"test_cmd":"npm test"}
EOF
_install_claude_mock '{"verdict":"approve","confidence":0.9,"issues":[],"summary":"looks ok"}'

OUTPUT_T15A="$ARTIFACT_DIR/review-485-t15a.json"
EVENTS_SNAPSHOT_T15A="$(wc -l < "$ZBUILD_EVENTS_JSONL" 2>/dev/null || echo 0)"
set +e
_review_run_inner \
    "$SCOPE_MANIFEST" \
    "$FIXTURE_DIR/plan.json" \
    "$FIXTURE_DIR/diff.patch" \
    "$FIXTURE_DIR/test-results.json" \
    "$OUTPUT_T15A" \
    "$ARTIFACT_DIR" >/dev/null 2>&1
rc=$?
set -e
assert_eq "#485 t15a: rc=0" "0" "$rc"
v="$(jq -r '.verdict' "$OUTPUT_T15A")"
assert_eq "#485 t15a: approve → request_changes when tests failed" "request_changes" "$v"
NEW_T15A="$(tail -n +$((EVENTS_SNAPSHOT_T15A + 1)) "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
ts_t15a="$(printf '%s\n' "$NEW_T15A" | jq -r 'select(.type == "review.test_status.coerced") | .data.test_status' 2>/dev/null | head -1)"
assert_eq "#485 t15a: test_status=failed" "failed" "$ts_t15a"

# ─── Test 15b: #485 — verdict=fail + LLM request_changes stays unchanged ─────
print_test_section "15b. #485: tests failed + LLM request_changes stays"
_install_claude_mock '{"verdict":"request_changes","confidence":0.6,"issues":["small issue"],"summary":"needs work"}'

OUTPUT_T15B="$ARTIFACT_DIR/review-485-t15b.json"
EVENTS_SNAPSHOT_T15B="$(wc -l < "$ZBUILD_EVENTS_JSONL" 2>/dev/null || echo 0)"
set +e
_review_run_inner \
    "$SCOPE_MANIFEST" \
    "$FIXTURE_DIR/plan.json" \
    "$FIXTURE_DIR/diff.patch" \
    "$FIXTURE_DIR/test-results.json" \
    "$OUTPUT_T15B" \
    "$ARTIFACT_DIR" >/dev/null 2>&1
rc=$?
set -e
assert_eq "#485 t15b: rc=0" "0" "$rc"
v="$(jq -r '.verdict' "$OUTPUT_T15B")"
assert_eq "#485 t15b: request_changes stays" "request_changes" "$v"
NEW_T15B="$(tail -n +$((EVENTS_SNAPSHOT_T15B + 1)) "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
coerce_t15b="$(printf '%s\n' "$NEW_T15B" | jq -c 'select(.type == "review.test_status.coerced")' 2>/dev/null | grep -c . || true)"
if [[ "${coerce_t15b:-0}" -eq 0 ]]; then
    assert_pass "#485 t15b: no coercion for request_changes verdict"
else
    assert_fail "#485 t15b: unexpected coercion event ($coerce_t15b)"
fi

# ─── Test 15c: #485 — verdict=fail + LLM block stays block (floor) ───────────
print_test_section "15c. #485: tests failed + LLM block stays block"
_install_claude_mock '{"verdict":"block","confidence":0.99,"issues":["critical"],"summary":"dangerous"}'

OUTPUT_T15C="$ARTIFACT_DIR/review-485-t15c.json"
EVENTS_SNAPSHOT_T15C="$(wc -l < "$ZBUILD_EVENTS_JSONL" 2>/dev/null || echo 0)"
set +e
_review_run_inner \
    "$SCOPE_MANIFEST" \
    "$FIXTURE_DIR/plan.json" \
    "$FIXTURE_DIR/diff.patch" \
    "$FIXTURE_DIR/test-results.json" \
    "$OUTPUT_T15C" \
    "$ARTIFACT_DIR" >/dev/null 2>&1
rc=$?
set -e
assert_eq "#485 t15c: rc=0" "0" "$rc"
v="$(jq -r '.verdict' "$OUTPUT_T15C")"
assert_eq "#485 t15c: block stays block (floor not demoted)" "block" "$v"
NEW_T15C="$(tail -n +$((EVENTS_SNAPSHOT_T15C + 1)) "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
coerce_t15c="$(printf '%s\n' "$NEW_T15C" | jq -c 'select(.type == "review.test_status.coerced")' 2>/dev/null | grep -c . || true)"
if [[ "${coerce_t15c:-0}" -eq 0 ]]; then
    assert_pass "#485 t15c: no coercion for block verdict"
else
    assert_fail "#485 t15c: block was coerced (should be floor)"
fi

# ─── Test 16: #485 — high confidence + tests unknown → still coerced ─────────
print_test_section "16. #485: high confidence + tests unknown → safety wins"
_remove_test_results
_install_claude_mock '{"verdict":"approve","confidence":0.99,"issues":[],"summary":"very confident"}'

OUTPUT_T16="$ARTIFACT_DIR/review-485-t16.json"
set +e
_review_run_inner \
    "$SCOPE_MANIFEST" \
    "$FIXTURE_DIR/plan.json" \
    "$FIXTURE_DIR/diff.patch" \
    "$FIXTURE_DIR/test-results.json" \
    "$OUTPUT_T16" \
    "$ARTIFACT_DIR" >/dev/null 2>&1
rc=$?
set -e
assert_eq "#485 t16: rc=0" "0" "$rc"
v="$(jq -r '.verdict' "$OUTPUT_T16")"
assert_eq "#485 t16: high-confidence approve still coerced when tests unknown" "request_changes" "$v"
# Confidence is preserved verbatim — coercion does not modify it.
conf_t16="$(jq -r '.confidence' "$OUTPUT_T16")"
assert_eq "#485 t16: confidence preserved (0.99)" "0.99" "$conf_t16"

# ─── Test 17: #485 — prompt declares the test-results requirement ────────────
print_test_section "17. #485: prompt declares 'approve requires tests passed' rule"
_install_passing_test_results
_CAPTURED_REVIEW_PROMPT_485="$TEST_TEMP_DIR/captured-review-prompt-485.txt"
: > "$_CAPTURED_REVIEW_PROMPT_485"
route_to_model() {
    printf '%s' "${2:-}" > "$_CAPTURED_REVIEW_PROMPT_485"
    printf '%s\n' '{"verdict":"approve","confidence":0.9,"issues":[],"summary":"ok"}'
    return 0
}

OUTPUT_T17="$ARTIFACT_DIR/review-485-t17.json"
set +e
_review_run_inner \
    "$SCOPE_MANIFEST" \
    "$FIXTURE_DIR/plan.json" \
    "$FIXTURE_DIR/diff.patch" \
    "$FIXTURE_DIR/test-results.json" \
    "$OUTPUT_T17" \
    "$ARTIFACT_DIR" >/dev/null 2>&1
set -e
captured_485="$(cat "$_CAPTURED_REVIEW_PROMPT_485")"
if echo "$captured_485" | grep -qi "approve verdict requires"; then
    assert_pass "#485 t17: prompt contains 'approve verdict requires' rule"
else
    assert_fail "#485 t17: prompt missing 'approve verdict requires' rule"
fi

# ─── Test 18: [SPEC-3] router rc!=0 → no review.json, no coercion (#1024) ────
# CHANGE: before #1024 a failing router caused fall-through to verdict parsing
# with empty raw_response, which defaulted to request_changes and WROTE
# review.json. After #1024 the plugin returns non-zero immediately; no artifact.
print_test_section "18. [SPEC-3] router_rc=1 → no review.json, no coercion (#1024 AC-1)"
_install_passing_test_results

_SPEC3_STATE_DIR="$(mktemp -d)"
export ZBUILD_STATE_DIR="$_SPEC3_STATE_DIR"
export ZBUILD_LLM_FAIL_THRESHOLD=99   # prevent abort so we isolate the no-artifact check

route_to_model() { return 1; }

OUTPUT_SPEC3="$ARTIFACT_DIR/review-spec3.json"
rm -f "$OUTPUT_SPEC3"
set +e
_review_run_inner \
    "$SCOPE_MANIFEST" "$FIXTURE_DIR/plan.json" "$FIXTURE_DIR/diff.patch" \
    "$FIXTURE_DIR/test-results.json" "$OUTPUT_SPEC3" "$ARTIFACT_DIR" >/dev/null 2>&1
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
    assert_pass "[SPEC-3] router_rc=1 → _review_run_inner returns non-zero"
else
    assert_fail "[SPEC-3] router_rc=1 → expected non-zero rc from _review_run_inner" "got rc=0"
fi
assert_file_not_exists "[SPEC-3] router_rc=1 → no review.json written (no coercion)" "$OUTPUT_SPEC3"
unset ZBUILD_STATE_DIR ZBUILD_LLM_FAIL_THRESHOLD
rm -rf "$_SPEC3_STATE_DIR"

# ─── Test 19: [SPEC-4] router rc=0+empty → no review.json (#1024 AC-1 guard) ─
# GUARD: the empty-envelope check (added in #476) must not regress — an rc=0
# with empty response must still be refused, producing no artifact.
print_test_section "19. [SPEC-4] router rc=0+empty → no review.json (empty-envelope guard)"
_install_passing_test_results

route_to_model() { printf ''; return 0; }

OUTPUT_SPEC4="$ARTIFACT_DIR/review-spec4.json"
rm -f "$OUTPUT_SPEC4"
set +e
_review_run_inner \
    "$SCOPE_MANIFEST" "$FIXTURE_DIR/plan.json" "$FIXTURE_DIR/diff.patch" \
    "$FIXTURE_DIR/test-results.json" "$OUTPUT_SPEC4" "$ARTIFACT_DIR" >/dev/null 2>&1
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
    assert_pass "[SPEC-4] router rc=0+empty → _review_run_inner returns non-zero"
else
    assert_fail "[SPEC-4] router rc=0+empty → expected non-zero rc" "got rc=0"
fi
assert_file_not_exists "[SPEC-4] router rc=0+empty → no review.json written" "$OUTPUT_SPEC4"

# ─── Test 20: [SPEC-6] two router failures → rc=9 (#1024 AC-2) ───────────────
# CHANGE: two consecutive failures at threshold=2 cause the second
# _review_run_inner call to return rc=9 (pipeline abort, not just rc=1).
print_test_section "20. [SPEC-6] two router failures at threshold → rc=9 (#1024 AC-2)"
_install_passing_test_results

_SPEC6_STATE_DIR="$(mktemp -d)"
export ZBUILD_STATE_DIR="$_SPEC6_STATE_DIR"
export ZBUILD_LLM_FAIL_THRESHOLD=2
export ZBUILD_RUN_ID="spec6-test-$$"
_zbuild_reset_cli_fail

route_to_model() { return 1; }

# First call: below threshold → non-zero but NOT rc=9
OUTPUT_SPEC6A="$ARTIFACT_DIR/review-spec6a.json"
rm -f "$OUTPUT_SPEC6A"
set +e
_review_run_inner \
    "$SCOPE_MANIFEST" "$FIXTURE_DIR/plan.json" "$FIXTURE_DIR/diff.patch" \
    "$FIXTURE_DIR/test-results.json" "$OUTPUT_SPEC6A" "$ARTIFACT_DIR" >/dev/null 2>&1
rc_first=$?
set -e
if [[ $rc_first -ne 0 && $rc_first -ne 9 ]]; then
    assert_pass "[SPEC-6] first failure below threshold returns non-zero but not rc=9"
else
    assert_fail "[SPEC-6] first failure should return rc=1 (not 0 or 9)" "got rc=$rc_first"
fi

# Second call: at threshold → must return rc=9
OUTPUT_SPEC6B="$ARTIFACT_DIR/review-spec6b.json"
rm -f "$OUTPUT_SPEC6B"
set +e
_review_run_inner \
    "$SCOPE_MANIFEST" "$FIXTURE_DIR/plan.json" "$FIXTURE_DIR/diff.patch" \
    "$FIXTURE_DIR/test-results.json" "$OUTPUT_SPEC6B" "$ARTIFACT_DIR" >/dev/null 2>&1
rc_second=$?
set -e
assert_eq "[SPEC-6] second failure at threshold=2 → rc=9" "9" "$rc_second"
assert_file_not_exists "[SPEC-6] no review.json written on rc=9 abort" "$OUTPUT_SPEC6B"
unset ZBUILD_STATE_DIR ZBUILD_LLM_FAIL_THRESHOLD ZBUILD_RUN_ID
rm -rf "$_SPEC6_STATE_DIR"

# ─── Test 21: [SPEC-8] postamble recovery via _review_envelope_schema_ok ─────
# CHANGE: before #944 a brace-bearing postamble caused LAST-wins to select junk
# → verdict defaulted to request_changes (no recovery). After #944 the schema-gate
# triggers _llm_recover_envelope_json and the real envelope is used.
print_test_section "21. [SPEC-8] postamble recovery — review plugin selects real envelope"
_install_passing_test_results

_SPEC8_STATE_DIR="$(mktemp -d)"
export ZBUILD_STATE_DIR="$_SPEC8_STATE_DIR"
export ZBUILD_LLM_FAIL_THRESHOLD=99

# Real envelope first, brace-bearing postamble last.
route_to_model() {
    printf '%s' '{"schema_version":1,"verdict":"approve","confidence":0.9,"issues":[],"summary":"LGTM"} Analysis: {"note":"postamble-junk"}'
    return 0
}

OUTPUT_SPEC8="$ARTIFACT_DIR/review-spec8.json"
rm -f "$OUTPUT_SPEC8"
set +e
_review_run_inner \
    "$SCOPE_MANIFEST" "$FIXTURE_DIR/plan.json" "$FIXTURE_DIR/diff.patch" \
    "$FIXTURE_DIR/test-results.json" "$OUTPUT_SPEC8" "$ARTIFACT_DIR" >/dev/null 2>&1
rc=$?
set -e
assert_eq "[SPEC-8] postamble recovery → _review_run_inner returns rc=0" "0" "$rc"
assert_file_exists "[SPEC-8] postamble recovery → review.json written" "$OUTPUT_SPEC8"
_spec8_verdict="$(jq -r '.verdict // empty' "$OUTPUT_SPEC8" 2>/dev/null || true)"
assert_eq "[SPEC-8] postamble recovery → recovered envelope verdict=approve (not defaulted)" \
    "approve" "$_spec8_verdict"
unset ZBUILD_STATE_DIR ZBUILD_LLM_FAIL_THRESHOLD
rm -rf "$_SPEC8_STATE_DIR"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
