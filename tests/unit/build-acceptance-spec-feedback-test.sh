#!/usr/bin/env bash
# Unit: build SPEC enumeration (Layer 1) + acceptance-coverage gap injection
# (Layer 2) — #951. Drives _build_stage_run_inner with a mocked route_to_model_loop
# that captures the assembled prompt, plus direct helper unit tests.
#
# L1a: design acceptance block with SPEC-n ids → prompt enumerates each [SPEC-n].
# L1b: prompt carries the change-vs-guard hedge (guards not contorted).
# L1c: NO acceptance block / bare SPEC: lines → no enumeration block (self-omit).
# L2a: _build_read_prior_acceptance returns ONLY untagged_spec ids (filters out
#      tautology:/negctl_error:/infra — those are #913/infra, not build's fault).
# L2b: with a gap result present, the prompt injects the ACCEPTANCE COVERAGE GAPS
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
    set +e
    _build_stage_run_inner "$SCOPE_MANIFEST" "$PLAN_JSON" "$DIFF_PATCH" "$SUMMARY_JSON" "$ARTIFACT_DIR" >/dev/null 2>&1
    set -e
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
if printf '%s' "$p" | grep -qF "SPEC IDS YOU MUST COVER"; then
    assert_pass "L1a: prompt has the SPEC-id enumeration header"
else
    assert_fail "L1a: prompt must enumerate SPEC ids" "(missing)"
fi
for sid in SPEC-1 SPEC-2 SPEC-3; do
    printf '%s' "$p" | grep -qF "[$sid]" \
        && assert_pass "L1a: prompt enumerates [$sid]" \
        || assert_fail "L1a: prompt must enumerate [$sid]" "(missing)"
done
printf '%s' "$p" | grep -qiE 'guard|not contorted' \
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
printf '%s' "$p" | grep -qF "SPEC IDS YOU MUST COVER" \
    && assert_fail "L1c: must NOT enumerate when there are no SPEC-n ids" "(present)" \
    || assert_pass "L1c: enumeration block self-omits on id-less acceptance block"

# ─── L2a: _build_read_prior_acceptance filters to untagged_spec ONLY ─────────
FB="$TEST_TEMP_DIR/fb"; mkdir -p "$FB"
printf '%s' '{"verdict":"fail","failures":["untagged_spec:SPEC-2","tautology:SPEC-3","negctl_error:worktree_failed"]}' \
    > "$FB/prior_acceptance_feedback.txt"
got="$(ZBUILD_CYCLE_ITER=2 ZBUILD_CYCLE_FEEDBACK_DIR="$FB" _build_read_prior_acceptance | tr '\n' ',' | sed 's/,$//')"
assert_eq "L2a: reader returns ONLY untagged_spec ids (tautology/infra filtered)" "SPEC-2" "$got"
# verdict=pass → empty
printf '%s' '{"verdict":"pass","failures":[]}' > "$FB/prior_acceptance_feedback.txt"
got2="$(ZBUILD_CYCLE_ITER=2 ZBUILD_CYCLE_FEEDBACK_DIR="$FB" _build_read_prior_acceptance)"
assert_eq "L2a: verdict=pass → no gaps" "" "$got2"

# ─── L2b: gap result present → prompt injects ACCEPTANCE COVERAGE GAPS block ─
cat > "$DESIGN_MD" <<'DESIGN'
# Design

```acceptance
SPEC-1: change behavior A
TESTFILES:
tests/unit/build-acceptance-spec-feedback-test.sh
```
DESIGN
printf '%s' '{"verdict":"fail","failures":["untagged_spec:SPEC-2"]}' \
    > "$FB/prior_acceptance_feedback.txt"
export ZBUILD_CYCLE_ITER=2 ZBUILD_CYCLE_FEEDBACK_DIR="$FB"
p="$(_drive_build)"
printf '%s' "$p" | grep -qF "ACCEPTANCE COVERAGE GAPS" \
    && assert_pass "L2b: prompt injects ACCEPTANCE COVERAGE GAPS block" \
    || assert_fail "L2b: gap block must inject when gaps present" "(missing)"
# the gap block names the untagged id
printf '%s' "$p" | grep -A6 'ACCEPTANCE COVERAGE GAPS' | grep -qF "[SPEC-2]" \
    && assert_pass "L2b: gap block names the untagged [SPEC-2]" \
    || assert_fail "L2b: gap block must name [SPEC-2]" "(missing)"
# absent gap file → block omitted
rm -f "$FB/prior_acceptance_feedback.txt"
p="$(_drive_build)"
printf '%s' "$p" | grep -qF "ACCEPTANCE COVERAGE GAPS" \
    && assert_fail "L2b: gap block must omit when no gap file" "(present)" \
    || assert_pass "L2b: gap block omits when no gap file present"
unset ZBUILD_CYCLE_ITER ZBUILD_CYCLE_FEEDBACK_DIR

cleanup_test_env
print_test_results
exit $((FAIL > 0))
