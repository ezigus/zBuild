#!/usr/bin/env bash
# Unit: build SPEC enumeration (Layer 1) + acceptance-coverage gap injection
# (Layer 2) — #951. Drives _build_stage_run_inner with a mocked route_to_model_loop
# that captures the assembled prompt, plus direct helper unit tests.
#
# L1a: design acceptance block with SPEC-n ids → prompt enumerates each [SPEC-n].
# L1b: prompt carries the change-vs-guard hedge (guards not contorted).
# L1c: NO acceptance block / bare SPEC: lines → no enumeration block (self-omit).
# L2a: (#2124) _build_read_prior_acceptance is retired (it returned untagged ids
#      tautology:/negctl_error:/infra — those are #913/infra, not build's fault).
# L2b: retired with L2a — no ACCEPTANCE COVERAGE GAPS section (#2124)
#      block listing the untagged ids; absent/pass → omitted.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "build SPEC enumeration + acceptance-gap injection (#951)"
setup_test_env "build-spec-feedback-951"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="build-spec-feedback-$$"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR/artifacts"
export _MOCK_ROUTE_CAPTURE="$TEST_TEMP_DIR/route-prompt.txt"

# shellcheck source=../../plugins/agent/build/plugin.sh
source "$REPO_ROOT/plugins/agent/build/plugin.sh"

# shellcheck disable=SC2317
route_to_model_loop() {
    local _prompt_file="$2"
    [[ -f "$_prompt_file" ]] && cp "$_prompt_file" "$_MOCK_ROUTE_CAPTURE"
    _ROUTE_LOOP_ITERATIONS=1; _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
    _ROUTE_LOOP_INPUT_TOKENS=0; _ROUTE_LOOP_OUTPUT_TOKENS=0
    _ROUTE_LOOP_LAST_RESPONSE="LOOP_COMPLETE"; return 0
}
# shellcheck disable=SC2317
_route_resolve_max_iterations() { echo 3; }
# shellcheck disable=SC2317
_route_loop_close_final_banner() { return 0; }
# shellcheck disable=SC2317
apply_scope_redaction() { local in="$1" out="$2"; [[ -f "$in" ]] && cp "$in" "$out"; return 0; }

_REPO="$TEST_TEMP_DIR/repo"; mkdir -p "$_REPO"
( cd "$_REPO" && git init -q && git config user.email t@t && git config user.name t \
    && echo seed > seed.txt && git add seed.txt && git commit -q -m seed ) >/dev/null
export ZBUILD_REPO_ROOT="$_REPO"

ARTIFACT_DIR="$ZBUILD_STATE_DIR/artifacts"
PLAN_JSON="$ARTIFACT_DIR/plan.json"; SCOPE_MANIFEST="$ZBUILD_STATE_DIR/scope-manifest.md"
DIFF_PATCH="$ARTIFACT_DIR/diff.patch"; SUMMARY_JSON="$ARTIFACT_DIR/build-summary.json"
printf '{"title":"t","files":["plugins/agent/build/plugin.sh"]}' > "$PLAN_JSON"
touch "$SCOPE_MANIFEST"
DESIGN_MD="$ARTIFACT_DIR/design.md"

_drive_build() {
    : > "$_MOCK_ROUTE_CAPTURE"
    local _e; case $- in *e*) _e=1 ;; *) _e=0 ;; esac   # save errexit; restore (don't force-enable)
    set +e
    _build_stage_run_inner "$SCOPE_MANIFEST" "$PLAN_JSON" "$DIFF_PATCH" "$SUMMARY_JSON" "$ARTIFACT_DIR" >/dev/null 2>&1
    [[ "$_e" -eq 1 ]] && set -e
    cat "$_MOCK_ROUTE_CAPTURE" 2>/dev/null || echo ''
}

# ─── L1: design.md with SPEC-n ids → prompt enumerates them + guard hedge ────
cat > "$DESIGN_MD" <<'DESIGN'
# Design

```acceptance
SPEC-1: change behavior A
SPEC-2: change behavior B
SPEC-3: guard behavior C stays the same
TESTFILES:
tests/unit/build-acceptance-spec-feedback-test.sh
```
DESIGN
unset ZBUILD_CYCLE_ITER ZBUILD_CYCLE_FEEDBACK_DIR
p="$(_drive_build)"
if grep -qF "SPEC IDS YOU MUST COVER" <<< "$p"; then
    assert_pass "L1a: prompt has the SPEC-id enumeration header"
