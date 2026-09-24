#!/usr/bin/env bash
# Tests: build prompt v2 framing — ORIGINAL TASK / INSTRUCTIONS /
# CURRENT ITERATION FEEDBACK sections + iter N/MAX banner (#571).
#
# Verifies the three-section structure the LLM sees:
#   - Iter 1: banner + ORIGINAL TASK + INSTRUCTIONS, NO FEEDBACK section.
#   - Iter 2+: same; prior-stage findings arrive as the router's STAGE
#     SUMMARIES block, not a composed section (#2124 retired the readers).
#   - Banner shows "iter N/MAX" accurately.
#   - the bespoke feedback readers are retired (#2124).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "build prompt v2 framing (#571)"
setup_test_env "build-prompt-framing"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR"

# Capture the assembled prompt by mocking route_to_model_loop.
export _MOCK_ROUTE_CAPTURE="$TEST_TEMP_DIR/route-prompt.txt"

# shellcheck source=../../plugins/agent/build/plugin.sh
source "$REPO_ROOT/plugins/agent/build/plugin.sh"

route_to_model_loop() {
    local _prompt_file="$2"
    [[ -f "$_prompt_file" ]] && cp "$_prompt_file" "$_MOCK_ROUTE_CAPTURE"
    _ROUTE_LOOP_ITERATIONS=1
    _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
    _ROUTE_LOOP_INPUT_TOKENS=0
    _ROUTE_LOOP_OUTPUT_TOKENS=0
    return 0
}

# Surface max iter to header — route resolver returns 3 so banner reads "iter N/3".
_route_resolve_max_iterations() { echo 3; }

# Fresh git repo so the post-loop `git diff HEAD` capture works.
_FRAMING_REPO="$TEST_TEMP_DIR/framing-repo"
mkdir -p "$_FRAMING_REPO"
( cd "$_FRAMING_REPO" && git init -q && git config user.email t@t && git config user.name t \
    && echo seed > seed.txt && git add seed.txt && git commit -q -m seed ) >/dev/null
export ZBUILD_REPO_ROOT="$_FRAMING_REPO"

# Pass-through redaction (no manifest needed for framing tests).
apply_scope_redaction() {
    local in="$1" out="$2"
    cp "$in" "$out"
    return 0
}

artifact_dir="$TEST_TEMP_DIR/state/artifacts"
mkdir -p "$artifact_dir"
plan_path="$artifact_dir/plan.json"
cat > "$plan_path" <<'EOF'
{
  "title": "Framing fixture plan",
  "goal": "Verify prompt v2 framing sections",
  "steps": [
    {"id": 1, "description": "do thing", "files": ["a.sh"]}
  ]
}
EOF

scope_manifest="$TEST_TEMP_DIR/state/scope-manifest.md"
touch "$scope_manifest"

# ─── Iter 1 — no cycle context, no FEEDBACK section ─────────────────────────
unset ZBUILD_CYCLE_ITER ZBUILD_CYCLE_FEEDBACK_DIR
: > "$_MOCK_ROUTE_CAPTURE"

set +e
_build_stage_run_inner \
    "$scope_manifest" \
    "$plan_path" \
    "$artifact_dir/diff.patch" \
    "$artifact_dir/build-summary.json" \
    "$artifact_dir" >/dev/null 2>&1
rc1=$?
set -e

assert_eq "F1: iter 1 build inner rc=0" "0" "$rc1"

iter1_prompt="$(cat "$_MOCK_ROUTE_CAPTURE" 2>/dev/null || echo '')"

# F2: banner present and reads "iter 1/3"
assert_contains "F2: iter 1 banner present" "$iter1_prompt" "ZBUILD BUILD"
assert_contains "F2: iter 1 banner reads 'iter 1/3'" "$iter1_prompt" "iter 1/3"

# F3: ORIGINAL TASK section header present
assert_contains "F3: iter 1 has ORIGINAL TASK section" "$iter1_prompt" \
    "## ORIGINAL TASK"

# F4: INSTRUCTIONS section header present
assert_contains "F4: iter 1 has INSTRUCTIONS section" "$iter1_prompt" \
    "## INSTRUCTIONS"

