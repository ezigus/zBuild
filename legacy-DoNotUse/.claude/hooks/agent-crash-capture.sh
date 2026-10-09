#!/usr/bin/env bash
# Hook: Capture diagnostics when a Skipper agent crashes
# Trigger: Post-tool-use on Bash failures that look like agent crashes

set -euo pipefail

# Read stdin for tool result context
INPUT="$(cat)"

# Check if this looks like an agent crash
if echo "$INPUT" | grep -qi "panic\|segfault\|killed\|oom\|fatal\|crash"; then
    TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
    CRASH_DIR="${HOME}/.shipwright/crash-reports"
    mkdir -p "$CRASH_DIR"

    REPORT_FILE="${CRASH_DIR}/crash_${TIMESTAMP}.json"

    # Capture diagnostics — use jq so all string fields are properly JSON-escaped
    local ts branch commit pipeline_state recent_commits
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    branch=$(git branch --show-current 2>/dev/null || echo 'unknown')
    commit=$(git rev-parse HEAD 2>/dev/null || echo 'unknown')
    pipeline_state=$(head -20 .claude/pipeline-state.md 2>/dev/null || echo 'none')
    recent_commits=$(git log --oneline -5 2>/dev/null || echo 'none')
    jq -n \
        --arg ts "$ts" \
        --arg wd "$(pwd)" \
        --arg branch "$branch" \
        --arg commit "$commit" \
        --arg ctx "${INPUT:0:2000}" \
        --arg state "$pipeline_state" \
        --arg commits "$recent_commits" \
        '{timestamp:$ts,working_directory:$wd,git_branch:$branch,git_commit:$commit,error_context:$ctx,pipeline_state:$state,recent_commits:$commits}' \
        > "$REPORT_FILE" 2>/dev/null || echo '{"error":"capture_failed"}' > "$REPORT_FILE"

    echo "Crash report saved to $REPORT_FILE" >&2
fi
