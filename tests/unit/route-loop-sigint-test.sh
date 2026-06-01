#!/usr/bin/env bash
# Unit test (#612): route_to_model_loop MUST propagate SIGINT (rc=130) from
# the child claude process as a TERMINAL condition.
#
# Today the generic `if [[ $rc -ne 0 ]]` handler in route.sh treats rc=130 as
# a transient error and `continue`s — the loop happily spawns another claude
# call, making the pipeline impossible to interrupt with Ctrl-C.
#
# Contract:
#   - Stub claude returns rc=130 → route_to_model_loop returns 130 (not 0/1/2).
#   - `_ROUTE_LOOP_TERMINATED_REASON` is set to "signal".
#   - `loop.terminated.signal` event is emitted.
#   - Claude is invoked EXACTLY ONCE — the loop does NOT iterate after rc=130.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "route-loop-sigint — rc=130 terminates loop (#612)"
setup_test_env "route-loop-sigint"
_test_cleanup_hook() { cleanup_test_env; }

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="route-sigint-$$"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR/artifacts/stage-io"

export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

# ── Throwaway git repo. ─────────────────────────────────────────────────────
REPO="$TEST_TEMP_DIR/repo"
mkdir -p "$REPO"
( cd "$REPO" \
    && git init -q \
    && git config user.email t@t \
    && git config user.name t \
    && echo seed > seed.txt \
    && git add seed.txt \
    && git commit -q -m seed ) >/dev/null

# ── Static prompt. ──────────────────────────────────────────────────────────
PROMPT_FILE="$TEST_TEMP_DIR/prompt.txt"
echo "test prompt body" > "$PROMPT_FILE"

# ── Mock claude: records every invocation, exits 130 (SIGINT equivalent).
mkdir -p "$TEST_TEMP_DIR/bin"
CALL_LOG="$TEST_TEMP_DIR/claude-calls.log"
: > "$CALL_LOG"

cat > "$TEST_TEMP_DIR/bin/claude" <<MOCK
#!/usr/bin/env bash
echo "call" >> "$CALL_LOG"
# Mimic a child process being killed by SIGINT: exit 130.
exit 130
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
export PATH="$TEST_TEMP_DIR/bin:$PATH"
export CALL_LOG

# ── Driver subprocess: invoke route_to_model_loop with max_iterations=5.
DRIVER="$TEST_TEMP_DIR/driver.sh"
RC_FILE="$TEST_TEMP_DIR/router-rc"
REASON_FILE="$TEST_TEMP_DIR/router-reason"

cat > "$DRIVER" <<EOF
set +e
source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/core/event-bus/event-bus.sh"
source "$REPO_ROOT/core/output/stage-io.sh"
source "$REPO_ROOT/core/router/route.sh"

export ZBUILD_EVENTS_DIR="$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_JSONL"
export ZBUILD_EVENT_SCHEMA="$ZBUILD_EVENT_SCHEMA"
export ZBUILD_STATE_DIR="$ZBUILD_STATE_DIR"
export ZBUILD_MODELS_FILE="$ZBUILD_MODELS_FILE"
export ZBUILD_RUN_ID="$ZBUILD_RUN_ID"
export HOME="$HOME"
export ZBUILD_SCOPE_OVERRIDE=1
export PATH="$PATH"

route_to_model_loop T2 "$PROMPT_FILE" "$REPO" 5
rc=\$?
printf '%s' "\$rc" > "$RC_FILE"
printf '%s' "\${_ROUTE_LOOP_TERMINATED_REASON:-EMPTY}" > "$REASON_FILE"
EOF

bash "$DRIVER" >/dev/null 2>&1 || true

# ─── Assertions ──────────────────────────────────────────────────────────────

# (0) Sanity: driver ran.
assert_file_exists "router-rc captured" "$RC_FILE"
assert_file_exists "router-reason captured" "$REASON_FILE"

# (1) Loop returns 130 — NOT 0, 1, or 2.
router_rc="$(cat "$RC_FILE" 2>/dev/null || echo MISSING)"
assert_eq "route_to_model_loop returns 130 on child rc=130" "130" "$router_rc"

# (2) Terminated reason is "signal".
router_reason="$(cat "$REASON_FILE" 2>/dev/null || echo MISSING)"
assert_eq "_ROUTE_LOOP_TERMINATED_REASON is 'signal'" "signal" "$router_reason"

# (3) Claude was invoked EXACTLY ONCE — no iteration after rc=130.
call_count="$(wc -l < "$CALL_LOG" 2>/dev/null | tr -d ' ' || echo 0)"
assert_eq "claude invoked exactly once (loop did NOT continue after rc=130)" "1" "$call_count"

# (4) loop.terminated.signal event is in the events log.
if [[ -f "$ZBUILD_EVENTS_JSONL" ]] && grep -q '"type":"loop.terminated.signal"' "$ZBUILD_EVENTS_JSONL"; then
    assert_pass "loop.terminated.signal event emitted"
else
    assert_fail "loop.terminated.signal event emitted" \
        "events_jsonl tail: $(tail -c 400 "$ZBUILD_EVENTS_JSONL" 2>/dev/null || echo MISSING)"
fi

print_test_results