# F5 (#2124): no per-iteration feedback section — findings arrive as the router's
# STAGE SUMMARIES block, never composed here.
if grep -qF "## CURRENT ITERATION FEEDBACK" <<< "$iter1_prompt"; then
    assert_fail "F5: the prompt composes no CURRENT ITERATION FEEDBACK section" \
        "found retired section"
else
    assert_pass "F5: the prompt composes no CURRENT ITERATION FEEDBACK section"
fi

# ─── Iter 2 — cycle context ─────────────────────────────────────────────────
export ZBUILD_CYCLE_ITER=2

: > "$_MOCK_ROUTE_CAPTURE"

set +e
_build_stage_run_inner \
    "$scope_manifest" \
    "$plan_path" \
    "$artifact_dir/diff.patch" \
    "$artifact_dir/build-summary.json" \
    "$artifact_dir" >/dev/null 2>&1
rc2=$?
set -e

assert_eq "F6: iter 2 build inner rc=0" "0" "$rc2"

iter2_prompt="$(cat "$_MOCK_ROUTE_CAPTURE" 2>/dev/null || echo '')"

# F7: banner shows iter 2/3
assert_contains "F7: iter 2 banner reads 'iter 2/3'" "$iter2_prompt" "iter 2/3"

# F8: ORIGINAL TASK + INSTRUCTIONS still present
assert_contains "F8: iter 2 has ORIGINAL TASK section" "$iter2_prompt" \
    "## ORIGINAL TASK"
assert_contains "F8: iter 2 has INSTRUCTIONS section" "$iter2_prompt" \
    "## INSTRUCTIONS"

# F9–F11 (#2124): retired with the readers they exercised — see the guard below.

# ─── F12: _build_render_task_header emits banner with iter N/MAX ────────────
if declare -F _build_render_task_header >/dev/null 2>&1; then
    hdr="$(_build_render_task_header 2 5)"
    assert_contains "F12: header banner contains 'ZBUILD BUILD'" "$hdr" "ZBUILD BUILD"
    assert_contains "F12: header banner contains 'iter 2/5'" "$hdr" "iter 2/5"
else
    assert_fail "F12: _build_render_task_header helper must exist" "missing"
fi

# ─── #2124: the bespoke feedback readers are retired ─────────────────────────
# No shipped template wires test_assessment/review/acceptance feedback into
# build since #1979 — findings arrive as engine-collected STAGE SUMMARIES. The
# readers stayed, and so did three prompt sections nothing could ever fill;
# one of them ("ACCEPTANCE COVERAGE GAPS … add [SPEC-n] tags") instructed the
# builder to edit the testfiles #2022 forbids it to touch. Their presence is
# what misled the #1841 diagnosis into "feedback was never delivered".
print_test_section "#2124: retired feedback readers"
for _fn in _build_read_prior_review _build_read_prior_acceptance; do
    if declare -F "$_fn" >/dev/null 2>&1; then
        assert_fail "[#2124] $_fn is retired" "still defined"
    else
        assert_pass "[#2124] $_fn is retired"
    fi
done
# The test-summary reader stays — it feeds the mechanical out-of-scope
# detection (scope expansion) — but reads the DECLARED input, not a feedback
# dir no template writes.
_si="$TEST_TEMP_DIR/si-2124.json"; _tfs="$TEST_TEMP_DIR/tfs-2124.md"
printf 'test failed: plugins/tool/x/plugin.sh pins 8 stages\n' > "$_tfs"
printf '{"inputs":{"test_failures_summary":"%s"}}\n' "$_tfs" > "$_si"
# #2132: only a PRIOR ITERATION of this run may feed it. On iteration 1 the
# declared input resolves to whatever hydrate restored from a previous run —
# run 35337145412 read a stale TIMEOUT line, named an out-of-scope file, and
# halted the cycle blocked_on_scope before iteration 2 could happen.
assert_contains "[#2124] _build_read_prior_assessment reads the declared test_failures_summary input (iter 2)" \
    "$(ZBUILD_STAGE_INPUTS="$_si" ZBUILD_CYCLE_ITER=2 _build_read_prior_assessment 2>/dev/null)" "pins 8 stages"
