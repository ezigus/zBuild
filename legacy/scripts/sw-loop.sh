#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright loop — Continuous agent loop harness for Claude Code               ║
# ║                                                                         ║
# ║  Runs Claude Code in a headless loop until a goal is achieved.          ║
# ║  Supports single-agent and multi-agent (parallel worktree) modes.       ║
# ║                                                                         ║
# ║  Inspired by Anthropic's autonomous 16-agent C compiler build.          ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

# Allow spawning Claude CLI from within a Claude Code session (daemon, fleet, etc.)
unset CLAUDECODE 2>/dev/null || true
# Ignore SIGHUP so tmux attach/detach doesn't kill long-running agent sessions
trap '' HUP
trap '' SIGPIPE
# Prevent git from blocking on HTTPS credential prompts during headless runs
export GIT_TERMINAL_PROMPT=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"
# Canonical helpers (colors, output, events)
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
[[ -f "$SCRIPT_DIR/lib/config.sh" ]] && source "$SCRIPT_DIR/lib/config.sh"
# Source DB for dual-write (emit_event → JSONL + SQLite).
# Note: do NOT call init_schema here — the pipeline (sw-pipeline.sh) owns schema
# initialization. Calling it here would create an empty DB that shadows JSON cost data.
if [[ -f "$SCRIPT_DIR/sw-db.sh" ]]; then
    source "$SCRIPT_DIR/sw-db.sh" 2>/dev/null || true
fi
# Cross-pipeline discovery (learnings from other pipeline runs)
[[ -f "$SCRIPT_DIR/sw-discovery.sh" ]] && source "$SCRIPT_DIR/sw-discovery.sh" 2>/dev/null || true
# Source loop sub-modules for modular iteration management
[[ -f "$SCRIPT_DIR/lib/loop-iteration.sh" ]] && source "$SCRIPT_DIR/lib/loop-iteration.sh"
[[ -f "$SCRIPT_DIR/lib/loop-convergence.sh" ]] && source "$SCRIPT_DIR/lib/loop-convergence.sh"
# Goal sanitization (Layer B): unified _strip_synthesized_sections helper.
# Sourced directly so standalone `sw loop` invocations also have it available,
# not just paths that transitively pull it via loop-restart.sh / pipeline-state.sh
# (#448 review feedback).
# shellcheck source=lib/goal-sanitize.sh
[[ -f "$SCRIPT_DIR/lib/goal-sanitize.sh" ]] && source "$SCRIPT_DIR/lib/goal-sanitize.sh"
[[ -f "$SCRIPT_DIR/lib/loop-restart.sh" ]] && source "$SCRIPT_DIR/lib/loop-restart.sh"
[[ -f "$SCRIPT_DIR/lib/loop-progress.sh" ]] && source "$SCRIPT_DIR/lib/loop-progress.sh"
# Per-iteration cost recording (issue #87) — record_iteration_cost reads $ITER_COST_JSONL
# which is exported by the pipeline before invoking `sw loop`.
[[ -f "$SCRIPT_DIR/lib/cost/iteration.sh" ]] && source "$SCRIPT_DIR/lib/cost/iteration.sh"
# RuFlo adapter — compatibility layer for ruflo health checks and timeout recovery
[[ -f "$SCRIPT_DIR/lib/ruflo-adapter.sh" ]] && source "$SCRIPT_DIR/lib/ruflo-adapter.sh" 2>/dev/null || true
# Context exhaustion prevention — proactive summarization before Claude hits context limits
[[ -f "$SCRIPT_DIR/lib/loop-context-monitor.sh" ]] && source "$SCRIPT_DIR/lib/loop-context-monitor.sh"
# Error actionability scoring and enhancement for better error context
# shellcheck source=lib/error-actionability.sh
[[ -f "$SCRIPT_DIR/lib/error-actionability.sh" ]] && source "$SCRIPT_DIR/lib/error-actionability.sh" 2>/dev/null || true
# Audit trail for compliance-grade pipeline traceability
# shellcheck source=lib/audit-trail.sh
[[ -f "$SCRIPT_DIR/lib/audit-trail.sh" ]] && source "$SCRIPT_DIR/lib/audit-trail.sh" 2>/dev/null || true
# GitHub helpers (gh_comment_issue, gh_update_progress) for SW_LOG_PROMPTS=github|both
[[ -f "$SCRIPT_DIR/lib/pipeline-github.sh" ]] && source "$SCRIPT_DIR/lib/pipeline-github.sh" 2>/dev/null || true
# Initialize GitHub integration so GH_AVAILABLE is set for SW_LOG_PROMPTS=github|both
type gh_init >/dev/null 2>&1 && gh_init 2>/dev/null || true
# Scope-label state hydration (PR C) — source lib if present, then hydrate state
[[ -f "${SCRIPT_DIR}/lib/scope-label.sh" ]] && source "${SCRIPT_DIR}/lib/scope-label.sh"
type _read_scope_state >/dev/null 2>&1 && _read_scope_state
# Fallbacks when helpers not loaded (e.g. test env with overridden SCRIPT_DIR)
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
  now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
  now_epoch() { date +%s; }
fi
if [[ "$(type -t emit_event 2>/dev/null)" != "function" ]]; then
  emit_event() {
    local event_type="$1"; shift; mkdir -p "${HOME}/.shipwright"
    # shellcheck disable=SC2155
    local payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do local key="${1%%=*}" val="${1#*=}"; payload="${payload},\"${key}\":\"${val}\""; shift; done
    echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
  }
fi

# ─── Defaults ─────────────────────────────────────────────────────────────────
GOAL=""
ORIGINAL_GOAL=""  # Preserved across restarts — GOAL gets appended to
MAX_ITERATIONS="${SW_MAX_ITERATIONS:-20}"
TEST_CMD=""
FAST_TEST_CMD=""
FAST_TEST_INTERVAL=5
TEST_LOG_FILE=""
MODEL="${SW_MODEL:-opus}"
AGENTS=1
AGENT_ROLES=""
USE_WORKTREE=false
SKIP_PERMISSIONS=false
MAX_TURNS=""
RESUME=false
VERBOSE=false
MAX_ITERATIONS_EXPLICIT=false
MAX_RESTARTS=$(_config_get_int "loop.max_restarts" 0 2>/dev/null || echo 0)
DOD_DIFF_MAX_LINES=$(_config_get_int "loop.dod_diff_max_lines" 5000 2>/dev/null || echo 5000)
HOLISTIC_DIFF_MAX_LINES=$(_config_get_int "loop.holistic_diff_max_lines" 1000 2>/dev/null || echo 1000)
LOOP_INNER_STAGE_COMMENTS="${LOOP_INNER_STAGE_COMMENTS:-$(_config_get "loop.inner_stage_comments" "off" 2>/dev/null || echo "off")}"
SESSION_RESTART=false
RESTART_COUNT=0
REPO_OVERRIDE=""
VERSION="3.6.1"

LOOP_ABORT_FATAL=false   # Set true by DoD when a tooling failure makes retry futile

# ─── Token Tracking ─────────────────────────────────────────────────────────
LOOP_INPUT_TOKENS=0
LOOP_OUTPUT_TOKENS=0
LOOP_COST_MILLICENTS=0

reset_token_counters() {
    LOOP_INPUT_TOKENS=0
    LOOP_OUTPUT_TOKENS=0
    LOOP_COST_MILLICENTS=0
}

# ─── Flexible Iteration Defaults ────────────────────────────────────────────
AUTO_EXTEND=true          # Auto-extend iterations when work is incomplete
EXTENSION_SIZE=3          # Additional iterations per extension
MAX_EXTENSIONS=1          # Max number of extensions (hard cap safety net) — 1×3 = 23 per-cycle ceiling
EXTENSION_COUNT=0         # Current number of extensions applied

# ─── Circuit Breaker Defaults ──────────────────────────────────────────────
CIRCUIT_BREAKER_THRESHOLD=3       # Consecutive low-progress iterations before stopping
MIN_PROGRESS_LINES=5              # Minimum insertions to count as progress

# ─── Audit & Quality Gate Defaults ───────────────────────────────────────────
AUDIT_ENABLED=false
AUDIT_AGENT_ENABLED=false
DOD_FILE=""
QUALITY_GATES_ENABLED=false
AUDIT_RESULT=""
HOLISTIC_RESULT=""
QUALITY_GATE_DETAIL=""
QUALITY_GATE_REASONS=""
COMPLETION_REJECTED=false
QUALITY_GATE_PASSED=true
GATE_FINDINGS=""
GATE_PASSED_NAMES=""
PREV_NEW_COMMITS=0          # Commit count from previous iteration (for zero-progress detection)

# ─── Multi-Test Defaults ──────────────────────────────────────────────────
ADDITIONAL_TEST_CMDS=()   # Array of extra test commands (from --additional-test-cmds)

# ─── Context Budget ──────────────────────────────────────────────────────────
CONTEXT_BUDGET_CHARS="${CONTEXT_BUDGET_CHARS:-200000}"  # Max prompt chars before trimming

# ─── Pipeline Context File (Layer A sidecar) ──────────────────────────────────
LOOP_CONTEXT_FILE="${LOOP_CONTEXT_FILE:-}"  # Sidecar with synthesized build context

# ─── Parse Arguments ──────────────────────────────────────────────────────────
show_help() {
    echo -e "${CYAN}${BOLD}shipwright${RESET} ${DIM}v${VERSION}${RESET} — ${BOLD}Continuous Loop${RESET}"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  ${CYAN}shipwright loop${RESET} \"<goal>\" [options]"
    echo ""
    echo -e "${BOLD}OPTIONS${RESET}"
    echo -e "  ${CYAN}--repo <path>${RESET}             Change to directory before running (must be a git repo)"
    echo -e "  ${CYAN}--local${RESET}                   Disable GitHub operations (local-only mode)"
    echo -e "  ${CYAN}--max-iterations${RESET} N       Max loop iterations (default: 20)"
    echo -e "  ${CYAN}--test-cmd${RESET} \"cmd\"         Test command to run between iterations"
    echo -e "  ${CYAN}--fast-test-cmd${RESET} \"cmd\"      Fast/subset test command (alternates with full)"
    echo -e "  ${CYAN}--fast-test-interval${RESET} N       Run full tests every N iterations (default: 5)"
    echo -e "  ${CYAN}--additional-test-cmds${RESET} \"cmd\" Extra test command (repeatable)"
    echo -e "  ${CYAN}--model${RESET} MODEL             Claude model to use (default: opus)"
    echo -e "  ${CYAN}--agents${RESET} N                Number of parallel agents (default: 1)"
    echo -e "  ${CYAN}--roles${RESET} \"r1,r2,...\"        Role per agent: builder,reviewer,tester,optimizer,docs,security"
    echo -e "  ${CYAN}--worktree${RESET}                Use git worktrees for isolation (auto if agents > 1)"
    echo -e "  ${CYAN}--skip-permissions${RESET}        Pass --dangerously-skip-permissions to Claude"
    echo -e "  ${CYAN}--max-turns${RESET} N             Max API turns per Claude session"
    echo -e "  ${CYAN}--resume${RESET}                  Resume from existing .claude/loop-state.md"
    echo -e "  ${CYAN}--max-restarts${RESET} N          Max session restarts on exhaustion (default: 0)"
    echo -e "  ${CYAN}--verbose${RESET}                 Show full Claude output (default: summary)"
    echo -e "  ${CYAN}--help${RESET}                    Show this help"
    echo ""
    echo -e "${BOLD}AUDIT & QUALITY${RESET}"
    echo -e "  ${CYAN}--audit${RESET}                   Inject self-audit checklist into agent prompt"
    echo -e "  ${CYAN}--audit-agent${RESET}             Run separate auditor agent (haiku) after each iteration"
    echo -e "  ${CYAN}--quality-gates${RESET}           Enable automated quality gates before accepting completion"
    echo -e "  ${CYAN}--definition-of-done${RESET} FILE DoD checklist file — evaluated by AI against git diff"
    echo -e "  ${CYAN}--dod-diff-max-lines${RESET} N    Max diff lines for DoD evaluator (default: 5000)"
    echo -e "  ${CYAN}--holistic-diff-max-lines${RESET} N Max diff lines for holistic gate (default: 1000)"
    echo -e "  ${CYAN}--no-auto-extend${RESET}          Disable auto-extension when max iterations reached"
    echo -e "  ${CYAN}--extension-size${RESET} N         Additional iterations per extension (default: 5)"
    echo -e "  ${CYAN}--max-extensions${RESET} N         Max number of auto-extensions (default: 3)"
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo -e "  ${DIM}shipwright loop \"Build user auth with JWT\"${RESET}"
    echo -e "  ${DIM}shipwright loop \"Add payment processing\" --test-cmd \"npm test\" --max-iterations 30${RESET}"
    echo -e "  ${DIM}shipwright loop \"Refactor the database layer\" --agents 3 --model sonnet${RESET}"
    echo -e "  ${DIM}shipwright loop \"Fix all lint errors\" --skip-permissions --verbose${RESET}"
    echo -e "  ${DIM}shipwright loop \"Add auth\" --audit --audit-agent --quality-gates${RESET}"
    echo -e "  ${DIM}shipwright loop \"Ship feature\" --quality-gates --definition-of-done dod.md${RESET}"
    echo ""
    echo -e "${BOLD}COMPLETION & CIRCUIT BREAKER${RESET}"
    echo -e "  The loop completes when:"
    echo -e "  ${DIM}• Claude outputs <<<LOOP:PASS>>> and all quality gates pass${RESET}"
    echo -e "  ${DIM}• Max iterations reached (auto-extends if work is incomplete)${RESET}"
    echo -e "  The loop stops (circuit breaker) if:"
    echo -e "  ${DIM}• ${CIRCUIT_BREAKER_THRESHOLD} consecutive iterations with < ${MIN_PROGRESS_LINES} lines changed${RESET}"
    echo -e "  ${DIM}• Hard cap reached (max_iterations + max_extensions * extension_size)${RESET}"
    echo -e "  ${DIM}• Ctrl-C (graceful shutdown with summary)${RESET}"
    echo ""
    echo -e "${BOLD}STATE & LOGS${RESET}"
    echo -e "  ${DIM}State file:  .claude/loop-state.md${RESET}"
    echo -e "  ${DIM}Logs dir:    .claude/loop-logs/${RESET}"
    echo -e "  ${DIM}Resume:      shipwright loop --resume${RESET}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)
            REPO_OVERRIDE="${2:-}"
            [[ -z "$REPO_OVERRIDE" ]] && { error "Missing value for --repo"; exit 1; }
            shift 2
            ;;
        --repo=*) REPO_OVERRIDE="${1#--repo=}"; shift ;;
        --local)
            # Skip GitHub operations in loop
            export NO_GITHUB=true
            shift ;;
        --max-iterations)
            MAX_ITERATIONS="${2:-}"
            MAX_ITERATIONS_EXPLICIT=true
            [[ -z "$MAX_ITERATIONS" ]] && { error "Missing value for --max-iterations"; exit 1; }
            shift 2
            ;;
        --max-iterations=*) MAX_ITERATIONS="${1#--max-iterations=}"; MAX_ITERATIONS_EXPLICIT=true; shift ;;
        --test-cmd)
            TEST_CMD="${2:-}"
            [[ -z "$TEST_CMD" ]] && { error "Missing value for --test-cmd"; exit 1; }
            shift 2
            ;;
        --test-cmd=*) TEST_CMD="${1#--test-cmd=}"; shift ;;
        --model)
            MODEL="${2:-}"
            [[ -z "$MODEL" ]] && { error "Missing value for --model"; exit 1; }
            shift 2
            ;;
        --model=*) MODEL="${1#--model=}"; shift ;;
        --agents)
            AGENTS="${2:-}"
            [[ -z "$AGENTS" ]] && { error "Missing value for --agents"; exit 1; }
            shift 2
            ;;
        --agents=*) AGENTS="${1#--agents=}"; shift ;;
        --worktree) USE_WORKTREE=true; shift ;;
        --skip-permissions) SKIP_PERMISSIONS=true; shift ;;
        --max-turns)
            MAX_TURNS="${2:-}"
            [[ -z "$MAX_TURNS" ]] && { error "Missing value for --max-turns"; exit 1; }
            shift 2
            ;;
        --max-turns=*) MAX_TURNS="${1#--max-turns=}"; shift ;;
        --resume) RESUME=true; shift ;;
        --verbose) VERBOSE=true; shift ;;
        --audit) AUDIT_ENABLED=true; shift ;;
        --audit-agent) AUDIT_AGENT_ENABLED=true; shift ;;
        --definition-of-done)
            DOD_FILE="${2:-}"
            [[ -z "$DOD_FILE" ]] && { error "Missing value for --definition-of-done"; exit 1; }
            shift 2
            ;;
        --definition-of-done=*) DOD_FILE="${1#--definition-of-done=}"; shift ;;
        --dod-diff-max-lines)
            DOD_DIFF_MAX_LINES="${2:-}"
            [[ -z "$DOD_DIFF_MAX_LINES" ]] && { error "Missing value for --dod-diff-max-lines"; exit 1; }
            shift 2
            ;;
        --dod-diff-max-lines=*) DOD_DIFF_MAX_LINES="${1#--dod-diff-max-lines=}"; shift ;;
        --holistic-diff-max-lines)
            HOLISTIC_DIFF_MAX_LINES="${2:-}"
            [[ -z "$HOLISTIC_DIFF_MAX_LINES" ]] && { error "Missing value for --holistic-diff-max-lines"; exit 1; }
            shift 2
            ;;
        --holistic-diff-max-lines=*) HOLISTIC_DIFF_MAX_LINES="${1#--holistic-diff-max-lines=}"; shift ;;
        --quality-gates) QUALITY_GATES_ENABLED=true; shift ;;
        --no-auto-extend) AUTO_EXTEND=false; shift ;;
        --extension-size)
            EXTENSION_SIZE="${2:-}"
            [[ -z "$EXTENSION_SIZE" ]] && { error "Missing value for --extension-size"; exit 1; }
            shift 2
            ;;
        --extension-size=*) EXTENSION_SIZE="${1#--extension-size=}"; shift ;;
        --max-extensions)
            MAX_EXTENSIONS="${2:-}"
            [[ -z "$MAX_EXTENSIONS" ]] && { error "Missing value for --max-extensions"; exit 1; }
            shift 2
            ;;
        --max-extensions=*) MAX_EXTENSIONS="${1#--max-extensions=}"; shift ;;
        --fast-test-cmd)
            FAST_TEST_CMD="${2:-}"
            [[ -z "$FAST_TEST_CMD" ]] && { error "Missing value for --fast-test-cmd"; exit 1; }
            shift 2
            ;;
        --fast-test-cmd=*) FAST_TEST_CMD="${1#--fast-test-cmd=}"; shift ;;
        --fast-test-interval)
            FAST_TEST_INTERVAL="${2:-}"
            [[ -z "$FAST_TEST_INTERVAL" ]] && { error "Missing value for --fast-test-interval"; exit 1; }
            shift 2
            ;;
        --fast-test-interval=*) FAST_TEST_INTERVAL="${1#--fast-test-interval=}"; shift ;;
        --additional-test-cmds)
            ADDITIONAL_TEST_CMDS+=("${2:-}")
            [[ -z "${2:-}" ]] && { error "Missing value for --additional-test-cmds"; exit 1; }
            shift 2
            ;;
        --additional-test-cmds=*) ADDITIONAL_TEST_CMDS+=("${1#--additional-test-cmds=}"); shift ;;
        --max-restarts)
            MAX_RESTARTS="${2:-}"
            [[ -z "$MAX_RESTARTS" ]] && { error "Missing value for --max-restarts"; exit 1; }
            shift 2
            ;;
        --max-restarts=*) MAX_RESTARTS="${1#--max-restarts=}"; shift ;;
        --roles)
            AGENT_ROLES="${2:-}"
            [[ -z "$AGENT_ROLES" ]] && { error "Missing value for --roles"; exit 1; }
            shift 2
            ;;
        --roles=*) AGENT_ROLES="${1#--roles=}"; shift ;;
        --context-file)
            LOOP_CONTEXT_FILE="${2:-}"
            [[ -z "$LOOP_CONTEXT_FILE" ]] && { error "Missing value for --context-file"; exit 1; }
            shift 2
            ;;
        --context-file=*) LOOP_CONTEXT_FILE="${1#--context-file=}"; shift ;;
        --help|-h)
            show_help
            exit 0
            ;;
        -*)
            error "Unknown option: $1"
            echo ""
            show_help
            exit 1
            ;;
        *)
            # Positional: goal
            if [[ -z "$GOAL" ]]; then
                GOAL="$1"
            else
                error "Unexpected argument: $1"
                exit 1
            fi
            shift
            ;;
    esac
done

# Auto-enable worktree for multi-agent
if [[ "$AGENTS" -gt 1 ]]; then
    # shellcheck disable=SC2034
    USE_WORKTREE=true
fi

# Recruit-powered auto-role assignment when multi-agent but no roles specified
if [[ "$AGENTS" -gt 1 ]] && [[ -z "$AGENT_ROLES" ]] && [[ -x "${SCRIPT_DIR:-}/sw-recruit.sh" ]]; then
    _recruit_goal="${GOAL:-}"
    if [[ -n "$_recruit_goal" ]]; then
        _recruit_team=$(bash "$SCRIPT_DIR/sw-recruit.sh" team --json "$_recruit_goal" 2>/dev/null) || true
        if [[ -n "$_recruit_team" ]]; then
            _recruit_roles=$(echo "$_recruit_team" | jq -r '.team | join(",")' 2>/dev/null) || true
            if [[ -n "$_recruit_roles" && "$_recruit_roles" != "null" ]]; then
                AGENT_ROLES="$_recruit_roles"
                info "Recruit assigned roles: ${AGENT_ROLES}"
            fi
        fi
    fi
fi

# Warn if --roles without --agents
if [[ -n "$AGENT_ROLES" ]] && [[ "$AGENTS" -le 1 ]]; then
    warn "--roles requires --agents > 1 (roles are ignored in single-agent mode)"
fi

# max-restarts is supported in both single-agent and multi-agent mode
# In multi-agent mode, restarts apply per-agent (agent can be respawned up to MAX_RESTARTS)

# Validate numeric flags
if ! [[ "$FAST_TEST_INTERVAL" =~ ^[1-9][0-9]*$ ]]; then
    error "--fast-test-interval must be a positive integer (got: $FAST_TEST_INTERVAL)"
    exit 1
fi
if ! [[ "$MAX_RESTARTS" =~ ^[0-9]+$ ]]; then
    error "--max-restarts must be a non-negative integer (got: $MAX_RESTARTS)"
    exit 1
fi
if ! [[ "$DOD_DIFF_MAX_LINES" =~ ^[1-9][0-9]*$ ]]; then
    error "--dod-diff-max-lines must be a positive integer (got: $DOD_DIFF_MAX_LINES)"
    exit 1
fi
if ! [[ "$HOLISTIC_DIFF_MAX_LINES" =~ ^[1-9][0-9]*$ ]]; then
    error "--holistic-diff-max-lines must be a positive integer (got: $HOLISTIC_DIFF_MAX_LINES)"
    exit 1
fi

# ─── Validate Inputs ─────────────────────────────────────────────────────────

if ! $RESUME && [[ -z "$GOAL" ]]; then
    error "Missing goal. Usage: shipwright loop \"<goal>\" [options]"
    echo ""
    echo -e "  ${DIM}shipwright loop \"Build user auth with JWT\"${RESET}"
    echo -e "  ${DIM}shipwright loop --resume${RESET}"
    exit 1
