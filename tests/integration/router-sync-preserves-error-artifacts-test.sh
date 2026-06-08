#!/usr/bin/env bash
# Integration: Wave 19-K (#748) — preserve claude raw output on SYNC rc≠0.
#
# Wave 19-I (#745) shipped preserve-on-error + diagnostic event for the LOOP
# path of route_to_model_loop. The SYNC path of route_to_model at
# core/router/route.sh:~409 still emits `router.error` and immediately
# rm -f's the stderr file with the JSON envelope still inside it. Six
# stages call this path: design, plan, review, test_assessment,
# security-lens, compound-quality-cycle. Issue 12 dogfood run
# 20260608054707-48308 hit it on test_assessment.
#
# Fix: before the existing rm -f at route.sh:411, persist $response (the
# claude stdout JSON envelope) to disk and copy $stderr_file. Emit
# router.error.diagnostic with parsed .is_error/.error/.num_turns so
# operators can grep events.jsonl without opening files.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "router_sync: preserve rc≠0 diagnostic artifacts (Wave 19-K, #748)"
setup_test_env "router-sync-preserves-error-artifacts"

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_ARTIFACT_DIR="$ZBUILD_STATE_DIR/artifacts"
export ZBUILD_RUN_ID="sync-error-preserve-$$"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR/artifacts/stage-io"
: > "$ZBUILD_EVENTS_JSONL"

export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

# Stub claude: print a JSON error envelope to stdout, a line to stderr,
# then exit rc=1. The sync path captures stdout into $response and
# redirects stderr to $stderr_file — both must be preserved by the fix.
mkdir -p "$TEST_TEMP_DIR/bin"
cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
printf 'CLI internal warning: rate limit nearing\n' >&2
jq -n '{type:"result", subtype:"error_max_turns", is_error:true, error:"max_turns_reached", result:"", num_turns:13, usage:{input_tokens:100, output_tokens:0}}'
exit 1
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
export PATH="$TEST_TEMP_DIR/bin:$PATH"

PROMPT_FILE="$TEST_TEMP_DIR/prompt.txt"
echo "sync prompt — preserve-error fixture" > "$PROMPT_FILE"

REPO="$TEST_TEMP_DIR/repo"
mkdir -p "$REPO"
( cd "$REPO" && git init -q && git config user.email t@t && git config user.name t \
    && echo seed > seed.txt && git add seed.txt && git commit -q -m seed ) >/dev/null

DRIVER="$TEST_TEMP_DIR/driver.sh"
cat > "$DRIVER" <<EOF
set -euo pipefail
source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/core/event-bus/event-bus.sh"
source "$REPO_ROOT/core/router/route.sh"

export ZBUILD_EVENTS_DIR="$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_JSONL"
export ZBUILD_EVENT_SCHEMA="$ZBUILD_EVENT_SCHEMA"
export ZBUILD_STATE_DIR="$ZBUILD_STATE_DIR"
export ZBUILD_ARTIFACT_DIR="$ZBUILD_ARTIFACT_DIR"
export ZBUILD_MODELS_FILE="$ZBUILD_MODELS_FILE"
export ZBUILD_RUN_ID="$ZBUILD_RUN_ID"
export HOME="$HOME"
export ZBUILD_SCOPE_OVERRIDE=1
export PATH="$PATH"
export ZBUILD_CURRENT_STAGE=test_assessment

# Seed the C6 precondition: router requires the most-recent event for
# this run_id to be redaction.applied (proves prompt passed through the
# redaction chokepoint, ADR-004). In production this fires from
# apply_scope_redaction; the test emits it directly.
eb_emit_event "redaction.applied" "stage=test_assessment" "tier=T2"

set +e
route_to_model T2 "$PROMPT_FILE" "$REPO"
rc=\$?
set -e
echo "route_rc=\$rc" >&2
EOF

bash "$DRIVER" >/dev/null 2>/dev/null || true

print_test_section "sync rc=1 preserves diagnostic artifacts + emits diagnostic event"

# T1: existing router.error event STILL fires (regression guard — fix
# doesn't replace, it augments).
err_count="$(jq -c 'select(.type=="router.error" and .data.rc=="1")' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "T1: router.error event still emitted on rc=1" "1" "$err_count"

# T2: NEW router.error.diagnostic event emitted.
diag_count="$(jq -c 'select(.type=="router.error.diagnostic")' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "T2: router.error.diagnostic emitted" "1" "$diag_count"

# T3: diagnostic event has parsed is_error=true from the stub's JSON.
diag_is_error="$(jq -r 'select(.type=="router.error.diagnostic") | .data.is_error' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)"
assert_eq "T3: diagnostic event is_error=true (parsed from JSON envelope)" "true" "$diag_is_error"

# T4: diagnostic event has parsed error_text.
diag_err="$(jq -r 'select(.type=="router.error.diagnostic") | .data.error_text' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)"
assert_eq "T4: diagnostic event error_text=max_turns_reached" "max_turns_reached" "$diag_err"

# T5: diagnostic event has parsed num_turns.
diag_turns="$(jq -r 'select(.type=="router.error.diagnostic") | .data.num_turns' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)"
assert_eq "T5: diagnostic event num_turns=13" "13" "$diag_turns"

# T6: diagnostic event records the stage name from ZBUILD_CURRENT_STAGE.
diag_stage="$(jq -r 'select(.type=="router.error.diagnostic") | .data.stage' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)"
assert_eq "T6: diagnostic event stage=test_assessment" "test_assessment" "$diag_stage"

# T7: preserved JSON envelope artifact exists at the path the event cites.
diag_json_path="$(jq -r 'select(.type=="router.error.diagnostic") | .data.raw_json_path' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)"
if [[ -n "$diag_json_path" && "$diag_json_path" != "absent" && -f "$diag_json_path" ]]; then
    assert_pass "T7: raw-claude-output.json preserved at cited path"
    if jq -r '.error // empty' "$diag_json_path" 2>/dev/null | grep -q "max_turns_reached"; then
        assert_pass "T8: preserved JSON contains the .error field intact"
    else
        assert_fail "T8: preserved JSON should contain .error=max_turns_reached" "missing"
    fi
else
    assert_fail "T7: raw-claude-output.json MUST exist at cited path" "got: $diag_json_path"
fi

# T9: preserved stderr artifact exists at the path the event cites.
diag_stderr_path="$(jq -r 'select(.type=="router.error.diagnostic") | .data.raw_stderr_path' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)"
if [[ -n "$diag_stderr_path" && "$diag_stderr_path" != "absent" && -f "$diag_stderr_path" ]]; then
    assert_pass "T9: raw-claude-stderr.txt preserved at cited path"
    if grep -q "rate limit nearing" "$diag_stderr_path"; then
        assert_pass "T10: preserved stderr contains the original line"
    else
        assert_fail "T10: preserved stderr should contain 'rate limit nearing'" "missing"
    fi
else
    assert_fail "T9: raw-claude-stderr.txt MUST exist at cited path" "got: $diag_stderr_path"
fi

# T11: the [event-bus] WARN for unknown event type 'router.error' must NOT
# appear — schema drift fix.
if grep -q "unknown event type 'router.error'" "$ZBUILD_EVENTS_DIR"/*.log 2>/dev/null; then
    assert_fail "T11: router.error is registered in event-schema.json (no unknown-type warning)" "warn present"
else
    assert_pass "T11: router.error is registered in event-schema.json (no unknown-type warning)"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
