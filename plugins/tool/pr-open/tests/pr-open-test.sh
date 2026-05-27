#!/usr/bin/env bash
# Tests: plugins/tool/pr-open — draft PR opening, safety guards (issue #344)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugin: pr-open (draft PR, safety guards — issue #344)"

setup_test_env "plugin-pr-open"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

# ─── State and artifact setup ─────────────────────────────────────────────────
STATE_DIR="$TEST_TEMP_DIR/state"
ARTIFACTS_DIR="$STATE_DIR/artifacts"
STATE_FILE="$STATE_DIR/pipeline-state.json"
REVIEW_JSON="$ARTIFACTS_DIR/review.json"
PR_RESULT_JSON="$ARTIFACTS_DIR/pr-result.json"

mkdir -p "$ARTIFACTS_DIR"
echo '{"schema_version":1,"run_id":"test-run","issue":"999","stage_statuses":{}}' > "$STATE_FILE"

# ─── Source plugin under test ─────────────────────────────────────────────────
PLUGIN_DIR="$REPO_ROOT/plugins/tool/pr-open"
# shellcheck source=../../../../plugins/tool/pr-open/plugin.sh
source "$PLUGIN_DIR/plugin.sh"

# ─── Test 1: pr_open_init sets env vars ──────────────────────────────────────
print_test_section "1. pr_open_init sets ZBUILD_PLUGIN env vars"

pr_open_init >/dev/null 2>&1

assert_eq "pr_open_init sets ZBUILD_PLUGIN=pr-open" "pr-open" "$ZBUILD_PLUGIN"
assert_eq "pr_open_init sets ZBUILD_PLUGIN_KIND=tool" "tool" "$ZBUILD_PLUGIN_KIND"

# ─── Test 2: blocked when review verdict=block ───────────────────────────────
print_test_section "2. Blocked when review verdict is 'block'"

rm -f "$PR_RESULT_JSON"
cat > "$REVIEW_JSON" <<'JSON'
{"schema_version":1,"verdict":"block","summary":"critical issues found"}
JSON

# Mock git to return a safe non-main branch so we reach the verdict check
git() {
    if [[ "${1:-} ${2:-}" == "rev-parse --abbrev-ref" ]]; then
        echo "zbuild/issue-999"
    else
        command git "$@"
    fi
}
export -f git

set +e
_pr_open_run_inner "$REVIEW_JSON" "$STATE_FILE" "$PR_RESULT_JSON" "999"
rc=$?
set -e

assert_exit_code "blocked verdict returns rc=2" "2" "$rc"
assert_file_exists "pr-result.json written on block" "$PR_RESULT_JSON"

if [[ -f "$PR_RESULT_JSON" ]]; then
    pr_status="$(jq -r '.status' "$PR_RESULT_JSON" 2>/dev/null || echo "")"
    assert_eq "pr-result.json status=blocked" "blocked" "$pr_status"
fi

unset -f git

# ─── Test 2b: blocked when review.json is missing (fail-closed, #358) ───────
print_test_section "2b. Blocked when review.json is missing (fail-closed per ADR-001)"

rm -f "$PR_RESULT_JSON"
rm -f "$REVIEW_JSON"

# Mock git to return a safe non-main branch so we reach the review.json check
git() {
    if [[ "${1:-} ${2:-}" == "rev-parse --abbrev-ref" ]]; then
        echo "zbuild/issue-999"
    else
        command git "$@"
    fi
}
export -f git

set +e
_pr_open_run_inner "$REVIEW_JSON" "$STATE_FILE" "$PR_RESULT_JSON" "999"
rc=$?
set -e

assert_exit_code "missing review.json returns rc=2" "2" "$rc"
assert_file_exists "pr-result.json written when review.json missing" "$PR_RESULT_JSON"

