#!/usr/bin/env bash
# Integration test (#1265, SPEC-1): a PRE-EXISTING untracked stray (present at
# intake, NOT created/touched by the build this run) does NOT trigger
# build.scope.violation and is NOT in build-summary.scope_violations. The build
# does only in-scope work; the leftover stray is out of judgment.
#
# RED at baseline: today `git add -N .` intent-adds the stray → status A → OOS →
# scope_violation. GREEN after: selective `git add -N` + census skip reading
# intake-untracked-baseline.txt.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "build #1265: pre-existing untracked stray is NOT a scope_violation"
setup_test_env "build-1265-preexisting-untracked"

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="build-1265-pre-$$"
export ZBUILD_ISSUE="1265"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR/artifacts/stage-io"

export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

REPO="$(setup_git_temp_repo build1265pre)"
mkdir -p "$REPO/tests/fixtures"
( cd "$REPO" \
    && echo "seed" > tests/fixtures/seed.txt \
    && git add tests/fixtures/seed.txt \
    && git commit -q -m "seed" ) >/dev/null

# Pre-existing untracked stray, left over from a prior run (the #1214/#945 file).
mkdir -p "$REPO/config/templates"
printf 'stray perf fixture\n' > "$REPO/config/templates/runner-state-dir-minimal.yaml"

# Stub claude: does ONLY in-scope work (tests/fixtures/in-scope.txt).
mkdir -p "$TEST_TEMP_DIR/bin"
cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
printf 'in scope content\n' > "$PWD/tests/fixtures/in-scope.txt"
jq -n --arg r $'did in-scope work\nCOMMIT_SUMMARY: in-scope change\nLOOP_COMPLETE' \
    '{result:$r, usage:{input_tokens:5, output_tokens:5}}'
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
export PATH="$TEST_TEMP_DIR/bin:$PATH"

cat > "$TEST_TEMP_DIR/template.yaml" <<'YAML'
id: standard
name: Standard
defaults:
  strategy: fanout
stages:
  - id: build
    gate: auto
    roles: [builder]
    io:
      destinations: [file]
      tail_lines: 40
YAML

STATE_DIR="$TEST_TEMP_DIR/state-build"
mkdir -p "$STATE_DIR/artifacts"
cat > "$STATE_DIR/artifacts/plan.json" <<'EOF'
{
  "schema_version": 1,
  "title": "in-scope only",
  "goal": "scope test",
  "files": ["tests/fixtures/in-scope.txt"],
  "steps": [{"id":"s1","description":"d","files":["tests/fixtures/in-scope.txt"],"estimated_lines":1}]
}
EOF
cat > "$STATE_DIR/scope-manifest.md" <<'EOF'
+ tests/fixtures/
EOF
# The intake untracked snapshot: the pre-existing stray was present at run-start.
printf 'config/templates/runner-state-dir-minimal.yaml\0' \
    > "$STATE_DIR/intake-untracked-baseline.txt"
STATE_FILE="$STATE_DIR/state.json"
printf '{"issue":1265,"branch":"feat/1265"}' > "$STATE_FILE"

STAGE_INPUTS_DRIVER="$TEST_TEMP_DIR/stage-inputs-driver.json"
jq -n \
    --arg sm "$STATE_DIR/scope-manifest.md" \
    --arg pl "$STATE_DIR/artifacts/plan.json" \
    '{"schema_version":1,"stage":"build","inputs":{"scope_manifest":$sm,"plan":$pl}}' \
    > "$STAGE_INPUTS_DRIVER"

DRIVER="$TEST_TEMP_DIR/driver.sh"
cat > "$DRIVER" <<EOF
set -euo pipefail
source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/core/event-bus/event-bus.sh"
source "$REPO_ROOT/core/pipeline/template.sh"
source "$REPO_ROOT/core/output/stage-io.sh"
source "$REPO_ROOT/plugins/agent/build/plugin.sh"

export ZBUILD_EVENTS_DIR="$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_JSONL"
export ZBUILD_EVENT_SCHEMA="$ZBUILD_EVENT_SCHEMA"
export ZBUILD_STATE_DIR="$ZBUILD_STATE_DIR"
export ZBUILD_MODELS_FILE="$ZBUILD_MODELS_FILE"
export ZBUILD_RUN_ID="$ZBUILD_RUN_ID"
export ZBUILD_ISSUE="$ZBUILD_ISSUE"
export ZBUILD_REPO_ROOT="$REPO"
export HOME="$HOME"
export ZBUILD_SCOPE_OVERRIDE=1
export PATH="$PATH"
export ZBUILD_STAGE_INPUTS="$STAGE_INPUTS_DRIVER"

load_template "$TEST_TEMP_DIR/template.yaml"
export ZBUILD_CURRENT_STAGE=build
build_stage_init >/dev/null 2>&1 || true
build_stage_run "ignored" "$STATE_FILE"
EOF

bash "$DRIVER" >/dev/null 2>/dev/null || true

# ── (1) No build.scope.violation for the pre-existing stray ────────────────
_sv_paths="$(jq -r 'select(.type=="build.scope.violation") | .data.path' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
if [[ -f "$ZBUILD_EVENTS_JSONL" ]] \
   && grep -Fxq 'config/templates/runner-state-dir-minimal.yaml' <<< "$_sv_paths"; then
    assert_fail "no scope.violation for pre-existing stray" "stray was flagged"
else
    assert_pass "no scope.violation for pre-existing stray"
fi

# ── (2) build-summary verdict is NOT scope_violation; stray not in list ────
SUMMARY="$STATE_DIR/artifacts/build-summary.json"
if [[ -f "$SUMMARY" ]]; then
    verdict="$(jq -r '.verdict // ""' "$SUMMARY" 2>/dev/null || echo "")"
    if [[ "$verdict" == "scope_violation" ]]; then
        assert_fail "build verdict is not scope_violation" "verdict=scope_violation"
    else
        assert_pass "build verdict is not scope_violation (got: ${verdict:-<empty>})"
    fi
    if grep -Fxq 'config/templates/runner-state-dir-minimal.yaml' \
        <<< "$(jq -r '.scope_violations[]?' "$SUMMARY" 2>/dev/null)"; then
        assert_fail "stray absent from scope_violations" "stray present"
    else
        assert_pass "stray absent from scope_violations"
    fi
else
    assert_fail "build-summary.json written" "missing"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
