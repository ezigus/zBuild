#!/usr/bin/env bash
# shellcheck disable=SC2034  # config vars used by sourced scripts and subshells
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright pipeline — Autonomous Feature Delivery (Idea → Production)        ║
# ║  Full GitHub integration · Auto-detection · Task tracking · Metrics    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

# Allow spawning Claude CLI from within a Claude Code session (daemon, fleet, etc.)
unset CLAUDECODE 2>/dev/null || true
# Ignore SIGHUP so tmux attach/detach doesn't kill long-running plan/design/review stages
trap '' HUP
trap '' SIGPIPE
# Prevent git from blocking on HTTPS credential prompts in any pipeline stage
export GIT_TERMINAL_PROMPT=0

VERSION="3.6.1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"
# Canonical helpers (colors, output, events)
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
[[ -f "$SCRIPT_DIR/lib/config.sh" ]] && source "$SCRIPT_DIR/lib/config.sh"
# Fallbacks when helpers not loaded (e.g. test env with overridden SCRIPT_DIR)
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
  now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
  now_epoch() { date +%s; }
fi
# Color variable fallbacks (defined by lib/helpers.sh; set empty if not loaded)
: "${CYAN:=}"
: "${PURPLE:=}"
: "${BLUE:=}"
: "${GREEN:=}"
: "${YELLOW:=}"
: "${RED:=}"
: "${DIM:=}"
: "${BOLD:=}"
: "${RESET:=}"
# Policy + pipeline quality thresholds (config/policy.json via lib/pipeline-quality.sh)
[[ -f "$SCRIPT_DIR/lib/pipeline-quality.sh" ]] && source "$SCRIPT_DIR/lib/pipeline-quality.sh"
# shellcheck source=lib/pipeline-state.sh
[[ -f "$SCRIPT_DIR/lib/pipeline-state.sh" ]] && source "$SCRIPT_DIR/lib/pipeline-state.sh"
# shellcheck source=lib/pipeline-github.sh
[[ -f "$SCRIPT_DIR/lib/pipeline-github.sh" ]] && source "$SCRIPT_DIR/lib/pipeline-github.sh"
# shellcheck source=lib/pipeline-detection.sh
[[ -f "$SCRIPT_DIR/lib/pipeline-detection.sh" ]] && source "$SCRIPT_DIR/lib/pipeline-detection.sh"
# shellcheck source=lib/pipeline-quality-checks.sh
[[ -f "$SCRIPT_DIR/lib/pipeline-quality-checks.sh" ]] && source "$SCRIPT_DIR/lib/pipeline-quality-checks.sh"
# shellcheck source=lib/pipeline-intelligence.sh
[[ -f "$SCRIPT_DIR/lib/pipeline-intelligence.sh" ]] && source "$SCRIPT_DIR/lib/pipeline-intelligence.sh"
# shellcheck source=lib/pipeline-stages.sh
[[ -f "$SCRIPT_DIR/lib/pipeline-stages.sh" ]] && source "$SCRIPT_DIR/lib/pipeline-stages.sh"
# Audit trail for compliance-grade pipeline traceability
# shellcheck source=lib/audit-trail.sh
[[ -f "$SCRIPT_DIR/lib/audit-trail.sh" ]] && source "$SCRIPT_DIR/lib/audit-trail.sh" 2>/dev/null || true
PIPELINE_COVERAGE_THRESHOLD="${PIPELINE_COVERAGE_THRESHOLD:-60}"
PIPELINE_QUALITY_GATE_THRESHOLD="${PIPELINE_QUALITY_GATE_THRESHOLD:-70}"

# ─── Intelligence Engine (optional) ──────────────────────────────────────────
# shellcheck source=sw-intelligence.sh
if [[ -f "$SCRIPT_DIR/sw-intelligence.sh" ]]; then
    source "$SCRIPT_DIR/sw-intelligence.sh"
fi
# shellcheck source=sw-pipeline-composer.sh
if [[ -f "$SCRIPT_DIR/sw-pipeline-composer.sh" ]]; then
    source "$SCRIPT_DIR/sw-pipeline-composer.sh"
fi
# shellcheck source=sw-developer-simulation.sh
if [[ -f "$SCRIPT_DIR/sw-developer-simulation.sh" ]]; then
    source "$SCRIPT_DIR/sw-developer-simulation.sh"
fi
# shellcheck source=sw-architecture-enforcer.sh
if [[ -f "$SCRIPT_DIR/sw-architecture-enforcer.sh" ]]; then
    source "$SCRIPT_DIR/sw-architecture-enforcer.sh"
fi
# shellcheck source=sw-adversarial.sh
if [[ -f "$SCRIPT_DIR/sw-adversarial.sh" ]]; then
    source "$SCRIPT_DIR/sw-adversarial.sh"
fi
# shellcheck source=sw-pipeline-vitals.sh
if [[ -f "$SCRIPT_DIR/sw-pipeline-vitals.sh" ]]; then
    source "$SCRIPT_DIR/sw-pipeline-vitals.sh"
fi

# ─── Memory, Optimization & Discovery (optional) ─────────────────────────
# shellcheck source=sw-memory.sh
if [[ -f "$SCRIPT_DIR/sw-memory.sh" ]]; then
    source "$SCRIPT_DIR/sw-memory.sh"
fi
# shellcheck source=sw-self-optimize.sh
if [[ -f "$SCRIPT_DIR/sw-self-optimize.sh" ]]; then
    source "$SCRIPT_DIR/sw-self-optimize.sh"
fi
# shellcheck source=sw-discovery.sh
if [[ -f "$SCRIPT_DIR/sw-discovery.sh" ]]; then
    source "$SCRIPT_DIR/sw-discovery.sh"
fi
# shellcheck source=sw-durable.sh
if [[ -f "$SCRIPT_DIR/sw-durable.sh" ]]; then
    source "$SCRIPT_DIR/sw-durable.sh"
fi
# shellcheck source=sw-db.sh
# Durable workflows: db_save_checkpoint/db_load_checkpoint.
[[ -f "$SCRIPT_DIR/sw-db.sh" ]] && source "$SCRIPT_DIR/sw-db.sh"
# Ensure DB schema exists so emit_event → db_add_event can write rows (CREATE IF NOT EXISTS is idempotent)
if type init_schema >/dev/null 2>&1 && type check_sqlite3 >/dev/null 2>&1 && check_sqlite3 2>/dev/null; then
    init_schema 2>/dev/null || true
fi
# shellcheck source=sw-cost.sh
# for cost_record persistence to costs.json + DB
[[ -f "$SCRIPT_DIR/sw-cost.sh" ]] && source "$SCRIPT_DIR/sw-cost.sh"
# shellcheck source=lib/cost/stage.sh
# Per-stage cost attribution helpers (issue #87). Must source AFTER sw-cost.sh
# so that cost_calculate / cost_record are available when stages bracket themselves.
[[ -f "$SCRIPT_DIR/lib/cost/stage.sh" ]] && source "$SCRIPT_DIR/lib/cost/stage.sh"
# shellcheck source=lib/skill-registry.sh
# for skill_analyze_outcome (AI outcome learning)
[[ -f "$SCRIPT_DIR/lib/skill-registry.sh" ]] && source "$SCRIPT_DIR/lib/skill-registry.sh"
# shellcheck source=lib/skill-memory.sh
# for skill memory operations
[[ -f "$SCRIPT_DIR/lib/skill-memory.sh" ]] && source "$SCRIPT_DIR/lib/skill-memory.sh"

# ─── GitHub API Modules (optional) ─────────────────────────────────────────
# shellcheck source=sw-github-graphql.sh
[[ -f "$SCRIPT_DIR/sw-github-graphql.sh" ]] && source "$SCRIPT_DIR/sw-github-graphql.sh"
# shellcheck source=sw-github-checks.sh
[[ -f "$SCRIPT_DIR/sw-github-checks.sh" ]] && source "$SCRIPT_DIR/sw-github-checks.sh"
# shellcheck source=sw-github-deploy.sh
[[ -f "$SCRIPT_DIR/sw-github-deploy.sh" ]] && source "$SCRIPT_DIR/sw-github-deploy.sh"

# ─── Ruflo Adapter (optional) ───────────────────────────────────────────────
# shellcheck source=lib/ruflo-adapter.sh
[[ -f "$SCRIPT_DIR/lib/ruflo-adapter.sh" ]] && source "$SCRIPT_DIR/lib/ruflo-adapter.sh" 2>/dev/null || true
if [[ "${SHIPWRIGHT_RUFLO_MCP_ONLY:-0}" == "1" ]]; then
    export SW_RUFLO_BACKEND=mcp
fi

# Parse coverage percentage from test output — multi-framework patterns
# Usage: parse_coverage_from_output <log_file>
# Outputs coverage percentage or empty string
parse_coverage_from_output() {
    local log_file="$1"
    [[ ! -f "$log_file" ]] && return
    local cov=""
    # Jest/Istanbul: "Statements : 85.5%"
    cov=$(grep -oE 'Statements\s*:\s*[0-9.]+' "$log_file" 2>/dev/null | grep -oE '[0-9.]+$' || true)
    # Istanbul table: "All files | 85.5"
    [[ -z "$cov" ]] && cov=$(grep -oE 'All files\s*\|\s*[0-9.]+' "$log_file" 2>/dev/null | grep -oE '[0-9.]+$' || true)
    # pytest-cov: "TOTAL    500    75    85%"
    [[ -z "$cov" ]] && cov=$(grep -oE 'TOTAL\s+[0-9]+\s+[0-9]+\s+[0-9]+%' "$log_file" 2>/dev/null | grep -oE '[0-9]+%' | tr -d '%' | tail -1 || true)
    # Vitest: "All files  |  85.5  |"
    [[ -z "$cov" ]] && cov=$(grep -oE 'All files\s*\|\s*[0-9.]+\s*\|' "$log_file" 2>/dev/null | grep -oE '[0-9.]+' | head -1 || true)
    # Go coverage: "coverage: 85.5% of statements"
    [[ -z "$cov" ]] && cov=$(grep -oE 'coverage:\s*[0-9.]+%' "$log_file" 2>/dev/null | grep -oE '[0-9.]+' | tail -1 || true)
    # Cargo tarpaulin: "85.50% coverage"
    [[ -z "$cov" ]] && cov=$(grep -oE '[0-9.]+%\s*coverage' "$log_file" 2>/dev/null | grep -oE '[0-9.]+' | head -1 || true)
    # Generic: "Coverage: 85.5%"
    [[ -z "$cov" ]] && cov=$(grep -oiE 'coverage:?\s*[0-9.]+%' "$log_file" 2>/dev/null | grep -oE '[0-9.]+' | tail -1 || true)
    echo "$cov"
}

format_duration() {
    local secs="$1"
    if [[ "$secs" -ge 3600 ]]; then
        printf "%dh %dm %ds" $((secs/3600)) $((secs%3600/60)) $((secs%60))
    elif [[ "$secs" -ge 60 ]]; then
        printf "%dm %ds" $((secs/60)) $((secs%60))
    else
        printf "%ds" "$secs"
    fi
}

# ─── Memory budget guard helpers ────────────────────────────────────────────
# Probe free memory in whole GB. Cross-platform (Linux /proc/meminfo, macOS
# vm_stat). On any probe failure returns 0 — fail-closed so the admission
# gate refuses rather than admitting on bad signal.
get_free_memory_gb() {
    local kb=0
    if [[ -r /proc/meminfo ]]; then
        # Prefer MemAvailable (kernel 3.14+); fall back to MemFree.
        kb=$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo "")
        if [[ -z "$kb" || ! "$kb" =~ ^[0-9]+$ ]]; then
            kb=$(awk '/^MemFree:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo "0")
        fi
    elif command -v vm_stat >/dev/null 2>&1 && command -v pagesize >/dev/null 2>&1; then
        # macOS: approximate MemAvailable as (free + inactive) * pagesize.
        # Just "free" undercounts and would over-block on a healthy host.
        local pagesz free_pages inactive_pages
        pagesz=$(pagesize 2>/dev/null || echo "4096")
        free_pages=$(vm_stat 2>/dev/null | awk -F'[: .]+' '/Pages free/ {print $3; exit}')
        inactive_pages=$(vm_stat 2>/dev/null | awk -F'[: .]+' '/Pages inactive/ {print $3; exit}')
        free_pages="${free_pages:-0}"
        inactive_pages="${inactive_pages:-0}"
        if [[ "$free_pages" =~ ^[0-9]+$ && "$inactive_pages" =~ ^[0-9]+$ && "$pagesz" =~ ^[0-9]+$ ]]; then
            local bytes=$(( (free_pages + inactive_pages) * pagesz ))
            kb=$(( bytes / 1024 ))
        fi
    fi
    [[ ! "$kb" =~ ^[0-9]+$ ]] && kb=0
    # Integer GB (rounds down — conservative; a host with 4.9 GB reports 4).
    echo $(( kb / 1024 / 1024 ))
}

