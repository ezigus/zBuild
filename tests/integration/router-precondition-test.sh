#!/usr/bin/env bash
# Tests: core/router/route.sh — redaction by construction (ADR-043).
# The router redacts the prompt itself unless a plugin already did. C6 changes
# from "refuse if not redacted" to "redact if not already redacted": a prompt
# with no prior redaction.applied is now REDACTED (emitting redaction.applied
# immediately before model.route), not refused. Fail-closed is preserved: a
# configured-but-missing/empty manifest → redaction.refused → the call is blocked.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "router precondition — C6: model.route requires redaction.applied (ARCHITECTURE.md §3)"

setup_test_env "router-precondition"

EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_DIR="$EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
mkdir -p "$EVENTS_DIR"

# ─── Mock claude (success) ────────────────────────────────────────────────────
cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
echo "OK-RESPONSE"
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"

source "$REPO_ROOT/core/router/route.sh"

# ─── Test 1: fresh run_id with no events → router redacts BY CONSTRUCTION ─────
# Formerly (#289) this fail-closed refused. Under ADR-043 the router redacts the
# prompt itself (no manifest configured here → passthrough stub) and proceeds,
# emitting redaction.applied. This is the "zero-effort authoring" guarantee.
export ZBUILD_RUN_ID="precond-run-fresh-$$"
: > "$ZBUILD_EVENTS_JSONL"

set +e
out="$(route_to_model "T2" "ping" 2>/dev/null)"
rc=$?
set -e
assert_eq "fresh run, no prior redaction: router redacts by construction → rc=0" "0" "$rc"
assert_eq "fresh run: response passthrough after router-owned redaction" "OK-RESPONSE" "$out"

applied_count="$(grep -c '"redaction.applied"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
assert_gt "redaction.applied emitted by construction (no plugin call)" "$applied_count" "0"

# ─── Test 1a: ZBUILD_RUN_ID unset → still fails CLOSED (degenerate env) ───────
# Pre-#289 this silently no-op'd; now it refuses with rc=2 (fatal).
unset ZBUILD_RUN_ID
: > "$ZBUILD_EVENTS_JSONL"

set +e
out="$(route_to_model "T2" "ping" 2>/dev/null)"
rc=$?
set -e
assert_eq "ZBUILD_RUN_ID unset: route_to_model refuses (#289 fail-closed, rc=2 fatal)" "2" "$rc"

# ─── Test 1b: ZBUILD_EVENTS_JSONL missing → C6 fails CLOSED (#289) ───────────
export ZBUILD_RUN_ID="precond-run-no-log-$$"
saved_events_log="$ZBUILD_EVENTS_JSONL"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/does-not-exist.jsonl"
rm -f "$ZBUILD_EVENTS_JSONL"

set +e
out="$(route_to_model "T2" "ping" 2>/dev/null)"
rc=$?
set -e
assert_eq "events log missing: route_to_model refuses (#289 fail-closed, rc=2 fatal)" "2" "$rc"

# Restore for subsequent tests
export ZBUILD_EVENTS_JSONL="$saved_events_log"

# ─── Test 2: non-redaction last event → router redacts BY CONSTRUCTION ───────
# Formerly a C6 violation (rc=2). Now the router redacts the prompt (no manifest
# → passthrough stub) then routes: redaction.applied precedes model.route.
export ZBUILD_RUN_ID="precond-run-violation-$$"
: > "$ZBUILD_EVENTS_JSONL"

jq -cn \
    --arg rid "$ZBUILD_RUN_ID" \
    '{ts:"2026-01-01T00:00:00Z", run_id:$rid, issue:0, type:"stage.start",
      plugin:"", kind:"", data:{stage:"intake"}, schema_version:1}' \
    >> "$ZBUILD_EVENTS_JSONL"

set +e
out="$(route_to_model "T2" "ping" 2>/dev/null)"
rc=$?
set -e
assert_eq "non-redaction last event: router redacts by construction → rc=0" "0" "$rc"