fi

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
    info "Using repository: $(pwd)"
fi

if ! command -v claude >/dev/null 2>&1; then
    error "Claude Code CLI not found. Install it first:"
    echo -e "  ${DIM}npm install -g @anthropic-ai/claude-code${RESET}"
    exit 1
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    error "Not inside a git repository. The loop requires git for progress tracking."
    exit 1
fi

# Validate --context-file path (if provided by pipeline).
# Resolves symlinks AND `..` so an attacker can't bypass the prefix check with a
# crafted path like `/workspace/shipwright/../sensitive.md` or a symlink that
# resolves outside PROJECT_ROOT (#448 review feedback).
#
# Bash 3.2 / macOS portable: `readlink -f` is GNU-only, so we walk the symlink
# chain manually with a bounded loop, then `cd ... && pwd -P` the parent dir to
# strip any remaining `..` segments and per-component symlinks.
if [[ -n "$LOOP_CONTEXT_FILE" ]]; then
    PROJECT_ROOT="$(git rev-parse --show-toplevel)"
    # Canonicalize PROJECT_ROOT (handles macOS /var → /private/var).
    _real_project_root="$(cd "$PROJECT_ROOT" && pwd -P)"

    # Walk symlinks at the leaf (max 32 hops; bounded to defeat symlink loops).
    _target="$LOOP_CONTEXT_FILE"
    _hops=0
    while [[ -L "$_target" ]]; do
        if [[ "$_hops" -ge 32 ]]; then
            error "context-file path '$LOOP_CONTEXT_FILE' has too many symlink hops (>32) — possible symlink loop"
            exit 1
        fi
        _link="$(readlink "$_target")"
        case "$_link" in
            /*) _target="$_link" ;;
            *)  _target="$(dirname "$_target")/$_link" ;;
        esac
        _hops=$((_hops + 1))
    done

    # Canonicalize the (possibly resolved) target. The file may not exist yet
    # (pipeline writes it before invoking sw-loop), so resolve the parent
    # directory and append the basename — `cd ... && pwd -P` collapses
    # symlinks AND `..` in the directory portion.
    _ctx_dir="$(dirname "$_target")"
    if [[ ! -d "$_ctx_dir" ]]; then
        error "context-file path '$LOOP_CONTEXT_FILE' (resolved: $_target) parent directory does not exist"
        exit 1
    fi
    _real_ctx_dir="$(cd "$_ctx_dir" && pwd -P)"
    _real_ctx="${_real_ctx_dir}/$(basename "$_target")"

    case "$_real_ctx" in
        "${_real_project_root}/"*) : ;;
        *)
            error "context-file path '$LOOP_CONTEXT_FILE' (resolved: $_real_ctx) must be inside project root '$_real_project_root'"
            exit 1
            ;;
    esac
    unset _real_project_root _target _hops _link _ctx_dir _real_ctx_dir _real_ctx
fi

# If the context file already exists at invocation time, verify it is readable.
# (Path validation above only confirms the path is within project root.)
if [[ -n "${LOOP_CONTEXT_FILE:-}" && -e "${LOOP_CONTEXT_FILE}" && ! -r "${LOOP_CONTEXT_FILE}" ]]; then
    error "context-file '$LOOP_CONTEXT_FILE' exists but is not readable"
    exit 1
fi

# Layer B: Strip synthesized sections from GOAL before preserving as ORIGINAL_GOAL.
# Only applied when --context-file was passed (i.e. invoked by the pipeline build stage),
# so standalone sw-loop invocations with multi-section user goals are never truncated.
#
# Fail hard if goal-sanitize.sh isn't loaded — a stale inline fallback list would
# silently leave new synthesis sections in the goal and pollute the agent prompt
# (#448 review feedback). The helper is sourced unconditionally above (line 46),
# so this only fires if the file was deleted/corrupted.
if [[ -n "$LOOP_CONTEXT_FILE" ]]; then
    if ! declare -f _strip_synthesized_sections >/dev/null 2>&1; then
        error "goal-sanitize.sh failed to load — cannot strip synthesis from goal. Expected: $SCRIPT_DIR/lib/goal-sanitize.sh"
        exit 1
    fi
    GOAL="$(_strip_synthesized_sections "$GOAL")"
fi

# Preserve original goal before any appending (memory fixes, human feedback)
ORIGINAL_GOAL="$GOAL"

# ─── Timeout Detection ────────────────────────────────────────────────────────
TIMEOUT_CMD=""
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_CMD="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_CMD="gtimeout"
fi
CLAUDE_TIMEOUT="${CLAUDE_TIMEOUT:-$(_config_get_int "loop.claude_timeout" 1800 2>/dev/null || echo 1800)}"  # 30 min default

if [[ "$AGENTS" -gt 1 ]]; then
    if ! command -v tmux >/dev/null 2>&1; then
        error "tmux is required for multi-agent mode."
        echo -e "  ${DIM}brew install tmux${RESET}  (macOS)"
        exit 1
    fi
    if [[ -z "${TMUX:-}" ]]; then
        error "Multi-agent mode requires running inside tmux."
        echo -e "  ${DIM}tmux new -s work${RESET}"
        exit 1
    fi
fi

# ─── Directory Setup ─────────────────────────────────────────────────────────

PROJECT_ROOT="$(git rev-parse --show-toplevel)"
STATE_DIR="$PROJECT_ROOT/.claude"
STATE_FILE="$STATE_DIR/loop-state.md"
LOG_DIR="$STATE_DIR/loop-logs"
WORKTREE_DIR="$PROJECT_ROOT/.worktrees"

mkdir -p "$STATE_DIR" "$LOG_DIR"

# ─── Adaptive Model Selection ────────────────────────────────────────────────
# Uses intelligence engine when available, falls back to defaults.
select_adaptive_model() {
    local role="${1:-build}"
    local default_model="${2:-opus}"
    # If user explicitly set --model, respect it
    if [[ "$default_model" != "${SW_MODEL:-opus}" ]]; then
        echo "$default_model"
        return 0
    fi
    # Read learned model routing
    local _routing_file="${HOME}/.shipwright/optimization/model-routing.json"
    if [[ -f "$_routing_file" ]] && command -v jq >/dev/null 2>&1; then
        local _routed_model
        _routed_model=$(jq -r --arg r "$role" '.routes[$r].model // ""' "$_routing_file" 2>/dev/null) || true
        if [[ -n "${_routed_model:-}" && "${_routed_model:-}" != "null" ]]; then
            echo "${_routed_model}"
            return 0
        fi
    fi

    # Try intelligence-based recommendation
    if type intelligence_recommend_model >/dev/null 2>&1; then
        local rec
        rec=$(intelligence_recommend_model "$role" "${COMPLEXITY:-5}" "${BUDGET:-0}" 2>/dev/null || echo "")
        if [[ -n "$rec" ]]; then
            local recommended
            recommended=$(echo "$rec" | jq -r '.model // ""' 2>/dev/null || echo "")
            if [[ -n "$recommended" && "$recommended" != "null" ]]; then
                echo "$recommended"
                return 0
            fi
        fi
    fi
    echo "$default_model"
}

# Select audit/DoD model — uses haiku if success rate is high enough, else sonnet
select_audit_model() {
    local default_model="haiku"
    local opt_file="$HOME/.shipwright/optimization/audit-tuning.json"
    if [[ -f "$opt_file" ]] && command -v jq >/dev/null 2>&1; then
        local success_rate
        success_rate=$(jq -r '.haiku_success_rate // 100' "$opt_file" 2>/dev/null || echo "100")
        if [[ "${success_rate%%.*}" -lt 90 ]]; then
            echo "sonnet"
            return 0
        fi
    fi
    echo "$default_model"
}

# ─── Token Accumulation ─────────────────────────────────────────────────────
# Parse token counts from Claude CLI JSON output and accumulate running totals.
# With --output-format json, the output is a JSON array containing a "result"
# object with usage.input_tokens, usage.output_tokens, and total_cost_usd.
accumulate_loop_tokens() {
    local log_file="$1"
    [[ ! -f "$log_file" ]] && return 0

    # If jq is available and the file looks like JSON, parse structured output
    if command -v jq >/dev/null 2>&1 && head -c1 "$log_file" 2>/dev/null | grep -q '\['; then
        local input_tok output_tok cache_read cache_create cost_usd
        # The result object is the last element in the JSON array
        input_tok=$(jq -r '.[-1].usage.input_tokens // 0' "$log_file" 2>/dev/null || echo "0")
        output_tok=$(jq -r '.[-1].usage.output_tokens // 0' "$log_file" 2>/dev/null || echo "0")
        cache_read=$(jq -r '.[-1].usage.cache_read_input_tokens // 0' "$log_file" 2>/dev/null || echo "0")
        cache_create=$(jq -r '.[-1].usage.cache_creation_input_tokens // 0' "$log_file" 2>/dev/null || echo "0")
        cost_usd=$(jq -r '.[-1].total_cost_usd // 0' "$log_file" 2>/dev/null || echo "0")

        LOOP_INPUT_TOKENS=$(( LOOP_INPUT_TOKENS + ${input_tok:-0} + ${cache_read:-0} + ${cache_create:-0} ))
        LOOP_OUTPUT_TOKENS=$(( LOOP_OUTPUT_TOKENS + ${output_tok:-0} ))
        # Accumulate cost in millicents for integer arithmetic
        if [[ -n "$cost_usd" && "$cost_usd" != "0" && "$cost_usd" != "null" ]]; then
            local cost_millicents
            cost_millicents=$(echo "$cost_usd" | awk '{printf "%.0f", $1 * 100000}' 2>/dev/null || echo "0")
            LOOP_COST_MILLICENTS=$(( ${LOOP_COST_MILLICENTS:-0} + ${cost_millicents:-0} ))
        else
            # Estimate cost from tokens when Claude doesn't provide it (rates per million tokens)
            local total_in total_out
            total_in=$(( ${input_tok:-0} + ${cache_read:-0} + ${cache_create:-0} ))
            total_out=${output_tok:-0}
            local cost=0
            case "${MODEL:-${CLAUDE_MODEL:-sonnet}}" in
                *opus*)   cost=$(awk -v i="$total_in" -v o="$total_out" 'BEGIN{printf "%.6f", (i * 15 + o * 75) / 1000000}') ;;
                *sonnet*) cost=$(awk -v i="$total_in" -v o="$total_out" 'BEGIN{printf "%.6f", (i * 3 + o * 15) / 1000000}') ;;
                *haiku*)  cost=$(awk -v i="$total_in" -v o="$total_out" 'BEGIN{printf "%.6f", (i * 0.25 + o * 1.25) / 1000000}') ;;
                *)       cost=$(awk -v i="$total_in" -v o="$total_out" 'BEGIN{printf "%.6f", (i * 3 + o * 15) / 1000000}') ;;
            esac
            cost_millicents=$(echo "$cost" | awk '{printf "%.0f", $1 * 100000}' 2>/dev/null || echo "0")
            LOOP_COST_MILLICENTS=$(( ${LOOP_COST_MILLICENTS:-0} + ${cost_millicents:-0} ))
        fi
    else
        # Fallback: regex-based parsing for non-JSON output
        local input_tok output_tok
        input_tok=$(grep -oE 'input[_ ]tokens?[: ]+[0-9,]+' "$log_file" 2>/dev/null | tail -1 | grep -oE '[0-9,]+' | tr -d ',' || echo "0")
        output_tok=$(grep -oE 'output[_ ]tokens?[: ]+[0-9,]+' "$log_file" 2>/dev/null | tail -1 | grep -oE '[0-9,]+' | tr -d ',' || echo "0")

        LOOP_INPUT_TOKENS=$(( LOOP_INPUT_TOKENS + ${input_tok:-0} ))
        LOOP_OUTPUT_TOKENS=$(( LOOP_OUTPUT_TOKENS + ${output_tok:-0} ))
    fi
}

# ─── JSON→Text Extraction ──────────────────────────────────────────────────
# Extract plain text from Claude's --output-format json response.
# Handles: valid JSON arrays, malformed JSON, non-JSON output, empty output.
_extract_text_from_json() {
    local json_file="$1" log_file="$2" err_file="${3:-}"

    # Case 1: File doesn't exist or is empty
    if [[ ! -s "$json_file" ]]; then
        # Check stderr for error messages
        if [[ -s "$err_file" ]]; then
            cp "$err_file" "$log_file"
        else
            echo "(no output)" > "$log_file"
        fi
        return 0
    fi

    local first_char
    first_char=$(head -c1 "$json_file" 2>/dev/null || true)

    # Case 2: Valid JSON (array or object) — extract with jq
    if [[ "$first_char" == "[" || "$first_char" == "{" ]] && command -v jq >/dev/null 2>&1; then
        local extracted
        if [[ "$first_char" == "[" ]]; then
            # Array: extract .result from last element
            extracted=$(jq -r '.[-1].result // empty' "$json_file" 2>/dev/null) || true
        else
            # Object: extract .result directly
            extracted=$(jq -r '.result // empty' "$json_file" 2>/dev/null) || true
        fi
        if [[ -n "$extracted" ]]; then
            echo "$extracted" > "$log_file"
            return 0
        fi
        # Try .content as fallback
        if [[ "$first_char" == "[" ]]; then
            extracted=$(jq -r '.[].content // empty' "$json_file" 2>/dev/null | head -500) || true
        else
            extracted=$(jq -r '.content // empty' "$json_file" 2>/dev/null | head -500) || true
        fi
        if [[ -n "$extracted" ]]; then
            echo "$extracted" > "$log_file"
            return 0
        fi
        # JSON parsed but no text found — write placeholder
        warn "JSON output has no .result field — check $json_file"
        echo "(no text result in JSON output)" > "$log_file"
        return 0
    fi

    # Case 3: Looks like JSON but jq not available — can't parse, use raw
    if [[ "$first_char" == "[" || "$first_char" == "{" ]]; then
        warn "JSON output but jq not available — using raw output"
        cp "$json_file" "$log_file"
        return 0
    fi

    # Case 4: Not JSON at all (plain text, error message, etc.) — use as-is
    cp "$json_file" "$log_file"
    return 0
}

# Write accumulated token totals to a JSON file for the pipeline to read.
write_loop_tokens() {
    local token_file="$LOG_DIR/loop-tokens.json"
    local cost_usd="0"
    if [[ "${LOOP_COST_MILLICENTS:-0}" -gt 0 ]]; then
        cost_usd=$(awk "BEGIN {printf \"%.6f\", ${LOOP_COST_MILLICENTS} / 100000}" 2>/dev/null || echo "0")
    fi
    local tmp_file
    tmp_file=$(mktemp "${token_file}.XXXXXX" 2>/dev/null || mktemp)
    # shellcheck disable=SC2064
    trap "rm -f '$tmp_file'" RETURN
    cat > "$tmp_file" <<TOKJSON
{"input_tokens":${LOOP_INPUT_TOKENS},"output_tokens":${LOOP_OUTPUT_TOKENS},"cost_usd":${cost_usd},"iterations":${ITERATION:-0}}
TOKJSON
    mv "$tmp_file" "$token_file"
}

# ─── Adaptive Iteration Budget ──────────────────────────────────────────────
# Reads tuning config for smarter iteration/circuit-breaker thresholds.
apply_adaptive_budget() {
    local tuning_file="$HOME/.shipwright/optimization/loop-tuning.json"
    if [[ -f "$tuning_file" ]] && command -v jq >/dev/null 2>&1; then
        local tuned_max tuned_ext tuned_ext_count tuned_cb
        tuned_max=$(jq -r '.max_iterations // ""' "$tuning_file" 2>/dev/null || echo "")
        tuned_ext=$(jq -r '.extension_size // ""' "$tuning_file" 2>/dev/null || echo "")
        tuned_ext_count=$(jq -r '.max_extensions // ""' "$tuning_file" 2>/dev/null || echo "")
        tuned_cb=$(jq -r '.circuit_breaker_threshold // ""' "$tuning_file" 2>/dev/null || echo "")

        # Only apply tuned values if user didn't explicitly set them
        if ! $MAX_ITERATIONS_EXPLICIT && [[ -n "$tuned_max" && "$tuned_max" != "null" ]]; then
            MAX_ITERATIONS="$tuned_max"
        fi
        [[ -n "$tuned_ext" && "$tuned_ext" != "null" ]] && EXTENSION_SIZE="$tuned_ext"
        [[ -n "$tuned_ext_count" && "$tuned_ext_count" != "null" ]] && MAX_EXTENSIONS="$tuned_ext_count"
        [[ -n "$tuned_cb" && "$tuned_cb" != "null" ]] && CIRCUIT_BREAKER_THRESHOLD="$tuned_cb"
    fi

    # Read learned iteration model
    local _iter_model="${HOME}/.shipwright/optimization/iteration-model.json"
    if [[ -f "$_iter_model" ]] && ! $MAX_ITERATIONS_EXPLICIT && command -v jq >/dev/null 2>&1; then
        local _complexity="${ISSUE_COMPLEXITY:-${COMPLEXITY:-medium}}"
        local _predicted_max
        _predicted_max=$(jq -r --arg c "$_complexity" '.predictions[$c].max_iterations // ""' "$_iter_model" 2>/dev/null) || true
        if [[ -n "${_predicted_max:-}" && "${_predicted_max:-}" != "null" && "${_predicted_max:-0}" -gt 0 ]]; then
            MAX_ITERATIONS="${_predicted_max}"
            info "Iteration model: ${_complexity} complexity → max ${_predicted_max} iterations"
        fi
    fi

    # Try intelligence-based iteration estimate
    if type intelligence_estimate_iterations >/dev/null 2>&1 && ! $MAX_ITERATIONS_EXPLICIT; then
        local est
        est=$(intelligence_estimate_iterations "${GOAL:-}" "${COMPLEXITY:-5}" 2>/dev/null || echo "")
        if [[ -n "$est" && "$est" =~ ^[0-9]+$ ]]; then
            MAX_ITERATIONS="$est"
        fi
    fi
}

# ─── Progress Velocity Tracking ─────────────────────────────────────────────
ITERATION_LINES_CHANGED=""
VELOCITY_HISTORY=""


# Compute average lines/iteration from recent history

# ─── Timing Helpers ───────────────────────────────────────────────────────────

format_duration() {
    local secs="$1"
    local mins=$(( secs / 60 ))
    local remaining_secs=$(( secs % 60 ))
    if [[ $mins -gt 0 ]]; then
        printf "%dm %ds" "$mins" "$remaining_secs"
    else
        printf "%ds" "$remaining_secs"
    fi
}

# ─── State Management ────────────────────────────────────────────────────────

ITERATION=0
CONSECUTIVE_FAILURES=0
TOTAL_COMMITS=0
START_EPOCH=""
STATUS="running"
TEST_PASSED=""
TEST_OUTPUT=""
TEST_EXIT_CODE=0
LOG_ENTRIES=""






# ─── Semantic Validation for Claude Output ─────────────────────────────────────
# Validates changed files before commit to catch syntax errors and API error leakage.
validate_claude_output() {
    local workdir="${1:-.}"
    local issues=0

    # Check for syntax errors in changed files
    local changed_files
    changed_files=$(git -C "$workdir" diff --cached --name-only 2>/dev/null || git -C "$workdir" diff --name-only 2>/dev/null)

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        [[ ! -f "$workdir/$file" ]] && continue

        case "$file" in
            *.sh)
                if ! bash -n "$workdir/$file" 2>/dev/null; then
                    warn "Syntax error in shell script: $file"
                    issues=$((issues + 1))
                fi
                ;;
            *.py)
                if command -v python3 >/dev/null 2>&1; then
                    if ! python3 -c "import ast, sys; ast.parse(open(sys.argv[1]).read())" "$workdir/$file" 2>/dev/null; then
                        warn "Syntax error in Python file: $file"
                        issues=$((issues + 1))
                    fi
                fi
                ;;
            *.json)
                if command -v jq >/dev/null 2>&1 && ! jq empty "$workdir/$file" 2>/dev/null; then
                    warn "Invalid JSON: $file"
                    issues=$((issues + 1))
                fi
                ;;
            *.ts|*.js|*.tsx|*.jsx)
                # Check for obvious corruption: API error text leaked into source
                if grep -qE '(CLAUDE_CODE_OAUTH_TOKEN|api key|rate limit|503 Service|DOCTYPE html)' "$workdir/$file" 2>/dev/null; then
                    warn "Claude API error leaked into source file: $file"
                    issues=$((issues + 1))
                fi
                ;;
        esac
    done <<< "$changed_files"

    # Check for obviously corrupt output (API errors dumped as code)
    local total_changed
    total_changed=$(echo "$changed_files" | grep -c '.' 2>/dev/null || true)
    total_changed="${total_changed:-0}"
    if [[ "$total_changed" -eq 0 ]]; then
        warn "Claude iteration produced no file changes"
        issues=$((issues + 1))
    fi

    return "$issues"
}

# ─── Gate Signal Detection ──────────────────────────────────────────────────
# Sourced from shared lib so ai-provider.sh can use the same function.
[[ -f "${SCRIPT_DIR}/lib/gate-signal.sh" ]] && source "${SCRIPT_DIR}/lib/gate-signal.sh"

# ─── Budget Gate (hard stop when exhausted) ───────────────────────────────────
check_budget_gate() {
    [[ ! -x "$SCRIPT_DIR/sw-cost.sh" ]] && return 0
    local remaining
    remaining=$(bash "$SCRIPT_DIR/sw-cost.sh" remaining-budget 2>/dev/null || echo "")
    [[ -z "$remaining" ]] && return 0
    [[ "$remaining" == "unlimited" ]] && return 0

    # Parse remaining as float, check if <= 0
    if awk -v r="$remaining" 'BEGIN { exit !(r <= 0) }' 2>/dev/null; then
        error "Budget exhausted (remaining: \$${remaining}) — stopping pipeline"
        emit_event "pipeline.budget_exhausted" "remaining=$remaining"
        return 1
    fi

    # Warn at 10% threshold (remaining < 1.0 when typical job ~$5+)
    if awk -v r="$remaining" 'BEGIN { exit !(r < 1.0) }' 2>/dev/null; then
        warn "Budget low: \$${remaining} remaining"
    fi

    return 0
}

# ─── Git Helpers ──────────────────────────────────────────────────────────────

git_commit_count() {
    git -C "$PROJECT_ROOT" rev-list --count HEAD 2>/dev/null || echo 0
}

git_recent_log() {
    git -C "$PROJECT_ROOT" log --oneline -20 2>/dev/null || echo "(no commits)"
}

git_diff_stat() {
    _git_diff_stat_excluded "$PROJECT_ROOT"
}

git_auto_commit() {
    local work_dir="${1:-$PROJECT_ROOT}"
    # Only commit if there are changes
    if git -C "$work_dir" diff --quiet && git -C "$work_dir" diff --cached --quiet; then
        # Check for untracked files
        local untracked
        untracked="$(git -C "$work_dir" ls-files --others --exclude-standard | head -1)"
        if [[ -z "$untracked" ]]; then
            return 1  # Nothing to commit
        fi
    fi

    safe_git_stage "$work_dir"

    # Diagnostic: surface exactly what is staged so push-tracing is possible
    local _staged_stat
    _staged_stat=$(git -C "$work_dir" diff --cached --stat 2>/dev/null || true)
    if [[ -z "$_staged_stat" ]]; then
        warn "git_auto_commit: nothing staged after safe_git_stage — skipping commit"
        return 1
    fi
    info "git_auto_commit staged:"
    echo "$_staged_stat"

    # Semantic validation before commit — skip commit if validation fails
    if ! validate_claude_output "$work_dir"; then
        warn "Validation failed — skipping commit for this iteration"
        git -C "$work_dir" reset HEAD 2>/dev/null || true
        return 1
    fi

    # Descriptive message: include diff summary so commit history is self-documenting
    local _summary
    _summary=$(echo "$_staged_stat" | tail -1 | sed 's/^ *//')
    _summary="${_summary:-autonomous progress}"
    git -C "$work_dir" commit \
        -m "loop: iteration ${ITERATION} — ${_summary}" \
        --no-verify 2>/dev/null || return 1
    return 0
}

