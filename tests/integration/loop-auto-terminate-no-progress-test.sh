#!/usr/bin/env bash
# Integration test (#613): route_to_model_loop auto-terminates after 2
# consecutive empty-diff iters when the LLM never emits LOOP_COMPLETE.
#
# Without this safety net, a stuck LLM (one that responds but makes no
# edits and forgets the sentinel) burns ALL max_iterations doing nothing.
# The new behaviour: empty diff twice in a row → terminate with
# reason=no_progress + loop.no_progress event.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "loop: auto-terminate on 2 empty-diff iters (#613)"
setup_test_env "loop-auto-terminate-no-progress"

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="loop-no-progress-$$"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR/artifacts/stage-io"

export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

REPO="$TEST_TEMP_DIR/repo"
mkdir -p "$REPO"
( cd "$REPO" \
    && git init -q \
    && git config user.email t@t \
    && git config user.name t \
    && echo seed > seed.txt \
    && git add seed.txt \
    && git commit -q -m seed ) >/dev/null

# Stub claude: NO edits, NEVER emits LOOP_COMPLETE.
MARK_FILE="$TEST_TEMP_DIR/llm-call.mark"
mkdir -p "$TEST_TEMP_DIR/bin"
cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
mark="${MARK_FILE:-/tmp/mark}"
echo "iter" >> "$mark"
jq -n --arg r "thinking, no changes yet" \
    '{result:$r, usage:{input_tokens:5, output_tokens:3}}'
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
export PATH="$TEST_TEMP_DIR/bin:$PATH"
export MARK_FILE

cat > "$TEST_TEMP_DIR/template.yaml" <<'YAML'
id: standard
name: Standard Pipeline
extends: null
defaults:
  strategy: fanout
stages:
  - id: build
    gate: auto
    roles: [builder]
    io:
      destinations: [file]
      tail_lines: 5
YAML

PROMPT_FILE="$TEST_TEMP_DIR/prompt.txt"
echo "build prompt — no-progress fixture" > "$PROMPT_FILE"

DRIVER="$TEST_TEMP_DIR/driver.sh"
REASON_OUT="$TEST_TEMP_DIR/reason.txt"
ITERS_OUT="$TEST_TEMP_DIR/iters.txt"
RC_OUT="$TEST_TEMP_DIR/rc.txt"

cat > "$DRIVER" <<EOF
set -euo pipefail
source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/core/event-bus/event-bus.sh"
source "$REPO_ROOT/core/pipeline/template.sh"
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
export MARK_FILE="$MARK_FILE"

load_template "$TEST_TEMP_DIR/template.yaml"
export ZBUILD_CURRENT_STAGE=build

set +e
route_to_model_loop T2 "$PROMPT_FILE" "$REPO" 10
rc=\$?
set -e
printf '%s' "\$rc"                            > "$RC_OUT"
printf '%s' "\${_ROUTE_LOOP_TERMINATED_REASON}" > "$REASON_OUT"
printf '%s' "\${_ROUTE_LOOP_ITERATIONS}"        > "$ITERS_OUT"
EOF

bash "$DRIVER" >/dev/null 2>/dev/null || true

rc="$(cat "$RC_OUT" 2>/dev/null || echo missing)"
reason="$(cat "$REASON_OUT" 2>/dev/null || echo missing)"
iters="$(cat "$ITERS_OUT" 2>/dev/null || echo missing)"
mark_count="$(wc -l < "$MARK_FILE" 2>/dev/null | tr -d ' ' || echo 0)"

# B1: loop returned 0 (clean auto-termination, not a fatal error).
assert_eq "B1: route_to_model_loop returned 0 (clean auto-term)" "0" "$rc"

# B2: terminated AFTER 2 empty-diff iters — not the 10-iter ceiling.
assert_eq "B2: terminated after exactly 2 iterations (empty-diff streak)" "2" "$iters"

# B3: stub claude was invoked exactly twice — proves loop did not run all 10.
assert_eq "B3: stub claude invoked exactly twice" "2" "$mark_count"

# B4: termination reason is the new no_progress sentinel.
assert_eq "B4: _ROUTE_LOOP_TERMINATED_REASON == no_progress" \
    "no_progress" "$reason"

# B5: loop.no_progress event was emitted with the empty-iter streak count.
no_progress_count="$(jq -c --arg t "loop.no_progress" \
    'select(.type==$t)' \
    "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "B5: one loop.no_progress event emitted" "1" "$no_progress_count"

# B6: NO loop.max_iterations event — proves we tripped the safety net first.
max_iter_count="$(jq -c --arg t "loop.max_iterations" \
    'select(.type==$t)' \
    "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "B6: no loop.max_iterations event (safety net fired first)" \
    "0" "$max_iter_count"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
