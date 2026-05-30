#!/usr/bin/env bash
# Tests: full Wave B pipeline integration — plan → build → test → review → pr-open
# Runs all 5 plugins sequentially against a fixture issue (#999) with mocked
# external dependencies. No live LLM, gh, or git apply calls.
export LC_ALL=C
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "Full Wave B pipeline integration — issue #999 fixture"
setup_test_env "full-pipeline"

# ─── Directory layout ────────────────────────────────────────────────────────
STATE_DIR="$TEST_TEMP_DIR/state"
ARTIFACTS_DIR="$STATE_DIR/artifacts"
EVENTS_DIR="$STATE_DIR/events"
BIN_DIR="$TEST_TEMP_DIR/bin"
STATE_FILE="$STATE_DIR/pipeline-state.json"

mkdir -p "$STATE_DIR" "$ARTIFACTS_DIR" "$EVENTS_DIR" "$BIN_DIR"

# ─── Wire event-bus to the test state dir ───────────────────────────────────
export ZBUILD_EVENTS_DIR="$EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_ISSUE=999
export ZBUILD_RUN_ID="full-pipeline-test-run-001"
export ZBUILD_GOAL="add a health check endpoint"
export ZBUILD_REPO_ROOT="$TEST_TEMP_DIR/repo"
export ZBUILD_TEST_CMD="true"
export NO_GITHUB=true

# Create a minimal fake repo for the test stage to copy+apply into
mkdir -p "$TEST_TEMP_DIR/repo/.git"

# ─── Scope manifest (non-empty — required by apply_scope_redaction) ──────────
SCOPE_MANIFEST="$STATE_DIR/scope-manifest.md"
cat > "$SCOPE_MANIFEST" <<'MANIFEST'
# Scope manifest for full-pipeline-test fixture
+ core/
+ plugins/
+ tests/fixtures/
MANIFEST

# ─── intake.md so plan_run can derive goal ───────────────────────────────────
printf '%s\n' "add a health check endpoint" > "$STATE_DIR/intake.md"

# ─── Source all 5 plugins ────────────────────────────────────────────────────
# Source order matters: later plugins source helpers/event-bus again (idempotent).
source "$REPO_ROOT/core/state/resume.sh"
source "$REPO_ROOT/plugins/agent/plan/plugin.sh"
source "$REPO_ROOT/plugins/agent/build/plugin.sh"
source "$REPO_ROOT/plugins/tool/test/plugin.sh"
source "$REPO_ROOT/plugins/agent/review/plugin.sh"
source "$REPO_ROOT/plugins/tool/pr-open/plugin.sh"

# ─── Init pipeline state ─────────────────────────────────────────────────────
init_state "$STATE_FILE" "$ZBUILD_RUN_ID" 999

# ─── Mock definitions ────────────────────────────────────────────────────────

# apply_scope_redaction: pass-through mock (avoids needing a full manifest parse)
apply_scope_redaction() {
    local input="$1"
    local output="$2"
    # Pass through content unchanged; emit the event route.sh checks for.
    cp "$input" "$output"
    emit_event "redaction.applied" \
        "input=$input" \
        "output=$output" \
        "size_before=0" \
        "size_after=0" \
        "redactions=0" \
        "scope_hash=mock" \
        "cycle=0"
    return 0
}

# Canned plan JSON
_PLAN_JSON='{"schema_version":1,"issue":999,"title":"fixture","goal":"add a health check endpoint","steps":[{"id":"step-1","description":"add /health route","files":["core/router/route.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}'

# Canned diff (build stage)
_BUILD_DIFF='diff --git a/tests/fixtures/health-check.txt b/tests/fixtures/health-check.txt
new file mode 100644
--- /dev/null
+++ b/tests/fixtures/health-check.txt
@@ -0,0 +1 @@
+ok'

# Canned review JSON
_REVIEW_JSON='{"verdict":"approve","confidence":0.95,"issues":[],"summary":"Diff implements the plan correctly."}'

# route_to_model: returns canned response per stage.
# Tests set _MOCK_STAGE before each stage's run call to select the response.
route_to_model() {
    local _tier="$1"  # unused in mock
    case "${_MOCK_STAGE:-}" in
        plan)    printf '%s\n' "$_PLAN_JSON" ;;
        build)   printf '%s\n' "$_BUILD_DIFF" ;;
        review)  printf '%s\n' "$_REVIEW_JSON" ;;
        bad_plan) printf '%s\n' 'not valid json at all {{{' ;;
        *)       printf '%s\n' "$_PLAN_JSON" ;;
    esac
    return 0
}

