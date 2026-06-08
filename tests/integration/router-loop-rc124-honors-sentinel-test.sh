#!/usr/bin/env bash
# Integration: Wave 19-I Fix A (#743) — sentinel-on-rc124 honoring.
#
# Dogfood 20260607181657-82646 iter 4 ran 900s (router.timeout_s for build),
# claude emitted LOOP_COMPLETE in its .result, then gtimeout fired at 900s,
# killing claude with rc=124 before the CLI could exit cleanly with rc=0.
# The rc≠0 branch in route_to_model_loop skips the sentinel check entirely,
# so the work-done signal is discarded and iter 5 starts with the
# already-complete code as "diff to continue from."
#
# Fix: when rc=124 AND the captured .result contains LOOP_COMPLETE on its
# own line, treat as successful done_sentinel termination.
#
# Mirrors the harness pattern from loop-already-done-emits-complete-test.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "router_loop: rc=124 honors LOOP_COMPLETE sentinel (Wave 19-I Fix A, #743)"
setup_test_env "router-loop-rc124-honors-sentinel"

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="loop-rc124-sentinel-$$"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR/artifacts/stage-io"

export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

# Fixture repo: a real change committed so each iter sees a non-empty diff
# (route_to_model_loop's safety net would otherwise terminate on no-progress).
REPO="$TEST_TEMP_DIR/repo"
mkdir -p "$REPO"
( cd "$REPO" && git init -q && git config user.email t@t && git config user.name t \
    && echo seed > seed.txt && git add seed.txt && git commit -q -m seed ) >/dev/null

# Stub claude: writes a file (so diff is non-empty), emits a JSON envelope
# with LOOP_COMPLETE in .result, then exits rc=124 (gtimeout-after-sentinel).
MARK_FILE="$TEST_TEMP_DIR/llm-call.mark"
mkdir -p "$TEST_TEMP_DIR/bin"
cat > "$TEST_TEMP_DIR/bin/claude" <<MOCK
#!/usr/bin/env bash
mark="\${MARK_FILE:-/tmp/mark}"
echo "iter" >> "\$mark"
# Simulate work done in the repo.
printf 'feature\n' > "$REPO/feature.txt" 2>/dev/null || true
# Emit the JSON envelope with LOOP_COMPLETE in .result, then exit 124.
# The heredoc above uses MOCK (unquoted-heredoc) so we need \$ to defer
# variable expansion to runtime. The jq command is written on a single
# line to avoid the \\\\ literal-backslash trap from earlier review.
jq -n --arg r \$'All changes complete.\nCOMMIT_SUMMARY: finish migration\nLOOP_COMPLETE' '{type:"result", subtype:"success", is_error:false, result:\$r, num_turns:18, usage:{input_tokens:50, output_tokens:2000, cache_read_input_tokens:100000, cache_creation_input_tokens:5000}}'
exit 124
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
export PATH="$TEST_TEMP_DIR/bin:$PATH"
export MARK_FILE

# Minimal template — no banner assertions needed.
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
echo "build prompt — rc124 sentinel fixture" > "$PROMPT_FILE"

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
printf '%s' "\$rc"                              > "$RC_OUT"
printf '%s' "\${_ROUTE_LOOP_TERMINATED_REASON}" > "$REASON_OUT"
printf '%s' "\${_ROUTE_LOOP_ITERATIONS}"        > "$ITERS_OUT"
EOF

bash "$DRIVER" >/dev/null 2>/dev/null || true

rc="$(cat "$RC_OUT" 2>/dev/null || echo missing)"
reason="$(cat "$REASON_OUT" 2>/dev/null || echo missing)"
iters="$(cat "$ITERS_OUT" 2>/dev/null || echo missing)"
mark_count="$(wc -l < "$MARK_FILE" 2>/dev/null | tr -d ' ' || echo 0)"

print_test_section "rc=124 with LOOP_COMPLETE in .result converges as done_sentinel"

# T1: loop exited cleanly (return 0 == done_sentinel branch).
assert_eq "T1: route_to_model_loop returned 0 (sentinel honored)" "0" "$rc"

# T2: only ONE iteration ran — proof of sentinel pre-emption.
assert_eq "T2: exactly 1 iteration consumed (sentinel pre-empts iter 2)" "1" "$iters"

# T3: stub claude was invoked exactly once.
assert_eq "T3: stub claude invoked exactly once" "1" "$mark_count"

# T4: termination reason is done_sentinel.
assert_eq "T4: _ROUTE_LOOP_TERMINATED_REASON == done_sentinel" "done_sentinel" "$reason"

# T5: NEW timeout_with_sentinel event fired.
twsentinel_count="$(jq -c 'select(.type=="router.loop.iter.timeout_with_sentinel")' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "T5: router.loop.iter.timeout_with_sentinel event emitted" "1" "$twsentinel_count"

# T6: loop.iteration.error NOT emitted (sentinel pre-empted the error path).
err_count="$(jq -c 'select(.type=="loop.iteration.error")' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "T6: loop.iteration.error NOT emitted for the rescued iter" "0" "$err_count"

# T7: loop.complete event has reason=done_sentinel.
complete_count="$(jq -c --arg t "loop.complete" 'select(.type==$t and .data.reason=="done_sentinel")' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "T7: one loop.complete event w/ reason=done_sentinel" "1" "$complete_count"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
