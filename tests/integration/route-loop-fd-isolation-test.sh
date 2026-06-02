#!/usr/bin/env bash
# Integration: route_to_model_loop's background spawn does not leak fd 3
# or ZBUILD_STAGE_IO_FD into the claude subprocess (issue #647).
#
# Companion to route-fd-isolation-test.sh — covers the loop variant. The
# build agent plugin routes through route_to_model_loop, whose claude
# spawn is `( cd "$cwd" && claude ... ) &` (background), so the fd-close
# pattern is slightly different from _route_call_claude's synchronous $().
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "integration: route_to_model_loop fd 3 / ZBUILD_STAGE_IO_FD isolation (#647)"
setup_test_env "route-loop-fd-isolation"

# Pin TMPDIR so the loop's per-iter tmpdir lands somewhere predictable.
ISOLATED_TMP="$TEST_TEMP_DIR/iso-tmp"
mkdir -p "$ISOLATED_TMP"
export TMPDIR="$ISOLATED_TMP"

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="loop-fd-iso-$$"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR/artifacts/stage-io"

export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

# Fixture git repo for the loop's cwd.
REPO="$TEST_TEMP_DIR/repo"
mkdir -p "$REPO"
( cd "$REPO" \
    && git init -q \
    && git config user.email t@t \
    && git config user.name t \
    && echo seed > seed.txt \
    && git add seed.txt \
    && git commit -q -m seed ) >/dev/null

# Stub claude: writes ENV_LEAK / FD3_LEAK markers to a shared file
# (stderr is consumed by the loop's stderr_file, so we use a side-channel
# the parent shell can inspect after the run). Always emits a sentinel
# response so the loop terminates on iter 1 (no_progress / done_sentinel).
LEAK_LOG="$TEST_TEMP_DIR/leak.log"
: > "$LEAK_LOG"
export ZB_LEAK_LOG="$LEAK_LOG"

mkdir -p "$TEST_TEMP_DIR/bin"
cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
if [[ -n "${ZBUILD_STAGE_IO_FD:-}" ]]; then
    printf 'ENV_LEAK ZBUILD_STAGE_IO_FD=%s\n' "$ZBUILD_STAGE_IO_FD" >> "$ZB_LEAK_LOG"
fi
if ( : >&3 ) 2>/dev/null; then
    printf 'FD3_LEAK\n' >> "$ZB_LEAK_LOG"
fi
jq -n --arg r $'all done\nLOOP_COMPLETE' \
    '{result:$r, usage:{input_tokens:1, output_tokens:1}}'
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
export PATH="$TEST_TEMP_DIR/bin:$PATH"

# Minimal pipeline template so per-iter stage_io banner doesn't fail hard.
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
echo "loop fd isolation fixture" > "$PROMPT_FILE"

# Sentinel that fd 3 would write to if not closed in the loop's background
# subshell.
SENTINEL="$TEST_TEMP_DIR/fd3-sentinel.txt"
: > "$SENTINEL"

# Drive via a sub-bash so we can open fd 3 → SENTINEL and export the env
# var without polluting the test runner's own fd table. The sub-bash sources
# the modules, opens fd 3, then calls route_to_model_loop. Cap timeout low.
DRIVER="$TEST_TEMP_DIR/driver.sh"
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
export TMPDIR="$TMPDIR"
export ZB_LEAK_LOG="$LEAK_LOG"
export ZBUILD_ROUTER_TIMEOUT=5

load_template "$TEST_TEMP_DIR/template.yaml"
export ZBUILD_CURRENT_STAGE=build

# Simulate parent runner: open fd 3 → sentinel and export the stage-io fd
# var. The router's loop must isolate these from the claude subprocess.
exec 3>"$SENTINEL"
export ZBUILD_STAGE_IO_FD=3

set +e
route_to_model_loop T2 "$PROMPT_FILE" "$REPO" 1 >/dev/null 2>&1
rc=\$?
set -e
exec 3>&-
printf '%s' "\$rc" > "$TEST_TEMP_DIR/rc.txt"
EOF

bash "$DRIVER" >/dev/null 2>&1 || true
rc="$(cat "$TEST_TEMP_DIR/rc.txt" 2>/dev/null || echo missing)"

leak_content="$(cat "$LEAK_LOG" 2>/dev/null || true)"
sentinel_content="$(cat "$SENTINEL" 2>/dev/null || true)"

# rc may be 0 (done_sentinel) or 1 (no_progress fallback) — both are fine;
# we only care that no leak markers appear.
case "$rc" in
    0|1) assert_pass "route_to_model_loop rc is 0 or 1 (got=$rc)" ;;
    *)   assert_fail "route_to_model_loop rc is 0 or 1" "got: $rc" ;;
esac

env_leak=0
fd3_leak=0
grep -qF "ENV_LEAK" <<< "$leak_content" 2>/dev/null && env_leak=1
grep -qF "FD3_LEAK" <<< "$leak_content" 2>/dev/null && fd3_leak=1
assert_eq "no ENV_LEAK marker from background claude spawn" "0" "$env_leak"
assert_eq "no FD3_LEAK marker from background claude spawn" "0" "$fd3_leak"
assert_eq "fd 3 sentinel file is empty (no leaked writes from loop)" "" "$sentinel_content"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