# kill -0 idiom — is the given PID alive and signalable by us?
pid_exists() {
    local pid="$1"
    [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null
}

# Walk active-pipelines/, unlink any entry whose PID is no longer alive.
# Echoes count reaped. Always returns 0; reaping is best-effort.
reap_stale_pipeline_locks() {
    local dir="$SHIPWRIGHT_ACTIVE_PIPELINES_DIR"
    [[ -d "$dir" ]] || { echo "0"; return 0; }
    local reaped=0
    local lock pid
    for lock in "$dir"/*.json; do
        [[ -f "$lock" ]] || continue
        pid=$(jq -r '.pid // empty' "$lock" 2>/dev/null || true)
        # Fall back to filename when JSON is corrupted.
        if [[ -z "$pid" || ! "$pid" =~ ^[0-9]+$ ]]; then
            pid=$(basename "$lock" .json)
        fi
        if ! pid_exists "$pid"; then
            rm -f "$lock" 2>/dev/null || true
            reaped=$((reaped + 1))
            emit_event "pipeline.lock_reaped" "pid=$pid" 2>/dev/null || true
        fi
    done
    echo "$reaped"
    return 0
}

# Count live entries (assumes reap has already run). Stdout: integer.
count_active_pipeline_locks() {
    local dir="$SHIPWRIGHT_ACTIVE_PIPELINES_DIR"
    [[ -d "$dir" ]] || { echo "0"; return 0; }
    local n=0 lock
    for lock in "$dir"/*.json; do
        [[ -f "$lock" ]] && n=$((n + 1))
    done
    echo "$n"
}

# Atomically write $SHIPWRIGHT_ACTIVE_PIPELINES_DIR/<pid>.json with metadata.
# Returns rc=0 on success, 1 on filesystem error (including missing jq).
write_active_pipeline_lock() {
    local dir="$SHIPWRIGHT_ACTIVE_PIPELINES_DIR"
    mkdir -p "$dir" 2>/dev/null || return 1
    if ! command -v jq >/dev/null 2>&1; then
        error "jq is required by the pipeline admission gate but was not found — install jq and retry (brew install jq / apt install jq)"
        return 1
    fi
    local pid="$_PIPELINE_PID"
    local lock_file="$dir/$pid.json"
    local tmp="$dir/$pid.json.tmp.$$"
    local started_at issue_or_goal repo_path
    started_at="$(now_iso)"
    issue_or_goal="${ISSUE_NUMBER:-${GOAL:-unknown}}"
    repo_path="${ORIGINAL_REPO_DIR:-$(pwd)}"
    if ! jq -n \
        --arg pid "$pid" \
        --arg started_at "$started_at" \
        --arg issue_or_goal "$issue_or_goal" \
        --arg repo "$repo_path" \
        --arg pipeline_template "${PIPELINE_NAME:-standard}" \
        '{pid: ($pid|tonumber), started_at: $started_at, issue_or_goal: $issue_or_goal, repo: $repo, pipeline_template: $pipeline_template}' \
        > "$tmp" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi
    if ! mv "$tmp" "$lock_file" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi
    _ACTIVE_PIPELINE_LOCK_FILE="$lock_file"
    emit_event "pipeline.lock_acquired" "pid=$pid" "issue_or_goal=$issue_or_goal" 2>/dev/null || true
    return 0
}

# Idempotent — safe to call from EXIT/SIGINT/SIGTERM traps.
release_active_pipeline_lock() {
    local lock_file="$_ACTIVE_PIPELINE_LOCK_FILE"
    [[ -z "$lock_file" ]] && lock_file="$SHIPWRIGHT_ACTIVE_PIPELINES_DIR/$_PIPELINE_PID.json"
    if [[ -f "$lock_file" ]]; then
        rm -f "$lock_file" 2>/dev/null || true
        emit_event "pipeline.lock_released" "pid=$_PIPELINE_PID" 2>/dev/null || true
    fi
    _ACTIVE_PIPELINE_LOCK_FILE=""
    return 0
}

# Format the "blocked by" diagnostic lines for a single lock file.
# Stdout: human-readable two lines (PID summary + age).
_describe_blocking_lock() {
    local lock="$1"
    [[ -f "$lock" ]] || return 0
    local pid started issue repo template
    pid=$(jq -r '.pid // "?"' "$lock" 2>/dev/null || echo "?")
    started=$(jq -r '.started_at // "?"' "$lock" 2>/dev/null || echo "?")
    issue=$(jq -r '.issue_or_goal // "?"' "$lock" 2>/dev/null || echo "?")
    repo=$(jq -r '.repo // "?"' "$lock" 2>/dev/null || echo "?")
    template=$(jq -r '.pipeline_template // "?"' "$lock" 2>/dev/null || echo "?")
    echo "    pid=$pid started=$started issue=$issue repo=$repo template=$template"
}

# Enforce concurrency cap and free-memory floor.
# rc=0 admit, rc=1 refuse. On refuse, writes diagnostic to stderr.
check_admission_gate() {
    mkdir -p "$SHIPWRIGHT_ACTIVE_PIPELINES_DIR" 2>/dev/null || true
    reap_stale_pipeline_locks >/dev/null 2>&1 || true

    local active
    active=$(count_active_pipeline_locks)
    if [[ "$active" -ge "$SHIPWRIGHT_MAX_ACTIVE_PIPELINES" ]]; then
        error "Refusing to start: $active active pipeline(s) already running (max=$SHIPWRIGHT_MAX_ACTIVE_PIPELINES per host)"
        echo -e "${DIM}  Concurrent pipelines can OOM the host. Wait for the running pipeline to finish.${RESET}" >&2
        echo -e "${DIM}  Blocking pipeline(s):${RESET}" >&2
        local lock
        for lock in "$SHIPWRIGHT_ACTIVE_PIPELINES_DIR"/*.json; do
            [[ -f "$lock" ]] && _describe_blocking_lock "$lock" >&2
        done
        echo -e "${DIM}  Inspect: shipwright doctor${RESET}" >&2
        emit_event "pipeline.admission_refused" "reason=concurrency" "active=$active" "max=$SHIPWRIGHT_MAX_ACTIVE_PIPELINES" 2>/dev/null || true
        return 1
    fi

    local free_gb
    free_gb=$(get_free_memory_gb)
    if [[ "$free_gb" -lt "$SHIPWRIGHT_MIN_FREE_GB" ]]; then
        error "Refusing to start: only ${free_gb} GB free memory (min=${SHIPWRIGHT_MIN_FREE_GB} GB required)"
        echo -e "${DIM}  Free memory below safety threshold — host risks OOM under pipeline load.${RESET}" >&2
        echo -e "${DIM}  Free up RAM (close apps, kill orphan agents) and retry, or set SHIPWRIGHT_MIN_FREE_GB=N to override.${RESET}" >&2
        emit_event "pipeline.admission_refused" "reason=memory" "free_gb=$free_gb" "min_gb=$SHIPWRIGHT_MIN_FREE_GB" 2>/dev/null || true
        return 1
    fi

    return 0
}

# Rotate event log if needed (standalone mode — daemon has its own rotation in poll loop)
rotate_event_log_if_needed() {
    local events_file="${EVENTS_FILE:-$HOME/.shipwright/events.jsonl}"
    local max_lines=10000
    [[ ! -f "$events_file" ]] && return
    local lines
    lines=$(wc -l < "$events_file" 2>/dev/null || true)
    lines="${lines:-0}"
    if [[ "$lines" -gt "$max_lines" ]]; then
        local tmp="${events_file}.rotating"
        if tail -5000 "$events_file" > "$tmp" 2>/dev/null && mv "$tmp" "$events_file" 2>/dev/null; then
            info "Rotated events.jsonl: ${lines} -> 5000 lines"
        fi
    fi
}

_pipeline_compact_goal() {
    local goal="$1"
    local plan_file="${2:-}"
    local design_file="${3:-}"
    local compact="$goal"

    # Include plan summary (first 20 lines only)
    if [[ -n "$plan_file" && -f "$plan_file" ]]; then
        compact="${compact}

## Plan Summary
$(head -20 "$plan_file" 2>/dev/null || true)
[... full plan in .claude/pipeline-artifacts/plan.md]"
    fi

    # Include design key decisions only (grep for headers)
    if [[ -n "$design_file" && -f "$design_file" ]]; then
        compact="${compact}

## Key Design Decisions
$(grep -E '^#{1,3} ' "$design_file" 2>/dev/null | head -10 || true)
[... full design in .claude/pipeline-artifacts/design.md]"
    fi

    echo "$compact"
}

load_composed_pipeline() {
    local spec_file="$1"
    [[ ! -f "$spec_file" ]] && return 1

    # Read enabled stages from composed spec
    local composed_stages
    composed_stages=$(jq -r '.stages // [] | .[] | .id' "$spec_file" 2>/dev/null) || return 1
    [[ -z "$composed_stages" ]] && return 1

    # Override enabled stages
    COMPOSED_STAGES="$composed_stages"

    # Override per-stage settings
    local build_max
    build_max=$(jq -r '.stages[] | select(.id=="build") | .max_iterations // ""' "$spec_file" 2>/dev/null) || true
    [[ -n "$build_max" && "$build_max" != "null" ]] && COMPOSED_BUILD_ITERATIONS="$build_max"

    emit_event "pipeline.composed_loaded" "stages=$(echo "$composed_stages" | wc -l | tr -d ' ')"
    return 0
}

# ─── Token / Cost Parsing ─────────────────────────────────────────────────
parse_claude_tokens() {
    local log_file="$1"
    local input_tok output_tok
    input_tok=$(grep -oE 'input[_ ]tokens?[: ]+[0-9,]+' "$log_file" 2>/dev/null | tail -1 | grep -oE '[0-9,]+' | tr -d ',' || echo "0")
    output_tok=$(grep -oE 'output[_ ]tokens?[: ]+[0-9,]+' "$log_file" 2>/dev/null | tail -1 | grep -oE '[0-9,]+' | tr -d ',' || echo "0")

    TOTAL_INPUT_TOKENS=$(( TOTAL_INPUT_TOKENS + ${input_tok:-0} ))
    TOTAL_OUTPUT_TOKENS=$(( TOTAL_OUTPUT_TOKENS + ${output_tok:-0} ))
}

# Estimate pipeline cost using historical averages from completed pipelines.
# Falls back to per-stage estimates when no history exists.
estimate_pipeline_cost() {
    local stages="$1"
    local stage_count
    stage_count=$(echo "$stages" | jq 'length' 2>/dev/null || echo "6")
    [[ ! "$stage_count" =~ ^[0-9]+$ ]] && stage_count=6

    local events_file="${EVENTS_FILE:-$HOME/.shipwright/events.jsonl}"
    local avg_input=0 avg_output=0
    if [[ -f "$events_file" ]]; then
        local hist
        hist=$(grep '"type":"pipeline.completed"' "$events_file" 2>/dev/null | tail -10)
        if [[ -n "$hist" ]]; then
            avg_input=$(echo "$hist" | jq -s -r '[.[] | .input_tokens // 0 | tonumber] | if length > 0 then (add / length | floor | tostring) else "0" end' 2>/dev/null | head -1)
            avg_output=$(echo "$hist" | jq -s -r '[.[] | .output_tokens // 0 | tonumber] | if length > 0 then (add / length | floor | tostring) else "0" end' 2>/dev/null | head -1)
        fi
    fi
    [[ ! "$avg_input" =~ ^[0-9]+$ ]] && avg_input=0
    [[ ! "$avg_output" =~ ^[0-9]+$ ]] && avg_output=0

    # Fall back to reasonable per-stage estimates only if no history
    if [[ "$avg_input" -eq 0 ]]; then
        avg_input=$(( stage_count * 8000 ))   # More realistic: ~8K input per stage
        avg_output=$(( stage_count * 4000 ))  # ~4K output per stage
    fi

    echo "{\"input_tokens\":${avg_input},\"output_tokens\":${avg_output}}"
}

# ─── Defaults ───────────────────────────────────────────────────────────────
GOAL=""
ORIGINAL_GOAL=""   # Clean goal — guards against mutation leak into write_state()
ISSUE_NUMBER=""
PIPELINE_NAME="standard"
PIPELINE_CONFIG=""
TEST_CMD=""
TEST_CMD_EXPLICIT=false  # true only when --test-cmd is explicitly provided via CLI
MODEL=""
AI_PROVIDER_OVERRIDE=""
AGENTS=""
PIPELINE_AGENT_ID="${PIPELINE_AGENT_ID:-pipeline-$$}"
SKIP_GATES=false
HEADLESS=false
GIT_BRANCH=""
GITHUB_ISSUE=""
TASK_TYPE=""
REVIEWERS=""
LABELS=""
BASE_BRANCH="main"
NO_GITHUB="${NO_GITHUB:-false}"
NO_ARTIFACT_PUSH="${NO_ARTIFACT_PUSH:-false}"
NO_GITHUB_LABEL="${NO_GITHUB_LABEL:-false}"
CI_MODE=false
DRY_RUN=false
IGNORE_BUDGET=false
COMPLETED_STAGES=""
RESUME_FROM_CHECKPOINT=false
MAX_ITERATIONS_OVERRIDE=""
MAX_RESTARTS_OVERRIDE=""
FAST_TEST_CMD_OVERRIDE=""
FAST_TEST_INTERVAL_OVERRIDE=""
PR_NUMBER=""
AUTO_WORKTREE=false
WORKTREE_NAME=""
CLEANUP_WORKTREE=false
ORIGINAL_REPO_DIR=""
REPO_OVERRIDE=""
_cleanup_done=""
PIPELINE_EXIT_CODE=1  # assume failure until run_pipeline succeeds

# GitHub metadata (populated during intake)
ISSUE_LABELS=""
ISSUE_MILESTONE=""
ISSUE_ASSIGNEES=""
ISSUE_BODY=""
PROGRESS_COMMENT_ID=""
REPO_OWNER=""
REPO_NAME=""
GH_AVAILABLE=false

# Timing
PIPELINE_START_EPOCH=""
STAGE_TIMINGS=""
PIPELINE_STAGES_PASSED=""
PIPELINE_SLOWEST_STAGE=""
LAST_STAGE_ERROR_CLASS=""
LAST_STAGE_ERROR=""

PROJECT_ROOT=""
STATE_DIR=""
STATE_FILE=""
ARTIFACTS_DIR=""
TASKS_FILE=""

# ─── Per-host admission gate ────────────────────────────────────────────────
# Concurrent pipelines on a single host can exhaust memory and OOM-kill the
# machine (16 GB host saw 2 pipelines + a process leak go over). The gate
# below enforces a host-level concurrency cap and a free-memory floor;
# layered above the existing per-issue durable lock. Defaults are safe for
# the lowest-end developer host (16 GB / 4-core); operators can override per
# host via the env vars below.
SHIPWRIGHT_MAX_ACTIVE_PIPELINES="${SHIPWRIGHT_MAX_ACTIVE_PIPELINES:-1}"
SHIPWRIGHT_MIN_FREE_GB="${SHIPWRIGHT_MIN_FREE_GB:-1}"
# Validate env vars are integers; reset to safe defaults on bad input so
# arithmetic comparisons in check_admission_gate never receive non-numeric values.
if [[ ! "$SHIPWRIGHT_MAX_ACTIVE_PIPELINES" =~ ^[1-9][0-9]*$ ]]; then
    warn "SHIPWRIGHT_MAX_ACTIVE_PIPELINES='$SHIPWRIGHT_MAX_ACTIVE_PIPELINES' is not a positive integer — resetting to 1"
    SHIPWRIGHT_MAX_ACTIVE_PIPELINES=1
fi
if [[ ! "$SHIPWRIGHT_MIN_FREE_GB" =~ ^[0-9]+$ ]]; then
    warn "SHIPWRIGHT_MIN_FREE_GB='$SHIPWRIGHT_MIN_FREE_GB' is not a non-negative integer — resetting to 1"
    SHIPWRIGHT_MIN_FREE_GB=1
fi
SHIPWRIGHT_ACTIVE_PIPELINES_DIR="${SHIPWRIGHT_ACTIVE_PIPELINES_DIR:-$HOME/.shipwright/active-pipelines}"
# Capture once at top-level so trap-time `$$` (which would resolve in any
# subshell that wraps cleanup) cannot drift to a different PID.
_PIPELINE_PID="$$"
_ACTIVE_PIPELINE_LOCK_FILE=""

# ─── Help ───────────────────────────────────────────────────────────────────

show_help() {
    echo -e "${CYAN}${BOLD}shipwright pipeline${RESET} — Autonomous Feature Delivery"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  ${CYAN}shipwright pipeline${RESET} <command> [options]"
    echo ""
    echo -e "${BOLD}COMMANDS${RESET}"
    echo -e "  ${CYAN}start${RESET}   --goal \"...\"    Start a new pipeline"
    echo -e "  ${CYAN}resume${RESET}                  Continue from last completed stage"
    echo -e "  ${CYAN}status${RESET}                  Show pipeline progress dashboard"
    echo -e "  ${CYAN}abort${RESET}                   Stop pipeline and mark aborted"
    echo -e "  ${CYAN}list${RESET}                    Show available pipeline templates"
    echo -e "  ${CYAN}show${RESET}    <name>          Display pipeline stages"
    echo -e "  ${CYAN}drift${RESET}                   Show scope drift report (redactions, violations, escalations)"
    echo ""
    echo -e "${BOLD}START OPTIONS${RESET}"
    echo -e "  ${DIM}--goal \"description\"${RESET}     What to build (required unless --issue)"
    echo -e "  ${DIM}--issue <number>${RESET}          Fetch goal from GitHub issue"
    echo -e "  ${DIM}--repo <path>${RESET}             Change to directory before running (must be a git repo)"
    echo -e "  ${DIM}--local${RESET}                   Alias for --no-github --no-github-label (local-only mode)"
    echo -e "  ${DIM}--pipeline <name>${RESET}         Pipeline template (default: standard)"
    echo -e "  ${DIM}--test-cmd \"command\"${RESET}     Override test command (auto-detected if omitted)"
    echo -e "  ${DIM}--model <model>${RESET}           Override AI model (opus, sonnet, haiku)"
    echo -e "  ${DIM}--ai-provider <name>${RESET}      AI provider (claude, codex, copilot)"
    echo -e "  ${DIM}--agents <n>${RESET}              Override agent count"
    echo -e "  ${DIM}--skip-gates${RESET}              Auto-approve all gates (fully autonomous)"
    echo -e "  ${DIM}--headless${RESET}                Full headless mode (skip gates, no prompts)"
    echo -e "  ${DIM}--base <branch>${RESET}           Base branch for PR (default: main)"
    echo -e "  ${DIM}--reviewers \"a,b\"${RESET}        Request PR reviewers (auto-detected if omitted)"
    echo -e "  ${DIM}--labels \"a,b\"${RESET}            Add labels to PR (inherited from issue if omitted)"
    echo -e "  ${DIM}--no-github${RESET}               Disable GitHub integration"
    echo -e "  ${DIM}--no-github-label${RESET}         Don't modify issue labels"
    echo -e "  ${DIM}--ci${RESET}                      CI mode (skip gates, non-interactive)"
    echo -e "  ${DIM}--ignore-budget${RESET}           Skip budget enforcement checks"
    echo -e "  ${DIM}--worktree [=name]${RESET}         Run in isolated git worktree (parallel-safe)"
    echo -e "  ${DIM}--dry-run${RESET}                 Show what would happen without executing"
    echo -e "  ${DIM}--slack-webhook <url>${RESET}     Send notifications to Slack"
    echo -e "  ${DIM}--self-heal <n>${RESET}            Build→test retry cycles on failure (default: 2)"
    echo -e "  ${DIM}--max-iterations <n>${RESET}       Override max build loop iterations"
    echo -e "  ${DIM}--max-restarts <n>${RESET}         Max session restarts in build loop"
    echo -e "  ${DIM}--fast-test-cmd <cmd>${RESET}      Fast/subset test for build loop"
    echo -e "  ${DIM}--fast-test-interval <n>${RESET}   Run full tests every N iterations (default: 5)"
    echo -e "  ${DIM}--tdd${RESET}                     Test-first: generate tests before implementation"
    echo -e "  ${DIM}--completed-stages \"a,b\"${RESET}   Skip these stages (CI resume)"
    echo ""
    echo -e "${BOLD}STAGES${RESET}  ${DIM}(configurable per pipeline template)${RESET}"
    echo -e "  intake → plan → design → build → test → review → pr → deploy → validate → monitor"
    echo ""
    echo -e "${BOLD}GITHUB INTEGRATION${RESET}  ${DIM}(automatic when gh CLI available)${RESET}"
    echo -e "  • Issue intake: fetch metadata, labels, milestone, self-assign"
    echo -e "  • Progress tracking: live updates posted as issue comments"
    echo -e "  • Task checklist: plan posted as checkbox list on issue"
    echo -e "  • PR creation: labels, milestone, reviewers auto-propagated"
    echo -e "  • Issue lifecycle: labeled in-progress → closed on completion"
    echo ""
    echo -e "${BOLD}SELF-HEALING${RESET}  ${DIM}(autonomous error recovery)${RESET}"
    echo -e "  • Build→test feedback loop: failures feed back as build context"
    echo -e "  • Configurable retry cycles (--self-heal N, default: 2)"
    echo -e "  • Auto-rebase before PR: handles base branch drift"
    echo -e "  • Signal-safe: Ctrl+C saves state for clean resume"
    echo -e "  • Git stash/restore: protects uncommitted work"
    echo ""
    echo -e "${BOLD}AUTO-DETECTION${RESET}  ${DIM}(zero-config for common setups)${RESET}"
    echo -e "  • Test command: package.json, Makefile, Cargo.toml, go.mod, etc."
    echo -e "  • Branch prefix: feat/, fix/, refactor/ based on task type"
    echo -e "  • Reviewers: from CODEOWNERS or recent git contributors"
    echo -e "  • Project type: language and framework detection"
    echo ""
    echo -e "${BOLD}NOTIFICATIONS${RESET}  ${DIM}(team awareness)${RESET}"
    echo -e "  • Slack: --slack-webhook <url>"
    echo -e "  • Custom webhook: set SHIPWRIGHT_WEBHOOK_URL env var"
    echo -e "  • Events: start, stage complete, failure, self-heal, done"
    echo ""
    echo -e "${BOLD}ADMISSION GATE${RESET}  ${DIM}(per-host concurrency + memory floor)${RESET}"
    echo -e "  • Refuses ${BOLD}start${RESET} / ${BOLD}resume${RESET} when too many pipelines are live or free RAM is low"
    echo -e "  • ${CYAN}SHIPWRIGHT_MAX_ACTIVE_PIPELINES${RESET}=N   max concurrent pipelines per host (default: 1)"
    echo -e "  • ${CYAN}SHIPWRIGHT_MIN_FREE_GB${RESET}=N            min free memory in GB to admit (default: 1)"
    echo -e "  • Inspect locks: ${CYAN}shipwright doctor${RESET}  ${DIM}(ACTIVE PIPELINES & MEMORY section)${RESET}"
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo -e "  ${DIM}# From GitHub issue (fully autonomous)${RESET}"
    echo -e "  ${DIM}shipwright pipeline start --issue 123 --skip-gates${RESET}"
    echo ""
    echo -e "  ${DIM}# From inline goal${RESET}"
    echo -e "  ${DIM}shipwright pipeline start --goal \"Add JWT authentication\"${RESET}"
    echo ""
    echo -e "  ${DIM}# Hotfix with custom test command${RESET}"
    echo -e "  ${DIM}shipwright pipeline start --issue 456 --pipeline hotfix --test-cmd \"pytest\"${RESET}"
    echo ""
    echo -e "  ${DIM}# Full deployment pipeline with 3 agents${RESET}"
    echo -e "  ${DIM}shipwright pipeline start --goal \"Build payment flow\" --pipeline full --agents 3${RESET}"
    echo ""
    echo -e "  ${DIM}# Parallel pipeline in isolated worktree${RESET}"
    echo -e "  ${DIM}shipwright pipeline start --issue 42 --worktree${RESET}"
    echo ""
    echo -e "  ${DIM}# Resume / monitor / abort${RESET}"
    echo -e "  ${DIM}shipwright pipeline resume${RESET}"
    echo -e "  ${DIM}shipwright pipeline status${RESET}"
    echo -e "  ${DIM}shipwright pipeline abort${RESET}"
    echo ""
}

# ─── Argument Parsing ───────────────────────────────────────────────────────

SUBCOMMAND="${1:-help}"
shift 2>/dev/null || true

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --goal)        GOAL="$2"; shift 2 ;;
            --issue)       ISSUE_NUMBER="$2"; _ISSUE_NUMBER_EXPLICIT=true; shift 2
                           [[ "${SHIPWRIGHT_DEBUG:-0}" == "1" ]] && echo "[ISSUE-TRACE] parse_args: ISSUE_NUMBER=${ISSUE_NUMBER}" >&2 || true ;;
            --repo)        REPO_OVERRIDE="$2"; shift 2 ;;
            --local)       NO_GITHUB=true; NO_GITHUB_LABEL=true; shift ;;
            --pipeline|--template) PIPELINE_NAME="$2"; shift 2 ;;
            --test-cmd)    TEST_CMD="$2"; TEST_CMD_EXPLICIT=true; shift 2 ;;
            --model)       MODEL="$2"; shift 2 ;;
            --ai-provider) AI_PROVIDER_OVERRIDE="$2"; shift 2 ;;
            --ai-provider=*) AI_PROVIDER_OVERRIDE="${1#--ai-provider=}"; shift ;;
            --agents)      AGENTS="$2"; shift 2 ;;
            --skip-gates)  SKIP_GATES=true; shift ;;
            --headless)    HEADLESS=true; SKIP_GATES=true; shift ;;
            --base)
                BASE_BRANCH="$2"
                if declare -f _validate_ref >/dev/null 2>&1; then
                    _validate_ref "$BASE_BRANCH" "--base" || exit 1
                fi
                shift 2 ;;
            --reviewers)   REVIEWERS="$2"; shift 2 ;;
            --labels)      LABELS="$2"; shift 2 ;;
            --no-github)   NO_GITHUB=true; shift ;;
            --no-github-label) NO_GITHUB_LABEL=true; shift ;;
            --ci)          CI_MODE=true; SKIP_GATES=true; shift ;;
            --ignore-budget) IGNORE_BUDGET=true; shift ;;
            --max-iterations) MAX_ITERATIONS_OVERRIDE="$2"; shift 2 ;;
            --completed-stages) COMPLETED_STAGES="$2"; shift 2 ;;
            --resume) RESUME_FROM_CHECKPOINT=true; shift ;;
            --worktree=*) AUTO_WORKTREE=true; WORKTREE_NAME="${1#--worktree=}"; WORKTREE_NAME="${WORKTREE_NAME//[^a-zA-Z0-9_-]/}"; if [[ -z "$WORKTREE_NAME" ]]; then error "Invalid worktree name (alphanumeric, hyphens, underscores only)"; exit 1; fi; shift ;;
            --worktree)   AUTO_WORKTREE=true; shift ;;
            --dry-run)     DRY_RUN=true; shift ;;
            --slack-webhook) SLACK_WEBHOOK="$2"; shift 2 ;;
            --self-heal)   BUILD_TEST_RETRIES="${2:-3}"; shift 2 ;;
            --max-restarts)
                MAX_RESTARTS_OVERRIDE="$2"
                if ! [[ "$MAX_RESTARTS_OVERRIDE" =~ ^[0-9]+$ ]]; then
                    error "--max-restarts must be numeric (got: $MAX_RESTARTS_OVERRIDE)"
                    exit 1
                fi
                shift 2 ;;

            --fast-test-cmd) FAST_TEST_CMD_OVERRIDE="$2"; shift 2 ;;
            --fast-test-interval)
                FAST_TEST_INTERVAL_OVERRIDE="$2"
                if ! [[ "$FAST_TEST_INTERVAL_OVERRIDE" =~ ^[1-9][0-9]*$ ]]; then
                    error "--fast-test-interval must be a positive integer (got: $FAST_TEST_INTERVAL_OVERRIDE)"
                    exit 1
                fi
                shift 2 ;;
            --tdd)         TDD_ENABLED=true; shift ;;
            --help|-h)     show_help; exit 0 ;;
            *)
                if [[ -z "$PIPELINE_NAME_ARG" ]]; then
                    PIPELINE_NAME_ARG="$1"
                fi
                shift ;;
        esac
    done
}

PIPELINE_NAME_ARG=""
parse_args "$@"

if [[ -n "$AI_PROVIDER_OVERRIDE" ]]; then
    export SHIPWRIGHT_AI_PROVIDER="$AI_PROVIDER_OVERRIDE"
fi

# ─── Non-Interactive Detection ──────────────────────────────────────────────
# When stdin is not a terminal (background, pipe, nohup, tmux send-keys),
# auto-enable headless mode to prevent read prompts from killing the script.
if [[ ! -t 0 ]]; then
    HEADLESS=true
    if [[ "$SKIP_GATES" != "true" ]]; then
        SKIP_GATES=true
    fi
fi
# --worktree implies headless when stdin is not a terminal
if [[ "$AUTO_WORKTREE" == "true" && "$SKIP_GATES" != "true" && ! -t 0 ]]; then
    SKIP_GATES=true
fi

# ─── Directory Setup ────────────────────────────────────────────────────────

setup_dirs() {
    PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    STATE_DIR="$PROJECT_ROOT/.claude"
    STATE_FILE="$STATE_DIR/pipeline-state.md"
    ARTIFACTS_DIR="$STATE_DIR/pipeline-artifacts"
    export ARTIFACTS_DIR  # Export so child processes (sw-loop.sh) can write audit events
    TASKS_FILE="$STATE_DIR/pipeline-tasks${ISSUE_NUMBER:+-${ISSUE_NUMBER}}.md"
    mkdir -p "$STATE_DIR" "$ARTIFACTS_DIR"

    # Compute repo hash first — used in SHIPWRIGHT_PIPELINE_ID and heartbeat job IDs.
    # Delegates to _sw_repo_hash() in helpers.sh (shared with sw-memory.sh pattern).
    if [[ -z "${REPO_HASH:-}" ]]; then
        REPO_HASH=$(_sw_repo_hash)
        export REPO_HASH
    fi

    export SHIPWRIGHT_PIPELINE_ID="${REPO_HASH:+${REPO_HASH}-}pipeline-$$-${ISSUE_NUMBER:-0}"
    export SHIPWRIGHT_ACTIVE=1
    export SHIPWRIGHT_SOURCE="${SHIPWRIGHT_SOURCE:-pipeline}"
}

# ─── Pipeline Config Loading ───────────────────────────────────────────────

find_pipeline_config() {
    local name="$1"
    local locations=(
        "$REPO_DIR/templates/pipelines/${name}.json"
        "${PROJECT_ROOT:-}/templates/pipelines/${name}.json"
        "$HOME/.shipwright/pipelines/${name}.json"
    )
    for loc in "${locations[@]}"; do
        if [[ -n "$loc" && -f "$loc" ]]; then
            echo "$loc"
            return 0
        fi
    done
    return 1
}

load_pipeline_config() {
    # Check for intelligence-composed pipeline first
    local composed_pipeline="${ARTIFACTS_DIR}/composed-pipeline.json"
    if [[ -f "$composed_pipeline" ]] && type composer_validate_pipeline >/dev/null 2>&1; then
        # Use composed pipeline if fresh (within cache TTL)
        local composed_cache_ttl
        composed_cache_ttl=$(_config_get_int "pipeline.composed_cache_ttl" 3600 2>/dev/null || echo 3600)
        local composed_age=99999
        local composed_mtime
        composed_mtime=$(file_mtime "$composed_pipeline")
        if [[ "$composed_mtime" -gt 0 ]]; then
            composed_age=$(( $(now_epoch) - composed_mtime ))
        fi
        if [[ "$composed_age" -lt "$composed_cache_ttl" ]]; then
            local validate_json
            validate_json=$(cat "$composed_pipeline" 2>/dev/null || echo "")
            if [[ -n "$validate_json" ]] && composer_validate_pipeline "$validate_json" 2>/dev/null; then
                PIPELINE_CONFIG="$composed_pipeline"
                info "Pipeline: ${BOLD}composed${RESET} ${DIM}(intelligence-driven)${RESET}"
                emit_event "pipeline.composed_loaded" "issue=${ISSUE_NUMBER:-0}"
                return
            fi
        fi
    fi

    PIPELINE_CONFIG=$(find_pipeline_config "$PIPELINE_NAME") || {
        error "Pipeline template not found: $PIPELINE_NAME"
        echo -e "  Available templates: ${DIM}shipwright pipeline list${RESET}"
        exit 1
    }
    info "Pipeline: ${BOLD}$PIPELINE_NAME${RESET} ${DIM}($PIPELINE_CONFIG)${RESET}"
    # TDD from template (overridable by --tdd)
    [[ "$(jq -r '.tdd // false' "$PIPELINE_CONFIG" 2>/dev/null)" == "true" ]] && PIPELINE_TDD=true
    return 0
}

CURRENT_STAGE_ID=""

# Notification / webhook
SLACK_WEBHOOK=""
NOTIFICATION_ENABLED=false

# Self-healing
BUILD_TEST_RETRIES=$(_config_get_int "pipeline.build_test_retries" 3 2>/dev/null || echo 3)
REVIEW_BUILD_RETRIES=$(_config_get_int "pipeline.review_build_retries" 2 2>/dev/null || echo 2)
STASHED_CHANGES=false
SELF_HEAL_COUNT=0

# Cycling halt: cap on consecutive test-stage failures across pipeline invocations.
# Despite the name (kept for backward compatibility), this counts test-stage failures,
# not build iterations — set SW_PIPELINE_MAX_BUILD_RETRIES=0 to disable (escape hatch).
SW_PIPELINE_MAX_BUILD_RETRIES=${SW_PIPELINE_MAX_BUILD_RETRIES:-3}
PIPELINE_STUCK_CYCLING=false

# ─── Cost Tracking ───────────────────────────────────────────────────────
TOTAL_INPUT_TOKENS=0
TOTAL_OUTPUT_TOKENS=0
COST_MODEL_RATES='{"opus":{"input":15,"output":75},"sonnet":{"input":3,"output":15},"haiku":{"input":0.25,"output":1.25}}'

# ─── Heartbeat ────────────────────────────────────────────────────────────────
HEARTBEAT_PID=""
HEARTBEAT_JOB_ID=""

start_heartbeat() {
    HEARTBEAT_JOB_ID="${REPO_HASH:+${REPO_HASH}-}${PIPELINE_NAME:-pipeline-$$}"
    local job_id="$HEARTBEAT_JOB_ID"
    # Capture parent PID before forking so the subshell can poll it.
    # Covers Class 2 (partial-cleanup) and Class 3 (hard-kill) orphan scenarios
    # where the parent exits without reaching stop_heartbeat().
    local _hb_parent_pid=$$
    (
        _hb_sleep_pid=""
        # TERM trap: fast shutdown on Class 1 (clean exit via stop_heartbeat).
        # Kept alongside the _parent_alive polling below so both paths work.
        trap '[[ -n "$_hb_sleep_pid" ]] && kill "$_hb_sleep_pid" 2>/dev/null || true; exit 0' TERM EXIT
        # Poll parent existence each iteration — exits naturally on parent death
        # regardless of signal delivery (handles SIGKILL and mid-cleanup exits).
        while _parent_alive "$_hb_parent_pid" 2>/dev/null; do
            "$SCRIPT_DIR/sw-heartbeat.sh" write "$job_id" \
                --pid $$ \
                --issue "${ISSUE_NUMBER:-0}" \
                --stage "${CURRENT_STAGE_ID:-unknown}" \
                --iteration "0" \
                --activity "$(get_stage_description "${CURRENT_STAGE_ID:-}" 2>/dev/null || echo "Running pipeline")" 2>/dev/null || true
            sleep "$(_config_get_int "pipeline.heartbeat_interval" 30 2>/dev/null || echo 30)" &
            _hb_sleep_pid=$!
            wait "$_hb_sleep_pid" 2>/dev/null || true
            _hb_sleep_pid=""
        done
    ) >/dev/null 2>&1 &
    HEARTBEAT_PID=$!
}

stop_heartbeat() {
    if [[ -n "${HEARTBEAT_PID:-}" ]]; then
        # Use BFS tree kill so any tools spawned by sw-heartbeat.sh are also reaped.
        if declare -f _kill_process_tree >/dev/null 2>&1; then
            _kill_process_tree TERM "$HEARTBEAT_PID" 2>/dev/null || true
        else
            kill "$HEARTBEAT_PID" 2>/dev/null || true
        fi
        wait "$HEARTBEAT_PID" 2>/dev/null || true
        "$SCRIPT_DIR/sw-heartbeat.sh" clear "${HEARTBEAT_JOB_ID:-${PIPELINE_NAME:-pipeline-$$}}" 2>/dev/null || true
        HEARTBEAT_PID=""
        HEARTBEAT_JOB_ID=""
    fi
}

# ─── CI Helpers ───────────────────────────────────────────────────────────

# _assert_push_target_matches_active_issue <branch>
# Returns 87 if <branch> is shipwright/issue-N and N != ISSUE_NUMBER.
# On block: writes a structured diagnostic to stderr (branch, ISSUE_NUMBER,
# SHIPWRIGHT_PIPELINE_ID, HEAD, state-file issue; full callerstack only when
# SHIPWRIGHT_DEBUG=1) and emits a pipeline.push_guard_blocked event.
# Passive (returns 0) for shipwright-data, ci/*, refs/notes/*, etc.
_assert_push_target_matches_active_issue() {
    local branch="$1"
    [[ "$branch" =~ ^shipwright/issue-([0-9]+)$ ]] || return 0
    local target_num="${BASH_REMATCH[1]}"
    local active="${ISSUE_NUMBER:-}"
    if [[ "$active" != "$target_num" ]]; then
        {
            echo "[PUSH-GUARD-FAIL] $(date -u +%FT%TZ)"
            echo "  branch=$branch target_issue=$target_num"
            echo "  ISSUE_NUMBER=${active:-<unset>}"
            echo "  SHIPWRIGHT_PIPELINE_ID=${SHIPWRIGHT_PIPELINE_ID:-<unset>}"
            echo "  HEAD=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
            echo "  state_file_issue=$(grep -m1 '^issue:' .claude/pipeline-state.md 2>/dev/null || echo none)"
            if [[ "${SHIPWRIGHT_DEBUG:-0}" == "1" ]]; then
                echo "  caller stack:"
                local i
                for ((i=0; i<${#FUNCNAME[@]}; i++)); do
                    printf '    #%d %s at %s:%s\n' "$i" "${FUNCNAME[$i]}" \
                        "${BASH_SOURCE[$i]:-?}" "${BASH_LINENO[$i]:-?}"
                done
            fi
        } >&2
        emit_event "pipeline.push_guard_blocked" \
            "branch=$branch target=$target_num active=${active:-none}" 2>/dev/null || true
        return 87
    fi
    return 0
}

# State persistence heartbeat — commits pipeline-state.md + progress.md when the
# state file has changed (sha1 comparison) up to every SHIPWRIGHT_HEARTBEAT_INTERVAL
# seconds (default 600s). Interval is captured at startup; runtime changes to the
# env var do not affect a running heartbeat. Only runs in CI mode. Uses the same
# flock push lock (.push.lock) as persist_artifacts to prevent concurrent git-push
# races.
_STATE_HEARTBEAT_PID=""

_start_state_heartbeat() {
    [[ "${CI_MODE:-false}" == "true" && -n "${WORKSPACE_BRANCH:-}" ]] || return 0
    local _hb_branch="$WORKSPACE_BRANCH"
    local _hb_state_file="${STATE_FILE:-.claude/pipeline-state.md}"
    local _hb_artifacts_dir="${ARTIFACTS_DIR:-}"
    local _hb_issue="${ISSUE_NUMBER:-}"
    local _hb_interval="${SHIPWRIGHT_HEARTBEAT_INTERVAL:-600}"
    (
        local _last_sha=""
        while sleep "$_hb_interval"; do
            local _cur_sha
            _cur_sha=$(shasum -a 1 "$_hb_state_file" 2>/dev/null | awk '{print $1}' \
                || sha1sum "$_hb_state_file" 2>/dev/null | awk '{print $1}' \
                || echo "")
            [[ -z "$_cur_sha" || "$_cur_sha" == "$_last_sha" ]] && continue
            # Snapshot progress.md into artifacts dir
            if [[ -n "$_hb_artifacts_dir" && -f ".claude/loop-logs/progress.md" ]]; then
                cp ".claude/loop-logs/progress.md" "${_hb_artifacts_dir}/progress.md" 2>/dev/null || true
            fi
            # Commit + push with lock to avoid racing persist_artifacts
            local _lock_file="${_hb_state_file%/*}/.push.lock"
            if command -v flock >/dev/null 2>&1; then
                (
                    flock -n 9 2>/dev/null || exit 0
                    # Copy state files into issue-scoped snapshot dir (never stage root paths).
                    if [[ -n "$_hb_artifacts_dir" && -n "$_hb_issue" ]]; then
                        local _hb_snap_dir="${_hb_artifacts_dir}/issue-${_hb_issue}"
                        mkdir -p "$_hb_snap_dir" 2>/dev/null || true
                        cp "$_hb_state_file" "${_hb_snap_dir}/pipeline-state.md" 2>/dev/null || true
                        local _hb_status_file="${_hb_state_file%pipeline-state.md}pipeline-status.json"
                        [[ -f "$_hb_status_file" ]] && cp "$_hb_status_file" "${_hb_snap_dir}/pipeline-status.json" 2>/dev/null || true
                        git add -f "${_hb_snap_dir}/pipeline-state.md" \
                                   "${_hb_snap_dir}/pipeline-status.json" 2>/dev/null || true
                    fi
                    [[ -n "$_hb_artifacts_dir" ]] && git add -f "${_hb_artifacts_dir}/progress.md" 2>/dev/null || true
                    if ! git diff --cached --quiet 2>/dev/null; then
                        git commit -m "chore: heartbeat state snapshot for #${_hb_issue} [skip ci]" \
                            --no-verify 2>/dev/null || true
                    fi
                    _assert_push_target_matches_active_issue "$_hb_branch" 2>/dev/null || {
                        echo "[HEARTBEAT-GUARD] push blocked: branch $_hb_branch does not match active issue ${_hb_issue}" >&2
                        exit 0
                    }
                    _timeout 30 git push --force-with-lease origin \
                        "HEAD:refs/heads/${_hb_branch}" 2>/dev/null || true
                ) 9>"$_lock_file"
            else
                # Copy state files into issue-scoped snapshot dir (never stage root paths).
                if [[ -n "$_hb_artifacts_dir" && -n "$_hb_issue" ]]; then
                    local _hb_snap_dir="${_hb_artifacts_dir}/issue-${_hb_issue}"
                    mkdir -p "$_hb_snap_dir" 2>/dev/null || true
                    cp "$_hb_state_file" "${_hb_snap_dir}/pipeline-state.md" 2>/dev/null || true
                    local _hb_status_file="${_hb_state_file%pipeline-state.md}pipeline-status.json"
                    [[ -f "$_hb_status_file" ]] && cp "$_hb_status_file" "${_hb_snap_dir}/pipeline-status.json" 2>/dev/null || true
                    git add -f "${_hb_snap_dir}/pipeline-state.md" \
                               "${_hb_snap_dir}/pipeline-status.json" 2>/dev/null || true
                fi
                [[ -n "$_hb_artifacts_dir" ]] && git add -f "${_hb_artifacts_dir}/progress.md" 2>/dev/null || true
                if ! git diff --cached --quiet 2>/dev/null; then
                    git commit -m "chore: heartbeat state snapshot for #${_hb_issue} [skip ci]" \
                        --no-verify 2>/dev/null || true
                fi
                _assert_push_target_matches_active_issue "$_hb_branch" 2>/dev/null || {
                    echo "[HEARTBEAT-GUARD] push blocked: branch $_hb_branch does not match active issue ${_hb_issue}" >&2
                    continue
                }
                _timeout 30 git push --force-with-lease origin \
                    "HEAD:refs/heads/${_hb_branch}" 2>/dev/null || true
            fi
            _last_sha="$_cur_sha"
        done
    ) &
    _STATE_HEARTBEAT_PID=$!
    info "State heartbeat: started (every ${_hb_interval}s, pid=${_STATE_HEARTBEAT_PID})"
}

_stop_state_heartbeat() {
    [[ -n "${_STATE_HEARTBEAT_PID:-}" ]] || return 0
    kill "$_STATE_HEARTBEAT_PID" 2>/dev/null || true
    wait "$_STATE_HEARTBEAT_PID" 2>/dev/null || true
    unset _STATE_HEARTBEAT_PID
}

ci_push_partial_work() {
    local push_timeout="${1:-5}"   # 5s default for SIGTERM grace path; watchdog passes 120
    [[ "${CI_MODE:-false}" != "true" ]] && return 0
    [[ -z "${ISSUE_NUMBER:-}" ]] && return 0
    [[ "${NO_GITHUB:-false}" == "true" || "${NO_ARTIFACT_PUSH:-false}" == "true" ]] && return 0
    [[ "${_PIPELINE_RUN_STARTED:-false}" == "true" ]] || return 0

    local _expected_wip="shipwright/issue-${ISSUE_NUMBER}"
    local _actual_head
    _actual_head=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    if [[ -n "$_actual_head" && "$_actual_head" != "HEAD" && "$_actual_head" != "$_expected_wip" ]]; then
        echo "[WIP-PUSH-SKIP] HEAD=${_actual_head} != expected ${_expected_wip} — skipping to prevent cross-branch pollution" >&2
        return 0
    fi

    local branch="shipwright/issue-${ISSUE_NUMBER}"
    echo "[WIP-PUSH-START] $(date -u +%FT%TZ) issue=${ISSUE_NUMBER} timeout=${push_timeout}s caller=${FUNCNAME[1]:-top}" >&2

    # Force-add issue-scoped artifact snapshots — .gitignore ignores the parent
    # pipeline-artifacts/ directory as a unit, which silently defeats the !issue-*/
    # negation rule. git add -f bypasses .gitignore for these specific paths.
    local _snap_dir="${ARTIFACTS_DIR:-${STATE_DIR:-}/pipeline-artifacts}/issue-${ISSUE_NUMBER}"
    [[ -d "$_snap_dir" ]] && git add -f "$_snap_dir/" 2>/dev/null || true

    # Only push if we have uncommitted changes (excluding bookkeeping files; runtime
    # files like pipeline-state.md are legitimate partial-progress markers here)
    if ! git diff --quiet -- $(_git_bookkeeping_pathspecs) 2>/dev/null || \
       ! git diff --cached --quiet -- $(_git_bookkeeping_pathspecs) 2>/dev/null; then
        safe_git_stage
        git commit -m "WIP: partial pipeline progress for #${ISSUE_NUMBER} [skip ci]" --no-verify 2>/dev/null || true
    fi

    # Push branch (create if needed, force to overwrite previous WIP).
    # Use GITHUBTOKEN (PAT with workflow scope) when available so branches
    # that include workflow file changes are not rejected by GITHUB_TOKEN.
    local _wip_repo_slug=""
    if [[ -n "${GITHUBTOKEN:-}" ]]; then
        _wip_repo_slug=$(git remote get-url origin 2>/dev/null | sed 's|.*github\.com[:/]||;s|\.git$||')
        git config --unset-all "http.https://github.com/.extraheader" 2>/dev/null || true
        git remote set-url origin "https://x-access-token:${GITHUBTOKEN}@github.com/${_wip_repo_slug}.git" 2>/dev/null || true
    fi
    local _guard_rc=0
    _assert_push_target_matches_active_issue "$branch" || _guard_rc=$?
    if [[ "$_guard_rc" -ne 0 ]]; then
        [[ -n "${_wip_repo_slug:-}" ]] && git remote set-url origin "https://github.com/${_wip_repo_slug}.git" 2>/dev/null || true
        return "$_guard_rc"
    fi
    if _timeout "$push_timeout" git push origin "HEAD:refs/heads/$branch" --force 2>/dev/null; then
        echo "[WIP-PUSH-OK] $(date -u +%FT%TZ) branch=$branch" >&2
    else
        local _push_rc=$?
        echo "[WIP-PUSH-FAIL] $(date -u +%FT%TZ) branch=$branch exit=${_push_rc}" >&2
        warn "git push failed for $branch — remote may be out of sync"
        emit_event "pipeline.push_failed" "branch=$branch exit=${_push_rc}"
        return "$_push_rc"
    fi
    # Scrub PAT from remote URL after push
    if [[ -n "${_wip_repo_slug:-}" ]]; then
        git remote set-url origin "https://github.com/${_wip_repo_slug}.git" 2>/dev/null || true
    fi
}

# Push final pipeline artifacts to the WIP branch on any exit (success or failure,
# local or CI). Unlike ci_push_partial_work, this is NOT gated on CI_MODE — the
# intent is that local runs also leave a complete audit trail on origin.
pipeline_final_artifact_push() {
    local push_timeout="${1:-60}"
    [[ -z "${ISSUE_NUMBER:-}" ]] && return 0
    [[ "${NO_GITHUB:-false}" == "true" || "${NO_ARTIFACT_PUSH:-false}" == "true" ]] && return 0
    [[ "${DRY_RUN:-false}" == "true" ]] && return 0

    local branch="shipwright/issue-${ISSUE_NUMBER}"
    echo "[ARTIFACT-PUSH-START] $(date -u +%FT%TZ) issue=${ISSUE_NUMBER} timeout=${push_timeout}s" >&2

    # Force-add issue-scoped artifact snapshots (.gitignore bypassed intentionally).
    local _snap_dir="${ARTIFACTS_DIR:-${STATE_DIR:-}/pipeline-artifacts}/issue-${ISSUE_NUMBER}"
    [[ -d "$_snap_dir" ]] && git add -f "$_snap_dir/" 2>/dev/null || true

    # Stage progress.md from the artifacts dir (not the repo root, which has no such file).
    # Root state files must not be committed — they leak to main on merge; the issue-N/
    # snapshot staged above is the correct resume path for the GHA restore step.
    git add -f "${ARTIFACTS_DIR}/progress.md" 2>/dev/null || true

    # Only commit if there are unstaged/staged changes (excluding bookkeeping files;
    # the issue-N/ snapshot dir and progress.md are force-added above and must trigger this commit)
    if ! git diff --quiet -- $(_git_bookkeeping_pathspecs) 2>/dev/null || \
       ! git diff --cached --quiet -- $(_git_bookkeeping_pathspecs) 2>/dev/null; then
        safe_git_stage
        git commit -m "chore: pipeline artifacts for #${ISSUE_NUMBER}" --no-verify 2>/dev/null || true
    fi

    # Push with PAT (workflow scope) when available — required if any artifact
    # includes a .github/workflows/ file; harmless when not.
    local _af_repo_slug=""
    if [[ -n "${GITHUBTOKEN:-}" ]]; then
        _af_repo_slug=$(git remote get-url origin 2>/dev/null | sed 's|.*github\.com[:/]||;s|\.git$||')
        git config --unset-all "http.https://github.com/.extraheader" 2>/dev/null || true
        git remote set-url origin "https://x-access-token:${GITHUBTOKEN}@github.com/${_af_repo_slug}.git" 2>/dev/null || true
    fi
    local _guard_rc=0
    _assert_push_target_matches_active_issue "$branch" || _guard_rc=$?
    if [[ "$_guard_rc" -ne 0 ]]; then
        git remote set-url origin "https://github.com/${_af_repo_slug}.git" 2>/dev/null || true
        return "$_guard_rc"
    fi
    if _timeout "$push_timeout" git push origin "HEAD:refs/heads/$branch" --force 2>/dev/null; then
        echo "[ARTIFACT-PUSH-OK] $(date -u +%FT%TZ) branch=$branch" >&2
    else
        local _push_rc=$?
        echo "[ARTIFACT-PUSH-FAIL] $(date -u +%FT%TZ) branch=$branch exit=${_push_rc}" >&2
        type warn >/dev/null 2>&1 && warn "artifact push failed for $branch — remote may be out of sync"
        type emit_event >/dev/null 2>&1 && emit_event "pipeline.artifact_push_failed" "branch=$branch exit=${_push_rc}"
    fi
    # Scrub PAT from remote URL after push.
    if [[ -n "${_af_repo_slug:-}" ]]; then
        git remote set-url origin "https://github.com/${_af_repo_slug}.git" 2>/dev/null || true
    fi
    return 0  # Never fail the pipeline — this is an audit step.
}

ci_post_stage_event() {
    [[ "${CI_MODE:-false}" != "true" ]] && return 0
    [[ -z "${ISSUE_NUMBER:-}" ]] && return 0
    [[ "${GH_AVAILABLE:-false}" != "true" ]] && return 0

    local stage="$1" status="$2" elapsed="${3:-0s}"
    local emoji
    case "$status" in
        complete) emoji="✅" ;;
        failed)   emoji="❌" ;;
        skipped)  emoji="⏭️" ;;
        *)        emoji="🔄" ;;
    esac
    # Visible body first so readers see content; HTML comment retained for
    # watchdog parsing (shipwright-watchdog.yml uses `contains("SHIPWRIGHT-STAGE")`).
    local comment
    comment="${emoji} Pipeline update — \`${stage}\` stage **${status}** (${elapsed})
