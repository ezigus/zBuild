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
    if grep -qF "$line" <<< "$legacy_block"; then
        legacy_has=1
    else
        legacy_has=0
    fi
    if grep -qF "$line" <<< "$prompt_block"; then
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

# Source plugin
# shellcheck source=../../../../plugins/agent/security-lens/plugin.sh
source "$PLUGIN_DIR/plugin.sh"
# shellcheck source=../../../../core/router/route.sh
source "$REPO_ROOT/core/router/route.sh"


# ADR-043: redaction is owned by route_to_model, which reads the manifest from
# ZBUILD_SCOPE_MANIFEST (runner-exported per-stage). Fail-closed is preserved AT
# THE ROUTER: a configured-but-missing manifest → redaction.refused (rc1) →
# route_to_model returns 2 → the security-lens plugin propagates rc=1. (The
# plugin no longer refuses on its own; the $2 arg is inert.)
export ZBUILD_SCOPE_MANIFEST="$TEST_TEMP_DIR/nonexistent-manifest.md"
set +e
_security_lens_run_inner "$INPUT" "" "$OUTPUT" 2>/dev/null
rc=$?
set -e
assert_eq "[SPEC-10] security_lens_run refuses when scope manifest missing (router fail-closed)" "1" "$rc"

# ─── Run: with scope manifest, emits typed findings.json ────────────────────
MANIFEST="$TEST_TEMP_DIR/scope.md"
cat > "$MANIFEST" <<EOF
+ src/
+ tests/
EOF
# Point the router at the real manifest so it redacts (not refuses) from here on.
export ZBUILD_SCOPE_MANIFEST="$MANIFEST"
# #2107: this run reaches whatever `claude` is on PATH. It must be this test's
# mock — the real CLI spends a model call locally and, on the CI runner, hit the
# shared rate limit and turned into a false ✗ (daemon run 34956206632).
install_envelope_mock_claude \
    '{"schema_version":1,"plugin_id":"security-lens","findings":[]}'
_first_claude="$(command -v claude 2>/dev/null || true)"
assert_eq "[#2107] claude on PATH before the first run is this test's mock" \
    "$TEST_TEMP_DIR/bin/claude" "$_first_claude"
_security_lens_run_inner "$INPUT" "$MANIFEST" "$OUTPUT" "$TEST_TEMP_DIR" >/dev/null
assert_file_exists "findings.json created" "$OUTPUT"

rc_contract=$(jq -r '.result_contract // "absent"' "$OUTPUT")
assert_eq "[SPEC-1] findings.json carries result_contract:2 on the pass exit path" "2" "$rc_contract"

verdict_v=$(jq -r '.verdict // "absent"' "$OUTPUT")
assert_eq "[SPEC-2] normal exit path verdict=pass" "pass" "$verdict_v"

disposition_v=$(jq -r '.disposition // "absent"' "$OUTPUT")
assert_eq "[SPEC-2] normal exit path disposition=complete" "complete" "$disposition_v"

