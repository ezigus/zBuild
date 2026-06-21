#!/usr/bin/env bash
# Integration test (#613): route_to_model_loop terminates after iter 1 when
# the stub LLM sees the branch is already done and emits LOOP_COMPLETE
# immediately. This is the in-spec happy path for the sharpened sentinel
# rule: "emit LOOP_COMPLETE whether you just finished it OR it was already
# done before you started."
#
# Counterpart to loop-auto-terminate-no-progress-test.sh, which exercises
# the safety-net branch (LLM forgets the sentinel, loop kills itself).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "loop: already-done branch → 1 iter, done_sentinel (#613)"
setup_test_env "loop-already-done-emits-complete"

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="loop-already-done-$$"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR/artifacts/stage-io"

export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

# Repo where the "required change" is already committed so the stub LLM has
# a legitimate reason to short-circuit on iter 1.
REPO="$TEST_TEMP_DIR/repo"
mkdir -p "$REPO"
( cd "$REPO" \
    && git init -q \
    && git config user.email t@t \
    && git config user.name t \
    && echo seed > seed.txt \
    && git add seed.txt \
    && git commit -q -m seed \
    && echo "REQUIRED_CHANGE_ALREADY_PRESENT" > feature.txt \
    && git add feature.txt \
    && git commit -q -m "feat: required change" ) >/dev/null

# Stub claude: produces NO edits, emits LOOP_COMPLETE on iter 1.
MARK_FILE="$TEST_TEMP_DIR/llm-call.mark"
if [[ -n "$MARK_FILE" ]]; then
    assert_pass "[SPEC-1] MARK_FILE non-empty at setup"
else
    assert_fail "[SPEC-1] MARK_FILE non-empty at setup" "MARK_FILE is empty or unset"
fi
mkdir -p "$TEST_TEMP_DIR/bin"
cat > "$TEST_TEMP_DIR/bin/claude" <<MOCK
#!/usr/bin/env bash
mark="$MARK_FILE"
echo "iter" >> "\$mark"
jq -n --arg r \$'branch already contains the required change\nLOOP_COMPLETE' \
    '{result:\$r, usage:{input_tokens:5, output_tokens:3}}'
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
assert_contains "[SPEC-2] mock-claude bakes concrete MARK_FILE path at write time" \
    "$(cat "$TEST_TEMP_DIR/bin/claude")" "$MARK_FILE"
mock_body="$(cat "$TEST_TEMP_DIR/bin/claude")"
if ! grep -qF '/tmp/mark' <<< "$mock_body" 2>/dev/null; then
    assert_pass "[SPEC-3] mock-claude has no /tmp/mark fallback"
else
    assert_fail "[SPEC-3] mock-claude has no /tmp/mark fallback" "found /tmp/mark in mock body"
fi
export PATH="$TEST_TEMP_DIR/bin:$PATH"
export MARK_FILE

# Minimal template — no stage-io banner assertions needed here.
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
echo "build prompt — short-circuit fixture" > "$PROMPT_FILE"

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

# A1: loop exited cleanly (return 0 == done_sentinel branch).
assert_eq "A1: route_to_model_loop returned 0" "0" "$rc"

# A2: only ONE iteration ran — proof of the short-circuit.
assert_eq "A2: exactly 1 iteration consumed" "1" "$iters"

# A3: stub claude was invoked exactly once.
assert_eq "A3: stub claude invoked exactly once" "1" "$mark_count"

# A4: termination reason is the sentinel branch.
assert_eq "A4: _ROUTE_LOOP_TERMINATED_REASON == done_sentinel" \
    "done_sentinel" "$reason"

# A5: loop.complete event with reason=done_sentinel was emitted.
complete_count="$(jq -c --arg t "loop.complete" \
    'select(.type==$t and .data.reason=="done_sentinel")' \
    "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "A5: one loop.complete event w/ reason=done_sentinel" "1" "$complete_count"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
