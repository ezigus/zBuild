#!/usr/bin/env bash
# Integration: design.md decision prose flows to the PERSISTED build prompt
# artifact, in the right order (#916 / ADR-020).
#
# Unlike the unit test (which inspects the mock-router capture), this drives the
# build stage through real artifact paths and asserts the on-disk build-prompt.txt
# carries the ## DESIGN DECISIONS section, sourced from a design.md as the design
# stage would emit it, AND that the section is ordered before ## ACCEPTANCE TESTS.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "design→build decision-prose flow (#916 / ADR-020)"
setup_test_env "design-build-decisions-flow-916"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="design-build-flow-$$"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR/artifacts"

# shellcheck source=../../plugins/agent/build/plugin.sh
source "$REPO_ROOT/plugins/agent/build/plugin.sh"

# Mock the router loop so no real model runs; the prompt artifact is written
# before the loop is invoked, so we inspect it on disk after the run.
# shellcheck disable=SC2317
route_to_model_loop() {
    _ROUTE_LOOP_ITERATIONS=1
    _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
    _ROUTE_LOOP_INPUT_TOKENS=0
    _ROUTE_LOOP_OUTPUT_TOKENS=0
    _ROUTE_LOOP_LAST_RESPONSE="LOOP_COMPLETE"
    return 0
}
# shellcheck disable=SC2317
_route_resolve_max_iterations() { echo 3; }
# shellcheck disable=SC2317
_route_loop_close_final_banner() { return 0; }
# shellcheck disable=SC2317
apply_scope_redaction() { local in="$1" out="$2"; [[ -f "$in" ]] && cp "$in" "$out"; return 0; }

_FLOW_REPO="$TEST_TEMP_DIR/flow-repo"
mkdir -p "$_FLOW_REPO"
( cd "$_FLOW_REPO" && git init -q && git config user.email t@t && git config user.name t \
    && echo seed > seed.txt && git add seed.txt && git commit -q -m seed ) >/dev/null
export ZBUILD_REPO_ROOT="$_FLOW_REPO"

ARTIFACT_DIR="$ZBUILD_STATE_DIR/artifacts"
PLAN_JSON="$ARTIFACT_DIR/plan.json"
SCOPE_MANIFEST="$ZBUILD_STATE_DIR/scope-manifest.md"
DIFF_PATCH="$ARTIFACT_DIR/diff.patch"
SUMMARY_JSON="$ARTIFACT_DIR/build-summary.json"
PROMPT_ARTIFACT="$ARTIFACT_DIR/build-prompt.txt"
cat > "$PLAN_JSON" <<'JSON'
{ "title": "flow", "files": ["plugins/agent/build/plugin.sh"] }
JSON
touch "$SCOPE_MANIFEST"
unset ZBUILD_CYCLE_ITER ZBUILD_CYCLE_FEEDBACK_DIR

# A design.md as the design stage emits it: prose decision + scope + acceptance.
cat > "$ARTIFACT_DIR/design.md" <<'DESIGN'
# Design

## Decision
Build MUST register the new event in config/event-schema.json — a UNIQUE_FLOW_MARKER directive.

```scope
plugins/agent/build/plugin.sh
```

```acceptance
SPEC: build registers the event
TESTFILES:
tests/unit/build-design-decisions-test.sh
```
DESIGN

set +e
_build_stage_run_inner "$SCOPE_MANIFEST" "$PLAN_JSON" "$DIFF_PATCH" \
    "$SUMMARY_JSON" "$ARTIFACT_DIR" >/dev/null 2>&1
rc=$?
set -e
assert_eq "IT1: _build_stage_run_inner rc=0" "0" "$rc"
assert_file_exists "IT1: build-prompt.txt artifact persisted" "$PROMPT_ARTIFACT"

prompt="$(cat "$PROMPT_ARTIFACT" 2>/dev/null || echo '')"

if printf '%s' "$prompt" | grep -qF "## DESIGN DECISIONS"; then
    assert_pass "IT2: persisted build prompt carries ## DESIGN DECISIONS"
else
    assert_fail "IT2: build-prompt.txt must contain ## DESIGN DECISIONS" "not found"
fi
if printf '%s' "$prompt" | grep -qF "UNIQUE_FLOW_MARKER"; then
    assert_pass "IT3: decision prose marker reached the persisted prompt"
else
    assert_fail "IT3: decision prose must reach build-prompt.txt" "marker not found"
fi

# Ordering: DESIGN DECISIONS must appear BEFORE ACCEPTANCE TESTS.
dd_line="$(printf '%s\n' "$prompt" | grep -n "## DESIGN DECISIONS" | head -1 | cut -d: -f1)"
at_line="$(printf '%s\n' "$prompt" | grep -n "## ACCEPTANCE TESTS" | head -1 | cut -d: -f1)"
if [[ -n "$dd_line" && -n "$at_line" && "$dd_line" -lt "$at_line" ]]; then
    assert_pass "IT4: DESIGN DECISIONS ordered before ACCEPTANCE TESTS ($dd_line < $at_line)"
else
    assert_fail "IT4: DESIGN DECISIONS must precede ACCEPTANCE TESTS" "dd=$dd_line at=$at_line"
fi

# The scope-block path must NOT be duplicated into the decisions section (it is
# already the build scope); assert the in-fence content is excluded from prose.
dd_section="$(printf '%s\n' "$prompt" | awk '/## DESIGN DECISIONS/{f=1;next} f&&/^## /{exit} f{print}')"
if printf '%s' "$dd_section" | grep -qF '```'; then
    assert_fail "IT5: decisions section must not contain a fenced block" "fence leaked"
else
    assert_pass "IT5: decisions section excludes fenced-block content"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
