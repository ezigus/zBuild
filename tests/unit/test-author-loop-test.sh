#!/usr/bin/env bash
# tests/unit/test-author-loop-test.sh — test-author works until it is done, like
# build (#2225 §3).
#
# Why: test-author made ONE model call for the whole contract, and a 15–25 SPEC
# contract regularly overran it (#1846 twice, #1837 twice on 2026-09-28/29 —
# 15 minutes each plus a retry that started over). build does not have this
# problem: route_to_model_loop keeps calling until the model says it is done,
# each call with its own time limit, the work committed as it goes.
#
# Drives the REAL route_to_model_loop with a fake model on PATH that writes one
# assertion per call.
#
# A1 [change] test-author keeps calling until the model says done — a contract
#             that needs three calls gets three calls, and completes
# A2 [change] each call starts from what the earlier calls wrote (the work stays
#             on disk between calls, as build's does — committing between calls
#             would read as "no progress" to the loop, which measures change
#             against the last commit)
# A3 [change] a contract not finished within the loop's calls ends
#             out_of_turns (from the shared mapping), rc=1, its work committed
# A4 [change] the prompt tells the model to say it is done once every SPEC has
#             its assertion
# A5 [change] the loop never shows the author the implementation (review #2229):
#             neither the uncommitted change nor build's commits reach any call's
#             prompt — only the testfiles' own progress does
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "test-author works until it is done, like build (#2225 §3)"
setup_test_env "test-author-loop"

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export HOME="$TEST_TEMP_DIR/home"; mkdir -p "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

cat > "$TEST_TEMP_DIR/template.yaml" <<'YAML'
id: standard
name: Standard Pipeline
extends: null
defaults:
  strategy: fanout
stages:
  - id: test-author
    gate: auto
    roles: [test_author]
YAML

# The fake model: each call appends one assertion to the testfile and records
# its prompt; it says done on call $FAKE_DONE_AT (never, when 0).
mkdir -p "$TEST_TEMP_DIR/bin"
cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
cat > "$FAKE_DIR/prompt.$(( $(wc -l < "$FAKE_DIR/calls") + 1 ))"
echo x >> "$FAKE_DIR/calls"
n="$(wc -l < "$FAKE_DIR/calls" | tr -d ' ')"
printf 'assert_eq "[SPEC-%s] assertion %s" "1" "$v"\n' "$n" "$n" >> "$FAKE_REPO/tests/acc-test.sh"
grep -c 'assertion' "$FAKE_REPO/tests/acc-test.sh" >> "$FAKE_DIR/commits-seen" || true
if [[ "${FAKE_DONE_AT:-0}" != "0" && "$n" -ge "$FAKE_DONE_AT" ]]; then last=LOOP_COMPLETE; else last="wrote SPEC-$n"; fi
jq -n --arg r "$(printf 'done some\n%s' "$last")" '{type:"result",result:$r,usage:{input_tokens:1,output_tokens:1}}'
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"

