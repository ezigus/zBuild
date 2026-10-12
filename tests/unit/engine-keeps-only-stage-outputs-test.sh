#!/usr/bin/env bash
# tests/unit/engine-keeps-only-stage-outputs-test.sh — the engine keeps nothing
# but each stage's output (ADR-068 §6–§8, amended 2026-10-11).
#
# Why: the engine kept its own record of which stage answered which finding,
# across rounds, and judged it (`unowned: yield|halt`). Finding numbers restart
# each time a check runs, so in #1668's run an answer from one round was counted
# against a different finding in the next, and the stop report printed a finding
# with no words. Eric (2026-10-11): the engine stores only what a stage outputs,
# passes it to later stages, and moves forward by the template's rules and what
# the stages say. A stage's reply to a finding is part of that stage's output.
#
# K1 [code] a template that declares `unowned:` on a loop is refused, and the
#           error says what replaces it
# K2 [code] a prompt that carries findings gets no request to fill in answer
#           lines (the router adds the summaries and nothing about answering)
# K3 [code] a reply with answer lines leaves no record in the state directory
# K4 [code] what is still open is read from the checks' latest results, never
#           from a record kept beside them (#1668: the stop report listed a
#           finding from an earlier round)
# K5 [code] every stage is told to say in its own result what it did about each
#           finding, not to fill in lines for the engine
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "the engine keeps only stage outputs (ADR-068 §6–§8)"
setup_test_env "engine-keeps-only-stage-outputs"
_test_cleanup_hook() { cleanup_test_env; }

print_test_section "K1: unowned: is refused"
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
T="$TEST_TEMP_DIR/uo.yaml"
cat > "$T" <<'EOF'
id: uo
name: unowned
defaults:
  strategy: fanout
flow:
  - outer
outer:
  type: cycle
  flow:
    - inner
  exit_when:
    stage: inner
    field: verdict
    op: eq
    value: pass
  max_iterations: 2
inner:
  type: cycle
  flow:
    - build
  exit_when:
    stage: build
    field: verdict
    op: eq
    value: pass
  max_iterations: 2
  unowned: yield
build:
  roles: [builder]
EOF
grep -v '^  unowned:' "$T" > "$TEST_TEMP_DIR/plain.yaml"
_TPL_STAGES=(); _TPL_CYCLES=()
_out0="$(load_template "$TEST_TEMP_DIR/plain.yaml" 2>&1)"
assert_eq "[K1] the same template without unowned: loads (fixture live)" "0" "$?"
_TPL_STAGES=(); _TPL_CYCLES=()
_out="$(load_template "$T" 2>&1)"; _rc=$?
if [[ $_rc -ne 0 ]]; then
    assert_pass "[K1] a template with unowned: does not load (rc=$_rc)"
else
    assert_fail "[K1] a template with unowned: does not load" "rc=0"
fi
assert_contains "[K1] the error says what replaces it" "$_out" "its rounds run out"

print_test_section "K2: no request to fill in answer lines"
export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STAGE_SCRATCH="$TEST_TEMP_DIR/scratch"
export ZBUILD_REPO_ROOT="$REPO_ROOT"
mkdir -p "$TEST_TEMP_DIR/events" "$TEST_TEMP_DIR/scratch"
export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
echo -n "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1
# shellcheck source=../../core/router/route.sh
source "$REPO_ROOT/core/router/route.sh" >/dev/null 2>&1 || true

# The engine's Previous work for a stage that follows a failing check — built
# with the engine's own writers (#1799) — and the prompt composed from it.
# shellcheck source=../../scripts/lib/stage-prompt.sh
source "$REPO_ROOT/scripts/lib/stage-prompt.sh" >/dev/null 2>&1 || true
# shellcheck source=../../core/pipeline/input-resolve.sh
source "$REPO_ROOT/core/pipeline/input-resolve.sh" >/dev/null 2>&1 || true
S2="$TEST_TEMP_DIR/state2"; P2="$TEST_TEMP_DIR/plugins2"; mkdir -p "$S2/artifacts" "$P2/tool/test"
printf 'id: test\nkind: tool\noutputs:\n  - id: test_result\n    path: ${artifact_dir}/test-result.json\n    format: json\n    required: true\n    primary: true\n' \
    > "$P2/tool/test/manifest.yaml"
printf '{"result_contract":2,"verdict":"fail","disposition":"complete","data":{"findings":[{"n":1,"text":"run-tests-test.sh fails on line 40"}]}}\n' \
    > "$S2/artifacts/test-result.json"
