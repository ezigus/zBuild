#!/usr/bin/env bash
# Unit test (#1685): the truncation banner stays OFF on the clean path.
#
# SPEC-2 (GUARD): when iter N completes normally (rc=0), iter N+1's -p prompt
#   does NOT contain the banner (no spurious noise on the healthy path).
#
# Deliberately its own file: the acceptance-gate's [guard] negative control
# runs a whole testfile at the merge-base and keys on the FILE's exit code, so
# pairing this guard with the [change] SPEC in
# build-timeout-truncation-banner-test.sh reports it guard_regressed even
# though this assertion passes at baseline.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "build-timeout-banner-clean-iter (#1685)"
setup_test_env "build-timeout-banner-clean-iter"
_test_cleanup_hook() { cleanup_test_env; }

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="timeout-banner-clean-$$"
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