assert_eq "[#2132] …but not on iteration 1 (a restored previous-run artifact)" "" \
    "$(ZBUILD_STAGE_INPUTS="$_si" ZBUILD_CYCLE_ITER=1 _build_read_prior_assessment 2>/dev/null)"
assert_eq "[#2132] …nor outside a cycle" "" \
    "$(ZBUILD_STAGE_INPUTS="$_si" ZBUILD_CYCLE_ITER="" _build_read_prior_assessment 2>/dev/null)"
assert_eq "[#2124] …and nothing from the feedback dir" "" \
    "$(ZBUILD_STAGE_INPUTS="" ZBUILD_CYCLE_ITER=2 ZBUILD_CYCLE_FEEDBACK_DIR="$TEST_TEMP_DIR" _build_read_prior_assessment 2>/dev/null)"
assert_contains "[#2124] build declares test_failures_summary as an optional input" \
    "$(awk '/^inputs:/,/^outputs:/' "$REPO_ROOT/plugins/agent/build/manifest.yaml")" "id: test_failures_summary"
for _sec in "CURRENT ITERATION FEEDBACK" "PRIOR REVIEW FEEDBACK" "ACCEPTANCE COVERAGE GAPS"; do
    if grep -qF "$_sec" "$REPO_ROOT/plugins/agent/build/lib/prompt.sh"; then
        assert_fail "[#2124] prompt.sh no longer renders '$_sec'" "section still present"
    else
        assert_pass "[#2124] prompt.sh no longer renders '$_sec'"
    fi
done

# ─── #2138: a prior build that changed nothing is not "done" ──────────────────
# "verdict=pass and touched 0 file(s) … emit LOOP_COMPLETE immediately" was
# obeyed verbatim by iteration 1 of run 35355623656 on a red suite.
print_test_section "#2138: PRIOR BUILD note"
_read_prior_output() { [[ "$1" == build-summary.json ]] && printf '{"verdict":"pass","files_changed":[]}'; return 0; }
_pb0="$(_build_read_prior_build_summary 2>/dev/null)"
assert_contains "[#2138] a 0-file prior build is described as having changed nothing" "$_pb0" "changed nothing"
if grep -qi 'emit LOOP_COMPLETE immediately' <<< "$_pb0"; then
    assert_fail "[#2138] a 0-file prior build must not invite an immediate LOOP_COMPLETE" "$_pb0"
else
    assert_pass "[#2138] a 0-file prior build does not invite an immediate LOOP_COMPLETE"
fi
assert_contains "[#2138] …and points at the STAGE SUMMARIES for the suite's state" "$_pb0" "STAGE SUMMARIES"
_read_prior_output() { [[ "$1" == build-summary.json ]] && printf '{"verdict":"pass","files_changed":["core/a.sh","core/b.sh"]}'; return 0; }
_pb2="$(_build_read_prior_build_summary 2>/dev/null)"
assert_contains "[#2138] a prior build with real changes keeps the continue-do-not-restart guidance" "$_pb2" "do NOT restart"
unset -f _read_prior_output

# ─── (#2183) the prompt permits reporting a finding that does not reproduce ─
# It used to say "'nothing to do' is not an available answer" while a RESOLVE
# summary stood, so a builder holding a passing test had no way to say so.
print_test_section "#2183: a finding that does not reproduce can be reported"
# Read the shipped text directly: this is the prompt the stage sends, and the
# rule under test is a property of that text, not of how it is assembled.
_t2183="$(sed -n '/### Completion sentinel/,/### Budget/p' \
    "$REPO_ROOT/plugins/agent/build/lib/prompt.sh" 2>/dev/null || true)"
assert_contains "[#2183] premise: the section under test was read" "$_t2183" "LOOP_COMPLETE"
assert_contains "[#2183] the prompt tells it how to report a non-reproduction" \
    "$_t2183" "does not reproduce"
if grep -q "not an available answer" <<< "$_t2183"; then
    assert_fail "[#2183] the blanket ban on 'nothing to do' is gone" "still present"
else
    assert_pass "[#2183] the blanket ban on 'nothing to do' is gone"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