# #467: build now calls route_to_model_loop (ADR-018 Pattern 2). Mock it to
# terminate immediately on DONE so no per-iteration loop.iteration.error events
# fire (which would make the event golden environment-dependent on whether the
# CI default claude shim returns rc!=0).
route_to_model_loop() {
    _ROUTE_LOOP_ITERATIONS=1
    _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
    _ROUTE_LOOP_INPUT_TOKENS=0
    _ROUTE_LOOP_OUTPUT_TOKENS=0
    return 0
}

# Mock git binary in BIN_DIR — accepts all operations; branch returns the
# feature branch so pr-open does not hit the main/master safety check.
cat > "$BIN_DIR/git" <<'GITEOF'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse)
        if [[ "${2:-}" == "--abbrev-ref" ]]; then
            echo "zbuild/issue-999"
        elif [[ "${2:-}" == "--show-toplevel" ]]; then
            echo "/tmp/mock-repo"
        else
            echo "/tmp/mock-repo"
        fi
        ;;
    apply)   exit 0 ;;
    push)    exit 0 ;;
    checkout) exit 0 ;;
    -C)
        # git -C <dir> apply ...
        shift; shift
        exit 0
        ;;
    *)       echo "" ;;
esac
exit 0
GITEOF
chmod +x "$BIN_DIR/git"

# rsync mock — delegates to cp so the test stage repo-copy path works
cat > "$BIN_DIR/rsync" <<'RSYNCEOF'
#!/usr/bin/env bash
# rsync -a <src>/ <dst>/ — simplified as cp -r
src="${@: -2:1}"
dst="${@: -1}"
cp -r "$src/." "$dst/" 2>/dev/null || true
exit 0
RSYNCEOF
chmod +x "$BIN_DIR/rsync"

# Mock gh binary — captures args to $BIN_DIR/gh-calls.log; returns fake PR URL
GH_CALLS_LOG="$BIN_DIR/gh-calls.log"
cat > "$BIN_DIR/gh" <<GHEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GH_CALLS_LOG"
case "\${1:-}" in
    pr)
        case "\${2:-}" in
            create) echo "https://github.com/testuser/zbuild/pull/999" ;;
            *)      echo "" ;;
        esac
        ;;
    *) echo "" ;;
esac
exit 0
GHEOF
chmod +x "$BIN_DIR/gh"

# Prepend our mock bin dir to PATH (setup_test_env already prepended
# TEST_TEMP_DIR/bin; we need BIN_DIR which may be the same directory here,
# but be explicit for clarity).
export PATH="$BIN_DIR:$PATH"

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 1: Negative path — malformed plan response halts plan_run cleanly
# ─────────────────────────────────────────────────────────────────────────────
print_test_section "Negative path: malformed plan JSON"

_MOCK_STAGE="bad_plan"

set +e
plan_init
plan_run "plan" "$STATE_FILE"
_neg_rc=$?
set -e

assert_exit_code "plan_run returns non-zero on malformed LLM response" "1" "$_neg_rc"

# plan.json must NOT have been written by the bad run
assert_file_not_exists "plan.json absent after malformed plan" "$ARTIFACTS_DIR/plan.json"

# Reset mock stage for happy path
_MOCK_STAGE="plan"

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 2: Happy path — run all 5 stages in order
# ─────────────────────────────────────────────────────────────────────────────
print_test_section "Happy path: plan stage"

_MOCK_STAGE="plan"
plan_init
set +e
plan_run "plan" "$STATE_FILE"
_plan_rc=$?
set -e

assert_eq "plan_run exits 0" "0" "$_plan_rc"
assert_file_exists "plan.json artifact created" "$ARTIFACTS_DIR/plan.json"

if [[ -f "$ARTIFACTS_DIR/plan.json" ]]; then
    _plan_sv="$(jq -r '.schema_version // empty' "$ARTIFACTS_DIR/plan.json" 2>/dev/null || true)"
    assert_eq "plan.json schema_version==1" "1" "$_plan_sv"

    _plan_steps="$(jq '.steps | length' "$ARTIFACTS_DIR/plan.json" 2>/dev/null || echo 0)"
    assert_gt "plan.json steps non-empty" "$_plan_steps" "0"
