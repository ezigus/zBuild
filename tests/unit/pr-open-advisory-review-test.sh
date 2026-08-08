#!/usr/bin/env bash
# Tests: pr-open advisory review-report rendering in PR body (#1707)
# Covers: _pr_open_render_advisory_section + body assembly in advisory mode.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "pr-open: advisory review-report body rendering (#1707)"

setup_test_env "pr-open-advisory-review"

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
REVIEW_REPORT_JSON="$ARTIFACTS_DIR/review-report.json"
PR_RESULT_JSON="$ARTIFACTS_DIR/pr-result.json"
BODY_FILE="$TEST_TEMP_DIR/captured-body.txt"
export BODY_FILE  # must be exported so gh() sees it in subshells

mkdir -p "$ARTIFACTS_DIR"
printf '{"schema_version":1,"run_id":"test-run","issue":"999","stage_statuses":{}}\n' \
    > "$STATE_FILE"

# ─── Source plugin under test ─────────────────────────────────────────────────
PLUGIN_DIR="$REPO_ROOT/plugins/tool/pr-open"
# shellcheck source=../../plugins/tool/pr-open/plugin.sh
source "$PLUGIN_DIR/plugin.sh"

# ─── SPEC-1: advisory mode with findings → count + top bullets + no N/A ─────
print_test_section "SPEC-1: review-report.json with findings → body has count, top findings, no verdict N/A"

rm -f "$PR_RESULT_JSON" "$REVIEW_JSON" "$REVIEW_REPORT_JSON" "$BODY_FILE"
cat > "$REVIEW_REPORT_JSON" <<'JSON'
{
    "schema_version": 1,
    "merge_readiness": "advisory",
    "lenses": [{"name": "security", "score": 6, "findings": []}],
    "findings": [
        {
            "severity": "high",
            "file": "foo.sh",
            "lenses": ["security"],
            "messages": ["potential injection"]
        },
        {
            "severity": "medium",
            "file": "bar.sh",
            "lenses": ["correctness"],
            "messages": ["missing error check"]
        }
    ]
}
JSON

git() {
    if [[ "${1:-} ${2:-}" == "rev-parse --abbrev-ref" ]]; then
        echo "zbuild/issue-999"
    else
        return 0
    fi
}
export -f git
gh() {
    local capture_next=0
    local arg
    for arg in "$@"; do
        if [[ $capture_next -eq 1 ]]; then
            printf '%s' "$arg" > "$BODY_FILE"
            capture_next=0
        fi
        if [[ "$arg" == "--body" ]]; then
            capture_next=1
        fi
    done
    case "${1:-} ${2:-}" in
        "pr list") echo "" ;;
        *) echo "https://github.com/ezigus/zBuild/pull/999" ;;
    esac
    return 0
}
export -f gh

set +e
_pr_open_run_inner "$REVIEW_JSON" "$STATE_FILE" "$PR_RESULT_JSON" "999"
spec1_rc=$?
set -e
unset -f git gh

assert_exit_code "[SPEC-1] advisory mode with findings: rc=0" "0" "$spec1_rc"

if [[ -f "$BODY_FILE" ]]; then
    spec1_body="$(cat "$BODY_FILE")"
    assert_contains "[SPEC-1] body contains finding count" \
        "$spec1_body" "finding(s)"
    assert_contains "[SPEC-1] body contains severity indicator" \
        "$spec1_body" "[high]"
    assert_contains "[SPEC-1] body contains lens name" \
        "$spec1_body" "security"
    if grep -qF '**Review verdict:** N/A' <<< "$spec1_body" 2>/dev/null; then
        assert_fail "[SPEC-1] advisory mode: no misleading 'Review verdict: N/A'" \
            "body still contains 'Review verdict: N/A'"
    else
        assert_pass "[SPEC-1] advisory mode: no misleading 'Review verdict: N/A'"
    fi
else
    assert_fail "[SPEC-1] body captured from gh call" "BODY_FILE not written"
fi

# ─── SPEC-2: review.json present, no review-report.json → "no advisory review ran" ─
print_test_section "SPEC-2: review.json present, review-report.json absent → 'no advisory review ran' in body"

rm -f "$PR_RESULT_JSON" "$REVIEW_JSON" "$REVIEW_REPORT_JSON" "$BODY_FILE"
cat > "$REVIEW_JSON" <<'JSON'
{"schema_version":1,"verdict":"approve","summary":"looks good"}
JSON

git() {
    if [[ "${1:-} ${2:-}" == "rev-parse --abbrev-ref" ]]; then
        echo "zbuild/issue-999"
    else
        return 0
    fi
}
export -f git
gh() {
    local capture_next=0
    local arg
    for arg in "$@"; do
        if [[ $capture_next -eq 1 ]]; then
            printf '%s' "$arg" > "$BODY_FILE"
            capture_next=0
        fi
        if [[ "$arg" == "--body" ]]; then
            capture_next=1
        fi
    done
    case "${1:-} ${2:-}" in
        "pr list") echo "" ;;
        *) echo "https://github.com/ezigus/zBuild/pull/999" ;;
    esac
    return 0
}
export -f gh

