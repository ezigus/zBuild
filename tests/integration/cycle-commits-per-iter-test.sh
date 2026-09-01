#!/usr/bin/env bash
# Integration test (#608): build stage commits LLM's work after the loop
# completes, using the COMMIT_SUMMARY marker for the message.
#
# Assert:
#   - HEAD advanced (commit was created)
#   - commit author = "zbuild-pipeline <pipeline@local>"
#   - commit subject = the COMMIT_SUMMARY the stub emitted
#   - working tree clean post-commit (no untracked in-scope files)
#   - build.commit.created event emitted with sha + iter
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "build #608: per-iter commit happy path with COMMIT_SUMMARY"
setup_test_env "build-608-commit"

# #1921 follow-up: reserved test identity — the QUOTED assignment form.
# These were real issue numbers used as run identity.
_ZB_ID="$(zb_test_issue)"

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="build-608-$$"
export ZBUILD_ISSUE="$_ZB_ID"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR/artifacts/stage-io"

export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

REPO="$(setup_git_temp_repo build608repo)"
[[ -d "$REPO" ]] || { echo "setup_git_temp_repo failed" >&2; exit 1; }
mkdir -p "$REPO/tests/fixtures"
( cd "$REPO" \
    && echo "seed" > tests/fixtures/seed.txt \
    && git add tests/fixtures/seed.txt \
    && git commit -q -m "seed" ) >/dev/null

PRE_HEAD="$(cd "$REPO" && git rev-parse HEAD)"

# Stub claude: edit in scope, emit COMMIT_SUMMARY, then LOOP_COMPLETE.
cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
mkdir -p "$PWD/tests/fixtures"
printf 'iter1\n' > "$PWD/tests/fixtures/build-608-newfile.txt"
jq -n --arg r $'wrote file\nCOMMIT_SUMMARY: add 608 fixture file\nLOOP_COMPLETE' \
    '{result:$r, usage:{input_tokens:5, output_tokens:5}}'
exit 0
MOCK
mkdir -p "$TEST_TEMP_DIR/bin"
chmod +x "$TEST_TEMP_DIR/bin/claude" || true
# Fix: ensure file is executable even if mkdir reordered
cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
mkdir -p "$PWD/tests/fixtures"
printf 'iter1\n' > "$PWD/tests/fixtures/build-608-newfile.txt"
jq -n --arg r $'wrote file\nCOMMIT_SUMMARY: add 608 fixture file\nLOOP_COMPLETE' \
    '{result:$r, usage:{input_tokens:5, output_tokens:5}}'
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
export PATH="$TEST_TEMP_DIR/bin:$PATH"

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
  "title": "fallback plan title",
  "goal": "Create fixture (#608)",
  "files": ["tests/fixtures/build-608-newfile.txt"],
  "steps": [
    {"id": "s1", "description": "create file",
     "files": ["tests/fixtures/build-608-newfile.txt"], "estimated_lines": 1}
  ]
}
EOF
cat > "$STATE_DIR/scope-manifest.md" <<'EOF'
+ tests/
+ plugins/
+ core/
EOF
STATE_FILE="$STATE_DIR/state.json"
printf '{"issue":$_ZB_ID,"branch":"feat/608"}' > "$STATE_FILE"

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

load_template "$TEST_TEMP_DIR/template.yaml"
export ZBUILD_CURRENT_STAGE=build
build_stage_run "ignored" "$STATE_FILE"
EOF

bash "$DRIVER" >/dev/null 2>/dev/null || true

# ── (1) HEAD advanced ──────────────────────────────────────────────────────
POST_HEAD="$(cd "$REPO" && git rev-parse HEAD)"
if [[ "$POST_HEAD" != "$PRE_HEAD" ]]; then
    assert_pass "HEAD advanced after build (new commit created)"
else
    assert_fail "HEAD advanced after build" "HEAD unchanged: $PRE_HEAD"
fi

# ── (2) Commit author is the pipeline ──────────────────────────────────────
AUTHOR="$(cd "$REPO" && git log -1 --format='%an <%ae>' 2>/dev/null || echo '')"
assert_eq "commit author is zbuild-pipeline" "zbuild-pipeline <pipeline@local>" "$AUTHOR"

# ── (3) Commit subject matches COMMIT_SUMMARY ──────────────────────────────
SUBJECT="$(cd "$REPO" && git log -1 --format='%s' 2>/dev/null || echo '')"
assert_eq "commit subject = COMMIT_SUMMARY value" "add 608 fixture file" "$SUBJECT"

# ── (4) Working tree clean (file committed, not untracked) ─────────────────
DIRTY="$(cd "$REPO" && git status --porcelain 2>/dev/null || echo 'fail')"
assert_eq "working tree clean post-commit" "" "$DIRTY"

# ── (5) build.commit.created event emitted ─────────────────────────────────
if [[ -f "$ZBUILD_EVENTS_JSONL" ]] && grep -q '"type":"build.commit.created"' "$ZBUILD_EVENTS_JSONL"; then
    assert_pass "build.commit.created event present"
    SHA_IN_EVT="$(jq -r 'select(.type=="build.commit.created") | .data.sha' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | tail -1)"
    assert_eq "event sha matches HEAD" "$POST_HEAD" "$SHA_IN_EVT"
else
    assert_fail "build.commit.created event present" "event missing from $ZBUILD_EVENTS_JSONL"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