else
    assert_fail "plan.json schema_version==1" "file missing"
    assert_fail "plan.json steps non-empty" "file missing"
fi

plan_finalize

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "Happy path: build stage"

_MOCK_STAGE="build"
build_stage_init
set +e
build_stage_run "build" "$STATE_FILE"
_build_rc=$?
set -e

assert_eq "build_stage_run exits 0" "0" "$_build_rc"
assert_file_exists "diff.patch artifact created" "$ARTIFACTS_DIR/diff.patch"
assert_file_exists "build-summary.json artifact created" "$ARTIFACTS_DIR/build-summary.json"

if [[ -f "$ARTIFACTS_DIR/build-summary.json" ]]; then
    set +e
    jq empty "$ARTIFACTS_DIR/build-summary.json" >/dev/null 2>&1
    _build_json_rc=$?
    set -e
    assert_eq "build-summary.json is valid JSON" "0" "$_build_json_rc"
else
    assert_fail "build-summary.json is valid JSON" "file missing"
fi

build_stage_finalize

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "Happy path: test stage"

# Provide an empty diff.patch so the test stage's git apply --allow-empty
# path is exercised and the mock git accepts it.
# diff.patch was already written by build_stage_run; the mock git always exits 0.

test_init
set +e
test_run "test" "$STATE_FILE"
_test_rc=$?
set -e

# test_run always returns 0; verdict is in the artifact
assert_eq "test_run exits 0 (verdict in artifact)" "0" "$_test_rc"
assert_file_exists "test-results.json artifact created" "$ARTIFACTS_DIR/test-results.json"

if [[ -f "$ARTIFACTS_DIR/test-results.json" ]]; then
    _test_verdict="$(jq -r '.verdict // empty' "$ARTIFACTS_DIR/test-results.json" 2>/dev/null || true)"
    case "${_test_verdict:-}" in
        pass|fail|error)
            assert_pass "test-results.json verdict is pass/fail/error (got: $_test_verdict)"
            ;;
        *)
            assert_fail "test-results.json verdict is pass/fail/error" "got: '${_test_verdict}'"
            ;;
    esac
else
    assert_fail "test-results.json verdict is pass/fail/error" "file missing"
fi

test_finalize

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "Happy path: review stage"

_MOCK_STAGE="review"
review_init
set +e
review_run "review" "$STATE_FILE"
_review_rc=$?
set -e

assert_eq "review_run exits 0" "0" "$_review_rc"
assert_file_exists "review.json artifact created" "$ARTIFACTS_DIR/review.json"

if [[ -f "$ARTIFACTS_DIR/review.json" ]]; then
    _review_verdict="$(jq -r '.verdict // empty' "$ARTIFACTS_DIR/review.json" 2>/dev/null || true)"
    case "${_review_verdict:-}" in
        approve|request_changes|block)
            assert_pass "review.json verdict is approve/request_changes/block (got: $_review_verdict)"
            ;;
        *)
            assert_fail "review.json verdict is approve/request_changes/block" "got: '${_review_verdict}'"
            ;;
    esac
else
    assert_fail "review.json verdict is approve/request_changes/block" "file missing"
fi

review_finalize

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "Happy path: pr-open stage"

pr_open_init
set +e
pr_open_run "pr" "$STATE_FILE"
_pr_rc=$?
set -e

assert_eq "pr_open_run exits 0" "0" "$_pr_rc"
assert_file_exists "pr-url.txt artifact created" "$ARTIFACTS_DIR/pr-url.txt"
assert_file_exists "pr-result.json artifact created" "$ARTIFACTS_DIR/pr-result.json"

if [[ -f "$ARTIFACTS_DIR/pr-url.txt" ]]; then
    _pr_url="$(cat "$ARTIFACTS_DIR/pr-url.txt" 2>/dev/null | tr -d '[:space:]')"
    if [[ -n "$_pr_url" ]]; then
        assert_pass "pr-url.txt is non-empty (got: $_pr_url)"
    else
        assert_fail "pr-url.txt is non-empty" "file is empty"
    fi
else
    assert_fail "pr-url.txt is non-empty" "file missing"
fi

