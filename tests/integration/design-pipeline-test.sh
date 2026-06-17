#!/usr/bin/env bash
# Tests: design stage plugin runs in the pipeline and emits plugin.run.start,
# writes design.md with a valid ```scope block that is a superset of
# plan.json's steps[].files[]. (#754)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER="$REPO_ROOT/core/pipeline/runner.sh"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "design: design stage runs in pipeline and produces scope block (#754)"
setup_test_env "design-pipeline-754"
export ZBUILD_CONTRACT_VALIDATOR=warn

PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
STATE_DIR="$TEST_TEMP_DIR/state"
EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"

export ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT"
export ZBUILD_STATE_DIR="$STATE_DIR"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$EVENTS_JSONL"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_CYCLES_ENABLED=0
mkdir -p "$STATE_DIR" "$TEST_TEMP_DIR/events"

_make_plugin() { mock_plugin_factory "$@"; }

# ─── Intake stub: writes scope-manifest.md ───────────────────────────────────
_intake_dir="$PLUGINS_ROOT/agent/intake"
mkdir -p "$_intake_dir"
cat > "$_intake_dir/manifest.yaml" <<'EOF'
id: intake
name: Stub intake
kind: agent
version: 0.0.1
hooks:
  run: intake_run
requires:
  core:
    - redaction
EOF
cat > "$_intake_dir/plugin.sh" <<'PLUGEOF'
intake_run() {
    local state_file="${2:-}"
    local state_dir; state_dir="$(dirname "${state_file:-$ZBUILD_STATE_DIR/state.json}")"
    mkdir -p "$state_dir"
    printf 'scope: all\n' > "$state_dir/scope-manifest.md"
    return 0
}
PLUGEOF

# ─── Plan stub: writes plan.json with steps[].files[] ────────────────────────
_plan_dir="$PLUGINS_ROOT/agent/plan"
mkdir -p "$_plan_dir"
cat > "$_plan_dir/manifest.yaml" <<'EOF'
id: plan
name: Stub plan
kind: agent
version: 0.0.1
hooks:
  run: plan_run
requires:
  core:
    - redaction
EOF
cat > "$_plan_dir/plugin.sh" <<'PLUGEOF'
plan_run() {
    local state_file="${2:-}"
    local state_dir; state_dir="$(dirname "${state_file:-$ZBUILD_STATE_DIR/state.json}")"
    local artifact_dir="$state_dir/artifacts"
    mkdir -p "$artifact_dir"
    cat > "$artifact_dir/plan.json" <<'JSONEOF'
{
  "title": "Test plan",
  "steps": [
    { "id": "step1", "files": ["src/foo.sh", "src/bar.sh"] }
  ]
}
JSONEOF
    return 0
}
PLUGEOF

# ─── Impact stub ─────────────────────────────────────────────────────────────
_make_plugin "impact" "agent" 0 >/dev/null

# ─── Design stub: emits plugin.run.start and writes design.md ────────────────
_design_dir="$PLUGINS_ROOT/agent/design"
mkdir -p "$_design_dir"
cat > "$_design_dir/manifest.yaml" <<'EOF'
id: design
name: Stub design
kind: agent
version: 0.0.1
hooks:
  run: design_run
requires:
  core:
    - redaction
EOF
cat > "$_design_dir/plugin.sh" <<'PLUGEOF'
design_run() {
    local state_file="${2:-}"
    local state_dir; state_dir="$(dirname "${state_file:-$ZBUILD_STATE_DIR/state.json}")"
    local artifact_dir="$state_dir/artifacts"
    mkdir -p "$artifact_dir"

    # Emit plugin.run.start to satisfy the assertion
    if declare -f emit_event >/dev/null 2>&1; then
        emit_event "plugin.run.start" "plugin=design" "stage=design"
    fi

    # Write design.md with a valid scope block (superset of plan.json files)
    cat > "$artifact_dir/design.md" <<'MDEOF'
# Design

## Decision
Implement the task as described in plan.json.

## Scope
```scope
src/foo.sh
src/bar.sh
src/extra.sh
```
MDEOF

    if declare -f emit_event >/dev/null 2>&1; then
        emit_event "plugin.run.complete" "plugin=design" "stage=design"
    fi
    return 0
}
PLUGEOF

