#!/usr/bin/env bash
# Tests: plugins/agent/security-lens — first agent plugin POC.
# Proves the end-to-end migration loop: discovery, redaction chokepoint,
# event bus emission, typed findings.json output.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugin: security-lens (first POC)"

setup_test_env "plugin-security-lens"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"

# #289: router C6 precondition now refuses fail-closed when ZBUILD_RUN_ID is
# unset. This integration test exercises the full chokepoint flow (security-lens
# emits redaction.applied via apply_scope_redaction, then calls route_to_model),
# so we need a run_id wired in for the precondition check to find the
# preceding redaction.applied event.
export ZBUILD_RUN_ID="security-lens-test-$$"

mkdir -p "$TEST_TEMP_DIR/bin"
export PATH="$TEST_TEMP_DIR/bin:$PATH"
export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"

# Source registry + plugin (registry pulls the lifecycle helpers we'll use)
# shellcheck source=../../../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"

PLUGIN_DIR="$REPO_ROOT/plugins/agent/security-lens"

# ─── Plugin is discoverable + valid ─────────────────────────────────────────
set +e
validate_manifest "$PLUGIN_DIR/manifest.yaml" >/dev/null 2>&1
rc=$?
set -e
assert_eq "security-lens manifest validates (kind: agent + requires.core: [redaction, ...])" "0" "$rc"

discovered="$(discover_plugins "$REPO_ROOT/plugins")"
assert_contains "security-lens is discovered" "$discovered" "agent/security-lens"

# ─── Prompt provenance: text matches legacy:48-53 verbatim ──────────────────
legacy_block="$(awk 'NR>=48 && NR<=53' "$REPO_ROOT/legacy/scripts/lib/compound-audit.sh" | tr -d '\r')"
prompt_block="$(cat "$PLUGIN_DIR/prompts/security.md")"

# Both should contain these exact lines
for line in \
    "You are a Security Auditor" \
    "Command injection, path traversal, input validation gaps" \
    "Credential/secret exposure in code or logs" \
    "Authentication/authorization bypass paths" \
    "OWASP top 10 vulnerability patterns" \
    "Do NOT report non-security issues."; do
    if echo "$legacy_block" | grep -qF "$line"; then
        legacy_has=1
    else
        legacy_has=0
    fi
    if echo "$prompt_block" | grep -qF "$line"; then
        prompt_has=1
    else
        prompt_has=0
    fi
    assert_eq "verbatim line preserved: '$line'" "$legacy_has" "$prompt_has"
done

# ─── Run: refuses without scope manifest (chokepoint enforcement) ───────────
INPUT="$TEST_TEMP_DIR/input.txt"
echo "some random text that mentions auth and credential leaks" > "$INPUT"

OUTPUT="$TEST_TEMP_DIR/findings.json"

# Source plugin and call init
# shellcheck source=../../../../plugins/agent/security-lens/plugin.sh
source "$PLUGIN_DIR/plugin.sh"
# shellcheck source=../../../../core/router/route.sh
source "$REPO_ROOT/core/router/route.sh"

security_lens_init >/dev/null

# Run without scope manifest — should fail (chokepoint refuses)
set +e
_security_lens_run_inner "$INPUT" "" "$OUTPUT" 2>/dev/null
rc=$?
set -e
assert_eq "security_lens_run refuses without scope manifest (chokepoint enforcement)" "1" "$rc"

# ─── Run: with scope manifest, emits typed findings.json ────────────────────
MANIFEST="$TEST_TEMP_DIR/scope.md"
cat > "$MANIFEST" <<EOF
+ src/
+ tests/
EOF
_security_lens_run_inner "$INPUT" "$MANIFEST" "$OUTPUT" "$TEST_TEMP_DIR" >/dev/null
assert_file_exists "findings.json created" "$OUTPUT"

schema_v=$(jq -r .schema_version "$OUTPUT")
assert_eq "findings.json schema_version=1" "1" "$schema_v"

plugin_id=$(jq -r .plugin_id "$OUTPUT")
assert_eq "findings.json plugin_id=security-lens" "security-lens" "$plugin_id"