# _run <name> <done_at> <max_iterations> — one test-author run in a subshell;
# prints the rc. Leaves the state, repo and fake-model records under $TEST_TEMP_DIR/<name>.
_run() {
    local d="$TEST_TEMP_DIR/$1"
    mkdir -p "$d/state/artifacts/stage-io" "$d/repo/tests" "$d/fake" "$d/events"
    : > "$d/fake/calls"; : > "$d/fake/commits-seen"; : > "$d/events/events.jsonl"
    printf '#!/usr/bin/env bash\n' > "$d/repo/tests/acc-test.sh"
    ( cd "$d/repo" && git init -q -b main . && git config user.email t@e.st && git config user.name t \
        && git add -A && git commit -q -m seed ) >/dev/null 2>&1
    # An implementation the author must not see: a build commit since intake,
    # and an uncommitted change.
    git -C "$d/repo" rev-parse HEAD > "$d/state/intake-baseline-ref.txt"
    mkdir -p "$d/repo/src"; printf 'impl_secret() { echo IMPL-SECRET-COMMITTED; }\n' > "$d/repo/src/impl.sh"
    ( cd "$d/repo" && git add -A && git commit -q -m "build: IMPL-SECRET-SUBJECT" ) >/dev/null 2>&1
    printf 'IMPL-SECRET-UNCOMMITTED\n' > "$d/repo/src/wip.sh"
    cat > "$d/state/artifacts/design.md" <<'EOF'
```acceptance
SPEC-1[change]: first
SPEC-2[change]: second
SPEC-3[change]: third
TESTFILES:
tests/acc-test.sh
```
EOF
    printf '{}' > "$d/state/pipeline-state.json"
    (
        export PATH="$TEST_TEMP_DIR/bin:$PATH" FAKE_DIR="$d/fake" FAKE_REPO="$d/repo" FAKE_DONE_AT="$2"
        export ZBUILD_STATE_DIR="$d/state" ZBUILD_ARTIFACT_DIR="$d/state/artifacts" ZBUILD_REPO_ROOT="$d/repo"
        export ZBUILD_EVENTS_DIR="$d/events" ZBUILD_EVENTS_JSONL="$d/events/events.jsonl"
        export ZBUILD_RUN_ID="ta-loop-$$" ZBUILD_CURRENT_STAGE=test-author ZBUILD_ROUTER_MAX_ITERATIONS="$3"
        unset ZBUILD_ISSUE
        source "$REPO_ROOT/core/event-bus/event-bus.sh"
        source "$REPO_ROOT/core/pipeline/template.sh"
        source "$REPO_ROOT/core/output/stage-io.sh"
        load_template "$TEST_TEMP_DIR/template.yaml" >/dev/null 2>&1
        source "$REPO_ROOT/plugins/agent/test-author/plugin.sh"
        cd "$d/repo" && test_author_run test-author "$d/state/pipeline-state.json"
    ) >/dev/null 2>&1
    printf '%s' "$?"
}
_calls() { wc -l < "$TEST_TEMP_DIR/$1/fake/calls" | tr -d ' '; }
_res() { jq -r "$2 // empty" "$TEST_TEMP_DIR/$1/state/artifacts/test-author-result.json" 2>/dev/null || true; }

print_test_section "A1/A2/A4: a contract that needs three calls"
_rc1="$(_run a1 3 6)"
assert_eq "[A1] three calls were made" "3" "$(_calls a1)"
assert_eq "[A1] ...and the stage completed" "complete" "$(_res a1 .disposition)"
assert_eq "[A1] rc=0" "0" "$_rc1"
_seen="$(tr '\n' ' ' < "$TEST_TEMP_DIR/a1/fake/commits-seen")"
assert_eq "[A2] the work accumulates across calls — after each call the file holds every assertion so far (counts: $_seen)" \
    "1 2 3 " "$_seen"
assert_contains "[A4] the prompt says how to finish" "$(cat "$TEST_TEMP_DIR/a1/fake/prompt.1" 2>/dev/null)" "LOOP_COMPLETE"

print_test_section "A5: the author stays blind to the implementation"
_all="$(cat "$TEST_TEMP_DIR"/a1/fake/prompt.* 2>/dev/null)"
if grep -qE 'IMPL-SECRET' <<< "$_all"; then
    assert_fail "[A5] no prompt shows the implementation" "$(grep -oE 'IMPL-SECRET[A-Z-]*' <<< "$_all" | sort -u | tr '\n' ' ')"
else
    assert_pass "[A5] no prompt shows the implementation"
fi
assert_contains "[A5] ...while a later call still sees the testfile's own progress" \
    "$(cat "$TEST_TEMP_DIR/a1/fake/prompt.2" 2>/dev/null)" "assertion 1"

print_test_section "A3: not finished within the loop"
_rc3="$(_run a3 0 2)"
assert_eq "[A3] the loop's calls were all made" "2" "$(_calls a3)"
assert_eq "[A3] rc=1" "1" "$_rc3"
assert_eq "[A3] disposition out_of_turns (the shared mapping)" "out_of_turns" "$(_res a3 .disposition)"
assert_eq "[A3] the work is committed" "" "$(git -C "$TEST_TEMP_DIR/a3/repo" status --porcelain -- tests/acc-test.sh 2>/dev/null)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