<!-- SHIPWRIGHT-STAGE: ${stage}:${status}:${elapsed} -->"
    _timeout "$(_config_get_int "network.gh_timeout" 30 2>/dev/null || echo 30)" gh issue comment "$ISSUE_NUMBER" --body "$comment" >/dev/null 2>&1 || true
}

# ─── Signal Handling ───────────────────────────────────────────────────────

# Set to true when a signal (SIGINT/SIGTERM) drives the cleanup, so that the
# EXIT trap can distinguish signal-driven interruption from normal completion.
_PIPELINE_SIGNALED=false

cleanup_on_exit() {
    local exit_code=$?
    local _grace="${PIPELINE_KILL_GRACE:-25}"
    [[ "$_grace" =~ ^[0-9]+$ ]] || _grace=25
    [[ "${_cleanup_done:-}" == "true" ]] && return 0
    _cleanup_done=true
    _stop_state_heartbeat

    # Only mark as interrupted and post GitHub comment if actually signal-driven.
    # On clean completions the pipeline stages handle their own state/comments.
    if [[ "$_PIPELINE_SIGNALED" == "true" && "$PIPELINE_STATUS" == "running" && -n "$STATE_FILE" ]]; then
        PIPELINE_STATUS="interrupted"
        UPDATED_AT="$(now_iso)"
        write_state 2>/dev/null || true
        echo ""
        warn "Pipeline interrupted — state saved."
        echo -e "  Resume: ${DIM}shipwright pipeline resume${RESET}"

        # Cancel lingering in_progress GitHub Check Runs
        pipeline_cancel_check_runs 2>/dev/null || true

        # Update GitHub
        if [[ -n "${ISSUE_NUMBER:-}" && "${GH_AVAILABLE:-false}" == "true" ]]; then
            if ! _timeout "$(_config_get_int "network.gh_timeout" 30 2>/dev/null || echo 30)" gh issue comment "$ISSUE_NUMBER" --body "⏸️ **Pipeline interrupted** at stage: ${CURRENT_STAGE_ID:-unknown}" 2>/dev/null; then
                warn "gh issue comment failed — status update may not have been posted"
                emit_event "pipeline.comment_failed" "issue=$ISSUE_NUMBER"
            fi
        fi
    fi

    # Push WIP on any non-zero CI exit — signal-driven OR stage-failure.
    # Use 60s timeout — stage-failure path needs headroom for first-time remote branch creation.
    if [[ "${CI_MODE:-false}" == "true" \
          && -n "${ISSUE_NUMBER:-}" \
          && "$exit_code" -ne 0 \
          && "${_PIPELINE_RUN_STARTED:-false}" == "true" ]]; then
        ci_push_partial_work 60
    fi

    # Push final artifacts on all exits (success + failure, local + CI).
    # Captures post-PR stage outputs (deploy/validate/monitor) that ci_push_partial_work
    # misses (it only runs on CI failure).
    if [[ -n "${ISSUE_NUMBER:-}" \
          && "${_PIPELINE_RUN_STARTED:-false}" == "true" ]]; then
        pipeline_final_artifact_push 60 || true
    fi

    # Generate cost-breakdown.json from sidecars on every exit path (issue #87 AC#4).
    # Doing this here (rather than only after the success block at line ~3038) means
    # an aborted/interrupted pipeline still produces an artifact for forensics.
    if type cost_generate_breakdown >/dev/null 2>&1 && [[ -n "${ARTIFACTS_DIR:-}" ]] && [[ -d "$ARTIFACTS_DIR" ]]; then
        local _bd_pid="${SHIPWRIGHT_PIPELINE_ID:-pipeline-$$-${ISSUE_NUMBER:-0}}"
        cost_generate_breakdown "$ARTIFACTS_DIR" "$_bd_pid" "${ISSUE_NUMBER:-}" >/dev/null 2>&1 || true

        # #504 D2: roll into baselines + render the per-stage cost table on success.
        # Order mirrors cost_breakdown_command (sw-cost.sh:1162-1172): RENDER FIRST so the
        # table reflects the comparison vs PRIOR runs, then UPDATE the baseline last.
        local _bd_file="${ARTIFACTS_DIR}/cost-breakdown.json"
        if [[ -f "$_bd_file" ]]; then
            if [[ "$exit_code" -eq 0 ]] && type render_cost_table_plain >/dev/null 2>&1; then
                local _issue_arg=()
                [[ -n "${ISSUE_NUMBER:-}" ]] && _issue_arg=(--issue "$ISSUE_NUMBER")
                render_cost_table_plain "$_bd_file" "${_issue_arg[@]}" --baseline-context 2>/dev/null || true
            fi
            if type cost_baseline_update >/dev/null 2>&1; then
                cost_baseline_update "$_bd_file" "${ISSUE_NUMBER:-}" >/dev/null 2>&1 || true
            fi
        fi
    fi

    # Push discoveries to shared orphan branch for cross-machine access
    if declare -f sw_discovery_ci_push >/dev/null 2>&1 \
       && [[ "${_PIPELINE_RUN_STARTED:-false}" == "true" ]]; then
        sw_discovery_ci_push || true
    fi

    # Cleanup ruflo MCP server
    if type ruflo_cleanup >/dev/null 2>&1; then
        ruflo_cleanup || true
    fi

    # Stop heartbeat writer
    stop_heartbeat

    # Restore stashed changes
    if [[ "$STASHED_CHANGES" == "true" ]]; then
        git stash pop --quiet 2>/dev/null || true
    fi

    # Release durable pipeline lock
    if [[ -n "${_PIPELINE_LOCK_ID:-}" ]] && type release_lock >/dev/null 2>&1; then
        release_lock "$_PIPELINE_LOCK_ID" 2>/dev/null || true
    fi

    # Release per-host admission lock — idempotent, safe to call even if
    # pipeline_start was refused before write_active_pipeline_lock ran.
    release_active_pipeline_lock 2>/dev/null || true

    # Kill the entire process group when we are the setsid group leader AND the
    # exit is non-zero. Previously gated on _PIPELINE_SIGNALED==true, which meant
    # error-path exits (set -e failure, audit failure, OOM, watchdog kill -9) never
    # triggered the group kill — leaving Claude workers and tool subprocesses alive.
    # Skip on exit_code==0 to preserve intentionally detached post-run jobs.
    if [[ "$exit_code" -ne 0 ]]; then
        local _our_pgid
        _our_pgid=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ') || true
        if [[ "${_our_pgid:-}" == "$$" ]]; then
            if declare -f _kill_process_group_safe >/dev/null 2>&1; then
                _kill_process_group_safe "$$" "$_grace" 2>/dev/null || true
            else
                kill -- -$$ 2>/dev/null || true
                sleep "$_grace"
                kill -9 -- -$$ 2>/dev/null || true
            fi
        fi
    fi

    exit "$exit_code"
}

_signal_cleanup() {
    _PIPELINE_SIGNALED=true
    cleanup_on_exit
}

trap cleanup_on_exit EXIT
trap _signal_cleanup SIGINT SIGTERM

# ─── Pre-flight Validation ─────────────────────────────────────────────────

preflight_checks() {
    local errors=0
    local ai_provider ai_cmd
    ai_provider="$(ai_provider_resolve "${SHIPWRIGHT_AI_PROVIDER:-}" 2>/dev/null || echo "claude")"
    ai_cmd="$(ai_provider_command "$ai_provider" 2>/dev/null || echo "$ai_provider")"

    echo -e "${PURPLE}${BOLD}━━━ Pre-flight Checks ━━━${RESET}"
    echo ""

    # 1. Required tools
    local required_tools=("git" "jq")
    local optional_tools=("gh" "$ai_cmd" "bc" "curl")

    for tool in "${required_tools[@]}"; do
        if command -v "$tool" >/dev/null 2>&1; then
            echo -e "  ${GREEN}✓${RESET} $tool"
        else
            echo -e "  ${RED}✗${RESET} $tool ${RED}(required)${RESET}"
            errors=$((errors + 1))
        fi
    done

    for tool in "${optional_tools[@]}"; do
        if command -v "$tool" >/dev/null 2>&1; then
            echo -e "  ${GREEN}✓${RESET} $tool"
        else
            echo -e "  ${DIM}○${RESET} $tool ${DIM}(optional — some features disabled)${RESET}"
        fi
    done

    # 2. Git state
    echo ""
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${RESET} Inside git repo"
    else
        echo -e "  ${RED}✗${RESET} Not inside a git repository"
        errors=$((errors + 1))
    fi

    # Check for uncommitted changes — offer to stash (excluding daemon-config.json runtime writes)
    local dirty_files
    dirty_files=$(_trim "$(git status --porcelain 2>/dev/null | grep -v '\.claude/daemon-config\.json' | wc -l)")
    if [[ "$dirty_files" -gt 0 ]]; then
        echo -e "  ${YELLOW}⚠${RESET} $dirty_files uncommitted change(s)"
        if [[ "$SKIP_GATES" == "true" ]]; then
            info "Auto-stashing uncommitted changes..."
            git stash push -m "sw-pipeline: auto-stash before pipeline" --quiet 2>/dev/null && STASHED_CHANGES=true
            if [[ "$STASHED_CHANGES" == "true" ]]; then
                echo -e "  ${GREEN}✓${RESET} Changes stashed (will restore on exit)"
            fi
        else
            echo -e "    ${DIM}Tip: Use --skip-gates to auto-stash, or commit/stash manually${RESET}"
        fi
    else
        echo -e "  ${GREEN}✓${RESET} Working tree clean"
    fi

    # Check if base branch exists
    if git rev-parse --verify "$BASE_BRANCH" >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${RESET} Base branch: $BASE_BRANCH"
    else
        echo -e "  ${RED}✗${RESET} Base branch not found: $BASE_BRANCH"
        errors=$((errors + 1))
    fi

    # 3. GitHub auth (if gh available and not disabled)
    if [[ "$NO_GITHUB" != "true" ]] && command -v gh >/dev/null 2>&1; then
        if gh auth status >/dev/null 2>&1; then
            echo -e "  ${GREEN}✓${RESET} GitHub authenticated"
        else
            echo -e "  ${YELLOW}⚠${RESET} GitHub not authenticated (features disabled)"
        fi
    fi

    # 4. AI provider readiness
    if ai_provider_check_ready "$ai_provider" >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${RESET} AI provider ready (${ai_provider}: ${ai_cmd})"
    else
        echo -e "  ${RED}✗${RESET} AI provider not ready (${ai_provider}: ${ai_cmd}) — plan/build stages will fail"
        errors=$((errors + 1))
    fi

    # 5. sw loop (needed for build stage)
    if [[ -x "$SCRIPT_DIR/sw-loop.sh" ]]; then
        echo -e "  ${GREEN}✓${RESET} shipwright loop available"
    else
        echo -e "  ${RED}✗${RESET} sw-loop.sh not found at $SCRIPT_DIR"
        errors=$((errors + 1))
    fi

    # 6. Disk space check (warn if < 1GB free)
    local free_space_kb
    free_space_kb=$(df -k "$PROJECT_ROOT" 2>/dev/null | tail -1 | awk '{print $4}')
    if [[ -n "$free_space_kb" ]] && [[ "$free_space_kb" -lt 1048576 ]] 2>/dev/null; then
        echo -e "  ${YELLOW}⚠${RESET} Low disk space: $(( free_space_kb / 1024 ))MB free"
    fi

    echo ""

    if [[ "$errors" -gt 0 ]]; then
        error "Pre-flight failed: $errors error(s)"
        return 1
    fi

    success "Pre-flight passed"
    echo ""
    return 0
}

# ─── Notification Helpers ──────────────────────────────────────────────────

notify() {
    local title="$1" message="$2" level="${3:-info}"
    local emoji
    case "$level" in
        success) emoji="✅" ;;
        error)   emoji="❌" ;;
        warn)    emoji="⚠️" ;;
        *)       emoji="🔔" ;;
    esac

    # Slack webhook
    if [[ -n "${SLACK_WEBHOOK:-}" ]]; then
        local payload
        payload=$(jq -n \
            --arg text "${emoji} *${title}*\n${message}" \
            '{text: $text}')
        curl -sf --connect-timeout "$(_config_get_int "network.connect_timeout" 10 2>/dev/null || echo 10)" --max-time "$(_config_get_int "network.max_time" 60 2>/dev/null || echo 60)" -X POST -H 'Content-Type: application/json' \
            -d "$payload" "$SLACK_WEBHOOK" >/dev/null 2>&1 || true
    fi

    # Custom webhook (env var SHIPWRIGHT_WEBHOOK_URL)
    local _webhook_url="${SHIPWRIGHT_WEBHOOK_URL:-}"
    if [[ -n "$_webhook_url" ]]; then
        local payload
        payload=$(jq -n \
            --arg title "$title" --arg message "$message" \
            --arg level "$level" --arg pipeline "${PIPELINE_NAME:-}" \
            --arg goal "${GOAL:-}" --arg stage "${CURRENT_STAGE_ID:-}" \
            '{title:$title, message:$message, level:$level, pipeline:$pipeline, goal:$goal, stage:$stage}')
        curl -sf --connect-timeout 10 --max-time 30 -X POST -H 'Content-Type: application/json' \
            -d "$payload" "$_webhook_url" >/dev/null 2>&1 || true
    fi
}

# ─── Error Classification ──────────────────────────────────────────────────
# Classifies errors to determine whether retrying makes sense.
# Returns: "infrastructure", "logic", "configuration", or "unknown"

classify_error() {
    local stage_id="$1"
    local log_file="${ARTIFACTS_DIR}/${stage_id}-results.log"
    [[ ! -f "$log_file" ]] && log_file="${ARTIFACTS_DIR}/test-results.log"
    [[ ! -f "$log_file" ]] && { echo "unknown"; return; }

    local log_tail
    log_tail=$(tail -50 "$log_file" 2>/dev/null || echo "")

    # Generate error signature for history lookup
    local error_sig
    error_sig=$(echo "$log_tail" | grep -iE 'error|fail|exception|fatal' 2>/dev/null | head -3 | cksum | awk '{print $1}' || echo "0")

    # Check classification history first (learned from previous runs)
    local class_history="${HOME}/.shipwright/optimization/error-classifications.json"
    if [[ -f "$class_history" ]]; then
        local cached_class
        cached_class=$(jq -r --arg sig "$error_sig" '.[$sig].classification // empty' "$class_history" 2>/dev/null || true)
        if [[ -n "$cached_class" && "$cached_class" != "null" ]]; then
            echo "$cached_class"
            return
        fi
    fi

    local classification="unknown"

    # Infrastructure errors: timeout, OOM, network — retry makes sense
    if echo "$log_tail" | grep -qiE 'timeout|timed out|ETIMEDOUT|ECONNREFUSED|ECONNRESET|network|socket hang up|OOM|out of memory|killed|signal 9|Cannot allocate memory'; then
        classification="infrastructure"
    # Configuration errors: missing env, wrong path — don't retry, escalate
    elif echo "$log_tail" | grep -qiE 'ENOENT|not found|No such file|command not found|MODULE_NOT_FOUND|Cannot find module|missing.*env|undefined variable|permission denied|EACCES'; then
        classification="configuration"
    # Logic errors: assertion failures, type errors — retry won't help without code change
    elif echo "$log_tail" | grep -qiE 'AssertionError|assert.*fail|Expected.*but.*got|TypeError|ReferenceError|SyntaxError|CompileError|type mismatch|cannot assign|incompatible type'; then
        classification="logic"
    # Build errors: compilation failures
    elif echo "$log_tail" | grep -qiE 'error\[E[0-9]+\]|error: aborting|FAILED.*compile|build failed|tsc.*error|eslint.*error'; then
        classification="logic"
    # Intelligence fallback: Claude classification for unknown errors
    elif [[ "$classification" == "unknown" ]] && type intelligence_search_memory >/dev/null 2>&1 && [[ "$(type -t ai_run_json 2>/dev/null)" == "function" ]]; then
        local ai_class ai_json ai_provider ai_out ai_err
        ai_provider="$(ai_provider_resolve "${SHIPWRIGHT_AI_PROVIDER:-}" 2>/dev/null || echo "claude")"
        ai_out=$(mktemp "${TMPDIR:-/tmp}/sw-classify-ai.XXXXXX")
        ai_err=$(mktemp "${TMPDIR:-/tmp}/sw-classify-ai-err.XXXXXX")
        ai_json=$(ai_run_json "$ai_provider" "Classify this error as exactly one of: infrastructure, configuration, logic, unknown.

Error output:
$(echo "$log_tail" | tail -20)

Reply with ONLY the classification word, nothing else." "haiku" "1" "$ai_out" "$ai_err" 2>/dev/null || true)
        rm -f "$ai_out" "$ai_err"
        ai_class=$(echo "$ai_json" | jq -r '.result_text // ""' 2>/dev/null || echo "")
        ai_class=$(echo "$ai_class" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
        case "$ai_class" in
            infrastructure|configuration|logic) classification="$ai_class" ;;
        esac
    fi

    # Map retry categories to shared taxonomy (from lib/compat.sh SW_ERROR_CATEGORIES)
    # Retry uses: infrastructure, configuration, logic, unknown
    # Shared uses: test_failure, build_error, lint_error, timeout, dependency, flaky, config, security, permission, unknown
    local canonical_category="unknown"
    case "$classification" in
        infrastructure) canonical_category="timeout" ;;
        configuration)  canonical_category="config" ;;
        logic)
            case "$stage_id" in
                test) canonical_category="test_failure" ;;
                *)    canonical_category="build_error" ;;
            esac
            ;;
    esac

    # Record classification for future runs (using both retry and canonical categories)
    if [[ -n "$error_sig" && "$error_sig" != "0" ]]; then
        local class_dir="${HOME}/.shipwright/optimization"
        mkdir -p "$class_dir" 2>/dev/null || true
        local tmp_class
        tmp_class="$(mktemp)"
        # shellcheck disable=SC2064  # intentional expansion at definition time
        trap "rm -f '$tmp_class'" RETURN
        if [[ -f "$class_history" ]]; then
            jq --arg sig "$error_sig" --arg cls "$classification" --arg canon "$canonical_category" --arg stage "$stage_id" \
                '.[$sig] = {"classification": $cls, "canonical": $canon, "stage": $stage, "recorded_at": now}' \
                "$class_history" > "$tmp_class" 2>/dev/null && \
                mv "$tmp_class" "$class_history" || rm -f "$tmp_class"
        else
            jq -n --arg sig "$error_sig" --arg cls "$classification" --arg canon "$canonical_category" --arg stage "$stage_id" \
                '{($sig): {"classification": $cls, "canonical": $canon, "stage": $stage, "recorded_at": now}}' \
                > "$tmp_class" 2>/dev/null && \
                mv "$tmp_class" "$class_history" || rm -f "$tmp_class"
        fi
    fi

    echo "$classification"
}