# ─── Build/test/test_assessment/review stubs ─────────────────────────────────
_make_plugin "build"           "agent" 0 >/dev/null
_make_plugin "test"            "tool"  0 >/dev/null
_make_plugin "test_assessment" "agent" 0 >/dev/null
# #922: acceptance-gate leaf stage (ADR-036).
_make_plugin "acceptance-gate" "agent" 0 >/dev/null
# #755: review_cycle.flow now includes the 4 compound_quality stages.
_make_plugin "cq-preflight"    "agent" 0 >/dev/null
_make_plugin "cq-audit-plan"   "agent" 0 >/dev/null
_make_plugin "cq-cycle"        "agent" 0 >/dev/null
_make_plugin "cq-backtrack"    "agent" 0 >/dev/null
_make_plugin "review"          "agent" 0 >/dev/null

# ─── Run the pipeline end-to-end ─────────────────────────────────────────────
rm -f "$EVENTS_JSONL" "$STATE_DIR/pipeline-state.json"
mkdir -p "$TEST_TEMP_DIR/home/.zbuild"
set +e
env -u ZBUILD_STATE_DIR \
    ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" \
    ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events" \
    ZBUILD_EVENTS_JSONL="$EVENTS_JSONL" \
    ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db" \
    ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
    ZBUILD_CYCLES_ENABLED=0 \
    HOME="$TEST_TEMP_DIR/home" \
    PATH="$PATH" \
    bash "$RUNNER" --issue 754 >/dev/null 2>&1
rc=$?
set -e

ACTUAL_STATE_DIR="$TEST_TEMP_DIR/home/.zbuild/state"

assert_eq "runner exits 0" "0" "$rc"

# ─── Assertion 1: plugin.run.start plugin=design appears in events.jsonl ─────
if [[ -f "$EVENTS_JSONL" ]] && grep -q '"plugin.run.start"' "$EVENTS_JSONL" 2>/dev/null && \
   grep '"plugin.run.start"' "$EVENTS_JSONL" | grep -q '"plugin":"design"' 2>/dev/null; then
    assert_pass "events.jsonl contains plugin.run.start plugin=design"
else
    assert_fail "events.jsonl contains plugin.run.start plugin=design" \
        "$(grep 'plugin.run' "$EVENTS_JSONL" 2>/dev/null | head -5 || echo '(no events file)')"
fi

# ─── Assertion 2: design.md exists ───────────────────────────────────────────
# Locate design.md in the computed state dir (runner uses HOME/.zbuild/state).
DESIGN_MD="$(find "$ACTUAL_STATE_DIR" -name "design.md" 2>/dev/null | head -1 || true)"
if [[ -n "$DESIGN_MD" && -f "$DESIGN_MD" ]]; then
    assert_pass "design.md exists in state artifacts"
else
    assert_fail "design.md exists in state artifacts" \
        "searched under $ACTUAL_STATE_DIR"
fi

# ─── Assertion 3: design.md scope block is superset of plan.json files[] ─────
if [[ -n "$DESIGN_MD" && -f "$DESIGN_MD" ]]; then
    # Extract scope block files from design.md
    in_block=0
    scope_files=()
    while IFS= read -r line; do
        if [[ "$line" == '```scope' ]]; then in_block=1; continue; fi
        if [[ $in_block -eq 1 && "$line" == '```' ]]; then break; fi
        if [[ $in_block -eq 1 && -n "$line" ]]; then scope_files+=("$line"); fi
    done < "$DESIGN_MD"

    if [[ ${#scope_files[@]} -gt 0 ]]; then
        assert_pass "design.md contains a ```scope block with ${#scope_files[@]} entries"
    else
        assert_fail "design.md contains a ```scope block" "no entries found"
    fi

    # Check plan.json seed files appear in scope block
    plan_seed=("src/foo.sh" "src/bar.sh")
    for seed_file in "${plan_seed[@]}"; do
        found=0
        for sf in "${scope_files[@]}"; do
            [[ "$sf" == "$seed_file" ]] && found=1 && break
        done
        if [[ $found -eq 1 ]]; then
            assert_pass "design.md scope block contains plan seed file: $seed_file"
        else
            assert_fail "design.md scope block contains plan seed file: $seed_file" \
                "scope block: ${scope_files[*]}"
        fi
    done
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
