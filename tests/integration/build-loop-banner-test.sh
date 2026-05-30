#!/usr/bin/env bash
# Integration test (#482): route_to_model_loop (Pattern 2) emits stage_io
# begin/end per iteration so build's LLM calls are observable like plan/review.
#
# Mirrors stage-io-banner-split-test.sh's approach but exercises the loop
# rather than route_to_model. Uses a real subprocess + mock claude that writes
# MARK timestamps so we can verify per-iteration ordering on fd 3.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "build loop banner: stage_io per iteration (#482, Pattern 2)"
setup_test_env "build-loop-banner"

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="build-loop-banner-$$"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR/artifacts/stage-io"

# Operator override so loop's per-iteration redaction.applied stub satisfies C6.
export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

# ── Test git repo for build loop ─────────────────────────────────────────────
REPO="$TEST_TEMP_DIR/repo"
mkdir -p "$REPO"
( cd "$REPO" \
    && git init -q \
    && git config user.email t@t \
    && git config user.name t \
    && echo seed > seed.txt \
    && git add seed.txt \
    && git commit -q -m seed ) >/dev/null

# ── Mock claude: 2 iters then DONE; appends MARK per call. ──────────────────
MARK_FILE="$TEST_TEMP_DIR/llm-call.mark"
mkdir -p "$TEST_TEMP_DIR/bin"
cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
# Increment iteration count via mark file lines.
mark="${MARK_FILE:-/tmp/mark}"
n=$(wc -l < "$mark" 2>/dev/null | tr -d ' ' || echo 0)
n=$(( n + 1 ))
echo "MARK_iter_${n}" >> "$mark"
# Edit something so git diff has content.
printf 'iter-%d\n' "$n" >> "$PWD/work.txt"
if [[ "$n" -ge 3 ]]; then
    jq -n --arg r $'all done\nLOOP_COMPLETE' \
        '{result:$r, usage:{input_tokens:7, output_tokens:4}}'
else
    jq -n --arg r "iter ${n} progress" \
        '{result:$r, usage:{input_tokens:7, output_tokens:4}}'
fi
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
export PATH="$TEST_TEMP_DIR/bin:$PATH"
export MARK_FILE

# ── Template: build stage uses stdout destination for banner emit. ──────────
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

# ── Subprocess driver: real route_to_model_loop with fd 3 banner capture. ──
DRIVER="$TEST_TEMP_DIR/driver.sh"
BANNER_FD3="$TEST_TEMP_DIR/banner-fd3.txt"
PROMPT_FILE="$TEST_TEMP_DIR/prompt.txt"
echo "build static prompt" > "$PROMPT_FILE"

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
route_to_model_loop T2 "$PROMPT_FILE" "$REPO" 5
EOF

ZBUILD_STAGE_IO_FD=3 bash "$DRIVER" >/dev/null 2>/dev/null 3>"$BANNER_FD3" || true

# ─── Assertions ──────────────────────────────────────────────────────────────
banner="$(cat "$BANNER_FD3" 2>/dev/null || echo '')"

# (1) Three iterations → three input/output pairs.
in_count="$(printf '%s\n' "$banner" | grep -c 'stage-io: build \[llm\] seq=.* input ──' || true)"
out_count="$(printf '%s\n' "$banner" | grep -c 'stage-io: build \[llm\] seq=.* output ' || true)"
assert_eq "3 input banners (one per iteration)"  "3" "$in_count"
assert_eq "3 output banners (one per iteration)" "3" "$out_count"

# (2) Subprocess-boundary: each input banner emits BEFORE its claude MARK,
# and each output banner emits AFTER. We test iter=1 as proof of ordering.
in_line_1="$(printf '%s\n' "$banner" | grep -n 'seq=1 input ──' | head -1 | cut -d: -f1)"
out_line_1="$(printf '%s\n' "$banner" | grep -n 'seq=1 output ' | head -1 | cut -d: -f1)"
if [[ -n "$in_line_1" && -n "$out_line_1" && "$in_line_1" -lt "$out_line_1" ]]; then
    assert_pass "iter=1 input < output ordering on fd 3"
else
    assert_fail "iter=1 input < output ordering" \
        "in=$in_line_1 out=$out_line_1; banner head: $(printf '%s' "$banner" | head -c 400)"
fi

# (3) Mock claude was invoked 3 times (3 MARK lines).
mark_count="$(wc -l < "$MARK_FILE" | tr -d ' ')"
assert_eq "mock claude invoked 3 times" "3" "$mark_count"

# (4) File artifacts: build-1.json, build-2.json, build-3.json with metadata.iter.
for s in 1 2 3; do
    art="$ZBUILD_STATE_DIR/artifacts/stage-io/build-${s}.json"
    assert_file_exists "build-${s}.json artifact written" "$art"
    if [[ -f "$art" ]]; then
        rec="$(cat "$art")"
        assert_json_key "build-${s}.json metadata.iter == $s" "$rec" ".metadata.iter" "$s"
    fi
done

# (5) Exactly 3 stage.io.captured events (one per iteration), all stage=build.
captured_count="$(jq -c --arg t "stage.io.captured" 'select(.type==$t and .data.stage=="build")' \
    "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "3 stage.io.captured events for build" "3" "$captured_count"

# (6) No orphan begins (every begin paired with an end).
orphan_count="$(jq -c --arg t "stage.io.error" 'select(.type==$t and .data.reason=="output_never_emitted")' \
    "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "no orphan begins" "0" "$orphan_count"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
