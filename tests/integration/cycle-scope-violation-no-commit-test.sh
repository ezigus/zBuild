#!/usr/bin/env bash
# Integration test (#608): when verdict=scope_violation, the build stage MUST
# NOT commit. It emits build.commit.skipped reason=scope_violation instead.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "build #608: scope_violation → no commit"
setup_test_env "build-608-scope-noviolation"

# #1921 follow-up: reserved test identity — the QUOTED assignment form.
# These were real issue numbers used as run identity.
_ZB_ID="$(zb_test_issue)"

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="build-608-sv-$$"
export ZBUILD_ISSUE="$_ZB_ID"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR/artifacts/stage-io"

export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

REPO="$(setup_git_temp_repo build608sv)"
mkdir -p "$REPO/tests/fixtures"
( cd "$REPO" \
    && echo "seed" > tests/fixtures/seed.txt \
    && git add tests/fixtures/seed.txt \
    && git commit -q -m "seed" ) >/dev/null

PRE_HEAD="$(cd "$REPO" && git rev-parse HEAD)"

# Stub claude: edit OUT-OF-SCOPE file → scope violation
mkdir -p "$TEST_TEMP_DIR/bin"
cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
# Out-of-scope: plan allows tests/fixtures/in-scope.txt but we touch a different path
mkdir -p "$PWD/src"
printf 'out of scope content\n' > "$PWD/src/oops.txt"
jq -n --arg r $'wrote a forbidden file\nCOMMIT_SUMMARY: should not commit\nLOOP_COMPLETE' \
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
STATE_FILE="$STATE_DIR/state.json"
printf '{"issue":$_ZB_ID,"branch":"feat/608"}' > "$STATE_FILE"

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
build_stage_run "ignored" "$STATE_FILE"
EOF

bash "$DRIVER" >/dev/null 2>/dev/null || true

# ── (1) HEAD did NOT advance ───────────────────────────────────────────────
POST_HEAD="$(cd "$REPO" && git rev-parse HEAD)"
assert_eq "HEAD unchanged on scope_violation" "$PRE_HEAD" "$POST_HEAD"

# ── (2) build.commit.skipped event with reason=scope_violation ─────────────
if [[ -f "$ZBUILD_EVENTS_JSONL" ]] && grep -q '"type":"build.commit.skipped"' "$ZBUILD_EVENTS_JSONL"; then
    REASON="$(jq -r 'select(.type=="build.commit.skipped") | .data.reason' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | tail -1)"
    assert_eq "skipped reason=scope_violation" "scope_violation" "$REASON"
else
    assert_fail "build.commit.skipped event emitted" "event missing"
fi

# ── (3) No build.commit.created event ──────────────────────────────────────
if [[ -f "$ZBUILD_EVENTS_JSONL" ]] && grep -q '"type":"build.commit.created"' "$ZBUILD_EVENTS_JSONL"; then
    assert_fail "no build.commit.created on scope_violation" "commit event present"
else
    assert_pass "no build.commit.created on scope_violation"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