if [[ -f "$ARTIFACTS_DIR/pr-result.json" ]]; then
    _pr_status="$(jq -r '.status // empty' "$ARTIFACTS_DIR/pr-result.json" 2>/dev/null || true)"
    assert_eq "pr-result.json status=opened" "opened" "$_pr_status"
else
    assert_fail "pr-result.json status=opened" "file missing"
fi

pr_open_finalize

# Assert gh pr create was called with --draft and Closes #999 in args
if [[ -f "$GH_CALLS_LOG" ]]; then
    _gh_call="$(cat "$GH_CALLS_LOG")"
    if printf '%s' "$_gh_call" | grep -q -- "--draft"; then
        assert_pass "gh pr create called with --draft flag"
    else
        assert_fail "gh pr create called with --draft flag" "log: $_gh_call"
    fi
    if printf '%s' "$_gh_call" | grep -q "Closes #999"; then
        assert_pass "gh pr create body contains Closes #999"
    else
        assert_fail "gh pr create body contains Closes #999" "log: $_gh_call"
    fi
else
    assert_fail "gh pr create called with --draft flag" "gh-calls.log not written"
    assert_fail "gh pr create body contains Closes #999" "gh-calls.log not written"
fi

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 3: Pipeline state assertions
# ─────────────────────────────────────────────────────────────────────────────
print_test_section "Pipeline state assertions"

if [[ -f "$STATE_FILE" ]]; then
    _state_run_id="$(jq -r '.run_id // empty' "$STATE_FILE" 2>/dev/null || true)"
    assert_eq "pipeline-state.json run_id matches" "$ZBUILD_RUN_ID" "$_state_run_id"

    _state_issue="$(jq -r '.issue // empty' "$STATE_FILE" 2>/dev/null || true)"
    assert_eq "pipeline-state.json issue==999" "999" "$_state_issue"

    _state_sv="$(jq -r '.schema_version // empty' "$STATE_FILE" 2>/dev/null || true)"
    assert_eq "pipeline-state.json schema_version==1" "1" "$_state_sv"
else
    assert_fail "pipeline-state.json run_id matches" "state file missing"
    assert_fail "pipeline-state.json issue==999" "state file missing"
    assert_fail "pipeline-state.json schema_version==1" "state file missing"
fi

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 4: Event sequence verification
# ─────────────────────────────────────────────────────────────────────────────
print_test_section "Event sequence verification"

# Set GOLDEN_DIR before sourcing so the library's default is overridden.
GOLDEN_DIR="$REPO_ROOT/tests/golden"
export GOLDEN_DIR
# shellcheck source=../../scripts/lib/golden.sh
source "$REPO_ROOT/scripts/lib/golden.sh"

if [[ -f "$ZBUILD_EVENTS_JSONL" ]]; then
    # Count plugin.run.complete events — expect at least one per stage (5 total)
    _complete_events="$(jq -r 'select(.type == "plugin.run.complete") | .type' \
        "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d '[:space:]')"
    assert_gt "at least 5 plugin.run.complete events in events.jsonl" \
        "$_complete_events" "4"

    # Verify each stage emitted at least one plugin.run.complete
    for _stage in plan build test review pr-open; do
        _stage_events="$(jq -r --arg s "$_stage" \
            'select(.type == "plugin.run.complete" and .plugin == $s) | .type' \
            "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d '[:space:]')"
        assert_gt "plugin.run.complete emitted for stage: $_stage" "$_stage_events" "0"
    done

    # Golden event-type sequence: strip non-deterministic fields (timestamps,
    # run_ids, sizes) and capture just the ordered event types.
    _normalized_events="$(jq -r '.type' "$ZBUILD_EVENTS_JSONL" 2>/dev/null \
        | grep -v '^$' || true)"

    set +e
    assert_golden "full-pipeline/event-sequence" "$_normalized_events"
    _golden_rc=$?
    set -e
    if [[ $_golden_rc -eq 0 ]]; then
        assert_pass "event type sequence matches golden"
    else
        assert_fail "event type sequence matches golden" \
            "run with UPDATE_GOLDEN=1 to regenerate tests/golden/full-pipeline/event-sequence.golden"
    fi
else
    assert_fail "events.jsonl exists for event verification" "file not found: $ZBUILD_EVENTS_JSONL"
fi

# ─────────────────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