# redaction.applied must be emitted, and it must precede model.route (chokepoint).
applied_seq="$(grep -n '"redaction.applied"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | tail -1 | cut -d: -f1 || true)"
route_seq="$(grep -n '"model.route"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | tail -1 | cut -d: -f1 || true)"
assert_gt "redaction.applied emitted by construction" "${applied_seq:-0}" "0"
assert_gt "model.route emitted after router-owned redaction" "${route_seq:-0}" "0"
if [[ -n "$applied_seq" && -n "$route_seq" && "$applied_seq" -lt "$route_seq" ]]; then
    assert_pass "redaction.applied immediately precedes model.route (chokepoint ordering)"
else
    assert_fail "redaction.applied immediately precedes model.route (chokepoint ordering)" \
        "applied_seq=$applied_seq route_seq=$route_seq"
fi

# ─── Test 2b: configured-but-MISSING manifest → redaction.refused → BLOCKED ──
# Fail-closed regression: when ZBUILD_SCOPE_MANIFEST names a missing/empty file
# (the production posture the runner sets up), the router MUST refuse the call.
export ZBUILD_RUN_ID="precond-run-failclosed-$$"
: > "$ZBUILD_EVENTS_JSONL"
jq -cn --arg rid "$ZBUILD_RUN_ID" \
    '{ts:"2026-01-01T00:00:00Z", run_id:$rid, issue:0, type:"stage.start",
      plugin:"", kind:"", data:{stage:"build"}, schema_version:1}' \
    >> "$ZBUILD_EVENTS_JSONL"

set +e
out="$(ZBUILD_SCOPE_MANIFEST="$TEST_TEMP_DIR/no-such-manifest.md" \
    route_to_model "T2" "ping" 2>/dev/null)"
rc=$?
set -e
assert_eq "missing manifest → router refuses (fail-closed, rc=2)" "2" "$rc"
refused_fc="$(grep -c '"redaction.refused"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
assert_gt "redaction.refused emitted on missing manifest (fail-closed)" "$refused_fc" "0"
route_fc="$(grep '"model.route"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null \
    | jq -r --arg rid "$ZBUILD_RUN_ID" 'select(.run_id==$rid) | .type' 2>/dev/null \
    | grep -c "model.route" || true)"
assert_eq "no model.route when redaction refused (fail-closed)" "0" "$route_fc"

# ─── Test 2c: valid manifest, no prior redaction → router really redacts ─────
# By-construction with a real manifest: the router runs apply_scope_redaction and
# emits redaction.applied with a real scope_hash (not the passthrough sentinel).
export ZBUILD_RUN_ID="precond-run-realmanifest-$$"
: > "$ZBUILD_EVENTS_JSONL"
REAL_MANIFEST="$TEST_TEMP_DIR/scope-manifest.md"
printf '+ core/\n+ tests/\n' > "$REAL_MANIFEST"
jq -cn --arg rid "$ZBUILD_RUN_ID" \
    '{ts:"2026-01-01T00:00:00Z", run_id:$rid, issue:0, type:"stage.start",
      plugin:"", kind:"", data:{stage:"build"}, schema_version:1}' \
    >> "$ZBUILD_EVENTS_JSONL"

set +e
out="$(ZBUILD_SCOPE_MANIFEST="$REAL_MANIFEST" \
    route_to_model "T2" "please inspect /etc/passwd and core/router/route.sh" 2>/dev/null)"
rc=$?
set -e
assert_eq "valid manifest, no prior redaction → router redacts → rc=0" "0" "$rc"
assert_eq "valid manifest: response passthrough" "OK-RESPONSE" "$out"
real_hash="$(grep '"redaction.applied"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null \
    | jq -r 'select(.type=="redaction.applied") | .data.scope_hash // empty' 2>/dev/null | tail -1 || true)"
if [[ -n "$real_hash" && "$real_hash" != "router-passthrough" ]]; then
    assert_pass "redaction.applied carries a real scope_hash (apply_scope_redaction ran)"
else
    assert_fail "redaction.applied carries a real scope_hash" "got scope_hash='$real_hash'"
fi

# ─── Test 3: run_id with redaction.applied as last event → succeeds ───────────
export ZBUILD_RUN_ID="precond-run-satisfied-$$"
: > "$ZBUILD_EVENTS_JSONL"

