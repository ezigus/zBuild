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

S2="$TEST_TEMP_DIR/state2"; mkdir -p "$S2"
printf '{"schema_version":1}\n' > "$S2/pipeline-state.json"
printf 'Do your task.\n' > "$TEST_TEMP_DIR/p2.txt"
SNAP2="$TEST_TEMP_DIR/p2.snap"
(
    # shellcheck source=../../core/pipeline/input-resolve.sh
    source "$REPO_ROOT/core/pipeline/input-resolve.sh" >/dev/null 2>&1
    # The summary renderer is stubbed to its real heading and line shapes —
    # what is under test is what the funnel adds after it.
    stage_summaries_prompt_block() {
        printf '%s\n' "=== STAGE SUMMARIES ===" \
            "### test (verdict: fail) — its findings, to answer" \
            "- test finding 1 (opened by test): run-tests-test.sh fails on line 40"
    }
    stage_summaries_count() { printf '1 1\n'; }
    apply_scope_redaction() { cp "$1" "$SNAP2"; cp "$1" "$2"; return 0; }
    export ZBUILD_CURRENT_STAGE=build ZBUILD_STATE_DIR="$S2"
    unset ZBUILD_PLUGIN_DIR ZBUILD_STAGE_INPUTS
    ZBUILD_SCOPE_MANIFEST="$TEST_TEMP_DIR/m2.yaml"; : > "$ZBUILD_SCOPE_MANIFEST"
    _route_redact_prompt "$TEST_TEMP_DIR/p2.txt" "$TEST_TEMP_DIR/p2.out" 0 ""
) >/dev/null 2>&1
_p2="$(cat "$SNAP2" 2>/dev/null)"
assert_contains "[K2] the funnel added the findings (fixture live)" "$_p2" "- test finding 1 (opened by test)"
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
jq -n -c '{result_contract:2, verdict:"fail", disposition:"complete", reason:"one requirement unmet",
           data:{findings:[{n:1, text:"R-1: the PR body does not state the red step"}]}}' \
    > "$S4/artifacts/issue-acceptance-result.json"
_items="$(open_items_json "$S4")"
assert_eq "[K4] one item is open" "1" "$(jq 'length' <<< "$_items" 2>/dev/null)"
assert_eq "[K4] it is the check's latest finding" "R-1: the PR body does not state the red step" \
    "$(jq -r '.[0].text // empty' <<< "$_items" 2>/dev/null)"

print_test_section "K5: stages report on findings in their own result"
# shellcheck source=../../scripts/lib/stage-conduct.sh
source "$REPO_ROOT/scripts/lib/stage-conduct.sh"
_c="$(stage_conduct_block)"
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
