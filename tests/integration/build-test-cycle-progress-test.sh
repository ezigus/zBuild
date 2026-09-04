#!/usr/bin/env bash
# Integration test (#602): a 2-iter build cycle makes real progress between
# iterations because the LLM's edits survive into the next iter (no stash
# hides them). Asserts that iter 1 produces non-zero numstat — the canonical
# signal that build is no longer 0/0/0.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "build #602: multi-iter cycle makes progress (numstat > 0)"
setup_test_env "build-602-cycle-progress"

# #1921 follow-up: reserved test identity — the QUOTED assignment form.
# These were real issue numbers used as run identity.
_ZB_ID="$(zb_test_issue)"

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="build-602cyc-$$"
export ZBUILD_ISSUE="$_ZB_ID"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR/artifacts/stage-io"

export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

REPO="$(setup_git_temp_repo build602cycrepo)"
[[ -d "$REPO" ]] || { echo "setup_git_temp_repo failed" >&2; exit 1; }
mkdir -p "$REPO/tests/fixtures"
( cd "$REPO" \
    && echo "seed" > tests/fixtures/seed.txt \
    && git add tests/fixtures/seed.txt \
    && git commit -q -m "seed" ) >/dev/null

# Stub claude: 2 iters, each appends a line to the in-scope fixture.
MARK_FILE="$TEST_TEMP_DIR/llm-call.mark"
if [[ -n "$MARK_FILE" ]]; then
    assert_pass "[SPEC-1] MARK_FILE non-empty at setup"
else
    assert_fail "[SPEC-1] MARK_FILE non-empty at setup" "MARK_FILE is empty or unset"
fi
mkdir -p "$TEST_TEMP_DIR/bin"
cat > "$TEST_TEMP_DIR/bin/claude" <<MOCK
#!/usr/bin/env bash
mark="$MARK_FILE"
n=\$(wc -l < "\$mark" 2>/dev/null | tr -d ' ' || echo 0)
n=\$(( n + 1 ))
echo "MARK_iter_\${n}" >> "\$mark"
mkdir -p "\$PWD/tests/fixtures"
printf 'progress-iter-%d\n' "\$n" >> "\$PWD/tests/fixtures/cycle-602.txt"
if [[ "\$n" -ge 2 ]]; then
    jq -n --arg r \$'done\nLOOP_COMPLETE' \
        '{result:\$r, usage:{input_tokens:7, output_tokens:4}}'
else
    jq -n --arg r "iter \${n} progress" \
        '{result:\$r, usage:{input_tokens:7, output_tokens:4}}'
fi
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
assert_contains "[SPEC-2] mock-claude bakes concrete MARK_FILE path at write time" \
    "$(cat "$TEST_TEMP_DIR/bin/claude")" "$MARK_FILE"
mock_body="$(cat "$TEST_TEMP_DIR/bin/claude")"
if ! grep -qF '/tmp/mark' <<< "$mock_body" 2>/dev/null; then
    assert_pass "[SPEC-3] mock-claude has no /tmp/mark fallback"
else
    assert_fail "[SPEC-3] mock-claude has no /tmp/mark fallback" "found /tmp/mark in mock body"
fi
export PATH="$TEST_TEMP_DIR/bin:$PATH"
export MARK_FILE

cat > "$TEST_TEMP_DIR/template.yaml" <<'YAML'
id: standard
name: Standard Pipeline
extends: null
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
  "goal": "Cycle progress fixture (#602)",
  "files": ["tests/fixtures/cycle-602.txt"],
  "steps": [
    {"id": "s1", "description": "append progress lines",
     "files": ["tests/fixtures/cycle-602.txt"], "estimated_lines": 2}
  ]
}
EOF
cat > "$STATE_DIR/scope-manifest.md" <<'EOF'
+ tests/
+ plugins/
+ core/
EOF
STATE_FILE="$STATE_DIR/state.json"
printf '{"issue":$_ZB_ID,"branch":"feat/602"}' > "$STATE_FILE"

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
export MARK_FILE="$MARK_FILE"
export ZBUILD_STAGE_INPUTS="$STAGE_INPUTS_DRIVER"

load_template "$TEST_TEMP_DIR/template.yaml"
export ZBUILD_CURRENT_STAGE=build
build_stage_run "ignored" "$STATE_FILE"
EOF

bash "$DRIVER" >/dev/null 2>/dev/null || true

# Build-summary.json should record > 0 lines added — proof that progress
# survived across the 2-iter loop.
SUMMARY="$STATE_DIR/artifacts/build-summary.json"
if [[ ! -f "$SUMMARY" ]]; then
    assert_fail "build-summary.json present" "missing"
    print_test_results
    exit 1
fi

lines_added="$(jq -r '.lines_added' "$SUMMARY" 2>/dev/null || echo 0)"
files_changed_count="$(jq -r '.files_changed | length' "$SUMMARY" 2>/dev/null || echo 0)"
verdict="$(jq -r '.verdict' "$SUMMARY" 2>/dev/null || echo error)"

# lines_added must be >= 2 (one line per iter, 2 iters)
if [[ "$lines_added" =~ ^[0-9]+$ && "$lines_added" -ge 2 ]]; then
    assert_pass "build-summary.lines_added >= 2 (2-iter cycle, was: $lines_added)"
else
    assert_fail "build-summary.lines_added >= 2 (2-iter cycle)" \
        "got: $lines_added — work likely stashed and not popped"
fi

assert_eq "build-summary.files_changed has 1 file" "1" "$files_changed_count"
assert_eq "build-summary.verdict=pass" "pass" "$verdict"

# Absence-test: no apply_check field present.
has_ac="$(jq -r 'has("apply_check")' "$SUMMARY" 2>/dev/null || echo true)"
assert_eq "no apply_check field on summary (#602)" "false" "$has_ac"

# No build.apply_check.* events fired.
ac_events="$(jq -c 'select(.type | startswith("build.apply_check"))' \
    "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "zero build.apply_check.* events (#602)" "0" "$ac_events"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
