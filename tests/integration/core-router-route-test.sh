#!/usr/bin/env bash
# Tests: core/router/route.sh — ADR-003 model router stub (issue #84)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/router/route — ADR-003 model router stub (issue #84)"
setup_test_env "router"

# ─── Shared env ──────────────────────────────────────────────────────────────
export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$TEST_TEMP_DIR/events"

# #289 rescope: --skip-precondition now requires the operator-override token
# (ZBUILD_SCOPE_OVERRIDE=1 + ~/.zbuild/scope-override-token matching RUN_ID or
# the literal "bootstrap"). Set up an isolated HOME so the tier-selection /
# error-path tests can use the flag without depending on the user's real
# ~/.zbuild.
export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
echo -n "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

# ─── Mock: model-recording claude stub (tests 1-3, 7-8) ──────────────────────
# Parses --model <id> from args (ignores -p and --print), records model to
# last_model, echoes "OK-RESPONSE". TEST_TEMP_DIR embedded at mock creation time.
cat > "$TEST_TEMP_DIR/bin/claude" <<MOCK
#!/usr/bin/env bash
model_id=""
while [[ \$# -gt 0 ]]; do
    if [[ "\$1" == "--model" && -n "\${2:-}" ]]; then
        model_id="\$2"; shift 2
    else
        shift
    fi
done
printf '%s\n' "\$model_id" > "$TEST_TEMP_DIR/last_model"
echo "OK-RESPONSE"
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"

# Source the module under test (after env is set).
# shellcheck source=../core/router/route.sh
source "$REPO_ROOT/core/router/route.sh"

# ─── Test 1: T2 selects Sonnet ───────────────────────────────────────────────
: > "$TEST_TEMP_DIR/last_model"

set +e
out="$(route_to_model "T2" "ping" --skip-precondition 2>/dev/null)"
rc=$?
set -e

assert_eq "T2 route returns rc=0" "0" "$rc"
last_model="$(cat "$TEST_TEMP_DIR/last_model" 2>/dev/null || true)"
assert_eq "T2 selects claude-sonnet-4-6" "claude-sonnet-4-6" "$last_model"

# ─── Test 2: T1 selects Haiku ────────────────────────────────────────────────
: > "$TEST_TEMP_DIR/last_model"

set +e
out="$(route_to_model "T1" "ping" --skip-precondition 2>/dev/null)"
rc=$?
set -e

assert_eq "T1 route returns rc=0" "0" "$rc"
last_model="$(cat "$TEST_TEMP_DIR/last_model" 2>/dev/null || true)"
assert_eq "T1 selects claude-haiku-4-5-20251001" "claude-haiku-4-5-20251001" "$last_model"

# ─── Test 3: T3 selects Opus ─────────────────────────────────────────────────
: > "$TEST_TEMP_DIR/last_model"

set +e
out="$(route_to_model "T3" "ping" --skip-precondition 2>/dev/null)"
rc=$?
set -e

assert_eq "T3 route returns rc=0" "0" "$rc"
last_model="$(cat "$TEST_TEMP_DIR/last_model" 2>/dev/null || true)"
assert_eq "T3 selects claude-opus-4-7" "claude-opus-4-7" "$last_model"

# ─── Test 4: T0 (wasm) returns rc=2 ─────────────────────────────────────────
set +e
err="$(route_to_model "T0" "ping" --skip-precondition 2>&1 >/dev/null)"
rc=$?
set -e

assert_eq "T0 wasm returns rc=2" "2" "$rc"
assert_contains "T0 stderr mentions not implemented" "$err" "not implemented"

# ─── Test 5: T4 (empty candidates) returns rc=1 ──────────────────────────────
set +e
err="$(route_to_model "T4" "ping" --skip-precondition 2>&1 >/dev/null)"
rc=$?
set -e

assert_eq "T4 empty candidates returns rc=1" "1" "$rc"
assert_contains "T4 stderr mentions no candidates" "$err" "no candidates"

# ─── Test 6: invalid tier returns rc=2 ───────────────────────────────────────
set +e
err="$(route_to_model "T9" "ping" --skip-precondition 2>&1 >/dev/null)"
rc=$?
set -e

assert_eq "invalid tier returns rc=2" "2" "$rc"
assert_contains "invalid tier stderr mentions invalid tier" "$err" "invalid tier"

# ─── Test 7: model.route event emitted with correct fields ───────────────────
: > "$ZBUILD_EVENTS_JSONL"
: > "$TEST_TEMP_DIR/last_model"

set +e
route_to_model "T2" "ping" --skip-precondition >/dev/null 2>&1
set -e

event_tier="$(grep '"model.route"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | \
    jq -r 'select(.type=="model.route") | .data.tier // empty' 2>/dev/null | tail -1 || true)"
event_model="$(grep '"model.route"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | \
    jq -r 'select(.type=="model.route") | .data.model_id // empty' 2>/dev/null | tail -1 || true)"

assert_eq "model.route event has tier=T2" "T2" "$event_tier"
assert_eq "model.route event has model_id=claude-sonnet-4-6" "claude-sonnet-4-6" "$event_model"

# ─── Test 8: response passthrough ────────────────────────────────────────────
: > "$TEST_TEMP_DIR/last_model"

set +e
out="$(route_to_model "T2" "ping" --skip-precondition 2>/dev/null)"
rc=$?
set -e

assert_eq "response passthrough returns rc=0" "0" "$rc"
assert_eq "stdout is OK-RESPONSE" "OK-RESPONSE" "$out"

# ─── Test 9: mock claude exits 1 → rc=1 (recoverable) ───────────────────────
# Swap in a failing claude mock.
cat > "$TEST_TEMP_DIR/bin/claude" <<'FAIL_MOCK'
#!/usr/bin/env bash
exit 1
FAIL_MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"

set +e
out="$(route_to_model "T2" "ping" --skip-precondition 2>/dev/null)"
rc=$?
set -e

assert_eq "claude CLI failure returns rc=1 (recoverable)" "1" "$rc"
assert_eq "no stdout on claude failure" "" "$out"

# ─── Test A4a: claude binary missing → rc=1 + router.error event ─────────────
# Simulate missing binary by placing a fake claude wrapper that returns 127
# (standard "command not found" exit code), then verify the router handles it.
# Note: We cannot completely hide the real claude binary on macOS without using
# Bash 3 (which breaks zbuild). Instead we verify the code path via a wrapper
# that immediately exits 127. The router checks "command -v claude" which would
# find the wrapper; to test the actual missing-binary path, we place a wrapper
# that mimics the "not found" behavior for the claude CLI subprocess call.
#
# For direct missing-binary test, verify the detection logic is correct in code:
# The router.sh now has: if ! command -v claude >/dev/null 2>&1; then ... return 1
# We verify this by checking what happens when a fake mock exits 127 (not found).
cat > "$TEST_TEMP_DIR/bin/claude" <<'MISSING_MOCK'
#!/usr/bin/env bash
# Simulate binary-not-found behavior at subprocess level
exit 127
MISSING_MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
: > "$ZBUILD_EVENTS_JSONL"

# With the 127-exit mock: `command -v claude` still FINDS the mock (it exists).
# The router emits router.error with reason=claude_cli_failed (rc=127).
set +e
err="$(route_to_model "T2" "ping" --skip-precondition 2>&1 >/dev/null)"
rc=$?
set -e

assert_eq "A4a: claude rc=127 → route_to_model returns rc=1" "1" "$rc"

a4a_err_evt=$(grep '"router.error"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | \
    jq -r 'select(.type=="router.error") | .data.reason // empty' 2>/dev/null | tail -1 || true)
# rc=127 is treated as claude_cli_failed (general failure) — binary-missing check
# triggers only when command -v itself fails (no binary at all in PATH).
assert_eq "A4a: rc=127 mock → router.error event emitted" "claude_cli_failed" "$a4a_err_evt"

# ─── Test A4a2: truly missing claude binary → claude_binary_missing event ────
# Run in a subshell with PATH reduced to only system dirs that don't have claude.
: > "$ZBUILD_EVENTS_JSONL"
set +e
a4a2_result=$(
    export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_JSONL"
    export ZBUILD_MODELS_FILE="$ZBUILD_MODELS_FILE"
    export ZBUILD_EVENT_SCHEMA="$ZBUILD_EVENT_SCHEMA"
    export ZBUILD_EVENTS_DIR="$ZBUILD_EVENTS_DIR"
    export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DB"
    export ZBUILD_RUN_ID="${ZBUILD_RUN_ID:-}"
    # Use a PATH with only a safe temp dir that has no claude binary
    safe_dir="$(mktemp -d)"
    # Copy only jq, bash, date, sed, awk, grep which router needs
    for b in jq bash date sed awk grep cat printf mkdir rm cp; do
        p="$(command -v "$b" 2>/dev/null || true)"
        [[ -n "$p" ]] && ln -sf "$p" "$safe_dir/$b" 2>/dev/null || true
    done
    export PATH="$safe_dir"
    source "$REPO_ROOT/core/router/route.sh" 2>/dev/null || true
    route_to_model "T2" "ping" --skip-precondition 2>/dev/null
    echo "rc=$?"
    rm -rf "$safe_dir"
)
set -e
a4a2_rc=$(printf '%s' "$a4a2_result" | grep 'rc=' | cut -d= -f2 || true)
a4a2_evt=$(grep '"router.error"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | \
    jq -r 'select(.type=="router.error") | .data.reason // empty' 2>/dev/null | tail -1 || true)
assert_eq "A4a2: no claude in PATH → route_to_model returns rc=1" "1" "$a4a2_rc"
assert_eq "A4a2: router.error reason=claude_binary_missing" "claude_binary_missing" "$a4a2_evt"

# ─── Test A4b: claude -p returns rc=1 → deterministic error emitted ───────────
# Already tested in test 9 (above). Verify router.error event is emitted.
cat > "$TEST_TEMP_DIR/bin/claude" <<'FAIL_MOCK'
#!/usr/bin/env bash
exit 1
FAIL_MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
: > "$ZBUILD_EVENTS_JSONL"

set +e
out="$(route_to_model "T2" "ping" --skip-precondition 2>/dev/null)"
rc=$?
set -e

assert_eq "A4b: claude rc=1 → route_to_model returns rc=1" "1" "$rc"

a4b_err_evt=$(grep '"router.error"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | \
    jq -r 'select(.type=="router.error") | .data.reason // empty' 2>/dev/null | tail -1 || true)
assert_eq "A4b: router.error event reason=claude_cli_failed" "claude_cli_failed" "$a4b_err_evt"

# ─── Test A4c: empty response → error event emitted ───────────────────────────
cat > "$TEST_TEMP_DIR/bin/claude" <<'EMPTY_MOCK'
#!/usr/bin/env bash
printf ""
exit 0
EMPTY_MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
: > "$ZBUILD_EVENTS_JSONL"

set +e
out="$(route_to_model "T2" "ping" --skip-precondition 2>/dev/null)"
rc=$?
set -e

assert_eq "A4c: empty response → rc=1 (recoverable)" "1" "$rc"

a4c_err_evt=$(grep '"router.error"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | \
    jq -r 'select(.type=="router.error") | .data.reason // empty' 2>/dev/null | tail -1 || true)
assert_eq "A4c: router.error event reason=empty_response" "empty_response" "$a4c_err_evt"

# ─── Test A4d: model.route emitted without preceding redaction.applied ─────────
# Restore working claude mock
cat > "$TEST_TEMP_DIR/bin/claude" <<'GOOD_MOCK'
#!/usr/bin/env bash
echo "OK-RESPONSE"
exit 0
GOOD_MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"

# Set ZBUILD_RUN_ID so the C6 check sees run events.
export ZBUILD_RUN_ID="c6-test-run-id"
: > "$ZBUILD_EVENTS_JSONL"

# Emit a non-redaction event for this run_id (stage.start, not redaction.applied)
jq -cn --arg rid "$ZBUILD_RUN_ID" \
    '{ts:"2026-01-01T00:00:00Z", run_id:$rid, issue:0, type:"stage.start",
      plugin:"", kind:"", data:{stage:"intake"}, schema_version:1}' \
    >> "$ZBUILD_EVENTS_JSONL"

set +e
out="$(route_to_model "T2" "ping" 2>/dev/null)"
rc=$?
set -e

assert_eq "A4d: model.route without redaction.applied → rc=2 (fatal)" "2" "$rc"

a4d_evt=$(grep '"router.precondition.violated"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | \
    jq -r '.type // empty' 2>/dev/null | tail -1 || true)
assert_eq "A4d: router.precondition.violated event emitted" "router.precondition.violated" "$a4d_evt"

# ─── Test A4e: model.route WITH preceding redaction.applied → succeeds ─────────
: > "$ZBUILD_EVENTS_JSONL"

# Emit a redaction.applied event for this run_id (precondition satisfied)
jq -cn --arg rid "$ZBUILD_RUN_ID" \
    '{ts:"2026-01-01T00:00:00Z", run_id:$rid, issue:0, type:"redaction.applied",
      plugin:"", kind:"", data:{}, schema_version:1}' \
    >> "$ZBUILD_EVENTS_JSONL"

set +e
out="$(route_to_model "T2" "ping" 2>/dev/null)"
rc=$?
set -e

assert_eq "A4e: model.route with redaction.applied preceding → rc=0" "0" "$rc"
assert_eq "A4e: response passthrough works" "OK-RESPONSE" "$out"

# ─── Teardown ────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
exit $((FAIL > 0))