# ─── Events emitted during the run ──────────────────────────────────────────
if [[ -f "$ZBUILD_EVENTS_JSONL" ]]; then
    redaction_count=$(grep -c '"redaction.applied"' "$ZBUILD_EVENTS_JSONL" || true)
    run_complete=$(grep -c '"plugin.run.complete"' "$ZBUILD_EVENTS_JSONL" || true)
    if [[ "$redaction_count" -ge 1 ]]; then
        assert_pass "redaction.applied event emitted (chokepoint observable)"
    else
        assert_fail "expected redaction.applied event in event log"
    fi
    if [[ "$run_complete" -ge 1 ]]; then
        assert_pass "plugin.run.complete event emitted"
    else
        assert_fail "expected plugin.run.complete event in event log"
    fi
else
    assert_fail "events.jsonl was not created"
fi

# ─── Finalize ───────────────────────────────────────────────────────────────
security_lens_finalize >/dev/null
finalize_count=$(grep -c '"plugin.finalize.complete"' "$ZBUILD_EVENTS_JSONL" || true)
if [[ "$finalize_count" -ge 1 ]]; then
    assert_pass "plugin.finalize.complete event emitted"
else
    assert_fail "expected plugin.finalize.complete event"
fi

# ─── Router tests ────────────────────────────────────────────────────────────

# ─── R1/R2: happy path — valid JSON response + redaction-reach assertion ─────
echo "auth bypass credential leak" > "$INPUT"

# #476: envelope-aware via the shared helper. Plugin now exports
# ZBUILD_ROUTER_JSON_OUTPUT=1 (ADR-018 Pattern 1 decision #8); router invokes
# claude with --output-format json. Helper also records the prompt so R2 can
# assert the system prompt reaches the LLM.
install_envelope_mock_claude \
    --record-prompt "$TEST_TEMP_DIR/last_prompt" \
    '{"schema_version":1,"plugin_id":"security-lens","findings":[{"title":"SQL Injection","severity":"high","category":"injection","file":"src/db.sh:42","evidence":"unsanitized var","suggestion":"quote all variables"}]}'

OUTPUT_R="$TEST_TEMP_DIR/findings_r.json"
_security_lens_run_inner "$INPUT" "$MANIFEST" "$OUTPUT_R" "$TEST_TEMP_DIR" >/dev/null 2>&1

assert_file_exists "R1: router run creates findings.json" "$OUTPUT_R"
stub_val=$(jq -r .stub "$OUTPUT_R")
assert_eq "R1: stub is false after real LLM path" "false" "$stub_val"
title_val=$(jq -r '.findings[0].title' "$OUTPUT_R")
assert_eq "R1: findings[0].title parsed" "SQL Injection" "$title_val"
sev_val=$(jq -r '.findings[0].severity' "$OUTPUT_R")
assert_eq "R1: findings[0].severity parsed" "high" "$sev_val"

assert_file_exists "R2: last_prompt sentinel file written (route_to_model was invoked)" "$TEST_TEMP_DIR/last_prompt"
if grep -qF "You are a Security Auditor" "$TEST_TEMP_DIR/last_prompt" 2>/dev/null; then
    assert_pass "R2: system prompt assembled into LLM call (prompts/security.md present)"
else
    assert_fail "R2: system prompt missing from LLM call"
fi

# ─── R3: fenced JSON response (envelope-wrapped per #476) ─────────────────────
install_envelope_mock_claude $'```json\n{"schema_version":1,"plugin_id":"security-lens","findings":[{"title":"XSS","severity":"medium","category":"owasp-a3","file":"src/out.sh:1","evidence":"echo $var","suggestion":"escape output"}]}\n```'
OUTPUT_R3="$TEST_TEMP_DIR/findings_r3.json"
_security_lens_run_inner "$INPUT" "$MANIFEST" "$OUTPUT_R3" "$TEST_TEMP_DIR" >/dev/null 2>&1
fence_title=$(jq -r '.findings[0].title' "$OUTPUT_R3")
assert_eq "R3: fenced JSON response parsed correctly" "XSS" "$fence_title"

# ─── R4: malformed (non-JSON) response (envelope-wrapped per #476) ───────────
install_envelope_mock_claude "this is not json at all"
OUTPUT_R4="$TEST_TEMP_DIR/findings_r4.json"
set +e
_security_lens_run_inner "$INPUT" "$MANIFEST" "$OUTPUT_R4" "$TEST_TEMP_DIR" >/dev/null 2>&1
rc=$?
set -e
assert_eq "R4: malformed response returns rc=0 (fail-open)" "0" "$rc"
r4_count=$(jq '.findings | length' "$OUTPUT_R4")
assert_eq "R4: malformed response yields empty findings" "0" "$r4_count"
r4_stub=$(jq -r '.stub' "$OUTPUT_R4")
assert_eq "R4: stub is false even on parse failure" "false" "$r4_stub"