# ─── Fatal Error Detection ────────────────────────────────────────────────────


# ─── Progress & Circuit Breaker ───────────────────────────────────────────────





# ─── Failure Diagnosis ─────────────────────────────────────────────────────────
# Pattern-based root-cause classification for smarter retries (no Claude needed).
# Returns markdown context to inject into the next iteration's goal.

diagnose_failure() {
    local error_output="$1"
    local changed_files="$2"
    local iteration="$3"

    local diagnosis=""
    local strategy="retry_with_context"  # default

    # Pattern-based classification (fast, no Claude needed)
    if echo "$error_output" | grep -qiE 'import.*not found|cannot find module|no module named'; then
        diagnosis="missing_import"
        strategy="fix_imports"
    elif echo "$error_output" | grep -qiE 'syntax error|unexpected token|parse error'; then
        diagnosis="syntax_error"
        strategy="fix_syntax"
    elif echo "$error_output" | grep -qiE 'type.*not assignable|type error|TypeError'; then
        diagnosis="type_error"
        strategy="fix_types"
    elif echo "$error_output" | grep -qiE 'undefined.*variable|not defined|ReferenceError'; then
        diagnosis="undefined_reference"
        strategy="fix_references"
    elif echo "$error_output" | grep -qiE 'timeout|timed out|ETIMEDOUT'; then
        diagnosis="timeout"
        strategy="optimize_performance"
    elif echo "$error_output" | grep -qiE 'assertion.*fail|expect.*to|AssertionError'; then
        diagnosis="test_assertion"
        strategy="fix_logic"
    elif echo "$error_output" | grep -qiE 'permission denied|EACCES|forbidden'; then
        diagnosis="permission_error"
        strategy="fix_permissions"
    elif echo "$error_output" | grep -qiE 'out of memory|heap|OOM|ENOMEM'; then
        diagnosis="resource_error"
        strategy="reduce_resource_usage"
    else
        diagnosis="unknown"
        strategy="retry_with_context"
    fi

    # Check if we've seen this diagnosis before in this session.
    # Append first, then count — so repeat_count reflects total occurrences
    # including the current one, and the threshold matches what the message reports.
    local diagnosis_file="${LOG_DIR:-/tmp}/diagnoses.txt"
    echo "$diagnosis" >> "$diagnosis_file"
    local repeat_count=0
    repeat_count=$(grep -c "^${diagnosis}$" "$diagnosis_file" 2>/dev/null || true)
    repeat_count="${repeat_count:-0}"

    # Escalate strategy if same diagnosis repeats — threshold is 5 same-session
    # failures to avoid thrashing on iteration 2 of a fresh run
    if [[ "$repeat_count" -ge 5 ]]; then
        strategy="alternative_approach"
    fi

    # Try memory-based fix lookup
    local known_fix=""
    if type memory_query_fix_for_error &>/dev/null; then
        local fix_json
        fix_json=$(memory_query_fix_for_error "$error_output" 2>/dev/null || true)
        if [[ -n "$fix_json" && "$fix_json" != "null" ]]; then
            known_fix=$(echo "$fix_json" | jq -r '.fix // ""' 2>/dev/null | head -5)
        fi
    fi

    # Build diagnosis context for Claude
    local diagnosis_context="## Failure Diagnosis (Iteration $iteration)
Classification: $diagnosis
Strategy: $strategy
Repeat count: $repeat_count"

    if [[ -n "$known_fix" ]]; then
        diagnosis_context+="
Known fix from memory: $known_fix"
    fi

    # Strategy-specific guidance
    case "$strategy" in
        fix_imports)
            diagnosis_context+="
INSTRUCTION: The error is about missing imports/modules. Check that all imports are correct, packages are installed, and paths are right. Do NOT change the logic - just fix the imports."
            ;;
        fix_syntax)
            diagnosis_context+="
INSTRUCTION: This is a syntax error. Carefully check the exact line mentioned in the error. Look for missing brackets, semicolons, commas, or mismatched quotes."
            ;;
        fix_types)
            diagnosis_context+="
INSTRUCTION: Type mismatch error. Check the types at the error location. Ensure function signatures match their usage."
            ;;
        fix_logic)
            diagnosis_context+="
INSTRUCTION: Test assertion failure. The code logic is wrong, not the syntax. Re-read the test expectations and fix the implementation to match."
            ;;
        alternative_approach)
            diagnosis_context+="
INSTRUCTION: This error has occurred $repeat_count times. The previous approach is not working. Try a FUNDAMENTALLY DIFFERENT approach:
- If you were modifying existing code, try rewriting the function from scratch
- If you were using one library, try a different one
- If you were adding to a file, try creating a new file instead
- Step back and reconsider the requirements"
            ;;
    esac

    echo "$diagnosis_context"
}

# ─── Test Gate ────────────────────────────────────────────────────────────────

run_test_gate() {
    if [[ -z "$TEST_CMD" ]] && [[ ${#ADDITIONAL_TEST_CMDS[@]} -eq 0 ]]; then
        TEST_PASSED=""
        TEST_OUTPUT=""
        TEST_EXIT_CODE=0
        return
    fi
    # Reset every invocation so a passing iteration cannot inherit a stale
    # non-zero code from the previous run.
    TEST_EXIT_CODE=0

    # Determine which test command to use this iteration
    local active_test_cmd="$TEST_CMD"
    local test_mode="full"
    if [[ -n "$FAST_TEST_CMD" ]]; then
        # Use full test every FAST_TEST_INTERVAL iterations, on first iteration, and on final iteration
        if [[ "$ITERATION" -eq 1 ]] || [[ $(( ITERATION % FAST_TEST_INTERVAL )) -eq 0 ]] || [[ "$ITERATION" -ge "$MAX_ITERATIONS" ]]; then
            active_test_cmd="$TEST_CMD"
            test_mode="full"
        else
            active_test_cmd="$FAST_TEST_CMD"
            test_mode="fast"
        fi
    fi

    local all_passed=true
    local test_results="[]"
    local combined_output=""
    local failed_output=""
    local test_timeout="${SW_TEST_TIMEOUT:-$(_config_get_int "loop.test_timeout" 900 2>/dev/null || echo 900)}"
    local _max_test_timeout="$(_config_get_int "loop.test_timeout_max" 3600 2>/dev/null || echo 3600)"
    # Scale proportionally for multi-target commands.
    # Supports both legacy -t FooTests,BarTests form and the current positional-arg
    # form used by ios_xcode targets (e.g. run-xcode-tests.sh FooTests BarTests Packages).
    local _target_count=0
    local _targets_str
    _targets_str=$(echo "$active_test_cmd" | grep -oE '\-t [^ ]+' | head -1 | sed 's/-t //' || true)
    if [[ -n "$_targets_str" ]]; then
        # Legacy -t comma-separated form
        _target_count=$(echo "$_targets_str" | tr ',' '\n' | grep -c '.' || true)
    elif echo "$active_test_cmd" | grep -qE 'run-xcode-tests\.sh'; then
        # Positional-arg form: count words after the script name, stopping at any shell
        # separator (&&, ||, |, ;) so chained commands are not counted as targets.
        local _args_after_script
        _args_after_script=$(echo "$active_test_cmd" \
            | sed 's|.*run-xcode-tests\.sh[[:space:]]*||; s/[[:space:]]*&&.*//; s/[[:space:]]*||.*//; s/[[:space:]]*|.*//; s/[[:space:]]*;.*//' \
            || true)
        if [[ -n "$_args_after_script" ]]; then
            _target_count=$(echo "$_args_after_script" | wc -w | tr -d '[:space:]' || true)
        fi
    fi
    if [[ "${_target_count:-0}" -gt 1 ]]; then
        local _scaled=$(( _target_count * test_timeout ))
        [[ "$_scaled" -gt "$_max_test_timeout" ]] && _scaled="$_max_test_timeout"
        test_timeout="$_scaled"
    fi

    # Run primary test command
    if [[ -n "$active_test_cmd" ]]; then
        local test_log="$LOG_DIR/tests-iter-${ITERATION}.log"
        TEST_LOG_FILE="$test_log"
        echo -e "  ${DIM}Running ${test_mode} tests...${RESET}"

        local test_wrapper="$active_test_cmd"
        if command -v timeout >/dev/null 2>&1; then
            test_wrapper="timeout ${test_timeout} bash -c $(printf '%q' "$active_test_cmd")"
        elif command -v gtimeout >/dev/null 2>&1; then
            test_wrapper="gtimeout ${test_timeout} bash -c $(printf '%q' "$active_test_cmd")"
        fi

        local start_ts exit_code=0
        start_ts=$(date +%s)
        bash -c "$test_wrapper" > "$test_log" 2>&1 || exit_code=$?
        local duration=$(( $(date +%s) - start_ts ))

        if command -v jq >/dev/null 2>&1; then
            test_results=$(echo "$test_results" | jq --arg cmd "$active_test_cmd" \
                --argjson exit "$exit_code" --argjson dur "$duration" \
                '. + [{"command": $cmd, "exit_code": $exit, "duration_s": $dur}]')
        fi

        local _primary_out
        _primary_out="$(cat "$test_log" 2>/dev/null)"
        combined_output+="$_primary_out"$'\n'
        if [[ "$exit_code" -ne 0 ]]; then
            all_passed=false
            failed_output+="$_primary_out"$'\n'
        fi
    fi

    # Run additional test commands (discovered or explicit)
    # Mid-build discovery: find test files created since loop start
    local mid_build_cmds=()
    if [[ -n "${LOOP_START_COMMIT:-}" ]] && type detect_created_test_files >/dev/null 2>&1; then
        while IFS= read -r _cmd; do
            [[ -n "$_cmd" ]] && mid_build_cmds+=("$_cmd")
        done < <(detect_created_test_files "$LOOP_START_COMMIT" 2>/dev/null || true)
    fi
    local all_extra=("${ADDITIONAL_TEST_CMDS[@]+"${ADDITIONAL_TEST_CMDS[@]}"}" "${mid_build_cmds[@]+"${mid_build_cmds[@]}"}")

    for extra_cmd in "${all_extra[@]+"${all_extra[@]}"}"; do
        [[ -z "$extra_cmd" ]] && continue
        local extra_log="${LOG_DIR}/tests-extra-iter-${ITERATION}.log"
        echo -e "  ${DIM}Running additional: ${extra_cmd}${RESET}"

        local extra_wrapper="$extra_cmd"
        if command -v timeout >/dev/null 2>&1; then
            extra_wrapper="timeout ${test_timeout} bash -c $(printf '%q' "$extra_cmd")"
        elif command -v gtimeout >/dev/null 2>&1; then
            extra_wrapper="gtimeout ${test_timeout} bash -c $(printf '%q' "$extra_cmd")"
        fi

        local start_ts exit_code=0 _extra_out=""
        start_ts=$(date +%s)
        _extra_out=$(bash -c "$extra_wrapper" 2>&1) || exit_code=$?
        echo "$_extra_out" >> "$extra_log"
        local duration=$(( $(date +%s) - start_ts ))

        if command -v jq >/dev/null 2>&1; then
            test_results=$(echo "$test_results" | jq --arg cmd "$extra_cmd" \
                --argjson exit "$exit_code" --argjson dur "$duration" \
                '. + [{"command": $cmd, "exit_code": $exit, "duration_s": $dur}]')
        fi

        combined_output+="$_extra_out"$'\n'
        if [[ "$exit_code" -ne 0 ]]; then
            all_passed=false
            failed_output+="=== $extra_cmd ==="$'\n'"$_extra_out"$'\n'
        fi
    done

    # Write structured test evidence
    if command -v jq >/dev/null 2>&1; then
        echo "$test_results" > "${LOG_DIR}/test-evidence-iter-${ITERATION}.json"
    fi

    # Promote the first non-zero exit code from test_results so downstream
    # memory hooks (capture_failure / analyze_failure) get ground truth
    # instead of inferring it from log text.
    if command -v jq >/dev/null 2>&1; then
        TEST_EXIT_CODE=$(echo "$test_results" | jq -r 'map(.exit_code) | map(select(. != 0)) | .[0] // 0' 2>/dev/null || echo 0)
        # Fall back to 0 on any garbage
        [[ "$TEST_EXIT_CODE" =~ ^[0-9]+$ ]] || TEST_EXIT_CODE=0
    fi

    # Audit: emit test gate event
    if type audit_emit >/dev/null 2>&1; then
        local cmd_count=0
        command -v jq >/dev/null 2>&1 && cmd_count=$(echo "$test_results" | jq 'length' 2>/dev/null || echo 0)
        audit_emit "loop.test_gate" "iteration=$ITERATION" "commands=$cmd_count" \
            "all_passed=$all_passed" "exit_code=$TEST_EXIT_CODE" \
            "evidence_path=test-evidence-iter-${ITERATION}.json" || true
    fi

    TEST_PASSED=$all_passed
    if [[ "$all_passed" == "false" ]] && [[ -n "$failed_output" ]]; then
        TEST_OUTPUT="$(echo "$failed_output" | tail -80 | strip_ansi)"
    else
        TEST_OUTPUT="$(echo "$combined_output" | tail -50 | strip_ansi)"
    fi
}

# Strip confirmed pass-marker lines so words like "fail-open" inside passing
# test descriptions don't get flagged as errors by write_error_summary.
# Why: shipwright test output prints "✓ Test 4: ... (fail-open ...)" for
# PASSING assertions; the unfiltered grep matched the substring "fail" and
# tripped the holistic gate's circuit breaker.
# Note: section-header lines ("Test N: description") are intentionally kept
# — they may be the only context for a failure that appears on the same line.
# Note: PASS/ok use explicit ([[:space:]]|$) boundaries instead of \b because
# \b is a GNU extension not guaranteed in all POSIX ERE implementations.
_strip_passing_test_lines() {
    grep -vE '✓|^[[:space:]]*(PASS([[:space:]]|$)|ok([[:space:]]|$))|[0-9]+/[0-9]+ pass([[:space:]]|$)|All .* passed' || true
}

# Returns 0 (success) if stdin contains a definitive failure marker.
# Used to distinguish real errors from descriptive section headers like
# "Test 4: missing fingerprint file fails open" that survive the pass-line
# strip per #447 design but contain "fail" only as part of a description.
# Why: without this distinction, write_error_summary surfaces section-header
# false positives to the loop's circuit breaker on otherwise green builds.
_has_real_failure_markers() {
    grep -qE '✗|✘|^[[:space:]]*FAIL([[:space:]]|$)|^[[:space:]]*FAILED([[:space:]]|$)|Error:|TypeError:|ReferenceError:|SyntaxError:|^[[:space:]]*at [a-zA-Z_$]|expected.*got|assertion failed'
}

write_error_summary() {
    local error_json="$LOG_DIR/error-summary.json"

    # Strip descriptive test section headers ("  Test 4: ... fails open ...") so
    # the error grep doesn't flag them as failures. Real failure lines are prefixed
    # with a marker (✗, FAIL, ERROR), so they don't match this pattern.
    # Why: section headers are intentionally kept by _strip_passing_test_lines so
    # they provide context in the iteration prompt (#447), but for the structured
    # error count they're noise that triggers spurious circuit-breaker iterations.
    local _strip_section_headers='^[[:space:]]*Test [0-9]+:[[:space:]]'

    # Write on test failure OR build failure (non-zero exit from Claude iteration)
    local build_log="$LOG_DIR/iteration-${ITERATION}.log"
    if [[ "${TEST_PASSED:-}" != "false" ]]; then
        # Check for build-level failures (Claude iteration exited non-zero or produced errors)
        local build_had_errors=false
        if [[ -f "$build_log" ]]; then
            local build_err_lines
            build_err_lines=$(tail -30 "$build_log" 2>/dev/null \
                | strip_ansi \
                | _strip_passing_test_lines \
                | grep -iE '(error|fail|exception|panic|FATAL)' || true)
            # Only treat as build error if at least one line has a real failure
            # marker — words like "fail" inside section-header descriptions
            # ("Test 4: ... fails open") are preserved by design but aren't
            # actual failures.
            if [[ -n "$build_err_lines" ]] \
                && printf '%s\n' "$build_err_lines" | _has_real_failure_markers; then
                build_had_errors=true
            fi
        fi
        if [[ "$build_had_errors" != "true" ]]; then
            # Clear previous error summary on success
            rm -f "$error_json" 2>/dev/null || true
            return
        fi
    fi

    # Prefer test log, fall back to build log
    local test_log="${TEST_LOG_FILE:-$LOG_DIR/tests-iter-${ITERATION}.log}"
    local source_log="$test_log"
    if [[ ! -f "$source_log" ]]; then
        source_log="$build_log"
    fi
    [[ ! -f "$source_log" ]] && return

    # Extract error lines (last 30 lines, grep for error patterns)
    local error_lines_raw
    error_lines_raw=$(tail -30 "$source_log" 2>/dev/null \
        | strip_ansi \
        | _strip_passing_test_lines \
        | grep -vE "$_strip_section_headers" \
        | grep -iE '(error|fail|assert|exception|panic|FAIL|TypeError|ReferenceError|SyntaxError)' \
        | head -10 || true)

    # Suppress false positives: if matched lines contain no definitive failure
    # marker (✗, FAIL keyword, error stack trace) AND the source log reports
    # a clean pass, the matches are descriptive section headers (e.g.,
    # "Test 4: missing fingerprint file fails open") preserved by #447 design,
    # not actual errors. Surfacing these trips the holistic circuit breaker on
    # green builds.
    if [[ -n "$error_lines_raw" ]] \
        && ! printf '%s\n' "$error_lines_raw" | _has_real_failure_markers; then
        if tail -50 "$source_log" 2>/dev/null \
            | strip_ansi \
            | grep -qE '(All [0-9]+ tests? passed|^[0-9]+/[0-9]+ pass([[:space:]]|$))'; then
            error_lines_raw=""
        fi
    fi

    local error_count=0
    if [[ -n "$error_lines_raw" ]]; then
        error_count=$(echo "$error_lines_raw" | wc -l | tr -d ' ')
    fi

    local tmp_json="${error_json}.tmp.$$"

    # Build JSON with jq (preferred) or plain-text fallback
    if command -v jq >/dev/null 2>&1; then
        jq -n \
            --argjson iteration "${ITERATION:-0}" \
            --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
            --argjson error_count "${error_count:-0}" \
            --arg error_lines "$error_lines_raw" \
            --arg test_cmd "${TEST_CMD:-}" \
            '{
                iteration: $iteration,
                timestamp: $timestamp,
                error_count: $error_count,
                error_lines: ($error_lines | split("\n") | map(select(length > 0))),
                test_cmd: $test_cmd
            }' > "$tmp_json" 2>/dev/null && mv "$tmp_json" "$error_json" || rm -f "$tmp_json" 2>/dev/null
    else
        # Fallback: write plain-text error summary (still machine-parseable)
        cat > "$tmp_json" <<ERRJSON
{"iteration":${ITERATION:-0},"error_count":${error_count:-0},"error_lines":[],"test_cmd":"test"}
ERRJSON
        mv "$tmp_json" "$error_json" 2>/dev/null || rm -f "$tmp_json" 2>/dev/null
    fi
}

# ─── Audit Agent ─────────────────────────────────────────────────────────────

run_audit_agent() {
    if ! $AUDIT_AGENT_ENABLED; then
        return
    fi

    local log_file="$LOG_DIR/iteration-${ITERATION}.log"
    local audit_log="$LOG_DIR/audit-iter-${ITERATION}.log"

    # Gather context: tail of implementer output + cumulative diff
    local impl_tail
    impl_tail="$(tail -100 "$log_file" 2>/dev/null || echo "(no output)")"

    # Use cumulative diff from loop start so auditor sees ALL work, not just latest commit
    local diff_stat cumulative_note=""
    if [[ -n "${LOOP_START_COMMIT:-}" ]]; then
        diff_stat="$(git -C "$PROJECT_ROOT" diff --stat "${LOOP_START_COMMIT}..HEAD" 2>/dev/null || echo "(no changes)")"
        cumulative_note="Note: This diff shows ALL changes since the loop started (iteration 1 through ${ITERATION}), not just the latest commit."
    else
        diff_stat="$(git -C "$PROJECT_ROOT" diff --stat HEAD~1 2>/dev/null || echo "(no changes)")"
    fi

    # Include verified test status so auditor doesn't have to guess
    local test_context=""
    local evidence_file="${LOG_DIR}/test-evidence-iter-${ITERATION}.json"
    if [[ -f "$evidence_file" ]] && command -v jq >/dev/null 2>&1; then
        local cmd_count total_cmds evidence_detail
        cmd_count=$(jq 'length' "$evidence_file" 2>/dev/null || echo 0)
        total_cmds=$(jq -r '[.[].command] | join(", ")' "$evidence_file" 2>/dev/null || echo "unknown")
        evidence_detail=$(jq -r '.[] | "- \(.command): exit \(.exit_code) (\(.duration_s)s)"' "$evidence_file" 2>/dev/null || echo "")
        test_context="## Verified Test Status (from harness, not from agent)
Test commands run: ${cmd_count} (${total_cmds})
${evidence_detail}
Overall: $(if [[ "${TEST_PASSED:-}" == "true" ]]; then echo "ALL PASSING"; else echo "FAILING"; fi)"
    elif [[ -n "$TEST_CMD" ]]; then
        # Fallback to existing boolean
        if [[ "${TEST_PASSED:-}" == "true" ]]; then
            test_context="## Verified Test Status (from harness, not from agent)
Tests: ALL PASSING (command: ${TEST_CMD})"
        else
            test_context="## Verified Test Status (from harness)
Tests: FAILING (command: ${TEST_CMD})
$(echo "${TEST_OUTPUT:-}" | tail -10)"
        fi
    fi

    local audit_prompt
    read -r -d '' audit_prompt <<AUDIT_PROMPT || true
You are an independent code auditor reviewing an autonomous coding agent's CUMULATIVE work.
This is iteration ${ITERATION}. The agent may have done most of the work in earlier iterations.

## Goal the agent was working toward
${GOAL}

## Agent Output This Iteration (last 100 lines)
${impl_tail}

## Cumulative Changes Made (git diff --stat)
${cumulative_note}
${diff_stat}

${test_context}

## Your Task
Critically review the CUMULATIVE work (not just the latest iteration):
1. Has the agent made meaningful progress toward the goal across all iterations?
2. Are there obvious bugs, logic errors, or security issues in the current codebase?
3. Did the agent leave incomplete work (TODOs, placeholder code)?
4. Are there any regressions or broken patterns?
5. Is the code quality acceptable?

IMPORTANT: If the current iteration made small or no code changes, that may be acceptable
if earlier iterations already completed the substantive work. Judge the whole body of work.

If the work is acceptable and moves toward the goal, output your verdict on its own line as:
  <<<AUDIT:PASS>>>
If there are issues that need fixing, list them and then output on its own line:
  <<<AUDIT:FAIL>>>
Do not wrap the verdict in JSON, markdown, or code blocks.
AUDIT_PROMPT

    echo -e "  ${PURPLE}▸${RESET} Running audit agent..."

    # Select audit model adaptively (haiku if success rate high, else sonnet)
    local audit_model
    audit_model="$(select_audit_model)"
    local audit_flags=()
    audit_flags+=("--model" "$audit_model")
    audit_flags+=("--disallowed-tools" "EnterPlanMode,ExitPlanMode")
    if $SKIP_PERMISSIONS; then
        audit_flags+=("--dangerously-skip-permissions")
    fi

    local exit_code=0
    local audit_err_log="${audit_log%.log}-stderr.log"
    # Pipe prompt via stdin (not as a CLI argument) so it is not subject to the
    # OS exec ARG_MAX limit. With cumulative diffs growing each iteration the
    # audit prompt regularly exceeds 128KB which trips
    # "Argument list too long" on Linux. claude -p reads stdin when no
    # positional prompt is given.
    printf '%s' "$audit_prompt" | claude -p "${audit_flags[@]}" > "$audit_log" 2>"$audit_err_log" &
    CHILD_PID=$!
    wait "$CHILD_PID" 2>/dev/null || exit_code=$?
    CHILD_PID=""

    # Guard: empty or near-empty response means the evaluator failed to run
    local audit_log_bytes
    audit_log_bytes="$(wc -c < "$audit_log" 2>/dev/null || echo "0")"
    audit_log_bytes="${audit_log_bytes// /}"
    if [[ ! -s "$audit_log" ]] || [[ "$audit_log_bytes" -le 2 ]]; then
        warn "Audit: evaluator returned empty output (exit_code=${exit_code}) — treating as fail"
        warn "Audit log: $audit_log (${audit_log_bytes} bytes), stderr: $audit_err_log"
        AUDIT_RESULT="Audit evaluator returned no output"
        return 0  # don't abort the loop; AUDIT_RESULT will be injected as feedback
    fi

    # Log non-zero exit alongside non-empty output — likely a Claude API/CLI error message
    if [[ "$exit_code" -ne 0 ]]; then
        warn "Audit: claude -p exited with code ${exit_code} — output may contain an error message"
    fi

    if detect_gate_signal "$audit_log" "AUDIT" \
        'AUDIT_PASS|"verdict"[[:space:]]*:[[:space:]]*"pass"' \
        'AUDIT_FAIL|<<<AUDIT:FAIL>>>'; then
        AUDIT_RESULT="pass"
        record_gate_finding "audit" "pass" "" ""
        echo -e "  ${GREEN}✓${RESET} Audit: passed"
    else
        AUDIT_RESULT="$(grep -v '^$' "$audit_log" | tail -20 | head -10 2>/dev/null || echo "Audit returned no output")"
        record_gate_finding "audit" "fail" "audit issues found" "$AUDIT_RESULT"
        echo -e "  ${YELLOW}⚠${RESET} Audit: issues found"
    fi
}

# ─── Quality Gates ───────────────────────────────────────────────────────────

# Record a gate result into the single-funnel accumulators.
# Passes go to GATE_PASSED_NAMES; failures get a guaranteed non-empty detail block in GATE_FINDINGS.
# Usage: record_gate_finding <gate_name> <verdict> <summary> [detail]
record_gate_finding() {
    local _gate="$1" _verdict="$2" _summary="$3" _detail="${4:-}"
    if [[ "$_verdict" == "pass" ]]; then
        GATE_PASSED_NAMES="${GATE_PASSED_NAMES} ${_gate}"
        return 0
    fi
    if [[ -z "$_detail" ]]; then
        _detail="Evaluator returned no item-level detail (harness diagnostic gap — the evaluator path did not produce structured output for this gate). Inspect the iteration log for raw evaluator output."
    fi
    GATE_FINDINGS="${GATE_FINDINGS}

### ${_gate} — verdict: ${_verdict}${_summary:+
${_summary}}
${_detail}"
}

# Ingest pipeline-stage gate artifacts into the findings funnel.
# Only runs on iteration 1 — pipeline artifacts are one-shot context, not repeated each loop.
ingest_pipeline_stage_findings() {
    [[ "${ITERATION:-0}" -gt 1 ]] && return 0
    [[ -z "${ARTIFACTS_DIR:-}" ]] || [[ ! -d "$ARTIFACTS_DIR" ]] && return 0

    local _artifact _detail _count

    # pipeline:adversarial
    _artifact="${ARTIFACTS_DIR}/adversarial-review.json"
    if [[ -f "$_artifact" ]]; then
        if [[ ! -s "$_artifact" ]]; then
            record_gate_finding "pipeline:adversarial" "fail" "adversarial review ran" ""
        else
            _count="$(grep -c '"severity"[[:space:]]*:[[:space:]]*"\(critical\|high\)"' "$_artifact" 2>/dev/null || true)"
            _count="${_count:-0}"
            if [[ "$_count" -gt 0 ]]; then
                _detail="$(grep -A2 '"severity"[[:space:]]*:[[:space:]]*"\(critical\|high\)"' "$_artifact" 2>/dev/null | head -20 || true)"
                record_gate_finding "pipeline:adversarial" "fail" "${_count} critical/high finding(s)" "${_detail}"
            else
                record_gate_finding "pipeline:adversarial" "pass" "" ""
            fi
        fi
    fi

    # pipeline:negative
    _artifact="${ARTIFACTS_DIR}/negative-review.md"
    if [[ -f "$_artifact" ]]; then
        if [[ ! -s "$_artifact" ]]; then
            record_gate_finding "pipeline:negative" "fail" "negative review ran" ""
        else
            _count="$(grep -ic 'critical' "$_artifact" 2>/dev/null || true)"
            _count="${_count:-0}"
            if [[ "$_count" -gt 0 ]]; then
                _detail="$(grep -i 'critical' "$_artifact" 2>/dev/null | head -10 || true)"
                record_gate_finding "pipeline:negative" "fail" "${_count} critical finding(s)" "${_detail}"
            else
                record_gate_finding "pipeline:negative" "pass" "" ""
            fi
        fi
    fi

    # pipeline:security — parse security artifacts/logs for ACTUAL findings.
    # Earlier versions of this gate marked any non-empty artifact as "fail",
    # which produced false positives when scans emit "[]" (empty JSON array)
    # or audit logs that say "found 0 vulnerabilities". Mirror the proven
    # parsing in scripts/lib/pipeline-intelligence.sh:1142 (uses jq length > 0)
    # and scripts/sw-loop.sh:1525-1540 (pipeline:adversarial pattern).
    _sec_verdict=""; _sec_summary=""; _sec_detail=""
    for _artifact in "${ARTIFACTS_DIR}"/security*.json "${ARTIFACTS_DIR}"/security*.log; do
        [[ -f "$_artifact" ]] || continue
        case "$_artifact" in
            *.json)
                # Empty file or `[]` array → no findings. Count entries via jq.
                if [[ ! -s "$_artifact" ]]; then
                    [[ -z "$_sec_verdict" ]] && _sec_verdict="pass"
                    continue
                fi
                _count="$(jq 'if type=="array" then length else 0 end' "$_artifact" 2>/dev/null || echo "0")"
                _count="${_count:-0}"
                if [[ "$_count" -gt 0 ]]; then
                    _sec_verdict="fail"
                    _sec_summary="${_count} security finding(s)"
                    _sec_detail="$(jq -r '.[0:5] | .[] | tostring' "$_artifact" 2>/dev/null | head -20 || true)"
                    break
                fi
                [[ -z "$_sec_verdict" ]] && _sec_verdict="pass"
                ;;
            *.log)
                # Empty log → skip (no signal). "found 0 vulnerabilities" / "no vulnerabilities" → pass.
                [[ ! -s "$_artifact" ]] && continue
                if grep -qiE '(0 vulnerabilities|no vulnerabilities|0 advisories)' "$_artifact" 2>/dev/null; then
                    [[ -z "$_sec_verdict" ]] && _sec_verdict="pass"
                    continue
                fi
                if grep -qiE '(severity[[:space:]]*:[[:space:]]*(critical|high)|CVE-[0-9])' "$_artifact" 2>/dev/null; then
                    _sec_verdict="fail"
                    _sec_summary="security findings present"
                    _sec_detail="$(tail -15 "$_artifact" 2>/dev/null || true)"
                    break
                fi
                [[ -z "$_sec_verdict" ]] && _sec_verdict="pass"
                ;;
        esac
    done
    [[ -n "$_sec_verdict" ]] && record_gate_finding "pipeline:security" "$_sec_verdict" "$_sec_summary" "$_sec_detail"

    # pipeline:lint
    _artifact="${ARTIFACTS_DIR}/lint-report.json"
    if [[ -f "$_artifact" ]]; then
        if [[ ! -s "$_artifact" ]]; then
            record_gate_finding "pipeline:lint" "fail" "lint ran but produced no output" ""
        else
            _count="$(jq '[.[] | select(.type=="error")] | length' "$_artifact" 2>/dev/null || echo "")"
            if [[ "${_count:-0}" -gt 0 ]]; then
                _detail="$(jq -r '.[] | select(.type=="error") | .file + ":" + (.line|tostring) + " " + .message' "$_artifact" 2>/dev/null | head -10 || true)"
                record_gate_finding "pipeline:lint" "fail" "${_count} lint error(s)" "${_detail}"
            else
                record_gate_finding "pipeline:lint" "pass" "" ""
            fi
        fi
    fi

    # pipeline:coverage — check both flat and nested locations used in the codebase
    _artifact="${ARTIFACTS_DIR}/coverage-summary.json"
    if [[ ! -f "$_artifact" ]]; then
        _artifact="${ARTIFACTS_DIR}/coverage/coverage-summary.json"
    fi
    if [[ -f "$_artifact" ]]; then
        if [[ ! -s "$_artifact" ]]; then
            record_gate_finding "pipeline:coverage" "fail" "coverage report empty" ""
        else
            _detail="$(jq -r 'to_entries[] | select(.key=="total") | .value | to_entries[] | .key + ": " + (.value.pct|tostring) + "%"' "$_artifact" 2>/dev/null | head -10 || true)"
            record_gate_finding "pipeline:coverage" "fail" "coverage below threshold" "${_detail:-see coverage-summary.json}"
        fi
    fi

    # pipeline:holistic (compound quality from pipeline stage)
    local _hol_artifact="${ARTIFACTS_DIR}/compound-quality.json"
    if [[ ! -f "$_hol_artifact" ]]; then
        _hol_artifact="${ARTIFACTS_DIR}/holistic-assessment.json"
    fi
    if [[ -f "$_hol_artifact" ]]; then
        if [[ ! -s "$_hol_artifact" ]]; then
            record_gate_finding "pipeline:holistic" "fail" "compound quality check ran" ""
        else
            _detail="$(jq -r '.summary // .gaps // ""' "$_hol_artifact" 2>/dev/null || tail -10 "$_hol_artifact" 2>/dev/null || true)"
            if jq -e '.verdict == "pass"' "$_hol_artifact" >/dev/null 2>&1; then
                record_gate_finding "pipeline:holistic" "pass" "" ""
            else
                record_gate_finding "pipeline:holistic" "fail" "pipeline holistic found gaps" "${_detail}"
            fi
        fi
    fi
}

