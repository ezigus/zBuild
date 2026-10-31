#!/usr/bin/env bash
# tests/unit/router-prompt-contract-test.sh — the router sends a stage's prompt
# as the stage composed it (ADR-067 §8, amended).
#
# The router used to edit every stage prompt in place: a read-only line on top,
# the vision on line 1, then a notes-file block, repository rules, input paths,
# stage summaries and the shared rules appended — and one rule inserted under
# the stage's own "What you must not do". Now the engine's blocks reach a stage
# at dispatch and the stage composes its prompt with stage_prompt_compose; the
# router only redacts it, and refuses a stage prompt that breaks the contract.
#
#   RC1 [change]: a stage prompt in the contract order goes out with nothing
#                 added — no vision preamble, no appended blocks, no inserted rule
#   RC2 [change]: a stage prompt that is not in the contract order is refused,
#                 and the refusal is an event
#   RC3 [guard] : a model call made outside any stage (no dispatched plugin)
#                 is not held to the stage contract
#   RC4 [change]: a refused stage prompt is reported as what it is — not in the
#                 contract order — and not also as a missing scope manifest
#   RC5 [change]: a stage's model loop refuses such a prompt too: the model is
#                 never called with it
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "router — a stage prompt goes out as the stage composed it"
setup_test_env "router-prompt-contract"

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$TEST_TEMP_DIR/events"
unset ZBUILD_SCOPE_MANIFEST ZBUILD_STAGE_INPUTS ZBUILD_STAGE_BLOCKS 2>/dev/null || true

# A target repository WITH a vision document and rules: if the router still
# added either, RC1 would see it.
TGT="$TEST_TEMP_DIR/target"
mkdir -p "$TGT/.zbuild/prompts"
printf '## Intent\nROUTER-MUST-NOT-ADD-THIS-INTENT\n' > "$TGT/.zbuild/vision.md"
printf 'ROUTER-MUST-NOT-ADD-THIS-RULE\n' > "$TGT/.zbuild/prompts/rules.md"
export ZBUILD_REPO_ROOT="$TGT"

# A dispatched agent stage that declares a notes file and repository rules —
# everything that used to make the router append.
PD="$TEST_TEMP_DIR/plugins/agent/rc-agent"
mkdir -p "$PD"
cat > "$PD/manifest.yaml" <<'EOF'
id: rc-agent
name: rc-agent
kind: agent
version: 0.0.1
prompt:
  repo_rules: true
hooks:
  run: x_run
outputs:
  - id: rc_agent_result
    path: ${artifact_dir}/rc-agent-result.json
    type: json
    required: true
    primary: true
  - id: rc_agent_checkpoint
    path: ${artifact_dir}/rc-agent-checkpoint.md
    type: text
    required: false
    role: checkpoint
EOF
STATE="$TEST_TEMP_DIR/state"
mkdir -p "$STATE/artifacts"
printf '{"schema_version":1,"stage_statuses":{"rc-agent":"complete"},"stage_verdicts":{"rc-agent":"fail"}}\n' \
    > "$STATE/pipeline-state.json"

# shellcheck source=../../core/router/route.sh
source "$REPO_ROOT/core/router/route.sh"

IN="$TEST_TEMP_DIR/in.md"
OUT="$TEST_TEMP_DIR/out.md"
cat > "$IN" <<'EOF'
## From the repo

repo
## What you own

own
## What you judge against

judge
## Previous work

prev
## What you must not do

limits
## Rules for this stage

rules
EOF

# The old router edited its INPUT file in place, so compare against a copy.
cp "$IN" "$IN.orig"
rc=0
ZBUILD_PLUGIN_DIR="$PD" ZBUILD_STATE_DIR="$STATE" ZBUILD_CURRENT_STAGE=rc-agent \
    _route_redact_prompt "$IN" "$OUT" >/dev/null 2>&1 || rc=$?
assert_eq "[RC1] a contract prompt is accepted" "0" "$rc"
assert_eq "[RC1] … and goes out exactly as composed" "$(cat "$IN.orig")" "$(cat "$OUT" 2>/dev/null)"
assert_eq "[RC1] … and the stage's file is not edited" "$(cat "$IN.orig")" "$(cat "$IN")"

printf 'just a task, no sections\n' > "$IN.bad"
: > "$ZBUILD_EVENTS_JSONL"
rc=0
ZBUILD_PLUGIN_DIR="$PD" ZBUILD_STATE_DIR="$STATE" ZBUILD_CURRENT_STAGE=rc-agent \
    _route_redact_prompt "$IN.bad" "$OUT.bad" >/dev/null 2>&1 || rc=$?
assert_eq "[RC2] a stage prompt out of the contract is refused" "1" "$rc"
assert_contains "[RC2] the refusal is evented" \
    "$(cat "$ZBUILD_EVENTS_JSONL" 2>/dev/null)" "router.prompt.refused"

printf 'just a task, no sections\n' > "$IN.free"
rc=0
( unset ZBUILD_PLUGIN_DIR; _route_redact_prompt "$IN.free" "$OUT.free" >/dev/null 2>&1 ) || rc=$?
assert_eq "[RC3] a call outside any stage is not held to the contract" "0" "$rc"
assert_contains "[RC3] … and its text is sent" "$(cat "$OUT.free" 2>/dev/null)" "just a task, no sections"

# RC5: the loop does not send it either.
mkdir -p "$TEST_TEMP_DIR/bin"
printf '#!/usr/bin/env bash\necho called >> "%s"\nprintf %%s %s\n' "$TEST_TEMP_DIR/claude-calls" \
    "'{\"result\":\"LOOP_COMPLETE\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}'" > "$TEST_TEMP_DIR/bin/claude"
chmod +x "$TEST_TEMP_DIR/bin/claude"
printf 'just a task, no sections\n' > "$TEST_TEMP_DIR/loop-bad.txt"
rc=0
( export PATH="$TEST_TEMP_DIR/bin:$PATH" ZBUILD_PLUGIN_DIR="$PD" ZBUILD_STATE_DIR="$STATE" ZBUILD_CURRENT_STAGE=rc-agent
  route_to_model_loop T2 "$TEST_TEMP_DIR/loop-bad.txt" "$TEST_TEMP_DIR" >/dev/null 2>&1 ) || rc=$?
assert_eq "[RC5] the loop refuses an out-of-order stage prompt" "1" "$([[ "$rc" -ne 0 ]] && echo 1 || echo 0)"
assert_eq "[RC5] …and the model is never called" "0" \
    "$(wc -l < "$TEST_TEMP_DIR/claude-calls" 2>/dev/null | tr -d ' ' || echo 0)"

# RC4: through route_to_model, the operator is told the real reason only.
export ZBUILD_RUN_ID="rc4-run"
: > "$ZBUILD_EVENTS_JSONL"
rc=0
_rc4_err="$( ZBUILD_PLUGIN_DIR="$PD" ZBUILD_STATE_DIR="$STATE" ZBUILD_CURRENT_STAGE=rc-agent \
    route_to_model T2 "just a task, no sections" 2>&1 >/dev/null )" || rc=$?
assert_eq "[RC4] the call is refused" "1" "$([[ "$rc" -ne 0 ]] && echo 1 || echo 0)"
assert_contains "[RC4] the operator is told it is not in the contract order" "$_rc4_err" "not in the contract order"
if grep -qF "scope manifest" <<< "$_rc4_err"; then
    assert_fail "[RC4] …and not that a scope manifest is missing" "$(grep -F 'scope manifest' <<< "$_rc4_err")"
else
    assert_pass "[RC4] …and not that a scope manifest is missing"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