# ─── Stage Runner ───────────────────────────────────────────────────────────

run_stage_with_retry() {
    local stage_id="$1"
    local max_retries
    max_retries=$(jq -r --arg id "$stage_id" '(.stages[] | select(.id == $id) | .config.retries) // 0' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$max_retries" || "$max_retries" == "null" ]] && max_retries=0

    # Guard: fail fast if stage function doesn't exist.
    # Without this, a missing function exits 127 and classify_error returns
    # "unknown" (no log file exists since the stage never ran), causing useless
    # retries when the stage has retries configured.
    # Use `type -t` (not plain `type`) to confirm it's a shell function, not
    # an executable on PATH that happens to share the name.
    if [[ "$(type -t "stage_${stage_id}" 2>/dev/null)" != "function" ]]; then
        error "stage_${stage_id}: function not defined — lib file may not have sourced correctly"
        emit_event "stage.failed" \
            "issue=${ISSUE_NUMBER:-0}" \
            "stage=$stage_id" \
            "error_class=missing_function"
        return 1
    fi

    local attempt=0
    local prev_error_class=""
    while true; do
        # Bracket every stage attempt for per-stage cost attribution (issue #87).
        # _start snapshots token totals; _end records the delta to stage-costs.jsonl
        # and the global cost ledger. Re-snapshotting on retry is intentional —
        # each attempt's delta is the cost incurred during that attempt.
        if type record_stage_cost_start >/dev/null 2>&1; then
            record_stage_cost_start "$stage_id"
        fi
        if "stage_${stage_id}"; then
            if type record_stage_cost_end >/dev/null 2>&1; then
                record_stage_cost_end "$stage_id"
            fi
            return 0
        fi
        if type record_stage_cost_end >/dev/null 2>&1; then
            record_stage_cost_end "$stage_id"
        fi

        # Capture error_class and error snippet for stage.failed / pipeline.completed events
        local error_class
        error_class=$(classify_error "$stage_id")
        LAST_STAGE_ERROR_CLASS="$error_class"
        LAST_STAGE_ERROR=""
        local _log_file="${ARTIFACTS_DIR}/${stage_id}-results.log"
        [[ ! -f "$_log_file" ]] && _log_file="${ARTIFACTS_DIR}/test-results.log"
        if [[ -f "$_log_file" ]]; then
            LAST_STAGE_ERROR=$(tail -20 "$_log_file" 2>/dev/null | grep -iE 'error|fail|exception|fatal' 2>/dev/null | head -1 | cut -c1-200 || true)
        fi

        attempt=$((attempt + 1))

        # Critical fix: if plan stage already has a valid artifact, skip retry
        if [[ "$stage_id" == "plan" ]]; then
            local plan_artifact="${ARTIFACTS_DIR}/plan.md"
            if [[ -s "$plan_artifact" ]]; then
                local existing_lines
                existing_lines=$(_trim "$(wc -l < "$plan_artifact" 2>/dev/null)")
                existing_lines="${existing_lines:-0}"
                if [[ "$existing_lines" -gt 10 ]]; then
                    info "Plan already exists (${existing_lines} lines) — skipping retry, advancing"
                    emit_event "retry.skipped_existing_artifact" \
                        "issue=${ISSUE_NUMBER:-0}" \
                        "stage=$stage_id" \
                        "artifact_lines=$existing_lines"
                    return 0
                fi
            fi
        fi

        if [[ "$attempt" -gt "$max_retries" ]]; then
            return 1
        fi

        # Classify done above; decide whether retry makes sense

        emit_event "retry.classified" \
            "issue=${ISSUE_NUMBER:-0}" \
            "stage=$stage_id" \
            "attempt=$attempt" \
            "error_class=$error_class"

        case "$error_class" in
            infrastructure)
                info "Error classified as infrastructure (timeout/network/OOM) — retry makes sense"
                ;;
            configuration)
                error "Error classified as configuration (missing env/path) — skipping retry, escalating"
                emit_event "retry.escalated" \
                    "issue=${ISSUE_NUMBER:-0}" \
                    "stage=$stage_id" \
                    "reason=configuration_error"
                return 1
                ;;
            logic)
                if [[ "$error_class" == "$prev_error_class" ]]; then
                    error "Error classified as logic (assertion/type error) with same class — retry won't help without code change"
                    emit_event "retry.skipped" \
                        "issue=${ISSUE_NUMBER:-0}" \
                        "stage=$stage_id" \
                        "reason=repeated_logic_error"
                    return 1
                fi
                warn "Error classified as logic — retrying once in case build fixes it"
                ;;
            *)
                info "Error classification: unknown — retrying"
                ;;
        esac
        prev_error_class="$error_class"

        if type db_save_reasoning_trace >/dev/null 2>&1; then
            local job_id="${SHIPWRIGHT_PIPELINE_ID:-$$}"
            local error_msg="${LAST_STAGE_ERROR:-$error_class}"
            db_save_reasoning_trace "$job_id" "retry_reasoning" \
                "stage=$stage_id error=$error_msg" \
                "Stage failed, analyzing error pattern before retry" \
                "retry_strategy=self_heal" 0.6 2>/dev/null || true
        fi

        warn "Stage $stage_id failed (attempt $attempt/$((max_retries + 1)), class: $error_class) — retrying..."
        # Exponential backoff with jitter to avoid thundering herd
        local backoff=$((2 ** attempt))
        [[ "$backoff" -gt 16 ]] && backoff=16
        local jitter=$(( RANDOM % (backoff + 1) ))
        local total_sleep=$((backoff + jitter))
        info "Backing off ${total_sleep}s before retry..."
        sleep "$total_sleep"

        # Write debugging context for the retry attempt to consume
        local _retry_ctx_file="${ARTIFACTS_DIR}/.retry-context-${stage_id}.md"
        {
            echo "## Previous Attempt Failed"
            echo ""
            echo "**Error classification:** ${error_class}"
            echo "**Attempt:** ${attempt} of $((max_retries + 1))"
            echo ""
            echo "### Error Output (last 30 lines)"
            echo '```'
            tail -30 "$_log_file" 2>/dev/null || echo "(no log available)"
            echo '```'
            echo ""
            # Check for existing artifacts that should be preserved
            local _existing_artifacts=""
            for _af in plan.md design.md test-results.log; do
                if [[ -s "${ARTIFACTS_DIR}/${_af}" ]]; then
                    local _af_lines
                    _af_lines=$(_trim "$(wc -l < "${ARTIFACTS_DIR}/${_af}" 2>/dev/null)")
                    _existing_artifacts="${_existing_artifacts}  - ${_af} (${_af_lines} lines)\n"
                fi
            done
            if [[ -n "$_existing_artifacts" ]]; then
                echo "### Existing Artifacts (PRESERVE these)"
                echo -e "$_existing_artifacts"
                echo "These artifacts exist from previous successful stages. Use them as-is unless they are the source of the problem."
                echo ""
            fi
            # Adaptive: check if additional skills could help this retry
            if type skill_memory_get_recommendations >/dev/null 2>&1; then
                local _retry_skills
                _retry_skills=$(skill_memory_get_recommendations "${INTELLIGENCE_ISSUE_TYPE:-backend}" "$stage_id" 2>/dev/null || true)
                if [[ -n "$_retry_skills" ]]; then
                    echo "### Skills Recommended by Learning System"
                    echo "Based on historical success rates, these skills may improve the retry:"
                    echo "- $(printf '%s' "$_retry_skills" | sed 's/,/\n- /g')"
                    echo ""
                fi
            fi

            echo "### Investigation Required"
            echo "Before attempting a fix:"
            echo "1. Read the error output above carefully"
            echo "2. Identify the ROOT CAUSE — not just the symptom"
            echo "3. If previous artifacts exist and are correct, build on them"
            echo "4. If previous artifacts are flawed, explain what's wrong before fixing"
        } > "$_retry_ctx_file" 2>/dev/null || true

        emit_event "retry.context_written" \
            "issue=${ISSUE_NUMBER:-0}" \
            "stage=$stage_id" \
            "attempt=$attempt" \
            "context_file=$_retry_ctx_file"
    done
}

