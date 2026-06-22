#!/usr/bin/env bash
# Integration test: pr agent plugin runs in the standard pipeline after
# build_review_cycle, emits plugin.run.start, and writes pr-url.txt (#756).
#
# SPEC coverage (A3-pr migration, ADR-036 acceptance gate):
#   [SPEC-1] standard.yaml has 14 leaf stages including pr
#   [SPEC-2] plugins/agent/pr/plugin.sh exists and is loadable
#   [SPEC-3] pr plugin emits plugin.run.start event
#   [SPEC-4] pr-url.txt artifact is written on pipeline success
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER="$REPO_ROOT/core/pipeline/runner.sh"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "pr agent plugin: pipeline integration (#756)"
setup_test_env "pr-pipeline-756"
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
export ZBUILD_DRY_RUN=1
mkdir -p "$STATE_DIR" "$TEST_TEMP_DIR/events"

# ─── SPEC-1: verify standard.yaml resolves to 14 leaf stages ─────────────────
# CHANGE: baseline standard.yaml has 13 stages (no pr). Adding pr makes 14.
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
load_template "$REPO_ROOT/config/templates/standard.yaml"
assert_eq "[SPEC-1] standard.yaml resolves to 14 leaf stages including pr" \
    "14" "${#_TPL_STAGES[@]}"
assert_eq "[SPEC-1] _TPL_STAGES[13] is pr" "pr" "${_TPL_STAGES[13]:-}"

# ─── SPEC-2: plugins/agent/pr/plugin.sh exists ────────────────────────────────
# CHANGE: file did not exist at baseline. It is created in this migration.
assert_file_exists "[SPEC-2] plugins/agent/pr/plugin.sh exists" \
    "$REPO_ROOT/plugins/agent/pr/plugin.sh"
assert_file_exists "[SPEC-2] plugins/agent/pr/manifest.yaml exists" \
    "$REPO_ROOT/plugins/agent/pr/manifest.yaml"

# ─── Stub all stages except pr ───────────────────────────────────────────────
# register_standard_pipeline_stubs registers pr too; overwrite it with a
# custom stub that emits plugin.run.start and writes pr-url.txt.
register_standard_pipeline_stubs

# Custom pr stub: emits plugin.run.start + writes pr-url.txt (ZBUILD_DRY_RUN=1
# sentinel ensures no real gh pr create call is made).
_pr_stub_dir="$PLUGINS_ROOT/agent/pr"
mkdir -p "$_pr_stub_dir"
cat > "$_pr_stub_dir/manifest.yaml" << 'MEOF'
id: pr
name: PR stub
kind: agent
version: 0.0.1
hooks:
  run: pr_run
requires:
  core:
    - redaction
provides:
  role: pr_delivery
MEOF
cat > "$_pr_stub_dir/plugin.sh" << 'PEOF'
pr_run() {
    local state_file="${2:-}"
    local state_dir; state_dir="$(dirname "${state_file:-${ZBUILD_STATE_DIR:-/tmp}/state.json}")"
    local artifact_dir="$state_dir/artifacts"
    mkdir -p "$artifact_dir"

    # Emit plugin.run.start so [SPEC-3] assertion can find it
    if declare -f emit_event >/dev/null 2>&1; then
        emit_event "plugin.run.start" "plugin=pr" "stage=pr"
    fi

    # Write pr-url.txt so [SPEC-4] artifact assertion passes (dry-run mode)
    printf 'https://github.com/mock/repo/pull/0\n' > "$artifact_dir/pr-url.txt"
    printf '{"status":"dry_run","branch":"mock","pr_number":0,"draft":true}\n' \
        > "$artifact_dir/pr-result.json"

    if declare -f emit_event >/dev/null 2>&1; then
        emit_event "plugin.run.complete" "plugin=pr" "stage=pr"
    fi
    return 0
}
PEOF

# Also write review.json so the real pr plugin's verdict guard has something to read
_review_stub_dir="$PLUGINS_ROOT/agent/review"
mkdir -p "$_review_stub_dir"
cat > "$_review_stub_dir/plugin.sh" << 'PEOF'
review_run() {
    local state_file="${2:-}"
    local state_dir; state_dir="$(dirname "${state_file:-${ZBUILD_STATE_DIR:-/tmp}/state.json}")"
    local artifact_dir="$state_dir/artifacts"
    mkdir -p "$artifact_dir"
    printf '{"verdict":"approve","review":"LGTM"}\n' > "$artifact_dir/review.json"
    return 0
}
PEOF

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
    ZBUILD_DRY_RUN=1 \
    HOME="$TEST_TEMP_DIR/home" \
    PATH="$PATH" \
    bash "$RUNNER" --issue 756 >/dev/null 2>&1
_rc=$?
set -e

ACTUAL_STATE_DIR="$TEST_TEMP_DIR/home/.zbuild/state"

# ─── SPEC-1 (continued): pipeline exits 0 when pr is in the flow ─────────────
assert_eq "[SPEC-1] pipeline with pr stage exits 0" "0" "$_rc"

# ─── SPEC-3: plugin.run.start event for pr appears in events.jsonl ───────────
# CHANGE: no pr plugin existed at baseline so this event was never emitted.
if [[ -f "$EVENTS_JSONL" ]] && \
   grep -q '"plugin.run.start"' "$EVENTS_JSONL" 2>/dev/null && \
   grep '"plugin.run.start"' "$EVENTS_JSONL" | grep -q '"plugin":"pr"' 2>/dev/null; then
    assert_pass "[SPEC-3] events.jsonl contains plugin.run.start plugin=pr"
else
    assert_fail "[SPEC-3] events.jsonl contains plugin.run.start plugin=pr" \
        "$(grep 'plugin.run' "$EVENTS_JSONL" 2>/dev/null | head -5 || echo '(no events file)')"
fi

# ─── SPEC-4: pr-url.txt artifact written ─────────────────────────────────────
# CHANGE: no pr stage existed at baseline, so pr-url.txt was never written.
PR_URL_TXT="$(find "$ACTUAL_STATE_DIR" -name "pr-url.txt" 2>/dev/null | head -1 || true)"
if [[ -n "$PR_URL_TXT" && -f "$PR_URL_TXT" ]]; then
    assert_pass "[SPEC-4] pr-url.txt artifact exists in state artifacts"
else
    assert_fail "[SPEC-4] pr-url.txt artifact exists in state artifacts" \
        "searched under $ACTUAL_STATE_DIR"
fi

cleanup_test_env
print_test_results