printf '{"schema_version":1,"stage_statuses":{"test":"failed"},"stage_verdicts":{"test":"fail"}}\n' > "$S2/pipeline-state.json"
B2="$TEST_TEMP_DIR/blocks2"; mkdir -p "$B2"
(
    _TPL_STAGES=(test build)
    _stage_block_from_repo build "$REPO_ROOT" > "$B2/from-repo.md"
    _stage_block_previous_work build "$S2" "$P2" "$(_inputs_resolve_stage build "$P2" "$S2")" "$S2" > "$B2/previous-work.md"
    _stage_block_rules build "$S2" "$REPO_ROOT/plugins/agent/build/manifest.yaml" > "$B2/rules.md"
) >/dev/null 2>&1
_p2="$(ZBUILD_STAGE_BLOCKS="$B2" stage_prompt_compose_parts "$(printf '## What you own\nDo your task.\n## What you judge against\nThe plan.\n## What you must not do\nNothing else.\n')" 2>/dev/null)"
assert_contains "[K2] the prompt carries the findings (fixture live)" "$_p2" "- test finding 1 (opened by test)"
for _w in "ANSWER EVERY FINDING" "ANSWER test finding 1:" "Fill in one line for each" "satisfied —"; do
    if grep -qF -- "$_w" <<< "$_p2"; then
        assert_fail "[K2] the prompt does not ask for answer lines ('$_w')" "found in the prompt"
    else
        assert_pass "[K2] the prompt does not ask for answer lines ('$_w')"
    fi
done

print_test_section "K3: a reply's answer lines leave no record"
cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
printf 'I fixed the test.\nANSWER test finding 1: done — changed run-tests.sh\nANSWER test finding 2: nothing to do — not mine\n'
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
S3="$TEST_TEMP_DIR/state3"; mkdir -p "$S3"
( export ZBUILD_CURRENT_STAGE=build ZBUILD_STATE_DIR="$S3"
  unset ZBUILD_ROUTER_JSON_OUTPUT ZBUILD_PLUGIN_DIR
  route_to_model "T2" "ping" --skip-precondition ) >"$TEST_TEMP_DIR/r3.out" 2>&1
assert_contains "[K3] the reply came back (fixture live)" "$(cat "$TEST_TEMP_DIR/r3.out")" "I fixed the test."
_left="$(cd "$S3" && find . -path '*answer*' 2>/dev/null)"
assert_eq "[K3] nothing about answers is kept in the state directory" "" "$_left"

print_test_section "K4: open items come from the checks' latest results"
# shellcheck source=../../scripts/lib/run-open-items.sh
source "$REPO_ROOT/scripts/lib/run-open-items.sh"
S4="$TEST_TEMP_DIR/state4"; mkdir -p "$S4/artifacts"
# A record kept beside the results, from an earlier round (#1668's shape).
jq -n -c '[{ref:"issue-acceptance finding 5", opener:"issue-acceptance", text:"", answers:[]}]' \
    > "$S4/artifacts/open-items.json"
# The findings are made by the writer every check uses (stage_findings_json).
# shellcheck source=../../scripts/lib/stage-summary.sh
source "$REPO_ROOT/scripts/lib/stage-summary.sh"
_f4="$(printf 'R-1: the PR body does not state the red step\n' | stage_findings_json)"
jq -n -c --argjson f "$_f4" '{result_contract:2, verdict:"fail", disposition:"complete",
           reason:"one requirement unmet", data:{findings:$f}}' \
    > "$S4/artifacts/issue-acceptance-result.json"
_items="$(open_items_json "$S4")"
assert_eq "[K4] one item is open" "1" "$(jq 'length' <<< "$_items" 2>/dev/null)"
assert_eq "[K4] it is the check's latest finding" "R-1: the PR body does not state the red step" \
    "$(jq -r '.[0].text // empty' <<< "$_items" 2>/dev/null)"
assert_eq "[K4] ...named by the check and its number" "issue-acceptance finding 1" \
    "$(jq -r '.[0].ref // empty' <<< "$_items" 2>/dev/null)"

print_test_section "K5: stages report on findings in their own result"
_c="$(_stage_block_rules any-stage "$TEST_TEMP_DIR/s5" "$TEST_TEMP_DIR/none.yaml")"
assert_contains "[K5] every stage is told to say what it did about each finding, in its result" \
    "$_c" "In your result, say what you did about each finding"
if grep -qF "Answer every finding you are given" <<< "$_c"; then
    assert_fail "[K5] no stage is told to fill in answer lines" "found 'Answer every finding you are given'"
else
    assert_pass "[K5] no stage is told to fill in answer lines"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