run_quality_gates() {
    if ! $QUALITY_GATES_ENABLED; then
        QUALITY_GATE_PASSED=true
        return
    fi

    HOLISTIC_RESULT=""       # reset: stale holistic text from a prior gate-run must not persist across iterations
    QUALITY_GATE_DETAIL=""   # reset: stale gate detail must not persist across iterations
    GATE_FINDINGS=""
    GATE_PASSED_NAMES=""
    QUALITY_GATE_REASONS=""
    QUALITY_GATE_PASSED=true
    local gate_failures=()

    ingest_pipeline_stage_findings

    echo -e "  ${PURPLE}▸${RESET} Running quality gates..."

    # Gate 1: Tests pass (if TEST_CMD set)
    if [[ -n "$TEST_CMD" ]]; then
        if [[ "$TEST_PASSED" == "false" ]]; then
            gate_failures+=("tests failing")
            record_gate_finding "tests" "fail" "tests failing" ""
        else
            record_gate_finding "tests" "pass" "" ""
        fi
    fi

    # Gate 2: No uncommitted changes (excluding all bookkeeping/runtime files)
    if ! git -C "$PROJECT_ROOT" diff --quiet -- $(_git_excluded_pathspecs) 2>/dev/null || \
       ! git -C "$PROJECT_ROOT" diff --cached --quiet -- $(_git_excluded_pathspecs) 2>/dev/null; then
        gate_failures+=("uncommitted changes present")
        local _uc_files
        _uc_files="$(git -C "$PROJECT_ROOT" diff --name-only -- $(_git_excluded_pathspecs) 2>/dev/null | head -10 || true)"
        record_gate_finding "uncommitted-changes" "fail" "uncommitted changes present" "${_uc_files:-no file list available}"
    else
        record_gate_finding "uncommitted-changes" "pass" "" ""
    fi

    # Gate 3: No TODO/FIXME/HACK/XXX in new source code
    # Exclude .claude/, docs/plans/, and markdown files (which legitimately contain task markers)
    # -c diff.noprefix=false ensures +++ b/<path> prefix is always present regardless of user config.
    # Capture once with --unified=0; use the same output for both counting and location extraction.
    # NOTE: --unified=0 is required — awk tracks line numbers by counting only added lines.
    # Context lines are absent with this flag; changing the diff flags would cause lineno drift.
    # file=$0; sub(...) handles paths with spaces by copying the full header line, then stripping
    # the +++ b/ prefix. /^\+/ && !/^\+\+\+/ counts ALL added lines (including empty ones) so
    # lineno stays accurate when blank lines precede a marker.
    # Marker patterns are assembled from shell-quoted fragments so this source
    # itself does not contain the literal marker substrings (which would
    # self-flag). The X-marker uses X{3} (quantifier) with a non-X boundary on
    # each side, so mktemp templates like X{6} (six contiguous X's) are
    # excluded as legitimate template syntax rather than task markers.
    local _m_t _m_f _m_h _m_alt
    _m_t='T''O''D''O'
    _m_f='F''I''X''M''E'
    _m_h='H''A''C''K'
    _m_alt="${_m_t}|${_m_f}|${_m_h}"
    local _todo_diff todo_count
    _todo_diff="$(git -C "$PROJECT_ROOT" -c diff.noprefix=false diff HEAD~1 --unified=0 \
        -- ':!.claude/' ':!docs/plans/' ':!*.md' 2>/dev/null || true)"
    todo_count="$(printf '%s\n' "$_todo_diff" | grep -cE "^\+[^+].*(${_m_alt}|([^X]|^)X{3}([^X]|$))" || true)"
    todo_count="${todo_count:-0}"
    if [[ "${todo_count:-0}" -gt 0 ]]; then
        gate_failures+=("${todo_count} task-marker(s) in new code")
        local _todo_locations
        _todo_locations="$(printf '%s\n' "$_todo_diff" \
          | awk -v t="$_m_t" -v f="$_m_f" -v h="$_m_h" '
              /^\+\+\+ / { file=$0; sub(/^\+\+\+ b\//,"",file) }
              /^@@ /     { s=$3; sub(/^[^+]*\+/,"",s); sub(/,.*/,"",s); lineno=int(s)-1 }
              /^\+/ && !/^\+\+\+/ {
                lineno++
                if (index($0,t) || index($0,f) || index($0,h) || match($0,/([^X]|^)X{3}([^X]|$)/))
                  print file ":" lineno ": " substr($0,2)
              }
            ' | head -10 || true)"
        record_gate_finding "task-markers" "fail" "${todo_count} task-marker(s) in new code" "${_todo_locations:-no locations extracted — grep the diff manually}"
    else
        record_gate_finding "task-markers" "pass" "" ""
    fi

    # Gate 4: Definition of Done (if DOD_FILE set)
    if [[ -n "$DOD_FILE" ]]; then
        type _emit_inner_stage_event >/dev/null 2>&1 && _emit_inner_stage_event "inner" "build" "dod_start" "Definition of Done check"
        if ! check_definition_of_done; then
            gate_failures+=("definition of done not satisfied")
        fi
    fi

    if [[ ${#gate_failures[@]} -gt 0 ]]; then
        QUALITY_GATE_PASSED=false
        local failures_str
        failures_str="$(printf ', %s' "${gate_failures[@]}")"
        failures_str="${failures_str:2}"  # trim leading ", "
        QUALITY_GATE_REASONS="$failures_str"
        echo -e "  ${RED}✗${RESET} Quality gates: FAILED (${failures_str})"
    else
        QUALITY_GATE_REASONS=""
        echo -e "  ${GREEN}✓${RESET} Quality gates: all passed"
    fi
}

_normalize_dod_checkboxes() {
    local _line _bracket
    while IFS= read -r _line || [[ -n "$_line" ]]; do
        case "$_line" in
            "- [x]"*) ;;
            "- [ ]"*)
                # Only promote when a check symbol is a trailing completion annotation:
                # either at the very end of the line, or followed by a parenthetical note.
                # Avoids false-positives when the description merely references a symbol
                # (e.g. "- [ ] Parser must handle ✓ markers in output" stays unchecked).
                case "$_line" in
                    *✓|*✔|*✅|*☑|\
                    *'✓ ('*')'|*'✔ ('*')'|*'✅ ('*')'|*'☑ ('*')')
                        _line="- [x]${_line#"- [ ]"}" ;;
                esac
                ;;
            "- ["*"]"*)
                # Normalize only when bracket content contains a non-whitespace character.
                # Prevents "- [  ] item" (multiple spaces) from being promoted.
                _bracket="${_line#"- ["}"
                _bracket="${_bracket%%]*}"
                if [[ "$_bracket" =~ [^[:space:]] ]]; then
                    _line="- [x]${_line#- \[*\]}"
                fi
                ;;
        esac
        printf '%s\n' "$_line"
    done
}

check_definition_of_done() {
    if [[ ! -f "$DOD_FILE" ]]; then
        warn "Definition of done file not found: $DOD_FILE"
        return 1
    fi

    local dod_content
    dod_content="$(cat "$DOD_FILE")"
    dod_content="$(_normalize_dod_checkboxes <<< "$dod_content")"

    # Use cumulative diff from loop start (not just HEAD~1) so the evaluator
    # can see ALL work done across every iteration, not just the latest commit.
    local diff_content
    local _diff_range
    if [[ -n "${LOOP_START_COMMIT:-}" ]]; then
        _diff_range="${LOOP_START_COMMIT}..HEAD"
        diff_content="$(git -C "$PROJECT_ROOT" diff --stat "${_diff_range}" -- . $(_git_excluded_pathspecs) 2>/dev/null || echo "(no diff)")"
        diff_content="${diff_content}

## Detailed Changes (cumulative diff, capped at ${DOD_DIFF_MAX_LINES} lines)
$(git -C "$PROJECT_ROOT" diff "${_diff_range}" -- . $(_git_excluded_pathspecs) 2>/dev/null | head -"${DOD_DIFF_MAX_LINES}" || echo "(no diff)")"
    else
        _diff_range="HEAD~1"
        diff_content="$(git -C "$PROJECT_ROOT" diff HEAD~1 -- . $(_git_excluded_pathspecs) 2>/dev/null | head -"${DOD_DIFF_MAX_LINES}" || echo "(no diff)")"
    fi

    # Detect actual truncation using N+1 probe against the same range used above.
    local _extra_line
    _extra_line=$(git -C "$PROJECT_ROOT" diff "${_diff_range}" -- . $(_git_excluded_pathspecs) 2>/dev/null | head -$((DOD_DIFF_MAX_LINES + 1)) | tail -1 || true)
    if [[ -n "$_extra_line" ]]; then
        diff_content="${diff_content}
[DIFF TRUNCATED at ${DOD_DIFF_MAX_LINES} lines — some changes are not shown. Do not conclude 'no changes' from missing sections.]"
    fi

    # Also compute the full branch diff vs base branch. In compound_rebuild cycles,
    # LOOP_START_COMMIT is reset to the HEAD after prior build work, so the loop-run
    # diff above only shows the small rebuild-cycle changes. The branch diff shows
    # ALL work accumulated on this branch — which is what the DoD items actually cover.
    local branch_diff_content=""
    local _dod_merge_base=""
    type _ensure_base_branch_ref >/dev/null 2>&1 && { _ensure_base_branch_ref || true; }
    _dod_merge_base="$(_git_branch_merge_base "${BASE_BRANCH:-}")"
    if [[ -n "$_dod_merge_base" ]]; then
        local _dod_branch_stat _dod_branch_diff
        _dod_branch_stat="$(git -C "$PROJECT_ROOT" diff --stat "${_dod_merge_base}..HEAD" -- . $(_git_excluded_pathspecs) 2>/dev/null || echo "(none)")"
        _dod_branch_diff="$(git -C "$PROJECT_ROOT" diff "${_dod_merge_base}..HEAD" -- . $(_git_excluded_pathspecs) 2>/dev/null \
            | head -"${DOD_DIFF_MAX_LINES}" \
            | sed 's/<<<DOD:PASS>>>/[REDACTED:DOD:PASS]/g; s/<<<DOD:FAIL>>>/[REDACTED:DOD:FAIL]/g' \
            || echo "(none)")"
        # Detect actual truncation by checking if git diff output exceeded the limit.
        local _branch_was_truncated=false
        local _branch_extra_line
        _branch_extra_line=$(git -C "$PROJECT_ROOT" diff "${_dod_merge_base}..HEAD" -- . $(_git_excluded_pathspecs) 2>/dev/null | head -$((DOD_DIFF_MAX_LINES + 1)) | tail -1 || true)
        if [[ -n "$_branch_extra_line" ]]; then
            _branch_was_truncated=true
        fi
        if [[ "$_branch_was_truncated" == "true" ]]; then
            _dod_branch_diff="${_dod_branch_diff}
[DIFF TRUNCATED at ${DOD_DIFF_MAX_LINES} lines — some changes are not shown. Do not conclude 'no changes' from missing sections.]"
        fi
        branch_diff_content="## Full Branch Changes vs Base (authoritative — all work including prior build loops)
${_dod_branch_stat}

### Branch Diff Detail (capped at ${DOD_DIFF_MAX_LINES} lines)
${_dod_branch_diff}"
    fi

    # Inject verified runtime facts so the evaluator doesn't have to guess
    local runtime_facts=""
    if [[ -n "$TEST_CMD" ]]; then
        if [[ "${TEST_PASSED:-}" == "true" ]]; then
            runtime_facts="## Verified Runtime Facts (from the loop harness, not from the agent)
- Tests: ALL PASSING (verified by running '${TEST_CMD}' after this iteration)
- Test output (last 10 lines):
$(echo "${TEST_OUTPUT:-}" | tail -10)"
        else
            runtime_facts="## Verified Runtime Facts
- Tests: FAILING (verified by running '${TEST_CMD}')
- Test output (last 10 lines):
$(echo "${TEST_OUTPUT:-}" | tail -10)"
        fi
    fi

    local dod_prompt
    read -r -d '' dod_prompt <<DOD_PROMPT || true
You are evaluating whether a project satisfies a Definition of Done checklist.
You are reviewing the CUMULATIVE work across all iterations, not just the latest commit.

## Definition of Done
${dod_content}

${runtime_facts}

## This Loop Run Changes (git diff from start of this loop invocation to now)
NOTE: If this section shows few or no changes, the original work was likely done in a prior build
loop (e.g., an earlier compound_quality rebuild cycle). Use the Full Branch diff below instead.
${diff_content}

${branch_diff_content}

## Your Task
For each item in the Definition of Done, determine if the project satisfies it.
Use the Full Branch diff above as the authoritative view of all work done on this branch.
The runtime facts above are verified by the harness — trust them as ground truth.

IMPORTANT: A checkbox item is satisfied if its brackets contain any non-space marker: [x], [X], [✓], [✔], [✅], [☑], [*], [+], [~], or similar. Treat any such item as satisfied=true.
An unchecked [ ] item may also be satisfied if a check symbol (✓ ✔ ✅ ☑) appears appended at the END of the item text as an explicit completion annotation (e.g. "- [ ] item ✓ (confirmed)"). Do NOT treat an item as satisfied merely because its description text references or discusses a check symbol.

IMPORTANT: Respond with a JSON object followed by a verdict line. No prose, no markdown fences, no code blocks. Format:
{"verdict":"pass","items":[{"item":"...","satisfied":true,"reason":"..."}],"summary":"..."}
- Set "verdict" to "pass" if ALL items are satisfied. Set it to "fail" if ANY item is not satisfied.
- For each DoD item, add an entry to "items" with the item text and whether it passes.
- In "summary", briefly explain your verdict (1-2 sentences max).

For each unsatisfied item, if you can identify specific files from the diffs above, also include:
- "files": array of specific file paths to create or modify
- "hint": one sentence describing the exact change needed
These fields are optional — only include them when you have high confidence from the diff context.

Example of an unsatisfied item with optional fields:
{"item":"Dashboard returns new fields","satisfied":false,"reason":"No TypeScript changes","files":["dashboard/src/types/api.ts","dashboard/src/core/api.ts"],"hint":"Add stageCosts field to FleetState interface and wire it in fetchMetrics()"}

On the line immediately after the JSON object, output exactly one of:
  <<<DOD:PASS>>>
  <<<DOD:FAIL>>>
DOD_PROMPT

    local dod_log="$LOG_DIR/dod-iter-${ITERATION}.log"
    local dod_model
    dod_model="$(select_audit_model)"
    local dod_flags=()
    dod_flags+=("--model" "$dod_model")
    # EnterPlanMode/ExitPlanMode are NOT disallowed here: the DoD evaluator is a
    # one-shot -p call. When the cumulative diff grows large (iter 2+), the model
    # tries to "plan" its analysis → hits the disallowed-tool restriction → exits 126
    # with empty output. No disallowed-tools restriction means the model can plan
    # freely; --dangerously-skip-permissions ensures it never blocks on a permission
    # prompt in CI. Note: --output-format json is intentionally absent — it causes
    # its own exit-126 in CI when combined with -p.
    if $SKIP_PERMISSIONS; then
        dod_flags+=("--dangerously-skip-permissions")
    fi

    # Pre-flight: if the assembled prompt exceeds the context limit, fail fast with a
    # clear diagnostic instead of sending it and getting a cryptic parse error back.
    # Retry would not help — the prompt will be the same size next iteration.
    local _dod_bytes=${#dod_prompt}
    local _dod_max="${SHIPWRIGHT_DOD_PROMPT_MAX_BYTES:-700000}"
    if [[ "$_dod_bytes" -gt "$_dod_max" ]]; then
        local _branch_stat=""
        [[ -n "${_dod_merge_base:-}" ]] && \
            _branch_stat="$(git -C "$PROJECT_ROOT" diff --stat "${_dod_merge_base}..HEAD" \
                -- . $(_git_excluded_pathspecs) 2>/dev/null | tail -20 || true)"
        warn "DoD: FATAL — prompt ${_dod_bytes} bytes (~$((_dod_bytes / 4)) tokens) exceeds limit (${_dod_max})"
        warn "DoD: branch diff --stat (what inflated the prompt):"
        [[ -n "$_branch_stat" ]] && warn "$_branch_stat"
        warn "DoD: fix — remove accidentally-committed runtime files: git rm --cached <file>"
        LOOP_ABORT_FATAL=true
        record_gate_finding "dod" "fail" \
            "DoD prompt too large (${_dod_bytes} bytes, ~$((_dod_bytes / 4)) tokens)" \
            "DoD prompt exceeded context limit (${_dod_max} bytes). Branch diff stat:
${_branch_stat}
Fix: git rm --cached <accidentally-committed-runtime-file>"
        return 1
    fi

    local dod_err_log="${dod_log%.log}-stderr.log"
    local dod_exit_code=0
    # Pipe prompt via stdin to bypass exec ARG_MAX. The DoD prompt embeds the
    # full branch diff plus runtime facts and routinely grows past 128KB on
    # long-running pipelines; passing it as a CLI argument was failing with
    # "Argument list too long" on the deployed shipwright-cli (#504 iter 8).
    printf '%s' "$dod_prompt" | claude -p "${dod_flags[@]}" > "$dod_log" 2>"$dod_err_log" &
    CHILD_PID=$!
    wait "$CHILD_PID" 2>/dev/null || dod_exit_code=$?
    CHILD_PID=""

    # Post-invocation: check both stdout and stderr for CLI context-limit errors.
    # The Anthropic CLI may report "Prompt is too long" on either stream depending
    # on how the error surfaces (HTTP 400 vs local pre-check).
    if grep -qiE "prompt is too long|context.?length.?exceeded|request.{0,20}too large" \
            "$dod_log" "$dod_err_log" 2>/dev/null; then
        local _cli_err _bytes=${#dod_prompt}
        _cli_err="$(cat "$dod_log" "$dod_err_log" 2>/dev/null | grep -iE "prompt is too long|context.?length.?exceeded|request.{0,20}too large" | head -1 || true)"
        local _branch_stat=""
        [[ -n "${_dod_merge_base:-}" ]] && \
            _branch_stat="$(git -C "$PROJECT_ROOT" diff --stat "${_dod_merge_base}..HEAD" \
                -- . $(_git_excluded_pathspecs) 2>/dev/null | tail -20 || true)"
        warn "DoD: FATAL — claude -p returned context error: ${_cli_err}"
        warn "DoD: prompt was ${_bytes} bytes (~$((_bytes / 4)) tokens)"
        [[ -n "$_branch_stat" ]] && warn "$_branch_stat"
        LOOP_ABORT_FATAL=true
        record_gate_finding "dod" "fail" \
            "DoD evaluator context error: ${_cli_err}" \
            "claude -p returned context-limit error. Prompt was ${_bytes} bytes.
Branch diff stat:
${_branch_stat}"
        return 1
    fi

    # Guard: if claude -p returned nothing, surface a diagnostic rather than silently failing.
    local dod_log_bytes
    dod_log_bytes="$(wc -c < "$dod_log" 2>/dev/null || echo "0")"
    dod_log_bytes="${dod_log_bytes// /}"
    if [[ ! -s "$dod_log" ]] || [[ "$dod_log_bytes" -le 2 ]]; then
        warn "DoD: claude -p returned empty output (exit_code=${dod_exit_code}) — check CLI flags and model availability"
        warn "DoD log: $dod_log (${dod_log_bytes} bytes), stderr: $dod_err_log"
        QUALITY_GATE_DETAIL="${QUALITY_GATE_DETAIL}
### Definition of Done — evaluator failure
The DoD evaluator returned no usable response (exit_code=${dod_exit_code}). The DoD content was:
$(head -20 "$DOD_FILE" 2>/dev/null | sed 's/^/  /' || true)"
        return 1
    fi

    # Strip markdown fences and delimiter lines before jq parsing.
    local dod_clean="${dod_log%.log}-clean.json"
    sed -E '/^```(json)?[[:space:]]*$|^<<<DOD:(PASS|FAIL)>>>[[:space:]]*$/d' "$dod_log" > "$dod_clean" 2>/dev/null || cp "$dod_log" "$dod_clean"

    # Parse structured JSON output: verdict field must be "pass"
    local dod_verdict
    dod_verdict="$(jq -r '.verdict // empty' "$dod_clean" 2>/dev/null || echo "")"

    # Structural validation: a pass verdict without a populated items array means the
    # model skipped the per-item checklist evaluation — reject it as incomplete.
    if [[ "$dod_verdict" == "pass" ]]; then
        local dod_item_count
        dod_item_count="$(jq 'if (.items | type) == "array" then (.items | length) else 0 end' "$dod_clean" 2>/dev/null || echo "0")"
        dod_item_count="${dod_item_count// /}"
        if [[ "${dod_item_count:-0}" -eq 0 ]]; then
            warn "DoD: verdict is pass but items array is missing, not an array, or empty — treating as fail"
            return 1
        fi
        echo -e "  ${GREEN}✓${RESET} Definition of Done: satisfied"
        # Log summary for diagnostics
        local dod_summary
        dod_summary="$(jq -r '.summary // ""' "$dod_clean" 2>/dev/null || echo "")"
        [[ -n "$dod_summary" ]] && info "  DoD summary: $dod_summary"
        record_gate_finding "dod" "pass" "" ""
        return 0
    else
        echo -e "  ${YELLOW}⚠${RESET} Definition of Done: not satisfied"
        # Surface failing items for diagnostics
        jq -r '.items[] | select(.satisfied == false) | "  - \(.item): " + (.reason // "not satisfied")' "$dod_clean" 2>/dev/null || true

        # Determine items array health for branched diagnostics
        local dod_items_type dod_items_len dod_unsatisfied_count
        dod_items_type="$(jq -r '(.items | type)' "$dod_clean" 2>/dev/null || echo "unknown")"
        dod_items_len="$(jq '(if (.items | type) == "array" then (.items | length) else 0 end)' "$dod_clean" 2>/dev/null || echo "0")"
        dod_unsatisfied_count="$(jq '(if (.items | type) == "array" then ([.items[] | select(.satisfied == false)] | length) else 0 end)' "$dod_clean" 2>/dev/null || echo "0")"
        dod_unsatisfied_count="${dod_unsatisfied_count// /}"
        dod_items_len="${dod_items_len// /}"

        local _dod_detail _dod_summary
        _dod_summary="$(jq -r '.summary // ""' "$dod_clean" 2>/dev/null || echo "")"

        if [[ -z "$dod_verdict" ]]; then
            # JSON was unparseable — most valuable case: tells agent the harness is broken
            _dod_detail="DoD evaluator output was unparseable JSON. Raw response (first 20 lines):
$(head -20 "$dod_clean" 2>/dev/null | sed 's/^/  /' || echo "  (no content)")"
        elif [[ "$dod_items_type" != "array" ]]; then
            _dod_detail="DoD evaluator reported fail but .items was missing or not an array (type: ${dod_items_type}). Summary: ${_dod_summary:-none}"
        elif [[ "${dod_items_len:-0}" -eq 0 ]]; then
            _dod_detail="DoD evaluator reported fail but .items was an empty array — likely a per-item evaluation skip. Summary: ${_dod_summary:-none}"
        elif [[ "${dod_unsatisfied_count:-0}" -eq 0 ]]; then
            _dod_detail="DoD evaluator reported fail but all .items were marked satisfied — likely model inconsistency. Summary: ${_dod_summary:-none}"
        else
            # Rich detail path: has real unsatisfied items
            # Extract optional file:hint details for next-iteration prompt injection.
            # Uses null-safe // [] so missing "files" field does not cause jq errors.
            _dod_detail="$(jq -r '
              .items[] | select(.satisfied == false) |
              "- " + .item + "\n" +
              (if ((.files | type) == "array") and ((.files | length) > 0) then "  Files: " + (.files | join(", ")) + "\n" else "" end) +
              (if .hint then "  Fix: " + .hint else "" end)
            ' "$dod_clean" 2>/dev/null | head -20 || true)"
            # Minimal fallback if rich detail somehow still empty (schema drift guard)
            if [[ -z "$_dod_detail" ]]; then
                _dod_detail="$(jq -r '.items[] | select(.satisfied == false) | "- " + .item' "$dod_clean" 2>/dev/null | head -20 || true)"
            fi
        fi

        record_gate_finding "dod" "fail" "${_dod_summary}" "${_dod_detail}"
        # Fallback: only when jq parse failed (dod_verdict empty) — not when jq returned "fail".
        # Without this guard, prose in a legitimately-parsed "fail" summary (e.g. "all requirements
        # are now satisfied") could match the legacy pattern and incorrectly flip the verdict to pass.
        if [[ -z "$dod_verdict" ]] && detect_gate_signal "$dod_log" "DOD" \
            'DOD_PASS|all.{0,20}satisfied|"verdict"[[:space:]]*:[[:space:]]*"pass"' \
            '"satisfied"[[:space:]]*:[[:space:]]*false|not satisfied|<<<DOD:FAIL>>>'; then
            warn "  DoD JSON parse failed but detected pass signal in raw output — accepting"
            return 0
        fi
        return 1
    fi
}

# ─── Guarded Completion ──────────────────────────────────────────────────────

guard_completion() {
    local log_file="$LOG_DIR/iteration-${ITERATION}.log"

    # Check if agent signaled completion
    if ! detect_gate_signal "$log_file" "LOOP" \
        'LOOP_COMPLETE' \
        '<<<LOOP:FAIL>>>'; then
        return 1  # No completion claim
    fi

    echo -e "  ${CYAN}▸${RESET} Completion signal detected — validating..."

    local rejection_reasons=()

    # Check quality gates
    if ! $QUALITY_GATE_PASSED; then
        rejection_reasons+=("quality gates failed")
    fi

    # Check audit agent
    if $AUDIT_AGENT_ENABLED && [[ "$AUDIT_RESULT" != "pass" ]]; then
        rejection_reasons+=("audit agent found issues")
    fi

    # Check tests
    if [[ -n "$TEST_CMD" ]] && [[ "$TEST_PASSED" == "false" ]]; then
        rejection_reasons+=("tests failing")
    fi

    # Holistic final gate: when all other gates pass, run a project-level assessment
    # that evaluates the entire codebase against the goal (not just the latest diff)
    if [[ ${#rejection_reasons[@]} -eq 0 ]]; then
        type _emit_inner_stage_event >/dev/null 2>&1 && _emit_inner_stage_event "inner" "build" "holistic_start" "Holistic gate check"
        if ! run_holistic_gate; then
            rejection_reasons+=("holistic project assessment found gaps")
        fi
    fi

    if [[ ${#rejection_reasons[@]} -gt 0 ]]; then
        local reasons_str
        reasons_str="$(printf ', %s' "${rejection_reasons[@]}")"
        reasons_str="${reasons_str:2}"
        echo -e "  ${RED}✗${RESET} Completion REJECTED: ${reasons_str}"
        COMPLETION_REJECTED=true
        return 1
    fi

    echo -e "  ${GREEN}${BOLD}✓ LOOP_COMPLETE accepted — all gates passed!${RESET}"
    return 0
}

# Holistic gate: evaluates the full project against the original goal.
# Only runs when all other gates pass (final checkpoint before acceptance).
run_holistic_gate() {
    # Skip if no starting commit (can't compute cumulative diff)
    [[ -z "${LOOP_START_COMMIT:-}" ]] && return 0

    local holistic_log="$LOG_DIR/holistic-iter-${ITERATION}.log"

    # Build a project summary: file tree, test count, cumulative diff stats
    local file_count
    file_count=$(git -C "$PROJECT_ROOT" ls-files | wc -l | tr -d ' ')
    local cumulative_stat
    cumulative_stat="$(git -C "$PROJECT_ROOT" diff --stat "${LOOP_START_COMMIT}..HEAD" -- . $(_git_excluded_pathspecs) 2>/dev/null | tail -1 || echo "(no changes)")"
    local merge_base branch_stat branch_diff
    type _ensure_base_branch_ref >/dev/null 2>&1 && { _ensure_base_branch_ref || true; }
    merge_base="$(_git_branch_merge_base)"
    if [[ -n "$merge_base" ]]; then
        branch_stat="$(git -C "$PROJECT_ROOT" diff --stat "${merge_base}..HEAD" -- . $(_git_excluded_pathspecs) 2>/dev/null | head -40 || echo "(none)")"
        # Cap diff and sanitize gate delimiter tokens to prevent prompt injection
        # via diff content that happens to contain <<<HOLISTIC:PASS>>> or similar strings.
        branch_diff="$(git -C "$PROJECT_ROOT" diff "${merge_base}..HEAD" -- . $(_git_excluded_pathspecs) 2>/dev/null \
            | head -"${HOLISTIC_DIFF_MAX_LINES}" \
            | sed 's/<<<HOLISTIC:PASS>>>/[REDACTED:HOLISTIC:PASS]/g; s/<<<HOLISTIC:FAIL>>>/[REDACTED:HOLISTIC:FAIL]/g' \
            || echo "(none)")"
    else
        branch_stat="(unable to determine base)"
        branch_diff="(unable to determine base)"
    fi
    local test_summary=""
    if [[ -n "${TEST_OUTPUT:-}" ]]; then
        test_summary="$(echo "$TEST_OUTPUT" | tail -5)"
    fi

    # Context-aware goal selection: compound_quality appends findings to GOAL so the
    # rebuild agent knows what to address — use it directly. In standalone loop runs,
    # GOAL accumulates iteration feedback that can poison the holistic assessment, so
    # prefer ORIGINAL_GOAL when available (fixes issue #345 non-regression).
    local _holistic_judge_goal="$GOAL"
    if [[ "${OUTER_STAGE:-}" != "compound_quality" && -n "${ORIGINAL_GOAL:-}" ]]; then
        _holistic_judge_goal="$ORIGINAL_GOAL"
    fi

    local holistic_prompt
    read -r -d '' holistic_prompt <<HOLISTIC_PROMPT || true
You are a final quality gate evaluating whether an autonomous coding agent has FULLY achieved its goal.

## Original Goal
${_holistic_judge_goal}

## Project Stats
- Files in repo: ${file_count}
- Iterations completed: ${ITERATION}
- Loop-run changes: ${cumulative_stat}
- Tests: ${TEST_PASSED:-unknown} (command: ${TEST_CMD:-none})
${test_summary:+- Test output: ${test_summary}}

## Cumulative Git Changes (this loop run only)
$(git -C "$PROJECT_ROOT" diff --stat "${LOOP_START_COMMIT}..HEAD" 2>/dev/null | head -40 || echo "(none — loop may have started after feature was committed)")

## Full Branch Changes vs Base — Stats (authoritative — use this to evaluate goal completion)
${branch_stat}

NOTE: If the loop was restarted after prior work, "this loop run" may show only minor fixes
while "full branch" shows the complete feature. Use the full branch diff to judge goal achievement.

## Full Branch Diff (first 300 lines — may be truncated; rely on stats above for files not shown)
${branch_diff}

## Evaluation Rules
- Default to FAIL. Only output PASS if you are certain every component of the goal is complete.
- Partial completion is FAIL. Gaps in test coverage for new behavior are FAIL.
- If the diff is truncated, use the stats section above to assess files not shown; do not FAIL solely due to truncation.

## Your Task
For each distinct component of the goal, explicitly state whether it is complete or missing.
Then answer:
1. Is EVERY component of the goal fully achieved — not partially?
2. Is there any gap that would make this unacceptable for production?

If the goal is fully achieved, output your verdict on its own line as:
  <<<HOLISTIC:PASS>>>
If there are gaps remaining, list them and then output on its own line:
  <<<HOLISTIC:FAIL>>>
Do not wrap the verdict in JSON, markdown, or code blocks.
HOLISTIC_PROMPT

    echo -e "  ${PURPLE}▸${RESET} Running holistic project assessment..."

    local hol_model
    hol_model="$(select_audit_model)"
    local hol_flags=("--model" "$hol_model")
    hol_flags+=("--disallowed-tools" "EnterPlanMode,ExitPlanMode")
    if $SKIP_PERMISSIONS; then
        hol_flags+=("--dangerously-skip-permissions")
    fi

    local holistic_stderr_log="${holistic_log%.log}-stderr.log"
    local holistic_exit_code=0
    # Pipe prompt via stdin to bypass exec ARG_MAX (see audit/DoD invocations).
    printf '%s' "$holistic_prompt" | claude -p "${hol_flags[@]}" > "$holistic_log" 2>"$holistic_stderr_log" &
    CHILD_PID=$!
    wait "$CHILD_PID" 2>/dev/null || holistic_exit_code=$?
    CHILD_PID=""

    if [[ ! -s "$holistic_log" ]] || ! grep -q '[^[:space:]]' "$holistic_log"; then
        warn "  Holistic: empty response from evaluator (exit_code=${holistic_exit_code}) — treating as fail"
        return 1
    fi

    if detect_gate_signal "$holistic_log" "HOLISTIC" \
        'HOLISTIC_PASS|"verdict"[[:space:]]*:[[:space:]]*"pass"' \
        '<<<HOLISTIC:FAIL>>>'; then
        echo -e "  ${GREEN}✓${RESET} Holistic assessment: passed"
        HOLISTIC_RESULT="pass"
        record_gate_finding "holistic" "pass" "" ""
        return 0
    else
        echo -e "  ${YELLOW}⚠${RESET} Holistic assessment: gaps found"
        HOLISTIC_RESULT="$(grep -v '^$' "$holistic_log" | tail -20 | head -10 2>/dev/null || echo "Holistic assessment found gaps")"
        record_gate_finding "holistic" "fail" "holistic assessment found gaps" "$HOLISTIC_RESULT"
        return 1
    fi
}

# ─── Context Window Management ───────────────────────────────────────────────

# ─── Prompt Composition ──────────────────────────────────────────────────────
# NOTE: compose_prompt() is now in lib/loop-iteration.sh (extracted upstream)

# ─── Alternative Strategy Exploration ─────────────────────────────────────────
# When stuckness is detected, generate a context-aware alternative strategy.
# Uses pattern matching on error type + iteration count to suggest different approaches.


# ─── Stuckness Detection ─────────────────────────────────────────────────────
# Multi-signal detection: text overlap, git diff hash, error repetition, exit code pattern, iteration budget.
# Returns 0 when stuck, 1 when not. Outputs stuckness section and sets STUCKNESS_HINT when stuck.
# When stuck: increments STUCKNESS_COUNT, emits event; if STUCKNESS_COUNT >= 3, caller triggers session restart.
STUCKNESS_COUNT=0
STUCKNESS_TRACKING_FILE=""



compose_audit_section() {
    if ! $AUDIT_ENABLED; then
        return
    fi

    # Try to inject audit items from past review feedback in memory
    local memory_audit_items=""
    if [[ -f "$SCRIPT_DIR/sw-memory.sh" ]]; then
        local mem_dir_path
        mem_dir_path="$HOME/.shipwright/memory"
        # Look for review feedback in any repo memory
        local repo_hash_val
        repo_hash_val=$(git config --get remote.origin.url 2>/dev/null | shasum -a 256 2>/dev/null | cut -c1-12 || echo "")
        if [[ -n "$repo_hash_val" && -f "$mem_dir_path/$repo_hash_val/failures.json" ]]; then
            memory_audit_items=$(jq -r '.failures[] | select(.stage == "review" and .pattern != "") |
                "- Check for: \(.pattern[:100])"' \
                "$mem_dir_path/$repo_hash_val/failures.json" 2>/dev/null | head -5 || true)
        fi
    fi

    echo "## Self-Audit Checklist"
    echo "Before declaring <<<LOOP:PASS>>>, critically evaluate your own work:"
    echo "1. Does the implementation FULLY satisfy the goal, not just partially?"
    echo "2. Are there any edge cases you haven't handled?"
    echo "3. Did you leave any TODO, FIXME, HACK, or XXX comments in new code?"
    echo "4. Are all new functions/modules tested (if a test command exists)?"
    echo "5. Would a code reviewer approve this, or would they request changes?"
    echo "6. Is the code clean, well-structured, and following project conventions?"
    if [[ -n "$memory_audit_items" ]]; then
        echo ""
        echo "Common review findings from this repo's history:"
        echo "$memory_audit_items"
    fi
    echo ""
    echo "If ANY answer is \"no\", do NOT output <<<LOOP:PASS>>>. Instead, fix the issues first."
}

compose_gate_findings_section() {
    local _passed="${GATE_PASSED_NAMES# }"
    local _failed="${GATE_FINDINGS:-}"
    [[ -z "$_passed" && -z "$_failed" ]] && return
    echo "## Quality Gate Results — Previous Iteration"
    echo ""
    if [[ -n "$_passed" ]]; then
        echo "**Passed:** ${_passed// /, }"
        echo ""
    fi
    if [[ -n "$_failed" ]]; then
        echo "**⚠ Findings — Address all items below before signalling completion. Multiple gates may have failed simultaneously.**"
        echo "${_failed}"
    fi
}

# Legacy delegates — kept for back-compat; return empty because compose_gate_findings_section
# now renders all gate content, and loop-iteration.sh calls gate_findings_section directly.
# Callers that still invoke these by name get no output (no duplication).
compose_audit_feedback_section()       { return 0; }
compose_holistic_feedback_section()    { return 0; }
compose_quality_gate_detail_section()  { return 0; }

compose_rejection_notice_section() {
    if $COMPLETION_REJECTED; then
        local _reasons="${QUALITY_GATE_REASONS:-}"
        local _failed_line=""
        [[ -n "$_reasons" ]] && _failed_line="
Failed: ${_reasons}"
        cat <<REJECTION
## ⚠ Completion Rejected${_failed_line}
Your previous <<<LOOP:PASS>>> was REJECTED.
Fix the issues and test, then try again.
Do NOT output <<<LOOP:PASS>>> until all quality checks pass.
REJECTION
    elif [[ "${GATES_PASSED_NO_SIGNAL:-false}" == "true" ]]; then
        cat <<'GATES_PASSED'
## ✓ Quality Gates Passed
All configured quality gates (tests, uncommitted changes, DoD) passed on the previous iteration. If the goal is fully achieved and any audit issues above are addressed, output <<<LOOP:PASS>>> to finish the loop.
GATES_PASSED
    elif ! ${QUALITY_GATE_PASSED:-true}; then
        local _reasons="${QUALITY_GATE_REASONS:-quality checks}"
        echo "## ⚠ Quality Gates Not Passing"
        echo "Failed: ${_reasons}"
        echo "Review the findings section above and fix all issues before signalling completion."
        echo "Do NOT output <<<LOOP:PASS>>> until all quality checks pass."
    fi
}

compose_worker_prompt() {
    local agent_num="$1"
    local total_agents="$2"

    local base_prompt
    base_prompt="$(compose_prompt)"

    # Role-specific instructions
    local role_section=""
    if [[ -n "$AGENT_ROLES" ]] && [[ "${agent_num:-0}" -ge 1 ]]; then
        # Split comma-separated roles and get role for this agent
        local role=""
        local IFS_BAK="$IFS"
        IFS=',' read -ra _roles <<< "$AGENT_ROLES"
        IFS="$IFS_BAK"
        if [[ "$agent_num" -le "${#_roles[@]}" ]]; then
            role="${_roles[$((agent_num - 1))]}"
            # Trim whitespace and skip empty roles (handles trailing comma)
            role="$(echo "$role" | tr -d ' ')"
        fi

        if [[ -n "$role" ]]; then
            local role_desc=""
            # Try to pull description from recruit's roles DB first
            local recruit_roles_db="${HOME}/.shipwright/recruitment/roles.json"
            if [[ -f "$recruit_roles_db" ]] && command -v jq >/dev/null 2>&1; then
                local recruit_desc
                recruit_desc=$(jq -r --arg r "$role" '.[$r].description // ""' "$recruit_roles_db" 2>/dev/null) || true
                if [[ -n "$recruit_desc" && "$recruit_desc" != "null" ]]; then
                    role_desc="$recruit_desc"
                fi
            fi
            # Fallback to built-in role descriptions
            if [[ -z "$role_desc" ]]; then
                case "$role" in
                    builder)   role_desc="Focus on implementation — writing code, fixing bugs, building features. You are the primary builder." ;;
                    reviewer)  role_desc="Focus on code review — look for bugs, security issues, edge cases in recent commits. Make fixes via commits." ;;
                    tester)    role_desc="Focus on test coverage — write new tests, fix failing tests, improve assertions and edge case coverage." ;;
                    optimizer) role_desc="Focus on performance — profile hot paths, reduce complexity, optimize algorithms and data structures." ;;
                    docs|docs-writer) role_desc="Focus on documentation — update README, add docstrings, write usage guides for new features." ;;
                    security|security-auditor) role_desc="Focus on security — audit for vulnerabilities, fix injection risks, validate inputs, check auth boundaries." ;;
                    *)         role_desc="Focus on: ${role}. Apply your expertise in this area to advance the goal." ;;
                esac
            fi
            role_section="## Your Role: ${role}
${role_desc}
Prioritize work in your area of expertise. Coordinate with other agents via git log."
        fi
    fi

    cat <<PROMPT
${base_prompt}

## Agent Identity
You are Agent ${agent_num} of ${total_agents}. Other agents are working in parallel.
Check git log to see what they've done — avoid duplicating their work.
Focus on areas they haven't touched yet.

${role_section}
PROMPT
}

# ─── Claude Execution ────────────────────────────────────────────────────────



# ─── Iteration Summary Extraction ────────────────────────────────────────────


# ─── Display Helpers ─────────────────────────────────────────────────────────

show_banner() {
    echo ""
    echo -e "${CYAN}${BOLD}shipwright${RESET} ${DIM}v${VERSION}${RESET} — ${BOLD}Continuous Loop${RESET}"
    echo -e "${CYAN}═══════════════════════════════════════════════${RESET}"
    echo ""
    echo -e "  ${BOLD}Goal:${RESET}  $GOAL"
    local extend_info=""
    if $AUTO_EXTEND; then
        extend_info=" ${DIM}(auto-extend: +${EXTENSION_SIZE} x${MAX_EXTENSIONS})${RESET}"
    fi
    echo -e "  ${BOLD}Model:${RESET} $MODEL ${DIM}|${RESET} ${BOLD}Max:${RESET} $MAX_ITERATIONS iterations${extend_info} ${DIM}|${RESET} ${BOLD}Test:${RESET} ${TEST_CMD:-"(none)"}"
    if [[ "$AGENTS" -gt 1 ]]; then
        echo -e "  ${BOLD}Agents:${RESET} $AGENTS ${DIM}(parallel worktree mode)${RESET}"
    fi
    if $SKIP_PERMISSIONS; then
        echo -e "  ${YELLOW}${BOLD}⚠${RESET}  ${YELLOW}--dangerously-skip-permissions enabled${RESET}"
    fi
    if $AUDIT_ENABLED || $AUDIT_AGENT_ENABLED || $QUALITY_GATES_ENABLED; then
        echo -e "  ${BOLD}Audit:${RESET} ${AUDIT_ENABLED:+self-audit }${AUDIT_AGENT_ENABLED:+audit-agent }${QUALITY_GATES_ENABLED:+quality-gates}${DIM}${DOD_FILE:+ | DoD: $DOD_FILE}${RESET}"
    fi
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}

show_summary() {
    local end_epoch
    end_epoch="$(now_epoch)"
    local duration=$(( end_epoch - START_EPOCH ))

    local status_display
    case "$STATUS" in
        complete)         status_display="${GREEN}✓ Complete (<<<LOOP:PASS>>> accepted)${RESET}" ;;
        circuit_breaker)  status_display="${RED}✗ Circuit breaker tripped${RESET}" ;;
        max_iterations)   status_display="${YELLOW}⚠ Max iterations reached${RESET}" ;;
        budget_exhausted) status_display="${RED}✗ Budget exhausted${RESET}" ;;
        interrupted)      status_display="${YELLOW}⚠ Interrupted by user${RESET}" ;;
        error)            status_display="${RED}✗ Error${RESET}" ;;
        stuck)            status_display="${RED}✗ Stuck (no progress — loop terminated)${RESET}" ;;
        stuck_restart)    status_display="${YELLOW}⚠ Stuck — restarting session${RESET}" ;;
        *)                status_display="${DIM}$STATUS${RESET}" ;;
    esac

    local test_display
    if [[ -z "$TEST_CMD" ]]; then
        test_display="${DIM}No tests configured${RESET}"
    elif [[ "$TEST_PASSED" == "true" ]]; then
        test_display="${GREEN}All passing${RESET}"
    elif [[ "$TEST_PASSED" == "false" ]]; then
        test_display="${RED}Failing${RESET}"
    else
        test_display="${DIM}Not run${RESET}"
    fi

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    local status_upper
    status_upper="$(echo "$STATUS" | tr '[:lower:]' '[:upper:]')"
    echo -e "  ${BOLD}LOOP ${status_upper}${RESET}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
    echo -e "  ${BOLD}Goal:${RESET}        $GOAL"
    echo -e "  ${BOLD}Status:${RESET}      $status_display"
    local ext_suffix=""
    [[ "$EXTENSION_COUNT" -gt 0 ]] && ext_suffix=" ${DIM}(${EXTENSION_COUNT} extensions)${RESET}"
    echo -e "  ${BOLD}Iterations:${RESET}  $ITERATION/$MAX_ITERATIONS${ext_suffix}"
    echo -e "  ${BOLD}Duration:${RESET}    $(format_duration "$duration")"
    echo -e "  ${BOLD}Commits:${RESET}     $TOTAL_COMMITS"
    echo -e "  ${BOLD}Tests:${RESET}       $test_display"
    if [[ "$LOOP_INPUT_TOKENS" -gt 0 || "$LOOP_OUTPUT_TOKENS" -gt 0 ]]; then
        echo -e "  ${BOLD}Tokens:${RESET}      in=${LOOP_INPUT_TOKENS} out=${LOOP_OUTPUT_TOKENS}"
    fi
    echo ""
    echo -e "  ${DIM}State: $STATE_FILE${RESET}"
    echo -e "  ${DIM}Logs:  $LOG_DIR/${RESET}"
    echo ""

    # Write token totals for pipeline cost tracking
    write_loop_tokens
}

