#!/usr/bin/env bash
# Unit test (#1685): route_to_model_loop injects a truncation banner on the
# iteration immediately following a per-iteration timeout (rc=124).
#
# SPEC-1 (CHANGE): when iter N times out, iter N+1's -p prompt contains the
#   "prior iteration timed out" warning so the model cannot emit false
#   LOOP_COMPLETE.
# SPEC-2 (CHANGE): when iter N completes normally (rc=0), iter N+1's -p prompt
#   does NOT contain the banner (no spurious noise on the clean path).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "build-timeout-truncation-banner (#1685)"
setup_test_env "build-timeout-truncation-banner"
_test_cleanup_hook() { cleanup_test_env; }

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="timeout-banner-$$"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR/artifacts/stage-io"

export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

# ── Throwaway git repo. ───────────────────────────────────────────────────────
REPO="$TEST_TEMP_DIR/repo"
mkdir -p "$REPO"
( cd "$REPO" \
    && git init -q \
    && git config user.email t@t \
    && git config user.name t \
    && echo seed > seed.txt \
    && git add seed.txt \
    && git commit -q -m seed ) >/dev/null

# ── Minimal prompt file. ─────────────────────────────────────────────────────
PROMPT_FILE="$TEST_TEMP_DIR/prompt.txt"
printf '%s\n' "BUILD PROMPT ZB1685_SENTINEL" > "$PROMPT_FILE"

# ── Template with build stage. ───────────────────────────────────────────────
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
      destinations: [stdout]
      tail_lines: 5
YAML

# ── Shared mock bin dir. ─────────────────────────────────────────────────────
mkdir -p "$TEST_TEMP_DIR/bin"

# ─────────────────────────────────────────────────────────────────────────────
# Scenario A: iter-1 times out (rc=124). iter-2 must carry the banner.
# ─────────────────────────────────────────────────────────────────────────────
PROMPT_DIR_A="$TEST_TEMP_DIR/prompts-a"
COUNTER_A="$TEST_TEMP_DIR/counter-a"
mkdir -p "$PROMPT_DIR_A"
: > "$COUNTER_A"

cat > "$TEST_TEMP_DIR/bin/claude" <<MOCK
#!/usr/bin/env bash
n=\$(( \$(wc -l < "$COUNTER_A" 2>/dev/null | tr -d ' ') + 1 ))
printf 'x\n' >> "$COUNTER_A"
prompt_text=""
while [[ \$# -gt 0 ]]; do
    case "\$1" in
        -p) prompt_text="\${2:-}"; shift 2 ;;
        *)  shift ;;
    esac
done
printf '%s' "\$prompt_text" > "$PROMPT_DIR_A/call-\${n}.prompt"
# Call 1: exit 124 (timeout), no JSON output.
# Call 2: emit LOOP_COMPLETE.
if [[ "\$n" -eq 1 ]]; then
    exit 124
fi
jq -n --arg r \$'done\nLOOP_COMPLETE' \
    '{type:"result",result:\$r,usage:{input_tokens:5,output_tokens:3}}'
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
export PATH="$TEST_TEMP_DIR/bin:$PATH"

DRIVER_A="$TEST_TEMP_DIR/driver-a.sh"
cat > "$DRIVER_A" <<EOF
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

load_template "$TEST_TEMP_DIR/template.yaml"
export ZBUILD_CURRENT_STAGE=build
route_to_model_loop T2 "$PROMPT_FILE" "$REPO" 5
EOF

bash "$DRIVER_A" >/dev/null 2>/dev/null || true

call_count_a="$(wc -l < "$COUNTER_A" | tr -d ' ')"
assert_eq "scenario-A: mock claude invoked twice (iter-1 timeout + iter-2 complete)" "2" "$call_count_a"

iter2_prompt_a="$(cat "$PROMPT_DIR_A/call-2.prompt" 2>/dev/null || true)"

if [[ "$iter2_prompt_a" == *"prior iteration timed out"* ]]; then
    assert_pass "[SPEC-1] scenario-A: iter-2 prompt contains truncation banner after iter-1 rc=124"
else
    assert_fail "[SPEC-1] scenario-A: iter-2 prompt contains truncation banner after iter-1 rc=124" \
        "prompt_head=$(printf '%s' "$iter2_prompt_a" | head -c 300)"
fi

# iter-1 must NOT have the banner (it is the first iteration)
iter1_prompt_a="$(cat "$PROMPT_DIR_A/call-1.prompt" 2>/dev/null || true)"
if [[ "$iter1_prompt_a" == *"prior iteration timed out"* ]]; then
    assert_fail "[SPEC-1] scenario-A: iter-1 prompt must NOT contain banner (it is the first)" \
        "prompt_head=$(printf '%s' "$iter1_prompt_a" | head -c 300)"
else
    assert_pass "[SPEC-1] scenario-A: iter-1 prompt correctly has no banner"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Scenario B: iter-1 completes normally (rc=0). iter-2 must NOT carry the banner.
# ─────────────────────────────────────────────────────────────────────────────
PROMPT_DIR_B="$TEST_TEMP_DIR/prompts-b"
COUNTER_B="$TEST_TEMP_DIR/counter-b"
mkdir -p "$PROMPT_DIR_B"
: > "$COUNTER_B"

cat > "$TEST_TEMP_DIR/bin/claude" <<MOCK
#!/usr/bin/env bash
n=\$(( \$(wc -l < "$COUNTER_B" 2>/dev/null | tr -d ' ') + 1 ))
printf 'x\n' >> "$COUNTER_B"
prompt_text=""
while [[ \$# -gt 0 ]]; do
    case "\$1" in
        -p) prompt_text="\${2:-}"; shift 2 ;;
        *)  shift ;;
    esac
done
printf '%s' "\$prompt_text" > "$PROMPT_DIR_B/call-\${n}.prompt"
# Call 1: normal result (no LOOP_COMPLETE).
# Call 2: emit LOOP_COMPLETE.
if [[ "\$n" -eq 1 ]]; then
    jq -n --arg r "iter 1 progress" \
        '{type:"result",result:\$r,usage:{input_tokens:5,output_tokens:3}}'
else
    jq -n --arg r \$'done\nLOOP_COMPLETE' \
        '{type:"result",result:\$r,usage:{input_tokens:5,output_tokens:3}}'
fi
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"

DRIVER_B="$TEST_TEMP_DIR/driver-b.sh"
cat > "$DRIVER_B" <<EOF
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

load_template "$TEST_TEMP_DIR/template.yaml"
export ZBUILD_CURRENT_STAGE=build
route_to_model_loop T2 "$PROMPT_FILE" "$REPO" 5
EOF

bash "$DRIVER_B" >/dev/null 2>/dev/null || true

call_count_b="$(wc -l < "$COUNTER_B" | tr -d ' ')"
assert_eq "scenario-B: mock claude invoked twice (iter-1 normal + iter-2 complete)" "2" "$call_count_b"

iter2_prompt_b="$(cat "$PROMPT_DIR_B/call-2.prompt" 2>/dev/null || true)"

if [[ "$iter2_prompt_b" == *"prior iteration timed out"* ]]; then
    assert_fail "[SPEC-2] scenario-B: iter-2 prompt must NOT contain banner after iter-1 rc=0" \
        "prompt_head=$(printf '%s' "$iter2_prompt_b" | head -c 300)"
else
    assert_pass "[SPEC-2] scenario-B: iter-2 prompt correctly has no banner after iter-1 rc=0"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