if [[ -f "$PR_RESULT_JSON" ]]; then
    pr_status="$(jq -r '.status' "$PR_RESULT_JSON" 2>/dev/null || echo "")"
    assert_eq "pr-result.json status=blocked when review.json missing" "blocked" "$pr_status"
    pr_reason="$(jq -r '.reason' "$PR_RESULT_JSON" 2>/dev/null || echo "")"
    if [[ "$pr_reason" == *"missing"* ]]; then
        assert_pass "pr-result.json reason contains 'missing'"
    else
        assert_fail "pr-result.json reason contains 'missing'" "reason was: $pr_reason"
    fi
fi

unset -f git

# ─── Test 3: blocked if current branch is main ───────────────────────────────
print_test_section "3. Blocked when current branch is main"

rm -f "$PR_RESULT_JSON"
# Write a passing review so the branch check is the only gate
cat > "$REVIEW_JSON" <<'JSON'
{"schema_version":1,"verdict":"approve","summary":"looks good"}
JSON

# Mock git to return "main" as current branch
git() {
    if [[ "${1:-} ${2:-}" == "rev-parse --abbrev-ref" ]]; then
        echo "main"
    else
        command git "$@"
    fi
}
export -f git

set +e
_pr_open_run_inner "$REVIEW_JSON" "$STATE_FILE" "$PR_RESULT_JSON" "999"
rc=$?
set -e

assert_exit_code "main branch returns rc=2" "2" "$rc"
assert_file_exists "pr-result.json written for main branch guard" "$PR_RESULT_JSON"

if [[ -f "$PR_RESULT_JSON" ]]; then
    pr_status="$(jq -r '.status' "$PR_RESULT_JSON" 2>/dev/null || echo "")"
    assert_eq "pr-result.json status=error for main branch" "error" "$pr_status"
fi

unset -f git

# ─── Test 4: successful PR open ──────────────────────────────────────────────
print_test_section "4. Successful PR open with mocked git and gh"

rm -f "$PR_RESULT_JSON"
cat > "$REVIEW_JSON" <<'JSON'
{"schema_version":1,"verdict":"approve","summary":"looks good"}
JSON

# Mock git: returns safe branch name, silently accepts checkout
git() {
    if [[ "${1:-} ${2:-}" == "rev-parse --abbrev-ref" ]]; then
        echo "zbuild/issue-999"
    else
        # Silently accept checkout and other git commands
        return 0
    fi
}
export -f git

# Mock gh: returns a fake PR URL
gh() {
    echo "https://github.com/ezigus/zBuild/pull/999"
    return 0
}
export -f gh

set +e
_pr_open_run_inner "$REVIEW_JSON" "$STATE_FILE" "$PR_RESULT_JSON" "999"
rc=$?
set -e

assert_exit_code "successful PR open returns rc=0" "0" "$rc"
assert_file_exists "pr-result.json written on success" "$PR_RESULT_JSON"
assert_file_exists "pr-url.txt written on success (ADR-013 canonical)" \
    "$(dirname "$PR_RESULT_JSON")/pr-url.txt"

if [[ -f "$PR_RESULT_JSON" ]]; then
    pr_result_json="$(cat "$PR_RESULT_JSON")"
    assert_json_key "pr-result.json status=opened" "$pr_result_json" '.status' "opened"
    pr_url="$(jq -r '.pr_url' "$PR_RESULT_JSON" 2>/dev/null || echo "")"
    if [[ -n "$pr_url" && "$pr_url" != "null" ]]; then
        assert_pass "pr-result.json pr_url is non-empty"
    else
        assert_fail "pr-result.json pr_url is non-empty" "pr_url was empty or null"
    fi
    assert_json_key "pr-result.json draft=true" "$pr_result_json" '.draft' "true"
    assert_json_key "pr-result.json branch=zbuild/issue-999" "$pr_result_json" '.branch' "zbuild/issue-999"
fi

unset -f git
unset -f gh

# ─── Test 5: pr_open_finalize runs cleanly ───────────────────────────────────
print_test_section "5. pr_open_finalize runs cleanly"