# ─── Signal Handling ──────────────────────────────────────────────────────────

CHILD_PID=""
_MEM_ANALYZE_PID=""
_CLEANUP_DONE=false
EXIT_CODE=""

cleanup() {
    # Guard against recursive invocation (EXIT trap fires after signal trap's exit call)
    [[ "${_CLEANUP_DONE:-false}" == "true" ]] && return 0
    _CLEANUP_DONE=true

    # Kill background memory analysis job if running
    [[ -n "${_MEM_ANALYZE_PID:-}" ]] && kill "$_MEM_ANALYZE_PID" 2>/dev/null || true

    # Kill any running Claude process
    if [[ -n "$CHILD_PID" ]] && kill -0 "$CHILD_PID" 2>/dev/null; then
        kill "$CHILD_PID" 2>/dev/null || true
        wait "$CHILD_PID" 2>/dev/null || true
    fi

    # If multi-agent, kill worker panes
    if [[ "$AGENTS" -gt 1 ]]; then
        cleanup_multi_agent
    fi

    # Reap child process trees (Claude Node workers, tool subprocesses that escape
    # a shallow pkill -P $$). Targeting children only — sending SIGTERM to $$
    # itself would re-trigger the SIGTERM trap and set EXIT_CODE=130 on clean exits.
    local _lc_child
    while IFS= read -r _lc_child; do
        [[ -n "$_lc_child" ]] || continue
        if declare -f _kill_process_tree >/dev/null 2>&1; then
            _kill_process_tree TERM "$_lc_child" 2>/dev/null || true
        else
            kill "$_lc_child" 2>/dev/null || true
        fi
    done < <(pgrep -P $$ 2>/dev/null || true)
    sleep 1
    while IFS= read -r _lc_child; do
        [[ -n "$_lc_child" ]] || continue
        if declare -f _kill_process_tree >/dev/null 2>&1; then
            _kill_process_tree KILL "$_lc_child" 2>/dev/null || true
        else
            kill -9 "$_lc_child" 2>/dev/null || true
        fi
    done < <(pgrep -P $$ 2>/dev/null || true)
    wait 2>/dev/null || true

    # Clear heartbeat (always — whether signal-driven or not)
    "$SCRIPT_DIR/sw-heartbeat.sh" clear "${PIPELINE_JOB_ID:-loop-$$}" 2>/dev/null || true

    # Interruption-specific: only when EXIT_CODE is set (SIGINT/SIGTERM triggered this)
    if [[ -n "${EXIT_CODE:-}" ]]; then
        echo ""
        warn "Loop interrupted at iteration $ITERATION"

        STATUS="interrupted"
        write_state

        # Save checkpoint for resume
        "$SCRIPT_DIR/sw-checkpoint.sh" save \
            --stage "build" \
            --iteration "$ITERATION" \
            --git-sha "$(git rev-parse HEAD 2>/dev/null || echo unknown)" 2>/dev/null || true

        # Save Claude context for meaningful resume (goal, findings, test output)
        export SW_LOOP_GOAL="$GOAL"
        export SW_LOOP_ITERATION="$ITERATION"
        export SW_LOOP_STATUS="$STATUS"
        export SW_LOOP_TEST_OUTPUT="${TEST_OUTPUT:-}"
        export SW_LOOP_FINDINGS="${LOG_ENTRIES:-}"
        # shellcheck disable=SC2155
        export SW_LOOP_MODIFIED="$(git diff --name-only HEAD 2>/dev/null | head -50 | tr '\n' ',' | sed 's/,$//')"
        "$SCRIPT_DIR/sw-checkpoint.sh" save-context --stage build 2>/dev/null || true

        show_summary
        exit "$EXIT_CODE"
    fi
    # For EXIT-trap-driven exits (errors, normal returns), let the shell exit
    # naturally with whatever code triggered the exit.
}

