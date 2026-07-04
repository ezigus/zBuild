#!/usr/bin/env bash
# tests/integration/router-loop-retries-test.sh — #1230 S11
#
# The `router.retries` knob must be honored by the AGENTIC-LOOP leaf path too
# (route_to_model_loop's inline per-iteration spawn), not just single-shot
# route_to_model. The inner retry is layered BEFORE the existing #1208
# timeout_recur circuit-breaker:
#   - router.retries = intra-iteration call retries (escalated LOCAL timeout)
#   - timeout_recur  = cross-iteration breaker (unchanged, 3 → yield non-fatal)
# An iteration bumps timeout_recur only AFTER exhausting the N inner retries
# (no double-count), and repeated timeouts still yield non-fatally (#1208).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "router_loop: router.retries inner retry + #1208 breaker intact (#1230 S11)"
setup_test_env "router-loop-retries"

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild" "$TEST_TEMP_DIR/bin"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

REPO="$TEST_TEMP_DIR/repo"
mkdir -p "$REPO"
( cd "$REPO" && git init -q && git config user.email t@t && git config user.name t \
    && echo seed > seed.txt && git add seed.txt && git commit -q -m seed ) >/dev/null

CALL_LOG="$TEST_TEMP_DIR/calls.log"
# Template: build leaf with router.retries=1. Loop path (route_to_model_loop).
cat > "$TEST_TEMP_DIR/template.yaml" <<'YAML'
id: standard
name: Standard Pipeline
defaults:
  strategy: fanout
stages:
  - id: build
    gate: auto
    roles: [builder]
    router:
      timeout_s: 180
      retries: 1
    io:
      destinations: [file]
      tail_lines: 5
YAML

PROMPT_FILE="$TEST_TEMP_DIR/prompt.txt"
echo "build prompt — loop retries fixture" > "$PROMPT_FILE"

_run_loop() {
    # $1 = path to mock claude body; sets rc/reason/iters/retry-count outputs.
    local mock="$1"
    : > "$CALL_LOG"
    cp "$mock" "$TEST_TEMP_DIR/bin/claude"
    chmod +x "$TEST_TEMP_DIR/bin/claude"
    local ev="$TEST_TEMP_DIR/ev.jsonl"; : > "$ev"
    local driver="$TEST_TEMP_DIR/driver.sh"
    cat > "$driver" <<EOF
set -uo pipefail
export PATH="$TEST_TEMP_DIR/bin:\$PATH"
export HOME="$HOME"
export ZBUILD_SCOPE_OVERRIDE=1
export ZBUILD_MODELS_FILE="$ZBUILD_MODELS_FILE"
export ZBUILD_EVENT_SCHEMA="$ZBUILD_EVENT_SCHEMA"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/ev"
export ZBUILD_EVENTS_JSONL="$ev"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="loop-retries-$$"
export ZB_CALL_LOG="$CALL_LOG"
export ZB_REPO="$REPO"
mkdir -p "$TEST_TEMP_DIR/ev" "$TEST_TEMP_DIR/state/artifacts/stage-io"
source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/core/event-bus/event-bus.sh"
source "$REPO_ROOT/core/pipeline/template.sh"
source "$REPO_ROOT/core/output/stage-io.sh"
source "$REPO_ROOT/core/router/route.sh"
load_template "$TEST_TEMP_DIR/template.yaml"
export ZBUILD_CURRENT_STAGE=build
set +e
route_to_model_loop T2 "$PROMPT_FILE" "$REPO" 10
rc=\$?
set -e
printf '%s' "\$rc" > "$TEST_TEMP_DIR/rc.txt"
printf '%s' "\${_ROUTE_LOOP_TERMINATED_REASON}" > "$TEST_TEMP_DIR/reason.txt"
printf '%s' "\${_ROUTE_LOOP_ITERATIONS}" > "$TEST_TEMP_DIR/iters.txt"
EOF
    bash "$driver" >/dev/null 2>&1 || true
}

_calls() { wc -l < "$CALL_LOG" | tr -d ' '; }
_retry_events() { local c; c="$(grep -c '"router.timeout.retry"' "$TEST_TEMP_DIR/ev.jsonl" 2>/dev/null || true)"; echo "${c:-0}"; }

# ── S11a: inner retry fires within an iteration, then succeeds ───────────────
# call1 → rc=124 (empty, no sentinel). Inner retry re-spawns within iter 1.
# call2 → writes a file (diff) + LOOP_COMPLETE + rc=0 → loop done, rc=0.
cat > "$TEST_TEMP_DIR/mock-a.sh" <<'MOCK'
#!/usr/bin/env bash
printf 'x\n' >> "$ZB_CALL_LOG"
n="$(wc -l < "$ZB_CALL_LOG" | tr -d ' ')"
if [[ "$n" -eq 1 ]]; then
    exit 124
fi
printf 'feature\n' > "$ZB_REPO/feature.txt" 2>/dev/null || true
jq -n --arg r $'done\nLOOP_COMPLETE' '{type:"result",subtype:"success",is_error:false,result:$r,num_turns:3,usage:{input_tokens:10,output_tokens:20,cache_read_input_tokens:0,cache_creation_input_tokens:0}}'
exit 0
MOCK
_run_loop "$TEST_TEMP_DIR/mock-a.sh"
assert_eq "[S11a] rc=0 (loop completed after inner retry)" "0" "$(cat "$TEST_TEMP_DIR/rc.txt")"
assert_eq "[S11a] inner retry fired → exactly 2 claude calls in iter 1" "2" "$(_calls)"
assert_eq "[S11a] exactly 1 router.timeout.retry event" "1" "$(_retry_events)"
assert_eq "[S11a] loop terminated on done_sentinel (not a timeout yield)" \
    "done_sentinel" "$(cat "$TEST_TEMP_DIR/reason.txt")"
assert_eq "[S11a] completed in 1 iteration (retry stayed intra-iteration)" \
    "1" "$(cat "$TEST_TEMP_DIR/iters.txt")"

# ── S11b: always-timeout → #1208 breaker intact, timeout_recur NOT double-bump ─
# retries=1 means 2 calls per iteration (1 + 1 inner retry). timeout_recur bumps
# ONCE per iteration → yields at 3 iterations = 6 calls (non-fatal rc=0). If the
# breaker double-counted inner attempts it would yield in 2 calls / <3 iters.
cat > "$TEST_TEMP_DIR/mock-b.sh" <<'MOCK'
#!/usr/bin/env bash
printf 'x\n' >> "$ZB_CALL_LOG"
n="$(wc -l < "$ZB_CALL_LOG" | tr -d ' ')"
# Keep the diff non-empty so the no-progress net doesn't pre-empt the timeout path.
printf 'partial %s\n' "$n" >> "$ZB_REPO/wip.txt" 2>/dev/null || true
exit 124
MOCK
_run_loop "$TEST_TEMP_DIR/mock-b.sh"
assert_eq "[S11b] always-timeout yields non-fatally (#1208 intact, rc=0)" \
    "0" "$(cat "$TEST_TEMP_DIR/rc.txt")"
assert_eq "[S11b] yield reason is router_timeout" \
    "router_timeout" "$(cat "$TEST_TEMP_DIR/reason.txt")"
assert_eq "[S11b] breaker counts ITERATIONS not attempts → yield at 3 iters" \
    "3" "$(cat "$TEST_TEMP_DIR/iters.txt")"
assert_eq "[S11b] 3 iters × (1 call + 1 inner retry) = 6 claude calls" \
    "6" "$(_calls)"
assert_eq "[S11b] 3 inner retries emitted (one per iteration)" "3" "$(_retry_events)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