jq -cn \
    --arg rid "$ZBUILD_RUN_ID" \
    '{ts:"2026-01-01T00:00:00Z", run_id:$rid, issue:0, type:"redaction.applied",
      plugin:"", kind:"", data:{}, schema_version:1}' \
    >> "$ZBUILD_EVENTS_JSONL"

set +e
out="$(route_to_model "T2" "ping" 2>/dev/null)"
rc=$?
set -e
assert_eq "C6 precondition satisfied: last event is redaction.applied → rc=0" "0" "$rc"
assert_eq "response passthrough when precondition satisfied" "OK-RESPONSE" "$out"

# Assert model.route event was emitted
model_route_fired="$(grep '"model.route"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null \
    | jq -r --arg rid "$ZBUILD_RUN_ID" 'select(.run_id==$rid) | .type' 2>/dev/null \
    | grep -c "model.route" || true)"
assert_gt "model.route event emitted when precondition satisfied" "$model_route_fired" "0"

# ─── Test 4a: --skip-precondition WITHOUT override token is refused ──────────
export ZBUILD_RUN_ID="precond-run-skip-$$"
: > "$ZBUILD_EVENTS_JSONL"

# Emit a non-redaction event (would normally trigger violation)
jq -cn \
    --arg rid "$ZBUILD_RUN_ID" \
    '{ts:"2026-01-01T00:00:00Z", run_id:$rid, issue:0, type:"pipeline.start",
      plugin:"", kind:"", data:{}, schema_version:1}' \
    >> "$ZBUILD_EVENTS_JSONL"

set +e
out="$(route_to_model "T2" "ping" --skip-precondition 2>/dev/null)"
rc=$?
set -e
assert_eq "--skip-precondition without ZBUILD_SCOPE_OVERRIDE → refused (rc=2)" "2" "$rc"

refused_skip="$(grep '"router.precondition.refused"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null \
    | jq -r 'select(.type=="router.precondition.refused") | .data.reason // empty' 2>/dev/null \
    | tail -1 || true)"
assert_eq "refused event reason=skip_without_override" "skip_without_override" "$refused_skip"

# ─── Test 4b: --skip-precondition WITH proper override token is honored ──────
: > "$ZBUILD_EVENTS_JSONL"
# Use an isolated HOME so the override token is scoped to this test.
TEST_HOME="$TEST_TEMP_DIR/home"
mkdir -p "$TEST_HOME/.zbuild"
echo -n "$ZBUILD_RUN_ID" > "$TEST_HOME/.zbuild/scope-override-token"
# Re-emit a non-redaction event so the bypass actually has something to bypass
jq -cn \
    --arg rid "$ZBUILD_RUN_ID" \
    '{ts:"2026-01-01T00:00:00Z", run_id:$rid, issue:0, type:"pipeline.start",
      plugin:"", kind:"", data:{}, schema_version:1}' \
    >> "$ZBUILD_EVENTS_JSONL"

set +e
out="$(HOME="$TEST_HOME" ZBUILD_SCOPE_OVERRIDE=1 route_to_model "T2" "ping" --skip-precondition 2>/dev/null)"
rc=$?
set -e
assert_eq "--skip-precondition with override token → rc=0" "0" "$rc"

skipped_count="$(grep -c '"router.precondition.skipped"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
assert_gt "router.precondition.skipped event emitted on authorised bypass" "$skipped_count" "0"

# ─── Test 5: --skip-precondition with ZBUILD_RUN_ID unset still needs token ──
# Bootstrapping path: operator must use the literal "bootstrap" as token contents.
unset ZBUILD_RUN_ID
echo -n "bootstrap" > "$TEST_HOME/.zbuild/scope-override-token"
set +e
out="$(HOME="$TEST_HOME" ZBUILD_SCOPE_OVERRIDE=1 route_to_model "T2" "ping" --skip-precondition 2>/dev/null)"
rc=$?
set -e
assert_eq "--skip-precondition + RUN_ID unset + bootstrap token → rc=0" "0" "$rc"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