trap 'EXIT_CODE=130; cleanup' SIGINT SIGTERM
trap cleanup EXIT

# ─── Multi-Agent: Worktree Setup ─────────────────────────────────────────────

setup_worktrees() {
    local branch_base="loop"
    mkdir -p "$WORKTREE_DIR"

    for i in $(seq 1 "$AGENTS"); do
        local wt_path="$WORKTREE_DIR/agent-${i}"
        local branch_name="${branch_base}/agent-${i}"

        if [[ -d "$wt_path" ]]; then
            info "Worktree agent-${i} already exists"
            continue
        fi

        # Create branch if it doesn't exist
        if ! git -C "$PROJECT_ROOT" rev-parse --verify "$branch_name" >/dev/null 2>&1; then
            git -C "$PROJECT_ROOT" branch "$branch_name" HEAD 2>/dev/null || true
        fi

        git -C "$PROJECT_ROOT" worktree add "$wt_path" "$branch_name" 2>/dev/null || {
            error "Failed to create worktree for agent-${i}"
            return 1
        }

        success "Worktree: agent-${i} → $wt_path"
    done
}

cleanup_worktrees() {
    for i in $(seq 1 "$AGENTS"); do
        local wt_path="$WORKTREE_DIR/agent-${i}"
        if [[ -d "$wt_path" ]]; then
            git -C "$PROJECT_ROOT" worktree remove --force "$wt_path" 2>/dev/null || true
        fi
    done
    rmdir "$WORKTREE_DIR" 2>/dev/null || true
}

# ─── Multi-Agent: Worker Loop Script ─────────────────────────────────────────

generate_worker_script() {
    local agent_num="$1"
    local total_agents="$2"
    local wt_path="$WORKTREE_DIR/agent-${agent_num}"
    local worker_script="$LOG_DIR/worker-${agent_num}.sh"

    local claude_flags
    claude_flags="$(build_claude_flags)"

    cat > "$worker_script" <<'WORKEREOF'
#!/usr/bin/env bash
set -euo pipefail

AGENT_NUM="__AGENT_NUM__"
TOTAL_AGENTS="__TOTAL_AGENTS__"
WORK_DIR="__WORK_DIR__"
LOG_DIR="__LOG_DIR__"
MAX_ITERATIONS="__MAX_ITERATIONS__"
GOAL="__GOAL__"
TEST_CMD="__TEST_CMD__"
CLAUDE_FLAGS="__CLAUDE_FLAGS__"

CYAN='\033[38;2;0;212;255m'
GREEN='\033[38;2;74;222;128m'
YELLOW='\033[38;2;250;204;21m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

cd "$WORK_DIR"
ITERATION=0
CONSECUTIVE_FAILURES=0
CONSECUTIVE_NOOP=0

echo -e "${CYAN}${BOLD}▸${RESET} Agent ${AGENT_NUM}/${TOTAL_AGENTS} starting in ${WORK_DIR}"

while [[ "$ITERATION" -lt "$MAX_ITERATIONS" ]]; do
    # Budget gate: stop if daily budget exhausted
    if [[ -x "$SCRIPT_DIR/sw-cost.sh" ]]; then
        budget_remaining=$("$SCRIPT_DIR/sw-cost.sh" remaining-budget 2>/dev/null || echo "")
        if [[ -n "$budget_remaining" && "$budget_remaining" != "unlimited" ]]; then
            if awk -v r="$budget_remaining" 'BEGIN { exit !(r <= 0) }' 2>/dev/null; then
                echo -e "  ${RED}✗${RESET} Budget exhausted (\$${budget_remaining}) — stopping agent ${AGENT_NUM}"
                break
            fi
        fi
    fi

    ITERATION=$(( ITERATION + 1 ))
    _iter_start=$(date +%s 2>/dev/null || echo 0)
    echo -e "\n${CYAN}${BOLD}▸${RESET} Agent ${AGENT_NUM} — Iteration ${ITERATION}/${MAX_ITERATIONS}"

    # Pull latest from other agents
    git fetch origin main 2>/dev/null && git merge origin/main --no-edit 2>/dev/null || true

    # Build prompt
    GIT_LOG="$(git log --oneline -20 2>/dev/null || echo '(no commits)')"
    TEST_SECTION="No test results yet."
    if [[ -n "$TEST_CMD" ]]; then
        TEST_SECTION="Test command: $TEST_CMD"
    fi

    PROMPT="$(cat <<PROMPT
You are an autonomous coding agent on iteration ${ITERATION}/${MAX_ITERATIONS} of a continuous loop.

## Your Goal
${GOAL}

## Recent Git Activity
${GIT_LOG}

## Test Results
${TEST_SECTION}

## Agent Identity
You are Agent ${AGENT_NUM} of ${TOTAL_AGENTS}. Other agents are working in parallel.
Check git log to see what they've done — avoid duplicating their work.
Focus on areas they haven't touched yet.

## Instructions
1. Read the codebase and understand the current state
2. Identify the highest-priority remaining work toward the goal
3. Implement ONE meaningful chunk of progress
4. Commit your work with a descriptive message
5. When the goal is FULLY achieved, output exactly on its own line: <<<LOOP:PASS>>>

## Rules
- Focus on ONE task per iteration — do it well
- Always commit with descriptive messages
- If stuck on the same issue for 2+ iterations, try a different approach
- Do NOT output <<<LOOP:PASS>>> unless the goal is genuinely achieved
PROMPT
)"

    # Capture commit count AND HEAD SHA before Claude runs so delta is iteration-scoped.
    # C4: _iter_start_sha replaces HEAD@{1} (reflog-relative — wrong when HEAD didn't move).
    local _commits_before _commits_after _new_commits _iter_start_sha
    _commits_before=$(git rev-list --count HEAD 2>/dev/null || echo 0)
    _iter_start_sha=$(git rev-parse HEAD 2>/dev/null || echo "")

    # Run Claude (output is JSON due to --output-format json in CLAUDE_FLAGS)
    local JSON_FILE="$LOG_DIR/agent-${AGENT_NUM}-iter-${ITERATION}.json"
    local ERR_FILE="$LOG_DIR/agent-${AGENT_NUM}-iter-${ITERATION}.stderr"
    LOG_FILE="$LOG_DIR/agent-${AGENT_NUM}-iter-${ITERATION}.log"
    # Pipe prompt via stdin (not as CLI arg) to bypass exec ARG_MAX. The
    # iteration prompt accumulates plan/design/historical context and routinely
    # exceeds 128KB. claude -p reads from stdin when no positional prompt is
    # given. See audit/DoD/holistic invocations for the same fix.
    # shellcheck disable=SC2086
    printf '%s' "$PROMPT" | claude -p $CLAUDE_FLAGS > "$JSON_FILE" 2>"$ERR_FILE" || true

    # Extract text result from JSON into .log for backwards compat
    _extract_text_from_json "$JSON_FILE" "$LOG_FILE" "$ERR_FILE"

    echo -e "  ${GREEN}✓${RESET} Claude session completed"

    # Check completion
    if detect_gate_signal "$LOG_FILE" "LOOP" \
        'LOOP_COMPLETE' \
        '<<<LOOP:FAIL>>>'; then
        echo -e "  ${GREEN}${BOLD}✓ Completion signal detected!${RESET}"
        # Signal completion
        touch "$LOG_DIR/.agent-${AGENT_NUM}-complete"
        break
    fi

    # Auto-commit
    safe_git_stage
    if git commit -m "agent-${AGENT_NUM}: iteration ${ITERATION}" --no-verify 2>/dev/null; then
        _loop_pat_slug=""
        if [[ -n "${GITHUBTOKEN:-}" ]]; then
            _loop_pat_slug=$(git remote get-url origin 2>/dev/null | sed 's|.*github\.com[:/]||;s|\.git$||')
            git config --unset-all "http.https://github.com/.extraheader" 2>/dev/null || true
            git remote set-url origin "https://x-access-token:${GITHUBTOKEN}@github.com/${_loop_pat_slug}.git" 2>/dev/null || true
        fi
        if ! git push origin "loop/agent-${AGENT_NUM}" 2>/dev/null; then
            echo -e "  ${YELLOW}⚠${RESET} git push failed for loop/agent-${AGENT_NUM} — remote may be out of sync"
            type emit_event >/dev/null 2>&1 && emit_event "loop.push_failed" "branch=loop/agent-${AGENT_NUM}"
        else
            echo -e "  ${GREEN}✓${RESET} Committed and pushed"
        fi
        if [[ -n "${_loop_pat_slug:-}" ]]; then
            git remote set-url origin "https://github.com/${_loop_pat_slug}.git" 2>/dev/null || true
        fi
    fi
    _commits_after=$(git rev-list --count HEAD 2>/dev/null || echo 0)
    _new_commits=$(( _commits_after - _commits_before ))

    # Iteration elapsed time (set _iter_start at top of loop body)
    _iter_end=$(date +%s 2>/dev/null || echo 0)
    _iter_seconds=$(( _iter_end - ${_iter_start:-_iter_end} ))

    # No-op detection: track iterations with no meaningful progress
    # A "real" iteration requires: >=1 commit, OR (>=10 diff lines AND >=60s elapsed)
    # C4: compare against captured start SHA (not HEAD@{1} which is reflog-relative and
    # wrong if HEAD didn't move — would compare against a prior iteration's position).
    # awk: key-driven parser handles insertions-only/deletions-only --shortstat output
    # where positional $4/$6 fields vary.
    _diff_lines=0
    _diff_stat=""
    if [[ -n "${_iter_start_sha:-}" ]]; then
        _diff_stat=$(git diff --shortstat "${_iter_start_sha}" HEAD 2>/dev/null || true)
        _diff_lines=$(echo "$_diff_stat" \
            | awk '{ins=0;del=0; for(i=1;i<=NF;i++){if($i~/insert/)ins=$(i-1); if($i~/delet/)del=$(i-1)} print ins+del}' \
            | head -1 || echo "0")
    fi
    _diff_lines="${_diff_lines:-0}"
    # Guard: ensure numeric (strip whitespace/letters, default to 0)
    _diff_lines=$(echo "$_diff_lines" | tr -dc '0-9')
    [[ -z "$_diff_lines" ]] && _diff_lines=0
    # Guard: binary-only diffs produce "N files changed" with no insert/delet tokens.
    # awk yields 0 in that case, which false-positively looks like a no-op.
    # If shortstat output is non-empty (something changed) but awk found nothing, count it as 1.
    [[ "$_diff_lines" -eq 0 && -n "$_diff_stat" ]] && _diff_lines=1
    # Belt-and-suspenders: some git versions omit --shortstat entry for binary-only changes.
    if [[ "$_diff_lines" -eq 0 && -n "${_iter_start_sha:-}" ]]; then
        if git diff --stat "${_iter_start_sha}" HEAD 2>/dev/null | grep -q 'Bin'; then
            _diff_lines=1
        fi
    fi

    if [[ "$_new_commits" -gt 0 ]] || \
       { [[ "$_diff_lines" -ge 10 ]] && [[ "$_iter_seconds" -ge 60 ]]; }; then
        CONSECUTIVE_FAILURES=0
        CONSECUTIVE_NOOP=0
    else
        CONSECUTIVE_FAILURES=$(( CONSECUTIVE_FAILURES + 1 ))
        CONSECUTIVE_NOOP=$(( ${CONSECUTIVE_NOOP:-0} + 1 ))
        echo -e "  ${YELLOW}⚠${RESET} Low progress (${CONSECUTIVE_FAILURES}/3): ${_iter_seconds}s, ${_new_commits} commits, ${_diff_lines} diff lines"
    fi

    if [[ "${CONSECUTIVE_NOOP:-0}" -ge 2 ]]; then
        echo -e "  ${RED}✗${RESET} No-op abort: ${CONSECUTIVE_NOOP} consecutive no-op iterations (${_iter_seconds}s, ${_new_commits} commits)"
        # Write abort-reason file so the parent monitoring loop can detect this.
        # LOOP_ABORT_FATAL cannot propagate from this worker tmux-pane process to the
        # parent — use a marker file instead. Atomic tmp+mv prevents partial reads.
        # Do NOT touch .agent-N-complete here: completion = success in the parent's
        # eyes, which would mask the abort and let restarts fire. The parent reads
        # the abort-reason marker on its own polling cycle.
        echo "NOOP_ITERATIONS" > "$LOG_DIR/.agent-${AGENT_NUM}-abort-reason.tmp" 2>/dev/null \
            && mv "$LOG_DIR/.agent-${AGENT_NUM}-abort-reason.tmp" \
               "$LOG_DIR/.agent-${AGENT_NUM}-abort-reason" 2>/dev/null || true
        break
    fi

    if [[ "$CONSECUTIVE_FAILURES" -ge 3 ]]; then
        echo -e "  ${RED}✗${RESET} Circuit breaker — stopping agent ${AGENT_NUM}"
        break
    fi

    sleep __SLEEP_BETWEEN_ITERATIONS__