# ─── Events emitted during the run ──────────────────────────────────────────
if [[ -f "$ZBUILD_EVENTS_JSONL" ]]; then
    redaction_count=$(grep -c '"redaction.applied"' "$ZBUILD_EVENTS_JSONL" || true)
    if [[ "$redaction_count" -ge 1 ]]; then
        assert_pass "redaction.applied event emitted (chokepoint observable)"
    else
        assert_fail "expected redaction.applied event in event log"
    fi
    _spec8_ev=$(grep '"plugin.result"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | \
        jq -r 'select(.type=="plugin.result" and .plugin=="security-lens" and (.data.result_contract // "0") == "2") | .type // empty' \
        2>/dev/null | head -1 || true)
    assert_eq "[SPEC-8] plugin.result event carries result_contract:2 on normal exit path with plugin=security-lens" \
        "plugin.result" "$_spec8_ev"
else
    assert_fail "events.jsonl was not created"
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
r1_contract=$(jq -r '.result_contract // "absent"' "$OUTPUT_R")
assert_eq "[SPEC-1] R1: result_contract:2 on normal pass path" "2" "$r1_contract"
r1_verdict=$(jq -r '.verdict // "absent"' "$OUTPUT_R")
assert_eq "[SPEC-2] R1: verdict=pass on normal pass path" "pass" "$r1_verdict"
r1_disp=$(jq -r '.disposition // "absent"' "$OUTPUT_R")
assert_eq "[SPEC-2] R1: disposition=complete on normal pass path" "complete" "$r1_disp"
# NOT `// "absent"`: jq's alternative operator treats a boolean false as empty,
# so the fallback fires on the very value this asserts. Ask whether the key is
# there, then render it.
stub_val=$(jq -r 'if has("data") and (.data|has("stub")) then (.data.stub|tostring) else "absent" end' "$OUTPUT_R")
assert_eq "R1: stub is false after real LLM path" "false" "$stub_val"
title_val=$(jq -r '.data.findings[0].title // "absent"' "$OUTPUT_R")
assert_eq "[SPEC-9] R1: findings[0].title accessible under .data.findings" "SQL Injection" "$title_val"
sev_val=$(jq -r '.data.findings[0].severity // "absent"' "$OUTPUT_R")
assert_eq "R1: data.findings[0].severity parsed" "high" "$sev_val"

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
fence_title=$(jq -r '.data.findings[0].title // "absent"' "$OUTPUT_R3")
assert_eq "R3: fenced JSON response parsed correctly" "XSS" "$fence_title"

# ─── R4: malformed (non-JSON) response (envelope-wrapped per #476) ───────────
install_envelope_mock_claude "this is not json at all"
OUTPUT_R4="$TEST_TEMP_DIR/findings_r4.json"
set +e
_security_lens_run_inner "$INPUT" "$MANIFEST" "$OUTPUT_R4" "$TEST_TEMP_DIR" >/dev/null 2>&1
rc=$?
set -e
assert_eq "R4: malformed response returns rc=0 (fail-open)" "0" "$rc"
r4_count=$(jq '.data.findings | length' "$OUTPUT_R4")
assert_eq "R4: malformed response yields empty findings" "0" "$r4_count"
r4_stub=$(jq -r '.data.stub' "$OUTPUT_R4")
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
r5_count=$(jq '.data.findings | length' "$OUTPUT_R5")
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
r6_count=$(jq '.data.findings | length' "$OUTPUT_R6")
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
r7_error_event=$(grep '"plugin.result"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | \
    jq -r 'select(.type=="plugin.result" and .data.verdict=="error") | .data.reason // empty' 2>/dev/null | tail -1 || true)
# T9 is an UNKNOWN TIER: the failure is tier resolution, not a router call —
# no router call happens at all. The old expectation ("router_fatal", with a
# hardcoded router_rc=2 beside it) named a router exit code that never existed
# and made a tier problem indistinguishable from a model failure in the log.
assert_eq "R7: plugin.result event names the real failure (tier, not router)" "tier_unresolved" "$r7_error_event"

# ─── R8: .findings key missing from valid JSON object (envelope-wrapped #476) ─
install_envelope_mock_claude '{"schema_version":1}'
OUTPUT_R8="$TEST_TEMP_DIR/findings_r8.json"
set +e
_security_lens_run_inner "$INPUT" "$MANIFEST" "$OUTPUT_R8" "$TEST_TEMP_DIR" >/dev/null 2>&1
rc=$?
set -e
assert_eq "R8: missing .findings returns rc=0" "0" "$rc"
r8_count=$(jq '.data.findings | length' "$OUTPUT_R8")
assert_eq "R8: missing .findings yields empty array (not null)" "0" "$r8_count"
r8_findings_type=$(jq -r '.data.findings | type' "$OUTPUT_R8")
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
r8b_title=$(jq -r '.data.findings[0].title // "missing"' "$OUTPUT_R8b" 2>/dev/null || echo missing)
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

# R11: ANSI escape bytes from redacted_content stripped before LLM
_r11_esc_count="$(LC_ALL=C tr -cd $'\x1b' < "$_CAPTURED_SECLENS_PROMPT_R11" | wc -c | tr -d ' ')"
assert_eq "R11: security-lens redacted_content ANSI bytes stripped before LLM prompt" \
    "0" "$_r11_esc_count"

# R11: genuine security content survives sanitize
_r11_prompt="$(cat "$_CAPTURED_SECLENS_PROMPT_R11")"
assert_contains "R11: security-lens redacted_content genuine content survives sanitize" \
    "$_r11_prompt" "Genuine security content: check for SQL injection"

# ─── R12: [SPEC-10] postamble recovery via _security_lens_envelope_schema_ok ──
# CHANGE: before #944 a brace-bearing postamble caused LAST-wins to select junk
# → .findings defaulted to []. After #944 recovery fires and the real findings
# envelope is used.

# SPEC-10: _security_lens_envelope_schema_ok must exist — it is the function
# that selects the findings envelope over a brace-bearing postamble.
if declare -F _security_lens_envelope_schema_ok >/dev/null 2>&1; then
    assert_pass "[SPEC-10] _security_lens_envelope_schema_ok exists and is callable"
else
    assert_fail "[SPEC-10] _security_lens_envelope_schema_ok exists and is callable"
fi

route_to_model() {
    # Real findings envelope first, brace-bearing postamble appended.
    printf '%s\n' '{"findings":[{"severity":"high","title":"SQL injection","file":"auth.sh","line":10,"description":"Unsanitized input"}]} Based on this: {"note":"postamble-junk"}'
    return 0
}

SEC_INPUT_R12="$TEST_TEMP_DIR/sec-input-r12.txt"
printf '%s\n' "Check for SQL injection in auth.sh" > "$SEC_INPUT_R12"
OUTPUT_R12="$TEST_TEMP_DIR/findings_r12.json"
set +e
_security_lens_run_inner "$SEC_INPUT_R12" "$MANIFEST" "$OUTPUT_R12" "$TEST_TEMP_DIR" \
    >/dev/null 2>&1
rc=$?
set -e
assert_eq "[SPEC-10] postamble recovery → rc=0" "0" "$rc"
assert_file_exists "[SPEC-10] postamble recovery → findings.json written" "$OUTPUT_R12"
_spec10_count="$(jq '.data.findings | length' "$OUTPUT_R12" 2>/dev/null || echo 0)"
assert_eq "[SPEC-10] postamble recovery → recovered findings (1 finding, not empty)" \
    "1" "$_spec10_count"

# [SPEC-10] proves recovery is performed by _security_lens_envelope_schema_ok:
# shadow the function to return 1 (reject all envelopes) — when the schema_ok
# gate is disabled, LAST-wins selects the postamble junk and .data.findings is 0.
# This is the only assertion that pinpoints WHICH code path performs recovery.
_security_lens_envelope_schema_ok() { return 1; }
OUTPUT_R12_NOOK="$TEST_TEMP_DIR/findings_r12_nook.json"
set +e
_security_lens_run_inner "$SEC_INPUT_R12" "$MANIFEST" "$OUTPUT_R12_NOOK" "$TEST_TEMP_DIR" \
    >/dev/null 2>&1
set -e
_spec10_nook_count=0
if [[ -f "$OUTPUT_R12_NOOK" ]]; then
    _spec10_nook_count=$(jq '.data.findings | length' "$OUTPUT_R12_NOOK" 2>/dev/null || echo 0)
fi
assert_eq "[SPEC-10] postamble recovery is performed by _security_lens_envelope_schema_ok (disabling it yields 0 findings, not 1)" \
    "0" "$_spec10_nook_count"
unset -f _security_lens_envelope_schema_ok
# Restore real _security_lens_envelope_schema_ok from plugin.sh
# shellcheck source=../../../../plugins/agent/security-lens/plugin.sh
source "$PLUGIN_DIR/plugin.sh"

# ─── [SPEC-3]: router-fatal path writes v2 result with verdict=error/broken ───
if [[ -f "$OUTPUT_R7" ]]; then
    spec3_contract=$(jq -r '.result_contract // "absent"' "$OUTPUT_R7" 2>/dev/null || echo absent)
    assert_eq "[SPEC-3] router-fatal path writes result_contract:2" "2" "$spec3_contract"
    spec3_verdict=$(jq -r '.verdict // "absent"' "$OUTPUT_R7" 2>/dev/null || echo absent)
    assert_eq "[SPEC-3] router-fatal path writes verdict=error" "error" "$spec3_verdict"
    spec3_disp=$(jq -r '.disposition // "absent"' "$OUTPUT_R7" 2>/dev/null || echo absent)
    assert_eq "[SPEC-3] router-fatal path writes disposition=broken" "broken" "$spec3_disp"
else
    assert_fail "[SPEC-3] router-fatal path writes v2 result (OUTPUT_R7 missing)"
fi

# ─── [SPEC-4]: no-state-file path writes v2 result and returns rc=1 ──────────
SPEC4_DIR="$TEST_TEMP_DIR/spec4-artifacts"
mkdir -p "$SPEC4_DIR"
export ZBUILD_ARTIFACT_DIR="$SPEC4_DIR"
set +e
security_lens_run "security-lens" "" >/dev/null 2>&1
spec4_rc=$?
set -e
assert_eq "[SPEC-4] no-state-file path returns rc=1 (not rc=2)" "1" "$spec4_rc"
if [[ -f "$SPEC4_DIR/security-findings.json" ]]; then
    spec4_contract=$(jq -r '.result_contract // "absent"' "$SPEC4_DIR/security-findings.json")
    assert_eq "[SPEC-4] no-state-file path writes result_contract:2" "2" "$spec4_contract"
else
    assert_fail "[SPEC-4] no-state-file path writes v2 result artifact"
fi
unset ZBUILD_ARTIFACT_DIR

# ─── [SPEC-5 new]: security_lens_cleanup is declared and returns 0 ────────────
# Verify the function is declared in plugin.sh itself (spec: "exists in plugin.sh")
if grep -qE '^(security_lens_cleanup[[:space:]]*\(\)|function[[:space:]]+security_lens_cleanup)' \
        "$PLUGIN_DIR/plugin.sh" 2>/dev/null; then
    assert_pass "[SPEC-5] security_lens_cleanup is declared in plugin.sh"
else
    assert_fail "[SPEC-5] security_lens_cleanup is declared in plugin.sh"
fi
set +e
security_lens_cleanup
spec5_cleanup_rc=$?
set -e
assert_eq "[SPEC-5] security_lens_cleanup is declared and returns 0" "0" "$spec5_cleanup_rc"

# ─── Manifest assertions (SPEC-5 manifest, SPEC-6, SPEC-7, SPEC-11, SPEC-13) ──
# SPEC-5 function-callable check is above; ADR-062 §3 retired manifest cleanup
# hook declarations tree-wide — also assert NO cleanup: YAML key under hooks:.
_MANIFEST_FILE="$PLUGIN_DIR/manifest.yaml"
# Portability (this repo's CI runs the suite on ubuntu AND macos): `\s` is a GNU
# awk/grep extension that BSD tools match as a literal `s`, so every extraction
# using it came back EMPTY on macOS — a SPEC then passed or failed by luck
# rather than by what the manifest says. POSIX classes throughout, and no
# multi-command `sed` range (BSD sed rejects `{...; p}` outright).

# SPEC-5 (manifest): confirm NO cleanup: YAML key appears under hooks: (ADR-062 §3)
_spec5_hooks_block=$(awk '/^hooks:/{found=1;next} found && /^[a-zA-Z]/{exit} found{print}' "$_MANIFEST_FILE" 2>/dev/null || true)
_spec5_cleanup_count=$(grep -cE '^[[:space:]]+cleanup:' <<< "$_spec5_hooks_block" 2>/dev/null || true)
assert_eq "[SPEC-5] manifest has NO cleanup: YAML key under hooks: (ADR-062 §3 retired)" "0" "$_spec5_cleanup_count"

# awk, not a multi-command sed range: BSD sed (macOS, which this repo's CI
# matrix runs) rejects `{...; p}` with "extra characters at the end of p
# command", so the extraction returned nothing and this SPEC failed on macOS
# while passing on ubuntu. Same shape as the SPEC-5 and SPEC-7 blocks above.
_spec6_provides=$(awk '/^provides:/{found=1;next} found && /^[a-zA-Z]/{exit} found{print}' "$_MANIFEST_FILE" 2>/dev/null || true)
if grep -q 'result_contract: 2' <<< "$_spec6_provides" 2>/dev/null; then
    assert_pass "[SPEC-6] manifest declares provides.result_contract: 2"
else
    assert_fail "[SPEC-6] manifest declares provides.result_contract: 2"
fi

_spec7_config=$(awk '/^config:/{found=1;next} found && /^[a-zA-Z]/{exit} found{print}' "$_MANIFEST_FILE" 2>/dev/null || true)
_spec7_vv=$(awk '/valid_verdicts:/{found=1;next} found && /^[[:space:]]+-/{print;next} found{exit}' <<< "$_spec7_config" 2>/dev/null || true)
if grep -q '\bpass\b' <<< "$_spec7_vv" 2>/dev/null && \
   grep -q '\berror\b' <<< "$_spec7_vv" 2>/dev/null; then
    assert_pass "[SPEC-7] manifest declares valid_verdicts: [pass, error]"
else
    assert_fail "[SPEC-7] manifest declares valid_verdicts: [pass, error]"
fi

_spec11_config=$(awk '/^config:/{found=1;next} found && /^[a-zA-Z]/{exit} found{print}' "$_MANIFEST_FILE" 2>/dev/null || true)
_spec11_router=$(awk '/^[[:space:]]+router:/{found=1;next} found && /^[[:space:]][[:space:]][[:space:]][[:space:]][a-z]/{print;next} found{exit}' <<< "$_spec11_config" 2>/dev/null || true)
if grep -q 'timeout_s:' <<< "$_spec11_router" 2>/dev/null && \
   grep -q 'max_turns:' <<< "$_spec11_router" 2>/dev/null; then
    assert_pass "[SPEC-11] manifest declares config.router with timeout_s and max_turns"
else
    assert_fail "[SPEC-11] manifest declares config.router with timeout_s and max_turns"
fi

_spec13_findings=$(awk '/^[[:space:]]+- id: findings/{found=1; print; next} found && /^[[:space:]]+- id:/{exit} found{print}' "$_MANIFEST_FILE" 2>/dev/null || true)
if grep -q 'primary: true' <<< "$_spec13_findings" 2>/dev/null; then
    assert_pass "[SPEC-13] manifest declares primary: true on findings output"
else
    assert_fail "[SPEC-13] manifest declares primary: true on findings output"
fi

# ─── [SPEC-16]: manifest declares provides.events with both required event names ─
_spec16_provides=$(awk '/^provides:/{found=1;next} found && /^[a-zA-Z]/{exit} found{print}' "$_MANIFEST_FILE" 2>/dev/null || true)
_spec16_events=$(awk '/^[[:space:]]+events:/{found=1;next} found && /^[[:space:]]+-/{print;next} found{exit}' <<< "$_spec16_provides" 2>/dev/null || true)
if grep -q 'plugin\.result' <<< "$_spec16_events" 2>/dev/null; then
    assert_pass "[SPEC-16] manifest provides.events contains plugin.result"
else
    assert_fail "[SPEC-16] manifest provides.events contains plugin.result"
fi
if grep -q 'security_lens\.failed' <<< "$_spec16_events" 2>/dev/null; then
    assert_pass "[SPEC-16] manifest provides.events contains security_lens.failed"
else
    assert_fail "[SPEC-16] manifest provides.events contains security_lens.failed"
fi

# ─── [SPEC-17]: manifest declares provides.role: security-auditor ────────────
_spec17_provides=$(awk '/^provides:/{found=1;next} found && /^[a-zA-Z]/{exit} found{print}' "$_MANIFEST_FILE" 2>/dev/null || true)
if grep -qE 'role:[[:space:]]+security-auditor' <<< "$_spec17_provides" 2>/dev/null; then
    assert_pass "[SPEC-17] manifest declares provides.role: security-auditor"
else
    assert_fail "[SPEC-17] manifest declares provides.role: security-auditor"
fi

# ─── [SPEC-12]: ZBUILD_ROUTER_MAX_TURNS_OVERRIDE takes precedence ────────────
# Restore real route_to_model so _route_resolve_max_turns runs and passes
# --max-turns to claude. Mock claude with argv recording to capture what value
# the router resolves — proving the override reaches claude, not the manifest.
unset _ZBUILD_ROUTER_LOADED
# shellcheck source=../../../../core/router/route.sh
source "$REPO_ROOT/core/router/route.sh"

_spec12_manifest_turns=$(awk '/^config:/{c=1;next} c && /^[a-zA-Z]/{exit} c && /^[[:space:]]+router:/{r=1;next} c && r && /max_turns:/{match($0,/[0-9]+/); print substr($0,RSTART,RLENGTH); exit}' "$_MANIFEST_FILE" 2>/dev/null || echo 45)
assert_eq "[SPEC-12] manifest max_turns differs from override value (precedence testable)" \
    "1" "$(( _spec12_manifest_turns != 7 ? 1 : 0 ))"

_spec12_argv="$TEST_TEMP_DIR/spec12-argv"
install_envelope_mock_claude --record-argv "$_spec12_argv" \
    '{"schema_version":1,"plugin_id":"security-lens","findings":[]}'
ZBUILD_ROUTER_MAX_TURNS_OVERRIDE=7 \
    _security_lens_run_inner "$INPUT" "$MANIFEST" \
    "$TEST_TEMP_DIR/findings_spec12.json" "$TEST_TEMP_DIR" >/dev/null 2>&1

# Prove the override reached claude as --max-turns 7, not the manifest value (45)
_spec12_max_turns=""
if [[ -f "$_spec12_argv" ]]; then
    _prev_arg=""
    while IFS= read -r _line; do
        [[ "$_prev_arg" == "--max-turns" ]] && { _spec12_max_turns="$_line"; break; }
        _prev_arg="$_line"
    done < "$_spec12_argv"
fi
assert_eq "[SPEC-12] ZBUILD_ROUTER_MAX_TURNS_OVERRIDE takes precedence over manifest config.router.max_turns" \
    "7" "$_spec12_max_turns"

# ─── [SPEC-21] the declared event is actually emitted (lens: SRE, high) ─────
# The manifest declares `security_lens.failed` under provides.events and NO
# call site existed anywhere in plugin.sh — every error path emitted only
# plugin.result, so a monitor wired to the declared event could never fire.
# A declared event that nothing emits is a contract the plugin does not keep.
print_test_section "[SPEC-21] every declared event has a call site"
_spec21_declared=$(awk '/^[[:space:]]+events:/{found=1;next} found && /^[[:space:]]+-/{sub(/^[[:space:]]*-[[:space:]]*/,""); print; next} found{exit}' \
    "$_MANIFEST_FILE" 2>/dev/null || true)
_spec21_missing=""
while IFS= read -r _ev; do
    [[ -n "$_ev" ]] || continue
    grep -qF "\"$_ev\"" "$PLUGIN_DIR/plugin.sh" 2>/dev/null || _spec21_missing="${_spec21_missing}${_ev} "
done <<< "$_spec21_declared"
assert_eq "[SPEC-21] every event the manifest declares has an emit site in plugin.sh" \
    "" "${_spec21_missing% }"

# ─── [SPEC-22] stub is a BOOLEAN (lens: correctness/red-team/SRE) ───────────
# It was written as the JSON string "false". `jq -r` renders a string "false"
# and a boolean false identically, so every existing assertion passed while a
# consumer doing `if .stub then` saw a truthy value — the inversion of what the
# field means. Assert the TYPE, which is the only thing that can see it.
print_test_section "[SPEC-22] stub is a boolean, not the string \"false\""
_spec22_art="$TEST_TEMP_DIR/spec22-findings.json"
_security_lens_write_result "$_spec22_art" "pass" "complete" "ok" '[]' 2>/dev/null || true
assert_eq "[SPEC-22] top-level .stub is a boolean" "boolean" \
    "$(jq -r '.stub | type' "$_spec22_art" 2>/dev/null || true)"
assert_eq "[SPEC-22] .data.stub is a boolean too" "boolean" \
    "$(jq -r '.data.stub | type' "$_spec22_art" 2>/dev/null || true)"

# ─── [SPEC-23] an interrupted review is never reported as a pass ───────────
# (lens: red-team) The handler sets _sl_interrupted and writes the interrupted
# artifact, but the flag was only consulted on the rc=130 branch. A signal
# arriving in the window between `trap` and the router returning leaves rc=0 —
# the normal-pass path then overwrote the interrupted artifact and an
# interrupted SECURITY review was reported as verdict=pass.
print_test_section "[SPEC-23] a signal seen during the call is not reported as a pass"
# Drives the REAL path: the router returns 0 (the race — the signal arrived
# before it returned), with the interrupt flag already set by the handler. The
# assertion reads the ARTIFACT the plugin wrote, so a wrong-direction change in
# the plugin fails it. (An earlier draft copied the plugin's own conditional
# into the test, which would have flipped with the implementation — caught in
# review of #2182.)
_spec23_out="$TEST_TEMP_DIR/spec23-findings.json"
rm -f "$_spec23_out"
# The race, reproduced honestly: a REAL signal arrives while the model call is
# in flight, and the call then completes with rc=0. The plugin installs its own
# TERM trap around the call, so the signal runs the handler in this process —
# a stub cannot set the flag any other way, because the call is captured in
# `$( )` and a subshell assignment never reaches the caller.
# shellcheck disable=SC2317
route_to_model() { kill -TERM $$ 2>/dev/null; sleep 0.2; printf '{"findings":[]}'; return 0; }
set +e
_security_lens_run_inner "$INPUT" "$MANIFEST" "$_spec23_out" "$TEST_TEMP_DIR" >/dev/null 2>&1
_spec23_rc=$?
set -e
unset -f route_to_model
assert_eq "[SPEC-23] a signal during the call returns the interrupt rc, not success" \
    "130" "$_spec23_rc"
assert_eq "[SPEC-23] …and the artifact says error, not pass" "error" \
    "$(jq -r '.verdict // ""' "$_spec23_out" 2>/dev/null)"
assert_eq "[SPEC-23] …with disposition=interrupted" "interrupted" \
    "$(jq -r '.disposition // ""' "$_spec23_out" 2>/dev/null)"
assert_eq "[SPEC-23] …and the declared failure event fired" "1" \
    "$( { grep -c '"security_lens.failed"' "$ZBUILD_EVENTS_JSONL" || true; } | awk '{print ($1>=1)?1:0}')"
_sl_interrupted=0

# ─── [SPEC-14]: no hardcoded artifact paths beyond manifest-declared basenames ─
_spec14_plugin="$PLUGIN_DIR/plugin.sh"
# What this SPEC is really about (ADR-055 §1, #1825/#1826): a plugin must not
# construct the path of an artifact it does not OWN. Its own declared outputs
# are built from the engine-provided artifact dir — every migrated plugin in the
# tree does that, and it is not the defect. Reaching into another stage's
# artifact by hand IS: it hardcodes a producer's filename, so the producer can
# never move it and the engine's resolved-input index is bypassed.
#
# The previous pattern `"[^"$]*\.(json|md)"` could not match a string containing
# a `$` — which is the only form these literals take — so it reported a clean
# file while `$state_dir/intake.md` and `$state_dir/scope-manifest.md` sat in it.
# Two parts, because "no hardcoded paths" has two halves that must BOTH hold:
#   (a) the engine's resolved index is what production reads;
#   (b) the only remaining literals are the direct-call fallbacks for exactly
#       those resolved variables — anything else is a producer's filename
#       pinned in this plugin.
_spec14_own='security-lens-summary\.md|security(-[A-Za-z0-9_]+)?-findings\.json'
_spec14_bad=$( { grep -nE '\$[A-Za-z_][A-Za-z0-9_]*/[A-Za-z0-9_-]+\.(json|md)' "$_spec14_plugin" \
                 || true; } \
             | { grep -vE "$_spec14_own" || true; } \
             | { grep -vE '\|\| _si_(intake|scope)=' || true; } | grep -c . || true)
_spec14_resolves=$( { grep -cE 'ZBUILD_STAGE_INPUTS' "$_spec14_plugin" || true; } )
assert_eq "[SPEC-14] the plugin reads the engine's resolved-input index" "1" \
    "$([[ "${_spec14_resolves:-0}" -ge 1 ]] && echo 1 || echo 0)"
assert_eq "[SPEC-14] plugin.sh has no hardcoded artifact paths beyond manifest-declared basenames" \
    "0" "$_spec14_bad"

# ─── [SPEC-18]: interrupt handler — rc=130 path writes verdict=error/interrupted ─
# PRIMARY negative-control proof: _security_lens_interrupt_handler does not
# exist at the merge-base; these assertions fail there and pass only after
# the handler is added. Follows the review-lens SPEC-13 pattern (ADR-063 §3).

# (a) mock route_to_model returning rc=130 — plugin must return 130 and write
#     a v2 result with verdict=error, disposition=interrupted.
route_to_model() {
    return 130
}
OUTPUT_SPEC18A="$TEST_TEMP_DIR/findings_spec18a.json"
set +e
_security_lens_run_inner "$INPUT" "$MANIFEST" "$OUTPUT_SPEC18A" "$TEST_TEMP_DIR" \
    >/dev/null 2>&1
spec18a_rc=$?
set -e
assert_eq "[SPEC-18] interrupt: router rc=130 returns plugin rc=130" "130" "$spec18a_rc"
if [[ -f "$OUTPUT_SPEC18A" ]]; then
    spec18a_verdict=$(jq -r '.verdict // "absent"' "$OUTPUT_SPEC18A" 2>/dev/null || echo absent)
    assert_eq "[SPEC-18a] interrupt artifact: verdict=error" "error" "$spec18a_verdict"
    spec18a_disp=$(jq -r '.disposition // "absent"' "$OUTPUT_SPEC18A" 2>/dev/null || echo absent)
    assert_eq "[SPEC-18a] interrupt artifact: disposition=interrupted" "interrupted" "$spec18a_disp"
    spec18a_contract=$(jq -r '.result_contract // "absent"' "$OUTPUT_SPEC18A" 2>/dev/null || echo absent)
    assert_eq "[SPEC-18a] interrupt artifact: result_contract=2" "2" "$spec18a_contract"
else
    assert_fail "[SPEC-18a] interrupt path writes v2 result artifact (file absent)"
    assert_fail "[SPEC-18a] interrupt artifact: verdict=error (file absent)"
    assert_fail "[SPEC-18a] interrupt artifact: disposition=interrupted (file absent)"
    assert_fail "[SPEC-18a] interrupt artifact: result_contract=2 (file absent)"
fi

# (b) direct invocation of _security_lens_interrupt_handler — function must
#     exist, write v2 result to $_sl_out_ref with verdict=error/interrupted.
OUTPUT_SPEC18B="$TEST_TEMP_DIR/findings_spec18b.json"
_sl_out_ref="$OUTPUT_SPEC18B"
if declare -F _security_lens_interrupt_handler >/dev/null 2>&1; then
    assert_pass "[SPEC-18b] _security_lens_interrupt_handler exists as callable function"
else
    assert_fail "[SPEC-18b] _security_lens_interrupt_handler exists as callable function"
fi
set +e
_security_lens_interrupt_handler
set -e
if [[ -f "$OUTPUT_SPEC18B" ]]; then
    spec18b_verdict=$(jq -r '.verdict // "absent"' "$OUTPUT_SPEC18B" 2>/dev/null || echo absent)
    assert_eq "[SPEC-18b] direct handler: verdict=error" "error" "$spec18b_verdict"
    spec18b_disp=$(jq -r '.disposition // "absent"' "$OUTPUT_SPEC18B" 2>/dev/null || echo absent)
    assert_eq "[SPEC-18b] direct handler: disposition=interrupted" "interrupted" "$spec18b_disp"
else
    assert_fail "[SPEC-18b] _security_lens_interrupt_handler writes v2 result artifact"
    assert_fail "[SPEC-18b] direct handler: verdict=error (file absent)"
    assert_fail "[SPEC-18b] direct handler: disposition=interrupted (file absent)"
fi

# (c) kill -TERM "$$" in a mock route_to_model — SIGTERM fires the registered
#     trap; plugin returns rc=130 with verdict=error/interrupted artifact.
OUTPUT_SPEC18C="$TEST_TEMP_DIR/findings_spec18c.json"
route_to_model() {
    kill -TERM "$$"
    return 130
}
set +e
_security_lens_run_inner "$INPUT" "$MANIFEST" "$OUTPUT_SPEC18C" "$TEST_TEMP_DIR" \
    >/dev/null 2>&1
spec18c_rc=$?
set -e
assert_eq "[SPEC-18c] kill -TERM: plugin rc=130" "130" "$spec18c_rc"
if [[ -f "$OUTPUT_SPEC18C" ]]; then
    spec18c_verdict=$(jq -r '.verdict // "absent"' "$OUTPUT_SPEC18C" 2>/dev/null || echo absent)
    assert_eq "[SPEC-18c] kill -TERM artifact: verdict=error" "error" "$spec18c_verdict"
    spec18c_disp=$(jq -r '.disposition // "absent"' "$OUTPUT_SPEC18C" 2>/dev/null || echo absent)
    assert_eq "[SPEC-18c] kill -TERM artifact: disposition=interrupted" "interrupted" "$spec18c_disp"
else
    assert_fail "[SPEC-18c] kill -TERM path writes v2 result artifact"
    assert_fail "[SPEC-18c] kill -TERM artifact: verdict=error (file absent)"
    assert_fail "[SPEC-18c] kill -TERM artifact: disposition=interrupted (file absent)"
fi

# ─── [SPEC-20]: manifest input entries declare only id and required: fields ──
# Extract the inputs block (from 'inputs:' until next top-level YAML key) and
# assert that none of the disallowed keys (from:, path:, type:) appear in it.
_spec20_inputs=$(awk '/^inputs:/{found=1;next} found && /^[a-zA-Z]/{exit} found{print}' "$_MANIFEST_FILE" 2>/dev/null || true)
_spec20_bad=$(grep -cE '^[[:space:]]+(from|path|type):' <<< "$_spec20_inputs" 2>/dev/null || true)
assert_eq "[SPEC-20] manifest input entries declare only id and required: (no from:/path:/type: keys)" \
    "0" "$_spec20_bad"

# ─── [SPEC-19]: canary — no failures accumulated up to this point ────────────
assert_eq "[SPEC-19] canary: all preceding assertions passed (FAIL==0)" "0" "$FAIL"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
