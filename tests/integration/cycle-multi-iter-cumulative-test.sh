#!/usr/bin/env bash
# Integration test (#608): two consecutive build_stage_run invocations (simulating
# two cycle iterations) produce two commits, both authored by the pipeline.
# The log shows both COMMIT_SUMMARY values in order.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "build #608: multi-iter cycle → cumulative pipeline commits"
setup_test_env "build-608-multi-iter"

# #1921 follow-up: reserved test identity — the QUOTED assignment form.
# These were real issue numbers used as run identity.
_ZB_ID="$(zb_test_issue)"

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="build-608-mi-$$"
export ZBUILD_ISSUE="$_ZB_ID"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR/artifacts/stage-io"

export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

REPO="$(setup_git_temp_repo build608mi)"
mkdir -p "$REPO/tests/fixtures"
( cd "$REPO" \
    && echo "seed" > tests/fixtures/seed.txt \
    && git add tests/fixtures/seed.txt \
    && git commit -q -m "seed" ) >/dev/null

PRE_HEAD="$(cd "$REPO" && git rev-parse HEAD)"

# Stub claude reads the file ITER_FILE to know which iteration's payload to emit.
mkdir -p "$TEST_TEMP_DIR/bin"
ITER_FILE="$TEST_TEMP_DIR/iter-counter"
echo 0 > "$ITER_FILE"
cat > "$TEST_TEMP_DIR/bin/claude" <<MOCK
#!/usr/bin/env bash
n=\$(cat "$ITER_FILE")
n=\$(( n + 1 ))
echo "\$n" > "$ITER_FILE"
mkdir -p "\$PWD/tests/fixtures"
printf 'iter-%d\n' "\$n" >> "\$PWD/tests/fixtures/build-608-mi.txt"
jq -n --arg r "iter \$n wrote
COMMIT_SUMMARY: iter \$n change
LOOP_COMPLETE" '{result:\$r, usage:{input_tokens:5, output_tokens:5}}'
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
  "title": "multi-iter plan",
  "goal": "multi iter",
  "files": ["tests/fixtures/build-608-mi.txt"],
  "steps": [{"id":"s1","description":"d","files":["tests/fixtures/build-608-mi.txt"],"estimated_lines":1}]
}
EOF
cat > "$STATE_DIR/scope-manifest.md" <<'EOF'
+ tests/
EOF
STATE_FILE="$STATE_DIR/state.json"
printf '{"issue":$_ZB_ID,"branch":"feat/608"}' > "$STATE_FILE"

STAGE_INPUTS_DRIVER="$TEST_TEMP_DIR/stage-inputs-driver.json"
jq -n \
    --arg sm "$STATE_DIR/scope-manifest.md" \
    --arg pl "$STATE_DIR/artifacts/plan.json" \
    '{"schema_version":1,"stage":"build","inputs":{"scope_manifest":$sm,"plan":$pl}}' \
    > "$STAGE_INPUTS_DRIVER"

# Run build twice — once per simulated cycle iteration. Each invocation
# should produce one pipeline commit.
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

export ZBUILD_CYCLE_ITER=1
build_stage_run "ignored" "$STATE_FILE"
export ZBUILD_CYCLE_ITER=2
build_stage_run "ignored" "$STATE_FILE"
EOF

bash "$DRIVER" >/dev/null 2>/dev/null || true

# ── (1) HEAD advanced by exactly 2 commits ─────────────────────────────────
COMMITS_SINCE="$(cd "$REPO" && git rev-list --count "$PRE_HEAD..HEAD" 2>/dev/null || echo 0)"
assert_eq "two commits since seed" "2" "$COMMITS_SINCE"

# ── (2) Both authored by pipeline ──────────────────────────────────────────
AUTHORS="$(cd "$REPO" && git log "$PRE_HEAD..HEAD" --format='%an <%ae>' 2>/dev/null | sort -u)"
assert_eq "both commits authored by zbuild-pipeline" "zbuild-pipeline <pipeline@local>" "$AUTHORS"

# ── (3) Subjects are the two COMMIT_SUMMARYs in order ──────────────────────
SUBJ_NEW="$(cd "$REPO" && git log -1 --format='%s' HEAD 2>/dev/null)"
SUBJ_OLD="$(cd "$REPO" && git log -1 --format='%s' "HEAD~1" 2>/dev/null)"
assert_eq "iter 1 commit subject" "iter 1 change" "$SUBJ_OLD"
assert_eq "iter 2 commit subject" "iter 2 change" "$SUBJ_NEW"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