done

echo -e "\n${DIM}Agent ${AGENT_NUM} finished after ${ITERATION} iterations${RESET}"
WORKEREOF

    # Replace placeholders — use awk for all values to avoid sed injection
    # (sed breaks on & | \ in paths and test commands)
    sed_i "s|__AGENT_NUM__|${agent_num}|g" "$worker_script"
    sed_i "s|__TOTAL_AGENTS__|${total_agents}|g" "$worker_script"
    sed_i "s|__MAX_ITERATIONS__|${MAX_ITERATIONS}|g" "$worker_script"
    sed_i "s|__SLEEP_BETWEEN_ITERATIONS__|$(_config_get_int "loop.sleep_between_iterations" 2 2>/dev/null || echo 2)|g" "$worker_script"
    # Paths and commands may contain sed-special chars — use awk
    awk -v val="$wt_path" '{gsub(/__WORK_DIR__/, val); print}' "$worker_script" > "${worker_script}.tmp" \
        && mv "${worker_script}.tmp" "$worker_script"
    awk -v val="$LOG_DIR" '{gsub(/__LOG_DIR__/, val); print}' "$worker_script" > "${worker_script}.tmp" \
        && mv "${worker_script}.tmp" "$worker_script"
    awk -v val="$SCRIPT_DIR" '{gsub(/__SCRIPT_DIR__/, val); print}' "$worker_script" > "${worker_script}.tmp" \
        && mv "${worker_script}.tmp" "$worker_script"
    awk -v val="$TEST_CMD" '{gsub(/__TEST_CMD__/, val); print}' "$worker_script" > "${worker_script}.tmp" \
        && mv "${worker_script}.tmp" "$worker_script"
    awk -v val="$claude_flags" '{gsub(/__CLAUDE_FLAGS__/, val); print}' "$worker_script" > "${worker_script}.tmp" \
        && mv "${worker_script}.tmp" "$worker_script"
    awk -v val="$GOAL" '{gsub(/__GOAL__/, val); print}' "$worker_script" > "${worker_script}.tmp" \
        && mv "${worker_script}.tmp" "$worker_script"
    chmod +x "$worker_script"
    echo "$worker_script"
}

# ─── Multi-Agent: Launch ─────────────────────────────────────────────────────

MULTI_WINDOW_NAME=""

launch_multi_agent() {
    info "Setting up multi-agent mode ($AGENTS agents)..."

    # Pre-run cleanup: remove stale markers from any prior crashed run that
    # did not reach cleanup_multi_agent. Without this, wait_for_multi_completion
    # reads the prior run's abort-reason marker on its first poll and
    # false-aborts before agents have even started. cleanup_multi_agent only
    # fires at end-of-run, so OOM/SIGKILL/host-reboot leaves zombies behind.
    if [[ -n "${LOG_DIR:-}" ]]; then
        rm -f "$LOG_DIR"/.agent-*-abort-reason 2>/dev/null || true
        rm -f "$LOG_DIR"/.agent-*-complete 2>/dev/null || true
    fi

    # Setup worktrees
    setup_worktrees || { error "Failed to setup worktrees"; exit 1; }

    # Create tmux window for workers
    MULTI_WINDOW_NAME="sw-loop-$(date +%s)"
    tmux new-window -n "$MULTI_WINDOW_NAME" -c "$PROJECT_ROOT"

    # Capture the first pane's ID (stable regardless of pane-base-index)
    local monitor_pane_id
    monitor_pane_id="$(tmux list-panes -t "$MULTI_WINDOW_NAME" -F '#{pane_id}' 2>/dev/null | head -1)"

    # First pane becomes monitor
    tmux send-keys -t "$monitor_pane_id" "printf '\\033]2;loop-monitor\\033\\\\'" Enter
    sleep 0.2
    tmux send-keys -t "$monitor_pane_id" "clear && echo 'Loop Monitor — watching agent logs...'" Enter

    # Create worker panes
    for i in $(seq 1 "$AGENTS"); do
        local worker_script
        worker_script="$(generate_worker_script "$i" "$AGENTS")"

        local worker_pane_id
        worker_pane_id="$(tmux split-window -t "$MULTI_WINDOW_NAME" -c "$PROJECT_ROOT" -P -F '#{pane_id}')"
        sleep 0.1
        tmux send-keys -t "$worker_pane_id" "printf '\\033]2;agent-${i}\\033\\\\'" Enter
        sleep 0.1
        tmux send-keys -t "$worker_pane_id" "bash '$worker_script'" Enter
    done

    # Layout: monitor pane on top (35%), worker agents tile below
    tmux select-layout -t "$MULTI_WINDOW_NAME" main-vertical 2>/dev/null || true
    tmux resize-pane -t "$monitor_pane_id" -y 35% 2>/dev/null || true

    # In the monitor pane, tail all agent logs
    tmux select-pane -t "$monitor_pane_id"
    sleep 0.5
    tmux send-keys -t "$monitor_pane_id" "clear && tail -f $LOG_DIR/agent-*-iter-*.log 2>/dev/null || echo 'Waiting for agent logs...'" Enter

    success "Launched $AGENTS worker agents in window: $MULTI_WINDOW_NAME"
    echo ""

    # Wait for completion
    info "Monitoring agents... (Ctrl-C to stop all)"
    wait_for_multi_completion
}

wait_for_multi_completion() {
    while true; do
        # Check abort-reason marker FIRST. If a worker no-op-aborted AND another agent
        # happens to legitimately complete in the same cycle, the abort takes precedence
        # so restarts stay suppressed. Reading complete first would mask the abort.
        for i in $(seq 1 "$AGENTS"); do
            # C1: read abort-reason marker written by no-op detection inside worker subshell.
            # LOOP_ABORT_FATAL can't propagate across the tmux-pane process boundary, so
            # the worker writes a marker file instead; this is the reader that closes the loop.
            if [[ -f "$LOG_DIR/.agent-${i}-abort-reason" ]]; then
                local _abort_reason
                _abort_reason=$(cat "$LOG_DIR/.agent-${i}-abort-reason" 2>/dev/null | tr -d '[:space:]' || true)
                if [[ "${_abort_reason:-}" == "NOOP_ITERATIONS" ]]; then
                    warn "Agent $i aborted: ${_abort_reason} — suppressing restarts"
                    LOOP_ABORT_FATAL=true
                    STATUS="failed"
                    write_state
                    # Return 0 so callers under `set -e` continue to the LOOP_ABORT_FATAL
                    # post-check. The flag is the authoritative signal; return code is advisory.
                    return 0
                fi
            fi
        done
        # Then check completion markers
        for i in $(seq 1 "$AGENTS"); do
            if [[ -f "$LOG_DIR/.agent-${i}-complete" ]]; then
                success "Agent $i signaled <<<LOOP:PASS>>>!"
                STATUS="complete"
                write_state
                return 0
            fi
        done

        # Check if all worker panes are still running
        local running=0
        for i in $(seq 1 "$AGENTS"); do
            # Check if the worker log is still being written to
            local latest_log
            latest_log="$(ls -t "$LOG_DIR"/agent-"${i}"-iter-*.log 2>/dev/null | head -1)"
            if [[ -n "$latest_log" ]]; then
                local age
                age=$(( $(now_epoch) - $(file_mtime "$latest_log") ))
                if [[ $age -lt 300 ]]; then  # Active within 5 minutes
                    running=$(( running + 1 ))
                fi
            fi
        done

        if [[ $running -eq 0 ]]; then
            # Check if we have any logs at all (might still be starting)
            local total_logs
            total_logs="$(ls "$LOG_DIR"/agent-*-iter-*.log 2>/dev/null | wc -l | tr -d ' ')"
            if [[ "${total_logs:-0}" -gt 0 ]]; then
                warn "All agents appear to have stopped."
                STATUS="complete"
                write_state
                return 0
            fi
        fi

        sleep "$(_config_get_int "loop.multi_agent_sleep" 5 2>/dev/null || echo 5)"
    done
}

cleanup_multi_agent() {
    [[ -z "${MULTI_WINDOW_NAME:-}" ]] && return 0

    # Collect shell PIDs from each pane before sending any signals.
    # #{pane_pid} is the PID of the shell running inside the pane — reliable
    # and unaffected by pane-base-index settings.
    local pane_pids=()
    local ppid
    while IFS= read -r ppid; do
        [[ -n "$ppid" ]] && pane_pids+=("$ppid")
    done < <(tmux list-panes -t "$MULTI_WINDOW_NAME" -F '#{pane_pid}' 2>/dev/null || true)

    # Send Ctrl-C to all panes (SIGINT for graceful shutdown of running commands)
    local pane_id
    while IFS= read -r pane_id; do
        [[ -z "$pane_id" ]] && continue
        tmux send-keys -t "$pane_id" C-c 2>/dev/null || true
    done < <(tmux list-panes -t "$MULTI_WINDOW_NAME" -F '#{pane_id}' 2>/dev/null || true)

    # SIGTERM process trees (BFS kill reaches Claude/ruflo grandchildren)
    local wpid
    for wpid in "${pane_pids[@]}"; do
        [[ -z "$wpid" ]] && continue
        if declare -f _kill_process_tree >/dev/null 2>&1; then
            _kill_process_tree TERM "$wpid" 2>/dev/null || true
        else
            pkill -P "$wpid" 2>/dev/null || true
            kill "$wpid" 2>/dev/null || true
        fi
    done

    sleep 3

    # Second pass: catch panes spawned while the first pass was running (snapshot race).
    local pane_pids2=()
    local ppid2
    while IFS= read -r ppid2; do
        [[ -n "$ppid2" ]] && pane_pids2+=("$ppid2")
    done < <(tmux list-panes -t "$MULTI_WINDOW_NAME" -F '#{pane_pid}' 2>/dev/null || true)
    for wpid in "${pane_pids2[@]}"; do
        [[ -z "$wpid" ]] && continue
        kill -0 "$wpid" 2>/dev/null || continue
        if declare -f _kill_process_tree >/dev/null 2>&1; then
            _kill_process_tree TERM "$wpid" 2>/dev/null || true
        else
            pkill -P "$wpid" 2>/dev/null || true
            kill "$wpid" 2>/dev/null || true
        fi
    done

    sleep 1

    # SIGKILL any survivors from both passes
    for wpid in "${pane_pids[@]}" "${pane_pids2[@]:-}"; do
        [[ -z "$wpid" ]] && continue
        kill -0 "$wpid" 2>/dev/null || continue
        warn "Force-killing multi-agent worker PID $wpid"
        if declare -f _kill_process_tree >/dev/null 2>&1; then
            _kill_process_tree KILL "$wpid" 2>/dev/null || true
        else
            pkill -9 -P "$wpid" 2>/dev/null || true
            kill -9 "$wpid" 2>/dev/null || true
        fi
    done

    tmux kill-window -t "$MULTI_WINDOW_NAME" 2>/dev/null || true

    # Clean up completion markers and abort-reason markers
    rm -f "$LOG_DIR"/.agent-*-complete 2>/dev/null || true
    rm -f "$LOG_DIR"/.agent-*-abort-reason 2>/dev/null || true
}

# ─── Main: Single-Agent Loop ─────────────────────────────────────────────────

