#!/usr/bin/env bash
# Integration test (#1329): build commit message reflects ALL inner route_to_model_loop
# iterations via _ROUTE_LOOP_ALL_RESPONSES (RS-delimited).
#
# Scenario: 3 inner iterations, each emitting a distinct COMMIT_SUMMARY.
# Expected: exactly one git commit whose subject = first iteration's COMMIT_SUMMARY
# and whose body bullets all three summaries.
#
# SPEC-1 (CHANGE): commit subject = first unique inner-iter COMMIT_SUMMARY
# SPEC-2 (CHANGE): commit body contains "- <summary>" bullet for each iter
# SPEC-3 (GUARD):  exactly one commit created (existing behavior preserved)
# SPEC-4 (CHANGE): commit body contains all 3 iteration summary bullets
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "build #1329: multi-inner-iter cumulative COMMIT_SUMMARY"
setup_test_env "build-1329-multi-inner-iter"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="build-1329-$$"
export ZBUILD_ISSUE="1329"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR/artifacts"

export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../plugins/agent/build/plugin.sh
source "$REPO_ROOT/plugins/agent/build/plugin.sh"

# ─── Real git repo ───────────────────────────────────────────────────────────
REPO="$TEST_TEMP_DIR/repo"
mkdir -p "$REPO"
(
    cd "$REPO"
    git init -q
    git config user.email t@t
    git config user.name t
    echo seed > seed.txt
    git add seed.txt
    git -c commit.gpgsign=false commit -q -m "M0 seed"
) >/dev/null

BASELINE="$(git -C "$REPO" rev-parse HEAD)"
printf '%s' "$BASELINE" > "$ZBUILD_STATE_DIR/intake-baseline-ref.txt"
PRE_HEAD="$BASELINE"

ART="$ZBUILD_STATE_DIR/artifacts"
mkdir -p "$ART"

# ─── Stubs ───────────────────────────────────────────────────────────────────
# shellcheck disable=SC2317
_route_loop_close_final_banner() { return 0; }
# shellcheck disable=SC2317
_route_resolve_max_iterations() { echo 1; }
# shellcheck disable=SC2317
apply_scope_redaction() {
    [[ -n "${1:-}" && -n "${2:-}" && -f "$1" ]] && cp -f "$1" "$2"
    return 0
}

# ─── Plan and scope ──────────────────────────────────────────────────────────
cat > "$ART/plan.json" <<'JSON'
{
    "title": "cumulative inner-loop commit message test",
    "files": ["target-file.txt"]
}
JSON

SCOPE_MANIFEST="$ZBUILD_STATE_DIR/scope-manifest.md"
printf '+ target-file.txt\n' > "$SCOPE_MANIFEST"

DIFF_PATCH="$ART/diff.patch"
SUMMARY_JSON="$ART/build-summary.json"

# ─── Stub route_to_model_loop: simulate 3 inner iterations ──────────────────
# Each iteration produces a distinct COMMIT_SUMMARY. The stub sets
# _ROUTE_LOOP_ALL_RESPONSES to the RS-delimited accumulation.
ITER1_RESP=$'did iter1 work\nCOMMIT_SUMMARY: add first feature\nmore prose'
ITER2_RESP=$'did iter2 work\nCOMMIT_SUMMARY: fix second bug\nmore prose'
ITER3_RESP=$'did iter3 work\nCOMMIT_SUMMARY: polish third item\nLOOP_COMPLETE'
RS=$'\x1e'
ALL_RESP="${ITER1_RESP}${RS}${ITER2_RESP}${RS}${ITER3_RESP}"

# shellcheck disable=SC2317
route_to_model_loop() {
    local _repo="$3"
    # Simulate the agent writing a file (so a commit is created).
    printf 'implementation\n' > "$_repo/target-file.txt"
    _ROUTE_LOOP_ITERATIONS=3
    _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
    _ROUTE_LOOP_INPUT_TOKENS=15
    _ROUTE_LOOP_OUTPUT_TOKENS=9
    _ROUTE_LOOP_LAST_RESPONSE="$ITER3_RESP"
    _ROUTE_LOOP_ALL_RESPONSES="$ALL_RESP"
    return 0
}

# ─── Run build ───────────────────────────────────────────────────────────────
(
    cd "$REPO"
    ZBUILD_CYCLE_ITER=1 _build_stage_run_inner \
        "$SCOPE_MANIFEST" "$ART/plan.json" \
        "$DIFF_PATCH" "$SUMMARY_JSON" "$ART"
) >/dev/null 2>&1 || true

# ─── Assertions ──────────────────────────────────────────────────────────────

# [SPEC-3] GUARD: exactly one commit created beyond baseline (existing behavior).
POST_HEAD="$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo 'no-head')"
if [[ "$POST_HEAD" != "$PRE_HEAD" ]]; then
    assert_pass "[SPEC-3] exactly one commit created (HEAD advanced beyond baseline)"
else
    assert_fail "[SPEC-3] exactly one commit created" "HEAD unchanged: $PRE_HEAD"
fi

# Verify only one new commit beyond baseline.
new_commit_count="$(git -C "$REPO" rev-list "${PRE_HEAD}..HEAD" --count 2>/dev/null || echo 0)"
if [[ "$new_commit_count" -eq 1 ]]; then
    assert_pass "[SPEC-3] exactly one new commit (count=$new_commit_count)"
else
    assert_fail "[SPEC-3] exactly one new commit" "got $new_commit_count commits"
fi

# Full commit message.
COMMIT_SUBJECT="$(git -C "$REPO" log -1 --format='%s' 2>/dev/null || echo '')"
COMMIT_BODY="$(git -C "$REPO" log -1 --format='%b' 2>/dev/null || echo '')"

# [SPEC-1] CHANGE: commit subject = first unique inner-iteration COMMIT_SUMMARY.
# Fails at baseline (old code uses LAST_RESPONSE → "polish third item").
assert_eq "[SPEC-1] commit subject = first unique inner-iter COMMIT_SUMMARY" \
    "add first feature" "$COMMIT_SUBJECT"

# [SPEC-2] CHANGE: commit body contains "- <summary>" bullet for iter 2.
# Fails at baseline (old code produces no body at all).
if printf '%s' "$COMMIT_BODY" | grep -q -- '- fix second bug'; then
    assert_pass "[SPEC-2] commit body contains bullet for iter 2 summary"
else
    assert_fail "[SPEC-2] commit body contains bullet for iter 2 summary" \
        "body: $(printf '%s' "$COMMIT_BODY" | head -10)"
fi

# [SPEC-4] CHANGE: commit body contains bullets for all 3 iteration summaries.
# Fails at baseline (old code produces no body).
bullet_count="$(printf '%s' "$COMMIT_BODY" | grep -c '^- ' 2>/dev/null || true)"
if [[ "$bullet_count" -eq 3 ]]; then
    assert_pass "[SPEC-4] commit body has 3 bullet lines (one per inner iter)"
else
    assert_fail "[SPEC-4] commit body has 3 bullet lines" \
        "got $bullet_count; body: $(printf '%s' "$COMMIT_BODY")"
fi

# Sanity: subject author
AUTHOR="$(git -C "$REPO" log -1 --format='%an <%ae>' 2>/dev/null || echo '')"
assert_eq "commit author is zbuild-pipeline" "zbuild-pipeline <pipeline@local>" "$AUTHOR"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
