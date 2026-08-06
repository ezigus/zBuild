#!/usr/bin/env bash
# Unit test (#1685): route_to_model_loop injects a truncation banner on the
# iteration immediately following a per-iteration timeout (rc=124).
#
# SPEC-1 (CHANGE): when iter N times out, iter N+1's -p prompt contains the
#   "prior iteration timed out" warning so the model cannot emit false
#   LOOP_COMPLETE.
#
# SPEC-2 lives in build-timeout-banner-clean-iter-test.sh, NOT here. The
# acceptance-gate's [guard] negative control runs a whole testfile at the
# merge-base and keys on the FILE's exit code, so a [guard] SPEC sharing a
# file with a [change] SPEC is always reported guard_regressed — the [change]
# SPEC's baseline failure (which is the negative control working correctly)
# reddens the file. One SPEC per file keeps each negative control isolated.
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
# Call 1: leave a PARTIAL edit in the tree, then exit 124 (timeout), no JSON
#   output. The partial edit is the whole point of #1685 — it makes prev_diff
#   non-empty so iter-2 takes the cumulative-diff prompt branch, which is the
#   shape the real failure had. Without it the test only ever exercises the
#   empty-diff branch.
# Call 2: emit LOOP_COMPLETE.
if [[ "\$n" -eq 1 ]]; then
    printf 'partial edit written before the turn was cut off\n' >> "$REPO/seed.txt"
    exit 124
fi
jq -n --arg r \$'done\nLOOP_COMPLETE' \
    '{type:"result",result:\$r,usage:{input_tokens:5,output_tokens:3}}'
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
# No PATH export here: setup_test_env already prepends $TEST_TEMP_DIR/bin.

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

# The truncated turn left a partial edit, so iter-2 must take the CUMULATIVE-DIFF
# prompt branch — the shape #1685 actually failed on — and carry the banner
# there, not only in the empty-diff branch.
if [[ "$iter2_prompt_a" == *"Cumulative diff so far"* \
   && "$iter2_prompt_a" == *"partial edit written before the turn was cut off"* ]]; then
    assert_pass "[SPEC-1] scenario-A: iter-2 carries the banner on the cumulative-diff branch (partial edit present)"
else
    assert_fail "[SPEC-1] scenario-A: iter-2 carries the banner on the cumulative-diff branch (partial edit present)" \
        "prompt_tail=$(printf '%s' "$iter2_prompt_a" | tail -c 300)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Scenario C: iter-1 times out (rc=124), iter-2 fails with a NON-timeout rc.
# iter-3 must NOT carry the banner — the flag tracks the IMMEDIATELY preceding
# iteration, so a rc=1 predecessor must clear it. Untagged (not a declared SPEC):
# this guards the flag's reset path, which is invisible to SPEC-1 and SPEC-2.
# ─────────────────────────────────────────────────────────────────────────────
PROMPT_DIR_C="$TEST_TEMP_DIR/prompts-c"
COUNTER_C="$TEST_TEMP_DIR/counter-c"
mkdir -p "$PROMPT_DIR_C"
: > "$COUNTER_C"

# Its own throwaway repo: scenario A deliberately leaves an uncommitted partial
# edit behind, and reusing that tree would hand scenario C a non-empty prev_diff
# before any timeout has happened. The current assertions do not read the diff,
# but a shared dirty tree is a trap for whoever extends them next.
REPO_C="$TEST_TEMP_DIR/repo-c"
mkdir -p "$REPO_C"
( cd "$REPO_C" \
    && git init -q \
    && git config user.email t@t \
    && git config user.name t \
    && echo seed > seed.txt \
    && git add seed.txt \
    && git commit -q -m seed ) >/dev/null

cat > "$TEST_TEMP_DIR/bin/claude" <<MOCK
#!/usr/bin/env bash
n=\$(( \$(wc -l < "$COUNTER_C" 2>/dev/null | tr -d ' ') + 1 ))
printf 'x\n' >> "$COUNTER_C"
prompt_text=""
while [[ \$# -gt 0 ]]; do
    case "\$1" in
        -p) prompt_text="\${2:-}"; shift 2 ;;
        *)  shift ;;
    esac
done
printf '%s' "\$prompt_text" > "$PROMPT_DIR_C/call-\${n}.prompt"
# Call 1: timeout. Call 2: non-timeout failure. Call 3: LOOP_COMPLETE.
if [[ "\$n" -eq 1 ]]; then exit 124; fi
if [[ "\$n" -eq 2 ]]; then exit 1; fi
jq -n --arg r \$'done\nLOOP_COMPLETE' \
    '{type:"result",result:\$r,usage:{input_tokens:5,output_tokens:3}}'
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"

# driver-a with $REPO swapped for $REPO_C. (An earlier revision generated this
# by sed-ing $COUNTER_A → $COUNTER_C, which was a no-op: the counter path is
# baked into the mock, not the driver.)
# Match the QUOTED path: $REPO is a string prefix of $REPO_C, so an unquoted
# substitution would also rewrite occurrences of repo-c itself.
sed "s|\"$REPO\"|\"$REPO_C\"|g" "$DRIVER_A" > "$TEST_TEMP_DIR/driver-c.sh"
grep -qF "$REPO_C" "$TEST_TEMP_DIR/driver-c.sh" \
    || assert_fail "scenario-C: driver-c must target its own repo" "sed produced no substitution"
bash "$TEST_TEMP_DIR/driver-c.sh" >/dev/null 2>/dev/null || true

call_count_c="$(wc -l < "$COUNTER_C" | tr -d ' ')"
assert_eq "scenario-C: mock claude invoked three times (124 → 1 → complete)" "3" "$call_count_c"

iter2_prompt_c="$(cat "$PROMPT_DIR_C/call-2.prompt" 2>/dev/null || true)"
if [[ "$iter2_prompt_c" == *"prior iteration timed out"* ]]; then
    assert_pass "scenario-C: iter-2 carries the banner (its predecessor DID time out)"
else
    assert_fail "scenario-C: iter-2 carries the banner (its predecessor DID time out)" \
        "prompt_head=$(printf '%s' "$iter2_prompt_c" | head -c 300)"
fi

iter3_prompt_c="$(cat "$PROMPT_DIR_C/call-3.prompt" 2>/dev/null || true)"
if [[ "$iter3_prompt_c" == *"prior iteration timed out"* ]]; then
    assert_fail "scenario-C: iter-3 must NOT carry the banner (its predecessor failed rc=1, not rc=124)" \
        "prompt_head=$(printf '%s' "$iter3_prompt_c" | head -c 300)"
else
    assert_pass "scenario-C: iter-3 must NOT carry the banner (its predecessor failed rc=1, not rc=124)"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
