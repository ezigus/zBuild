#!/usr/bin/env bash
# Integration test (#566): the build stage's per-iteration [llm] banner MUST
# emit on the banner fd when build runs inside a cycle (ZBUILD_CYCLE_ITER set,
# ZBUILD_CURRENT_STAGE NOT set by caller — orchestrator must export it).
#
# This complements tests/integration/build-loop-banner-test.sh which drives
# route_to_model_loop directly with ZBUILD_CURRENT_STAGE=build pre-set. Here we
# drive the orchestrator → cycle_dispatch_stage → route_to_model_loop path and
# verify the banner survives the cycle dispatch.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "build banner llm prompt visible inside cycle dispatch (#566)"
setup_test_env "build-banner-llm-prompt-visible"

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
mkdir -p "$ZBUILD_STATE_DIR/artifacts/stage-io"
export ZBUILD_RUN_ID="build-banner-cyc-$$"

# C6 override for the loop's per-iter precondition stub.
export HOME="$TEST_TEMP_DIR/home"; mkdir -p "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

# ── Test git repo ────────────────────────────────────────────────────────────
REPO="$TEST_TEMP_DIR/repo"
mkdir -p "$REPO"
( cd "$REPO" \
    && git init -q \
    && git config user.email t@t \
    && git config user.name t \
    && echo seed > seed.txt \
    && git add seed.txt \
    && git commit -q -m seed ) >/dev/null

# ── Mock claude: one iter then DONE ──────────────────────────────────────────
MARK_FILE="$TEST_TEMP_DIR/llm-call.mark"
mkdir -p "$TEST_TEMP_DIR/bin"
cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
mark="${MARK_FILE:-/tmp/mark}"
n=$(wc -l < "$mark" 2>/dev/null | tr -d ' ' || echo 0)
n=$(( n + 1 ))
echo "MARK_iter_${n}" >> "$mark"
printf 'iter-%d\n' "$n" >> "$PWD/work.txt"
jq -n --arg r $'all done\nLOOP_COMPLETE' \
    '{result:$r, usage:{input_tokens:5, output_tokens:3}}'
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
export PATH="$TEST_TEMP_DIR/bin:$PATH"
export MARK_FILE

# ── Template with build stdout destination ───────────────────────────────────
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
      destinations: [file, stdout]
      tail_lines: 5
YAML

# ── Driver: mimic cycle_dispatch_stage path — caller does NOT export
#    ZBUILD_CURRENT_STAGE, only ZBUILD_CYCLE_ITER/ZBUILD_CYCLE_ID.
#    This is exactly what _cycle_iter_dispatch does today (without the fix).
#    After the fix, _cycle_iter_dispatch will add the export, and the banner
#    must appear.
DRIVER="$TEST_TEMP_DIR/driver.sh"
BANNER_FD3="$TEST_TEMP_DIR/banner-fd3.txt"
PROMPT_FILE="$TEST_TEMP_DIR/prompt.txt"
echo "build static prompt — CYCLE_BANNER_SENTINEL" > "$PROMPT_FILE"

cat > "$DRIVER" <<EOF
set -uo pipefail
source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/core/event-bus/event-bus.sh"
source "$REPO_ROOT/core/pipeline/template.sh"
source "$REPO_ROOT/core/output/stage-io.sh"
source "$REPO_ROOT/core/router/route.sh"
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"

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

# Stand in for cycle_dispatch_stage: instead of running plugin_hook_call
# (which would require the whole build plugin), invoke route_to_model_loop
# directly the way the build plugin's run hook would. Crucially, the caller
# (this stub) does NOT export ZBUILD_CURRENT_STAGE — it relies on the
# orchestrator's per-stage export.
cycle_dispatch_stage() {
    local _stage="\$1"
    _CYCLE_DISPATCH_VERDICT=""
    _CYCLE_DISPATCH_STATUS=""
    set +e
    route_to_model_loop T2 "$PROMPT_FILE" "$REPO" 5
    local _rc=\$?
    set -e
    if [[ \$_rc -eq 0 ]]; then
        _CYCLE_DISPATCH_VERDICT="pass"
        _CYCLE_DISPATCH_STATUS="complete"
    else
        _CYCLE_DISPATCH_VERDICT="error"
        _CYCLE_DISPATCH_STATUS="failed"
    fi
    return \$_rc
}

# Drive the orchestrator's per-iter dispatch directly. This is the smallest
# surface that exercises the bug + fix: _cycle_iter_dispatch must export
# ZBUILD_CURRENT_STAGE before invoking cycle_dispatch_stage.
_CYCLE_STAGES=(build)
_CYCLE_TRAP_CYCLE_ID="cyc1"
_cycle_install_traps() { :; }
_cycle_pre_iter_cleanup() { :; }

# Pre-condition: caller does NOT have ZBUILD_CURRENT_STAGE set.
unset ZBUILD_CURRENT_STAGE
unset ZBUILD_PLUGIN

STATE_FILE="\$ZBUILD_STATE_DIR/pipeline-state.json"
jq -n '{schema_version:1, stage_statuses:{}, updated_at:"seed"}' > "\$STATE_FILE"

_cycle_iter_dispatch 1 "\$STATE_FILE"
EOF

ZBUILD_STAGE_IO_FD=3 bash "$DRIVER" >/dev/null 2>/dev/null 3>"$BANNER_FD3" || true

banner="$(cat "$BANNER_FD3" 2>/dev/null || echo '')"

# (1) Per-iter input banner appears with stage=build and kind=llm.
in_count="$(printf '%s\n' "$banner" | grep -cE '══ build \[llm\] seq=.* input ══' || true)"
assert_eq "1 [llm] input banner for build inside cycle dispatch" "1" "$in_count"

# (2) Output banner appears.
out_count="$(printf '%s\n' "$banner" | grep -cE '══ build \[llm\] seq=.* output ' || true)"
assert_eq "1 [llm] output banner for build inside cycle dispatch" "1" "$out_count"

# (3) Mock claude was invoked (cycle dispatch succeeded).
mark_count="$(wc -l < "$MARK_FILE" 2>/dev/null | tr -d ' ' || echo 0)"
assert_eq "mock claude invoked 1 time" "1" "$mark_count"

# (4) Artifact persists the cycle-context input.
art_count="$(ls -1 "$ZBUILD_STATE_DIR/artifacts/stage-io/"build-*.json 2>/dev/null | wc -l | tr -d ' ')"
assert_gt "at least one build stage-io artifact written" "$art_count" "0"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