# ─── R5: empty stdout (rc=0) ─────────────────────────────────────────────────
cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
OUTPUT_R5="$TEST_TEMP_DIR/findings_r5.json"
set +e
_security_lens_run_inner "$INPUT" "$MANIFEST" "$OUTPUT_R5" "$TEST_TEMP_DIR" >/dev/null 2>&1
rc=$?
set -e
assert_eq "R5: empty response returns rc=0" "0" "$rc"
r5_count=$(jq '.findings | length' "$OUTPUT_R5")
assert_eq "R5: empty response yields empty findings" "0" "$r5_count"

# ─── R6: router rc=1 (recoverable) ───────────────────────────────────────────
cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
OUTPUT_R6="$TEST_TEMP_DIR/findings_r6.json"
set +e
_security_lens_run_inner "$INPUT" "$MANIFEST" "$OUTPUT_R6" "$TEST_TEMP_DIR" >/dev/null 2>&1
rc=$?
set -e
assert_eq "R6: router rc=1 returns plugin rc=0 (fail-open)" "0" "$rc"
r6_count=$(jq '.findings | length' "$OUTPUT_R6")
assert_eq "R6: router failure yields empty findings" "0" "$r6_count"

# ─── R7: router rc=2 (fatal) — invalid tier triggers router-internal fatal ────
# claude exit codes map to rc=1 (recoverable); rc=2 comes from router internals
# (invalid tier, missing models.json, T0). Use T9 (unknown tier) to force it.
OUTPUT_R7="$TEST_TEMP_DIR/findings_r7.json"
set +e
ZBUILD_SECURITY_LENS_TIER=T9 _security_lens_run_inner "$INPUT" "$MANIFEST" "$OUTPUT_R7" "$TEST_TEMP_DIR" >/dev/null 2>&1
rc=$?
set -e
assert_eq "R7: router rc=2 (fatal tier) returns plugin rc=1 (propagates)" "1" "$rc"
r7_error_event=$(grep '"plugin.run.error"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | \
    jq -r 'select(.type=="plugin.run.error") | .data.reason // empty' 2>/dev/null | tail -1 || true)
assert_eq "R7: plugin.run.error event emitted with router_fatal reason" "router_fatal" "$r7_error_event"

# ─── R8: .findings key missing from valid JSON object (envelope-wrapped #476) ─
install_envelope_mock_claude '{"schema_version":1}'
OUTPUT_R8="$TEST_TEMP_DIR/findings_r8.json"
set +e
_security_lens_run_inner "$INPUT" "$MANIFEST" "$OUTPUT_R8" "$TEST_TEMP_DIR" >/dev/null 2>&1
rc=$?
set -e
assert_eq "R8: missing .findings returns rc=0" "0" "$rc"
r8_count=$(jq '.findings | length' "$OUTPUT_R8")
assert_eq "R8: missing .findings yields empty array (not null)" "0" "$r8_count"
r8_findings_type=$(jq -r '.findings | type' "$OUTPUT_R8")
assert_eq "R8: .findings is array not null" "array" "$r8_findings_type"

# ─── R8b (#478): prose-prefixed JSON survives via parser-side helper ────────
# Envelope mode (#476) separates reasoning *turns* from the final turn but
# the model can still emit prose INSIDE the final assistant message before
# its JSON. extract_first_json_object slices the LAST top-level balanced
# object out. Locks the dogfood shape that motivated #478.
install_envelope_mock_claude 'Now I have a complete picture.

{"schema_version":1,"plugin_id":"security-lens","findings":[{"title":"Secret leak","severity":"high","category":"secret","file":"src/cfg.sh:3","evidence":"API_KEY=abc","suggestion":"use env"}]}'
OUTPUT_R8b="$TEST_TEMP_DIR/findings_r8b.json"
set +e
_security_lens_run_inner "$INPUT" "$MANIFEST" "$OUTPUT_R8b" "$TEST_TEMP_DIR" >/dev/null 2>&1
rc=$?
set -e
assert_eq "R8b (#478): prose-prefixed response returns rc=0" "0" "$rc"
assert_file_exists "R8b (#478): findings.json written despite prose preface" "$OUTPUT_R8b"
r8b_title=$(jq -r '.findings[0].title // "missing"' "$OUTPUT_R8b" 2>/dev/null || echo missing)
assert_eq "R8b (#478): finding parsed from prose-prefixed payload" "Secret leak" "$r8b_title"

# ─── R8c (#478): prompt hardening — system prompt carries explicit "{" rule ──
# The shared sentence is appended to prompts/security.md; assert it reaches
# the model via the last_prompt capture.
install_envelope_mock_claude \
    --record-prompt "$TEST_TEMP_DIR/last_prompt_478" \
    '{"schema_version":1,"plugin_id":"security-lens","findings":[]}'
_security_lens_run_inner "$INPUT" "$MANIFEST" "$TEST_TEMP_DIR/findings_r8c.json" "$TEST_TEMP_DIR" >/dev/null 2>&1
if grep -qF 'Your response MUST begin with `{`' "$TEST_TEMP_DIR/last_prompt_478" 2>/dev/null; then
    assert_pass "R8c (#478): security-lens prompt carries 'MUST begin with {' rule"
else
    assert_fail "R8c (#478): prompt missing 'MUST begin with {' rule"
fi
if grep -qF "no leading prose, no trailing prose, no markdown fences" "$TEST_TEMP_DIR/last_prompt_478" 2>/dev/null; then
    assert_pass "R8c (#478): security-lens prompt forbids leading/trailing prose"
else
    assert_fail "R8c (#478): prompt missing prose prohibition"
fi

# ─── Hook contract: security_lens_run(stage, state_file) ─────────────────────
# Verifies the wrapper derives paths correctly and writes to the right artifact.
STATE_DIR="$TEST_TEMP_DIR/state"
STATE_FILE="$STATE_DIR/pipeline-state.json"
mkdir -p "$STATE_DIR/artifacts"
echo '{"schema_version":1,"run_id":"test-hook-001","issue":"0","stage_statuses":{}}' > "$STATE_FILE"
echo "auth bypass credential leak" > "$STATE_DIR/intake.md"
printf '+ src/\n+ tests/\n' > "$STATE_DIR/scope-manifest.md"

install_envelope_mock_claude '{"schema_version":1,"plugin_id":"security-lens","findings":[]}'

set +e
security_lens_run "security-lens" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "hook contract: security_lens_run(stage, state_file) returns rc=0" "0" "$rc"
assert_file_exists "hook contract: artifact written to state_dir/artifacts/" \
    "$STATE_DIR/artifacts/security-findings.json"

# Platform partitioning: ZBUILD_TARGET_PLATFORM suffix is injected into filename
ZBUILD_TARGET_PLATFORM="ios" security_lens_run "security-lens" "$STATE_FILE" >/dev/null 2>&1
assert_file_exists "hook contract: platform fanout writes platform-scoped artifact" \
    "$STATE_DIR/artifacts/security-ios-findings.json"

# ─── R9 (#476): plugin exports ZBUILD_ROUTER_JSON_OUTPUT=1 ───────────────────
# ADR-018 Pattern 1 decision #8: plugins MUST opt into JSON envelope mode so
# the router adds --output-format json. Mock records argv to disk; assert.
# DO NOT REMOVE — this is the sole production-path argv pin for the #476
# invariant on security-lens. Tests R1/R3/R4/R8 pass with or without envelope
# mode because the helper handles both.
ARGV_CAPTURE="$TEST_TEMP_DIR/r9-argv"
install_envelope_mock_claude \
    --record-argv "$ARGV_CAPTURE" \
    '{"schema_version":1,"plugin_id":"security-lens","findings":[]}'

OUTPUT_R9="$TEST_TEMP_DIR/findings_r9.json"
_security_lens_run_inner "$INPUT" "$MANIFEST" "$OUTPUT_R9" "$TEST_TEMP_DIR" >/dev/null 2>&1
assert_file_exists "R9: claude was invoked (argv capture file written)" "$ARGV_CAPTURE"
if grep -qx '\--output-format' "$ARGV_CAPTURE" && grep -qx 'json' "$ARGV_CAPTURE"; then
    assert_pass "R9 (#476): security-lens invokes claude with --output-format json"
else
    assert_fail "R9 (#476): expected --output-format json in argv" "got: $(tr '\n' ' ' < "$ARGV_CAPTURE")"
fi

# ─── R10 (#483): security-lens tags capture with metadata.artifact ───────────
# ADR-018 producer-side renderer dispatch. The "security-lens" renderer is NOT
# yet registered (follow-up issue); render_artifact passthrough + fallback
# event is acceptable. This test pins the env-var opt-in symmetric with
# plan/review so the wiring is exercised. Shadows route_to_model in-process so
# we can introspect the exported env var at call time.
_CAPTURED_SECLENS_ARTIFACT="$TEST_TEMP_DIR/captured-seclens-artifact.txt"
: > "$_CAPTURED_SECLENS_ARTIFACT"
route_to_model() {
    printf '%s' "${ZBUILD_ROUTER_ARTIFACT_ID:-unset}" > "$_CAPTURED_SECLENS_ARTIFACT"
    printf '%s\n' '{"schema_version":1,"plugin_id":"security-lens","findings":[]}'
    return 0
}
OUTPUT_R10="$TEST_TEMP_DIR/findings_r10.json"
set +e
_security_lens_run_inner "$INPUT" "$MANIFEST" "$OUTPUT_R10" "$TEST_TEMP_DIR" >/dev/null 2>&1
set -e
captured_seclens_artifact="$(cat "$_CAPTURED_SECLENS_ARTIFACT" 2>/dev/null || true)"
assert_eq "R10 (#483): security-lens exports ZBUILD_ROUTER_ARTIFACT_ID=security-lens around route_to_model" \
    "security-lens" "$captured_seclens_artifact"

# ─── R11 (#721 SPEC-5, SPEC-6): sanitizer strips noise from redacted_content ──
# SPEC-5 (CHANGE): ANSI bytes from redacted_content stripped — fails at
# baseline because without the sanitizer source+pipe the bytes reach the
# prompt verbatim. SPEC-6 (GUARD): genuine security content always survives.
#
# Shadow route_to_model to capture the full prompt at call time (the claude
# mock captures argv/stdout but not the assembled prompt string).
_CAPTURED_SECLENS_PROMPT_R11="$TEST_TEMP_DIR/captured-seclens-prompt-r11.txt"
: > "$_CAPTURED_SECLENS_PROMPT_R11"
route_to_model() {
    # Capture the full prompt (arg $2) for noise-content assertions.
    printf '%s' "${2:-}" > "$_CAPTURED_SECLENS_PROMPT_R11"
    printf '%s\n' '{"schema_version":1,"plugin_id":"security-lens","findings":[]}'
    return 0
}

_SECLENS_ANSI_ESC=$'\x1b'
NOISY_SEC_INPUT="$TEST_TEMP_DIR/noisy-sec-input.txt"
printf '%s\n' \
    "${_SECLENS_ANSI_ESC}[31mANSI-NOISE-SECLENS${_SECLENS_ANSI_ESC}[0m" \
    "<out-of-scope-context>OOS-SEC-WRAPPED</out-of-scope-context>" \
    "Genuine security content: check for SQL injection" \
    > "$NOISY_SEC_INPUT"

OUTPUT_R11="$TEST_TEMP_DIR/findings_r11.json"
set +e
_security_lens_run_inner "$NOISY_SEC_INPUT" "$MANIFEST" "$OUTPUT_R11" "$TEST_TEMP_DIR" \
    >/dev/null 2>&1
set -e

# SPEC-5 (CHANGE): ANSI escape bytes from redacted_content stripped before LLM
_r11_esc_count="$(LC_ALL=C tr -cd $'\x1b' < "$_CAPTURED_SECLENS_PROMPT_R11" | wc -c | tr -d ' ')"
assert_eq "[SPEC-5] security-lens redacted_content ANSI bytes stripped before LLM prompt" \
    "0" "$_r11_esc_count"

# SPEC-6 (GUARD): genuine security content survives sanitize
_r11_prompt="$(cat "$_CAPTURED_SECLENS_PROMPT_R11")"
assert_contains "[SPEC-6] security-lens redacted_content genuine content survives sanitize" \
    "$_r11_prompt" "Genuine security content: check for SQL injection"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