set +e
_pr_open_run_inner "$REVIEW_JSON" "$STATE_FILE" "$PR_RESULT_JSON" "999"
spec2_rc=$?
set -e
unset -f git gh

assert_exit_code "[SPEC-2] review.json present, no report: rc=0" "0" "$spec2_rc"

if [[ -f "$BODY_FILE" ]]; then
    spec2_body="$(cat "$BODY_FILE")"
    assert_contains "[SPEC-2] body contains 'no advisory review ran'" \
        "$spec2_body" "no advisory review ran"
else
    assert_fail "[SPEC-2] body captured from gh call" "BODY_FILE not written"
fi

# ─── SPEC-3: advisory mode, findings=[] → "no findings" in body ──────────────
print_test_section "SPEC-3: review-report.json with findings=[] → 'no findings' in body"

rm -f "$PR_RESULT_JSON" "$REVIEW_JSON" "$REVIEW_REPORT_JSON" "$BODY_FILE"
cat > "$REVIEW_REPORT_JSON" <<'JSON'
{"schema_version":1,"merge_readiness":"advisory","lenses":[],"findings":[]}
JSON

git() {
    if [[ "${1:-} ${2:-}" == "rev-parse --abbrev-ref" ]]; then
        echo "zbuild/issue-999"
    else
        return 0
    fi
}
export -f git
gh() {
    local capture_next=0
    local arg
    for arg in "$@"; do
        if [[ $capture_next -eq 1 ]]; then
            printf '%s' "$arg" > "$BODY_FILE"
            capture_next=0
        fi
        if [[ "$arg" == "--body" ]]; then
            capture_next=1
        fi
    done
    case "${1:-} ${2:-}" in
        "pr list") echo "" ;;
        *) echo "https://github.com/ezigus/zBuild/pull/999" ;;
    esac
    return 0
}
export -f gh

set +e
_pr_open_run_inner "$REVIEW_JSON" "$STATE_FILE" "$PR_RESULT_JSON" "999"
spec3_rc=$?
set -e
unset -f git gh

assert_exit_code "[SPEC-3] advisory mode, no findings: rc=0" "0" "$spec3_rc"

if [[ -f "$BODY_FILE" ]]; then
    spec3_body="$(cat "$BODY_FILE")"
    assert_contains "[SPEC-3] body contains 'no findings'" \
        "$spec3_body" "no findings"
else
    assert_fail "[SPEC-3] body captured from gh call" "BODY_FILE not written"
fi

# ─── SPEC-4: high-severity advisory finding → rc=0, PR opens (ADR-040 guard) ─
print_test_section "SPEC-4: high-severity advisory finding → rc=0 (ADR-040: advisory never blocks)"

rm -f "$PR_RESULT_JSON" "$REVIEW_JSON" "$REVIEW_REPORT_JSON" "$BODY_FILE"
cat > "$REVIEW_REPORT_JSON" <<'JSON'
{
    "schema_version": 1,
    "merge_readiness": "advisory",
    "lenses": [{"name": "security", "score": 3, "findings": []}],
    "findings": [
        {
            "severity": "high",
            "file": "plugin.sh",
            "lenses": ["security"],
            "messages": ["high severity advisory finding"]
        }
    ]
}
JSON

git() {
    if [[ "${1:-} ${2:-}" == "rev-parse --abbrev-ref" ]]; then
        echo "zbuild/issue-999"
    else
        return 0
    fi
}
export -f git
gh() {
    local capture_next=0
    local arg
    for arg in "$@"; do
        if [[ $capture_next -eq 1 ]]; then
            printf '%s' "$arg" > "$BODY_FILE"
            capture_next=0
        fi
        if [[ "$arg" == "--body" ]]; then
            capture_next=1
        fi
    done
    case "${1:-} ${2:-}" in
        "pr list") echo "" ;;
        *) echo "https://github.com/ezigus/zBuild/pull/999" ;;
    esac
    return 0
}
export -f gh

set +e
_pr_open_run_inner "$REVIEW_JSON" "$STATE_FILE" "$PR_RESULT_JSON" "999"
spec4_rc=$?
set -e
unset -f git gh

assert_exit_code "[SPEC-4] high-severity advisory finding: rc=0 (not blocked)" "0" "$spec4_rc"

if [[ -f "$BODY_FILE" ]]; then
    spec4_body="$(cat "$BODY_FILE")"
    assert_contains "[SPEC-4] body contains finding count (advisory section rendered)" \
        "$spec4_body" "finding(s)"
else
    assert_fail "[SPEC-4] body captured from gh call" "BODY_FILE not written"
fi

# ─── Teardown ─────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
exit $((FAIL > 0))
