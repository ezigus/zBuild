#!/usr/bin/env bash
# Loop prompt template v2 — task-first structure.
# Activated by SHIPWRIGHT_PROMPT_V2=1. Default: off (uses existing template).
# All functions are pure: no side effects, no file writes, output to stdout.

# Renders the TASK header section — always the first thing in the prompt.
# Args: $1=goal_text $2=scope_label $3=max_iterations
render_task_header() {
    local goal="$1"
    local label="${2:-Build Iteration 1}"
    local max_iter="${3:-10}"
    cat <<TASK_HEADER
============================================================
 SHIPWRIGHT TASK — ${label} (max ${max_iter} iterations)
============================================================

YOUR GOAL FOR THIS ITERATION:
${goal}

WHEN COMPLETE, COMMIT ALL CHANGES AND OUTPUT EXACTLY: LOOP_COMPLETE
IF STUCK FOR 2+ ITERATIONS ON THE SAME PROBLEM, TRY A DIFFERENT APPROACH.

TASK_HEADER
}

# Renders the dynamic state section — changes each iteration.
# Args: $1=test_summary $2=git_log $3=quality_findings $4=dod_status
render_dynamic_state() {
    local test_summary="${1:-No previous test results}"
    local git_log="${2:-No recent commits}"
    local quality_findings="${3:-}"
    local dod_status="${4:-}"
    cat <<DYNAMIC
============================================================
 DYNAMIC STATE (changes every iteration)
============================================================

## Test Results (Previous Iteration)
${test_summary}

## Recent Git Activity
${git_log}
DYNAMIC

    if [[ -n "$quality_findings" ]]; then
        echo ""
        echo "## Quality-Gate Findings"
        echo "$quality_findings"
    fi

    if [[ -n "$dod_status" ]]; then
        echo ""
        echo "## Definition of Done (auto items only)"
        echo "$dod_status"
    fi
    echo ""
}

# Renders the static reference section — stable across iterations.
# Args: $1=artifacts_dir
render_static_reference() {
    local adir="${1:-.claude/pipeline-artifacts}"
    cat <<STATIC
============================================================
 STATIC REFERENCE (read on demand — do not re-read if already known)
============================================================

Pre-summarized above where relevant. Files available in workspace:
  - ${adir}/plan.md         — feature plan and implementation steps
  - ${adir}/design.md       — full ADR with interface contracts and edge cases
  - ${adir}/dod.md          — Definition of Done checklist
  - ${adir}/build-context.md — accumulated decisions from previous iterations

Do NOT re-read static reference unless dynamic state cites a specific section.
For wide repo searches: use targeted Grep → Read with offset/limit.

## Context Efficiency
- Batch independent tool calls in parallel — avoid sequential round-trips
- Use targeted file reads (offset/limit) instead of reading entire large files
- Delegate large searches to subagents — only import the summary
- Filter tool results with grep/jq before reasoning over them

## Rules
- Always commit with descriptive messages
- If stuck on the same issue for 2+ iterations, try a different approach
STATIC
}

# Renders design-stage key findings inline.
# Args: $1=artifacts_dir
render_design_findings() {
    local adir="${1:-.claude/pipeline-artifacts}"
    local findings_file="${adir}/design-findings.json"

    echo ""
    echo "============================================================"
    echo " DESIGN KEY FINDINGS (actionable issues from ADR)"
    echo "============================================================"
    echo ""

    if [[ ! -f "$findings_file" ]]; then
        echo "(no design findings recorded for this issue)"
        return 0
    fi

    local count
    count=$(jq 'length' "$findings_file" 2>/dev/null || echo 0)
    if [[ "$count" -eq 0 ]]; then
        echo "(no design findings recorded for this issue)"
        return 0
    fi

    # Render each finding with severity indicator
    jq -r '.[] | "  • [\(.severity // "info" | ascii_upcase)] \(.finding)" + if .file then " (\(.file)" + if .line then ":\(.line)" else "" end + ")" else "" end' \
        "$findings_file" 2>/dev/null | head -10
}