run_single_agent_loop() {
    # Save original environment variables before loop starts
    local SAVED_CLAUDE_MODEL="${CLAUDE_MODEL:-}"
    local SAVED_ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"

    if [[ "$SESSION_RESTART" == "true" ]]; then
        # Restart: state already reset by run_loop_with_restarts, skip init
        # Restore environment variables for clean iteration state
        [[ -n "$SAVED_CLAUDE_MODEL" ]] && export CLAUDE_MODEL="$SAVED_CLAUDE_MODEL"
        info "Session restart ${RESTART_COUNT}/${MAX_RESTARTS} — fresh context, reading progress"
    elif $RESUME; then
        resume_state
    else
        initialize_state
    fi

    # Ensure LOOP_START_COMMIT is set (may not be on resume/restart)
    if [[ -z "${LOOP_START_COMMIT:-}" ]]; then
        LOOP_START_COMMIT="$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo "")"
    fi

    # Apply adaptive budget/model before showing banner
    apply_adaptive_budget
    MODEL="$(select_adaptive_model "build" "$MODEL")"

    # Track applied memory fix patterns for outcome recording
    _applied_fix_pattern=""
    STUCKNESS_COUNT=0
    LOOP_FAILURE_DIAGNOSIS=""
    LOOP_CLOSED_LOOP_FIX=""
    LOOP_HUMAN_FEEDBACK=""
    STUCKNESS_TRACKING_FILE="$LOG_DIR/stuckness-tracking.txt"
    : > "$STUCKNESS_TRACKING_FILE" 2>/dev/null || true
    : > "${LOG_DIR:-/tmp}/strategy-attempts.txt" 2>/dev/null || true
    # Clear per-session diagnosis tracking so repeat counts don't bleed across pipeline runs
    : > "${LOG_DIR:-/tmp}/diagnoses.txt" 2>/dev/null || true

    show_banner

    while true; do
        # Reset environment variables at start of each iteration
        # Prevents previous iterations from affecting model selection or API keys
        [[ -n "$SAVED_CLAUDE_MODEL" ]] && export CLAUDE_MODEL="$SAVED_CLAUDE_MODEL"
        [[ -n "$SAVED_ANTHROPIC_API_KEY" ]] && export ANTHROPIC_API_KEY="$SAVED_ANTHROPIC_API_KEY"

        # Pre-checks (before incrementing — ITERATION tracks completed count)
        check_circuit_breaker || break
        check_max_iterations || break
        check_time_budget || break
        check_budget_gate || {
            STATUS="budget_exhausted"
            write_state
            write_progress
            error "Budget exhausted — stopping pipeline"
            show_summary
            return 1
        }
        ITERATION=$(( ITERATION + 1 ))

        # Periodic ruflo health check — attempt daemon recovery every 5 iterations
        if (( ITERATION % 5 == 0 )) && type ruflo_health_check >/dev/null 2>&1; then
            ruflo_health_check || true
        fi

        # Emit iteration start event for pipeline visibility
        if type emit_event >/dev/null 2>&1; then
            emit_event "loop.iteration_start" \
                "iteration=$ITERATION" \
                "max=$MAX_ITERATIONS" \
                "job_id=${PIPELINE_JOB_ID:-loop-$$}" \
                "agent=${AGENT_NUM:-1}" \
                "test_passed=${TEST_PASSED:-unknown}"
        fi
        type _emit_inner_stage_event >/dev/null 2>&1 && _emit_inner_stage_event "inner" "build" "iteration_start" "Iteration ${ITERATION:-?}"

        # Root-cause diagnosis and memory-based fix on retry after test failure
        if [[ "${TEST_PASSED:-}" == "false" ]]; then
            # Source memory module for diagnosis and fix lookup
            [[ -f "$SCRIPT_DIR/sw-memory.sh" ]] && source "$SCRIPT_DIR/sw-memory.sh" 2>/dev/null || true

            # Capture failure for memory (enables memory_analyze_failure and future fix lookup).
            # Pass the captured exit code as ground truth so future analysis cannot
            # hallucinate a different one from log text.
            if type memory_capture_failure &>/dev/null && [[ -n "${TEST_OUTPUT:-}" ]]; then
                memory_capture_failure "test" "$TEST_OUTPUT" "${TEST_EXIT_CODE:-0}" 2>/dev/null || true
            fi

            # Pattern-based diagnosis (no Claude needed) — inject into goal for smarter retry
            local _changed_files=""
            _changed_files=$(git diff --name-only HEAD 2>/dev/null | head -50 | tr '\n' ',' | sed 's/,$//')
            local _diagnosis
            _diagnosis=$(diagnose_failure "${TEST_OUTPUT:-}" "$_changed_files" "$ITERATION" 2>/dev/null || true)

            if [[ -n "$_diagnosis" ]]; then
                GOAL="${GOAL}

${_diagnosis}"
                LOOP_FAILURE_DIAGNOSIS="$_diagnosis"
                info "Failure diagnosis injected (classification from error pattern)"
            else
                LOOP_FAILURE_DIAGNOSIS=""
            fi

            # Self-heal hypothesis hive — root-cause triage on test failure (gated by RUFLO_SELF_HEAL_HIVE=true).
            # Function is fail-open: returns 0 always, prints empty stdout when skipped/failed.
            local _hypothesis=""
            if [[ "${RUFLO_SELF_HEAL_HIVE:-false}" == "true" ]] \
               && type ruflo_execute_self_heal_hive >/dev/null 2>&1; then
                _hypothesis=$(ruflo_execute_self_heal_hive "${TEST_OUTPUT:-}" "$_changed_files" 2>/dev/null || true)
            fi
            if [[ -n "$_hypothesis" ]]; then
                # Strip loop-control sentinels so a malformed hypothesis cannot
                # prematurely terminate the loop or corrupt the goal format.
                _hypothesis="${_hypothesis//<<<}"
                _hypothesis="${_hypothesis//>>>}"
                GOAL="${GOAL}

## Self-Heal Hypothesis (hive-selected)
${_hypothesis}"
                info "Self-heal hypothesis injected (cheapest verification path)"
            fi

            # Memory-based fix suggestion (from past successful fixes)
            local _last_error=""
            local _prev_log="$LOG_DIR/iteration-$(( ITERATION - 1 )).log"
            if [[ -f "$_prev_log" ]]; then
                _last_error=$(tail -20 "$_prev_log" 2>/dev/null | grep -iE '(error|fail|exception)' | head -1 || true)
            fi
            [[ -z "$_last_error" ]] && _last_error=$(echo "${TEST_OUTPUT:-}" | head -3 | tr '\n' ' ')
            local _fix_suggestion=""
            if type memory_closed_loop_inject >/dev/null 2>&1 && [[ -n "${_last_error:-}" ]]; then
                _fix_suggestion=$(memory_closed_loop_inject "$_last_error" 2>/dev/null) || true
            fi
            if [[ -n "${_fix_suggestion:-}" ]]; then
                _applied_fix_pattern="${_last_error}"
                GOAL="KNOWN FIX (from past success): ${_fix_suggestion}

${GOAL}"
                LOOP_CLOSED_LOOP_FIX="$_fix_suggestion"
                info "Memory fix injected: ${_fix_suggestion:0:80}"
            else
                LOOP_CLOSED_LOOP_FIX=""
            fi

            # Analyze failure via Claude (background, non-blocking) for richer root_cause/fix in memory.
            # TEST_EXIT_CODE is threaded through as ground truth — the analyst will anchor
            # category and sanitize hallucinated exit codes / signal names against it.
            if type memory_analyze_failure &>/dev/null && [[ "${INTELLIGENCE_ENABLED:-auto}" != "false" ]]; then
                local _test_log="${TEST_LOG_FILE:-$LOG_DIR/tests-iter-$(( ITERATION - 1 )).log}"
                if [[ -f "$_test_log" ]]; then
                    memory_analyze_failure "$_test_log" "test" "${TEST_EXIT_CODE:-0}" 2>/dev/null &
                    _MEM_ANALYZE_PID=$!
                fi
            fi
        else
            # Tests passed — clear previous iteration's guidance so stale info doesn't bleed forward
            LOOP_FAILURE_DIAGNOSIS=""
            LOOP_CLOSED_LOOP_FIX=""
        fi

        # Capture commit count before Claude runs so Claude-initiated commits are included in delta
        local commits_before
        commits_before="$(git_commit_count)"

        # Snapshot token counters for per-iteration cost attribution (issue #87).
        # These snapshots are only needed when ITER_COST_JSONL is set, because
        # record_iteration_cost returns early when that sidecar path is unset.
        _ITER_SNAP_INPUT="${LOOP_INPUT_TOKENS:-0}"
        _ITER_SNAP_OUTPUT="${LOOP_OUTPUT_TOKENS:-0}"
        _ITER_SNAP_COST_MC="${LOOP_COST_MILLICENTS:-0}"

        # Run Claude
        local exit_code=0
        run_claude_iteration || exit_code=$?

        # Reset per-iteration completion signal flags now that compose_prompt has consumed them.
        # Resetting here (after run_claude_iteration) rather than before it ensures compose_prompt
        # sees the PREVIOUS iteration's COMPLETION_REJECTED value and can include the rejection
        # notice in the prompt. Quality gates below will set fresh values for this iteration.
        COMPLETION_REJECTED=false
        GATES_PASSED_NO_SIGNAL=false

        # Record per-iteration delta to the pipeline's loop-iteration-costs.jsonl sidecar.
        # No-ops silently when ITER_COST_JSONL is not exported (e.g. standalone `sw loop`).
        # Note: this path is only reached in single-agent mode. Multi-agent runs go through
        # launch_multi_agent and do not currently record per-iteration iteration costs to
        # the sidecar. Iteration attribution for --agents>1 is a future enhancement.
        if type record_iteration_cost >/dev/null 2>&1; then
            record_iteration_cost "$ITERATION" 2>/dev/null || true
        fi

        local log_file="$LOG_DIR/iteration-${ITERATION}.log"
        local _err_file="${log_file%.log}.stderr"

        # Record iteration data for stuckness detection (diff hash, error hash, exit code)
        record_iteration_stuckness_data "$exit_code"

        # Detect <<<LOOP:SCOPE_ESCALATION:reason>>> signal — agent is flagging a new-scope need
        if grep -q '<<<LOOP:SCOPE_ESCALATION:' "$log_file" 2>/dev/null; then
            local _esc_reason
            _esc_reason=$(grep -o '<<<LOOP:SCOPE_ESCALATION:[^>]*>>>' "$log_file" 2>/dev/null \
                | head -1 | sed 's/<<<LOOP:SCOPE_ESCALATION:\(.*\)>>>/\1/' || true)
            type emit_event >/dev/null 2>&1 && emit_event "pipeline.scope_escalation" \
                "iteration=$ITERATION" \
                "reason=${_esc_reason:-unspecified}" \
                "job_id=${PIPELINE_JOB_ID:-loop-$$}" 2>/dev/null || true
            warn "Agent signaled scope escalation (iteration $ITERATION): ${_esc_reason:-unspecified}"
        fi

        # Detect fatal CLI errors (API key, auth, network, session/usage limits) — abort immediately
        if check_fatal_error "$log_file" "$exit_code" "$_err_file"; then
            STATUS="error"
            write_state
            write_progress
            error "Fatal CLI error detected — aborting loop (see iteration log)"
            show_summary
            return 1
        fi

        # Honor stuckness detection: if detect_stuckness() returned success this iteration,
        # halt immediately with status: stuck (not stuck_restart). This prevents the
        # infinite loop where Claude keeps getting spawned despite hitting stuckness.
        if [[ "${STUCKNESS_DETECTED_THIS_ITERATION:-false}" == "true" ]]; then
            STATUS="stuck"
            type emit_event >/dev/null 2>&1 && emit_event "loop.stuck" \
                "iteration=$ITERATION" \
                "diagnosis=${STUCKNESS_DIAGNOSIS:-cycling}" \
                "signals=${STUCKNESS_COUNT:-0}" \
                "job_id=${PIPELINE_JOB_ID:-loop-$$}"
            write_state
            write_progress
            warn "Stuckness detected on iteration $ITERATION — halting loop with status: stuck"
            show_summary
            return 1
        fi

        # Context exhaustion prevention — check cumulative token usage
        if type check_context_exhaustion >/dev/null 2>&1 && check_context_exhaustion; then
            local _ctx_pct
            _ctx_pct="$(get_context_usage_pct 2>/dev/null || echo '?')"
            warn "Context usage at ${_ctx_pct}% — triggering proactive summarization and session restart"
            summarize_loop_state >/dev/null 2>&1 || true
            STATUS="context_exhaustion"
            write_state
            write_progress
            break
        fi

        # Mid-loop memory refresh — re-query with current error context after iteration 3
        if [[ "$ITERATION" -ge 3 ]] && type memory_inject_context >/dev/null 2>&1; then
            local refresh_ctx
            refresh_ctx=$(tail -20 "$log_file" 2>/dev/null || true)
            if [[ -n "$refresh_ctx" ]]; then
                local refreshed_memory
                refreshed_memory=$(memory_inject_context "build" "$refresh_ctx" 2>/dev/null | head -5 || true)
                if [[ -n "$refreshed_memory" ]]; then
                    # Append to next iteration's memory context
                    local memory_refresh_file="$LOG_DIR/memory-refresh-${ITERATION}.txt"
                    echo "$refreshed_memory" > "$memory_refresh_file"
                fi
            fi
        fi

        # Auto-commit if Claude didn't
        git_auto_commit "$PROJECT_ROOT" || true
        local commits_after
        commits_after="$(git_commit_count)"
        local new_commits=$(( commits_after - commits_before ))
        TOTAL_COMMITS=$(( TOTAL_COMMITS + new_commits ))

        # Git diff stats
        local diff_stat
        diff_stat="$(git_diff_stat)"
        if [[ -n "$diff_stat" ]]; then
            echo -e "  ${GREEN}✓${RESET} Git: $diff_stat"
        fi

        # Track velocity for adaptive extension budget
        track_iteration_velocity

        # Test gate
        run_test_gate
        write_error_summary
        if [[ -n "$TEST_CMD" ]]; then
            if [[ "$TEST_PASSED" == "true" ]]; then
                echo -e "  ${GREEN}✓${RESET} Tests: passed"
            else
                echo -e "  ${RED}✗${RESET} Tests: failed"
            fi
        fi

        # Track fix outcome for memory effectiveness
        if [[ -n "${_applied_fix_pattern:-}" ]]; then
            if type memory_record_fix_outcome >/dev/null 2>&1; then
                if [[ "${TEST_PASSED:-}" == "true" ]]; then
                    memory_record_fix_outcome "$_applied_fix_pattern" "true" "true" 2>/dev/null || true
                else
                    memory_record_fix_outcome "$_applied_fix_pattern" "true" "false" 2>/dev/null || true
                fi
            fi
            _applied_fix_pattern=""
        fi

        # Save Claude context for checkpoint resume (goal, findings, test output)
        export SW_LOOP_GOAL="$GOAL"
        export SW_LOOP_ITERATION="$ITERATION"
        export SW_LOOP_STATUS="${STATUS:-running}"
        export SW_LOOP_TEST_OUTPUT="${TEST_OUTPUT:-}"
        export SW_LOOP_FINDINGS="${LOG_ENTRIES:-}"
        # shellcheck disable=SC2155
        export SW_LOOP_MODIFIED="$(git diff --name-only HEAD 2>/dev/null | head -50 | tr '\n' ',' | sed 's/,$//')"
        "$SCRIPT_DIR/sw-checkpoint.sh" save-context --stage build 2>/dev/null || true

        # Audit agent (reviews implementer's work)
        run_audit_agent

        # Verification gap detection: audit failed but tests passed
        # Instead of a full retry (which causes context bloat/timeout), run targeted verification
        if [[ "${AUDIT_RESULT:-}" != "pass" ]] && [[ "${TEST_PASSED:-}" == "true" ]]; then
            type _emit_inner_stage_event >/dev/null 2>&1 && _emit_inner_stage_event "inner" "build" "verification_gap_warning" "Verification gap detected"
            echo -e "  ${YELLOW}▸${RESET} Verification gap detected (tests pass, audit disagrees)"

            local verification_passed=true

            # 1. Re-run ALL test commands to double-check
            local recheck_log="${LOG_DIR}/verification-iter-${ITERATION}.log"
            if [[ -n "$TEST_CMD" ]]; then
                eval "$TEST_CMD" > "$recheck_log" 2>&1 || verification_passed=false
            fi
            for _vg_cmd in "${ADDITIONAL_TEST_CMDS[@]+"${ADDITIONAL_TEST_CMDS[@]}"}"; do
                [[ -z "$_vg_cmd" ]] && continue
                eval "$_vg_cmd" >> "$recheck_log" 2>&1 || verification_passed=false
            done

            # 2. Check for uncommitted changes (quality gate)
            if ! git -C "$PROJECT_ROOT" diff --quiet -- $(_git_excluded_pathspecs) 2>/dev/null; then
                echo -e "  ${YELLOW}⚠${RESET} Uncommitted changes detected"
                verification_passed=false
            fi

            if [[ "$verification_passed" == "true" ]]; then
                echo -e "  ${GREEN}✓${RESET} Verification passed — overriding audit"
                # Root-cause fix (PR B): only override AUDIT_RESULT if cumulative diff vs
                # cycle-start commit is non-empty. A no-op iteration trivially satisfies
                # "tests pass + tree clean", so guard the override with an actual change check.
                local _vgap_cumulative_diff=""
                if [[ -n "${OUTER_STAGE_START_COMMIT:-}" ]]; then
                    _vgap_cumulative_diff="$(git -C "${PROJECT_ROOT:-.}" diff --name-only "${OUTER_STAGE_START_COMMIT}..HEAD" 2>/dev/null || true)"
                fi
                if [[ -z "${OUTER_STAGE_START_COMMIT:-}" ]] || [[ -n "$_vgap_cumulative_diff" ]]; then
                    AUDIT_RESULT="pass"
                    type _emit_inner_stage_event >/dev/null 2>&1 && _emit_inner_stage_event "inner" "build" "verification_gap_resolved" "Audit override applied"
                    emit_event "loop.verification_gap_resolved" \
                        "iteration=$ITERATION" "action=override_audit"
                    if type audit_emit >/dev/null 2>&1; then
                        audit_emit "loop.verification_gap" "iteration=$ITERATION" \
                            "resolution=override" "tests_recheck=pass" || true
                    fi
                else
                    type _emit_inner_stage_event >/dev/null 2>&1 && _emit_inner_stage_event "inner" "build" "verification_gap_confirmed" "Audit override NOT applied"
                    emit_event "loop.verification_gap_confirmed" \
                        "iteration=$ITERATION" "action=noop_no_cumulative_diff"
                    warn "Verification gap: no cumulative diff vs cycle-start — audit override suppressed (no-op iteration)"
                fi
            else
                type _emit_inner_stage_event >/dev/null 2>&1 && _emit_inner_stage_event "inner" "build" "verification_gap_confirmed" "Audit override NOT applied"
                echo -e "  ${RED}✗${RESET} Verification failed — audit stands"
                emit_event "loop.verification_gap_confirmed" \
                    "iteration=$ITERATION" "action=retry"
                if type audit_emit >/dev/null 2>&1; then
                    audit_emit "loop.verification_gap" "iteration=$ITERATION" \
                        "resolution=retry" "tests_recheck=fail" || true
                fi
            fi
        fi

        # Auto-commit any remaining changes before quality gates
        # (audit agent, verification handler, or test evidence may create files)
        if ! git -C "$PROJECT_ROOT" diff --quiet -- $(_git_excluded_pathspecs) 2>/dev/null || \
           ! git -C "$PROJECT_ROOT" diff --cached --quiet -- $(_git_excluded_pathspecs) 2>/dev/null || \
           [[ -n "$(git -C "$PROJECT_ROOT" ls-files --others --exclude-standard 2>/dev/null | head -1)" ]]; then
            safe_git_stage "$PROJECT_ROOT"
            git -C "$PROJECT_ROOT" commit -m "loop: iteration $ITERATION — post-audit cleanup" --no-verify 2>/dev/null || true
        fi

        # Recompute iteration commit count after post-audit cleanup
        local commits_after_cleanup
        commits_after_cleanup="$(git_commit_count)"
        new_commits=$(( commits_after_cleanup - commits_before ))
        TOTAL_COMMITS=$(( TOTAL_COMMITS + commits_after_cleanup - commits_after ))

        # Quality gates (automated checks)
        run_quality_gates

        # Hard stop: a fatal tooling error (e.g., DoD prompt too large) means retry
        # won't help. Exit immediately so the user gets an actionable diagnostic.
        if [[ "${LOOP_ABORT_FATAL:-false}" == "true" ]]; then
            error "Loop aborted: fatal tooling error — see DoD diagnostic above"
            STATUS="failed"
            write_state
            write_progress
            return 1
        fi

        # Guarded completion (replaces naive grep check)
        if guard_completion; then
            STATUS="complete"
            write_state
            write_progress
            show_summary
            return 0
        fi

        # If gates passed but agent never emitted <<<LOOP:PASS>>>, hint next iteration.
        # Only set when quality gates are actually enabled (disabled runs default
        # QUALITY_GATE_PASSED=true unconditionally) and audit also passed.
        GATES_PASSED_NO_SIGNAL=false
        if $QUALITY_GATES_ENABLED && $QUALITY_GATE_PASSED && \
           [[ "${COMPLETION_REJECTED:-false}" != "true" ]] && \
           [[ "${AUDIT_RESULT:-pass}" == "pass" ]]; then
            GATES_PASSED_NO_SIGNAL=true
        fi

        # Early exit: all gates passing — work is done regardless of whether commits were made.
        # Holistic gate runs as a final independent confirmation before exiting.
        if [[ "$GATES_PASSED_NO_SIGNAL" == "true" ]] && run_holistic_gate; then
            STATUS="complete"
            emit_event "loop.early_exit_gates_passed" \
                "iteration=$ITERATION" \
                "total_commits=$TOTAL_COMMITS" 2>/dev/null || true
            echo -e "  ${GREEN}${BOLD}✓ Complete — all gates passing${RESET}"
            write_state
            write_progress
            show_summary
            return 0
        fi

        # Check progress (circuit breaker)
        # Count a strike whenever there is no progress (no new commits) and we are
        # NOT in the "(tests pass AND audit passes)" bypass. This includes cases
        # where tests or audit failed, were skipped, or have not yet run. The only
        # no-progress case that is not penalized is when both tests and audit pass —
        # the implementation is verified and the agent isn't stuck.
        if check_progress "$new_commits"; then
            CONSECUTIVE_FAILURES=0
            if [[ "${TEST_PASSED:-}" == "true" ]]; then
                echo -e "  ${GREEN}✓${RESET} Progress detected — continuing"
            elif [[ "${TEST_PASSED:-}" == "false" ]]; then
                echo -e "  ${CYAN}▸${RESET} Progress detected — tests still failing"
            else
                echo -e "  ${CYAN}▸${RESET} Progress detected — continuing"
            fi
        elif [[ "${TEST_PASSED:-}" == "true" ]] && \
             { ! $AUDIT_AGENT_ENABLED || [[ "${AUDIT_RESULT:-}" == "pass" ]]; } && \
             { ! $QUALITY_GATES_ENABLED || $QUALITY_GATE_PASSED; }; then
            # Tests passed AND audit either passed or is disabled AND quality gates
            # either passed or are disabled. All verification signals agree the
            # implementation is correct — this is not a stuck agent.
            # Clear prior strikes so stale counts don't trip the breaker later.
            CONSECUTIVE_FAILURES=0
            echo -e "  ${CYAN}▸${RESET} Tests, audit, and quality gates passed — skipping circuit breaker strike"
        else
            CONSECUTIVE_FAILURES=$(( CONSECUTIVE_FAILURES + 1 ))
            echo -e "  ${YELLOW}⚠${RESET} Low progress (${CONSECUTIVE_FAILURES}/${CIRCUIT_BREAKER_THRESHOLD} before circuit breaker)"
        fi

        # Persist commit count so the next iteration's compose_prompt() can detect
        # zero-progress (agent made no commits but quality gate is still failing).
        PREV_NEW_COMMITS="${new_commits:-0}"

        # Extract summary and update state
        local summary outcome
        summary="$(extract_summary "$log_file")"
        outcome="$(compose_iteration_outcome)"
        append_log_entry "### Iteration $ITERATION ($(now_iso))
${summary}

${outcome}
"
        write_state
        write_progress

        # Emit iteration complete event for pipeline visibility
        if type emit_event >/dev/null 2>&1; then
            emit_event "loop.iteration_complete" \
                "iteration=$ITERATION" \
                "max=$MAX_ITERATIONS" \
                "job_id=${PIPELINE_JOB_ID:-loop-$$}" \
                "agent=${AGENT_NUM:-1}" \
                "test_passed=${TEST_PASSED:-unknown}" \
                "commits=$TOTAL_COMMITS" \
                "status=${STATUS:-running}"
        fi
        type _emit_inner_stage_event >/dev/null 2>&1 && _emit_inner_stage_event "inner" "build" "iteration_complete" "Iteration ${ITERATION:-?}"

        # Update heartbeat
        "$SCRIPT_DIR/sw-heartbeat.sh" write "${PIPELINE_JOB_ID:-loop-$$}" \
            --pid $$ \
            --stage "build" \
            --iteration "$ITERATION" \
            --activity "Loop iteration $ITERATION" 2>/dev/null || true

        # Human intervention: check for human message between iterations
        local human_msg_file="$STATE_DIR/pipeline-artifacts/human-message.txt"
        LOOP_HUMAN_FEEDBACK=""
        if [[ -f "$human_msg_file" ]]; then
            local human_msg
            human_msg="$(cat "$human_msg_file" 2>/dev/null || true)"
            if [[ -n "$human_msg" ]]; then
                echo -e "  ${PURPLE}${BOLD}💬 Human message:${RESET} $human_msg"
                # Inject human message as additional context for next iteration
                GOAL="${GOAL}

HUMAN FEEDBACK (received after iteration $ITERATION): $human_msg"
                LOOP_HUMAN_FEEDBACK="$human_msg"
                rm -f "$human_msg_file"
            fi
        fi

        # Stuckness-triggered restart: if detected 3+ times, break to allow session restart
        if [[ "${STUCKNESS_COUNT:-0}" -ge 3 ]]; then
            STATUS="stuck_restart"
            write_state
            write_progress
            warn "Stuckness detected 3+ times — triggering session restart"
            break
        fi

        sleep "$(_config_get_int "loop.sleep_between_iterations" 2 2>/dev/null || echo 2)"
    done

    # Write final state after loop exits
    write_state
    write_progress
    show_summary
}

# ─── Session Restart Wrapper ─────────────────────────────────────────────────

run_loop_with_restarts() {
    while true; do
        local loop_exit=0
        run_single_agent_loop || loop_exit=$?

        # Fatal tooling error — restart won't fix it; surface the diagnostic and stop.
        if [[ "${LOOP_ABORT_FATAL:-false}" == "true" ]]; then
            warn "Fatal error — suppressing restart"
            return "$loop_exit"
        fi

        # If completed successfully or no restarts configured, exit
        if [[ "$STATUS" == "complete" ]]; then
            return 0
        fi
        if [[ "$MAX_RESTARTS" -le 0 ]]; then
            return "$loop_exit"
        fi
        if [[ "$RESTART_COUNT" -ge "$MAX_RESTARTS" ]]; then
            warn "Max restarts ($MAX_RESTARTS) reached — stopping"
            return "$loop_exit"
        fi
        # Hard cap safety net
        if [[ "$RESTART_COUNT" -ge 5 ]]; then
            warn "Hard restart cap (5) reached — stopping"
            return "$loop_exit"
        fi

        # Check if tests are still failing (worth restarting)
        if [[ "${TEST_PASSED:-}" == "true" ]]; then
            info "Tests passing but loop incomplete — restarting session"
        else
            info "Tests failing and loop exhausted — restarting with fresh context"
        fi

        RESTART_COUNT=$(( RESTART_COUNT + 1 ))
        local _restart_reason="${STATUS:-unknown}"
        local _prev_iteration="$ITERATION"
        if type emit_event >/dev/null 2>&1; then
            emit_event "loop.restart" "restart=$RESTART_COUNT" "max=$MAX_RESTARTS" "iteration=$ITERATION" "reason=$_restart_reason"
        fi
        info "Session restart ${RESTART_COUNT}/${MAX_RESTARTS} — resetting iteration counter"

        # Reset ALL iteration-level state for the new session
        # SESSION_RESTART tells run_single_agent_loop to skip init/resume
        SESSION_RESTART=true
        ITERATION=0
        CONSECUTIVE_FAILURES=0
        EXTENSION_COUNT=0
        STUCKNESS_COUNT=0
        STATUS="running"
        LOG_ENTRIES=""
        TEST_PASSED=""
        TEST_OUTPUT=""
        TEST_LOG_FILE=""
        # Preserve LOOP_START_EPOCH across restarts — time budget is wall-clock from
        # the very first loop invocation, not from each session restart.
        : "${LOOP_START_EPOCH:=$(now_epoch 2>/dev/null || echo 0)}"
        # Reset GOAL to original — prevent unbounded growth from memory/human injections
        GOAL="$ORIGINAL_GOAL"
        # Reset per-session token counters on every restart — cumulative totals from
        # the previous session must not carry over and trigger false exhaustion warnings
        reset_token_counters

        # Context exhaustion restart: inject compressed summary so the new session
        # has essential context without re-exhausting the window
        if [[ "$_restart_reason" == "context_exhaustion" ]]; then
            local _ctx_summary_file="${LOG_DIR:-/tmp}/context-summary.md"
            if [[ -f "$_ctx_summary_file" ]]; then
                local _ctx_summary
                _ctx_summary="$(head -50 "$_ctx_summary_file" 2>/dev/null || true)"
                if [[ -n "$_ctx_summary" ]]; then
                    GOAL="${GOAL}

## Previous Session Context (Summarized)
${_ctx_summary}"
                    info "Context summary injected from previous session (${#_ctx_summary} chars)"
                fi
            fi
            if type emit_event >/dev/null 2>&1; then
                emit_event "loop.context_exhaustion_restart" \
                    "restart=$RESTART_COUNT" \
                    "prev_iteration=$_prev_iteration" \
                    "iteration=$ITERATION"
            fi
        fi

        # Archive old artifacts so they don't get overwritten or pollute new session
        local restart_archive="$LOG_DIR/restart-${RESTART_COUNT}"
        mkdir -p "$restart_archive"
        for old_log in "$LOG_DIR"/iteration-*.log "$LOG_DIR"/tests-iter-*.log; do
            [[ -f "$old_log" ]] && mv "$old_log" "$restart_archive/" 2>/dev/null || true
        done
        # Archive progress.md and error-summary.json from previous session
        # IMPORTANT: copy (not move) error-summary.json so the fresh session can still read it
        [[ -f "$LOG_DIR/progress.md" ]] && cp "$LOG_DIR/progress.md" "$restart_archive/progress.md" 2>/dev/null || true
        [[ -f "$LOG_DIR/error-summary.json" ]] && cp "$LOG_DIR/error-summary.json" "$restart_archive/" 2>/dev/null || true

        write_state

        sleep "$(_config_get_int "loop.sleep_between_iterations" 2 2>/dev/null || echo 2)"
    done
}

# ─── Main: Entry Point ───────────────────────────────────────────────────────

main() {
    if [[ "$AGENTS" -gt 1 ]]; then
        if $RESUME; then
            resume_state
        else
            initialize_state
        fi
        show_banner
        # Guard against set -e: launch_multi_agent → wait_for_multi_completion may
        # return non-zero on abort. The LOOP_ABORT_FATAL flag is the authoritative
        # signal; `|| true` ensures the post-check always runs.
        launch_multi_agent || true
        if [[ "${LOOP_ABORT_FATAL:-false}" == "true" ]]; then
            warn "Abort-fatal flag set by multi-agent worker — suppressing any restart"
            STATUS="${STATUS:-failed}"
        fi
        show_summary
    else
        run_loop_with_restarts
    fi
}

main