# ─── Cycling Halt: Cumulative Test-Failure Counter ────────────────────────
# Reads `## Log` section of pipeline-state.md and returns the trailing run of
# consecutive `test` stage failures. Resets to 0 on any `test` `complete` entry.
# Survives daemon/pipeline restarts because the log is persisted to disk.
#
# Bash 3.2 compatible: no associative arrays; stage extraction uses sed instead of
# BASH_REMATCH array indexing to avoid any ambiguity on Bash 3.2 (macOS default).
#
# Format hardening (#448 review feedback): the stage-header regex accepts any
# non-whitespace stage id (digits, uppercase, custom stage names like `test_2`)
# so the parser doesn't silently drop entries when the log format drifts. We
# also warn (to stderr — log-only) when a non-empty log contains no `### test`
# headers at all, which would silently disable the cycling halt.
count_consecutive_test_failures() {
    local state_file="${1:-${STATE_FILE:-}}"
    if [[ -z "$state_file" || ! -f "$state_file" ]]; then
        echo 0
        return 0
    fi

    local in_log=0 current_stage="" outcomes="" saw_log_section=0 saw_any_test_header=0
    while IFS= read -r line; do
        if [[ "$line" == "## Log" ]]; then
            in_log=1
            saw_log_section=1
            continue
        fi
        [[ "$in_log" -eq 0 ]] && continue
        # Accept any stage id token (e.g. test, test_2, build, COMPOUND_QUALITY).
        # Outcome matching below filters to the `test` stage specifically.
        # sed extraction avoids BASH_REMATCH array indexing for Bash 3.2 portability.
        if [[ "$line" =~ ^###[[:space:]] ]]; then
            current_stage=$(printf '%s\n' "$line" | sed -E 's/^###[[:space:]]+([^[:space:]]+)[[:space:]].*/\1/')
            [[ "$current_stage" == "test" ]] && saw_any_test_header=1
            continue
        fi
        if [[ "$current_stage" == "test" ]]; then
            if [[ "$line" =~ ^complete ]]; then
                outcomes="$outcomes pass"
                current_stage=""
            elif [[ "$line" =~ ^failed ]]; then
                outcomes="$outcomes fail"
                current_stage=""
            fi
        fi
    done < "$state_file"

    # Defensive warning: log present but no `test` stage entries parsed. Either
    # the pipeline genuinely never reached the test stage (legitimate 0) or
    # the log format drifted and the parser silently missed entries. We only
    # warn when a literal `### test` header is visible in the file but the
    # parser failed to recognize it — a real format-drift signal.
    if [[ "$saw_log_section" -eq 1 && "$saw_any_test_header" -eq 0 ]]; then
        if grep -qE '^(##|####)[[:space:]]+test[[:space:]]' "$state_file" 2>/dev/null; then
            echo "WARN: count_consecutive_test_failures: state file '$state_file' contains 'test' stage headers at an unexpected heading level — log format may have drifted; cycling halt may be disabled" >&2
            emit_event "pipeline.cycling_halt_disabled" \
                "reason=log_format_drift" \
                "state_file=${state_file}" || true
        fi
    fi

    local count=0 word
    for word in $outcomes; do
        if [[ "$word" == "fail" ]]; then
            count=$((count + 1))
        elif [[ "$word" == "pass" ]]; then
            count=0
        fi
    done
    echo "$count"
}

# ─── Self-Healing Build→Test Feedback Loop ─────────────────────────────────
# When tests fail after a build, this captures the error and re-runs the build
# with the error context, so Claude can fix the issue automatically.

self_healing_build_test() {
    local cycle=0
    local max_cycles="$BUILD_TEST_RETRIES"
    local last_test_error=""

    # Convergence tracking
    local prev_error_sig="" consecutive_same_error=0
    local prev_fail_count=0 zero_convergence_streak=0

    # Vitals-driven adaptive limit (preferred over static BUILD_TEST_RETRIES)
    if type pipeline_adaptive_limit >/dev/null 2>&1; then
        local _vitals_json=""
        if type pipeline_compute_vitals >/dev/null 2>&1; then
            _vitals_json=$(pipeline_compute_vitals "$STATE_FILE" "$ARTIFACTS_DIR" "${ISSUE_NUMBER:-}" 2>/dev/null) || true
        fi
        local vitals_limit
        vitals_limit=$(pipeline_adaptive_limit "build_test" "$_vitals_json" 2>/dev/null) || true
        if [[ -n "$vitals_limit" && "$vitals_limit" =~ ^[0-9]+$ && "$vitals_limit" -gt 0 ]]; then
            info "Vitals-driven build-test limit: ${max_cycles} → ${vitals_limit}"
            max_cycles="$vitals_limit"
            emit_event "vitals.adaptive_limit" \
                "issue=${ISSUE_NUMBER:-0}" \
                "context=build_test" \
                "original=$BUILD_TEST_RETRIES" \
                "vitals_limit=$vitals_limit"
        fi
    # Fallback: intelligence-based adaptive limits
    elif type composer_estimate_iterations >/dev/null 2>&1; then
        local estimated
        estimated=$(composer_estimate_iterations \
            "${INTELLIGENCE_ANALYSIS:-{}}" \
            "${HOME}/.shipwright/optimization/iteration-model.json" 2>/dev/null || echo "")
        if [[ -n "$estimated" && "$estimated" =~ ^[0-9]+$ && "$estimated" -gt 0 ]]; then
            max_cycles="$estimated"
            emit_event "intelligence.adaptive_iterations" \
                "issue=${ISSUE_NUMBER:-0}" \
                "estimated=$estimated" \
                "original=$BUILD_TEST_RETRIES"
        fi
    fi

    # Fallback: adaptive cycle limits from optimization data
    if [[ "$max_cycles" == "$BUILD_TEST_RETRIES" ]]; then
        local _iter_model="${HOME}/.shipwright/optimization/iteration-model.json"
        if [[ -f "$_iter_model" ]]; then
            local adaptive_bt_limit
            adaptive_bt_limit=$(pipeline_adaptive_cycles "$max_cycles" "build_test" "0" "-1" 2>/dev/null) || true
            if [[ -n "$adaptive_bt_limit" && "$adaptive_bt_limit" =~ ^[0-9]+$ && "$adaptive_bt_limit" -gt 0 && "$adaptive_bt_limit" != "$max_cycles" ]]; then
                info "Adaptive build-test cycles: ${max_cycles} → ${adaptive_bt_limit}"
                max_cycles="$adaptive_bt_limit"
            fi
        fi
    fi

    while [[ "$cycle" -le "$max_cycles" ]]; do
        cycle=$((cycle + 1))

        if [[ "$cycle" -gt 1 ]]; then
            SELF_HEAL_COUNT=$((SELF_HEAL_COUNT + 1))
            echo ""
            echo -e "${YELLOW}${BOLD}━━━ Self-Healing Cycle ${cycle}/$((max_cycles + 1)) ━━━${RESET}"
            info "Feeding test failure back to build loop..."

            if [[ -n "$ISSUE_NUMBER" ]]; then
                gh_comment_issue "$ISSUE_NUMBER" "🔄 **Self-healing cycle ${cycle}** — rebuilding with error context" 2>/dev/null || true
            fi

            # Reset build/test stage statuses for retry
            set_stage_status "build" "retrying"
            set_stage_status "test" "pending"
        fi

        # ── Run Build Stage ──
        echo ""
        echo -e "${CYAN}${BOLD}▸ Stage: build${RESET} ${DIM}[cycle ${cycle}]${RESET}"
        CURRENT_STAGE_ID="build"

        # Inject error context on retry cycles
        if [[ "$cycle" -gt 1 && -n "$last_test_error" ]]; then
            # Query memory for known fixes
            local _memory_fix=""
            if type memory_closed_loop_inject >/dev/null 2>&1; then
                local _error_sig_short
                _error_sig_short=$(echo "$last_test_error" | head -3 || echo "")
                _memory_fix=$(memory_closed_loop_inject "$_error_sig_short" 2>/dev/null) || true
            fi

            local memory_prefix=""
            if [[ -n "$_memory_fix" ]]; then
                info "Memory suggests fix: $(echo "$_memory_fix" | head -1)"
                memory_prefix="KNOWN FIX (from past success): ${_memory_fix}

"
            fi

            # Temporarily augment the goal with error context
            local original_goal="$GOAL"
            trap '{ GOAL="$original_goal"; trap - RETURN; }' RETURN
            GOAL="$GOAL

${memory_prefix}IMPORTANT — Previous build attempt failed tests. Fix these errors:
$last_test_error

Focus on fixing the failing tests while keeping all passing tests working."

            update_status "running" "build"
            record_stage_start "build"
            type audit_emit >/dev/null 2>&1 && audit_emit "stage.start" "stage=build" || true

            local build_start_epoch
            build_start_epoch=$(date +%s)
            if run_stage_with_retry "build"; then
                mark_stage_complete "build"
                local timing
                timing=$(get_stage_timing "build")
                local build_dur_s=$(( $(date +%s) - build_start_epoch ))
                type audit_emit >/dev/null 2>&1 && audit_emit "stage.complete" "stage=build" "verdict=pass" "duration_s=${build_dur_s}" || true
                success "Stage ${BOLD}build${RESET} complete ${DIM}(${timing})${RESET}"
                if type pipeline_emit_progress_snapshot >/dev/null 2>&1 && [[ -n "${ISSUE_NUMBER:-}" ]]; then
                    local _diff_count
                    _diff_count=$(git diff --stat HEAD~1 2>/dev/null | tail -1 | grep -oE '[0-9]+' | head -1) || true
                    local _snap_files _snap_error
                    _snap_files=$(git diff --stat HEAD~1 2>/dev/null | tail -1 | grep -oE '[0-9]+' | head -1 || true)
                    _snap_files="${_snap_files:-0}"
                    _snap_error=$(tail -1 "$ARTIFACTS_DIR/error-log.jsonl" 2>/dev/null | jq -r '.error // ""' 2>/dev/null || true)
                    _snap_error="${_snap_error:-}"
                    pipeline_emit_progress_snapshot "${ISSUE_NUMBER}" "${CURRENT_STAGE_ID:-build}" "${cycle:-0}" "${_diff_count:-0}" "${_snap_files}" "${_snap_error}" 2>/dev/null || true
                fi
            else
                mark_stage_failed "build"
                local build_dur_s=$(( $(date +%s) - build_start_epoch ))
                type audit_emit >/dev/null 2>&1 && audit_emit "stage.complete" "stage=build" "verdict=fail" "duration_s=${build_dur_s}" || true
                GOAL="$original_goal"
                return 1
            fi
            GOAL="$original_goal"
        else
            update_status "running" "build"
            record_stage_start "build"
            type audit_emit >/dev/null 2>&1 && audit_emit "stage.start" "stage=build" || true

            local build_start_epoch
            build_start_epoch=$(date +%s)
            if run_stage_with_retry "build"; then
                mark_stage_complete "build"
                local timing
                timing=$(get_stage_timing "build")
                local build_dur_s=$(( $(date +%s) - build_start_epoch ))
                type audit_emit >/dev/null 2>&1 && audit_emit "stage.complete" "stage=build" "verdict=pass" "duration_s=${build_dur_s}" || true
                success "Stage ${BOLD}build${RESET} complete ${DIM}(${timing})${RESET}"
                if type pipeline_emit_progress_snapshot >/dev/null 2>&1 && [[ -n "${ISSUE_NUMBER:-}" ]]; then
                    local _diff_count
                    _diff_count=$(git diff --stat HEAD~1 2>/dev/null | tail -1 | grep -oE '[0-9]+' | head -1) || true
                    local _snap_files _snap_error
                    _snap_files=$(git diff --stat HEAD~1 2>/dev/null | tail -1 | grep -oE '[0-9]+' | head -1 || true)
                    _snap_files="${_snap_files:-0}"
                    _snap_error=$(tail -1 "$ARTIFACTS_DIR/error-log.jsonl" 2>/dev/null | jq -r '.error // ""' 2>/dev/null || true)
                    _snap_error="${_snap_error:-}"
                    pipeline_emit_progress_snapshot "${ISSUE_NUMBER}" "${CURRENT_STAGE_ID:-build}" "${cycle:-0}" "${_diff_count:-0}" "${_snap_files}" "${_snap_error}" 2>/dev/null || true
                fi
            else
                mark_stage_failed "build"
                local build_dur_s=$(( $(date +%s) - build_start_epoch ))
                type audit_emit >/dev/null 2>&1 && audit_emit "stage.complete" "stage=build" "verdict=fail" "duration_s=${build_dur_s}" || true
                return 1
            fi
        fi

        # ── Run Test Stage ──
        echo ""
        echo -e "${CYAN}${BOLD}▸ Stage: test${RESET} ${DIM}[cycle ${cycle}]${RESET}"
        CURRENT_STAGE_ID="test"
        update_status "running" "test"
        record_stage_start "test"

        if run_stage_with_retry "test"; then
            mark_stage_complete "test"
            local timing
            timing=$(get_stage_timing "test")
            success "Stage ${BOLD}test${RESET} complete ${DIM}(${timing})${RESET}"
            emit_event "convergence.tests_passed" \
                "issue=${ISSUE_NUMBER:-0}" \
                "cycle=$cycle"
            if type pipeline_emit_progress_snapshot >/dev/null 2>&1 && [[ -n "${ISSUE_NUMBER:-}" ]]; then
                local _diff_count
                _diff_count=$(git diff --stat HEAD~1 2>/dev/null | tail -1 | grep -oE '[0-9]+' | head -1) || true
                local _snap_files _snap_error
                _snap_files=$(git diff --stat HEAD~1 2>/dev/null | tail -1 | grep -oE '[0-9]+' | head -1 || true)
                _snap_files="${_snap_files:-0}"
                _snap_error=$(tail -1 "$ARTIFACTS_DIR/error-log.jsonl" 2>/dev/null | jq -r '.error // ""' 2>/dev/null || true)
                _snap_error="${_snap_error:-}"
                pipeline_emit_progress_snapshot "${ISSUE_NUMBER}" "${CURRENT_STAGE_ID:-test}" "${cycle:-0}" "${_diff_count:-0}" "${_snap_files}" "${_snap_error}" 2>/dev/null || true
            fi
            # Record fix outcome when tests pass after a retry with memory injection (pipeline path)
            if [[ "$cycle" -gt 1 && -n "${last_test_error:-}" ]] && [[ -x "$SCRIPT_DIR/sw-memory.sh" ]]; then
                local _sig
                _sig=$(echo "$last_test_error" | head -3 | tr '\n' ' ' | sed 's/^ *//;s/ *$//')
                [[ -n "$_sig" ]] && bash "$SCRIPT_DIR/sw-memory.sh" fix-outcome "$_sig" "true" "true" 2>/dev/null || true
            fi
            return 0  # Tests passed!
        fi

        # Tests failed — capture error for next cycle
        local test_log="$ARTIFACTS_DIR/test-results.log"

        # Detect infrastructure errors that self-healing cannot fix (no point cycling)
        if grep -q "Unable to find a device matching" "$test_log" 2>/dev/null; then
            error "Infrastructure error: simulator not found — self-healing cannot fix this"
            error "Check 'xcrun simctl list devices available' and fix the test destination"
            if [[ -n "${ISSUE_NUMBER:-}" ]]; then
                gh_comment_issue "$ISSUE_NUMBER" "❌ **Infrastructure error**: simulator destination not found. This is a test configuration issue, not a code problem. Fix the simulator setup and re-run." >/dev/null 2>&1 || true
            fi
            mark_stage_failed "test"
            return 1
        fi

        # Extract meaningful errors — skip simulator destination lists and boilerplate
        last_test_error=$(grep -vE '^\s*\{ platform:|Available destinations|The requested device|no available devices' "$test_log" 2>/dev/null \
            | grep -E 'error:|FAIL|fail:|assert|panic|xcodebuild: error|Build FAILED|Undefined symbol|cannot find|fatal' 2>/dev/null \
            | tail -20 || true)
        if [[ -z "$last_test_error" ]]; then
            # Fallback: get last lines but still filter out sim list
            last_test_error=$(grep -vE '^\s*\{ platform:|Available destinations|The requested device|no available devices' "$test_log" 2>/dev/null | tail -15 || echo "Test command failed with no output")
        fi
        mark_stage_failed "test"

        # ── Cycling Halt: cumulative cap across pipeline invocations ──
        # External automation (daemon, autonomous pipeline) may re-enter build
        # after self-healing exhausts. Persistent log of test failures detects
        # this and halts with a distinct `stuck_cycling` state.
        #
        # IMPORTANT: This check runs AFTER the current cycle's test failure has
        # been logged via mark_stage_failed (which calls log_stage + write_state).
        # Reading the count BEFORE running the cycle would falsely halt fresh
        # resumes whose first attempt hasn't run yet (#448 review feedback).
        local _max_build_retries="${SW_PIPELINE_MAX_BUILD_RETRIES:-3}"
        # Bounds validation: negative or non-integer values silently disable the cycling
        # halt (the -gt 0 check below would be false), re-introducing the #448 bug.
        case "$_max_build_retries" in
            ''|*[!0-9]*)
                warn "SW_PIPELINE_MAX_BUILD_RETRIES='${_max_build_retries}' is not a non-negative integer; using default of 3"
                _max_build_retries=3
                ;;
        esac
        if [[ "$_max_build_retries" -gt 0 ]]; then
            local _consec_failures
            _consec_failures=$(count_consecutive_test_failures)
            if [[ "$_consec_failures" -ge "$_max_build_retries" ]]; then
                PIPELINE_STUCK_CYCLING=true
                if declare -f log_stage >/dev/null 2>&1; then
                    log_stage "pipeline" "stuck_cycling: ${_consec_failures} consecutive test failures (cap=${_max_build_retries}). Override: SW_PIPELINE_MAX_BUILD_RETRIES=0"
                fi
                update_status "stuck_cycling" "build"
                error "Pipeline halted: ${_consec_failures} consecutive test failures reached cap of ${_max_build_retries}"
                if [[ "$_max_build_retries" -eq 0 ]]; then
                    warn "Cycling halt is disabled (SW_PIPELINE_MAX_BUILD_RETRIES=0)"
                else
                    warn "Override: SW_PIPELINE_MAX_BUILD_RETRIES=0 shipwright pipeline resume"
                fi
                emit_event "pipeline.stuck_cycling" \
                    "issue=${ISSUE_NUMBER:-0}" \
                    "consecutive_failures=${_consec_failures}" \
                    "cap=${_max_build_retries}" || true
                return 1
            fi
        fi

        # ── Convergence Detection ──
        # Hash the error output to detect repeated failures
        local error_sig
        error_sig=$(echo "$last_test_error" | shasum -a 256 2>/dev/null | cut -c1-16 || echo "unknown")

        # Count failing tests (extract from common patterns)
        local current_fail_count=0
        current_fail_count=$(grep -ciE 'fail|error|FAIL' "$test_log" 2>/dev/null || true)
        current_fail_count="${current_fail_count:-0}"

        if [[ "$error_sig" == "$prev_error_sig" ]]; then
            consecutive_same_error=$((consecutive_same_error + 1))
        else
            consecutive_same_error=1
        fi
        prev_error_sig="$error_sig"

        # Check: same error 3 times consecutively → stuck
        if [[ "$consecutive_same_error" -ge 3 ]]; then
            error "Convergence: stuck on same error for 3 consecutive cycles — exiting early"
            emit_event "convergence.stuck" \
                "issue=${ISSUE_NUMBER:-0}" \
                "cycle=$cycle" \
                "error_sig=$error_sig" \
                "consecutive=$consecutive_same_error"
            notify "Build Convergence" "Stuck on unfixable error after ${cycle} cycles" "error"
            return 1
        fi

        # Track convergence rate: did we reduce failures?
        if [[ "$cycle" -gt 1 && "$prev_fail_count" -gt 0 ]]; then
            if [[ "$current_fail_count" -ge "$prev_fail_count" ]]; then
                zero_convergence_streak=$((zero_convergence_streak + 1))
            else
                zero_convergence_streak=0
            fi

            # Check: zero convergence for 2 consecutive iterations → plateau
            if [[ "$zero_convergence_streak" -ge 2 ]]; then
                error "Convergence: no progress for 2 consecutive cycles (${current_fail_count} failures remain) — exiting early"
                emit_event "convergence.plateau" \
                    "issue=${ISSUE_NUMBER:-0}" \
                    "cycle=$cycle" \
                    "fail_count=$current_fail_count" \
                    "streak=$zero_convergence_streak"
                notify "Build Convergence" "No progress after ${cycle} cycles — plateau reached" "error"
                return 1
            fi
        fi
        prev_fail_count="$current_fail_count"

        info "Convergence: error_sig=${error_sig:0:8} repeat=${consecutive_same_error} failures=${current_fail_count} no_progress=${zero_convergence_streak}"

        if [[ "$cycle" -le "$max_cycles" ]]; then
            warn "Tests failed — will attempt self-healing (cycle $((cycle + 1))/$((max_cycles + 1)))"
            notify "Self-Healing" "Tests failed on cycle ${cycle}, retrying..." "warn"
        fi
    done

    error "Self-healing exhausted after $((max_cycles + 1)) cycles"
    notify "Self-Healing Failed" "Tests still failing after $((max_cycles + 1)) build-test cycles" "error"
    return 1
}

# ─── Merge Self-Healing ───────────────────────────────────────────────────
# When the merge stage is blocked by CI failure or reviewer CHANGES_REQUESTED,
# inject the retry context back into the build loop and re-run
# build→test→pr→merge until resolved or max cycles exhausted.

self_healing_merge_build_test() {
    local cycle=0
    local max_cycles=3
    local retry_ctx="${ARTIFACTS_DIR}/.retry-context-build.md"

    while [[ "$cycle" -lt "$max_cycles" ]]; do
        cycle=$((cycle + 1))
        SELF_HEAL_COUNT=$((SELF_HEAL_COUNT + 1))
        echo ""
        echo -e "${YELLOW}${BOLD}━━━ Merge Self-Healing Cycle ${cycle}/${max_cycles} ━━━${RESET}"

        if [[ -n "${ISSUE_NUMBER:-}" ]]; then
            gh_comment_issue "$ISSUE_NUMBER" \
                "🔄 **Merge self-healing cycle ${cycle}** — rebuilding to address CI/review feedback" 2>/dev/null || true
        fi

        # Load retry context (CI failure log or review change-request pointer)
        local heal_context=""
        if [[ -f "$retry_ctx" ]]; then
            heal_context=$(cat "$retry_ctx")
        fi
        [[ -z "${heal_context// }" ]] && heal_context="CI or code review blocked the merge. Read the PR and fix any issues."

        # Inject context into GOAL for the build loop
        local original_goal="$GOAL"
        trap '{ GOAL="$original_goal"; trap - RETURN; }' RETURN
        GOAL="$GOAL

IMPORTANT — CI or code review requires fixes before this PR can merge:
${heal_context}

Fix all issues. Do not break existing tests."

        rm -f "$retry_ctx"  # consumed; stage_merge will write a fresh one if needed

        # Re-run build → test loop
        if ! self_healing_build_test; then
            GOAL="$original_goal"
            error "Build loop failed during merge self-healing cycle ${cycle}"
            return 1
        fi
        GOAL="$original_goal"

        # Re-run pr and merge stages to push fixes and attempt merge again
        echo ""
        echo -e "${CYAN}${BOLD}▸ Re-running pr stage (merge self-healing cycle ${cycle})${RESET}"
        CURRENT_STAGE_ID="pr"
        update_status "running" "pr"
        record_stage_start "pr"
        if ! run_stage_with_retry "pr"; then
            error "PR stage failed during merge self-healing cycle ${cycle}"
            return 1
        fi
        mark_stage_complete "pr"

        echo ""
        echo -e "${CYAN}${BOLD}▸ Re-running merge stage (merge self-healing cycle ${cycle})${RESET}"
        CURRENT_STAGE_ID="merge"
        update_status "running" "merge"
        record_stage_start "merge"
        if run_stage_with_retry "merge"; then
            mark_stage_complete "merge"
            success "Stage ${BOLD}merge${RESET} complete after self-healing ${DIM}(cycle ${cycle})${RESET}"
            emit_event "merge.self_healed" "issue=${ISSUE_NUMBER:-0}" "cycle=$cycle"
            return 0
        fi

        warn "Merge still blocked after cycle ${cycle}"
        emit_event "merge.still_blocked" "issue=${ISSUE_NUMBER:-0}" "cycle=$cycle"
    done

    error "Merge self-healing exhausted after ${max_cycles} cycle(s)"
    # Label PR for human review
    local _pr_num=""
    _pr_num=$(cat "$ARTIFACTS_DIR/pr-url.txt" 2>/dev/null | grep -oE '[0-9]+$' || true)
    [[ -n "$_pr_num" ]] && gh pr edit "$_pr_num" --add-label "pipeline/needs-human" 2>/dev/null || true
    return 1
}

# ─── Review Self-Healing ──────────────────────────────────────────────────
# When the review stage blocks on critical/security issues, inject the review
# findings back into the build loop goal and re-run build→test→review until
# all issues are resolved or retry cycles are exhausted.

self_healing_review_build_test() {
    local cycle=0
    local max_cycles="$REVIEW_BUILD_RETRIES"
    local blockers_file="$ARTIFACTS_DIR/review-blockers.md"

    while [[ "$cycle" -lt "$max_cycles" ]]; do
        cycle=$((cycle + 1))
        SELF_HEAL_COUNT=$((SELF_HEAL_COUNT + 1))
        echo ""
        echo -e "${YELLOW}${BOLD}━━━ Review Self-Healing Cycle ${cycle}/${max_cycles} ━━━${RESET}"
        info "Injecting review findings into build loop..."

        if [[ -n "${ISSUE_NUMBER:-}" ]]; then
            gh_comment_issue "$ISSUE_NUMBER" \
                "🔄 **Review self-healing cycle ${cycle}** — rebuilding to address review blockers" 2>/dev/null || true
        fi

        # Load review blockers
        local review_context=""
        if [[ -f "$blockers_file" ]]; then
            review_context=$(cat "$blockers_file")
        fi
        if [[ -z "${review_context// }" ]]; then
            review_context="Code review found critical/security issues that must be fixed."
        fi

        # Inject review blockers into goal for the build loop
        local original_goal="$GOAL"
        trap '{ GOAL="$original_goal"; trap - RETURN; }' RETURN
        GOAL="$GOAL

IMPORTANT — Code review found critical/security issues that MUST be fixed:
${review_context}

Fix the listed blockers that were introduced by this PR. Do not modify pre-existing code outside the scope of issue #${ISSUE_NUMBER:-0}."

        # Re-run build→test loop with the review context in goal
        if ! self_healing_build_test; then
            GOAL="$original_goal"
            error "Build loop failed during review self-healing cycle ${cycle}"
            return 1
        fi
        GOAL="$original_goal"

        # Build+test passed — re-run review to check if blockers are resolved
        echo ""
        echo -e "${CYAN}${BOLD}▸ Re-running review (self-healing cycle ${cycle})${RESET}"
        CURRENT_STAGE_ID="review"
        update_status "running" "review"
        record_stage_start "review"
        set_stage_status "review" "pending"

        if run_stage_with_retry "review"; then
            mark_stage_complete "review"
            local timing
            timing=$(get_stage_timing "review")
            success "Stage ${BOLD}review${RESET} complete after self-healing ${DIM}(${timing})${RESET}"
            emit_event "review.self_healed" "issue=${ISSUE_NUMBER:-0}" "cycle=$cycle"
            # File pre-existing findings as follow-up GitHub issues
            if [[ -s "${ARTIFACTS_DIR:-}/review-followups.md" ]] && [[ -n "${ISSUE_NUMBER:-}" ]] && [[ "${NO_GITHUB:-false}" != "true" ]]; then
                local _followup_label="follow-up,pre-existing,from-${ISSUE_NUMBER}"
                gh label create "follow-up" --color "#e4e669" --description "Follow-up issue" 2>/dev/null || true
                gh label create "pre-existing" --color "#f9d0c4" --description "Pre-existing issue found during review" 2>/dev/null || true
                gh label create "from-${ISSUE_NUMBER}" --color "#bfdadc" --description "Found during review of #${ISSUE_NUMBER}" 2>/dev/null || true
                local _finding_title _finding_count=0
                while IFS= read -r _line; do
                    _finding_title=$(echo "$_line" | sed 's/.*\[Pre-existing\][[:space:]]*//' | cut -c1-100)
                    if [[ -n "$_finding_title" ]]; then
                        local _existing
                        _existing=$(gh issue list --label "from-${ISSUE_NUMBER}" --search "$_finding_title" --json number --jq 'length' 2>/dev/null || echo "0")
                        if [[ "${_existing:-0}" -eq 0 ]]; then
                            local _followup_body
                            _followup_body="Pre-existing finding identified during review of #${ISSUE_NUMBER}.

$(grep -F -A5 "$_finding_title" "${ARTIFACTS_DIR}/review-followups.md" 2>/dev/null | head -10 || true)"
                            gh issue create \
                                --title "[follow-up from #${ISSUE_NUMBER}] ${_finding_title}" \
                                --body "$_followup_body" \
                                --label "$_followup_label" 2>/dev/null || true
                            _finding_count=$(( _finding_count + 1 ))
                        fi
                    fi
                done < <(grep -E '\[Pre-existing\]' "${ARTIFACTS_DIR}/review-followups.md" 2>/dev/null || true)
                if [[ "$_finding_count" -gt 0 ]]; then
                    info "Filed ${_finding_count} pre-existing finding(s) as follow-up GitHub issues"
                fi
            fi
            return 0
        fi

        # Review still blocked — refresh blockers for next cycle
        grep -iE '\*\*\[?(Critical|Security)\]?\*\*' "$ARTIFACTS_DIR/review.md" \
            > "$blockers_file" 2>/dev/null || true
        warn "Review still blocked after cycle ${cycle}"
        emit_event "review.still_blocked" "issue=${ISSUE_NUMBER:-0}" "cycle=$cycle"
    done

    error "Review self-healing exhausted after ${max_cycles} cycle(s)"
    return 1
}

# ─── Auto-Rebase ──────────────────────────────────────────────────────────

auto_rebase() {
    info "Syncing with ${BASE_BRANCH}..."

    # Fetch latest — GIT_TERMINAL_PROMPT=0 prevents blocking on HTTPS credential prompts
    GIT_TERMINAL_PROMPT=0 git fetch origin "$BASE_BRANCH" --quiet 2>/dev/null || {
        warn "Could not fetch origin/${BASE_BRANCH}"
        return 0
    }

    # Check if rebase is needed
    local behind
    behind=$(git rev-list --count "HEAD..origin/${BASE_BRANCH}" 2>/dev/null || echo "0")

    if [[ "$behind" -eq 0 ]]; then
        success "Already up to date with ${BASE_BRANCH}"
        return 0
    fi

    info "Rebasing onto origin/${BASE_BRANCH} ($behind commits behind)..."
    if git rebase "origin/${BASE_BRANCH}" --quiet 2>/dev/null; then
        success "Rebase successful"
    else
        warn "Rebase conflict detected — aborting rebase"
        git rebase --abort 2>/dev/null || true
        warn "Falling back to merge..."
        if git merge "origin/${BASE_BRANCH}" --no-edit --quiet 2>/dev/null; then
            success "Merge successful"
        else
            git merge --abort 2>/dev/null || true
            error "Both rebase and merge failed — manual intervention needed"
            return 1
        fi
    fi
}

run_pipeline() {
    _PIPELINE_RUN_STARTED=true
    if declare -f _validate_ref >/dev/null 2>&1; then
        _validate_ref "${BASE_BRANCH:-}" "BASE_BRANCH" || return 1
    fi
    [[ "${SHIPWRIGHT_DEBUG:-0}" == "1" ]] && echo "[ISSUE-TRACE] run_pipeline: ISSUE_NUMBER=${ISSUE_NUMBER:-<unset>}" >&2 || true
    _start_state_heartbeat

    # Rotate event log if needed (standalone mode)
    rotate_event_log_if_needed

    # Initialize audit trail for this pipeline run
    if type audit_init >/dev/null 2>&1; then
        audit_init || true
    fi

    # Initialize ruflo adapter (no-op if unavailable)
    if type ruflo_init >/dev/null 2>&1; then
        ruflo_init || true
    fi

    local stages
    stages=$(jq -c '.stages[]' "$PIPELINE_CONFIG")

    local stage_count enabled_count
    stage_count=$(jq '.stages | length' "$PIPELINE_CONFIG")
    enabled_count=$(jq '[.stages[] | select(.enabled == true)] | length' "$PIPELINE_CONFIG")
    local completed=0

    # Check which stages are enabled to determine if we use the self-healing loop
    local build_enabled test_enabled
    build_enabled=$(jq -r '.stages[] | select(.id == "build") | .enabled' "$PIPELINE_CONFIG" 2>/dev/null)
    test_enabled=$(jq -r '.stages[] | select(.id == "test") | .enabled' "$PIPELINE_CONFIG" 2>/dev/null)
    local use_self_healing=false
    if [[ "$build_enabled" == "true" && "$test_enabled" == "true" && "$BUILD_TEST_RETRIES" -gt 0 ]]; then
        use_self_healing=true
    fi

    while IFS= read -r -u 3 stage; do
        local id enabled gate
        id=$(echo "$stage" | jq -r '.id')
        enabled=$(echo "$stage" | jq -r '.enabled')
        gate=$(echo "$stage" | jq -r '.gate')

        CURRENT_STAGE_ID="$id"

        # Human intervention: check for skip-stage directive
        if [[ -f "$ARTIFACTS_DIR/skip-stage.txt" ]]; then
            local skip_list
            skip_list="$(cat "$ARTIFACTS_DIR/skip-stage.txt" 2>/dev/null || true)"
            if echo "$skip_list" | grep -qx "$id" 2>/dev/null; then
                info "Stage ${BOLD}${id}${RESET} skipped by human directive"
                emit_event "stage.skipped" "issue=${ISSUE_NUMBER:-0}" "stage=$id" "reason=human_skip"
                # Remove this stage from the skip file
                local tmp_skip
                tmp_skip="$(mktemp)"
                # shellcheck disable=SC2064  # intentional expansion at definition time
                trap "rm -f '$tmp_skip'" RETURN
                grep -vx "$id" "$ARTIFACTS_DIR/skip-stage.txt" > "$tmp_skip" 2>/dev/null || true
                mv "$tmp_skip" "$ARTIFACTS_DIR/skip-stage.txt"
                continue
            fi
        fi

        # Human intervention: check for human message
        if [[ -f "$ARTIFACTS_DIR/human-message.txt" ]]; then
            local human_msg
            human_msg="$(cat "$ARTIFACTS_DIR/human-message.txt" 2>/dev/null || true)"
            if [[ -n "$human_msg" ]]; then
                echo ""
                echo -e "  ${PURPLE}${BOLD}💬 Human message:${RESET} $human_msg"
                emit_event "pipeline.human_message" "issue=${ISSUE_NUMBER:-0}" "stage=$id" "message=$human_msg"
                rm -f "$ARTIFACTS_DIR/human-message.txt"
            fi
        fi

        if [[ "$enabled" != "true" ]]; then
            echo -e "  ${DIM}○ ${id} — skipped (disabled)${RESET}"
            continue
        fi

        # Intelligence: evaluate whether to skip this stage
        local skip_reason=""
        skip_reason=$(pipeline_should_skip_stage "$id" 2>/dev/null) || true
        if [[ -n "$skip_reason" ]]; then
            echo -e "  ${DIM}○ ${id} — skipped (intelligence: ${skip_reason})${RESET}"
            set_stage_status "$id" "complete"
            completed=$((completed + 1))
            continue
        fi

        local stage_status
        stage_status=$(get_stage_status "$id")
        if [[ "$stage_status" == "complete" ]]; then
            echo -e "  ${GREEN}✓ ${id}${RESET} ${DIM}— already complete${RESET}"
            completed=$((completed + 1))
            continue
        fi

        # CI resume: skip stages marked as completed from previous run
        if [[ -n "${COMPLETED_STAGES:-}" ]] && echo "$COMPLETED_STAGES" | tr ',' '\n' | grep -qx "$id"; then
            # Verify artifacts survived the merge — regenerate if missing
            if verify_stage_artifacts "$id"; then
                echo -e "  ${GREEN}✓ ${id}${RESET} ${DIM}— skipped (CI resume)${RESET}"
                set_stage_status "$id" "complete"
                completed=$((completed + 1))
                emit_event "stage.skipped" "issue=${ISSUE_NUMBER:-0}" "stage=$id" "reason=ci_resume"
                continue
            else
                warn "Stage $id marked complete but artifacts missing — regenerating"
                emit_event "stage.artifact_miss" "issue=${ISSUE_NUMBER:-0}" "stage=$id"
            fi
        fi

        # Self-healing build→test loop: when we hit build, run both together
        if [[ "$id" == "build" && "$use_self_healing" == "true" ]]; then
            # TDD: generate tests before build when enabled
            if [[ "${TDD_ENABLED:-false}" == "true" || "${PIPELINE_TDD:-}" == "true" ]]; then
                stage_test_first || true
            fi
            # Gate check for build
            local build_gate
            build_gate=$(echo "$stage" | jq -r '.gate')
            if [[ "$build_gate" == "approve" && "$SKIP_GATES" != "true" ]]; then
                show_stage_preview "build"
                local answer=""
                if [[ -t 0 ]]; then
                    read -rp "  Proceed with build+test (self-healing)? [Y/n] " answer || true
                fi
                if [[ "$answer" =~ ^[Nn] ]]; then
                    update_status "paused" "build"
                    info "Pipeline paused. Resume with: ${DIM}shipwright pipeline resume${RESET}"
                    return 0
                fi
            fi

            if self_healing_build_test; then
                completed=$((completed + 2))  # Both build and test

                # Intelligence: reassess complexity after build+test
                local reassessment
                reassessment=$(pipeline_reassess_complexity 2>/dev/null) || true
                if [[ -n "$reassessment" && "$reassessment" != "as_expected" ]]; then
                    info "Complexity reassessment: ${reassessment}"
                fi
            else
                if [[ "${PIPELINE_STUCK_CYCLING:-false}" == "true" ]]; then
                    # Cycling halt already wrote `status: stuck_cycling` — preserve it.
                    return 1
                fi
                update_status "failed" "test"
                error "Pipeline failed: build→test self-healing exhausted"
                return 1
            fi
            continue
        fi

        # TDD: generate tests before build when enabled (non-self-healing path)
        if [[ "$id" == "build" && "$use_self_healing" != "true" ]] && [[ "${TDD_ENABLED:-false}" == "true" || "${PIPELINE_TDD:-}" == "true" ]]; then
            stage_test_first || true
        fi

        # Skip test if already handled by self-healing loop
        if [[ "$id" == "test" && "$use_self_healing" == "true" ]]; then
            stage_status=$(get_stage_status "test")
            if [[ "$stage_status" == "complete" ]]; then
                echo -e "  ${GREEN}✓ test${RESET} ${DIM}— completed in build→test loop${RESET}"
            fi
            continue
        fi

        # Gate check
        if [[ "$gate" == "approve" && "$SKIP_GATES" != "true" ]]; then
            show_stage_preview "$id"
            local answer=""
            if [[ -t 0 ]]; then
                read -rp "  Proceed with ${id}? [Y/n] " answer || true
            else
                # Non-interactive: auto-approve (shouldn't reach here if headless detection works)
                info "Non-interactive mode — auto-approving ${id}"
            fi
            if [[ "$answer" =~ ^[Nn] ]]; then
                update_status "paused" "$id"
                info "Pipeline paused at ${BOLD}$id${RESET}. Resume with: ${DIM}shipwright pipeline resume${RESET}"
                return 0
            fi
        fi

        # Budget enforcement check (skip with --ignore-budget)
        if [[ "$IGNORE_BUDGET" != "true" ]] && [[ -x "$SCRIPT_DIR/sw-cost.sh" ]]; then
            local budget_rc=0
            bash "$SCRIPT_DIR/sw-cost.sh" check-budget 2>/dev/null || budget_rc=$?
            if [[ "$budget_rc" -eq 2 ]]; then
                warn "Daily budget exceeded — pausing pipeline before stage ${BOLD}$id${RESET}"
                warn "Resume with --ignore-budget to override, or wait until tomorrow"
                emit_event "pipeline.budget_paused" "issue=${ISSUE_NUMBER:-0}" "stage=$id"
                update_status "paused" "$id"
                return 0
            fi
        fi

        # Intelligence: per-stage model routing (UCB1 when DB has data, else A/B testing)
        local recommended_model="" from_ucb1=false
        if type ucb1_select_model >/dev/null 2>&1; then
            recommended_model=$(ucb1_select_model "$id" 2>/dev/null || echo "")
            [[ -n "$recommended_model" ]] && from_ucb1=true
        fi
        if [[ -z "$recommended_model" ]] && type intelligence_recommend_model >/dev/null 2>&1; then
            local stage_complexity="${INTELLIGENCE_COMPLEXITY:-5}"
            local budget_remaining=""
            if [[ -x "$SCRIPT_DIR/sw-cost.sh" ]]; then
                budget_remaining=$(bash "$SCRIPT_DIR/sw-cost.sh" remaining-budget 2>/dev/null || echo "")
            fi
            local recommended_json
            recommended_json=$(intelligence_recommend_model "$id" "$stage_complexity" "$budget_remaining" 2>/dev/null || echo "")
            recommended_model=$(echo "$recommended_json" | jq -r '.model // empty' 2>/dev/null || echo "")
        fi
        if [[ -n "$recommended_model" && "$recommended_model" != "null" ]]; then
            if [[ "$from_ucb1" == "true" ]]; then
                # UCB1 already balances exploration/exploitation — use directly
                export CLAUDE_MODEL="$recommended_model"
                emit_event "intelligence.model_ucb1" \
                    "issue=${ISSUE_NUMBER:-0}" \
                    "stage=$id" \
                    "model=$recommended_model"
            else
                # A/B testing for intelligence recommendation
                local ab_ratio=20
                local daemon_cfg="${PROJECT_ROOT}/.claude/daemon-config.json"
                if [[ -f "$daemon_cfg" ]]; then
                    local cfg_ratio
                    cfg_ratio=$(jq -r '.intelligence.ab_test_ratio // 0.2' "$daemon_cfg" 2>/dev/null || echo "0.2")
                    ab_ratio=$(awk -v r="$cfg_ratio" 'BEGIN{printf "%d", r * 100}' 2>/dev/null || echo "20")
                fi

                local routing_file="${HOME}/.shipwright/optimization/model-routing.json"
                local use_recommended=false
                local ab_group="control"

                if [[ -f "$routing_file" ]]; then
                    local stage_samples total_samples
                    stage_samples=$(jq -r --arg s "$id" '.routes[$s].sonnet_samples // .[$s].sonnet_samples // 0' "$routing_file" 2>/dev/null || echo "0")
                    total_samples=$(jq -r --arg s "$id" '((.routes[$s].sonnet_samples // .[$s].sonnet_samples // 0) + (.routes[$s].opus_samples // .[$s].opus_samples // 0))' "$routing_file" 2>/dev/null || echo "0")
                    if [[ "${total_samples:-0}" -ge 50 ]]; then
                        use_recommended=true
                        ab_group="graduated"
                    fi
                fi

                if [[ "$use_recommended" != "true" ]]; then
                    local roll=$((RANDOM % 100))
                    if [[ "$roll" -lt "$ab_ratio" ]]; then
                        use_recommended=true
                        ab_group="experiment"
                    fi
                fi

                if [[ "$use_recommended" == "true" ]]; then
                    export CLAUDE_MODEL="$recommended_model"
                else
                    export CLAUDE_MODEL="opus" # A/B control arm: opus is intentional — do not replace with get_effective_model()
                fi

                emit_event "intelligence.model_ab" \
                    "issue=${ISSUE_NUMBER:-0}" \
                    "stage=$id" \
                    "recommended=$recommended_model" \
                    "applied=$CLAUDE_MODEL" \
                    "ab_group=$ab_group" \
                    "ab_ratio=$ab_ratio"
            fi
        fi

        echo ""
        echo -e "${CYAN}${BOLD}▸ Stage: ${id}${RESET} ${DIM}[$((completed + 1))/${enabled_count}]${RESET}"
        update_status "running" "$id"
        record_stage_start "$id"
        local stage_start_epoch
        stage_start_epoch=$(now_epoch)
        emit_event "stage.started" "issue=${ISSUE_NUMBER:-0}" "stage=$id"

        # Mark GitHub Check Run as in-progress
        if [[ "${NO_GITHUB:-false}" != "true" ]] && type gh_checks_stage_update >/dev/null 2>&1; then
            gh_checks_stage_update "$id" "in_progress" "" "Stage $id started" 2>/dev/null || true
        fi

        # Audit: stage start
        if type audit_emit >/dev/null 2>&1; then
            audit_emit "stage.start" "stage=$id" || true
        fi

        local stage_model_used=""
        if run_stage_with_retry "$id"; then
            # Resolve after stage runs so loop-state.md reflects this stage's model
            stage_model_used="$(get_effective_model)"
            mark_stage_complete "$id"
            completed=$((completed + 1))
            # Capture project pattern after intake (for memory context in later stages)
            if [[ "$id" == "intake" ]] && [[ -x "$SCRIPT_DIR/sw-memory.sh" ]]; then
                (cd "$REPO_DIR" && bash "$SCRIPT_DIR/sw-memory.sh" pattern "project" "{}" 2>/dev/null) || true
            fi
            local timing stage_dur_s
            timing=$(get_stage_timing "$id")
            stage_dur_s=$(( $(now_epoch) - stage_start_epoch ))
            success "Stage ${BOLD}$id${RESET} complete ${DIM}(${timing})${RESET}"
            emit_event "stage.completed" "issue=${ISSUE_NUMBER:-0}" "stage=$id" "duration_s=$stage_dur_s" "result=success"
            # Audit: stage complete
            if type audit_emit >/dev/null 2>&1; then
                audit_emit "stage.complete" "stage=$id" "verdict=pass" \
                    "duration_s=${stage_dur_s:-0}" || true
            fi
            # Emit vitals snapshot on every stage transition (not just build/test)
            if type pipeline_emit_progress_snapshot >/dev/null 2>&1 && [[ -n "${ISSUE_NUMBER:-}" ]]; then
                pipeline_emit_progress_snapshot "${ISSUE_NUMBER}" "$id" "0" "0" "0" "" 2>/dev/null || true
            fi
            # Record model outcome for UCB1 learning
            type record_model_outcome >/dev/null 2>&1 && record_model_outcome "$stage_model_used" "$id" 1 "$stage_dur_s" 0 2>/dev/null || true
            # Broadcast discovery for cross-pipeline learning
            if [[ -x "$SCRIPT_DIR/sw-discovery.sh" ]]; then
                local _disc_cat _disc_patterns _disc_text
                _disc_cat="$id"
                case "$id" in
                    plan)   _disc_patterns="*.md"; _disc_text="Plan completed: ${GOAL:-goal}" ;;
                    design) _disc_patterns="*.md,*.ts,*.tsx,*.js"; _disc_text="Design completed for ${GOAL:-goal}" ;;
                    build)  _disc_patterns="src/*,*.ts,*.tsx,*.js"; _disc_text="Build completed" ;;
                    test)   _disc_patterns="*.test.*,*_test.*"; _disc_text="Tests passed" ;;
                    review) _disc_patterns="*.md,*.ts,*.tsx"; _disc_text="Review completed" ;;
                    *)      _disc_patterns="*"; _disc_text="Stage $id completed" ;;
                esac
                bash "$SCRIPT_DIR/sw-discovery.sh" broadcast "$_disc_cat" "$_disc_patterns" "$_disc_text" "" 2>/dev/null || true
            fi
            # Log model used for prediction feedback
            echo "${id}|${stage_model_used}|true" >> "${ARTIFACTS_DIR}/model-routing.log"
        else
            # Self-healing: review blocked → rebuild with review findings
            if [[ "$id" == "review" && "$use_self_healing" == "true" ]] \
                && [[ -f "$ARTIFACTS_DIR/review-blockers.md" ]] \
                && [[ -s "$ARTIFACTS_DIR/review-blockers.md" ]]; then
                info "Review blocked — attempting review self-healing rebuild..."
                if self_healing_review_build_test; then
                    stage_model_used="$(get_effective_model)"
                    mark_stage_complete "$id"
                    completed=$((completed + 1))
                    echo "${id}|${stage_model_used}|true" >> "${ARTIFACTS_DIR}/model-routing.log"
                    continue
                fi
                # Self-healing exhausted — fall through to normal failure
            fi

            # Self-healing: merge blocked by CI failure or review change-request → rebuild
            if [[ "$id" == "merge" && "$use_self_healing" == "true" ]] \
                && [[ -f "${ARTIFACTS_DIR}/.retry-context-build.md" ]] \
                && [[ -s "${ARTIFACTS_DIR}/.retry-context-build.md" ]]; then
                info "Merge blocked — attempting merge self-healing rebuild..."
                if self_healing_merge_build_test; then
                    stage_model_used="$(get_effective_model)"
                    mark_stage_complete "$id"
                    completed=$((completed + 1))
                    echo "${id}|${stage_model_used}|true" >> "${ARTIFACTS_DIR}/model-routing.log"
                    continue
                fi
                # Self-healing exhausted — fall through to normal failure
            fi

            mark_stage_failed "$id"
            local stage_dur_s
            stage_dur_s=$(( $(now_epoch) - stage_start_epoch ))
            error "Pipeline failed at stage: ${BOLD}$id${RESET}"
            if [[ "${PIPELINE_STUCK_CYCLING:-false}" != "true" ]]; then
                update_status "failed" "$id"
            fi
            emit_event "stage.failed" \
                "issue=${ISSUE_NUMBER:-0}" \
                "stage=$id" \
                "duration_s=$stage_dur_s" \
                "error=${LAST_STAGE_ERROR:-unknown}" \
                "error_class=${LAST_STAGE_ERROR_CLASS:-unknown}"
            # Audit: stage failed
            if type audit_emit >/dev/null 2>&1; then
                audit_emit "stage.complete" "stage=$id" "verdict=fail" \
                    "duration_s=${stage_dur_s:-0}" || true
            fi
            # Emit vitals snapshot on failure too
            if type pipeline_emit_progress_snapshot >/dev/null 2>&1 && [[ -n "${ISSUE_NUMBER:-}" ]]; then
                pipeline_emit_progress_snapshot "${ISSUE_NUMBER}" "$id" "0" "0" "0" "${LAST_STAGE_ERROR:-unknown}" 2>/dev/null || true
            fi
            # Log model used for prediction feedback
            echo "${id}|${stage_model_used}|false" >> "${ARTIFACTS_DIR}/model-routing.log"
            # Record model outcome for UCB1 learning
            type record_model_outcome >/dev/null 2>&1 && record_model_outcome "$stage_model_used" "$id" 0 "$stage_dur_s" 0 2>/dev/null || true
            # Cancel any remaining in_progress check runs
            pipeline_cancel_check_runs 2>/dev/null || true
            return 1
        fi
    done 3<<< "$stages"

    # Pipeline complete!
    update_status "complete" ""
    PIPELINE_STAGES_PASSED="$completed"
    PIPELINE_SLOWEST_STAGE=""
    if type get_slowest_stage >/dev/null 2>&1; then
        PIPELINE_SLOWEST_STAGE=$(get_slowest_stage 2>/dev/null || true)
    fi
    local total_dur=""
    if [[ -n "$PIPELINE_START_EPOCH" ]]; then
        total_dur=$(format_duration $(( $(now_epoch) - PIPELINE_START_EPOCH )))
    fi

    echo ""
    echo -e "${GREEN}${BOLD}═══════════════════════════════════════════════════════════════════${RESET}"
    success "Pipeline complete! ${completed}/${enabled_count} stages passed in ${total_dur:-unknown}"
    echo -e "${GREEN}${BOLD}═══════════════════════════════════════════════════════════════════${RESET}"

    # Show summary
    echo ""
    if [[ -f "$ARTIFACTS_DIR/pr-url.txt" ]]; then
        echo -e "  ${BOLD}PR:${RESET}        $(cat "$ARTIFACTS_DIR/pr-url.txt")"
    fi
    echo -e "  ${BOLD}Branch:${RESET}    $GIT_BRANCH"
    [[ -n "${GITHUB_ISSUE:-}" ]] && echo -e "  ${BOLD}Issue:${RESET}     $GITHUB_ISSUE"
    echo -e "  ${BOLD}Duration:${RESET}  $total_dur"
    echo -e "  ${BOLD}Artifacts:${RESET} $ARTIFACTS_DIR/"
    echo ""

    # Capture learnings to memory (success or failure)
    if [[ -x "$SCRIPT_DIR/sw-memory.sh" ]]; then
        bash "$SCRIPT_DIR/sw-memory.sh" capture "$STATE_FILE" "$ARTIFACTS_DIR" 2>/dev/null || true
    fi

    # Final GitHub progress update
    if [[ -n "$ISSUE_NUMBER" ]]; then
        local body
        body=$(gh_build_progress_body)
        gh_update_progress "$body"
    fi

    # Post-completion cleanup
    pipeline_post_completion_cleanup
}