set +e
pr_open_finalize >/dev/null 2>&1
rc=$?
set -e

assert_exit_code "pr_open_finalize returns rc=0" "0" "$rc"

# ─── Test 6: pr_open_cleanup runs cleanly ────────────────────────────────────
print_test_section "6. pr_open_cleanup runs cleanly"

set +e
pr_open_cleanup >/dev/null 2>&1
rc=$?
set -e

assert_exit_code "pr_open_cleanup returns rc=0" "0" "$rc"

# ─── Test 7: redaction chokepoint regression guard (issue #360) ──────────────
# Per ADR-004 every LLM-bound prompt must pass through apply_scope_redaction.
# pr-open is a T0 tool: it builds a PR body from on-disk artifacts and shells
# out to `gh`. It MUST NOT call route_to_model or emit `model.route` events.
#
# FINDING (issue #360): pr-open does not currently invoke the chokepoint
# because it has no LLM call. That is the correct design for a T0 tool. The
# safety risk is that someone could *add* an LLM call to this plugin later
# (e.g. "use Claude to summarize the diff in the PR body") without routing
# the prompt through apply_scope_redaction. This section catches that
# regression by asserting no model.route event was emitted across all the
# successful runs above. If a future change adds an LLM call without
# redaction, this assertion fails and forces the author to either:
#   (a) route through apply_scope_redaction first, OR
#   (b) keep pr-open T0 and move the LLM work to a different plugin.
print_test_section "7. pr-open is T0: no model.route without redaction (issue #360)"

if [[ -f "$ZBUILD_EVENTS_JSONL" ]]; then
    model_route_count="$(jq -c 'select(.type == "model.route" and .plugin == "pr-open")' \
        "$ZBUILD_EVENTS_JSONL" 2>/dev/null | grep -c . || true)"
    if [[ "$model_route_count" -eq 0 ]]; then
        assert_pass "no model.route events from pr-open (T0 invariant holds)"
    else
        assert_fail "pr-open emitted $model_route_count model.route event(s) — must redact first per ADR-004"
    fi

    # If a future change ever emits a model.route from pr-open, mirror the
    # router's C6 precondition (core/router/route.sh): the most recent event
    # for that run_id, at the moment of the model.route, must be
    # redaction.applied. A bare "any redaction.applied in the same run" check
    # is too loose — a stale redaction from an earlier plugin invocation, or
    # a route ordered *before* its redaction, would falsely pass it
    # (Copilot review on PR #376).
    #
    # Algorithm: walk events.jsonl in order. For every model.route with
    # plugin=pr-open, the immediately-preceding event for the same run_id
    # must be type=redaction.applied. Otherwise the route is unredacted.
    unredacted="$(jq -rs '
        # Per-run last-event-type tracker, then count pr-open model.routes
        # whose preceding event for their run_id was not redaction.applied.
        reduce .[] as $e (
            {last: {}, bad: 0};
            if ($e.type == "model.route" and $e.plugin == "pr-open") then
                .bad += (if (.last[$e.run_id] // "") == "redaction.applied" then 0 else 1 end)
                | .last[$e.run_id] = $e.type
            else
                .last[$e.run_id] = $e.type
            end
        ) | .bad
    ' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || echo 0)"

    if [[ "${unredacted:-0}" -eq 0 ]]; then
        # Either no pr-open model.route events exist (vacuously true today),
        # or every one was immediately preceded by redaction.applied for the
        # same run_id — matching the router's C6 invariant exactly.
        assert_pass "ADR-004 invariant: every pr-open model.route immediately preceded by redaction.applied (same run_id)"
    else
        assert_fail "$unredacted pr-open model.route event(s) not immediately preceded by redaction.applied for same run_id"
    fi
else
    assert_fail "redaction chokepoint guard: events.jsonl not found"
fi

# ─── Teardown ─────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
exit $((FAIL > 0))
