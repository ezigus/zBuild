#!/usr/bin/env bash
# tests/unit/router-loop-done-variants-test.sh — the loop hears "done" however
# the model punctuates it.
#
# Why: #1847 run 20260928102849-23575. design ended 8 of 14 answers with
# "LOOP_COMPLETE." — a full stop — and the router only accepted a line that was
# exactly `LOOP_COMPLETE`. Each miss cost another full model call: design's
# second iteration ran 10 calls (~41 min) where 1–2 were needed.
#
# A line counts when, with whitespace and punctuation removed and case ignored,
# it is exactly the sentinel's two words. A sentence that merely MENTIONS it
# still does not count.
#
# L1 [change] `LOOP_COMPLETE.` ends the loop on the call that said it
# L2 [change] markdown-wrapped (`**LOOP_COMPLETE**`, `` `LOOP_COMPLETE` ``) ends it
# L3 [change] the two words spaced or lower-cased (`Loop complete!`, `LOOP COMPLETE`) end it
# L4 [guard]  the bare sentinel still ends it
# L5 [guard]  a sentence that mentions the sentinel does not — the loop runs to its cap
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "router loop: the done sentinel, however it is punctuated"
setup_test_env "router-loop-done-variants"

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

REPO="$TEST_TEMP_DIR/repo"; mkdir -p "$REPO"
( cd "$REPO" && git init -q && git config user.email t@t && git config user.name t \
    && echo seed > seed.txt && git add seed.txt && git commit -q -m seed ) >/dev/null
PROMPT_FILE="$TEST_TEMP_DIR/prompt.txt"; printf 'Do the work.\n' > "$PROMPT_FILE"

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
YAML

# Every call answers with $LAST_LINE as its final line and edits a file, so a
# missed sentinel shows up as another call.
mkdir -p "$TEST_TEMP_DIR/bin"
cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
cat >/dev/null
echo "x" >> "$COUNTER"
printf 'edit\n' >> "$PWD/work.txt"
jq -n --arg r "$(printf 'did the work\n%s' "$LAST_LINE")" \
    '{type:"result",result:$r,usage:{input_tokens:5,output_tokens:3}}'
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"

# _calls <last line> — how many model calls a 4-iteration loop made.
_calls() {
    local d="$TEST_TEMP_DIR/run-$RANDOM"; mkdir -p "$d/events" "$d/state/artifacts/stage-io"
    : > "$d/counter"; : > "$d/events/events.jsonl"
    (
        export PATH="$TEST_TEMP_DIR/bin:$PATH" COUNTER="$d/counter" LAST_LINE="$1"
        export ZBUILD_EVENTS_DIR="$d/events" ZBUILD_EVENTS_JSONL="$d/events/events.jsonl"
        export ZBUILD_STATE_DIR="$d/state" ZBUILD_RUN_ID="done-variants-$$" ZBUILD_CURRENT_STAGE=build
        source "$REPO_ROOT/core/event-bus/event-bus.sh"
        source "$REPO_ROOT/core/pipeline/template.sh"
        source "$REPO_ROOT/core/output/stage-io.sh"
        source "$REPO_ROOT/core/router/route.sh"
        load_template "$TEST_TEMP_DIR/template.yaml" >/dev/null 2>&1
        route_to_model_loop T2 "$PROMPT_FILE" "$REPO" 4
    ) >/dev/null 2>&1 || true
    wc -l < "$d/counter" | tr -d ' '
}

print_test_section "L1–L4: variants that end the loop"
assert_eq "[L1] 'LOOP_COMPLETE.' ends it at once" "1" "$(_calls 'LOOP_COMPLETE.')"
assert_eq "[L2] '**LOOP_COMPLETE**' ends it at once" "1" "$(_calls '**LOOP_COMPLETE**')"
assert_eq "[L2] backticked LOOP_COMPLETE ends it at once" "1" "$(_calls '`LOOP_COMPLETE`')"
assert_eq "[L3] 'Loop complete!' ends it at once" "1" "$(_calls 'Loop complete!')"
assert_eq "[L3] 'LOOP COMPLETE' ends it at once" "1" "$(_calls 'LOOP COMPLETE')"
assert_eq "[L4] the bare sentinel ends it at once" "1" "$(_calls 'LOOP_COMPLETE')"

print_test_section "L5: a mention is not a signal"
assert_eq "[L5] a sentence mentioning it runs to the cap" "4" \
    "$(_calls 'Next I will verify before emitting LOOP_COMPLETE')"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