# ─── Post-Completion Cleanup ──────────────────────────────────────────────
# Cleans up transient artifacts after a successful pipeline run.

pipeline_post_completion_cleanup() {
    local cleaned=0

    # 1. Clear checkpoints and context files (they only matter for resume; pipeline is done)
    if [[ -d "${ARTIFACTS_DIR}/checkpoints" ]]; then
        local cp_count=0
        local cp_file
        for cp_file in "${ARTIFACTS_DIR}/checkpoints"/*-checkpoint.json; do
            [[ -f "$cp_file" ]] || continue
            rm -f "$cp_file"
            cp_count=$((cp_count + 1))
        done
        for cp_file in "${ARTIFACTS_DIR}/checkpoints"/*-claude-context.json; do
            [[ -f "$cp_file" ]] || continue
            rm -f "$cp_file"
            cp_count=$((cp_count + 1))
        done
        if [[ "$cp_count" -gt 0 ]]; then
            cleaned=$((cleaned + cp_count))
        fi
    fi

    # 2. Clear transient intelligence/routing artifacts (not needed after completion).
    # Note: delivery artifacts (intake.json, plan.md, review.md, etc.) are intentionally
    # kept so they remain inspectable after a completed run.  Only remove the ephemeral
    # files that guided decisions during the run — expanding on the original 4-file list.
    local _f
    for _f in \
        "${ARTIFACTS_DIR}/classified-findings.json" \
        "${ARTIFACTS_DIR}/reassessment.json" \
        "${ARTIFACTS_DIR}/skip-stage.txt" \
        "${ARTIFACTS_DIR}/human-message.txt" \
        "${ARTIFACTS_DIR}/model-routing.log" \
        "${ARTIFACTS_DIR}/.plan-failure-sig.txt" \
        "${ARTIFACTS_DIR}/progress-comment.id"; do
        [[ -f "$_f" ]] && rm -f "$_f" && cleaned=$((cleaned + 1)) || true
    done
    rm -f "${STATE_DIR}/loop-logs"/.agent-*-abort-reason 2>/dev/null || true

    # 3. Clear stale pipeline state (mark as idle so next run starts clean)
    if [[ -f "$STATE_FILE" ]]; then
        # Reset status to idle (preserves the file for reference but unblocks new runs)
        local tmp_state
        tmp_state=$(mktemp)
        # shellcheck disable=SC2064  # intentional expansion at definition time
        trap "rm -f '$tmp_state'" RETURN
        sed 's/^status: .*/status: idle/' "$STATE_FILE" > "$tmp_state" 2>/dev/null || true
        mv "$tmp_state" "$STATE_FILE"
    fi

    if [[ "$cleaned" -gt 0 ]]; then
        emit_event "pipeline.cleanup" \
            "issue=${ISSUE_NUMBER:-0}" \
            "cleaned=$cleaned" \
            "type=post_completion"
    fi
}

# Cancel any lingering in_progress GitHub Check Runs (called on abort/interrupt)
pipeline_cancel_check_runs() {
    if [[ "${NO_GITHUB:-false}" == "true" ]]; then
        return
    fi

    if ! type gh_checks_stage_update >/dev/null 2>&1; then
        return
    fi

    local ids_file="${ARTIFACTS_DIR:-/dev/null}/check-run-ids.json"
    [[ -f "$ids_file" ]] || return

    local stage
    while IFS= read -r stage; do
        [[ -z "$stage" ]] && continue
        gh_checks_stage_update "$stage" "completed" "cancelled" "Pipeline interrupted" 2>/dev/null || true
    done < <(jq -r 'keys[]' "$ids_file" 2>/dev/null || true)
}

# ─── Worktree Isolation ───────────────────────────────────────────────────
# Creates a git worktree for parallel-safe pipeline execution

pipeline_setup_worktree() {
    local worktree_base=".worktrees"
    local name="${WORKTREE_NAME}"

    # Auto-generate name from issue number or timestamp
    if [[ -z "$name" ]]; then
        if [[ -n "${ISSUE_NUMBER:-}" ]]; then
            name="pipeline-issue-${ISSUE_NUMBER}"
        else
            name="pipeline-$(date +%s)"
        fi
    fi

    local worktree_path="${worktree_base}/${name}"
    local branch_name="pipeline/${name}"

    info "Setting up worktree: ${DIM}${worktree_path}${RESET}"

    # Ensure worktree base exists
    mkdir -p "$worktree_base"

    # Remove stale worktree if it exists
    if [[ -d "$worktree_path" ]]; then
        warn "Worktree already exists — removing: ${worktree_path}"
        git worktree remove --force "$worktree_path" 2>/dev/null || rm -rf "$worktree_path"
    fi

    # Delete stale branch if it exists
    git branch -D "$branch_name" 2>/dev/null || true

    # Create worktree with new branch from current HEAD
    git worktree add -b "$branch_name" "$worktree_path" HEAD

    # Store original dir for cleanup, then cd into worktree
    ORIGINAL_REPO_DIR="$(pwd)"
    cd "$worktree_path" || { error "Failed to cd into worktree: $worktree_path"; return 1; }
    CLEANUP_WORKTREE=true

    success "Worktree ready: ${CYAN}${worktree_path}${RESET} (branch: ${branch_name})"
}

pipeline_cleanup_worktree() {
    if [[ "${CLEANUP_WORKTREE:-false}" != "true" ]]; then
        return
    fi

    local worktree_path
    worktree_path="$(pwd)"

    if [[ -n "${ORIGINAL_REPO_DIR:-}" && "$worktree_path" != "$ORIGINAL_REPO_DIR" ]]; then
        cd "$ORIGINAL_REPO_DIR" 2>/dev/null || cd /
        # Only clean up worktree on success — preserve on failure for inspection
        if [[ "${PIPELINE_EXIT_CODE:-1}" -eq 0 ]]; then
            info "Cleaning up worktree: ${DIM}${worktree_path}${RESET}"
            # Extract branch name before removing worktree
            local _wt_branch=""
            _wt_branch=$(git worktree list --porcelain 2>/dev/null | grep -A1 "worktree ${worktree_path}$" | grep "^branch " | sed 's|^branch refs/heads/||' || true)
            if ! git worktree remove --force "$worktree_path" 2>/dev/null; then
                warn "Failed to remove worktree at ${worktree_path} — may need manual cleanup"
            fi
            # Clean up the local branch
            if [[ -n "$_wt_branch" ]]; then
                if ! git branch -D "$_wt_branch" 2>/dev/null; then
                    warn "Failed to delete local branch ${_wt_branch}"
                fi
            fi
            # Clean up the remote branch (if it was pushed)
            if [[ -n "$_wt_branch" && "${NO_GITHUB:-}" != "true" ]]; then
                git push origin --delete "$_wt_branch" 2>/dev/null || true
            fi
        else
            warn "Pipeline failed — worktree preserved for inspection: ${DIM}${worktree_path}${RESET}"
            warn "Clean up manually: ${DIM}git worktree remove --force ${worktree_path}${RESET}"
        fi
    fi
}

# ─── Dry Run Mode ───────────────────────────────────────────────────────────
# Shows what would happen without executing
run_dry_run() {
    echo ""
    echo -e "${BLUE}${BOLD}━━━ Dry Run: Pipeline Validation ━━━${RESET}"
    echo ""

    # Validate pipeline config
    if [[ ! -f "$PIPELINE_CONFIG" ]]; then
        error "Pipeline config not found: $PIPELINE_CONFIG"
        return 1
    fi

    # Validate JSON structure
    local validate_json
    validate_json=$(jq . "$PIPELINE_CONFIG" 2>/dev/null) || {
        error "Pipeline config is not valid JSON: $PIPELINE_CONFIG"
        return 1
    }

    # Extract pipeline metadata
    local pipeline_name stages_count enabled_stages gated_stages
    pipeline_name=$(jq -r '.name // "unknown"' "$PIPELINE_CONFIG")
    stages_count=$(jq '.stages | length' "$PIPELINE_CONFIG")
    enabled_stages=$(jq '[.stages[] | select(.enabled == true)] | length' "$PIPELINE_CONFIG")
    gated_stages=$(jq '[.stages[] | select(.enabled == true and .gate == "approve")] | length' "$PIPELINE_CONFIG")

    # Build model (per-stage override or default)
    local default_model stage_model
    default_model=$(get_pipeline_model)
    stage_model="$MODEL"
    [[ -z "$stage_model" ]] && stage_model="$default_model"

    echo -e "  ${BOLD}Pipeline:${RESET}       $pipeline_name"
    echo -e "  ${BOLD}Stages:${RESET}         $enabled_stages enabled of $stages_count total"
    if [[ "$SKIP_GATES" == "true" ]]; then
        echo -e "  ${BOLD}Gates:${RESET}         ${YELLOW}all auto (--skip-gates)${RESET}"
    else
        echo -e "  ${BOLD}Gates:${RESET}         $gated_stages approval gate(s)"
    fi
    echo -e "  ${BOLD}Model:${RESET}         $stage_model"
    echo ""

    # Table header
    echo -e "${CYAN}${BOLD}Stage         Enabled  Gate     Model${RESET}"
    echo -e "${CYAN}────────────────────────────────────────${RESET}"

    # List all stages
    while IFS= read -r stage_json; do
        local stage_id stage_enabled stage_gate stage_config_model stage_model_display
        stage_id=$(echo "$stage_json" | jq -r '.id')
        stage_enabled=$(echo "$stage_json" | jq -r '.enabled')
        stage_gate=$(echo "$stage_json" | jq -r '.gate')

        # Determine stage model: CLI --model flag wins; else per-stage config; else default
        if [[ -n "${MODEL:-}" ]]; then
            stage_model_display="$MODEL"
        else
            stage_config_model=$(echo "$stage_json" | jq -r '.config.model // ""')
            if [[ -n "$stage_config_model" && "$stage_config_model" != "null" ]]; then
                stage_model_display="$stage_config_model"
            else
                stage_model_display="$default_model"
            fi
        fi

        # Format enabled
        local enabled_str
        if [[ "$stage_enabled" == "true" ]]; then
            enabled_str="${GREEN}yes${RESET}"
        else
            enabled_str="${DIM}no${RESET}"
        fi

        # Format gate
        local gate_str
        if [[ "$stage_enabled" == "true" ]]; then
            if [[ "$stage_gate" == "approve" ]]; then
                gate_str="${YELLOW}approve${RESET}"
            else
                gate_str="${GREEN}auto${RESET}"
            fi
        else
            gate_str="${DIM}—${RESET}"
        fi

        printf "%-15s %s  %s  %s\n" "$stage_id" "$enabled_str" "$gate_str" "$stage_model_display"
    done < <(jq -c '.stages[]' "$PIPELINE_CONFIG")

    echo ""

    # Validate required tools
    echo -e "${BLUE}${BOLD}━━━ Tool Validation ━━━${RESET}"
    echo ""

    local tool_errors=0
    local required_tools=("git" "jq")
    local ai_provider ai_cmd
    ai_provider="$(ai_provider_resolve "${SHIPWRIGHT_AI_PROVIDER:-}" 2>/dev/null || echo "claude")"
    ai_cmd="$(ai_provider_command "$ai_provider" 2>/dev/null || echo "$ai_provider")"
    local optional_tools=("gh" "$ai_cmd" "bc")

    for tool in "${required_tools[@]}"; do
        if command -v "$tool" >/dev/null 2>&1; then
            echo -e "  ${GREEN}✓${RESET} $tool"
        else
            echo -e "  ${RED}✗${RESET} $tool ${RED}(required)${RESET}"
            tool_errors=$((tool_errors + 1))
        fi
    done

    for tool in "${optional_tools[@]}"; do
        if command -v "$tool" >/dev/null 2>&1; then
            echo -e "  ${GREEN}✓${RESET} $tool"
        else
            echo -e "  ${DIM}○${RESET} $tool"
        fi
    done

    echo ""

    # Cost estimation: use historical averages from past pipelines when available
    echo -e "${BLUE}${BOLD}━━━ Estimated Resource Usage ━━━${RESET}"
    echo ""

    local stages_json
    stages_json=$(jq '[.stages[] | select(.enabled == true)]' "$PIPELINE_CONFIG" 2>/dev/null || echo "[]")
    local est
    est=$(estimate_pipeline_cost "$stages_json")
    local input_tokens_estimate output_tokens_estimate
    input_tokens_estimate=$(echo "$est" | jq -r '.input_tokens // 0')
    output_tokens_estimate=$(echo "$est" | jq -r '.output_tokens // 0')

    # Calculate cost based on selected model
    local input_rate output_rate input_cost output_cost total_cost
    input_rate=$(echo "$COST_MODEL_RATES" | jq -r ".${stage_model}.input // 3" 2>/dev/null || echo "3")
    output_rate=$(echo "$COST_MODEL_RATES" | jq -r ".${stage_model}.output // 15" 2>/dev/null || echo "15")

    # Cost calculation: tokens per million * rate
    input_cost=$(awk -v tokens="$input_tokens_estimate" -v rate="$input_rate" 'BEGIN{printf "%.4f", (tokens / 1000000) * rate}')
    output_cost=$(awk -v tokens="$output_tokens_estimate" -v rate="$output_rate" 'BEGIN{printf "%.4f", (tokens / 1000000) * rate}')
    total_cost=$(awk -v i="$input_cost" -v o="$output_cost" 'BEGIN{printf "%.4f", i + o}')

    echo -e "  ${BOLD}Estimated Input Tokens:${RESET}  ~$input_tokens_estimate"
    echo -e "  ${BOLD}Estimated Output Tokens:${RESET} ~$output_tokens_estimate"
    echo -e "  ${BOLD}Model Cost Rate:${RESET}        $stage_model"
    echo -e "  ${BOLD}Estimated Cost:${RESET}         \$$total_cost USD"
    echo ""

    # Validate composed pipeline if intelligence is enabled
    if [[ -f "$ARTIFACTS_DIR/composed-pipeline.json" ]] && type composer_validate_pipeline >/dev/null 2>&1; then
        echo -e "${BLUE}${BOLD}━━━ Intelligence-Composed Pipeline ━━━${RESET}"
        echo ""

        if composer_validate_pipeline "$(cat "$ARTIFACTS_DIR/composed-pipeline.json" 2>/dev/null || echo "")" 2>/dev/null; then
            echo -e "  ${GREEN}✓${RESET} Composed pipeline is valid"
        else
            echo -e "  ${YELLOW}⚠${RESET} Composed pipeline validation failed (will use template defaults)"
        fi
        echo ""
    fi

    # Final validation result
    if [[ "$tool_errors" -gt 0 ]]; then
        error "Dry run validation failed: $tool_errors required tool(s) missing"
        return 1
    fi

    success "Dry run validation passed"
    echo ""
    echo -e "  To execute this pipeline: ${DIM}remove --dry-run flag${RESET}"
    echo ""
    return 0
}

# ─── Reasoning Trace Generation ──────────────────────────────────────────────
# Multi-step autonomous reasoning traces for pipeline start (before stages run)

generate_reasoning_trace() {
    local job_id="${SHIPWRIGHT_PIPELINE_ID:-$$}"
    local issue="${ISSUE_NUMBER:-}"
    local goal="${GOAL:-}"

    # Step 1: Analyze issue complexity and risk
    local complexity="medium"
    local risk_score=50
    if [[ -n "$issue" ]] && type intelligence_analyze_issue >/dev/null 2>&1; then
        local issue_json analysis
        issue_json=$(gh issue view "$issue" --json number,title,body,labels 2>/dev/null || echo "{}")
        if [[ -n "$issue_json" && "$issue_json" != "{}" ]]; then
            analysis=$(intelligence_analyze_issue "$issue_json" 2>/dev/null || echo "")
            if [[ -n "$analysis" ]]; then
                local comp_num
                comp_num=$(echo "$analysis" | jq -r '.complexity // 5' 2>/dev/null || echo "5")
                if [[ "$comp_num" -le 3 ]]; then
                    complexity="low"
                elif [[ "$comp_num" -le 6 ]]; then
                    complexity="medium"
                else
                    complexity="high"
                fi
                risk_score=$((100 - $(echo "$analysis" | jq -r '.success_probability // 50' 2>/dev/null || echo "50")))
            fi
        fi
    elif [[ -n "$goal" ]]; then
        issue_json=$(jq -n --arg title "${goal}" --arg body "" '{title: $title, body: $body, labels: []}')
        if type intelligence_analyze_issue >/dev/null 2>&1; then
            analysis=$(intelligence_analyze_issue "$issue_json" 2>/dev/null || echo "")
            if [[ -n "$analysis" ]]; then
                local comp_num
                comp_num=$(echo "$analysis" | jq -r '.complexity // 5' 2>/dev/null || echo "5")
                if [[ "$comp_num" -le 3 ]]; then complexity="low"; elif [[ "$comp_num" -le 6 ]]; then complexity="medium"; else complexity="high"; fi
                risk_score=$((100 - $(echo "$analysis" | jq -r '.success_probability // 50' 2>/dev/null || echo "50")))
            fi
        fi
    fi

    # Step 2: Query similar past issues
    local similar_context=""
    if type memory_semantic_search >/dev/null 2>&1 && [[ -n "$goal" ]]; then
        similar_context=$(memory_semantic_search "$goal" "" 3 2>/dev/null || echo "")
    fi

    # Step 3: Select template using Thompson sampling
    local selected_template="${PIPELINE_TEMPLATE:-}"
    if [[ -z "$selected_template" ]] && type thompson_select_template >/dev/null 2>&1; then
        selected_template=$(thompson_select_template "$complexity" 2>/dev/null || echo "standard")
    fi
    [[ -z "$selected_template" ]] && selected_template="standard"

    # Step 4: Predict failure modes from memory
    local failure_predictions=""
    if type memory_semantic_search >/dev/null 2>&1 && [[ -n "$goal" ]]; then
        failure_predictions=$(memory_semantic_search "failure error $goal" "" 3 2>/dev/null || echo "")
    fi

    # Save reasoning traces to DB
    if type db_save_reasoning_trace >/dev/null 2>&1; then
        db_save_reasoning_trace "$job_id" "complexity_analysis" \
            "issue=$issue goal=$goal" \
            "Analyzed complexity=$complexity risk=$risk_score" \
            "complexity=$complexity risk_score=$risk_score" 0.7 2>/dev/null || true

        db_save_reasoning_trace "$job_id" "template_selection" \
            "complexity=$complexity historical_outcomes" \
            "Thompson sampling over historical success rates" \
            "template=$selected_template" 0.8 2>/dev/null || true

        if [[ -n "$similar_context" && "$similar_context" != "[]" ]]; then
            db_save_reasoning_trace "$job_id" "similar_issues" \
                "$goal" \
                "Found similar past issues for context injection" \
                "$similar_context" 0.6 2>/dev/null || true
        fi

        if [[ -n "$failure_predictions" && "$failure_predictions" != "[]" ]]; then
            db_save_reasoning_trace "$job_id" "failure_prediction" \
                "$goal" \
                "Predicted potential failure modes from history" \
                "$failure_predictions" 0.5 2>/dev/null || true
        fi
    fi

    # Export for use by pipeline stages
    [[ -n "$selected_template" && -z "${PIPELINE_TEMPLATE:-}" ]] && export PIPELINE_TEMPLATE="$selected_template"

    emit_event "reasoning.trace" "job_id=$job_id" "complexity=$complexity" "risk=$risk_score" "template=${selected_template:-standard}" 2>/dev/null || true
}

# ─── Subcommands ────────────────────────────────────────────────────────────

