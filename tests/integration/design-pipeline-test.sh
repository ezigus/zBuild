#!/usr/bin/env bash
# Tests: plugins/agent/design plugin produces design.md with a ```scope fenced block
# that is a strict superset of the files listed in plan.json steps[].files[].
# Verifies: plugin.run.start event, design.md existence, superset invariant.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "design plugin — scope superset + event emission (#754)"
setup_test_env "design-pipeline-754"
export ZBUILD_CONTRACT_VALIDATOR=warn

STATE_DIR="$TEST_TEMP_DIR/state"
ARTIFACTS_DIR="$STATE_DIR/artifacts"
EVENTS_DIR="$TEST_TEMP_DIR/events"
EVENTS_JSONL="$EVENTS_DIR/events.jsonl"

export ZBUILD_STATE_DIR="$STATE_DIR"
export ZBUILD_EVENTS_DIR="$EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$EVENTS_JSONL"
export ZBUILD_EVENTS_DB="$EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_RUN_ID="design-test-run-$$"
export ZBUILD_ISSUE="754"
export ZBUILD_GOAL="Test design stage scope superset"
export ZBUILD_OUTPUT_GH_COMMENT=0
export ZBUILD_OUTPUT_GH_CHECK_RUN=0
export NO_GITHUB=true

mkdir -p "$STATE_DIR" "$ARTIFACTS_DIR" "$EVENTS_DIR"

# ─── Stub plan.json with two known files ────────────────────────────────────
PLAN_FILE_A="plugins/agent/design/plugin.sh"
PLAN_FILE_B="plugins/agent/build/plugin.sh"

jq -n \
    --arg fa "$PLAN_FILE_A" \
    --arg fb "$PLAN_FILE_B" \
    '{
        title: "Test plan for design stage",
        files: [$fa, $fb],
        steps: [
            {id: "s1", title: "Step one", files: [$fa]},
            {id: "s2", title: "Step two", files: [$fb]}
        ]
    }' > "$ARTIFACTS_DIR/plan.json"

# ─── Stub scope-manifest.md so redaction passes ─────────────────────────────
printf '+ ./\n' | atomic_write "$STATE_DIR/scope-manifest.md"

# ─── State file ─────────────────────────────────────────────────────────────
STATE_FILE="$STATE_DIR/pipeline-state.json"
jq -n \
    --arg run_id "$ZBUILD_RUN_ID" \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{schema_version:1, run_id:$run_id, issue:754, stage_statuses:{},
      current_iteration:0, self_heal_count:{}, scope_manifest_hash:"",
      cost_ledger_pointer:0, claim_lease_id:"", plugin_state:{},
      updated_at:$now}' > "$STATE_FILE"

# ─── Mock claude to write design.md with scope block ────────────────────────
# The mock writes the output file directly and exits 0.
MOCK_BIN="$TEST_TEMP_DIR/bin"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/claude" <<'MOCK'
#!/usr/bin/env bash
# Minimal claude mock: write design.md containing a scope block and exit.
# The design plugin passes --output-file <path> to route_to_model_loop which
# reads it. We write to the path the plugin put in the prompt.
output_file=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-file) output_file="$2"; shift 2 ;;
        *) shift ;;
    esac
done

# If no --output-file flag, look for it in stdin prompt or just find design.md path
if [[ -z "$output_file" ]]; then
    # Parse from the first positional that looks like an output path
    exit 0
fi

cat > "$output_file" <<'DESIGN'
# Design: Test plan for design stage

## Context
Test design document produced by mock claude.

## Decision
Implement the design stage as a kind:agent plugin.

## Scope (machine-parsed by the build pipeline)

```scope
plugins/agent/design/plugin.sh
plugins/agent/build/plugin.sh
config/templates/standard.yaml
```

LOOP_COMPLETE
DESIGN
MOCK
chmod +x "$MOCK_BIN/claude"
export PATH="$MOCK_BIN:$PATH"

# Emit redaction.applied so router precondition is satisfied
jq -cn \
    --arg rid "$ZBUILD_RUN_ID" \
    '{ts:"2026-01-01T00:00:00Z", run_id:$rid, issue:754, type:"redaction.applied",
      plugin:"", kind:"", data:{}, schema_version:1}' \
    >> "$EVENTS_JSONL"

# ─── Run design plugin ───────────────────────────────────────────────────────
source "$REPO_ROOT/plugins/agent/design/plugin.sh"
design_stage_init
set +e
design_stage_run "design" "$STATE_FILE" 2>/dev/null
design_rc=$?
set -e

# ─── Assertions ──────────────────────────────────────────────────────────────

# (a) plugin.run.start event emitted
if grep -q '"type":"plugin.run.start"' "$EVENTS_JSONL" 2>/dev/null && \
   grep -q '"plugin":"design"' "$EVENTS_JSONL" 2>/dev/null; then
    assert_pass "plugin.run.start plugin=design in events.jsonl"
else
    assert_fail "plugin.run.start plugin=design in events.jsonl" \
        "events: $(cat "$EVENTS_JSONL" 2>/dev/null | tr '\n' '|' | head -c 400)"
fi

# (b) design.md exists
assert_file_exists "design.md produced" "$ARTIFACTS_DIR/design.md"

# (c) design.md contains a ```scope fenced block
if grep -q '^\`\`\`scope' "$ARTIFACTS_DIR/design.md" 2>/dev/null; then
    assert_pass "design.md contains \`\`\`scope fenced block"
else
    assert_fail "design.md contains \`\`\`scope fenced block" \
        "design.md contents: $(head -20 "$ARTIFACTS_DIR/design.md" 2>/dev/null || echo '(empty)')"
fi

# (d) superset invariant: every file in plan.json steps[].files[] appears in scope block
scope_block="$(awk '/^```scope/{found=1; next} found && /^```/{exit} found{print}' \
    "$ARTIFACTS_DIR/design.md" 2>/dev/null || echo "")"

for plan_file in "$PLAN_FILE_A" "$PLAN_FILE_B"; do
    if printf '%s\n' "$scope_block" | grep -qF "$plan_file"; then
        assert_pass "scope block contains plan file: $plan_file"
    else
        assert_fail "scope block contains plan file: $plan_file" \
            "scope block: $(printf '%s' "$scope_block" | head -c 300)"
    fi
done

cleanup_test_env
print_test_results
exit $((FAIL > 0))