else
    assert_fail "L1a: prompt must enumerate SPEC ids" "(missing)"
fi
for sid in SPEC-1 SPEC-2 SPEC-3; do
    grep -qF "[$sid]" <<< "$p" \
        && assert_pass "L1a: prompt enumerates [$sid]" \
        || assert_fail "L1a: prompt must enumerate [$sid]" "(missing)"
done
grep -qiE 'guard|not contorted' <<< "$p" \
    && assert_pass "L1b: prompt carries the change-vs-guard hedge" \
    || assert_fail "L1b: prompt must hedge guard SPECs" "(missing)"

# ─── L1c: bare SPEC: lines (no ids) → enumeration self-omits ────────────────
cat > "$DESIGN_MD" <<'DESIGN'
# Design

```acceptance
SPEC: a bare spec with no id
TESTFILES:
tests/unit/build-acceptance-spec-feedback-test.sh
```
DESIGN
p="$(_drive_build)"
grep -qF "SPEC IDS YOU MUST COVER" <<< "$p" \
    && assert_fail "L1c: must NOT enumerate when there are no SPEC-n ids" "(present)" \
    || assert_pass "L1c: enumeration block self-omits on id-less acceptance block"

# ─── L2a/L2b (#2124): the acceptance-gap reader is retired ─────────────────────
# It told build to add [SPEC-n] tags to testfiles — the edit #2022 forbids —
# and no template wired its input. Untagged SPECs reach the next prompts as
# the gate's `summary: true` output (ADR-055 §9).
FB="$TEST_TEMP_DIR/fb"; mkdir -p "$FB"
if declare -f _build_read_prior_acceptance >/dev/null 2>&1; then
    assert_fail "L2a: the acceptance-gap reader is retired from build" "still defined"
else
    assert_pass "L2a: the acceptance-gap reader is retired from build"
fi

# ─── L2c/L2d (#2022): the tautology feed no longer reaches build ─────────────
# #1583 fed the gate's tautology finding to build so build could re-author the
# assertion — the agent whose control was found inert rewriting the control.
# #1978 tightened the WORDING of that licence; #2022 removes the licence. The
# same feedback now reaches test-author, which owns assertion bodies.
if declare -f _build_read_tautology_ids >/dev/null 2>&1; then
    assert_fail "L2c: the tautology reader is retired from build" \
        "_build_read_tautology_ids is still defined"
else
    assert_pass "L2c: the tautology reader is retired from build"
fi

cat > "$DESIGN_MD" <<'DESIGN'
# Design

```acceptance
SPEC-1: change behavior A
TESTFILES:
tests/unit/build-acceptance-spec-feedback-test.sh
```
DESIGN
printf '%s' '{"verdict":"fail","failures":["tautology:SPEC-3"]}' \
    > "$FB/prior_acceptance_feedback.txt"
export ZBUILD_CYCLE_ITER=2 ZBUILD_CYCLE_FEEDBACK_DIR="$FB"
p="$(_drive_build)"
grep -qF "## TAUTOLOGICAL ASSERTIONS" <<< "$p" \
    && assert_fail "L2d: a tautology finding no longer reaches build" "(block present)" \
    || assert_pass "L2d: a tautology finding no longer reaches build"
grep -qF "which you MUST re-author" <<< "$p" \
    && assert_fail "L2d: the re-author licence is gone from build's prompt" "(present)" \
    || assert_pass "L2d: the re-author licence is gone from build's prompt"
grep -qF "MUST NOT weaken, delete, retag or re-author any assertion" <<< "$p" \
    && assert_pass "L2d: build is told the assertions are not its to touch" \
    || assert_fail "L2d: build must be told the assertions are not its to touch" "(missing)"

# absent → block omitted
rm -f "$FB/prior_acceptance_feedback.txt"
p="$(_drive_build)"
grep -qF "## TAUTOLOGICAL ASSERTIONS" <<< "$p" \
    && assert_fail "L2d: tautology block must omit when no feedback file" "(present)" \
    || assert_pass "L2d: tautology block omits when no feedback file"
unset ZBUILD_CYCLE_ITER ZBUILD_CYCLE_FEEDBACK_DIR

cleanup_test_env
print_test_results
exit $((FAIL > 0))