pipeline_start() {
    # Handle --repo flag: change to directory before running
    if [[ -n "$REPO_OVERRIDE" ]]; then
        if [[ ! -d "$REPO_OVERRIDE" ]]; then
            error "Directory does not exist: $REPO_OVERRIDE"
            exit 1
        fi
        if ! cd "$REPO_OVERRIDE" 2>/dev/null; then
            error "Cannot cd to: $REPO_OVERRIDE"
            exit 1
        fi
        if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
            error "Not a git repository: $REPO_OVERRIDE"
            exit 1
        fi
        ORIGINAL_REPO_DIR="$(pwd)"
        info "Using repository: $ORIGINAL_REPO_DIR"
    fi

    # Bootstrap optimization & memory if cold start (before first intelligence use)
    if [[ -f "$SCRIPT_DIR/lib/bootstrap.sh" ]]; then
        source "$SCRIPT_DIR/lib/bootstrap.sh"
        [[ ! -f "$HOME/.shipwright/optimization/iteration-model.json" ]] && bootstrap_optimization 2>/dev/null || true
        [[ ! -f "$HOME/.shipwright/memory/patterns.json" ]] && bootstrap_memory 2>/dev/null || true
    fi

    if [[ -z "$GOAL" && -z "$ISSUE_NUMBER" ]]; then
        error "Must provide --goal or --issue"
        echo -e "  Example: ${DIM}shipwright pipeline start --goal \"Add JWT auth\"${RESET}"
        echo -e "  Example: ${DIM}shipwright pipeline start --issue 123${RESET}"
        exit 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        error "jq is required. Install it: brew install jq"
        exit 1
    fi

    # Set up worktree isolation if requested
    if [[ "$AUTO_WORKTREE" == "true" ]]; then
        pipeline_setup_worktree
    fi

    # Register worktree cleanup on exit (chain with existing cleanup)
    if [[ "$CLEANUP_WORKTREE" == "true" ]]; then
        trap 'pipeline_cleanup_worktree; cleanup_on_exit' SIGINT SIGTERM
        trap 'pipeline_cleanup_worktree; cleanup_on_exit' EXIT
    fi

    setup_dirs

    # Per-host admission gate: enforce concurrency cap and free-memory floor
    # to prevent concurrent pipelines from OOM-killing the host.
    if ! check_admission_gate; then
        exit 1
    fi
    if ! write_active_pipeline_lock; then
        error "Failed to write pipeline lock at $SHIPWRIGHT_ACTIVE_PIPELINES_DIR — check permissions/disk"
        exit 1
    fi
    # Race re-check: two near-simultaneous starts could both pass the gate
    # before either writes its lock. Tiebreaker is lowest-PID-wins (not FIFO):
    # deterministic and deadlock-free. Higher-PID process backs off.
    local _post_active
    _post_active=$(count_active_pipeline_locks)
    if [[ "$_post_active" -gt "$SHIPWRIGHT_MAX_ACTIVE_PIPELINES" ]]; then
        local _lock _other_pid _lowest_pid="$_PIPELINE_PID"
        for _lock in "$SHIPWRIGHT_ACTIVE_PIPELINES_DIR"/*.json; do
            [[ -f "$_lock" ]] || continue
            _other_pid=$(jq -r '.pid // empty' "$_lock" 2>/dev/null || true)
            [[ -z "$_other_pid" || ! "$_other_pid" =~ ^[0-9]+$ ]] && continue
            if [[ "$_other_pid" -lt "$_lowest_pid" ]]; then
                _lowest_pid="$_other_pid"
            fi
        done
        if [[ "$_lowest_pid" != "$_PIPELINE_PID" ]]; then
            release_active_pipeline_lock
            emit_event "pipeline.admission_race_lost" "our_pid=$_PIPELINE_PID" "winner_pid=$_lowest_pid" 2>/dev/null || true
            error "Refusing to start: lost admission race to pid=$_lowest_pid"
            exit 1
        fi
    fi

    # Acquire durable lock to prevent concurrent pipelines on the same issue/goal
    _PIPELINE_LOCK_ID=""
    if type acquire_lock >/dev/null 2>&1; then
        _PIPELINE_LOCK_ID="pipeline-${ISSUE_NUMBER:-goal-$$}"
        if ! acquire_lock "$_PIPELINE_LOCK_ID" 5 2>/dev/null; then
            error "Another pipeline is already running for this issue/goal"
            echo -e "  Wait for it to finish, or remove stale lock:"
            echo -e "  ${DIM}rm -rf ~/.shipwright/durable/locks/${_PIPELINE_LOCK_ID}.lock${RESET}"
            _PIPELINE_LOCK_ID=""
            exit 1
        fi
    fi

    # Generate reasoning trace (complexity analysis, template selection, failure predictions)
    local user_specified_pipeline="$PIPELINE_NAME"
    generate_reasoning_trace 2>/dev/null || true
    if [[ -n "${PIPELINE_TEMPLATE:-}" && "$user_specified_pipeline" == "standard" ]]; then
        PIPELINE_NAME="$PIPELINE_TEMPLATE"
    fi

    # Check for existing pipeline (skip guard when resuming from checkpoint)
    if [[ -f "$STATE_FILE" ]] && ! $RESUME_FROM_CHECKPOINT; then
        local existing_status
        existing_status=$(sed -n 's/^status: *//p' "$STATE_FILE" | head -1)
        if [[ "$existing_status" == "running" || "$existing_status" == "paused" || "$existing_status" == "interrupted" ]]; then
            warn "A pipeline is already in progress (status: $existing_status)"
            echo -e "  Resume it: ${DIM}shipwright pipeline resume${RESET}"
            echo -e "  Abort it:  ${DIM}shipwright pipeline abort${RESET}"
            exit 1
        fi
        # `stuck_cycling` is a guardrail state — block fresh starts that would
        # silently overwrite the halt record. Operator must abort or override.
        if [[ "$existing_status" == "stuck_cycling" ]]; then
            error "Previous pipeline halted in 'stuck_cycling' state — refusing to start a new one."
            echo -e "  ${DIM}The previous run halted after consecutive test failures.${RESET}"
            echo -e "  Abort and start fresh: ${BOLD}shipwright pipeline abort${RESET}"
            echo -e "  Resume with cap disabled: ${BOLD}SW_PIPELINE_MAX_BUILD_RETRIES=0 shipwright pipeline resume${RESET}"
            emit_event "pipeline.start_refused" "reason=stuck_cycling" 2>/dev/null || true
            exit 2
        fi
    fi

    # Pre-flight checks
    preflight_checks || exit 1

    # Initialize GitHub integration
    gh_init

    load_pipeline_config

    # Checkpoint resume: when --resume is passed, try DB first, then file-based
    checkpoint_stage=""
    checkpoint_iteration=0
    if $RESUME_FROM_CHECKPOINT && type db_load_checkpoint >/dev/null 2>&1; then
        local saved_checkpoint
        saved_checkpoint=$(db_load_checkpoint "pipeline-${SHIPWRIGHT_PIPELINE_ID:-$$}" 2>/dev/null || echo "")
        if [[ -n "$saved_checkpoint" ]]; then
            checkpoint_stage=$(echo "$saved_checkpoint" | jq -r '.stage // ""' 2>/dev/null || echo "")
            if [[ -n "$checkpoint_stage" ]]; then
                info "Resuming from DB checkpoint: stage=$checkpoint_stage"
                checkpoint_iteration=$(echo "$saved_checkpoint" | jq -r '.iteration // 0' 2>/dev/null || echo "0")
                # Build COMPLETED_STAGES: all enabled stages before checkpoint_stage
                local enabled_list before_list=""
                enabled_list=$(jq -r '.stages[] | select(.enabled == true) | .id' "$PIPELINE_CONFIG" 2>/dev/null) || true
                local s
                while IFS= read -r s; do
                    [[ -z "$s" ]] && continue
                    if [[ "$s" == "$checkpoint_stage" ]]; then
                        break
                    fi
                    [[ -n "$before_list" ]] && before_list="${before_list},${s}" || before_list="$s"
                done <<< "$enabled_list"
                if [[ -n "$before_list" ]]; then
                    COMPLETED_STAGES="${before_list}"
                    SELF_HEAL_COUNT="${checkpoint_iteration}"
                fi
            fi
        fi
    fi
    if $RESUME_FROM_CHECKPOINT && [[ -z "$checkpoint_stage" ]] && [[ -d "${ARTIFACTS_DIR}/checkpoints" ]]; then
        local cp_dir="${ARTIFACTS_DIR}/checkpoints"
        local latest_cp="" latest_mtime=0
        local f
        for f in "$cp_dir"/*-checkpoint.json; do
            [[ -f "$f" ]] || continue
            local mtime
            mtime=$(file_mtime "$f" 2>/dev/null || echo "0")
            if [[ "${mtime:-0}" -gt "$latest_mtime" ]]; then
                latest_mtime="${mtime}"
                latest_cp="$f"
            fi
        done
        if [[ -n "$latest_cp" && -x "$SCRIPT_DIR/sw-checkpoint.sh" ]]; then
            checkpoint_stage="$(basename "$latest_cp" -checkpoint.json)"
            local cp_json
            cp_json="$("$SCRIPT_DIR/sw-checkpoint.sh" restore --stage "$checkpoint_stage" 2>/dev/null)" || true
            if [[ -n "$cp_json" ]] && command -v jq >/dev/null 2>&1; then
                checkpoint_iteration="$(echo "$cp_json" | jq -r '.iteration // 0' 2>/dev/null)" || checkpoint_iteration=0
                info "Checkpoint resume: stage=${checkpoint_stage} iteration=${checkpoint_iteration}"
                # Build COMPLETED_STAGES: all enabled stages before checkpoint_stage
                local enabled_list before_list=""
                enabled_list="$(jq -r '.stages[] | select(.enabled == true) | .id' "$PIPELINE_CONFIG" 2>/dev/null)" || true
                local s
                while IFS= read -r s; do
                    [[ -z "$s" ]] && continue
                    if [[ "$s" == "$checkpoint_stage" ]]; then
                        break
                    fi
                    [[ -n "$before_list" ]] && before_list="${before_list},${s}" || before_list="$s"
                done <<< "$enabled_list"
                if [[ -n "$before_list" ]]; then
                    COMPLETED_STAGES="${before_list}"
                    SELF_HEAL_COUNT="${checkpoint_iteration}"
                fi
            fi
        fi
    fi

    # Restore from state file if resuming (failed/interrupted/running pipeline); else initialize fresh
    # Note: "running" is included because a killed process leaves status as "running"
    # without gracefully setting it to "interrupted"
    if $RESUME_FROM_CHECKPOINT && [[ -f "$STATE_FILE" ]]; then
        local existing_status
        existing_status="$(sed -n 's/^status: *//p' "$STATE_FILE" | head -1)"
        if [[ "$existing_status" == "failed" || "$existing_status" == "interrupted" || "$existing_status" == "running" ]]; then
            resume_state || exit $?
            if [[ -n "${OUTER_STAGE:-}" ]]; then
                CURRENT_STAGE="$OUTER_STAGE"
                clear_outer_stage   # writes state; no transient memory/file divergence
            fi
        else
            initialize_state
        fi
    else
        initialize_state
    fi

    # CI resume: restore branch + goal context when intake is skipped
    if [[ -n "${COMPLETED_STAGES:-}" ]] && echo "$COMPLETED_STAGES" | tr ',' '\n' | grep -qx "intake"; then
        # Intake was completed in a previous run — restore context
        # The workflow checks out the partial work branch directly, so code changes are on HEAD

        # Restore GOAL from issue if not already set
        if [[ -z "$GOAL" && -n "$ISSUE_NUMBER" ]]; then
            GOAL=$(_timeout "$(_config_get_int "network.gh_timeout" 30 2>/dev/null || echo 30)" gh issue view "$ISSUE_NUMBER" --json title -q .title 2>/dev/null || echo "Issue #${ISSUE_NUMBER}")
            info "CI resume: goal from issue — ${GOAL}"
        fi

        # Restore branch context
        if [[ -z "$GIT_BRANCH" ]]; then
            local _fallback
            if [[ "${CI_MODE:-false}" == "true" ]]; then
                if [[ -z "${WORKSPACE_BRANCH:-}" ]]; then
                    error "CI resume: WORKSPACE_BRANCH unset. Refusing to fall back to ci/issue-${ISSUE_NUMBER}."
                    exit 2
                fi
                _fallback="$WORKSPACE_BRANCH"
            else
                _fallback="${WORKSPACE_BRANCH:-ci/issue-${ISSUE_NUMBER}}"
            fi
            info "CI resume: restoring branch ${_fallback}"
            if ! git checkout "$_fallback" 2>/dev/null && ! git checkout -b "$_fallback" 2>/dev/null; then
                warn "CI resume: failed to checkout branch ${_fallback}"
            fi
            GIT_BRANCH="$_fallback"
        elif [[ "$(git branch --show-current 2>/dev/null)" != "$GIT_BRANCH" ]]; then
            info "CI resume: checking out branch ${GIT_BRANCH}"
            if ! git checkout "$GIT_BRANCH" 2>/dev/null && ! git checkout -b "$GIT_BRANCH" 2>/dev/null; then
                warn "CI resume: failed to checkout branch ${GIT_BRANCH}"
            fi
        fi
        # Capture clean goal before write_state — prevents lazy bootstrap contamination
        ORIGINAL_GOAL="${ORIGINAL_GOAL:-$GOAL}"
        write_state 2>/dev/null || true
    fi

    # Capture clean goal before any stage mutations — mirrors sw-loop.sh:415
    ORIGINAL_GOAL="${ORIGINAL_GOAL:-$GOAL}"

    echo ""
    echo -e "${PURPLE}${BOLD}╔═══════════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${PURPLE}${BOLD}║  shipwright pipeline — Autonomous Feature Delivery               ║${RESET}"
    echo -e "${PURPLE}${BOLD}╚═══════════════════════════════════════════════════════════════════╝${RESET}"
    echo ""

    # Comprehensive environment summary
    if [[ -n "$GOAL" ]]; then
        echo -e "  ${BOLD}Goal:${RESET}        $GOAL"
    fi
    if [[ -n "$ISSUE_NUMBER" ]]; then
        echo -e "  ${BOLD}Issue:${RESET}       #$ISSUE_NUMBER"
    fi

    echo -e "  ${BOLD}Pipeline:${RESET}    $PIPELINE_NAME"

    local enabled_stages
    enabled_stages=$(jq -r '.stages[] | select(.enabled == true) | .id' "$PIPELINE_CONFIG" | tr '\n' ' ')
    echo -e "  ${BOLD}Stages:${RESET}      $enabled_stages"

    local gate_count
    gate_count=$(jq '[.stages[] | select(.gate == "approve" and .enabled == true)] | length' "$PIPELINE_CONFIG")
    if [[ "$HEADLESS" == "true" ]]; then
        echo -e "  ${BOLD}Gates:${RESET}       ${YELLOW}all auto (headless — non-interactive stdin detected)${RESET}"
    elif [[ "$SKIP_GATES" == "true" ]]; then
        echo -e "  ${BOLD}Gates:${RESET}       ${YELLOW}all auto (--skip-gates)${RESET}"
    else
        echo -e "  ${BOLD}Gates:${RESET}       ${gate_count} approval gate(s)"
    fi

    echo -e "  ${BOLD}Model:${RESET}       $(get_pipeline_model)"
    echo -e "  ${BOLD}Self-heal:${RESET}   ${BUILD_TEST_RETRIES} retry cycle(s)"

    if [[ "$GH_AVAILABLE" == "true" ]]; then
        echo -e "  ${BOLD}GitHub:${RESET}      ${GREEN}✓${RESET} ${DIM}${REPO_OWNER}/${REPO_NAME}${RESET}"
    else
        echo -e "  ${BOLD}GitHub:${RESET}      ${DIM}disabled${RESET}"
    fi

    if [[ -n "$SLACK_WEBHOOK" ]]; then
        echo -e "  ${BOLD}Slack:${RESET}       ${GREEN}✓${RESET} notifications enabled"
    fi

    echo ""

    if [[ "$DRY_RUN" == "true" ]]; then
        run_dry_run
        return $?
    fi

    # Capture predictions for feedback loop (intelligence → actuals → learning)
    if type intelligence_analyze_issue >/dev/null 2>&1 && (type intelligence_estimate_iterations >/dev/null 2>&1 || type intelligence_predict_cost >/dev/null 2>&1); then
        local issue_json="${INTELLIGENCE_ANALYSIS:-}"
        if [[ -z "$issue_json" || "$issue_json" == "{}" ]]; then
            if [[ -n "$ISSUE_NUMBER" ]]; then
                issue_json=$(gh issue view "$ISSUE_NUMBER" --json number,title,body,labels 2>/dev/null || echo "{}")
            else
                issue_json=$(jq -n --arg title "${GOAL:-untitled}" --arg body "" '{title: $title, body: $body, labels: []}')
            fi
            if [[ -n "$issue_json" && "$issue_json" != "{}" ]]; then
                issue_json=$(intelligence_analyze_issue "$issue_json" 2>/dev/null || echo "{}")
            fi
        fi
        if [[ -n "$issue_json" && "$issue_json" != "{}" ]]; then
            if type intelligence_estimate_iterations >/dev/null 2>&1; then
                PREDICTED_ITERATIONS=$(intelligence_estimate_iterations "$issue_json" "" 2>/dev/null || echo "")
                export PREDICTED_ITERATIONS
            fi
            if type intelligence_predict_cost >/dev/null 2>&1; then
                local cost_json
                cost_json=$(intelligence_predict_cost "$issue_json" "{}" 2>/dev/null || echo "{}")
                PREDICTED_COST=$(echo "$cost_json" | jq -r '.estimated_cost_usd // empty' 2>/dev/null || echo "")
                export PREDICTED_COST
            fi
        fi
    fi

    # Start background heartbeat writer
    start_heartbeat

    # Initialize GitHub Check Runs for all pipeline stages
    if [[ "${NO_GITHUB:-false}" != "true" ]] && type gh_checks_pipeline_start >/dev/null 2>&1; then
        local head_sha
        head_sha=$(git rev-parse HEAD 2>/dev/null || echo "")
        if [[ -n "$head_sha" && -n "$REPO_OWNER" && -n "$REPO_NAME" ]]; then
            local stages_json
            stages_json=$(jq -c '[.stages[] | select(.enabled == true) | .id]' "$PIPELINE_CONFIG" 2>/dev/null || echo '[]')
            gh_checks_pipeline_start "$REPO_OWNER" "$REPO_NAME" "$head_sha" "$stages_json" >/dev/null 2>/dev/null || true
            info "GitHub Checks: created check runs for pipeline stages"
        fi
    fi

    # Send start notification
    notify "Pipeline Started" "Goal: ${GOAL}\nPipeline: ${PIPELINE_NAME}" "info"

    emit_event "pipeline.started" \
        "issue=${ISSUE_NUMBER:-0}" \
        "template=${PIPELINE_NAME}" \
        "complexity=${INTELLIGENCE_COMPLEXITY:-0}" \
        "machine=$(hostname 2>/dev/null || echo "unknown")" \
        "pipeline=${PIPELINE_NAME}" \
        "model=$(get_pipeline_model)" \
        "goal=${GOAL}"

    # Record pipeline run in SQLite for dashboard visibility
    if type add_pipeline_run >/dev/null 2>&1; then
        add_pipeline_run "${SHIPWRIGHT_PIPELINE_ID}" "${ISSUE_NUMBER:-0}" "${GOAL}" "${BRANCH:-}" "${PIPELINE_NAME}" 2>/dev/null || true
    fi

    # Durable WAL: publish pipeline start event
    if type publish_event >/dev/null 2>&1; then
        publish_event "pipeline.started" "{\"issue\":\"${ISSUE_NUMBER:-0}\",\"pipeline\":\"${PIPELINE_NAME}\",\"goal\":\"${GOAL:0:200}\"}" 2>/dev/null || true
    fi

    run_pipeline
    local exit_code=$?
    PIPELINE_EXIT_CODE="$exit_code"

    # Compute total cost for pipeline.completed (prefer actual from Claude when available)
    local model_key
    model_key="$(get_effective_model)"
    local total_cost
    if [[ -n "${TOTAL_COST_USD:-}" && "${TOTAL_COST_USD}" != "0" && "${TOTAL_COST_USD}" != "null" ]]; then
        total_cost="${TOTAL_COST_USD}"
    else
        local input_cost output_cost
        input_cost=$(awk -v tokens="$TOTAL_INPUT_TOKENS" -v rate="$(echo "$COST_MODEL_RATES" | jq -r ".${model_key}.input // 3")" 'BEGIN{printf "%.4f", (tokens / 1000000) * rate}')
        output_cost=$(awk -v tokens="$TOTAL_OUTPUT_TOKENS" -v rate="$(echo "$COST_MODEL_RATES" | jq -r ".${model_key}.output // 15")" 'BEGIN{printf "%.4f", (tokens / 1000000) * rate}')
        total_cost=$(awk -v i="$input_cost" -v o="$output_cost" 'BEGIN{printf "%.4f", i + o}')
    fi

    # Send completion notification + event
    local total_dur_s=""
    [[ -n "$PIPELINE_START_EPOCH" ]] && total_dur_s=$(( $(now_epoch) - PIPELINE_START_EPOCH ))
    if [[ "$exit_code" -eq 0 ]]; then
        local total_dur=""
        [[ -n "$total_dur_s" ]] && total_dur=$(format_duration "$total_dur_s")
        local pr_url
        pr_url=$(cat "$ARTIFACTS_DIR/pr-url.txt" 2>/dev/null || echo "")
        notify "Pipeline Complete" "Goal: ${GOAL}\nDuration: ${total_dur:-unknown}\nPR: ${pr_url:-N/A}" "success"
        emit_event "pipeline.completed" \
            "issue=${ISSUE_NUMBER:-0}" \
            "result=success" \
            "duration_s=${total_dur_s:-0}" \
            "iterations=$((SELF_HEAL_COUNT + 1))" \
            "template=${PIPELINE_NAME}" \
            "complexity=${INTELLIGENCE_COMPLEXITY:-0}" \
            "stages_passed=${PIPELINE_STAGES_PASSED:-0}" \
            "slowest_stage=${PIPELINE_SLOWEST_STAGE:-}" \
            "pr_url=${pr_url:-}" \
            "agent_id=${PIPELINE_AGENT_ID}" \
            "input_tokens=$TOTAL_INPUT_TOKENS" \
            "output_tokens=$TOTAL_OUTPUT_TOKENS" \
            "total_cost=$total_cost" \
            "self_heal_count=$SELF_HEAL_COUNT"

        # Finalize audit trail
        if type audit_finalize >/dev/null 2>&1; then
            audit_finalize "success" || true
        fi

        # Update pipeline run status in SQLite
        if type update_pipeline_status >/dev/null 2>&1; then
            update_pipeline_status "${SHIPWRIGHT_PIPELINE_ID}" "completed" "${PIPELINE_SLOWEST_STAGE:-}" "complete" "${total_dur_s:-0}" 2>/dev/null || true
        fi

        # Auto-ingest pipeline outcome into recruit profiles
        if [[ -x "$SCRIPT_DIR/sw-recruit.sh" ]]; then
            bash "$SCRIPT_DIR/sw-recruit.sh" ingest-pipeline 1 2>/dev/null || true
        fi

        # Capture success patterns to memory (learn what works — parallel the failure path)
        if [[ -x "$SCRIPT_DIR/sw-memory.sh" ]]; then
            bash "$SCRIPT_DIR/sw-memory.sh" capture "$STATE_FILE" "$ARTIFACTS_DIR" 2>/dev/null || true
        fi
        # Update memory baselines with successful run metrics
        if type memory_update_metrics >/dev/null 2>&1; then
            memory_update_metrics "build_duration_s" "${total_dur_s:-0}" 2>/dev/null || true
            memory_update_metrics "total_cost_usd" "${total_cost:-0}" 2>/dev/null || true
            memory_update_metrics "iterations" "$((SELF_HEAL_COUNT + 1))" 2>/dev/null || true
        fi

        # Record positive fix outcome if self-healing succeeded
        if [[ "$SELF_HEAL_COUNT" -gt 0 && -x "$SCRIPT_DIR/sw-memory.sh" ]]; then
            local _success_sig
            _success_sig=$(tail -30 "$ARTIFACTS_DIR/test-results.log" 2>/dev/null | head -3 | tr '\n' ' ' | sed 's/^ *//;s/ *$//' || true)
            if [[ -n "$_success_sig" ]]; then
                bash "$SCRIPT_DIR/sw-memory.sh" fix-outcome "$_success_sig" "true" "true" 2>/dev/null || true
            fi
        fi
    else
        notify "Pipeline Failed" "Goal: ${GOAL}\nFailed at: ${CURRENT_STAGE_ID:-unknown}" "error"
        emit_event "pipeline.completed" \
            "issue=${ISSUE_NUMBER:-0}" \
            "result=failure" \
            "duration_s=${total_dur_s:-0}" \
            "iterations=$((SELF_HEAL_COUNT + 1))" \
            "template=${PIPELINE_NAME}" \
            "complexity=${INTELLIGENCE_COMPLEXITY:-0}" \
            "failed_stage=${CURRENT_STAGE_ID:-unknown}" \
            "error_class=${LAST_STAGE_ERROR_CLASS:-unknown}" \
            "agent_id=${PIPELINE_AGENT_ID}" \
            "input_tokens=$TOTAL_INPUT_TOKENS" \
            "output_tokens=$TOTAL_OUTPUT_TOKENS" \
            "total_cost=$total_cost" \
            "self_heal_count=$SELF_HEAL_COUNT"

        # Finalize audit trail
        if type audit_finalize >/dev/null 2>&1; then
            audit_finalize "failure" || true
        fi

        # Update pipeline run status in SQLite
        if type update_pipeline_status >/dev/null 2>&1; then
            update_pipeline_status "${SHIPWRIGHT_PIPELINE_ID}" "failed" "${CURRENT_STAGE_ID:-unknown}" "failed" "${total_dur_s:-0}" 2>/dev/null || true
        fi

        # Auto-ingest pipeline outcome into recruit profiles
        if [[ -x "$SCRIPT_DIR/sw-recruit.sh" ]]; then
            bash "$SCRIPT_DIR/sw-recruit.sh" ingest-pipeline 1 2>/dev/null || true
        fi

        # Capture failure learnings to memory
        if [[ -x "$SCRIPT_DIR/sw-memory.sh" ]]; then
            bash "$SCRIPT_DIR/sw-memory.sh" capture "$STATE_FILE" "$ARTIFACTS_DIR" 2>/dev/null || true
            bash "$SCRIPT_DIR/sw-memory.sh" analyze-failure "$ARTIFACTS_DIR/.claude-tokens-${CURRENT_STAGE_ID:-build}.log" "${CURRENT_STAGE_ID:-unknown}" 2>/dev/null || true

            # Record negative fix outcome — memory suggested a fix but it didn't resolve the issue
            # This closes the negative side of the fix-outcome feedback loop
            if [[ "$SELF_HEAL_COUNT" -gt 0 ]]; then
                local _fail_sig
                _fail_sig=$(tail -30 "$ARTIFACTS_DIR/test-results.log" 2>/dev/null | head -3 | tr '\n' ' ' | sed 's/^ *//;s/ *$//' || true)
                if [[ -n "$_fail_sig" ]]; then
                    bash "$SCRIPT_DIR/sw-memory.sh" fix-outcome "$_fail_sig" "true" "false" 2>/dev/null || true
                fi
            fi
        fi
    fi

    # AI-powered outcome learning
    if type skill_analyze_outcome >/dev/null 2>&1; then
        local _failed_stage=""
        local _error_ctx=""
        if [[ "$exit_code" -ne 0 ]]; then
            _failed_stage="${CURRENT_STAGE_ID:-unknown}"
            _error_ctx=$(tail -30 "$ARTIFACTS_DIR/errors-collected.json" 2>/dev/null || true)
        fi
        local _outcome_result="success"
        [[ "$exit_code" -ne 0 ]] && _outcome_result="failure"

        if skill_analyze_outcome "$_outcome_result" "$ARTIFACTS_DIR" "$_failed_stage" "$_error_ctx" 2>/dev/null; then
            info "Skill outcome analysis complete — learnings recorded"
        fi
    fi

    # ── Prediction Validation Events ──
    # Compare predicted vs actual outcomes for feedback loop calibration
    local pipeline_success="false"
    [[ "$exit_code" -eq 0 ]] && pipeline_success="true"

    # Complexity prediction vs actual iterations
    emit_event "prediction.validated" \
        "issue=${ISSUE_NUMBER:-0}" \
        "predicted_complexity=${INTELLIGENCE_COMPLEXITY:-0}" \
        "actual_iterations=$SELF_HEAL_COUNT" \
        "success=$pipeline_success"

    # Close intelligence prediction feedback loop — validate predicted vs actual
    if type intelligence_validate_prediction >/dev/null 2>&1 && [[ -n "${ISSUE_NUMBER:-}" ]]; then
        intelligence_validate_prediction \
            "$ISSUE_NUMBER" \
            "${INTELLIGENCE_COMPLEXITY:-0}" \
            "${SELF_HEAL_COUNT:-0}" \
            "$pipeline_success" 2>/dev/null || true
    fi

    # Validate iterations prediction against actuals (cost validation moved below after total_cost is computed)
    local ACTUAL_ITERATIONS=$((SELF_HEAL_COUNT + 1))
    if [[ -n "${PREDICTED_ITERATIONS:-}" ]] && type intelligence_validate_prediction >/dev/null 2>&1; then
        intelligence_validate_prediction "iterations" "$PREDICTED_ITERATIONS" "$ACTUAL_ITERATIONS" 2>/dev/null || true
    fi

    # Close predictive anomaly feedback loop — confirm whether flagged anomalies were real
    if [[ -x "$SCRIPT_DIR/sw-predictive.sh" ]]; then
        local _actual_failure="false"
        [[ "$exit_code" -ne 0 ]] && _actual_failure="true"
        # Confirm anomalies for build and test stages based on pipeline outcome
        for _anomaly_stage in build test; do
            bash "$SCRIPT_DIR/sw-predictive.sh" confirm-anomaly "$_anomaly_stage" "duration_s" "$_actual_failure" 2>/dev/null || true
        done
    fi

    # Template outcome tracking
    emit_event "template.outcome" \
        "issue=${ISSUE_NUMBER:-0}" \
        "template=${PIPELINE_NAME}" \
        "success=$pipeline_success" \
        "duration_s=${total_dur_s:-0}" \
        "complexity=${INTELLIGENCE_COMPLEXITY:-0}"

    # Risk prediction vs actual failure
    local predicted_risk="${INTELLIGENCE_RISK_SCORE:-0}"
    emit_event "risk.outcome" \
        "issue=${ISSUE_NUMBER:-0}" \
        "predicted_risk=$predicted_risk" \
        "actual_failure=$([[ "$exit_code" -ne 0 ]] && echo "true" || echo "false")"

    # Per-stage model outcome events (read from stage timings)
    local routing_log="${ARTIFACTS_DIR}/model-routing.log"
    if [[ -f "$routing_log" ]]; then
        while IFS='|' read -r s_stage s_model s_success; do
            [[ -z "$s_stage" ]] && continue
            emit_event "model.outcome" \
                "issue=${ISSUE_NUMBER:-0}" \
                "stage=$s_stage" \
                "model=$s_model" \
                "success=$s_success"
        done < "$routing_log"
    fi

    # Record pipeline outcome for model routing feedback loop
    if type optimize_analyze_outcome >/dev/null 2>&1; then
        optimize_analyze_outcome "$STATE_FILE" 2>/dev/null || true
    fi

    # Auto-learn after pipeline completion (non-blocking).
    # Both stdout and stderr are suppressed so this background subshell does not
    # hold the write end of the "| tee" pipe open after the pipeline exits.
    if type optimize_tune_templates &>/dev/null; then
        (
            optimize_tune_templates 2>/dev/null
            optimize_learn_iterations 2>/dev/null
            optimize_route_models 2>/dev/null
            optimize_learn_risk_keywords 2>/dev/null
        ) >/dev/null 2>&1 &
    fi

    if type memory_finalize_pipeline >/dev/null 2>&1; then
        memory_finalize_pipeline "$STATE_FILE" "$ARTIFACTS_DIR" 2>/dev/null || true
    fi

    # Broadcast discovery for cross-pipeline learning
    if type broadcast_discovery >/dev/null 2>&1; then
        local _disc_result="failure"
        [[ "$exit_code" -eq 0 ]] && _disc_result="success"
        local _disc_files=""
        _disc_files=$(git diff --name-only HEAD~1 HEAD 2>/dev/null | head -20 | tr '\n' ',' || true)
        broadcast_discovery "pipeline_${_disc_result}" "${_disc_files:-unknown}" \
            "Pipeline ${_disc_result} for issue #${ISSUE_NUMBER:-0} (${PIPELINE_NAME:-unknown} template, stage=${CURRENT_STAGE_ID:-unknown})" \
            "${_disc_result}" 2>/dev/null || true
    fi

    # Emit cost event — prefer actual cost from Claude CLI when available
    local model_key
    model_key="$(get_effective_model)"
    local total_cost
    if [[ -n "${TOTAL_COST_USD:-}" && "${TOTAL_COST_USD}" != "0" && "${TOTAL_COST_USD}" != "null" ]]; then
        total_cost="${TOTAL_COST_USD}"
    else
        # Fallback: estimate from token counts and model rates
        local input_cost output_cost
        input_cost=$(awk -v tokens="$TOTAL_INPUT_TOKENS" -v rate="$(echo "$COST_MODEL_RATES" | jq -r ".${model_key}.input // 3")" 'BEGIN{printf "%.4f", (tokens / 1000000) * rate}')
        output_cost=$(awk -v tokens="$TOTAL_OUTPUT_TOKENS" -v rate="$(echo "$COST_MODEL_RATES" | jq -r ".${model_key}.output // 15")" 'BEGIN{printf "%.4f", (tokens / 1000000) * rate}')
        total_cost=$(awk -v i="$input_cost" -v o="$output_cost" 'BEGIN{printf "%.4f", i + o}')
    fi

    emit_event "pipeline.cost" \
        "input_tokens=$TOTAL_INPUT_TOKENS" \
        "output_tokens=$TOTAL_OUTPUT_TOKENS" \
        "model=$model_key" \
        "cost_usd=$total_cost"

    # Persist a pipeline-level cost entry only when stage attribution is NOT active.
    # When record_stage_cost_end is loaded, each stage delta is already written to
    # costs.json individually, so writing a pipeline total here would double-count
    # every token in budget checks and dashboard aggregations.
    if type cost_record >/dev/null 2>&1 && ! type record_stage_cost_end >/dev/null 2>&1; then
        cost_record "$TOTAL_INPUT_TOKENS" "$TOTAL_OUTPUT_TOKENS" "$model_key" "pipeline" "${ISSUE_NUMBER:-}" 2>/dev/null || true
    fi
    # cost_generate_breakdown runs from cleanup_on_exit so it fires on every exit path.

    # Record pipeline outcome for Thompson sampling / outcome-based learning
    if type db_record_outcome >/dev/null 2>&1; then
        local _outcome_success=0
        [[ "$exit_code" -eq 0 ]] && _outcome_success=1
        local _outcome_complexity="medium"
        [[ "${INTELLIGENCE_COMPLEXITY:-5}" -le 3 ]] && _outcome_complexity="low"
        [[ "${INTELLIGENCE_COMPLEXITY:-5}" -ge 7 ]] && _outcome_complexity="high"
        db_record_outcome \
            "${SHIPWRIGHT_PIPELINE_ID:-pipeline-$$-${ISSUE_NUMBER:-0}}" \
            "${ISSUE_NUMBER:-}" \
            "${PIPELINE_NAME:-standard}" \
            "$_outcome_success" \
            "${total_dur_s:-0}" \
            "${SELF_HEAL_COUNT:-0}" \
            "${total_cost:-0}" \
            "$_outcome_complexity" 2>/dev/null || true
    fi

    # Validate cost prediction against actual (after total_cost is computed)
    if [[ -n "${PREDICTED_COST:-}" ]] && type intelligence_validate_prediction >/dev/null 2>&1; then
        intelligence_validate_prediction "cost" "$PREDICTED_COST" "$total_cost" 2>/dev/null || true
    fi

    # Close the ruflo learning feedback loop — index pipeline outcome into HNSW
    if type ruflo_learn_from_shipwright >/dev/null 2>&1; then
        local _ruflo_result="success"
        [[ "$exit_code" -ne 0 ]] && _ruflo_result="failure"
        local _ruflo_outcome
        _ruflo_outcome=$(jq -n \
            --arg status "$_ruflo_result" \
            --arg issue "${ISSUE_NUMBER:-}" \
            --arg goal "${GOAL:-}" \
            --arg template "${PIPELINE_NAME:-standard}" \
            --argjson duration_s "${total_dur_s:-0}" \
            --argjson stages_passed "${PIPELINE_STAGES_PASSED:-0}" \
            --argjson self_heal_count "${SELF_HEAL_COUNT:-0}" \
            --arg failed_stage "${CURRENT_STAGE_ID:-}" \
            '{"task_type":"pipeline","status":$status,"issue_number":$issue,"goal":$goal,"template":$template,"duration_s":$duration_s,"stages_passed":$stages_passed,"self_heal_count":$self_heal_count,"failed_stage":$failed_stage}')
        ruflo_learn_from_shipwright "$_ruflo_outcome" 2>/dev/null || true
    fi

    return $exit_code
}

pipeline_resume() {
    setup_dirs

    # Refuse to resume a `stuck_cycling` pipeline unless the operator has
    # explicitly disabled the cap via SW_PIPELINE_MAX_BUILD_RETRIES=0.
    # Read directly from the state file because resume_state() unconditionally
    # rewrites PIPELINE_STATUS to "running" before returning (#448 review feedback).
    if [[ -f "$STATE_FILE" ]]; then
        if [[ ! -r "$STATE_FILE" ]]; then
            error "State file '$STATE_FILE' exists but is not readable — cannot verify pipeline state before resume"
            exit 1
        fi
        local _persisted_status
        _persisted_status=$(sed -n 's/^status: *//p' "$STATE_FILE" | head -1)
        if [[ "$_persisted_status" == "stuck_cycling" ]]; then
            local _max_retries_resume="${SW_PIPELINE_MAX_BUILD_RETRIES:-3}"
            if [[ "$_max_retries_resume" != "0" ]]; then
                error "Pipeline is in 'stuck_cycling' state — refusing to resume."
                echo -e "  ${DIM}The previous run halted after consecutive test failures.${RESET}"
                echo -e "  ${DIM}Investigate the failures, then either:${RESET}"
                echo -e "    1. Fix the underlying issue and resume with cap disabled:"
                echo -e "       ${BOLD}SW_PIPELINE_MAX_BUILD_RETRIES=0 shipwright pipeline resume${RESET}"
                echo -e "    2. Abort and start fresh: ${BOLD}shipwright pipeline abort${RESET}"
                emit_event "pipeline.resume_refused" "reason=stuck_cycling" "max_retries=$_max_retries_resume" 2>/dev/null || true
                exit 2
            fi
            warn "Resuming stuck_cycling pipeline with SW_PIPELINE_MAX_BUILD_RETRIES=0 (cap disabled)."
            emit_event "pipeline.stuck_cycling_resume_override" "max_retries=0" 2>/dev/null || true
        fi
    fi

    resume_state || exit $?

    # Refuse to resume if pipeline is stuck (terminal state)
    if [[ "${STATUS:-}" == "stuck" ]]; then
        error "Cannot resume: pipeline halted with status: stuck"
        error "The loop detected cycling and no further progress is possible."
        error "Review the error log and try: shipwright pipeline start --goal \"...\""
        exit 2
    fi

    # Recompute TASKS_FILE now that ISSUE_NUMBER has been populated from the state file.
    # setup_dirs runs before resume_state, so ISSUE_NUMBER was empty during the first call.
    TASKS_FILE="${STATE_DIR}/pipeline-tasks${ISSUE_NUMBER:+-${ISSUE_NUMBER}}.md"
    load_pipeline_config

    # Resume is a fresh process — re-claim a host slot through the same gate.
    if ! check_admission_gate; then
        exit 1
    fi
    if ! write_active_pipeline_lock; then
        error "Failed to write pipeline lock at $SHIPWRIGHT_ACTIVE_PIPELINES_DIR — check permissions/disk"
        exit 1
    fi
    # Race re-check: same lowest-PID-wins tiebreaker as pipeline_start to
    # prevent two simultaneous resumes from both bypassing the admission gate.
    local _post_active
    _post_active=$(count_active_pipeline_locks)
    if [[ "$_post_active" -gt "$SHIPWRIGHT_MAX_ACTIVE_PIPELINES" ]]; then
        local _lock _other_pid _lowest_pid="$_PIPELINE_PID"
        for _lock in "$SHIPWRIGHT_ACTIVE_PIPELINES_DIR"/*.json; do
            [[ -f "$_lock" ]] || continue
            _other_pid=$(jq -r '.pid // empty' "$_lock" 2>/dev/null || true)
            [[ -z "$_other_pid" || ! "$_other_pid" =~ ^[0-9]+$ ]] && continue
            if [[ "$_other_pid" -lt "$_lowest_pid" ]]; then
                _lowest_pid="$_other_pid"
            fi
        done
        if [[ "$_lowest_pid" != "$_PIPELINE_PID" ]]; then
            release_active_pipeline_lock
            emit_event "pipeline.admission_race_lost" "our_pid=$_PIPELINE_PID" "winner_pid=$_lowest_pid" 2>/dev/null || true
            error "Refusing to resume: lost admission race to pid=$_lowest_pid"
            exit 1
        fi
    fi

    echo ""
    run_pipeline
}

pipeline_status() {
    setup_dirs

    if [[ ! -f "$STATE_FILE" ]]; then
        info "No active pipeline."
        echo -e "  Start one: ${DIM}shipwright pipeline start --goal \"...\"${RESET}"
        return
    fi

    echo ""
    echo -e "${PURPLE}${BOLD}━━━ Pipeline Status ━━━${RESET}"
    echo ""

    local p_name="" p_goal="" p_status="" p_branch="" p_stage="" p_started="" p_issue="" p_elapsed="" p_pr=""
    local in_frontmatter=false
    while IFS= read -r line; do
        if [[ "$line" == "---" ]]; then
            if $in_frontmatter; then break; else in_frontmatter=true; continue; fi
        fi
        if $in_frontmatter; then
            case "$line" in
                pipeline:*)      p_name="$(_trim "${line#pipeline:}")" ;;
                goal:*)          p_goal="$(echo "${line#goal:}" | sed 's/^ *"//;s/" *$//')" ;;
                status:*)        p_status="$(_trim "${line#status:}")" ;;
                branch:*)        p_branch="$(echo "${line#branch:}" | sed 's/^ *"//;s/" *$//')" ;;
                current_stage:*) p_stage="$(_trim "${line#current_stage:}")" ;;
                started_at:*)    p_started="$(_trim "${line#started_at:}")" ;;
                issue:*)         p_issue="$(echo "${line#issue:}" | sed 's/^ *"//;s/" *$//')" ;;
                elapsed:*)       p_elapsed="$(_trim "${line#elapsed:}")" ;;
                pr_number:*)     p_pr="$(_trim "${line#pr_number:}")" ;;
            esac
        fi
    done < "$STATE_FILE"

    local status_icon
    case "$p_status" in
        running)        status_icon="${CYAN}●${RESET}" ;;
        complete)       status_icon="${GREEN}✓${RESET}" ;;
        paused)         status_icon="${YELLOW}⏸${RESET}" ;;
        interrupted)    status_icon="${YELLOW}⚡${RESET}" ;;
        failed)         status_icon="${RED}✗${RESET}" ;;
        aborted)        status_icon="${RED}◼${RESET}" ;;
        stuck_cycling)  status_icon="${YELLOW}⚠${RESET}" ;;
        *)              status_icon="${DIM}○${RESET}" ;;
    esac

    echo -e "  ${BOLD}Pipeline:${RESET}  $p_name"
    echo -e "  ${BOLD}Goal:${RESET}      $p_goal"
    echo -e "  ${BOLD}Status:${RESET}    $status_icon $p_status"
    [[ -n "$p_branch" ]]  && echo -e "  ${BOLD}Branch:${RESET}    $p_branch"
    [[ -n "$p_issue" ]]   && echo -e "  ${BOLD}Issue:${RESET}     $p_issue"
    [[ -n "$p_pr" ]]      && echo -e "  ${BOLD}PR:${RESET}        #$p_pr"
    [[ -n "$p_stage" ]]   && echo -e "  ${BOLD}Stage:${RESET}     $p_stage"
    [[ -n "$p_started" ]] && echo -e "  ${BOLD}Started:${RESET}   $p_started"
    [[ -n "$p_elapsed" ]] && echo -e "  ${BOLD}Elapsed:${RESET}   $p_elapsed"

    echo ""
    echo -e "  ${BOLD}Stages:${RESET}"

    local in_stages=false
    while IFS= read -r line; do
        if [[ "$line" == "stages:" ]]; then
            in_stages=true; continue
        fi
        if $in_stages; then
            if [[ "$line" == "---" || ! "$line" =~ ^" " ]]; then break; fi
            local trimmed
            trimmed="$(_trim "$line")"
            if [[ "$trimmed" == *":"* ]]; then
                local sid="${trimmed%%:*}"
                local sst="${trimmed#*: }"
                local s_icon
                case "$sst" in
                    complete) s_icon="${GREEN}✓${RESET}" ;;
                    running)  s_icon="${CYAN}●${RESET}" ;;
                    failed)   s_icon="${RED}✗${RESET}" ;;
                    *)        s_icon="${DIM}○${RESET}" ;;
                esac
                echo -e "    $s_icon $sid"
            fi
        fi
    done < "$STATE_FILE"

    if [[ -d "$ARTIFACTS_DIR" ]]; then
        local artifact_count
        artifact_count=$(_trim "$(find "$ARTIFACTS_DIR" -type f 2>/dev/null | wc -l)")
        if [[ "$artifact_count" -gt 0 ]]; then
            echo ""
            echo -e "  ${BOLD}Artifacts:${RESET} ($artifact_count files)"
            ls "$ARTIFACTS_DIR" 2>/dev/null | sed 's/^/    /'
        fi
    fi
    echo ""
}

pipeline_abort() {
    setup_dirs

    if [[ ! -f "$STATE_FILE" ]]; then
        info "No active pipeline to abort."
        return
    fi

    local current_status
    current_status=$(sed -n 's/^status: *//p' "$STATE_FILE" | head -1)

    if [[ "$current_status" == "complete" || "$current_status" == "aborted" ]]; then
        info "Pipeline already $current_status."
        return
    fi

    resume_state 2>/dev/null || true
    PIPELINE_STATUS="aborted"
    write_state

    # Clear stale per-run task and loop state so a subsequent pipeline does not
    # inherit context from the aborted run. These files are bookkeeping/runtime
    # state (see _GIT_BOOKKEEPING_FILES / _GIT_RUNTIME_EXCLUDES in helpers.sh)
    # and are normally cleared by initialize_state at the next run; clearing
    # them on abort makes status reporting (`shipwright status`, etc.) accurate
    # immediately and prevents stale tasks leaking into a different goal/issue.
    pipeline_clear_stale_run_state
    pipeline_cancel_check_runs 2>/dev/null || true

    # Update GitHub
    if [[ -n "$ISSUE_NUMBER" ]]; then
        gh_init
        gh_remove_label "$ISSUE_NUMBER" "pipeline/in-progress"
        gh_comment_issue "$ISSUE_NUMBER" "⏹️ **Pipeline aborted** at stage: ${CURRENT_STAGE:-unknown}"
    fi

    warn "Pipeline aborted."
    echo -e "  State saved at: ${DIM}$STATE_FILE${RESET}"
}

# Clear transient task/loop state left behind by a running pipeline.
# Removes:
#   - $TASKS_FILE (current run's pipeline-tasks*.md)
#   - any other pipeline-tasks*.md siblings in STATE_DIR (issue-suffixed runs)
#   - .claude/tasks.md (Claude Code task checklist generated by plan stage)
#   - .claude/loop-state.md (build-loop iteration state)
# Safe to call when files are missing — each removal is best-effort.
pipeline_clear_stale_run_state() {
    [[ -z "${STATE_DIR:-}" ]] && return 0
    local _f
    [[ -n "${TASKS_FILE:-}" && -f "$TASKS_FILE" ]] && rm -f "$TASKS_FILE"
    for _f in "$STATE_DIR"/pipeline-tasks*.md; do
        [[ -f "$_f" ]] && rm -f "$_f"
    done
    [[ -f "$STATE_DIR/tasks.md" ]] && rm -f "$STATE_DIR/tasks.md"
    [[ -f "$STATE_DIR/loop-state.md" ]] && rm -f "$STATE_DIR/loop-state.md"
    return 0
}

pipeline_list() {
    local locations=(
        "$REPO_DIR/templates/pipelines"
        "$HOME/.shipwright/pipelines"
    )

    echo ""
    echo -e "${PURPLE}${BOLD}━━━ Pipeline Templates ━━━${RESET}"
    echo ""

    local found=false
    for dir in "${locations[@]}"; do
        if [[ -d "$dir" ]]; then
            for f in "$dir"/*.json; do
                [[ -f "$f" ]] || continue
                found=true
                local name desc stages_enabled gate_count
                name=$(jq -r '.name' "$f" 2>/dev/null)
                desc=$(jq -r '.description' "$f" 2>/dev/null)
                stages_enabled=$(jq -r '[.stages[] | select(.enabled == true) | .id] | join(" → ")' "$f" 2>/dev/null)
                gate_count=$(jq '[.stages[] | select(.gate == "approve" and .enabled == true)] | length' "$f" 2>/dev/null)
                echo -e "  ${CYAN}${BOLD}$name${RESET}"
                echo -e "    $desc"
                echo -e "    ${DIM}$stages_enabled${RESET}"
                echo -e "    ${DIM}(${gate_count} approval gates)${RESET}"
                echo ""
            done
        fi
    done

    if [[ "$found" != "true" ]]; then
        warn "No pipeline templates found."
        echo -e "  Expected at: ${DIM}templates/pipelines/*.json${RESET}"
    fi
}

pipeline_show() {
    local name="${PIPELINE_NAME_ARG:-$PIPELINE_NAME}"

    local config_file
    config_file=$(find_pipeline_config "$name") || {
        error "Pipeline template not found: $name"
        echo -e "  Available: ${DIM}shipwright pipeline list${RESET}"
        exit 1
    }

    echo ""
    echo -e "${PURPLE}${BOLD}━━━ Pipeline: $(jq -r '.name' "$config_file") ━━━${RESET}"
    echo -e "  $(jq -r '.description' "$config_file")"
    echo ""

    echo -e "${BOLD}  Defaults:${RESET}"
    jq -r '.defaults | to_entries[] | "    \(.key): \(.value)"' "$config_file" 2>/dev/null
    echo ""

    echo -e "${BOLD}  Stages:${RESET}"
    jq -r '.stages[] |
        (if .enabled then "    ✓" else "    ○" end) +
        " \(.id)" +
        (if .gate == "approve" then "  [gate: approve]" elif .gate == "skip" then "  [skip]" else "" end)
    ' "$config_file" 2>/dev/null
    echo ""

    echo -e "${BOLD}  GitHub Integration:${RESET}"
    echo -e "    • Issue: self-assign, label lifecycle, progress comments"
    echo -e "    • PR: labels, milestone, reviewers auto-propagated"
    echo -e "    • Validation: auto-close issue on completion"
    echo ""
}

# ─── Drift Report ───────────────────────────────────────────────────────────

pipeline_drift_report() {
    local events_file="${EVENTS_FILE:-${HOME}/.shipwright/events.jsonl}"
    if [[ ! -f "$events_file" ]]; then
        warn "No events log found at $events_file — run a pipeline first."
        return 0
    fi

    echo ""
    echo -e "${PURPLE}${BOLD}━━━ Scope Drift Report ━━━${RESET}"
    echo ""

    # Scope manifest adoption
    local missing_count loaded_count
    missing_count=$(grep -c '"pipeline.scope_manifest_missing"' "$events_file" 2>/dev/null || true)
    missing_count=${missing_count:-0}
    loaded_count=$(grep -c '"pipeline.scope_manifest_loaded"' "$events_file" 2>/dev/null || true)
    loaded_count=${loaded_count:-0}
    echo -e "${BOLD}  Scope fence adoption:${RESET}"
    echo -e "    Stages with fence:    ${GREEN}${loaded_count}${RESET}"
    echo -e "    Stages without fence: ${YELLOW}${missing_count}${RESET}"
    echo ""

    # Path redactions
    local redacted_count
    redacted_count=$(grep -c '"pipeline.prompt_path_redacted"' "$events_file" 2>/dev/null || true)
    redacted_count=${redacted_count:-0}
    echo -e "${BOLD}  Out-of-scope path redactions:${RESET}"
    echo -e "    Total redacted: ${redacted_count}"
    if [[ "$redacted_count" -gt 0 ]] && command -v jq >/dev/null 2>&1; then
        echo -e "    By seam:"
        grep '"pipeline.prompt_path_redacted"' "$events_file" 2>/dev/null \
            | jq -r '.prompt_section // .seam // "unknown"' 2>/dev/null \
            | sort | uniq -c | sort -rn \
            | awk '{count=$1; $1=""; sub(/^ /,""); printf "      %-40s %s\n", $0, count}' || true
    fi
    echo ""

    # Staging violations (pre-existing)
    local violation_count
    violation_count=$(grep -c '"loop.scope_violation"' "$events_file" 2>/dev/null || true)
    violation_count=${violation_count:-0}
    echo -e "${BOLD}  Staging violations (loop.scope_violation):${RESET}"
    echo -e "    Total: ${violation_count}"
    echo ""

    # Scope escalations
    local escalation_count
    escalation_count=$(grep -c '"pipeline.scope_escalation"' "$events_file" 2>/dev/null || true)
    escalation_count=${escalation_count:-0}
    echo -e "${BOLD}  Scope escalations (agent requested scope expansion):${RESET}"
    echo -e "    Total: ${escalation_count}"
    if [[ "$escalation_count" -gt 0 ]] && command -v jq >/dev/null 2>&1; then
        echo -e "    Reasons:"
        grep '"pipeline.scope_escalation"' "$events_file" 2>/dev/null \
            | jq -r '.reason // "unspecified"' 2>/dev/null \
            | sort | uniq -c | sort -rn \
            | awk '{count=$1; $1=""; sub(/^ /,""); printf "      %-60s %s\n", $0, count}' || true
    fi
    echo ""
}

# ─── Main ───────────────────────────────────────────────────────────────────

case "$SUBCOMMAND" in
    start)          pipeline_start ;;
    resume)         pipeline_resume ;;
    status)         pipeline_status ;;
    abort)          pipeline_abort ;;
    list)           pipeline_list ;;
    show)           pipeline_show ;;
    drift)          pipeline_drift_report ;;
    test)
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        exec "$SCRIPT_DIR/sw-pipeline-test.sh" "$@"
        ;;
    help|--help|-h) show_help ;;
    *)
        error "Unknown pipeline command: $SUBCOMMAND"
        echo ""
        show_help
        exit 1
        ;;
esac
